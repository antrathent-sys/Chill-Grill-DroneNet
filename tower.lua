-- tower: the CINDER traffic tower (AVIONICS.md). A computer of its own at
-- CHI with an ender modem, a disk drive and a monitor. It registers CINDER
-- NAV units, hears every registered unit's ping, answers each with the
-- traffic near it, and keeps the registry and the log.
--
--   tower                  run: hear, answer, keep the board (startup autorun tower)
--   tower register         register a unit: put its computer in the disk drive
--   tower list             every registration
--   tower show <reg|unit>  one registration and when it was last heard
--   tower revoke <reg|unit>  forget its key: it can no longer speak to the tower
--   tower log [n]          the last n events (default 20)
--
-- It holds every unit's key (.navkeys) and NEVER a fleet key: it is the
-- public face, and nothing on it can fly a CINDER unit. What it sends a unit
-- is information only.
--
--   .navkeys     unit id -> key, one line each (seckey's format)
--   navreg.lua   the registry: one record per unit (lib/nav.lua)
--   navlog.csv   one line per event: registered, first heard, departed,
--                arrived, distress, changed vehicle, revoked
--   .pong.ctr    the counter every pong is sealed under

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

local function describe(rec)
  local status = rec.revoked and ("REVOKED " .. rec.revoked) or (rec.last and "registered" or "registered, never heard")
  return string.format("%s  %-16s %-12s %s (%s)", N.regNumber(rec.n), rec.call, N.TYPES[rec.kind].word,
    rec.owner, status)
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

if cmd ~= "run" then
  print("tower [run | register | list | show <reg> | revoke <reg> | log [n]]")
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

local recs, byUnit, keys = {}, {}, {}
local function adopt(list)
  recs, byUnit = list, {}
  for _, r in ipairs(recs) do byUnit[r.unit] = r end
end
adopt(loadReg())
keys = loadKeys()

local contacts, senders = {}, {}
local rx = SEC.receiver()
local dirty = false
local heard = { n = 0, refused = 0 }
local lastEvent = nil

-- What `tower register` and `tower revoke` change while this runs is picked
-- up here: the file's records are the truth for who is registered, this
-- computer's for when and where each was last heard.
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
  local env = s.seal(N.pong(traffic, adv, { sos = m.st == "sos" }))
  if env then pcall(peripheral.call, radio, "transmit", N.CHANNEL, N.CHANNEL, env) end
end

local function hear(msg)
  if type(msg) ~= "table" or not msg.sl or msg.d ~= SEC.DIR.NAV_TO_TOWER then return end
  local body, why = rx.open(msg, keyFor, SEC.DIR.NAV_TO_TOWER, N.MAX_AGE_MS)
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
    local detail = nil
    if ev == "craft" then detail = tostring(rec.sid) .. " -> " .. tostring(m.sid) end
    -- "first" is first since this tower started; only the very first ever is news
    if ev ~= "first" or neverHeard then
      logEvent(rec, ev, c, detail)
      lastEvent = string.format("%s %s %s", N.regNumber(rec.n), rec.call, ev:upper())
    end
  end
  if m.sid and m.sid ~= rec.sid then
    if not rec.sid then logEvent(rec, "bound", c, m.sid) end
    rec.sid = m.sid
  end
  dirty = true
  answer(rec, c, m)
end

-- ------------------------------------------------------------------ board --
local D, T = dofile("lib/display.lua"), dofile("lib/tui.lua")
local mon
for _, n in ipairs(peripheral.getNames()) do
  if peripheral.getType(n) == "monitor" then mon = n break end
end
if mon then
  pcall(peripheral.call, mon, "setTextScale", 0.5)
  T.apply({ setPaletteColour = function(...) return peripheral.call(mon, "setPaletteColour", ...) end })
end
T.apply(term)

local function board()
  local target
  if mon then
    target = { setCursorPos = function(x, y) peripheral.call(mon, "setCursorPos", x, y) end,
               blit = function(s, f, b) peripheral.call(mon, "blit", s, f, b) end,
               getSize = function() return peripheral.call(mon, "getSize") end }
  else
    target = term
  end
  local okS, w, h = pcall(target.getSize)
  if not (okS and w) then return end
  local c = D.canvas(w, h)
  c:fill(1, 1, w, h, T.C.ground)
  local now = os.clock()
  local live = 0
  for _, ct in pairs(contacts) do if now - ct.t <= N.STALE then live = live + 1 end end
  T.band(c, 1, "CINDER TRAFFIC", string.format("%d HEARD  %d REG", live, #recs), T.C.text, T.C.faint)
  c:text(2, 3, string.format("%-8s %-16s %-4s %-5s %5s %6s %6s", "REG", "CALLSIGN", "TYPE", "STATE", "SPD", "ALT",
    "HEARD"), T.C.faint)
  local list = {}
  for _, ct in pairs(contacts) do list[#list + 1] = ct end
  table.sort(list, function(a, b)
    local sa, sb = a.st == "sos" and 0 or 1, b.st == "sos" and 0 or 1
    if sa ~= sb then return sa < sb end
    return a.n < b.n
  end)
  for i, ct in ipairs(list) do
    local y = 3 + i
    if y >= h - 1 then break end
    local age = math.floor(now - ct.t)
    local stale = age > N.STALE
    local row = string.format("%-8s %-16s %-4s %-5s %5d %6d %5ds", N.regNumber(ct.n), ct.call:sub(1, 16),
      N.TYPES[ct.kind].short, stale and "LOST" or ct.st:upper(), math.floor(ct.spd + 0.5), math.floor(ct.y + 0.5), age)
    if ct.st == "sos" and not stale then
      c:text(1, y, string.rep(" ", w), T.C.text, T.C.accent)
      c:text(2, y, row:sub(1, w - 2), T.C.text, T.C.accent)
    else
      c:text(2, y, row:sub(1, w - 2), stale and T.C.faint or T.C.text)
    end
  end
  if #list == 0 then c:text(2, 5, "NOTHING HEARD YET", T.C.faint) end
  T.band(c, h, lastEvent or "LISTENING", heard.refused > 0 and (heard.refused .. " REFUSED") or nil)
  c:flush(target)
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
local function boardLoop()
  while true do
    board()
    sleep(1)
  end
end

print(string.format("tower: %d registered, listening on %d", #recs, N.CHANNEL))
parallel.waitForAny(radioLoop, syncLoop, boardLoop)
