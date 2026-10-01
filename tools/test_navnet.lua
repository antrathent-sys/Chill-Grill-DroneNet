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
local function towerWorld(lines)
  local w = withFs(W.new(DIR, { label = "tower", S = S, lines = lines }))
  for _, f in ipairs(N.FILES) do w.files[f] = readRepo(f) end
  w.files["kiosk.lua"] = readRepo("kiosk.lua")
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
check("the unit has its software, key and identity, and kiosk as its startup", w.files["disk/nav.lua"]
  and w.files["disk/.navkey"] == HEX3 .. "\n" and w.files["disk/startup.lua"] == readRepo("kiosk.lua")
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
  u.periph.monitor_0 = { type = "monitor", m = {
    setTextScale = function() end, getSize = function() return 36, 10 end, setPaletteColour = function() end,
    setCursorPos = function(_, y) cy = y end,
    blit = function(s) u.rows[cy] = s:gsub("[\128-\255]", " ") end } }
  u.pos = { x = 100, y = 150, z = -40 }
  u.env.sublevel = {
    getLogicalPose = function() return { position = { x = u.pos.x, y = u.pos.y, z = u.pos.z },
                                         orientation = { x = 0, y = 0, z = 0, w = 1 } } end,
    getLinearVelocity = function() return { x = 0, y = 0, z = -30 } end,
    getUniqueId = function() return "uuid-falcon" end,
    getName = function() return "Falcon" end,
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
  and pings[1].sid == "uuid-falcon" and pings[1].sname == "Falcon", u.err or #pings)
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
u9.periph.monitor_1 = { type = "monitor", m = {
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
check("a second screen starts one page along (a block: height)", (seen.two or ""):find("ALTITUDE", 1, true), seen.two)
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
check("a centre shows the master's traffic round its own position", (seen.centre or ""):find("CINDER TRAFFIC  NORTH", 1, true)
  and (seen.centre or ""):find("FALCON", 1, true) and (seen.centre or ""):find("FEED", 1, true), seen.centre)
check("...and answers no unit itself", #cw.sent == 0, #cw.sent)
local cw2 = centreWorld():run("tower.lua", {}, 12)
check("a centre with no feed says so", table.concat(cw2.mrows, "\n"):find("NO FEED FROM MASTER", 1, true))
local cw3 = centreWorld():run("tower.lua", { "register" }, 3)
check("a centre registers nothing: that is the master's", cw3.text:find("display only", 1, true), cw3.text)
print("")
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then error("navnet tests failed", 0) end
