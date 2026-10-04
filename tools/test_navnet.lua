-- Desktop tests for CINDER NAV end to end: tower.lua registering a unit
-- through its disk drive, tower.lua hearing pings and answering with traffic,
-- and nav.lua on a vehicle - Sable, a monitor and an ender modem stood in for.
-- Everything on the radio is really sealed (lib/seclink.lua).
local DIR = ...
local pass, fail = 0, 0
local function check(n, c, d)
  if c then pass = pass + 1 print("  ok   " .. n)
  else fail = fail + 1 print("  FAIL " .. n .. (d and ("  " .. tostring(d)) or "")) end
end

dofile(DIR .. "/cc_shim.lua")
local S = dofile(DIR .. "/../lib/seclink.lua")
S.ROOT = DIR .. "/../"
local N = dofile(DIR .. "/../lib/nav.lua")
local W = dofile(DIR .. "/cc_world.lua")
local HEX1 = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
local HEX2 = "202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f"
local HEX3 = "404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f"
local KEY1, KEY2, KEY3 = S.parseKey(HEX1), S.parseKey(HEX2), S.parseKey(HEX3)

local function readRepo(p)
  local f = assert(io.open(DIR .. "/../" .. p, "rb"), "missing " .. p)
  local s = f:read("*a")
  f:close()
  return s
end

