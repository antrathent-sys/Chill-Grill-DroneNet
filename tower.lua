-- tower: the CINDER traffic tower (AVIONICS.md). The MASTER is a computer of
-- its own at CHI with an ender modem, a disk drive and monitors. It registers
-- CINDER NAV units, hears every registered unit's ping, answers each with the
-- traffic near it and where the traffic centres are, keeps the registry and
-- the log, and feeds any number of display-only CENTRES elsewhere: every ping
-- goes to the master, and a centre only shows what the master hears (Alex,
-- 2026-10-01). On any monitor 3x3 or bigger the tower shows its radar; on the
-- others, and on its own screen, the board (lib/towerui.lua).
--
--   tower                  run (startup autorun tower): the master, or a centre
--                          if this computer has been made one
--   tower register         register a unit: put its computer in the disk drive
--   tower list             every registration
--   tower show <reg|unit>  one registration and when it was last heard
--   tower revoke <reg|unit>  forget its key: it can no longer speak to the tower
--   tower log [n]          the last n events (default 20)
--   tower here <NAME> <x> <y> <z>   this master's name and place, told to every unit
--   tower range <blocks>   the radar's outer ring (default 2000)
--   tower centre add <NAME> <x> <y> <z>   make a display-only centre: its
--                          computer (or a floppy for it) in the drive
--   tower centre list | drop <NAME>
--   tower join             on a centre: take its identity off the master's floppy
--
-- It holds every unit's key (.navkeys) and NEVER a fleet key: it is the
-- public face, and nothing on it can fly a CINDER unit. What it sends a unit
-- is information only.
--
--   .navkeys     unit id -> key, one line each (seckey's format)
--   navreg.lua   the registry: one record per unit (lib/nav.lua)
--   navlog.csv   one line per event: registered, first heard, departed,
--                arrived, distress, updated, revoked
--
-- A unit that goes quiet is AWAY, never an alarm: players pack their craft
-- into containers, and the unit goes with it until it is put out again.
--   .pong.ctr    the counter every pong is sealed under
--   tower.cfg    this tower's name, place and radar range
--   centres.lua  the display-only centres it feeds: NAME=x,y,z
--   .centrekeys  their keys; .pic.ctr the counter their pictures go under
-- On a centre: .centre (its name, place and master) and .centrekey.

local N = dofile("lib/nav.lua")
local SEC = dofile("lib/seclink.lua")
local args = { ... }
local cmd = (args[1] or "run"):lower()

local KEYS, REG, LOG, PONG_CTR = ".navkeys", "navreg.lua", "navlog.csv", ".pong.ctr"
local LOG_MAX = 256 * 1024          -- bytes, then the log rolls to navlog.old.csv

local function readAll(p)
  if not fs.exists(p) then return nil end
  local h = fs.open(p, "r")
  if not h then return nil end
  local s = h.readAll()
  h.close()
  return s
end
local function writeText(p, text)
  local h = fs.open(p, "w")
  if not h then return false end
  h.write(text)
  h.close()
  return true
end
local function nowSecs() return os.epoch and math.floor(os.epoch("utc") / 1000) or os.time() end
local function today()
  local ok, s = pcall(os.date, "!%Y-%m-%d")
  return ok and type(s) == "string" and s or tostring(nowSecs())
end

local function loadReg()
  local recs, bad = N.loadRegistry(readAll(REG) or "")
  for _, why in ipairs(bad) do print("registry: " .. why) end
  return recs
end
local function saveReg(recs) return writeText(REG, N.serialise(recs)) end
local function loadKeys() return (SEC.readFleetKeys(KEYS)) end
local function saveKeys(keys) return writeText(KEYS, SEC.formatFleetKeys(keys, SEC.NAV_HEADER)) end

local function logEvent(rec, ev, c, detail)
  if fs.exists(LOG) and fs.getSize and fs.getSize(LOG) > LOG_MAX then
    if fs.exists("navlog.old.csv") then fs.delete("navlog.old.csv") end
    fs.move(LOG, "navlog.old.csv")
  end
  local fresh = not fs.exists(LOG)
  local h = fs.open(LOG, "a")
  if not h then return end
  if fresh then h.write(N.LOG_HEADER .. "\n") end
  h.write(N.event(nowSecs(), rec, ev, c, detail) .. "\n")
  h.close()
end

local function ask(q)
  write(q .. " ")
  local a = read()
  return type(a) == "string" and a:gsub("^%s+", ""):gsub("%s+$", "") or ""
end
local function yes(q) return ask(q .. " (y/n)"):lower():sub(1, 1) == "y" end

-- ------------------------------------------------- this tower and its centres --
local CFG, CENTRES, CKEYS, PIC_CTR = "tower.cfg", "centres.lua", ".centrekeys", ".pic.ctr"
local APPS = "centreapps.csv"      -- applications to host a centre, from the kiosks
local KKEYS, KSTATUS, KIOSK_CTR = ".kioskkeys", "kiosks.status", ".kiosk.ctr"   -- registration kiosks
-- Open (Alex, 2026-10-02: "disable the key for now"): while this file exists
-- the master also answers kiosks with no key, in the clear. For testing: a new
-- unit's key then goes over the air unsealed, and any computer could ask.
local KOPEN = "kiosks.open"
local ME_FILE, ME_KEY = ".centre", ".centrekey"
local function loadCfg()
  local t = {}
  for k, v in (readAll(CFG) or ""):gmatch("(%w+)=([^\n]*)") do t[k] = v end
  return { name = N.validCentre(t.name) or "TOWER", x = tonumber(t.x), y = tonumber(t.y), z = tonumber(t.z),
           range = tonumber(t.range) or 2000 }
end
local function saveCfg(c)
  local lines = { "name=" .. c.name, "range=" .. c.range }
  if c.x then
    lines[#lines + 1] = "x=" .. math.floor(c.x)
    lines[#lines + 1] = "y=" .. math.floor(c.y or 0)
    lines[#lines + 1] = "z=" .. math.floor(c.z)
  end
  writeText(CFG, table.concat(lines, "\n") .. "\n")
end
local function loadCentres()
  local out = {}
  for name, x, y, z in (readAll(CENTRES) or ""):gmatch("([%w%-]+)=(%-?%d+),(%-?%d+),(%-?%d+)") do
    out[#out + 1] = { name = name, x = tonumber(x), y = tonumber(y), z = tonumber(z) }
  end
  return out
end
local function saveCentres(list)
  local lines = { "-- display-only centres this master feeds (tower centre add)" }
  for _, c in ipairs(list) do lines[#lines + 1] = string.format("%s=%d,%d,%d", c.name, c.x, c.y or 0, c.z) end
  writeText(CENTRES, table.concat(lines, "\n") .. "\n")
end
-- a display-only centre has its identity from the master
local slave = N.parseCentreFile(readAll(ME_FILE))

local function describe(rec)
  local status = rec.revoked and ("REVOKED " .. rec.revoked) or (rec.last and "registered" or "registered, never heard")
  return string.format("%s  %-16s %-12s %s%s (%s)", N.regNumber(rec.n), rec.call, N.TYPES[rec.kind].word,
    rec.owner, rec.idby == "typed" and " (typed)" or "", status)
end

-- Registering. The files are the truth: read, added to and written in one
-- go, with nothing in between that could let another of this computer's
-- loops run. A unit filed: its record and its new key, saved.
local function fileUnit(owner, idby, kind, call, by)
  local recs, keys = loadReg(), loadKeys()
  local n = N.nextNumber(recs)
  local rec = { n = n, unit = N.unitId(n), owner = owner, idby = idby, call = call, kind = kind,
                issued = today(), by = by or (os.getComputerLabel and os.getComputerLabel()) or nil }
  local key = SEC.newKey()
  keys[rec.unit] = key
  saveKeys(keys)
  recs[#recs + 1] = rec
  saveReg(recs)
  return rec, key
end
-- ...and taken back out, when it could not be written onto its computer
local function unfileUnit(unit)
  local recs, keep = loadReg(), {}
  for _, r in ipairs(recs) do if r.unit ~= unit then keep[#keep + 1] = r end end
  saveReg(keep)
  local keys = loadKeys()
  keys[unit] = nil
  saveKeys(keys)
end
-- A new unit on the computer at `mount` (in `drive`): the record, or nil, why.
local function newUnit(drive, mount, owner, idby, kind, call)
  local rec, key = fileUnit(owner, idby, kind, call)
  local ok, why = N.install(fs, mount, { rec = rec, keyHex = SEC.keyHex(key), src = "", version = readAll(".commit") })
  if not ok then unfileUnit(rec.unit) return nil, why end
  pcall(peripheral.call, drive, "setDiskLabel", rec.unit)
  logEvent(rec, "registered", nil, owner .. " " .. kind .. " " .. idby)
  return rec
end
-- A registered unit's software refreshed and its key kept; its type and
-- callsign changed when given.
-- mount nil: the record only (a kiosk writes the unit itself). owner, when
-- given, must be the unit's.
local function refreshUnit(mount, unit, kind, call, owner)
  local recs = loadReg()
  local rec = N.find(recs, unit)
  if not rec or rec.revoked then return nil, "not registered" end
  if owner and rec.owner:lower() ~= tostring(owner):lower() then return nil, "NOT YOUR UNIT" end
  if call and call ~= rec.call then
    local free, whyNot = N.callFree(recs, call, unit)
    if not free then return nil, whyNot end
    call = free
  end
  local changed = (kind ~= nil and kind ~= rec.kind) or (call ~= nil and call ~= rec.call)
  rec.kind, rec.call = kind or rec.kind, call or rec.call
  if mount then
    local ok, why = N.install(fs, mount, { rec = rec, src = "", version = readAll(".commit") })
    if not ok then return nil, why end
  end
  if changed then saveReg(recs) end
  logEvent(rec, "updated", nil, changed and (rec.kind .. " " .. rec.call) or nil)
  return rec
end

if slave and (cmd == "register" or cmd == "list" or cmd == "show" or cmd == "revoke" or cmd == "log"
              or cmd == "kiosk") then
  print(string.format("this is the %s centre, display only - registrations live on the master (%s)", slave.name,
    tostring(slave.master or "?")))
  return
end

-- ------------------------------------------------------------ registering --
if cmd == "register" then
  local drive
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n) == "drive" then drive = n break end
  end
  if not drive then print("no disk drive beside this computer - fit one to register units") return end
  local function eject() pcall(peripheral.call, drive, "ejectDisk") end
  if not peripheral.call(drive, "hasData") then
    print("put the unit's computer in the drive (" .. drive .. ")")
    repeat sleep(0.5) until peripheral.call(drive, "hasData")
  end
  local mount = peripheral.call(drive, "getMountPath")
  local info = N.inspect(fs, mount)
  if info.kind == "dev" then
    print("that is one of CINDER's own machines (" .. tostring(info.marker) .. ") - not touching it")
    eject() return
  end
  if info.kind == "pass" then
    print("that is a customer's pass, not a nav unit - provision looks after those")
    eject() return
  end
  local recs = loadReg()
  local keys = loadKeys()
  if info.kind == "unit" and info.me then
    local rec = N.find(recs, info.me.unit)
    if rec and not rec.revoked and keys[rec.unit] then
      print(describe(rec))
      if yes("update its software, keeping its key and registration?") then
        local ok, why = refreshUnit(mount, rec.unit)
        print(ok and ("updated " .. N.regNumber(rec.n)) or ("could not: " .. tostring(why)))
      end
      eject() return
    end
    print("a unit this tower does not know, or one that was revoked - it can be registered afresh")
  end
  if info.kind == "other" or info.kind == "unit" then
    print("it has files on it: " .. table.concat(info.files or {}, " "):sub(1, 120))
    if not yes("wipe them and make it a CINDER NAV unit?") then eject() return end
  end

  -- The owner: whoever is sitting in the seat beside the tower (Alex,
  -- 2026-10-02), so nobody registers a unit in somebody else's name. No seat
  -- fitted: typed, and the record says so.
  local seat
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n) == "create_target" then seat = n break end
  end
  local owner, idby
  if seat then
    local function seated()
      local okL, line = pcall(peripheral.call, seat, "getLine", 1)
      return okL and N.seatName(line) or nil
    end
    owner = seated()
    if not owner then
      print(string.format("the owner sits in the seat now (%d s)", N.SEAT_WAIT))
      local t0 = os.clock()
      repeat sleep(0.5) owner = seated() until owner or os.clock() - t0 > N.SEAT_WAIT
    end
    if not owner then print("nobody in the seat - not registered") eject() return end
    if not yes("owner " .. owner .. " (in the seat) - right?") then eject() return end
    idby = "seat"
  else
    print("no seat fitted (a Create Seat, a Display Link on it reading Entity Name, a CC:C Bridge")
    print("target block on this computer) - the name is typed, and not checked")
    for _ = 1, 3 do
      owner = ask("owner's player name:")
      if N.validOwner(owner) then break end
      print("a player name is 3 to 16 letters, digits or _")
      owner = nil
    end
    if not owner then eject() return end
    idby = "typed"
  end
  local kind
  local WORDS = { air = "air", aircraft = "air", plane = "air", airship = "air",
                  land = "land", car = "land", vehicle = "land", train = "land",
                  sea = "sea", boat = "sea", ship = "sea", vessel = "sea",
                  sub = "sub", submarine = "sub" }
  for _ = 1, 3 do
    kind = WORDS[ask("vehicle type - air, land, sea or sub:"):lower()]
    if kind then break end
    print("one of: air, land, sea, sub")
  end
  if not kind then eject() return end
  local call
  for _ = 1, 3 do
    local why
    call, why = N.callFree(loadReg(), ask("callsign - what traffic calls it (2-16 letters, digits, - or space):"))
    if call then break end
    print(tostring(why):lower())
  end
  if not call then eject() return end

  local rec, why = newUnit(drive, mount, owner, idby, kind, call)
  if not rec then print("could not: " .. tostring(why)) eject() return end
  print(string.format("REGISTERED %s  %s  %s  for %s", N.regNumber(rec.n), call, N.TYPES[kind].word, owner))
  print("fit it with an advanced monitor and an ender modem on the vehicle; it starts by itself")
  eject()
  return
end

-- --------------------------------------------------------------- the books --
if cmd == "list" then
  local recs = loadReg()
  if #recs == 0 then print("no registrations yet - tower register") end
  for _, r in ipairs(recs) do print(describe(r)) end
  return
end

if cmd == "show" then
  local rec = N.find(loadReg(), args[2])
  if not rec then print("no registration " .. tostring(args[2]) .. " - tower list") return end
  print(describe(rec))
  print(string.format("  unit %s, issued %s by %s", rec.unit, tostring(rec.issued), tostring(rec.by)))
  print(string.format("  vehicle: %s %s, mass %s", tostring(rec.sname or "?"), tostring(rec.sid or "not yet heard"),
    tostring(rec.mass or "?")))
  if rec.last then
    print(string.format("  last heard %d s ago at %d %d %d", nowSecs() - rec.last, rec.x or 0, rec.y or 0, rec.z or 0))
  end
  return
end

if cmd == "revoke" then
  local recs = loadReg()
  local rec = N.find(recs, args[2])
  if not rec then print("no registration " .. tostring(args[2]) .. " - tower list") return end
  local keys = loadKeys()
  keys[rec.unit] = nil
  saveKeys(keys)
  rec.revoked = today()
  saveReg(recs)
  logEvent(rec, "revoked")
  print("revoked " .. N.regNumber(rec.n) .. " - a running tower stops answering it within 10 s")
  return
end

if cmd == "log" then
  local text = readAll(LOG) or ""
  local lines = {}
  for l in text:gmatch("[^\n]+") do lines[#lines + 1] = l end
  local want = tonumber(args[2]) or 20
  for i = math.max(2, #lines - want + 1), #lines do print(lines[i]) end
  return
end

-- ---------------------------------------------------------------- centres --
-- This tower's own name and place, and the display-only centres it feeds.
if cmd == "here" then
  local name = N.validCentre(args[2])
  local x, y, z = tonumber(args[3]), tonumber(args[4]), tonumber(args[5])
  if not (name and x and y and z) then print("tower here <NAME> <x> <y> <z>   e.g. tower here CHI 2497 70 -3297") return end
  if slave then print("this is a display-only centre: its name and place came from its master") return end
  local cfg = loadCfg()
  cfg.name, cfg.x, cfg.y, cfg.z = name, x, y, z
  saveCfg(cfg)
  print(string.format("this tower is %s at %d %d %d - every unit is told so", name, x, y, z))
  return
end

-- Registration kiosks (navdesk.lua): computers of their own, wherever
-- players are, that ask this master to register units. `tower kiosk add`
-- gives one its name and key, through the drive, the way centres get theirs.
if cmd == "kiosk" or cmd == "kiosks" then
  local sub = (args[2] or "list"):lower()
  local keys = SEC.readFleetKeys(KKEYS)
  if sub == "open" or sub == "closed" or sub == "close" then
    if sub == "open" then
      writeText(KOPEN, "kiosks without a key are answered in the clear - tower kiosk closed ends it\n")
      print("kiosks OPEN: any kiosk is answered without a key, in the clear - a new unit's key goes over the air")
      print("unsealed and any computer can ask. For testing; tower kiosk closed to end it.")
    else
      if fs.exists(KOPEN) then fs.delete(KOPEN) end
      print("kiosks closed: only kiosks with a key from tower kiosk add are answered")
    end
    return
  end
  if sub == "list" then
    print(fs.exists(KOPEN) and "kiosks OPEN - answered without a key (tower kiosk closed)" or "kiosks closed - keys only")
    local st = {}
    for id, stock, t in (readAll(KSTATUS) or ""):gmatch("([%w%-]+)=(%-?%d+),(%d+)") do st[id] = { tonumber(stock), tonumber(t) } end
    local any = false
    for id in pairs(keys) do
      any = true
      local s2 = st[id]
      print(string.format("  %-16s %s", id, s2 and string.format("%s kits, heard %s",
        s2[1] >= 0 and tostring(s2[1]) or "no chests", os.date and os.date("%m-%d %H:%M", s2[2]) or s2[2])
        or "never heard"))
    end
    if not any then print("no kiosks - tower kiosk add <NAME> with the kiosk's computer in the drive") end
    return
  end
  if sub == "drop" then
    local name = N.validCentre(args[3])
    if not (name and keys[N.kioskId(name)]) then print("no kiosk " .. tostring(args[3])) return end
    keys[N.kioskId(name)] = nil
    writeText(KKEYS, SEC.formatFleetKeys(keys, SEC.KIOSK_HEADER))
    print("dropped " .. name .. " - the master no longer answers it")
    return
  end
  if sub == "add" then
    local name = N.validCentre(args[3])
    if not name then print("tower kiosk add <NAME>   (2-12 letters, digits or dashes) with its computer in the drive") return end
    local drive
    for _, n in ipairs(peripheral.getNames()) do if peripheral.getType(n) == "drive" then drive = n break end end
    if not (drive and peripheral.call(drive, "hasData")) then
      print("put the kiosk's computer, or a floppy for it, in the disk drive first") return
    end
    local mount = peripheral.call(drive, "getMountPath")
    local key = SEC.newKey()
    writeText(mount .. "/.navdeskkey", SEC.keyHex(key) .. "\n")
    writeText(mount .. "/.navdesk", N.kioskFile({ name = name, master = loadCfg().name }))
    keys[N.kioskId(name)] = key
    writeText(KKEYS, SEC.formatFleetKeys(keys, SEC.KIOSK_HEADER))
    pcall(peripheral.call, drive, "setDiskLabel", N.kioskId(name))
    pcall(peripheral.call, drive, "ejectDisk")
    print(string.format("kiosk %s added. On its computer: startup role kiosk (navdesk join first if this was a floppy),", name))
    print("then navdesk setup. The running tower answers it within 10 s.")
    return
  end
  print("tower kiosk [list | add <NAME> | drop <NAME> | open | closed]")
  return
end

if cmd == "range" then
  local r = tonumber(args[2])
  if not (r and r >= 200 and r <= 20000) then print("tower range <blocks>   200 to 20000, the radar's outer ring") return end
  local cfg = loadCfg()
  cfg.range = math.floor(r)
  saveCfg(cfg)
  print("radar range " .. cfg.range .. " blocks")
  return
end

if cmd == "centre" or cmd == "center" then
  local sub = (args[2] or "list"):lower()
  if slave then print("this is a display-only centre: centres are added on the master") return end
  -- applications to host a centre, made at the kiosk
  if sub == "apps" or sub == "approve" or sub == "refuse" then
    local apps = N.parseApps(readAll(APPS))
    if sub == "apps" then
      local any = false
      for _, a in ipairs(apps) do
        if a.status == "pending" or args[3] == "all" then
          any = true
          print(string.format("  %3d  %-12s %6d %6d  %-16s %s", a.n, a.name, a.x, a.z, a.who, a.status))
        end
      end
      if not any then print("no applications waiting (tower centre apps all shows every one)") end
      return
    end
    local n = tonumber(args[3])
    local app
    for _, a in ipairs(apps) do if a.n == n then app = a end end
    if not app then print("no application " .. tostring(args[3]) .. " - tower centre apps") return end
    app.status = sub == "approve" and "approved" or "refused"
    writeText(APPS, N.appsText(apps))
    if sub == "approve" then
      print(string.format("approved: %s at %d %d for %s", app.name, app.x, app.z, app.who))
      print(string.format("with the centre's computer (or a floppy) in the drive: tower centre add %s %d <y> %d",
        app.name, app.x, app.z))
    else
      print("refused: " .. app.name)
    end
    return
  end
  if sub == "list" then
    local list = loadCentres()
    local cfg = loadCfg()
    print(string.format("master %s %s", cfg.name, cfg.x and string.format("at %d %d %d", cfg.x, cfg.y or 0, cfg.z)
      or "- position not set: tower here <name> <x> <y> <z>"))
    if #list == 0 then print("no display-only centres - tower centre add <NAME> <x> <y> <z>") end
    local ck = SEC.readFleetKeys(CKEYS)
    for _, c in ipairs(list) do
      print(string.format("  %-12s %d %d %d  %s", c.name, c.x, c.y, c.z,
        ck[N.centreId(c.name)] and "fed" or "NO KEY - tower centre add it again"))
    end
    print("a centre on NO SIGNAL: tower check on its computer says why")
    return
  end
  if sub == "drop" then
    local name = N.validCentre(args[3])
    local list, kept = loadCentres(), {}
    for _, c in ipairs(list) do if c.name ~= name then kept[#kept + 1] = c end end
    if #kept == #list then print("no centre " .. tostring(args[3])) return end
    saveCentres(kept)
    local keys = SEC.readFleetKeys(CKEYS)
    keys[N.centreId(name)] = nil
    writeText(CKEYS, SEC.formatFleetKeys(keys, SEC.CENTRE_HEADER))
    print("dropped " .. name .. " - the master stops feeding it within 10 s")
    return
  end
  if sub == "add" then
    local name = N.validCentre(args[3])
    local x, y, z = tonumber(args[4]), tonumber(args[5]), tonumber(args[6])
    if not (name and x and y and z) then
      print("tower centre add <NAME> <x> <y> <z>   with the centre's computer (or a floppy) in the drive") return
    end
    local cfg = loadCfg()
    if name == cfg.name then print(name .. " is this tower's own name") return end
    local drive
    for _, n in ipairs(peripheral.getNames()) do if peripheral.getType(n) == "drive" then drive = n break end end
    if not (drive and peripheral.call(drive, "hasData")) then
      print("put the centre's computer, or a floppy for it, in the disk drive first") return
    end
    local mount = peripheral.call(drive, "getMountPath")
    local key = SEC.newKey()
    writeText(fs.combine and fs.combine(mount, ME_KEY) or (mount .. "/" .. ME_KEY), SEC.keyHex(key) .. "\n")
    writeText(fs.combine and fs.combine(mount, ME_FILE) or (mount .. "/" .. ME_FILE),
      N.centreFile({ name = name, x = x, y = y, z = z, master = cfg.name }))
    local keys = SEC.readFleetKeys(CKEYS)
    keys[N.centreId(name)] = key
    writeText(CKEYS, SEC.formatFleetKeys(keys, SEC.CENTRE_HEADER))
    local list, kept = loadCentres(), {}
    for _, c in ipairs(list) do if c.name ~= name then kept[#kept + 1] = c end end
    kept[#kept + 1] = { name = name, x = x, y = y, z = z }
    saveCentres(kept)
    pcall(peripheral.call, drive, "setDiskLabel", "tower-" .. name:lower())
    pcall(peripheral.call, drive, "ejectDisk")
    print(string.format("centre %s at %d %d %d added. Put it back, fit an ender modem and monitors, reboot.",
      name, x, y, z))
    print("Not given its role yet: startup role centre. From a floppy: tower join with it in the centre's drive.")
    return
  end
  print("tower centre [list | add <NAME> <x> <y> <z> | drop <NAME>]")
  return
end

if cmd == "join" then
  -- on a display-only centre: take its identity off the floppy the master wrote
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n) == "drive" and peripheral.call(n, "hasData") then
      local mount = peripheral.call(n, "getMountPath")
      local f, k = mount .. "/" .. ME_FILE, mount .. "/" .. ME_KEY
      if fs.exists(f) and fs.exists(k) then
        writeText(ME_FILE, readAll(f))
        writeText(ME_KEY, readAll(k))
        fs.delete(f) fs.delete(k)
        local me = N.parseCentreFile(readAll(ME_FILE))
        print(string.format("this computer is now the %s centre - it shows %s's traffic. Wiped the floppy.",
          me and me.name or "?", me and me.master or "the master's"))
        return
      end
    end
  end
  print("no centre floppy in any drive - on the master: tower centre add <NAME> <x> <y> <z> with it in the drive")
  return
end

if cmd == "check" then
  -- on a centre: listen for 10 seconds and say what is wrong with its signal
  if not slave then
    -- on the master: is CINDER's own fleet coming through from the base?
    local wkey = SEC.readKeyFile(".watchkey")
    local me = os.getComputerLabel and os.getComputerLabel() or nil
    local modemM
    for _, n in ipairs(peripheral.getNames()) do
      if peripheral.getType(n) == "modem" then
        local okW, w = pcall(peripheral.call, n, "isWireless")
        if okW and w then modemM = n end
      end
    end
    print(string.format("master %s - watch key %s - label %s - radio %s", loadCfg().name,
      wkey and "present" or "MISSING", tostring(me), modemM or "NONE"))
    if not modemM then print("no ender modem: put one on this computer") return end
    if not wkey then
      print("no watch key: on the base, seckey watch new tower (a floppy in its drive);")
      print("here, label set tower, then seckey watch set disk") return
    end
    if not (me == "tower" or (me and me:match("^tower%-"))) then
      print("this computer is labelled " .. tostring(me) .. ": the base sends positions only to a watcher")
      print("named tower or tower-<something>. label set tower, and make the key under that name.") return
    end
    pcall(peripheral.call, modemM, "open", N.CINDER_FEED)
    local rxW = SEC.receiver()
    local units, status, stealth, bad, why, others = {}, 0, false, 0, nil, {}
    print("listening for 10 seconds for the base...")
    local timerM = os.startTimer(10)
    while true do
      local e, a, ch, _, msg = os.pullEvent()
      if e == "timer" and a == timerM then break end
      if e == "modem_message" and ch == N.CINDER_FEED and type(msg) == "table" and msg.sl
         and msg.d == SEC.DIR.BASE_TO_WATCH then
        if msg.id == me then
          local body, w = rxW.open(msg, function(id) return id == me and wkey or nil end, SEC.DIR.BASE_TO_WATCH,
            N.MAX_AGE_MS)
          if not body then bad, why = bad + 1, w
          elseif body.type == "cinder.unit" then units[tostring(body.unit)] = true
          elseif body.type == "cinder.status" then status, stealth = status + 1, body.stealth == true end
        else others[tostring(msg.id)] = true end
      end
    end
    local names, other = {}, {}
    for u in pairs(units) do names[#names + 1] = u end
    for id in pairs(others) do other[#other + 1] = id end
    if #names > 0 then
      print("CINDER FEED FINE: " .. #names .. " unit(s) heard - " .. table.concat(names, ", "))
      print("Not on the radar? They may be outside its ring: tower range <blocks>. The board lists them all.")
    elseif bad > 0 then
      print(string.format("the base's messages for %s will not open (%s): the keys differ.", me, tostring(why)))
      print("On the base: seckey watch new " .. me .. " again; here: seckey watch set disk.")
    elseif status > 0 and stealth then
      print("the base is talking, and STEALTH IS ON: on the base, ops stealth off")
    elseif status > 0 then
      print("the base is talking but no drone is reporting to it: are the drones switched on, beacon running?")
    elseif #other > 0 then
      print("the base feeds " .. table.concat(other, ", ") .. " but not " .. me .. ".")
      print("On the base: seckey watch list - make the key for " .. me .. " if it is missing.")
      print("Listed? Reboot the base (an older ops never sees a new key) and look on its board")
      print("for " .. me:upper() .. " FEED FAILED - a full disk cannot start a new feed.")
    else
      print("nothing from the base on channel " .. N.CINDER_FEED .. ". Is ops running on the base, with its chunk")
      print("loaded and an ender modem? An older ops started before the key existed needs restarting.")
    end
    return
  end
  local key = SEC.readKeyFile(ME_KEY)
  local myId = N.centreId(slave.name)
  local modem
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n) == "modem" then
      local okW, w = pcall(peripheral.call, n, "isWireless")
      if okW and w then modem = n end
    end
  end
  print(string.format("centre %s - key %s - radio %s", slave.name, key and "present" or "MISSING", modem or "NONE"))
  if not modem then print("no ender modem: put one on this computer") return end
  if not key then
    print(string.format("no key: with this computer in the master's drive, tower centre add %s %d %d %d",
      slave.name, slave.x, slave.y or 0, slave.z)) return
  end
  pcall(peripheral.call, modem, "open", N.CHANNEL)
  local rxC = SEC.receiver()
  local mine, bad, why, others, other = 0, 0, nil, {}, 0
  print("listening for 10 seconds...")
  local timer = os.startTimer(10)
  while true do
    local e, a, ch, _, msg = os.pullEvent()
    if e == "timer" and a == timer then break end
    if e == "modem_message" and ch == N.CHANNEL and type(msg) == "table" then
      if msg.sl and msg.d == SEC.DIR.TOWER_TO_CENTRE then
        if msg.id == myId then
          local body, w = rxC.open(msg, function(id) return id == myId and key or nil end, SEC.DIR.TOWER_TO_CENTRE,
            N.MAX_AGE_MS)
          if body then mine = mine + 1 else bad, why = bad + 1, w end
        else others[#others + 1] = tostring(msg.id) end
      else other = other + 1 end
    end
  end
  if mine > 0 then
    print(string.format("SIGNAL FINE: %d pictures in 10 s. Still NO SIGNAL on screen? Reboot this computer.", mine))
  elseif bad > 0 then
    print(string.format("pictures for %s arrive but will not open (%s): the keys differ.", slave.name, tostring(why)))
    print("On the master, with this computer in its drive: tower centre add " .. slave.name .. " ... again.")
  elseif #others > 0 then
    print("the master is feeding " .. table.concat(others, ", ") .. " - not " .. myId .. ".")
    print("On the master: tower centre list. Add " .. slave.name .. " if it is missing.")
  elseif other > 0 then
    print(string.format("the radio works (%d other messages) but no pictures at all.", other))
    print("Is the master's tower running? Its chunk must be loaded to send - with nobody at HQ, it is not.")
  else
    print("heard nothing at all. Is this an ENDER modem (a plain wireless one reaches ~64 blocks)?")
    print("Is the master's tower running, with its chunk loaded?")
  end
  return
end

if cmd ~= "run" then
  print("tower [run | register | list | show <reg> | revoke <reg> | log [n] | here <NAME> <x> <y> <z> | range <blocks>")
  print("       | centre [list | add <NAME> <x> <y> <z> | drop <NAME> | apps | approve <n> | refuse <n>] | join | check")
  print("       | kiosk [list | add <NAME> | drop <NAME> | open | closed]")
  return
end

-- -------------------------------------------------------------------- run --
-- An ender modem placed straight on the computer (a wired one cannot reach
-- the units). With none, it waits for one rather than ending: the autorun
-- would only start it again every 3 s (2026-10-01).
local radio
local function findRadio()
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n) == "modem" then
      local okW, wireless = pcall(peripheral.call, n, "isWireless")
      if okW and wireless then return n end
    end
  end
end
radio = findRadio()
if not radio then
  print("no ender modem - the tower cannot hear anyone")
  print("place one on a face of this computer; waiting for it")
  repeat os.pullEvent("peripheral") radio = findRadio() until radio
  print("ender modem on " .. radio)
end
pcall(peripheral.call, radio, "open", N.CHANNEL)

-- ------------------------------------------------------------------ screens --
-- every monitor: the radar on any 3x3 or bigger, the board on the rest; the
-- board on this computer's own screen as well
local D, T, TU = dofile("lib/display.lua"), dofile("lib/tui.lua"), dofile("lib/towerui.lua")
local mons = {}
local function findMonitors()
  for name in pairs(mons) do if not peripheral.isPresent(name) then mons[name] = nil end end
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n) == "monitor" and not mons[n] then
      pcall(peripheral.call, n, "setTextScale", 0.5)
      local setter = { setPaletteColour = function(...) return peripheral.call(n, "setPaletteColour", ...) end }
      T.apply(setter)
      TU.apply(setter)
      mons[n] = {}
    end
  end
end
T.apply(term)
TU.apply(term)
-- A craft touched on a radar gets a ring and a card (Alex, 2026-10-03: "if
-- on a radar a craft is touched, it brings up the stats of it"), for this
-- long or until the screen is touched away from every craft.
local SEL_SECS = 60
local function show(view)
  for name, m in pairs(mons) do
    local okS, w, h = pcall(peripheral.call, name, "getSize")
    if okS and w then
      if not m.canvas or m.canvas.w ~= w or m.canvas.h ~= h then m.canvas = D.canvas(w, h) end
      local c = m.canvas
      c:clear()
      if m.sel and os.clock() - m.selAt > SEL_SECS then m.sel = nil end
      if TU.wantsRadar(w, h) then m.hits = TU.radar(T, c, view, m.sel) else m.hits = nil TU.board(T, c, view) end
      c:flush({ setCursorPos = function(x, y) peripheral.call(name, "setCursorPos", x, y) end,
                blit = function(s, f, b) peripheral.call(name, "blit", s, f, b) end })
    end
  end
  local okT, tw, th = pcall(term.getSize)
  if okT and tw and term.blit then
    local c = D.canvas(tw, th)
    TU.board(T, c, view)
    c:flush(term)
  end
end
findMonitors()
-- a touch on a radar: pick the craft under it, or put the card away.
-- True when the screens should be drawn again now.
local function touched(name, x, y)
  local m = mons[name]
  if not (m and m.hits) then return false end
  local key = TU.pick(m.hits, x, y)
  if key == m.sel then key = nil end                    -- the same one again: put it away
  m.sel, m.selAt = key, os.clock()
  return true
end

-- ------------------------------------------------- a display-only centre --
if slave then
  local key = SEC.readKeyFile(ME_KEY)
  if not key then print("no centre key - on the master: tower centre add, then tower join here") return end
  local myId = N.centreId(slave.name)
  local rx = SEC.receiver()
  local pic, lastPic = { contacts = {}, centres = {} }, nil
  local function view()
    local list = {}
    for _, ct in ipairs(pic.contacts) do ct.reg = N.regOf(ct) list[#list + 1] = ct end
    local fresh = lastPic and os.clock() - lastPic <= N.PIC_PERIOD * 3 + 2
    return { name = slave.name, x = slave.x, z = slave.z, range = loadCfg().range, now = os.clock(),
             contacts = list, centres = pic.centres, feed = fresh and "ok" or "none",
             lastEvent = pic.ev }
  end
  print(string.format("traffic centre %s", slave.name))
  parallel.waitForAny(function()
    while true do
      local _, _, ch, _, msg = os.pullEvent("modem_message")
      if ch == N.CHANNEL and type(msg) == "table" and msg.sl and msg.d == SEC.DIR.TOWER_TO_CENTRE then
        local body = rx.open(msg, function(id) return id == myId and key or nil end, SEC.DIR.TOWER_TO_CENTRE, N.MAX_AGE_MS)
        local p = body and N.parsePicture(body, os.clock())
        if p then pic, lastPic = p, os.clock() end
      end
    end
  end, function()
    local n = 0
    while true do
      show(view())
      n = n + 1
      if n % 10 == 0 then findMonitors() end
      sleep(1)
    end
  end, function()
    while true do
      local _, name, x, y = os.pullEvent("monitor_touch")
      if touched(name, x, y) then show(view()) end
    end
  end)
  return
end

-- ------------------------------------------------------------- the master --
local recs, byUnit, keys = {}, {}, {}
local function adopt(list)
  recs, byUnit = list, {}
  for _, r in ipairs(recs) do byUnit[r.unit] = r end
end
adopt(loadReg())
keys = loadKeys()
local cfg = loadCfg()
local centreKeys = SEC.readFleetKeys(CKEYS)
local centreList = loadCentres()

local contacts, senders, picSenders = {}, {}, {}
local rx = SEC.receiver()
local kioskKeys, kioskSenders = SEC.readFleetKeys(KKEYS), {}
local kiosksOpen = fs.exists(KOPEN)
-- CINDER's own units, from the base's read-only feed: this tower is a public
-- watcher (lib/watch.lua W.isPublic), told where each unit is and nothing
-- while the base is in stealth. `seckey watch new tower` on the base,
-- `seckey watch set disk` here, labelled tower. No key, no CINDER units.
local cinder = { key = SEC.readKeyFile(".watchkey"), me = os.getComputerLabel and os.getComputerLabel(),
                 stealth = false, last = nil }
local NAMES = select(2, pcall(dofile, "lib/names.lua"))
if cinder.key then pcall(peripheral.call, radio, "open", N.CINDER_FEED) end
local dirty = false
local heard = { n = 0, refused = 0 }
local lastEvent = nil

-- every centre a unit should know of: this master first, then the rest
local function allCentres()
  local out = {}
  if cfg.x and cfg.z then out[1] = { name = cfg.name, x = cfg.x, y = cfg.y or 0, z = cfg.z } end
  for _, c in ipairs(centreList) do out[#out + 1] = c end
  return out
end

-- What `tower register`, `revoke`, `here` and `centre` change while this
-- runs is picked up here: the files are the truth for who is registered and
-- where the centres are, this computer's memory for when and where each unit
-- was last heard.
local RUNTIME = { "first", "last", "x", "y", "z", "sid", "sname", "mass" }
-- A sender made with a key that has since changed - a centre or a kiosk
-- added again, a unit given a new key - is dropped, or everything to it
-- would go on being sealed with the old key and refused (2026-10-03: a
-- centre on NO SIGNAL until the master was rebooted).
local function prune(cache, keyTable)
  for id, s in pairs(cache) do if keyTable[id] == nil or keyTable[id] ~= s.madeWith then cache[id] = nil end end
end

local function sync()
  local fileRecs = loadReg()
  for _, r in ipairs(fileRecs) do
    local m = byUnit[r.unit]
    if m then for _, k in ipairs(RUNTIME) do if m[k] ~= nil then r[k] = m[k] end end end
  end
  if dirty then saveReg(fileRecs) dirty = false end
  adopt(fileRecs)
  keys = loadKeys()
  prune(senders, keys)
  cfg = loadCfg()
  kioskKeys = SEC.readFleetKeys(KKEYS)
  kiosksOpen = fs.exists(KOPEN)
  prune(kioskSenders, kioskKeys)
  centreKeys = SEC.readFleetKeys(CKEYS)
  centreList = loadCentres()
  prune(picSenders, centreKeys)
  findMonitors()
end

local function keyFor(id)
  local r = byUnit[id]
  if not r or r.revoked then return nil end
  return keys[id]
end

local function answer(rec, c, m)
  local traffic = N.traffic(contacts, c, os.clock())
  local adv = N.advisory(c, traffic)
  local s = senders[rec.unit]
  if not s then
    s = SEC.sender(keys[rec.unit], rec.unit, SEC.DIR.TOWER_TO_NAV, PONG_CTR)
    s.madeWith = keys[rec.unit]
    senders[rec.unit] = s
  end
  local env = s.seal(N.pong(traffic, adv, { sos = m.st == "sos", centres = allCentres() }))
  if env then pcall(peripheral.call, radio, "transmit", N.CHANNEL, N.CHANNEL, env) end
end

local function hear(msg)
  if type(msg) ~= "table" or not msg.sl or msg.d ~= SEC.DIR.NAV_TO_TOWER then return end
  local body = rx.open(msg, keyFor, SEC.DIR.NAV_TO_TOWER, N.MAX_AGE_MS)
  local m = body and N.checkPing(body)
  if not m then heard.refused = heard.refused + 1 return end
  local rec = byUnit[body.id]
  local c, events = N.track(contacts, rec, m, os.clock())
  heard.n = heard.n + 1
  local now = nowSecs()
  local neverHeard = rec.first == nil
  rec.first = rec.first or now
  rec.last, rec.x, rec.y, rec.z = now, math.floor(m.x + 0.5), math.floor(m.y + 0.5), math.floor(m.z + 0.5)
  if m.sname then rec.sname = m.sname end
  if m.mass then rec.mass = m.mass end
  for _, ev in ipairs(events) do
    -- "first" is first since this tower started; only the very first ever is news
    if ev ~= "first" or neverHeard then
      logEvent(rec, ev, c, ev == "first" and m.sname or nil)
      lastEvent = string.format("%s %s %s", N.regNumber(rec.n), rec.call, ev:upper())
    end
  end
  -- the vehicle as last heard, for reference: a packed craft comes back new
  if m.sid then rec.sid = m.sid end
  dirty = true
  answer(rec, c, m)
end

local function hearCinder(msg)
  if not (cinder.key and type(msg) == "table" and msg.sl and msg.d == SEC.DIR.BASE_TO_WATCH
          and msg.id == cinder.me) then return end
  local body = rx.open(msg, function(id) return id == cinder.me and cinder.key or nil end,
                       SEC.DIR.BASE_TO_WATCH, N.MAX_AGE_MS)
  if not body then return end
  cinder.last = os.clock()
  if body.type == "cinder.status" then
    cinder.stealth = body.stealth == true
    if cinder.stealth then N.dropCinder(contacts) end
  elseif body.type == "cinder.unit" and not cinder.stealth then
    N.cinderContact(contacts, body, type(NAMES) == "table" and NAMES.unit(body.unit) or body.unit, os.clock())
  end
end

-- ------------------------------------------------------------ the kiosks --
-- A registration kiosk's question (navdesk.lua), answered to that kiosk
-- alone. Everything is decided here, from the files: the kiosk only shows it.
local function applyCentre(owner, name, x, z)
  name = N.validCentre(name)
  if not (name and N.validOwner(owner) and tonumber(x) and tonumber(z)) then return nil, "NOT A VALID APPLICATION" end
  local apps = N.parseApps(readAll(APPS))
  for _, a in ipairs(apps) do
    if a.status == "pending" and a.who:lower() == tostring(owner):lower() then
      return nil, "YOU HAVE AN APPLICATION WAITING"
    end
    if a.status ~= "refused" and a.name == name then return nil, "THAT NAME IS TAKEN" end
  end
  if name == cfg.name then return nil, "THAT NAME IS TAKEN" end
  for _, c in ipairs(loadCentres()) do if c.name == name then return nil, "THAT NAME IS TAKEN" end end
  apps[#apps + 1] = { n = #apps + 1, when = nowSecs(), who = owner, name = name, x = math.floor(x), z = math.floor(z),
                      status = "pending" }
  writeText(APPS, N.appsText(apps))
  lastEvent = string.format("CENTRE APPLICATION: %s %s", name, tostring(owner):upper())
  return true
end

local function recAnswer(r)
  return { ok = true, unit = r.unit, n = r.n, reg = N.regNumber(r.n), call = r.call, kind = r.kind, owner = r.owner,
           revoked = r.revoked and true or nil }
end

local function kioskOp(id, b)
  local recs = loadReg()
  local function count(owner)
    local n = 0
    for _, r in ipairs(recs) do if not r.revoked and r.owner:lower() == tostring(owner):lower() then n = n + 1 end end
    return n
  end
  if b.op == "info" then
    return { ok = true, count = count(b.owner), nextReg = N.regNumber(N.nextNumber(recs)) }
  elseif b.op == "find" then
    local r = N.find(recs, b.unit)
    if not r then return { ok = false, why = "NOT REGISTERED" } end
    return recAnswer(r)
  elseif b.op == "callFree" then
    local c, why = N.callFree(recs, b.call, b.except)
    return { ok = c ~= nil, call = c, why = why }
  elseif b.op == "register" then
    if not (N.validOwner(b.owner) and N.TYPES[b.kind]) then return { ok = false, why = "NOT A VALID REGISTRATION" } end
    if count(b.owner) >= N.KIOSK_MAX then
      return { ok = false, why = "YOU HAVE " .. N.KIOSK_MAX .. " UNITS REGISTERED" }
    end
    local call, why = N.callFree(recs, b.call)
    if not call then return { ok = false, why = why } end
    local rec, key = fileUnit(b.owner, "seat", b.kind, call, id)
    local a = recAnswer(rec)
    a.key = SEC.keyHex(key)
    return a
  elseif b.op == "written" then
    local r = N.find(recs, b.unit)
    if r and b.ok then
      logEvent(r, "registered", nil, r.owner .. " " .. r.kind .. " seat " .. id)
      lastEvent = string.format("%s %s REGISTERED AT %s", N.regNumber(r.n), r.call, id:upper())
    elseif r then
      unfileUnit(r.unit)
    end
    return { ok = true }
  elseif b.op == "refresh" then
    local r, why = refreshUnit(nil, b.unit, b.kind, b.call, b.owner)
    if not r then return { ok = false, why = why } end
    return recAnswer(r)
  elseif b.op == "apply" then
    local ok, why = applyCentre(b.owner, b.name, b.x, b.z)
    return { ok = ok == true, why = why }
  elseif b.op == "status" then
    local st, lines = {}, {}
    for kid, stock, t in (readAll(KSTATUS) or ""):gmatch("([%w%-]+)=(%-?%d+),(%d+)") do st[kid] = stock .. "," .. t end
    st[id] = math.floor(tonumber(b.stock) or -1) .. "," .. nowSecs()
    for kid, v in pairs(st) do lines[#lines + 1] = kid .. "=" .. v end
    table.sort(lines)
    writeText(KSTATUS, table.concat(lines, "\n") .. "\n")
    if tonumber(b.stock) == 0 then lastEvent = id:upper() .. " IS OUT OF KITS" end
    return { ok = true }
  end
  return { ok = false, why = "UNKNOWN REQUEST" }
end

local function hearKiosk(msg)
  if type(msg) ~= "table" then return end
  -- open: a plain question from a kiosk with no key, answered in the clear
  if not msg.sl then
    local name = kiosksOpen and msg.type == "kq" and N.validCentre(msg.kiosk)
    if not name then return end
    local id = N.kioskId(name)
    local a = kioskOp(id, msg)
    a.type, a.re, a.to = "ka", msg.q, id
    pcall(peripheral.call, radio, "transmit", N.CHANNEL, N.CHANNEL, a)
    return
  end
  if msg.d ~= SEC.DIR.KIOSK_TO_TOWER then return end
  local body = rx.open(msg, function(id) return kioskKeys[id] end, SEC.DIR.KIOSK_TO_TOWER, N.MAX_AGE_MS)
  if not (body and body.type == "kq" and type(body.id) == "string") then return end
  local id = body.id
  local a = kioskOp(id, body)
  a.type, a.re = "ka", body.q
  local s = kioskSenders[id]
  if not s then
    s = SEC.sender(kioskKeys[id], id, SEC.DIR.TOWER_TO_KIOSK, KIOSK_CTR)
    s.madeWith = kioskKeys[id]
    kioskSenders[id] = s
  end
  local env = s.seal(a)
  if env then pcall(peripheral.call, radio, "transmit", N.CHANNEL, N.CHANNEL, env) end
end

-- the picture every display-only centre is sent
local function feedCentres()
  local list = allCentres()
  for _, c in ipairs(centreList) do
    local id = N.centreId(c.name)
    local key = centreKeys[id]
    if key then
      local s = picSenders[id]
      if not s then
        s = SEC.sender(key, id, SEC.DIR.TOWER_TO_CENTRE, PIC_CTR)
        s.madeWith = key
        picSenders[id] = s
      end
      local env = s.seal(N.picture(contacts, list, os.clock(), lastEvent))
      if env then pcall(peripheral.call, radio, "transmit", N.CHANNEL, N.CHANNEL, env) end
    end
  end
end

local function view()
  local list = {}
  for _, ct in pairs(contacts) do ct.reg = N.regOf(ct) list[#list + 1] = ct end
  local cinderState = cinder.key and (cinder.stealth and "stealth"
    or ((cinder.last and os.clock() - cinder.last <= 10) and "ok" or "none")) or nil
  return { name = cfg.name, x = cfg.x, z = cfg.z, range = cfg.range, now = os.clock(), contacts = list,
           centres = allCentres(), regs = #recs, lastEvent = lastEvent, refused = heard.refused,
           cinder = cinderState }
end

local function radioLoop()
  while true do
    local _, _, ch, _, msg = os.pullEvent("modem_message")
    if ch == N.CHANNEL then
      if type(msg) == "table" and (msg.d == SEC.DIR.KIOSK_TO_TOWER or msg.type == "kq") then hearKiosk(msg)
      else hear(msg) end
    elseif ch == N.CINDER_FEED then hearCinder(msg) end
  end
end
local function syncLoop()
  while true do
    sleep(10)
    sync()
  end
end
local function screenLoop()
  while true do
    N.dropCinder(contacts, os.clock())     -- the base gone quiet: off the picture
    show(view())
    sleep(1)
  end
end
local function feedLoop()
  while true do
    feedCentres()
    sleep(N.PIC_PERIOD)
  end
end
local function touchLoop()
  while true do
    local _, name, x, y = os.pullEvent("monitor_touch")
    if touched(name, x, y) then show(view()) end
  end
end

print(string.format("tower %s: %d registered, %d centres fed, listening on %d", cfg.name, #recs, #centreList, N.CHANNEL))
parallel.waitForAny(radioLoop, syncLoop, screenLoop, feedLoop, touchLoop)
