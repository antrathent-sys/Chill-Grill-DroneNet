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
  return string.format("%s  %-16s %-12s %s (%s)", N.regNumber(rec.n), rec.call, N.TYPES[rec.kind].word,
    rec.owner, status)
end

if slave and (cmd == "register" or cmd == "list" or cmd == "show" or cmd == "revoke" or cmd == "log") then
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
        local ok, why = N.install(fs, mount, { rec = rec, src = "", version = readAll(".commit") })
        print(ok and ("updated " .. N.regNumber(rec.n)) or ("could not: " .. tostring(why)))
        if ok then logEvent(rec, "updated") end
      end
      eject() return
    end
    print("a unit this tower does not know, or one that was revoked - it can be registered afresh")
  end
  if info.kind == "other" or info.kind == "unit" then
    print("it has files on it: " .. table.concat(info.files or {}, " "):sub(1, 120))
    if not yes("wipe them and make it a CINDER NAV unit?") then eject() return end
  end

  local owner
  for _ = 1, 3 do
    owner = ask("owner's player name:")
    if N.validOwner(owner) then break end
    print("a player name is 3 to 16 letters, digits or _")
    owner = nil
  end
  if not owner then eject() return end
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
    call = N.validCall(ask("callsign - what traffic calls it (2-16 letters, digits, - or space):"))
    if call then break end
    print("2 to 16 letters, digits, spaces or dashes")
  end
  if not call then eject() return end

  local n = N.nextNumber(recs)
  local rec = { n = n, unit = N.unitId(n), owner = owner, call = call, kind = kind,
                issued = today(), by = os.getComputerLabel and os.getComputerLabel() or nil }
  local key = SEC.newKey()
  local ok, why = N.install(fs, mount, { rec = rec, keyHex = SEC.keyHex(key), src = "", version = readAll(".commit") })
  if not ok then print("could not: " .. tostring(why)) eject() return end
  keys[rec.unit] = key
  saveKeys(keys)
  recs[#recs + 1] = rec
  saveReg(recs)
  pcall(peripheral.call, drive, "setDiskLabel", rec.unit)
  logEvent(rec, "registered", nil, owner .. " " .. kind)
  print(string.format("REGISTERED %s  %s  %s  for %s", N.regNumber(n), call, N.TYPES[kind].word, owner))
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
  if sub == "list" then
    local list = loadCentres()
    local cfg = loadCfg()
    print(string.format("master %s %s", cfg.name, cfg.x and string.format("at %d %d %d", cfg.x, cfg.y or 0, cfg.z)
      or "- position not set: tower here <name> <x> <y> <z>"))
    if #list == 0 then print("no display-only centres - tower centre add <NAME> <x> <y> <z>") end
    for _, c in ipairs(list) do print(string.format("  %-12s %d %d %d", c.name, c.x, c.y, c.z)) end
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
    print(string.format("centre %s at %d %d %d added. On its computer: startup role tower, and if this was a floppy,",
      name, x, y, z))
    print("tower join with the floppy in its drive. It shows what this master hears; it answers no one.")
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

if cmd ~= "run" then
  print("tower [run | register | list | show <reg> | revoke <reg> | log [n] | here <NAME> <x> <y> <z> | range <blocks>")
  print("       | centre [list | add <NAME> <x> <y> <z> | drop <NAME>] | join]")
  return
end

-- -------------------------------------------------------------------- run --
local radio
for _, n in ipairs(peripheral.getNames()) do
  if peripheral.getType(n) == "modem" then
    local okW, wireless = pcall(peripheral.call, n, "isWireless")
    if okW and wireless then radio = n break end
  end
end
if not radio then print("no ender modem - the tower cannot hear anyone") return end
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
      T.apply({ setPaletteColour = function(...) return peripheral.call(n, "setPaletteColour", ...) end })
      mons[n] = {}
    end
  end
end
T.apply(term)
local function show(view)
  for name, m in pairs(mons) do
    local okS, w, h = pcall(peripheral.call, name, "getSize")
    if okS and w then
      if not m.canvas or m.canvas.w ~= w or m.canvas.h ~= h then m.canvas = D.canvas(w, h) end
      local c = m.canvas
      c:clear()
      if TU.wantsRadar(w, h) then TU.radar(T, c, view) else TU.board(T, c, view) end
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

-- ------------------------------------------------- a display-only centre --
if slave then
  local key = SEC.readKeyFile(ME_KEY)
  if not key then print("no centre key - on the master: tower centre add, then tower join here") return end
  local myId = N.centreId(slave.name)
  local rx = SEC.receiver()
  local pic, lastPic = { contacts = {}, centres = {} }, nil
  local function view()
    local list = {}
    for _, ct in ipairs(pic.contacts) do ct.reg = N.regNumber(ct.n) list[#list + 1] = ct end
    local fresh = lastPic and os.clock() - lastPic <= N.PIC_PERIOD * 3 + 2
    return { name = slave.name, x = slave.x, z = slave.z, range = loadCfg().range, now = os.clock(),
             contacts = list, centres = pic.centres, feed = fresh and "ok" or "none",
             lastEvent = string.format("%s CENTRE  FED BY %s", slave.name, slave.master or "THE MASTER") }
  end
  print(string.format("centre %s: showing %s's traffic", slave.name, slave.master or "the master's"))
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
local function sync()
  local fileRecs = loadReg()
  for _, r in ipairs(fileRecs) do
    local m = byUnit[r.unit]
    if m then for _, k in ipairs(RUNTIME) do if m[k] ~= nil then r[k] = m[k] end end end
  end
  if dirty then saveReg(fileRecs) dirty = false end
  adopt(fileRecs)
  keys = loadKeys()
  for unit in pairs(senders) do if not keys[unit] then senders[unit] = nil end end
  cfg = loadCfg()
  centreKeys = SEC.readFleetKeys(CKEYS)
  centreList = loadCentres()
  for id in pairs(picSenders) do if not centreKeys[id] then picSenders[id] = nil end end
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
        picSenders[id] = s
      end
      local env = s.seal(N.picture(contacts, list, os.clock()))
      if env then pcall(peripheral.call, radio, "transmit", N.CHANNEL, N.CHANNEL, env) end
    end
  end
end

local function view()
  local list = {}
  for _, ct in pairs(contacts) do ct.reg = N.regNumber(ct.n) list[#list + 1] = ct end
  return { name = cfg.name, x = cfg.x, z = cfg.z, range = cfg.range, now = os.clock(), contacts = list,
           centres = allCentres(), regs = #recs, lastEvent = lastEvent, refused = heard.refused }
end

local function radioLoop()
  while true do
    local _, _, ch, _, msg = os.pullEvent("modem_message")
    if ch == N.CHANNEL then hear(msg) end
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

print(string.format("tower %s: %d registered, %d centres fed, listening on %d", cfg.name, #recs, #centreList, N.CHANNEL))
parallel.waitForAny(radioLoop, syncLoop, screenLoop, feedLoop)