-- CC's fs as the tower sees it: directories, list, copy
local function withFs(w)
  local F = w.env.fs
  local function under(p, k) return k == p or k:sub(1, #p + 1) == p .. "/" end
  F.exists = function(p)
    if w.files[p] then return true end
    for k in pairs(w.files) do if under(p, k) then return true end end
    return false
  end
  F.list = function(p)
    local seen, out = {}, {}
    for k in pairs(w.files) do
      local rest = (p == "" or p == nil) and k or (k:sub(1, #p + 1) == p .. "/" and k:sub(#p + 2) or nil)
      local top = rest and rest:match("^[^/]+")
      if top and not seen[top] then seen[top] = true out[#out + 1] = top end
    end
    return out
  end
  F.delete = function(p) for k in pairs(w.files) do if under(p, k) then w.files[k] = nil end end end
  F.getDir = function(p) return p:match("^(.*)/[^/]+$") or "" end
  F.makeDir = function() end
  F.copy = function(a, b) w.files[b] = assert(w.files[a], "no " .. a) end
  F.getSize = function(p) return #(w.files[p] or "") end
  return w
end

local function radio(w, name, sent)
  w.periph[name] = { type = "modem", m = {
    isWireless = function() return true end, open = function() end,
    transmit = function(ch, _, env) sent[#sent + 1] = { t = w.clock, ch = ch, env = env } end } }
end

local function rec(n, call, kind, owner)
  return { n = n, unit = N.unitId(n), owner = owner or "alex_r", call = call, kind = kind or "air", issued = "2026-10-01" }
end

-- ======================================================================
print("registering a unit")
local function towerWorld(lines, seat)
  local w = withFs(W.new(DIR, { label = "tower", S = S, lines = lines }))
  -- seat: what the CC:C Bridge target block reads (a string, or a function of
  -- the clock); nil = no seat fitted
  if seat then
    w.periph.create_target_0 = { type = "create_target", m = {
      getLine = function() return type(seat) == "function" and seat(w) or seat end } }
  end
  for _, f in ipairs(N.FILES) do w.files[f] = readRepo(f) end
  w.files["startup.lua"] = readRepo("startup.lua")
  w.ejected, w.labelled = 0, nil
  w.periph.drive_0 = { type = "drive", m = {
    hasData = function() return true end, getMountPath = function() return "disk" end,
    ejectDisk = function() w.ejected = w.ejected + 1 end,
    setDiskLabel = function(l) w.labelled = l end } }
  return w
end
local realNewKey = S.newKey
S.newKey = function() return KEY3 end
local w = towerWorld({ "alex_r", "boat", "sea wolf" }):run("tower.lua", { "register" }, 30)
S.newKey = realNewKey
local recs = N.loadRegistry(w.files["navreg.lua"] or "")
check("registered: a record, a key, a log line", w.err == nil and #recs == 1 and recs[1].unit == "nav-0001"
  and recs[1].kind == "sea" and recs[1].call == "SEA WOLF" and recs[1].owner == "alex_r"
  and (w.files[".navkeys"] or ""):find("nav-0001=" .. HEX3, 1, true)
  and (w.files["navlog.csv"] or ""):find(",CR-0001,nav-0001,SEA WOLF,registered,", 1, true), w.err or w.text)
check("the unit has its software, key and identity, and the updater as its startup, role nav", w.files["disk/nav.lua"]
  and w.files["disk/.navkey"] == HEX3 .. "\n" and w.files["disk/startup.lua"] == readRepo("startup.lua")
  and w.files["disk/.role"] == "nav\n" and w.files["disk/.autorun"] == "nav\n"
  and N.parseUnitFile(w.files["disk/.nav"]).unit == "nav-0001")
check("labelled, ejected, and told what to fit", w.labelled == "nav-0001" and w.ejected == 1
  and w.text:find("REGISTERED CR-0001  SEA WOLF  VESSEL  for alex_r", 1, true), w.text)

-- the same unit back in the drive: an update, keeping its key
local w2 = towerWorld({ "y" })
for k, v in pairs(w.files) do if k:sub(1, 5) == "disk/" or k == "navreg.lua" or k == ".navkeys" then w2.files[k] = v end end
w2.files["disk/nav.lua"] = "-- old"
w2 = w2:run("tower.lua", { "register" }, 30)
check("brought back: updated, same key, same registration", w2.files["disk/nav.lua"] == readRepo("nav.lua")
  and w2.files["disk/.navkey"] == HEX3 .. "\n" and #N.loadRegistry(w2.files["navreg.lua"]) == 1
  and w2.text:find("updated CR-0001", 1, true), w2.text)

local w3 = towerWorld({})
w3.files["disk/.fleetkeys"] = "drone-1=" .. HEX1
w3 = w3:run("tower.lua", { "register" }, 10)
check("one of CINDER's own machines is refused untouched", w3.files["disk/.fleetkeys"] and not w3.files["disk/nav.lua"]
  and w3.text:find("not touching it", 1, true), w3.text)
local w4 = towerWorld({})
w4.files["disk/.pass"] = "sam\n"
w4 = w4:run("tower.lua", { "register" }, 10)
check("a customer's pass is refused", not w4.files["disk/nav.lua"] and w4.text:find("customer's pass", 1, true), w4.text)
local w5 = towerWorld({ "x y", "zz", "zz", "zz" }):run("tower.lua", { "register" }, 10)
check("a bad name three times: nothing registered", not w5.files["navreg.lua"] and not w5.files["disk/nav.lua"], w5.text)
check("with no seat the name is typed, and the record says so", recs[1].idby == "typed"
  and w.text:find("not checked", 1, true), w.text)

print("the owner, off the seat")
S.newKey = function() return KEY3 end
local ws = towerWorld({ "y", "boat", "sea wolf" }, "alex_r"):run("tower.lua", { "register" }, 30)
local rs = N.loadRegistry(ws.files["navreg.lua"] or "")
check("whoever sits in the seat is the owner - no name to type", rs[1] and rs[1].owner == "alex_r"
  and rs[1].idby == "seat" and not ws.text:find("owner's player name", 1, true), ws.err or ws.text)
check("the registrar confirms it", ws.text:find("owner alex_r (in the seat) - right?", 1, true) ~= nil)
local wl = towerWorld({ "y", "air", "late one" }, function(w) return w.clock > 5 and "sam_k" or "" end)
  :run("tower.lua", { "register" }, 30)
local rl = N.loadRegistry(wl.files["navreg.lua"] or "")
check("an empty seat: it waits for the owner to sit down", rl[1] and rl[1].owner == "sam_k"
  and wl.text:find("sits in the seat now", 1, true), wl.err or wl.text)
local wn = towerWorld({}, "Iron Golem"):run("tower.lua", { "register" }, 90)
check("something that is no player name: it waits, then gives up", not wn.files["navreg.lua"]
  and wn.text:find("nobody in the seat", 1, true), wn.text)
local wr = towerWorld({ "n" }, "Pig"):run("tower.lua", { "register" }, 30)
check("a pig reads as a name - the registrar says no: nothing registered", not wr.files["navreg.lua"]
  and not wr.files["disk/nav.lua"] and wr.text:find("owner Pig", 1, true), wr.text)
S.newKey = realNewKey

-- ======================================================================
print("the tower answering")
local function runningTower(extra)
  local tw = withFs(W.new(DIR, { label = "tower", S = S }))
  tw.files[".navkeys"] = S.formatFleetKeys({ ["nav-0001"] = KEY1, ["nav-0002"] = KEY2 }, S.NAV_HEADER)
  tw.files["navreg.lua"] = N.serialise({ N.checkRecord(rec(1, "FALCON")), N.checkRecord(rec(2, "HAWK", "air", "sam")) })
  tw.sent = {}
  radio(tw, "modem_0", tw.sent)
  if extra then extra(tw) end
  return tw
end
local tx1 = S.sender(KEY1, "nav-0001", S.DIR.NAV_TO_TOWER, nil)
local tx2 = S.sender(KEY2, "nav-0002", S.DIR.NAV_TO_TOWER, nil)
local txBad = S.sender(KEY3, "nav-0009", S.DIR.NAV_TO_TOWER, nil)
local function pingAt(tw, t, tx, r, st, craft)
  tw.at(t, function() return { "modem_message", "modem_0", N.CHANNEL, N.CHANNEL, tx.seal(N.ping(r, st, craft)) } end)
end
-- a touch on the tower's radar: the craft's card
local rowsR, cyR = {}, 1
local twT = runningTower(function(w)
  w.files["tower.cfg"] = "name=CHI\nrange=2000\nx=0\ny=70\nz=0\n"
  w.periph.monitor_5 = { type = "monitor", m = { isColour = function() return true end,
    setTextScale = function() end, getSize = function() return 57, 38 end, setPaletteColour = function() end,
    setCursorPos = function(_, y) cyR = y end, blit = function(s) rowsR[cyR] = s:gsub("[\128-\255]", " ") end } }
end)
local function radarText() local t = {} for y = 1, 38 do t[y] = rowsR[y] or "" end return table.concat(t, "\n") end
pingAt(twT, 1, tx1, N.reading({ x = 0, y = 100, z = 0 }, { x = 20, y = 0, z = 0 }), nil, { id = "u", name = "F", mass = 1500 })
local seenR = {}
twT.at(2.5, function() seenR.before = radarText() return { "noop" } end)
twT.at(3, { "monitor_touch", "monitor_5", 29, 19 })
twT.at(3.2, function() seenR.card = radarText() return { "noop" } end)
twT.at(4, { "monitor_touch", "monitor_5", 29, 19 })
twT.at(4.2, function() seenR.again = radarText() return { "noop" } end)
twT = twT:run("tower.lua", {}, 5)
check("the tower's radar: no card until a craft is touched", not (seenR.before or ""):find("SPEED", 1, true), twT.err or seenR.before)
check("...touching it brings up its card, with its owner", (seenR.card or ""):find("CR-0001  FALCON", 1, true)
  and (seenR.card or ""):find("OWNER  ALEX_R", 1, true)
  and (seenR.card or ""):find("20 B/S", 1, true) and (seenR.card or ""):find("WT M", 1, true), seenR.card)
check("...and touching it again puts the card away", not (seenR.again or ""):find("CR-0001  FALCON", 1, true), seenR.again)

local tw = runningTower()
local headOn1 = N.reading({ x = 0, y = 100, z = 0 }, { x = 20, y = 0, z = 0 })
local headOn2 = N.reading({ x = 300, y = 102, z = 0 }, { x = -20, y = 0, z = 0 })
pingAt(tw, 1, tx2, headOn2, nil, { id = "uuid-hawk", name = "Hawk", mass = 900 })
pingAt(tw, 2, tx1, headOn1, nil, { id = "uuid-falcon", name = "Falcon", mass = 1500 })
pingAt(tw, 3, txBad, headOn1)
local replay
tw.at(4, function()
  replay = tx1.seal(N.ping(headOn1))
  return { "modem_message", "modem_0", N.CHANNEL, N.CHANNEL, replay }
end)
tw.at(4.5, function() return { "modem_message", "modem_0", N.CHANNEL, N.CHANNEL, replay } end)
pingAt(tw, 6, tx1, headOn1, "sos")
tw = tw:run("tower.lua", {}, 24)
local rxU = S.receiver()
local pongs = {}
for _, s in ipairs(tw.sent) do
  local key = s.env and (s.env.id == "nav-0001" and KEY1 or s.env.id == "nav-0002" and KEY2 or nil)
  local body = key and rxU.open(s.env, function() return key end, S.DIR.TOWER_TO_NAV, nil)
  if body then pongs[#pongs + 1] = { id = s.env.id, p = N.parsePong(body), t = s.t } end
end
check("every good ping answered, the stranger and the replay not", tw.err == nil and #pongs == 4, #pongs .. " " .. tostring(tw.err))
local toFalcon = pongs[2]
check("Falcon is told about Hawk, head on, with an advisory", toFalcon and toFalcon.id == "nav-0001"
  and #toFalcon.p.traffic == 1 and toFalcon.p.traffic[1].call == "HAWK" and toFalcon.p.traffic[1].warn
  and toFalcon.p.adv == "TRAFFIC 12 O'CLOCK 300 SAME LEVEL", toFalcon and toFalcon.p.adv)
check("a distress ping is acknowledged", pongs[4] and pongs[4].p.sos)
check("the board shows the refused", tw.text ~= nil)
local after = N.loadRegistry(tw.files["navreg.lua"])
check("the registry learns where each was heard and on what vehicle", after[1].sid == "uuid-falcon"
  and after[1].sname == "Falcon" and after[1].mass == 1500 and after[1].x == 0 and after[1].y == 100
  and after[2].sid == "uuid-hawk" and after[1].last ~= nil, N.serialise(after))
local log = tw.files["navlog.csv"] or ""
check("the log: first contact with the vehicle's name, then distress", log:find(",nav-0001,FALCON,first,0,100,0,Falcon", 1, true)
  and log:find(",nav-0001,FALCON,sos,", 1, true) and not log:find("bound", 1, true), log)

-- CINDER's own units, from the base's read-only feed, and stealth
local WKEY = S.parseKey(HEX3)
local base = S.sender(WKEY, "tower", S.DIR.BASE_TO_WATCH, nil)
local function fromBase(tw, t, body)
  tw.at(t, function() return { "modem_message", "modem_0", N.CINDER_FEED, N.CINDER_FEED, base.seal(body) } end)
end
-- tower check on the master: is CINDER's fleet coming through?
local function masterCheck(setup, feedFn)
  local w = runningTower(function(t) t.files[".watchkey"] = HEX3 .. "\n" if setup then setup(t) end end)
  if feedFn then feedFn(w) end
  return w:run("tower.lua", { "check" }, 12)
end
local mOk = masterCheck(nil, function(w)
  fromBase(w, 1, { type = "cinder.status", stealth = false })
  fromBase(w, 2, { type = "cinder.unit", unit = "drone-1", x = 300, y = 100, z = 0, spd = 0 })
end)
check("tower check on the master: drones coming through", mOk.text:find("CINDER FEED FINE: 1 unit", 1, true)
  and mOk.text:find("drone-1", 1, true), mOk.err or mOk.text)
local mStealth = masterCheck(nil, function(w) fromBase(w, 1, { type = "cinder.status", stealth = true }) end)
check("...stealth on: says so", mStealth.text:find("STEALTH IS ON", 1, true), mStealth.err or mStealth.text)
local mQuiet = masterCheck(nil, function(w) fromBase(w, 1, { type = "cinder.status", stealth = false }) end)
check("...the base talking but no drone reporting", mQuiet.text:find("no drone is reporting", 1, true), mQuiet.err or mQuiet.text)
local mNoKey = masterCheck(function(t) t.files[".watchkey"] = nil end)
check("...no watch key: how to make one", mNoKey.text:find("no watch key", 1, true)
  and mNoKey.text:find("seckey watch new tower", 1, true), mNoKey.err or mNoKey.text)
local mLabel = masterCheck(function(t) t.env.os.getComputerLabel = function() return "chi-master" end end)
check("...a label the base will not send positions to", mLabel.text:find("labelled chi-master", 1, true), mLabel.err or mLabel.text)
local otherBase = S.sender(WKEY, "screens", S.DIR.BASE_TO_WATCH, nil)
local mOther = masterCheck(nil, function(w)
  w.at(1, function() return { "modem_message", "modem_0", N.CINDER_FEED, N.CINDER_FEED,
    otherBase.seal({ type = "ops" }) } end)
end)
check("...the base feeding others but not this one", mOther.text:find("feeds screens but not tower", 1, true),
  mOther.err or mOther.text)
check("...nothing at all", masterCheck().text:find("nothing from the base", 1, true))

local tc = runningTower(function(w) w.files[".watchkey"] = HEX3 .. "\n" end)
local unitNear = N.reading({ x = 400, y = 100, z = 0 }, { x = 0, y = 0, z = 0 })
fromBase(tc, 1, { type = "cinder.status", stealth = false })
fromBase(tc, 2, { type = "cinder.unit", unit = "drone-1", x = 300, y = 100, z = 0, spd = 0, phase = "docked" })
pingAt(tc, 3, tx1, unitNear)
fromBase(tc, 5, { type = "cinder.status", stealth = true })
fromBase(tc, 6, { type = "cinder.unit", unit = "drone-1", x = 300, y = 100, z = 0, spd = 0, phase = "docked" })
pingAt(tc, 13, tx1, unitNear)
tc = tc:run("tower.lua", {}, 16)
local cPongs = {}
local rxC = S.receiver()      -- a fresh one: each tower world starts its counter again
for _, s in ipairs(tc.sent) do
  local body = s.env and s.env.id == "nav-0001" and rxC.open(s.env, function() return KEY1 end, S.DIR.TOWER_TO_NAV, nil)
  if body then cPongs[#cPongs + 1] = N.parsePong(body) end
end
check("a nav unit is told of the CINDER unit as traffic", cPongs[1] and #cPongs[1].traffic == 1
  and cPongs[1].traffic[1].call == "LAMBDA-001" and cPongs[1].traffic[1].reg == "CINDER", tc.err or tostring(#cPongs))
check("stealth: gone, and what the base sends after is ignored", cPongs[2] and #cPongs[2].traffic == 0,
  cPongs[2] and #cPongs[2].traffic)
local tn = runningTower()
fromBase(tn, 1, { type = "cinder.unit", unit = "drone-1", x = 300, y = 100, z = 0, spd = 0 })
pingAt(tn, 3, tx1, unitNear)
tn = tn:run("tower.lua", {}, 5)
local nPong
local rxN = S.receiver()
for _, s in ipairs(tn.sent) do
  local body = s.env and s.env.id == "nav-0001" and rxN.open(s.env, function() return KEY1 end, S.DIR.TOWER_TO_NAV, nil)
  if body then nPong = N.parsePong(body) end
end
check("no watch key: no CINDER units at all", nPong and #nPong.traffic == 0)
check("the feed's channel is the base's", N.CINDER_FEED == dofile(DIR .. "/../lib/watch.lua").CHANNEL)

-- ======================================================================
print("a registration kiosk and the master")
local KUI2 = dofile(DIR .. "/../lib/kioskui.lua")
local D2, T2 = dofile(DIR .. "/../lib/display.lua"), dofile(DIR .. "/../lib/tui.lua")
local function at(view, id)
  for _, h in ipairs(KUI2.render(T2, D2.canvas(57, 24), view)) do if h.id == id then return h.x1, h.y1 end end
end
-- the master answering a kiosk's sealed questions
local KKEY = S.parseKey(HEX2)
local kq = S.sender(KKEY, "kiosk-hq", S.DIR.KIOSK_TO_TOWER, nil)
local tq = runningTower(function(w)
  w.files[".kioskkeys"] = S.formatFleetKeys({ ["kiosk-hq"] = KKEY }, S.KIOSK_HEADER)
end)
local function askAt(t, q, op, fields)
  tq.at(t, function()
    local m = { type = "kq", q = q, op = op }
    for k, v in pairs(fields or {}) do m[k] = v end
    return { "modem_message", "modem_0", N.CHANNEL, N.CHANNEL, kq.seal(m) }
  end)
end
S.newKey = function() return KEY3 end
askAt(1, "a", "info", { owner = "alex_r" })
askAt(1.5, "b", "callFree", { call = "falcon" })
askAt(2, "c", "callFree", { call = "lambda-1" })
askAt(2.5, "d", "register", { owner = "sam_k", kind = "sea", call = "kite" })
askAt(3, "e", "written", { unit = "nav-0003", ok = true })
askAt(3.5, "f", "register", { owner = "sam_k", kind = "air", call = "kite" })
askAt(4, "g", "refresh", { unit = "nav-0003", owner = "alex_r", call = "KESTREL" })
askAt(4.5, "h", "apply", { owner = "sam_k", name = "NORTH", x = 1200, z = -400 })
askAt(5, "i", "status", { stock = 0 })
askAt(5.5, "j", "register", { owner = "sam_k", kind = "air", call = "hawk2" })
askAt(6, "k", "written", { unit = "nav-0004", ok = false })
tq = tq:run("tower.lua", {}, 8)
S.newKey = realNewKey
local rxK, ans = S.receiver(), {}
for _, s in ipairs(tq.sent) do
  local b = s.env and s.env.id == "kiosk-hq" and rxK.open(s.env, function() return KKEY end, S.DIR.TOWER_TO_KIOSK, nil)
  if b and b.type == "ka" then ans[b.re] = b end
end
check("the master answers the kiosk: alex_r has one unit, the next is CR-0003", ans.a and ans.a.count == 1
  and ans.a.nextReg == "CR-0003", tq.err)
check("a taken callsign and a CINDER one are refused", ans.b and not ans.b.ok and ans.b.why == "TAKEN BY CR-0001"
  and ans.c and ans.c.why == "RESERVED FOR CINDER")
check("register: filed, and the new unit's key sent back, sealed to that kiosk", ans.d and ans.d.ok
  and ans.d.unit == "nav-0003" and ans.d.reg == "CR-0003" and ans.d.call == "KITE" and ans.d.key == HEX3)
check("a second unit cannot take the same callsign", ans.f and not ans.f.ok and ans.f.why == "TAKEN BY CR-0003")
check("someone else cannot change a player's unit", ans.g and not ans.g.ok and ans.g.why == "NOT YOUR UNIT")
local regK = N.loadRegistry(tq.files["navreg.lua"] or "")
local kite
for _, r in ipairs(regK) do if r.unit == "nav-0003" then kite = r end end
check("the kiosk's unit is in the registry, owner off its seat, filed by the kiosk", kite and kite.owner == "sam_k"
  and kite.idby == "seat" and kite.by == "kiosk-hq" and (tq.files[".navkeys"] or ""):find("nav-0003=", 1, true))
check("one the kiosk could not write is taken back out", not (tq.files[".navkeys"] or ""):find("nav-0004=", 1, true)
  and #regK == 3, #regK)
check("an application to host a centre is filed", ans.h and ans.h.ok
  and (tq.files["centreapps.csv"] or ""):find("1,%d+,sam_k,NORTH,1200,%-400,pending"))
check("and how many kits each kiosk has", (tq.files["kiosks.status"] or ""):find("kiosk-hq=0,", 1, true))
-- open (no keys): answered in the clear only while the master says so
local function plainAsk(tw, t, q, fields)
  tw.at(t, function()
    local m = { type = "kq", q = q, op = "info", owner = "alex_r", kiosk = "LOBBY" }
    for k, v in pairs(fields or {}) do m[k] = v end
    return { "modem_message", "modem_0", N.CHANNEL, N.CHANNEL, m }
  end)
end
local to = runningTower(function(w) w.files["kiosks.open"] = "x" end)
plainAsk(to, 1, "p1")
to = to:run("tower.lua", {}, 3)
local plain
for _, s in ipairs(to.sent) do if type(s.env) == "table" and s.env.type == "ka" and s.env.re == "p1" then plain = s.env end end
check("open: a kiosk with no key is answered in the clear, by its name", plain and plain.to == "kiosk-lobby"
  and plain.count == 1, to.err)
local tc2 = runningTower()
plainAsk(tc2, 1, "p2")
tc2 = tc2:run("tower.lua", {}, 3)
local plain2
for _, s in ipairs(tc2.sent) do if type(s.env) == "table" and s.env.type == "ka" then plain2 = s.env end end
check("closed (the default): no answer without a key", plain2 == nil)
local unknown = S.sender(KEY1, "kiosk-x", S.DIR.KIOSK_TO_TOWER, nil)
local tu = runningTower()
tu.at(1, function() return { "modem_message", "modem_0", N.CHANNEL, N.CHANNEL,
  unknown.seal({ type = "kq", q = "z", op = "info", owner = "x" }) } end)
tu = tu:run("tower.lua", {}, 3)
local answeredStranger = false
for _, s in ipairs(tu.sent) do if s.env and s.env.id == "kiosk-x" then answeredStranger = true end end
check("a kiosk the master does not know gets no answer", not answeredStranger)

-- the kiosk itself (navdesk.lua), against a stand-in for the master
local function kioskWorld(open)
  local w = withFs(W.new(DIR, { label = "kiosk-hq", S = S }))
  for _, f in ipairs(N.FILES) do w.files[f] = readRepo(f) end
  for _, f in ipairs({ "startup.lua", "navdesk.lua", "lib/navkiosk.lua", "lib/kioskui.lua" }) do w.files[f] = readRepo(f) end
  w.files[".navdesk"] = N.kioskFile({ name = "HQ", master = "CHI" })
  if not open then w.files[".navdeskkey"] = HEX2 .. "\n" end
  w.files["navdesk.cfg"] = "monitor=monitor_9\ndrive=drive_0\nstock=minecraft:chest_0\nout=minecraft:chest_1\n"
  w.periph.monitor_9 = { type = "monitor", m = { getSize = function() return 57, 24 end, setTextScale = function() end,
    setPaletteColour = function() end, setCursorPos = function() end, blit = function() end, isColour = function() return true end } }
  w.periph.create_target_0 = { type = "create_target", m = { getLine = function() return "sam_k" end } }
  w.stock = { { name = "computercraft:computer_advanced", count = 1 }, { name = "computercraft:monitor_advanced", count = 2 },
              { name = "computercraft:wireless_modem_advanced", count = 1 } }
  w.out = {}
  w.periph.drive_0 = { type = "drive", m = { hasData = function() return w.inDrive ~= nil end,
    getMountPath = function() return "disk" end, ejectDisk = function() w.inDrive = nil end,
    isDiskPresent = function() return w.inDrive ~= nil end,
    setDiskLabel = function(l) w.labelled = l end } }
  w.periph["minecraft:chest_0"] = { type = "minecraft:chest", m = {
    list = function()
      local t = {}
      for k, v in pairs(w.stock) do t[k] = { name = v.name, count = v.count } end
      return t
    end,
    pushItems = function(to, slot, n)
      local it = w.stock[slot]
      if not it then return 0 end
      n = math.min(n or it.count, it.count)
      if to == "drive_0" then
        if w.inDrive then return 0 end
        w.inDrive, n = it.name, 1
      else
        w.out[#w.out + 1] = { name = it.name, count = n }
      end
      it.count = it.count - n
      if it.count == 0 then w.stock[slot] = nil end
      return n
    end,
    pullItems = function(from)
      if from == "drive_0" and w.inDrive then w.stock[9] = { name = w.inDrive, count = 1 } w.inDrive = nil return 1 end
      return 0
    end } }
  w.periph["minecraft:chest_1"] = { type = "minecraft:chest", m = {
    list = function() return w.out end,
    pushItems = function(to, slot)
      local it = w.out[slot]
      if to ~= "drive_0" or not it or w.inDrive then return 0 end
      w.inDrive, w.inDriveNbt = it.name, it.nbt
      for k in pairs(w.files) do if k:sub(1, 5) == "disk/" then w.files[k] = nil end end
      for k, v in pairs(it.files or {}) do w.files["disk/" .. k] = v end
      table.remove(w.out, slot)
      return 1
    end,
    pullItems = function(from)
      if from == "drive_0" and w.inDrive then
        w.out[#w.out + 1] = { name = w.inDrive, count = 1, written = w.files["disk/.nav"] ~= nil,
          nbt = w.inDriveNbt or ("issued-" .. #w.out), nav = w.files["disk/.nav"] }
        w.inDrive, w.inDriveNbt = nil, nil
        return 1
      end
      return 0
    end } }
  -- the stand-in master: opens each question, answers it a moment later
  local mrx, mtx = S.receiver(), S.sender(KKEY, "kiosk-hq", S.DIR.TOWER_TO_KIOSK, nil)
  w.asked = {}
  w.periph.modem_0 = { type = "modem", m = { isWireless = function() return true end, open = function() end,
    transmit = function(ch, _, env)
      local b
      if open then b = (type(env) == "table" and not env.sl) and env or nil
      else b = mrx.open(env, function(id) return id == "kiosk-hq" and KKEY or nil end, S.DIR.KIOSK_TO_TOWER, nil) end
      if not b then return end
      w.asked[#w.asked + 1] = b.op
      local a = { type = "ka", re = b.q, ok = true }
      if b.op == "info" then a.count, a.nextReg = 0, "CR-0009"
      elseif b.op == "callFree" then a.call = N.validCall(b.call)
      elseif b.op == "register" then
        a.unit, a.n, a.reg, a.call, a.kind, a.owner, a.key = "nav-0009", 9, "CR-0009", N.validCall(b.call), b.kind,
          b.owner, HEX3
      elseif b.op == "written" then w.writtenOk = b.ok
      elseif b.op == "find" then
        a.unit, a.n, a.reg, a.call, a.kind, a.owner = b.unit, 7, "CR-0007", "OLD KITE", "air", w.unitOwner or "sam_k"
      elseif b.op == "refresh" then
        w.refreshed = b
        a.unit, a.n, a.reg, a.call, a.kind, a.owner = b.unit, 7, "CR-0007", N.validCall(b.call or "OLD KITE"),
          b.kind or "air", "sam_k"
      end
      local reply = mtx.seal(a)
      if open then a.to = "kiosk-" .. tostring(b.kiosk):lower() reply = a end
      w.at(w.clock + 0.05, { "modem_message", "modem_0", N.CHANNEL, N.CHANNEL, reply })
    end } }
  return w
end
local kw = kioskWorld()
local function kTouch(t, view, id) local x, y = at(view, id) kw.at(t, { "monitor_touch", "monitor_9", x, y }) end
kTouch(2, { state = "hello", who = "sam_k", stock = 1 }, "register")
kTouch(3, { state = "type" }, "kind:air")
for i, ch in ipairs({ "K", "I", "T", "E" }) do kTouch(3 + i * 0.3, { state = "callsign", call = "" }, "key:" .. ch) end
kTouch(5.5, { state = "callsign", call = "KITE" }, "next")
kTouch(6.5, { state = "confirm", call = "KITE" }, "register")
kw = kw:run("navdesk.lua", {}, 9)
local unitFile = N.parseUnitFile(kw.files["disk/.nav"])
check("the kiosk asked the master, never decided itself", table.concat(kw.asked, ","):find("callFree", 1, true)
  and table.concat(kw.asked, ","):find("register", 1, true), kw.err or table.concat(kw.asked, ","))
check("the unit written with the master's number and key, role nav", unitFile and unitFile.unit == "nav-0009"
  and unitFile.call == "KITE" and unitFile.owner == "sam_k" and kw.files["disk/.navkey"] == HEX3 .. "\n"
  and kw.files["disk/.role"] == "nav\n" and kw.labelled == "nav-0009", kw.err)
check("and the master told it was written", kw.writtenOk == true)
local gotK = {}
for _, it in ipairs(kw.out) do gotK[it.name] = (gotK[it.name] or 0) + it.count end
check("the kit in the out chest: the unit, two monitors, an ender modem",
  gotK["computercraft:computer_advanced"] == 1 and gotK["computercraft:monitor_advanced"] == 2
  and gotK["computercraft:wireless_modem_advanced"] == 1 and kw.out[1].written, tostring(#kw.out))

-- players cannot reach the drive (Alex, 2026-10-04): their unit goes in the
-- out container, the kiosk takes it into the drive, checks it is theirs,
-- updates it, and gives it back there
local unitFiles = { [".nav"] = N.unitFile(N.checkRecord(rec(7, "OLD KITE", "air", "sam_k"))), [".navkey"] = HEX3 .. "\n" }
local kx = kioskWorld()
kx.out = { { name = "computercraft:computer_advanced", count = 1, nbt = "sams-unit", files = unitFiles } }
local seenX = {}
kx.at(1.5, function(world) seenX.state = "?" return { "noop" } end)
local function xTouch(t, view, id) local x, y = at(view, id) kx.at(t, { "monitor_touch", "monitor_9", x, y }) end
xTouch(3, { state = "mine", who = "sam_k", unit = { id = "nav-0007", reg = "CR-0007", call = "OLD KITE", kind = "air" } },
  "update")
kx = kx:run("navdesk.lua", {}, 6)
check("a unit put in the out container: the kiosk takes it, finds it theirs, updates it, gives it back",
  kx.err == nil and kx.refreshed and kx.refreshed.unit == "nav-0007" and kx.refreshed.owner == "sam_k"
  and kx.out[1] and kx.out[1].nbt == "sams-unit" and kx.out[1].written and not kx.inDrive,
  kx.err or (tostring(kx.refreshed) .. " out " .. #kx.out))
local ky = kioskWorld()
ky.unitOwner = "alex_r"
ky.out = { { name = "computercraft:computer_advanced", count = 1, nbt = "alexs-unit", files = unitFiles } }
local yRows = {}
ky.periph.monitor_9.m.blit = function(s2) yRows[#yRows + 1] = s2 end
ky = ky:run("navdesk.lua", {}, 4)
check("...someone else's: back in the container at once, and not taken again", ky.err == nil and #ky.out == 1
  and ky.out[1].nbt == "alexs-unit" and not ky.inDrive and table.concat(yRows, "\n"):find("REGISTERED TO ANOTHER", 1, true)
  and #(ky.asked) < 12, ky.err or (#ky.out .. " " .. table.concat(ky.asked, ",")))

-- setup on a bare computer: says what is missing instead of failing
local bare = withFs(W.new(DIR, { label = "kiosk-hq", S = S, lines = { "1", "2" } }))
for _, f in ipairs({ "navdesk.lua", "lib/nav.lua", "lib/seclink.lua" }) do bare.files[f] = readRepo(f) end
bare = bare:run("navdesk.lua", { "setup" }, 5)
check("navdesk setup with nothing fitted says what is missing", bare.err == nil
  and bare.text:find("seat: NONE", 1, true) and bare.text:find("monitor: NONE", 1, true), bare.err or bare.text)
local setupW = kioskWorld(true)
setupW.files["navdesk.cfg"] = nil
setupW.lines = { "2" }
setupW = setupW:run("navdesk.lua", { "setup" }, 5)
check("navdesk setup finds the monitor, drive and seat, and asks which chest is which",
  setupW.err == nil and (setupW.files["navdesk.cfg"] or ""):find("monitor=monitor_9", 1, true)
  and (setupW.files["navdesk.cfg"] or ""):find("drive=drive_0", 1, true)
  and setupW.text:find("seat: create_target_0", 1, true)
  and (setupW.files["navdesk.cfg"] or ""):find("out=minecraft:chest_1", 1, true)
  and setupW.text:find("stock: every other container - minecraft:chest_0", 1, true), setupW.err or setupW.text)

-- Alex's booth (2026-10-04): an empty barrel gives, barrels and a chest each
-- hold one part, and the stock is whatever is on the network - the modem
-- barrel is cabled in after the kiosk has started
local km = kioskWorld(true)
km.files["navdesk.cfg"] = "monitor=monitor_9\ndrive=drive_0\nout=minecraft:barrel_0\n"
km.out = {}
local function part(name, count, kind)
  local held = { { name = name, count = count } }
  return { type = kind or "minecraft:barrel", m = {
    list = function()
      local t = {}
      for k, v in pairs(held) do t[k] = { name = v.name, count = v.count } end
      return t
    end,
    pushItems = function(to, slot, n)
      local it = held[slot]
      if not it then return 0 end
      n = math.min(n or it.count, it.count)
      if to == "drive_0" then
        if km.inDrive then return 0 end
        km.inDrive, n = it.name, 1
      else
        km.out[#km.out + 1] = { name = it.name, count = n }
      end
      it.count = it.count - n
      if it.count == 0 then held[slot] = nil end
      return n
    end,
    pullItems = function(from)
      if from == "drive_0" and km.inDrive then held[9] = { name = km.inDrive, count = 1 } km.inDrive = nil return 1 end
      return 0
    end } }
end
km.periph["minecraft:barrel_2"] = part("computercraft:computer_advanced", 3)
km.periph["minecraft:chest_3"] = part("computercraft:monitor_advanced", 6, "minecraft:chest")
km.periph["minecraft:barrel_0"] = km.periph["minecraft:chest_1"]
km.periph["minecraft:chest_0"], km.periph["minecraft:chest_1"] = nil, nil
km.at(1, function(world)
  world.periph["minecraft:barrel_4"] = part("computercraft:wireless_modem_advanced", 3)
  return { "noop" }
end)
local function mTouch(t, view, id) local x, y = at(view, id) km.at(t, { "monitor_touch", "monitor_9", x, y }) end
mTouch(2, { state = "hello", who = "sam_k", stock = 3 }, "register")
mTouch(3, { state = "type" }, "kind:sea")
for i, ch in ipairs({ "B", "O", "A", "T" }) do mTouch(3 + i * 0.3, { state = "callsign", call = "" }, "key:" .. ch) end
mTouch(5.5, { state = "callsign", call = "BOAT" }, "next")
mTouch(6.5, { state = "confirm", call = "BOAT" }, "register")
km = km:run("navdesk.lua", {}, 9)
local gotM = {}
for _, it in ipairs(km.out) do gotM[it.name] = (gotM[it.name] or 0) + it.count end
check("barrels are stock as much as chests, one cabled in later counts, the empty out barrel never does: the whole kit",
  gotM["computercraft:computer_advanced"] == 1 and gotM["computercraft:monitor_advanced"] == 2
  and gotM["computercraft:wireless_modem_advanced"] == 1, km.err or tostring(#km.out))

-- 2026-10-04: navdesk.cfg said monitor=top, and top had become a block with a
-- getSize and no setCursorPos - the kiosk crashed in a loop. Now any monitor.
local kmon = kioskWorld(true)
kmon.files["navdesk.cfg"] = "monitor=top\ndrive=drive_0\nstock=minecraft:chest_0\nout=minecraft:chest_1\n"
kmon.periph.top = { type = "cccbridge:target", m = { getSize = function() return 20, 4 end } }
local drawn = 0
kmon.periph.monitor_9.m.blit = function() drawn = drawn + 1 end
kmon = kmon:run("navdesk.lua", {}, 4)
check("a kiosk whose saved side is no longer a monitor: no crash, it draws on the monitor there is", kmon.err == nil
  and drawn > 0 and kmon.text:find("1 monitor", 1, true), kmon.err or kmon.text)

local ko = kioskWorld(true)
local function oTouch(t, view, id) local x, y = at(view, id) ko.at(t, { "monitor_touch", "monitor_9", x, y }) end
oTouch(2, { state = "hello", who = "sam_k", stock = 1 }, "register")
oTouch(3, { state = "type" }, "kind:air")
for i, ch in ipairs({ "K", "I", "T", "E" }) do oTouch(3 + i * 0.3, { state = "callsign", call = "" }, "key:" .. ch) end
oTouch(5.5, { state = "callsign", call = "KITE" }, "next")
oTouch(6.5, { state = "confirm", call = "KITE" }, "register")
ko = ko:run("navdesk.lua", {}, 9)
check("with no key the kiosk works in the clear, under its own name", ko.files["disk/.navkey"] == HEX3 .. "\n"
  and ko.text:find("NO KEY", 1, true), ko.err or ko.text)

-- a revocation done beside it is picked up at the next sync
local tw2 = runningTower()
pingAt(tw2, 1, tx2, headOn2)
tw2.at(5, function(world)
  world.files[".navkeys"] = S.formatFleetKeys({ ["nav-0001"] = KEY1 }, S.NAV_HEADER)
  return { "noop" }      -- an event nobody listens for: cc_world needs one back
end)
pingAt(tw2, 15, tx2, headOn2)
tw2 = tw2:run("tower.lua", {}, 20)
local answered2 = 0
for _, s in ipairs(tw2.sent) do if s.env and s.env.id == "nav-0002" then answered2 = answered2 + 1 end end
check("revoked: answered before, not after", answered2 == 1, answered2)

-- ======================================================================
print("the unit on a vehicle")
local function unitWorld(opts)
  opts = opts or {}
  local u = withFs(W.new(DIR, { label = "nav-0001", S = S }))
  if not opts.unregistered then
    u.files[".nav"] = N.unitFile(N.checkRecord(rec(1, "FALCON", opts.kind or "air")))
    u.files[".navkey"] = HEX1 .. "\n"
  end
  u.sent, u.rows = {}, {}
  radio(u, "modem_1", u.sent)
  local cy = 1
  u.periph.monitor_0 = { type = "monitor", m = { isColour = function() return true end,
    setTextScale = function() end, getSize = function() return 36, 10 end, setPaletteColour = function() end,
    setCursorPos = function(_, y) cy = y end,
    blit = function(s) u.rows[cy] = s:gsub("[\128-\255]", " ") end } }
  u.pos = { x = 100, y = 150, z = -40 }
  u.craftName = "Falcon"
  u.env.sublevel = {
    getLogicalPose = function() return { position = { x = u.pos.x, y = u.pos.y, z = u.pos.z },
                                         orientation = { x = 0, y = 0, z = 0, w = 1 } } end,
    getLinearVelocity = function() return { x = 0, y = 0, z = -30 } end,
    getAngularVelocity = function() return { x = 0, y = -0.05, z = 0 } end,
    getUniqueId = function() return "uuid-falcon" end,
    getName = function() return u.craftName end,
    setName = function(s) u.craftName = s u.named = (u.named or 0) + 1 end,
    getMass = function() return 1500 end,
  }
  return u
end
local function screen(u) local t = {} for y = 1, 10 do t[y] = u.rows[y] or "" end return table.concat(t, "\n") end
local towerTx = S.sender(KEY1, "nav-0001", S.DIR.TOWER_TO_NAV, nil)
local function pongAt(u, t, traffic, adv, opts)
  u.at(t, function() return { "modem_message", "modem_1", N.CHANNEL, N.CHANNEL, towerTx.seal(N.pong(traffic, adv, opts)) } end)
end
local u = unitWorld()
local seen = {}
u.at(3, function(world) seen.before = screen(world) return { "noop" } end)
pongAt(u, 3.2, { { call = "HAWK", reg = "CR-0002", kind = "air", brg = 0, dist = 300, dy = 2, warn = true } },
  "TRAFFIC 12 O'CLOCK 300 SAME LEVEL")
u.at(3.6, function(world) seen.contact = screen(world) return { "noop" } end)
u = u:run("nav.lua", { "kiosk" }, 4)
local rxT = S.receiver()
local pings = {}
for _, s in ipairs(u.sent) do
  local body = s.env and rxT.open(s.env, function(id) return id == "nav-0001" and KEY1 or nil end, S.DIR.NAV_TO_TOWER, nil)
  if body then pings[#pings + 1] = N.checkPing(body) end
end
check("it pings at once, sealed, from what Sable says", u.err == nil and #pings >= 1 and pings[1].x == 100
  and pings[1].y == 150 and pings[1].spd == 30 and pings[1].hdg == 0 and pings[1].st == "move"
  and pings[1].sid == "uuid-falcon" and pings[1].sname == "CR-0001 FALCON", u.err or #pings)
check("the craft carries its registration: Sable's name stamped once", u.craftName == "CR-0001 FALCON" and u.named == 1,
  tostring(u.craftName) .. " " .. tostring(u.named))
check("...and the ping says it, with the turn (a right turn, from Sable's spin)", pings[1] and pings[1].sname == "CR-0001 FALCON"
  and pings[1].tr == 2.9, pings[1] and pings[1].tr)
check("every two seconds while it moves", #pings >= 2 and u.sent[2].t - u.sent[1].t == N.PING_MOVING, #pings)
check("the screen before the tower answers: calling", (seen.before or ""):find("CALLING TOWER", 1, true), seen.before)
check("after the pong: in contact, and the advisory across the screen", (seen.contact or ""):find("TOWER CONTACT", 1, true)
  and (seen.contact or ""):find("TRAFFIC 12 O'CLOCK 300 SAME LEVEL", 1, true), seen.contact)

local u2 = unitWorld()
u2 = u2:run("nav.lua", { "kiosk" }, 9)
check("no answer to three pings: NO TOWER CONTACT", screen(u2):find("NO TOWER CONTACT", 1, true), screen(u2))

local u3 = unitWorld()
u3.at(1, { "monitor_touch", "monitor_0", 33, 10 })
u3.at(1.5, function(world) seen.armed = screen(world) return { "noop" } end)
u3.at(2, { "monitor_touch", "monitor_0", 33, 10 })
pongAt(u3, 2.5, {}, nil, { sos = true })
u3.at(3, function(world) seen.heard = screen(world) return { "noop" } end)
u3 = u3:run("nav.lua", { "kiosk" }, 3.1)
local sosPing = false
local rx3 = S.receiver()
for _, s in ipairs(u3.sent) do
  local body = s.env and rx3.open(s.env, function() return KEY1 end, S.DIR.NAV_TO_TOWER, nil)
  if body and body.st == "sos" and s.t >= 2 and s.t < 2.5 then sosPing = true end
end
check("distress: one touch arms it", (seen.armed or ""):find("TOUCH AGAIN", 1, true), seen.armed)
check("...a second sends at once", sosPing)
check("...and the tower's acknowledgement shows", (seen.heard or ""):find("SOS HEARD", 1, true), seen.heard)

local u4 = unitWorld()
u4.at(0.7, function(world) seen.first = screen(world) return { "noop" } end)
u4.at(1, { "monitor_touch", "monitor_0", 5, 10 })
u4.at(1.5, function(world) seen.miss = screen(world) return { "noop" } end)
u4 = u4:run("nav.lua", { "kiosk" }, 2)
check("a wide screen starts on the overview", (seen.first or ""):find("CINDER NAV", 1, true), seen.first)
check("a touch anywhere but SOS shows the next page, and arms nothing", (seen.miss or ""):find("SPEED", 1, true)
  and (seen.miss or ""):find("2/6", 1, true) and not (seen.miss or ""):find("TOUCH AGAIN", 1, true), seen.miss)
check("...and the screen keeps it", (u4.files[".navpages"] or ""):find("monitor_0=speed", 1, true), u4.files[".navpages"])

-- two screens: each its own page, the second starting one along
local u9 = unitWorld()
local rows2, cy2 = {}, 1
u9.periph.monitor_1 = { type = "monitor", m = { isColour = function() return true end,
  setTextScale = function() end, getSize = function() return 15, 10 end, setPaletteColour = function() end,
  setCursorPos = function(_, y) cy2 = y end, blit = function(s) rows2[cy2] = s:gsub("[\128-\255]", " ") end } }
local function screen2() local t = {} for y = 1, 10 do t[y] = rows2[y] or "" end return table.concat(t, "\n") end
u9.at(0.7, function() seen.two = screen2() return { "noop" } end)
u9.at(1, { "monitor_touch", "monitor_1", 3, 4 })
u9.at(1.5, function(world) seen.twoA, seen.twoB = screen(world), screen2() return { "noop" } end)
pongAt(u9, 1.8, {}, nil, { centres = { { name = "CHI", x = 100, y = 70, z = 1000 } } })
u9.at(2, { "monitor_touch", "monitor_1", 3, 4 })
u9.at(2.2, { "monitor_touch", "monitor_1", 3, 4 })
u9.at(2.6, function() seen.twoS = screen2() return { "noop" } end)
u9 = u9:run("nav.lua", { "kiosk" }, 3)
check("a second screen starts one page along (a block: the altimeter)", (seen.two or ""):find("ALTIMETER", 1, true), seen.two)
check("a touch moves only that screen on", (seen.twoB or ""):find("HEADING", 1, true)
  and (seen.twoA or ""):find("CINDER NAV", 1, true), seen.twoB)
check("the status page shows the nearest centre the tower named", (seen.twoS or ""):find("CHI 1.0K S", 1, true), seen.twoS)
local u10 = unitWorld()
u10.files[".navpages"] = "monitor_0=radar\n"
u10.at(0.7, function(world) seen.kept = screen(world) return { "noop" } end)
u10 = u10:run("nav.lua", { "kiosk" }, 1)
check("after a restart each screen is back on its page", (seen.kept or ""):find("RADAR", 1, true), seen.kept)

local u5 = unitWorld()
u5.at(1, { "monitor_touch", "monitor_0", 33, 10 })
u5 = u5:run("nav.lua", { "kiosk" }, 8)
check("an armed key lets go by itself", not screen(u5):find("TOUCH AGAIN", 1, true), screen(u5))

local u6 = unitWorld({ unregistered = true })
u6 = u6:run("nav.lua", { "kiosk" }, 5)
check("unregistered: says so, sends nothing", screen(u6):find("UNREGISTERED", 1, true) and #u6.sent == 0, screen(u6))

local u7 = unitWorld({ kind = "sub" })
u7.pos = { x = 0, y = 40, z = 0 }
u7 = u7:run("nav.lua", { "kiosk" }, 1)
check("a submarine's screen shows depth", screen(u7):find("DEPTH", 1, true), screen(u7))

local u8 = unitWorld()
local stopped = u8.env.sublevel
stopped.getLinearVelocity = function() return { x = 0, y = 0, z = 0 } end
u8 = u8:run("nav.lua", { "kiosk" }, 12)
check("standing still it pings every ten seconds", #u8.sent == 2 and u8.sent[2].t - u8.sent[1].t == N.PING_PARKED, #u8.sent)


-- ======================================================================
print("traffic centres")
local function cmdWorld(args, setup, lines)
  local cw = withFs(W.new(DIR, { label = "tower", S = S, lines = lines }))
  if setup then setup(cw) end
  return cw:run("tower.lua", args, 10)
end
local here = cmdWorld({ "here", "chi", "2497", "70", "-3297" })
check("tower here: this master's name and place", (here.files["tower.cfg"] or ""):find("name=CHI", 1, true)
  and (here.files["tower.cfg"] or ""):find("z=-3297", 1, true), here.text)
local rangeW = cmdWorld({ "range", "3000" }, function(cw) cw.files["tower.cfg"] = here.files["tower.cfg"] end)
check("tower range keeps the place", (rangeW.files["tower.cfg"] or ""):find("range=3000", 1, true)
  and (rangeW.files["tower.cfg"] or ""):find("name=CHI", 1, true), rangeW.files["tower.cfg"])
S.newKey = function() return KEY3 end
local added = cmdWorld({ "centre", "add", "north", "1200", "80", "-400" }, function(cw)
  cw.files["tower.cfg"] = here.files["tower.cfg"]
  cw.ejected = 0
  cw.periph.drive_0 = { type = "drive", m = { hasData = function() return true end,
    getMountPath = function() return "disk" end, ejectDisk = function() cw.ejected = cw.ejected + 1 end,
    setDiskLabel = function(l) cw.labelled = l end } }
end)
S.newKey = realNewKey
check("tower centre add: its key and identity on the drive, its key and place here", added.err == nil
  and added.files["disk/.centrekey"] == HEX3 .. "\n"
  and N.parseCentreFile(added.files["disk/.centre"]).master == "CHI"
  and (added.files[".centrekeys"] or ""):find("ctr-north=" .. HEX3, 1, true)
  and (added.files["centres.lua"] or ""):find("NORTH=1200,80,-400", 1, true)
  and added.labelled == "tower-north" and added.ejected == 1, added.err or added.text)
local joined = cmdWorld({ "join" }, function(cw)
  cw.files["disk/.centre"] = added.files["disk/.centre"]
  cw.files["disk/.centrekey"] = added.files["disk/.centrekey"]
  cw.periph.drive_0 = { type = "drive", m = { hasData = function() return true end, getMountPath = function() return "disk" end } }
end)
check("tower join on a centre: its identity off the floppy, the floppy wiped", joined.files[".centre"]
  and joined.files[".centrekey"] == HEX3 .. "\n" and not joined.files["disk/.centrekey"], joined.text)

-- the master: pongs name the centres, and the centre is fed the picture
local function masterWorld()
  local mw = runningTower(function(tw)
    tw.files["tower.cfg"] = "name=CHI\nrange=2000\nx=0\ny=70\nz=0\n"
    tw.files["centres.lua"] = "NORTH=1200,80,-400\n"
    tw.files[".centrekeys"] = S.formatFleetKeys({ ["ctr-north"] = KEY3 }, S.CENTRE_HEADER)
    tw.mrows = {}
    local my = 1
    tw.periph.monitor_9 = { type = "monitor", m = { setTextScale = function() end, setPaletteColour = function() end,
      getSize = function() return 57, 38 end, setCursorPos = function(_, y) my = y end,
      blit = function(s) tw.mrows[my] = s:gsub("[\128-\255]", " ") end } }
  end)
  return mw
end
local mw = masterWorld()
pingAt(mw, 1, tx1, N.reading({ x = 300, y = 120, z = -200 }, { x = 10, y = 0, z = 0 }))
mw = mw:run("tower.lua", {}, 7)
local rxC, rxU2 = S.receiver(), S.receiver()
local pongC, pics = nil, {}
for _, s in ipairs(mw.sent) do
  if s.env and s.env.d == S.DIR.TOWER_TO_NAV then
    local b = rxU2.open(s.env, function() return KEY1 end, S.DIR.TOWER_TO_NAV, nil)
    pongC = b and N.parsePong(b) or pongC
  elseif s.env and s.env.d == S.DIR.TOWER_TO_CENTRE then
    local b = rxC.open(s.env, function(id) return id == "ctr-north" and KEY3 or nil end, S.DIR.TOWER_TO_CENTRE, nil)
    pics[#pics + 1] = b and N.parsePicture(b, 0)
  end
end
check("a pong names every centre, the master first", pongC and #pongC.centres == 2 and pongC.centres[1].name == "CHI"
  and pongC.centres[2].name == "NORTH", pongC and #pongC.centres)
check("the centre is fed a sealed picture every two seconds, with what the master hears", #pics >= 3
  and pics[#pics] and #pics[#pics].contacts == 1 and pics[#pics].contacts[1].call == "FALCON"
  and #pics[#pics].centres == 2, #pics)
local mscreen = table.concat(mw.mrows, "\n")
check("the master's 3x3 monitor shows the radar, the unit on it", mscreen:find("RANGE 2K", 1, true)
  and mscreen:find("FALCON", 1, true) and mscreen:find("NORTH", 1, true), mscreen)

-- a display-only centre: shows what the master sends, answers no one
local function centreWorld()
  local cw = withFs(W.new(DIR, { label = "tower-north", S = S }))
  cw.files[".centre"] = N.centreFile({ name = "NORTH", x = 1200, y = 80, z = -400, master = "CHI" })
  cw.files[".centrekey"] = HEX3 .. "\n"
  cw.sent, cw.mrows = {}, {}
  radio(cw, "modem_0", cw.sent)
  local my = 1
  cw.periph.monitor_9 = { type = "monitor", m = { setTextScale = function() end, setPaletteColour = function() end,
    getSize = function() return 57, 38 end, setCursorPos = function(_, y) my = y end,
    blit = function(s) cw.mrows[my] = s:gsub("[\128-\255]", " ") end } }
  return cw
end
local picTx = S.sender(KEY3, "ctr-north", S.DIR.TOWER_TO_CENTRE, nil)
local cw = centreWorld()
local pcs2 = {}
N.track(pcs2, rec(1, "FALCON"), N.ping(N.reading({ x = 1500, y = 120, z = -400 }, { x = 10, y = 0, z = 0 })), 0)
cw.at(1, function() return { "modem_message", "modem_0", N.CHANNEL, N.CHANNEL,
  picTx.seal(N.picture(pcs2, { { name = "CHI", x = 0, y = 70, z = 0 }, { name = "NORTH", x = 1200, y = 80, z = -400 } }, 0)) } end)
pingAt(cw, 2, tx1, N.reading({ x = 1500, y = 120, z = -400 }, nil))
cw.at(3, function(world) seen.centre = table.concat(world.mrows, "\n") return { "noop" } end)
cw = cw:run("tower.lua", {}, 4)
check("a centre shows the master's traffic round its own position, and says nothing of a master",
  (seen.centre or ""):find("CINDER TRAFFIC  NORTH", 1, true) and (seen.centre or ""):find("FALCON", 1, true)
  and not (seen.centre or ""):find("FEED", 1, true) and not (seen.centre or ""):find("FED BY", 1, true), seen.centre)
check("...and answers no unit itself", #cw.sent == 0, #cw.sent)
local cw2 = centreWorld():run("tower.lua", {}, 12)
check("a centre that hears nothing says NO SIGNAL", table.concat(cw2.mrows, "\n"):find("NO SIGNAL", 1, true))
-- a centre added again while the master runs: its new key is used within a sync
local mwR = masterWorld()
mwR.at(4, function(world)
  world.files[".centrekeys"] = S.formatFleetKeys({ ["ctr-north"] = KEY2 }, S.CENTRE_HEADER)
  return { "noop" }
end)
mwR = mwR:run("tower.lua", {}, 16)
local oldOK, newOK = 0, 0
local rxOld, rxNew = S.receiver(), S.receiver()
for _, s in ipairs(mwR.sent) do
  if s.env and s.env.d == S.DIR.TOWER_TO_CENTRE and (s.t or 0) > 11 then
    if rxOld.open(s.env, function() return KEY3 end, S.DIR.TOWER_TO_CENTRE, nil) then oldOK = oldOK + 1 end
    if rxNew.open(s.env, function() return KEY2 end, S.DIR.TOWER_TO_CENTRE, nil) then newOK = newOK + 1 end
  end
end
check("a centre added again while the master runs gets pictures in its new key, without a reboot",
  newOK >= 1 and oldOK == 0, newOK .. " new, " .. oldOK .. " old")

-- tower check on a centre: what is wrong with its signal
local function checkWith(feed)
  local w = centreWorld()
  if feed then feed(w) end
  return w:run("tower.lua", { "check" }, 12)
end
local fine = checkWith(function(w)
  for _, t in ipairs({ 1, 3, 5 }) do
    w.at(t, function() return { "modem_message", "modem_0", N.CHANNEL, N.CHANNEL, picTx.seal(N.picture({}, {}, 0)) } end)
  end
end)
check("tower check: pictures arriving - SIGNAL FINE", fine.text:find("SIGNAL FINE: 3 pictures", 1, true), fine.err or fine.text)
local wrongTx = S.sender(KEY2, "ctr-north", S.DIR.TOWER_TO_CENTRE, nil)
local wrong = checkWith(function(w)
  w.at(1, function() return { "modem_message", "modem_0", N.CHANNEL, N.CHANNEL, wrongTx.seal(N.picture({}, {}, 0)) } end)
end)
check("...sealed with another key - the keys differ, add it again", wrong.text:find("will not open", 1, true)
  and wrong.text:find("tower centre add NORTH", 1, true), wrong.err or wrong.text)
local southTx = S.sender(KEY2, "ctr-south", S.DIR.TOWER_TO_CENTRE, nil)
local south = checkWith(function(w)
  w.at(1, function() return { "modem_message", "modem_0", N.CHANNEL, N.CHANNEL, southTx.seal(N.picture({}, {}, 0)) } end)
end)
check("...only another centre's - the master is not feeding this one", south.text:find("feeding ctr-south", 1, true),
  south.err or south.text)
local pingsOnly = checkWith(function(w)
  w.at(1, function() return { "modem_message", "modem_0", N.CHANNEL, N.CHANNEL, tx1.seal(N.ping(N.reading({ x = 0, y = 70, z = 0 }, nil))) } end)
end)
check("...traffic but no pictures - is the master running, its chunk loaded", pingsOnly.text:find("the radio works", 1, true)
  and pingsOnly.text:find("chunk", 1, true), pingsOnly.err or pingsOnly.text)
local silent = checkWith()
check("...nothing at all - an ender modem? the master running?", silent.text:find("heard nothing at all", 1, true),
  silent.err or silent.text)

local cw3 = centreWorld():run("tower.lua", { "register" }, 3)
check("a centre registers nothing: that is the master's", cw3.text:find("display only", 1, true), cw3.text)
print("")
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then error("navnet tests failed", 0) end
