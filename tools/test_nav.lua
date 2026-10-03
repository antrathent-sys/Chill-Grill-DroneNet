-- Desktop tests for lib/nav.lua and lib/navui.lua: CINDER NAV's readings,
-- ping and pong, traffic and advisories, the registry, putting the software
-- on a unit, and the one screen at every size it might be fitted with.
local DIR = ...
local pass, fail = 0, 0
local function check(n, c, d)
  if c then pass = pass + 1 print("  ok   " .. n)
  else fail = fail + 1 print("  FAIL " .. n .. (d and ("  " .. tostring(d)) or "")) end
end
local abs = math.abs

local N = dofile(DIR .. "/../lib/nav.lua")
local UI = dofile(DIR .. "/../lib/navui.lua")
local D = dofile(DIR .. "/../lib/display.lua")
local T = dofile(DIR .. "/../lib/tui.lua")

print("readings")
local r = N.reading({ x = 100, y = 200, z = -50 }, { x = 10, y = -2, z = 0 })
check("ground speed, climb, and heading east moving +x", abs(r.spd - 10) < 1e-9 and r.vs == -2
  and abs(r.hdg - 90) < 1e-6 and r.moving)
check("north is -z", abs(N.reading({ x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = -5 }).hdg) < 1e-6)
local slow = N.reading({ x = 0, y = 64, z = 0 }, { x = 0.1, y = 0, z = 0 }, { hdg = 123 })
check("too slow for a heading: the last one is kept, and it is standing", slow.hdg == 123 and not slow.moving)
check("depth below sea level", N.reading({ x = 0, y = 40, z = 0 }, nil).depth == 23)
check("climbing alone counts as moving", N.reading({ x = 0, y = 0, z = 0 }, { x = 0, y = 3, z = 0 }).moving)

print("ping")
local p = N.ping(r, nil, { id = "a1b2", name = "Falcon", mass = 1234.4 })
check("a ping carries position, speed, heading, state and the vehicle", p.type == "nav.ping" and p.st == "move"
  and p.hdg == 90 and p.x == 100 and p.sid == "a1b2" and p.sname == "Falcon" and p.mass == 1234)
check("a good ping passes the tower's check", N.checkPing(p) ~= nil)
local bad = function(f) local q = N.ping(r) f(q) return N.checkPing(q) == nil end
check("a bad state is refused", bad(function(q) q.st = "fly" end))
check("off the world is refused", bad(function(q) q.x = 9e7 end))
check("not a number is refused", bad(function(q) q.spd = "fast" end) and bad(function(q) q.y = 0 / 0 end))
check("a heading off the compass is refused", bad(function(q) q.hdg = 400 end))
check("distress is a state", N.ping(r, "sos").st == "sos" and N.checkPing(N.ping(r, "sos")) ~= nil)

print("pong")
local tr = { { call = "HAWK, ONE", reg = "CR-0002", kind = "air", brg = 271.6, dist = 312.4, dy = -12.2, warn = true },
             { call = "BARGE", reg = "CR-0003", kind = "sea", brg = 10, dist = 900, dy = -150, warn = false } }
local pg = N.pong(tr, "TRAFFIC 12 O'CLOCK 300 SAME LEVEL", { sos = true })
local back = N.parsePong(pg)
check("traffic packs into one string and back", back and #back.traffic == 2 and back.traffic[1].call == "HAWK ONE"
  and back.traffic[1].brg == 272 and back.traffic[1].dist == 312 and back.traffic[1].dy == -12
  and back.traffic[1].warn and not back.traffic[2].warn and back.traffic[2].kind == "sea", pg.tr)
check("the advisory and the distress acknowledgement come through", back.adv == "TRAFFIC 12 O'CLOCK 300 SAME LEVEL" and back.sos)
check("a pong is a flat table seclink can carry", type(pg.tr) == "string" and type(pg.n) == "number")
check("not a pong is nil", N.parsePong({ type = "nav.ping" }) == nil)
local many = {}
for i = 1, 10 do many[i] = { call = "C" .. i, reg = "CR-" .. i, kind = "air", brg = 0, dist = i, dy = 0 } end
check("at most TRAFFIC_MAX contacts", #N.parsePong(N.pong(many)).traffic == N.TRAFFIC_MAX)

print("traffic")
local function rec(n, call, kind) return { n = n, unit = N.unitId(n), owner = "alex", call = call, kind = kind or "air" } end
local contacts = {}
local now = 100
local me = N.track(contacts, rec(1, "FALCON"), N.ping(N.reading({ x = 0, y = 64, z = 0 }, { x = 20, y = 0, z = 0 })), now)
N.track(contacts, rec(2, "HAWK"), N.ping(N.reading({ x = 300, y = 66, z = 0 }, { x = -20, y = 0, z = 0 })), now)
N.track(contacts, rec(3, "HIGH"), N.ping(N.reading({ x = 0, y = 200, z = 300 }, { x = 0, y = 0, z = 0 })), now)
N.track(contacts, rec(4, "FAR"), N.ping(N.reading({ x = 5000, y = 64, z = 0 }, nil)), now)
N.track(contacts, rec(5, "OLD"), N.ping(N.reading({ x = 50, y = 64, z = 0 }, nil)), now - N.STALE - 5)
local list = N.traffic(contacts, me, now)
check("traffic: in range and fresh only, not itself, nearest first", #list == 2 and list[1].call == "HAWK"
  and list[2].call == "HIGH", #list)
check("head-on at 300 closing at 40 b/s: passes in 7.5 s, too close - warned", abs(list[1].tca - 7.5) < 1e-6
  and list[1].cpa < 1 and list[1].warn)
check("far above: no warning", not list[2].warn and abs(list[2].dy - 136) < 1e-6)
check("the advisory says where, in clock and distance", N.advisory(me, list) == "TRAFFIC 12 O'CLOCK 300 SAME LEVEL",
  N.advisory(me, list))
check("clock positions", N.clock(90, 0) == 3 and N.clock(0, 90) == 9 and N.clock(180, 180) == 12 and N.clock(200, 0) == 7)
local calm = N.traffic({ [me.unit] = me, x = nil }, me, now)
check("nothing near: no advisory", #calm == 0 and N.advisory(me, calm) == nil)
contacts[N.unitId(2)].st = "sos"
contacts[N.unitId(2)].vx, contacts[N.unitId(2)].vz = 0, 0
me.vx = 0
local sosList = N.traffic(contacts, me, now)
check("someone in distress nearby is called out", N.advisory(me, sosList):find("DISTRESS HAWK", 1, true) ~= nil,
  N.advisory(me, sosList))

print("events")
local cs = {}
local R = rec(9, "TEST")
local _, ev = N.track(cs, R, N.ping(N.reading({ x = 0, y = 0, z = 0 }, nil)), 0)
check("first heard", ev[1] == "first")
_, ev = N.track(cs, R, N.ping(N.reading({ x = 0, y = 0, z = 0 }, { x = 5, y = 0, z = 0 })), 2)
check("standing to moving is a departure", ev[1] == "depart")
_, ev = N.track(cs, R, N.ping(N.reading({ x = 9, y = 0, z = 0 }, nil)), 4)
check("moving to standing is an arrival", ev[1] == "arrive")
_, ev = N.track(cs, R, N.ping(N.reading({ x = 9, y = 0, z = 0 }, nil), "sos"), 6)
check("distress", ev[1] == "sos")
_, ev = N.track(cs, R, N.ping(N.reading({ x = 9, y = 0, z = 0 }, nil)), 8)
check("distress over", ev[1] == "sos-clear")
R.sid = "old"
local cNew
cNew, ev = N.track(cs, R, N.ping(N.reading({ x = 9, y = 0, z = 0 }, nil), nil, { id = "new" }), 10)
check("a craft packed and put out again comes back with a new id: remembered, no event", #ev == 0 and cNew.sid == "new")
_, ev = N.track(cs, R, N.ping(N.reading({ x = 9, y = 0, z = 0 }, { x = 5, y = 0, z = 0 })), 10 + N.STALE + 30)
check("after a long silence moving again is not a departure from where it was", #ev == 0 or ev[1] ~= "depart")

print("registry")
check("registration number placeholder and unit id", N.regNumber(1) == "CR-0001" and N.unitId(1) == "nav-0001")
local good = { n = 1, unit = "nav-0001", owner = "alex_r", call = "falcon one", kind = "air", issued = "2026-10-01" }
check("a good record passes, callsign in capitals", N.checkRecord(good) and N.checkRecord(good).call == "FALCON ONE")
check("a bad owner, callsign, type or unit id is refused",
  not N.checkRecord({ n = 1, unit = "nav-0001", owner = "a b", call = "X1", kind = "air" })
  and not N.checkRecord({ n = 1, unit = "nav-0001", owner = "alex", call = "X", kind = "air" })
  and not N.checkRecord({ n = 1, unit = "nav-0001", owner = "alex", call = "OK", kind = "rocket" })
  and not N.checkRecord({ n = 2, unit = "nav-0001", owner = "alex", call = "OK", kind = "air" }))
local recs = { N.checkRecord(good), N.checkRecord({ n = 2, unit = "nav-0002", owner = "sam", call = "BARGE", kind = "sea",
  sid = "uuid-1", x = 5, y = 63, z = -9, revoked = "2026-10-02" }) }
local back2, badLines = N.loadRegistry(N.serialise(recs))
check("the registry round-trips", #back2 == 2 and back2[2].sid == "uuid-1" and back2[2].revoked == "2026-10-02"
  and back2[1].call == "FALCON ONE" and #badLines == 0)
local evil = N.loadRegistry("os.shutdown() return {}")
check("a registry that is code runs nothing and yields nothing", #evil == 0)
check("next number and lookups", N.nextNumber(recs) == 3 and N.find(recs, "cr-0002") == recs[2]
  and N.find(recs, "nav-0001") == recs[1] and N.find(recs, "2") == recs[2] and N.find(recs, "zzz") == nil)
local line = N.event(1700000000, recs[1], "depart", { x = 1.4, y = 64, z = -3.6 }, "a,b")
check("a log line", line == "1700000000,CR-0001,nav-0001,FALCON ONE,depart,1,64,-4,a b", line)

print("putting it on a unit")
-- a filesystem with directories, as CC's fs looks to the tower
local function fakeFs(files)
  local F = { files = files or {} }
  local function under(p) return function(k) return k == p or k:sub(1, #p + 1) == p .. "/" end end
  function F.exists(p)
    if F.files[p] then return true end
    for k in pairs(F.files) do if under(p)(k) then return true end end
    return false
  end
  function F.list(p)
    local seen, out = {}, {}
    for k in pairs(F.files) do
      if k:sub(1, #p + 1) == p .. "/" then
        local top = k:sub(#p + 2):match("^[^/]+")
        if top and not seen[top] then seen[top] = true out[#out + 1] = top end
      end
    end
    return out
  end
  function F.delete(p) for k in pairs(F.files) do if under(p)(k) then F.files[k] = nil end end end
  function F.getDir(p) return p:match("^(.*)/[^/]+$") or "" end
  function F.makeDir() end
  function F.copy(a, b) F.files[b] = assert(F.files[a], "no " .. a) end
  function F.open(p, mode)
    if mode == "r" then
      local s = F.files[p]
      if not s then return nil end
      return { readAll = function() return s end, readLine = function() return s:match("^[^\n]*") end,
               close = function() end }
    end
    local buf = {}
    return { write = function(x) buf[#buf + 1] = x end, close = function() F.files[p] = table.concat(buf) end }
  end
  return F
end
local src = {}
for _, f in ipairs(N.FILES) do src["src/" .. f] = "-- " .. f end
src["src/startup.lua"] = "-- startup"
local function copy(t) local o = {} for k, v in pairs(t) do o[k] = v end return o end
local fsys = fakeFs(copy(src))
check("a blank computer", N.inspect(fsys, "disk").kind == "blank")
local KH = string.rep("ab", 32)
local okI, nI = N.install(fsys, "disk", { rec = good, keyHex = KH, src = "src", version = "abc1234" })
check("installed: every file, the tower's startup as its own, role nav, running nav", okI and nI == #N.FILES + 1
  and fsys.files["disk/startup.lua"] == "-- startup" and fsys.files["disk/.role"] == "nav\n"
  and fsys.files["disk/.autorun"] == "nav\n"
  and fsys.files["disk/lib/navui.lua"] == "-- lib/navui.lua" and fsys.files["disk/ccryptolib/internal/hw.lua"])
check("its identity, key and build", fsys.files["disk/.navkey"] == KH .. "\n"
  and N.parseUnitFile(fsys.files["disk/.nav"]).call == "FALCON ONE" and fsys.files["disk/.commit"] == "abc1234\n")
check("nothing of a pass on it", fsys.files["disk/.pass"] == nil and fsys.files["disk/.kiosk"] == nil)
local seen = N.inspect(fsys, "disk")
check("then it is a unit, and knows which", seen.kind == "unit" and seen.me.unit == "nav-0001" and seen.me.n == 1)
fsys.files["disk/.navkey.ctr"] = "128"
fsys.files["disk/junk.txt"] = "x"
check("an update keeps the key and its counter", N.install(fsys, "disk", { rec = good, src = "src" })
  and fsys.files["disk/.navkey"] == KH .. "\n" and fsys.files["disk/.navkey.ctr"] == "128"
  and fsys.files["disk/junk.txt"] == nil)
check("a new key resets the counter", N.install(fsys, "disk", { rec = good, keyHex = string.rep("cd", 32), src = "src" })
  and fsys.files["disk/.navkey.ctr"] == nil)
local devFs = fakeFs({ ["disk/.fleetkeys"] = "x", ["disk/ops.lua"] = "x" })
check("CINDER's own machines are refused", N.inspect(devFs, "disk").kind == "dev")
check("a customer's pass is not a unit", N.inspect(fakeFs({ ["disk/.pass"] = "sam" }), "disk").kind == "pass")
check("any role but nav is one of CINDER's machines", N.inspect(fakeFs({ ["disk/.role"] = "drone\n" }), "disk").kind == "dev")
check("so is a display-only centre", N.inspect(fakeFs({ ["disk/.role"] = "centre" }), "disk").kind == "dev")
check("and a centre's key alone gives one away", N.inspect(fakeFs({ ["disk/.centrekey"] = "x" }), "disk").kind == "dev")
-- the files a unit is made with are exactly what it pulls afterwards
local MAN = assert(loadstring(assert(io.open(DIR .. "/../manifest.lua")):read("*a")))()
local inMan, inFiles, gap = {}, {}, {}
for _, f in ipairs(MAN.nav or {}) do inMan[f] = true end
for _, f in ipairs(N.FILES) do inFiles[f] = true if not inMan[f] then gap[#gap + 1] = "manifest lacks " .. f end end
for f in pairs(inMan) do if f ~= "startup.lua" and not inFiles[f] then gap[#gap + 1] = "N.FILES lacks " .. f end end
check("the manifest's nav role is N.FILES plus startup.lua", inMan["startup.lua"] and #gap == 0, table.concat(gap, ", "))
check("and has nothing that uploads or holds keys for others",
  not inMan["upload.lua"] and not inMan["machine.lua"] and not inMan["seckey.lua"] and not inMan["paste.lua"])
check("somebody's files", N.inspect(fakeFs({ ["disk/game.lua"] = "x" }), "disk").kind == "other")
local missing = fakeFs({ ["disk/keep.lua"] = "mine", ["src/nav.lua"] = "x" })
local okM, whyM = N.install(missing, "disk", { rec = good, keyHex = KH, src = "src" })
check("a missing source file stops it before anything is deleted", not okM and whyM:find("missing", 1, true)
  and missing.files["disk/keep.lua"] == "mine")
check("no key on the unit and none given is refused", not N.install(fakeFs(copy(src)), "disk", { rec = good, src = "src" }))

print("the owner, off the seat")
check("a seated player's name", N.seatName("alex_r") == "alex_r")
check("trimmed, colour codes stripped", N.seatName("  \194\1676alex_r ") == "alex_r", tostring(N.seatName("  \194\1676alex_r ")))
check("an empty seat is no one", N.seatName("") == nil and select(2, N.seatName("")) == "seat empty")
check("nor is anything that is not a player name", N.seatName("Iron Golem") == nil and N.seatName("ab") == nil)
check("how the owner was known is kept", N.checkRecord({ n = 1, unit = N.unitId(1), owner = "alex_r", idby = "seat",
  call = "X1", kind = "air" }).idby == "seat")

print("CINDER's own units, from the base's feed")
local cts = {}
local cu = N.cinderContact(cts, { unit = "drone-1", x = 100, y = 120, z = 50, spd = 30, hdg = 90, vx = 30, vz = 0,
  phase = "cruise" }, "LAMBDA-001", 10)
check("a CINDER unit becomes a contact, number 0, named", cu and cts["cinder:drone-1"] == cu and cu.n == 0
  and cu.call == "LAMBDA-001" and cu.cinder and cu.st == "move" and cu.vx == 30)
check("shown as CINDER, not a registration", N.regOf(cu) == "CINDER" and N.regOf({ n = 7 }) == N.regNumber(7))
local near = { unit = "nav-0001", x = 300, y = 120, z = 50, vx = 0, vz = 0 }
local tr = N.traffic(cts, near, 12)
check("other units are told of it as traffic", #tr == 1 and tr[1].reg == "CINDER" and tr[1].call == "LAMBDA-001")
N.cinderContact(cts, { unit = "drone-2", x = 0, z = 0, phase = "sos" }, "LAMBDA-002", 60)
N.dropCinder(cts, 80)
check("not heard for a minute: off the picture; the fresh one stays", cts["cinder:drone-1"] == nil
  and cts["cinder:drone-2"] ~= nil and cts["cinder:drone-2"].st == "sos")
cts.reg1 = { unit = "nav-0003", n = 3, x = 0, z = 0, t = 80 }
N.dropCinder(cts)
check("stealth: every CINDER unit gone at once, registered craft untouched", cts["cinder:drone-2"] == nil
  and cts.reg1 ~= nil)
local pc = N.parsePicture(N.picture({ a = N.cinderContact({}, { unit = "drone-1", x = 5, z = 6 }, "LAMBDA-001", 1) },
  {}, 2), 2)
check("a centre's picture carries it, and shows it as CINDER", pc.contacts[1] and pc.contacts[1].n == 0
  and N.regOf(pc.contacts[1]) == "CINDER" and pc.contacts[1].call == "LAMBDA-001")

print("the registration kiosk")
local KL = dofile(DIR .. "/../lib/navkiosk.lua")
local KUI = dofile(DIR .. "/../lib/kioskui.lua")
local function fakeKiosk()
  local f = { t = 0, who = nil, disk = nil, regs = {}, ejected = 0, kits = 3, made = nil, refreshed = nil, apps = {} }
  f.io = {
    seated = function() return f.who end,
    drive = function() return f.disk end,
    eject = function() f.ejected = f.ejected + 1 f.disk = nil end,
    find = function(unit) for _, r in ipairs(f.regs) do if r.unit == unit then return r end end end,
    count = function(owner)
      local n = 0
      for _, r in ipairs(f.regs) do if r.owner == owner and not r.revoked then n = n + 1 end end
      return n
    end,
    nextReg = function() return N.regNumber(#f.regs + 1) end,
    stock = function() return f.kits end,
    callFree = function(call, except) return N.callFree(f.regs, call, except) end,
    kit = function(owner, kind, call)
      f.made = { owner = owner, kind = kind, call = call }
      f.kits = f.kits - 1
      local rec = { n = #f.regs + 1, unit = N.unitId(#f.regs + 1), owner = owner, kind = kind, call = call }
      rec.reg = N.regNumber(rec.n)
      f.regs[#f.regs + 1] = rec
      return rec
    end,
    refresh = function(unit, kind, call)
      f.refreshed = { unit = unit, kind = kind, call = call }
      local r = f.io.find(unit)
      return { reg = r.reg, call = call or r.call }
    end,
    validCentre = N.validCentre,
    apply = function(owner, name, x, z)
      for _, a in ipairs(f.apps) do if a.who == owner then return nil, "YOU HAVE AN APPLICATION WAITING" end end
      f.apps[#f.apps + 1] = { who = owner, name = name, x = x, z = z }
      return true
    end,
    now = function() return f.t end,
  }
  f.k = KL.new(f.io)
  return f
end
local kf = fakeKiosk()
kf.k:tick()
check("nobody seated: the attract screen", kf.k.view.state == "attract")
kf.who = "alex_r" kf.k:tick()
check("someone sits: welcome, by name, with the kits in stock", kf.k.view.state == "hello"
  and kf.k.view.who == "alex_r" and kf.k.view.stock == 3)
kf.k:touch("register")
check("register: straight to the vehicle type - the kit brings the computer", kf.k.view.state == "type")
kf.k:touch("kind:air")
check("the type chosen: on to the callsign", kf.k.view.state == "callsign" and kf.k.view.kind == "air")
for _, ch in ipairs({ "F", "A", "L", "C", "O", "N", " ", " ", "1" }) do kf.k:touch("key:" .. ch) end
check("typed on the screen, no double spaces", kf.k.view.call == "FALCON 1", kf.k.view.call)
kf.k:touch("del") kf.k:touch("key:2")
check("delete takes the last one off", kf.k.view.call == "FALCON 2")
kf.k:touch("next")
check("next: the confirm screen, with the registration it will get", kf.k.view.state == "confirm"
  and kf.k.view.reg == "CR-0001" and kf.k.view.who == "alex_r")
kf.k:touch("register")
check("register: the kit made in the seated player's name", kf.made and kf.made.owner == "alex_r"
  and kf.made.kind == "air" and kf.made.call == "FALCON 2" and kf.k.view.state == "done" and kf.k.view.kit
  and kf.k.view.reg == "CR-0001")
kf.k:touch("done")
check("done: back to the welcome", kf.k.view.state == "hello")
-- the callsign is now taken
kf.k:touch("register") kf.k:touch("kind:land")
for _, ch in ipairs({ "F", "A", "L", "C", "O", "N", " ", "2" }) do kf.k:touch("key:" .. ch) end
kf.k:touch("next")
check("a callsign already in use is refused, and says by whom", kf.k.view.state == "callsign"
  and kf.k.view.note == "TAKEN BY CR-0001", kf.k.view.note)
for _ = 1, 8 do kf.k:touch("del") end
for _, ch in ipairs({ "L", "A", "M", "B", "D", "A", "-", "9" }) do kf.k:touch("key:" .. ch) end
kf.k:touch("next")
check("so is one of CINDER's names", kf.k.view.note == "RESERVED FOR CINDER", kf.k.view.note)
kf.k:touch("back") kf.k:touch("back")
check("back, back: the welcome", kf.k.view.state == "hello")
-- their unit back in the drive
kf.disk = { kind = "unit", me = { unit = "nav-0001" } } kf.k:tick()
check("their own unit in the drive: update or change it", kf.k.view.state == "mine" and kf.k.view.unit.reg == "CR-0001")
kf.k:touch("change") kf.k:touch("kind:sea") kf.k:touch("del") kf.k:touch("key:3") kf.k:touch("next")
check("changing it keeps its registration, its own callsign is no clash", kf.k.view.state == "confirm"
  and kf.k.view.reg == "CR-0001")
kf.k:touch("register")
check("...and only changes it", kf.refreshed and kf.refreshed.unit == "nav-0001" and kf.refreshed.kind == "sea"
  and kf.refreshed.call == "FALCON 3" and #kf.regs == 1 and kf.k.view.updated)
kf.k:touch("done") kf.disk = nil kf.k:tick()
kf.disk = { kind = "blank" } kf.k:tick()
check("anything else in the drive: asked to take it out", kf.k.view.drive == "other")
kf.k:touch("register")
check("...before a kit is made", kf.k.view.state == "error" and kf.k.view.msg[1]:find("OUT OF THE DRIVE", 1, true))
kf.k:touch("done") kf.disk = nil
kf.kits = 0 kf.k:tick() kf.k:touch("register")
check("no kits in stock: said so, nothing started", kf.k.view.state == "error"
  and kf.k.view.msg[1]:find("OUT OF STOCK", 1, true))
kf.k:touch("done") kf.kits = 3
-- hosting a traffic centre
kf.k:tick() kf.k:touch("apply")
check("apply: the centre's name first", kf.k.view.state == "appname")
for _, ch in ipairs({ "N", "O", "R", "T", "H" }) do kf.k:touch("key:" .. ch) end
kf.k:touch("next")
check("then where", kf.k.view.state == "appwhere" and kf.k.view.appName == "NORTH")
for _, ch in ipairs({ "1", "2", "0", "0", " ", "-", "4", "0", "0" }) do kf.k:touch("key:" .. ch) end
kf.k:touch("next")
check("X and Z read off what was typed", kf.k.view.state == "appconfirm" and kf.k.view.x == 1200 and kf.k.view.z == -400)
kf.k:touch("send")
check("sent: recorded for CINDER to review", kf.k.view.state == "appdone" and kf.apps[1] and kf.apps[1].name == "NORTH"
  and kf.apps[1].who == "alex_r")
kf.k:touch("done") kf.k:touch("apply")
for _, ch in ipairs({ "E", "A", "S", "T" }) do kf.k:touch("key:" .. ch) end
kf.k:touch("next")
for _, ch in ipairs({ "1", " ", "2" }) do kf.k:touch("key:" .. ch) end
kf.k:touch("next") kf.k:touch("send")
check("one application at a time", kf.k.view.state == "error" and kf.k.view.msg[2]:find("WAITING", 1, true))
kf.who = "sam_k" kf.disk = { kind = "unit", me = { unit = "nav-0001" } } kf.k:tick()
check("someone else's unit: refused, said so", kf.k.view.state == "hello" and kf.k.view.drive == "theirs"
  and kf.k.view.who == "sam_k")
kf.who = nil kf.t = 1 kf.k:tick() kf.t = 5 kf.k:tick()
check("the seat empty a few seconds: back to the start", kf.k.view.state == "attract")
local lim = fakeKiosk()
for i = 1, KL.MAX_PER_OWNER do lim.regs[i] = { n = i, unit = N.unitId(i), owner = "alex_r", reg = N.regNumber(i) } end
lim.who = "alex_r"
lim.k:tick() lim.k:touch("register")
check("a player at the limit is sent to a CINDER operator", lim.k.view.state == "error"
  and tostring(lim.k.view.msg[1]):find("5 UNITS", 1, true))
local idle = fakeKiosk()
idle.who = "alex_r"
idle.k:tick() idle.k:touch("register") idle.k:touch("kind:land")
idle.t = KL.IDLE + 1 idle.k:tick()
check("walked off part-way (still seated): back to the welcome", idle.k.view.state == "hello")
check("callsigns: free, taken, reserved", N.callFree({}, "falcon one") == "FALCON ONE"
  and select(2, N.callFree({ { n = 4, unit = "nav-0004", call = "FALCON ONE" } }, " falcon  one")) == "TAKEN BY CR-0004"
  and N.callFree({ { n = 4, unit = "nav-0004", call = "FALCON ONE" } }, "FALCON ONE", "nav-0004") == "FALCON ONE"
  and N.callFree({ { n = 4, unit = "nav-0004", call = "FALCON ONE", revoked = "x" } }, "FALCON ONE") == "FALCON ONE"
  and select(2, N.callFree({}, "cinder 1")) == "RESERVED FOR CINDER")
check("kits counted from a chest: the scarcest part decides", N.kitsIn({
  { name = "computercraft:computer_advanced", count = 3 }, { name = "computercraft:monitor_advanced", count = 5 },
  { name = "computercraft:wireless_modem_advanced", count = 9 } }) == 2)
check("the parts of a kit, the short ones first", N.kitParts({ { name = "computercraft:monitor_advanced", count = 4 },
  { name = "computercraft:wireless_modem_normal", count = 3 } })
  == "advanced computers 0/1, ender modems 0/1, advanced monitors 4/2")
local apps = N.parseApps(N.appsText({ { n = 1, when = 5, who = "alex_r", name = "NORTH", x = 1200, z = -400, status = "pending" } }))
check("applications survive their file", apps[1] and apps[1].name == "NORTH" and apps[1].z == -400 and apps[1].status == "pending")
local hitsK = KUI.render(T, D.canvas(57, 24), { state = "type", who = "alex_r" })
check("the screen's buttons are where a touch finds them", KUI.hit(hitsK, 3, 6) == "kind:air"
  and KUI.hit(hitsK, 1, 1) == nil)
local kb = KUI.render(T, D.canvas(57, 24), { state = "callsign", who = "alex_r", call = "" })
local keysFound = 0
for _, h in ipairs(kb) do if h.id:match("^key:") then keysFound = keysFound + 1 end end
check("the keyboard: every letter, digit, dash and space", keysFound == 38, keysFound)
local nb = KUI.render(T, D.canvas(57, 24), { state = "appwhere", who = "alex_r", text = "" })
local numKeys = 0
for _, h in ipairs(nb) do if h.id:match("^key:") then numKeys = numKeys + 1 end end
check("a place is typed on digits, minus and space only", numKeys == 12, numKeys)

print("the screen")
local function shot(w, h, view, page)
  local c = D.canvas(w, h)
  local hit = UI.render(T, c, view, page)
  local rows = {}
  for y = 1, h do rows[y] = (c:row(y)):gsub("[\128-\255]", " ") end
  return table.concat(rows, "\n"), hit, c
end
local function view(kind, extra)
  local v = { me = { reg = "CR-0001", call = "FALCON", kind = kind },
              r = N.reading({ x = 812, y = 147, z = -3300 }, { x = 30, y = 1.5, z = -40 }),
              link = "contact", craft = true,
              traffic = { { call = "HAWK", reg = "CR-0002", kind = "air", brg = 10, dist = 320, dy = 4, warn = false } } }
  for k, v2 in pairs(extra or {}) do v[k] = v2 end
  return v
end
for _, size in ipairs({ { 15, 10 }, { 36, 10 }, { 57, 10 }, { 36, 24 }, { 57, 24 }, { 15, 24 } }) do
  for _, kind in ipairs(N.TYPE_ORDER) do
    local okR, txt, hit = pcall(shot, size[1], size[2], view(kind))
    if not okR then check(string.format("%s at %dx%d draws", kind, size[1], size[2]), false, txt) break end
    if kind == "air" and size[1] == 36 and size[2] == 10 then
      check("a strip: CINDER NAV, the registration, speed, height, heading, climb",
        txt:find("CINDER NAV", 1, true) and txt:find("CR-0001", 1, true) and txt:find("SPD B/S", 1, true)
        and txt:find("ALT", 1, true) and txt:find("HDG 037", 1, true) and txt:find("V/S +1.5", 1, true), txt)
      check("...the tower link and the distress key on the bottom row", txt:find("TOWER CONTACT", 1, true)
        and hit.sos and hit.sos.y == 10 and txt:sub(-20):find("SOS", 1, true), txt)
      check("...and the nearest traffic", txt:find("TRAFFIC 1  NEAREST HAWK 320", 1, true), txt)
    end
  end
end
local subTxt = shot(36, 10, view("sub"))
check("a submarine shows depth", subTxt:find("DEPTH", 1, true) and not subTxt:find("ALT", 1, true), subTxt)
local boatTxt = shot(36, 10, view("sea"))
check("a boat shows heading big and its position", boatTxt:find("HDG", 1, true) and boatTxt:find("POS 812 -3300", 1, true), boatTxt)
print("pages")
check("an aircraft's block cycles speed, the altimeter, heading, radar, status", table.concat(UI.pages("air", 15), ",")
  == "speed,altimeter,heading,radar,status")
check("each kind has its own gauge", UI.pages("land", 15)[1] == "speedo" and UI.pages("sub", 15)[2] == "depth"
  and UI.pages("sea", 15)[2] == "compass")
check("the attitude page is switched off for now", not UI.SHOW_ATTITUDE
  and not table.concat(UI.pages("air", 36), ","):find("attitude", 1, true))
UI.SHOW_ATTITUDE = true
check("...and switched on, every kind has it after its first gauge", UI.pages("air", 15)[2] == "attitude"
  and UI.pages("land", 15)[2] == "attitude" and UI.pages("sea", 15)[2] == "attitude" and UI.pages("sub", 15)[3] == "attitude")
UI.SHOW_ATTITUDE = false
check("a wide one starts on the overview", UI.pages("air", 36)[1] == "overview" and #UI.pages("air", 36) == 6)
check("a boat has no height page", table.concat(UI.pages("sea", 15), ",") == "speed,compass,radar,status")
check("a land vehicle puts heading before height", UI.pages("land", 15)[2] == "heading")
check("the next page, and round again", UI.nextPage("air", 15, "speed") == "altimeter"
  and UI.nextPage("air", 15, "status") == "speed" and UI.nextPage("air", 15, "nonsense") == "speed")
local sp = shot(15, 10, view("air"), "speed")
check("speed: the title, which page of how many, B/S, heading under it, the key", sp:find("SPEED", 1, true)
  and sp:find("1/5", 1, true) and sp:find("B/S", 1, true) and sp:find("HDG 037", 1, true)
  and sp:find("TOWER", 1, true) and sp:find("SOS", 1, true), sp)
local ht = shot(15, 10, view("air"), "altimeter")
check("the altimeter: a dial, Y in figures in it, the climb under it", ht:find("ALTIMETER", 1, true)
  and ht:find("2/5", 1, true) and ht:find("147", 1, true) and ht:find("V/S +1.5", 1, true), ht)
local dp = shot(15, 10, view("sub"), "depth")
check("a submarine's depth gauge, with the depth in figures", dp:find("DEPTH", 1, true)
  and dp:find(tostring(N.SEA_LEVEL - 147 > 0 and (N.SEA_LEVEL - 147) or "SURF"), 1, true), dp)
local lv = shot(15, 10, view("land"), "speedo")
check("a land vehicle's speedometer: its full scale and the speed in figures", lv:find("SPEED", 1, true)
  and lv:find("/", 1, true) and lv:find("HDG 037", 1, true), lv)
check("...and its height page is still there", shot(15, 10, view("land"), "height"):find("ALTITUDE", 1, true))
local cp = shot(15, 10, view("sea"), "compass")
check("a vessel's compass: N on the ring, the heading in figures, the point in words", cp:find("COMPASS", 1, true)
  and cp:find("N", 1, true) and cp:find("037", 1, true) and cp:find("NORTHEAST", 1, true), cp)
local hd = shot(15, 10, view("air"), "heading")
check("heading: the compass point in words", hd:find("HEADING", 1, true) and hd:find("NORTHEAST", 1, true), hd)
local high = shot(15, 10, view("air", { r = N.reading({ x = 0, y = 1079, z = 0 }, nil) }), "altimeter")
check("a four-figure height still fits a block", high:find("1079", 1, true), high)
local st = shot(15, 10, view("air", { centres = N.centresFrom(N.reading({ x = 812, y = 147, z = -3300 }, nil),
  { { name = "CHI", x = 2000, y = 70, z = -3300 }, { name = "NORTH", x = 812, y = 80, z = -9000 } }) }), "status")
check("status: callsign, type, tower, traffic, the nearest centre and its direction", st:find("FALCON", 1, true)
  and st:find("AIRCRAFT", 1, true) and st:find("TOWER CONTACT", 1, true) and st:find("TRAFFIC 1", 1, true)
  and st:find("CHI 1.2K E", 1, true) and st:find("CR-0001", 1, true), st)
local stNone = shot(15, 10, view("air"), "status")
check("...or says it knows of none", stNone:find("NO CENTRE KNOWN", 1, true), stNone)
local function pixelsOf(c, col)
  local n = 0
  for _, v in pairs(c.px) do if v == col then n = n + 1 end end
  return n
end
local _, _, rc = shot(15, 10, view("air", { traffic = { { call = "HAWK", brg = 0, dist = 500, dy = 0, warn = true },
  { call = "BARGE", brg = 180, dist = 900, dy = 0 } },
  centres = { { name = "CHI", brg = 90, dist = 400 }, { name = "FAR", brg = 0, dist = 5000 } } }), "radar")
local rt = shot(15, 10, view("air"), "radar")
check("radar: RADAR and its range in the title", rt:find("RADAR", 1, true) and rt:find("1K", 1, true), rt)
check("...a ring, you, a dot per vehicle (warned in rust), centres in green, nothing past the ring",
  pixelsOf(rc, T.C.rule) > 20 and pixelsOf(rc, T.C.warn) == 4 and pixelsOf(rc, T.C.ok) == 4
  and pixelsOf(rc, T.C.text) >= 9)
local rl = shot(15, 10, view("air", { link = "none", traffic = {} }), "radar")
check("...and NO TOWER when it has no picture", rl:find("NO TOWER", 1, true), rl)
local adv = shot(15, 10, view("air", { adv = "TRAFFIC 12 O'CLOCK 300 SAME LEVEL" }), "speed")
check("an advisory on every page, shortened to fit a block", adv:find("TFC 12H 300", 1, true), adv)
local advR = shot(15, 10, view("air", { adv = "TRAFFIC 12 O'CLOCK 300 SAME LEVEL" }), "radar")
check("...the radar too", advR:find("TFC 12H 300", 1, true), advR)
for _, kind in ipairs(N.TYPE_ORDER) do
  for _, w in ipairs({ 15, 36, 57 }) do
    for _, page in ipairs(UI.pages(kind, w)) do
      for _, h in ipairs({ 10, 24, 38 }) do
        local okP, txt, hit = pcall(shot, w, h, view(kind), page)
        if not (okP and hit.sos and hit.sos.y == h and hit.page == page) then
          check(string.format("%s %s at %dx%d draws with the key", kind, page, w, h), false, txt)
        end
      end
    end
  end
end
check("every page of every vehicle draws at every size, with the key on its bottom row", true)
local def = shot(36, 10, view("air"))
check("no page given: a wide screen shows the overview", def:find("CINDER NAV", 1, true) and def:find("SPD B/S", 1, true), def)
local panel = shot(36, 24, view("air", { traffic = { { call = "HAWK", reg = "CR-0002", kind = "air", brg = 90,
  dist = 1200, dy = -20, warn = true } }, adv = "TRAFFIC 3 O'CLOCK 1.2K BELOW" }))
check("a panel lists traffic by clock, distance and height", panel:find("HAWK", 1, true) and panel:find("1.2K", 1, true)
  and panel:find("-20", 1, true) and panel:find("TRAFFIC 3 O'CLOCK 1.2K BELOW", 1, true), panel)
local lost = shot(36, 10, view("air", { link = "none", traffic = {} }))
check("no tower: said plainly", lost:find("NO TOWER CONTACT", 1, true) and lost:find("NO TRAFFIC PICTURE", 1, true), lost)
local armed = shot(36, 10, view("air", { sos = "armed" }))
check("the key asks for a second touch", armed:find("TOUCH AGAIN", 1, true), armed)
check("a touch on the key, and not elsewhere", UI.onSos({ sos = { x1 = 30, x2 = 36, y = 10 } }, 33, 10)
  and not UI.onSos({ sos = { x1 = 30, x2 = 36, y = 10 } }, 5, 10))
local unreg = shot(36, 10, { me = { kind = "air" }, unregistered = true })
check("unregistered says where to take it", unreg:find("UNREGISTERED", 1, true) and unreg:find("TAKE THIS UNIT TO CINDER", 1, true), unreg)
local still = shot(36, 10, view("air", { r = N.reading({ x = 0, y = 70, z = 0 }, nil), craft = false }))
check("not on a vehicle: the setup page says so, and what to do", still:find("SET UP", 1, true)
  and still:find("NOT ON A VEHICLE", 1, true) and still:find("PLACE THE COMPUTER ON YOUR CRAFT", 1, true), still)

print("a unit that teaches itself")
local bare = shot(15, 10, view("air", { noRadio = true, craft = false, noTouch = true }))
check("everything missing, on one block: each problem and its fix", bare:find("NO ENDER", 1, true)
  and bare:find("MODEM", 1, true) and bare:find("+2", 1, true), bare)
local noModem = shot(36, 10, view("air", { noRadio = true }))
check("no ender modem: says to put one on the computer", noModem:find("NO ENDER MODEM", 1, true)
  and noModem:find("PUT ONE ON THE COMPUTER", 1, true) and not noModem:find("B/S", 1, true), noModem)
local noTouch = shot(36, 10, view("air", { noTouch = true }))
check("only plain monitors: SOS needs an advanced one", noTouch:find("SOS NEEDS AN ADVANCED MONITOR", 1, true), noTouch)
check("fitted right: no problems", #UI.problems(view("air")) == 0)
local function shotOpts(w, h, v, page, opts)
  local c = D.canvas(w, h)
  UI.render(T, c, v, page, opts)
  local rows = {}
  for y = 1, h do rows[y] = (c:row(y)):gsub("[\128-\255]", " ") end
  return table.concat(rows, "\n")
end
local untouched = shotOpts(15, 10, view("air"), "speed", { hint = true })
check("a screen never touched says TAP (TOUCH when wide) where its page number goes", untouched:find("TAP", 1, true)
  and not untouched:find("1/5", 1, true), untouched)
check("once touched, the page number", shotOpts(15, 10, view("air"), "speed", {}):find("1/5", 1, true))

print("attitude")
local function qAxis(ax, ay, az, deg)
  local h = math.rad(deg) / 2
  return { x = ax * math.sin(h), y = ay * math.sin(h), z = az * math.sin(h), w = math.cos(h) }
end
check("Sable's orientation is an Advanced Math object: .a and .v", N.quat({ a = 1, v = { x = 0, y = 0, z = 0 } }).w == 1
  and N.quat({ x = 0, y = 0, z = 0, w = 2 }).w == 1 and N.quat({ x = 0, y = 0, z = 0, w = 0 }) == nil
  and N.quat(nil) == nil and N.quat({ a = 0 / 0, v = { x = 0, y = 0, z = 0 } }) == nil)
local function near(a, b) return a and abs(a - b) < 0.01 end
local p0, r0 = N.attitude(qAxis(0, 1, 0, 0), "-z")
check("level as built: pitch 0, roll 0", near(p0, 0) and near(r0, 0), tostring(p0) .. " " .. tostring(r0))
local p1, r1 = N.attitude(qAxis(1, 0, 0, 20), "-z")
check("nose -z turned 20 about x: pitch up 20", near(p1, 20) and near(r1, 0), tostring(p1) .. " " .. tostring(r1))
local p2, r2 = N.attitude(qAxis(0, 0, 1, -30), "-z")
check("...30 about z the other way: right wing down 30", near(p2, 0) and near(r2, 30), tostring(p2) .. " " .. tostring(r2))
local p3, r3 = N.attitude(qAxis(0, 0, 1, -30), "+x")
check("the same turn on a craft built nose east: pitch 30 down, no roll", near(p3, -30) and near(r3, 0),
  tostring(p3) .. " " .. tostring(r3))
local yawed = qAxis(0, 1, 0, 90)
local p4, r4 = N.attitude(yawed, "-z")
check("yaw alone is neither pitch nor roll", near(p4, 0) and near(r4, 0))
local _, r5 = N.attitude(qAxis(0, 0, 1, 180), "-z")
check("upside down: roll 180", near(abs(r5), 180), r5)
check("no nose, no attitude", N.attitude(yawed, nil) == nil)

local st = N.noseState(nil)
for _ = 1, 19 do N.noseVote(st, qAxis(0, 1, 0, 0), { x = 0, y = 0, z = -10 }) end
check("still learning after 19 samples forward", st.nose == nil)
N.noseVote(st, qAxis(0, 1, 0, 0), { x = 0, y = 0, z = -10 })
check("20 samples going -z: the nose is -z", st.nose == "-z", st.nose)
local st2 = N.noseState(nil)
for _ = 1, 25 do N.noseVote(st2, yawed, { x = -10, y = 0, z = 0 }) end
check("turned 90 and going west: still the craft's own -z", st2.nose == "-z", st2.nose)
local st3 = N.noseState(nil)
for _ = 1, 40 do N.noseVote(st3, qAxis(0, 1, 0, 0), { x = 1, y = -20, z = 1 }) end
for _ = 1, 40 do N.noseVote(st3, qAxis(0, 1, 0, 0), { x = 7, y = 0, z = 7 }) end
check("straight down or diagonal: no vote", st3.nose == nil and st3.total == 0)
local st4 = N.noseState("+x")
for _ = 1, 10 do N.noseVote(st4, qAxis(0, 1, 0, 0), { x = 0, y = 0, z = -10 }) end
check("a remembered nose holds against a little reversing", st4.nose == "+x")
for _ = 1, 200 do N.noseVote(st4, qAxis(0, 1, 0, 0), { x = 0, y = 0, z = -10 }) end
check("...but a craft that clearly goes another way relearns", st4.nose == "-z", st4.nose)

print("more from Sable: the nose's heading, the turn, the weight")
local function nearly(a, b, tol) return a and math.abs(a - b) < (tol or 0.01) end
local qId = qAxis(0, 1, 0, 0)
check("the nose's heading: built north, level - 0", nearly(N.noseHeading(qId, "-z"), 0))
check("...built east - 90", nearly(N.noseHeading(qId, "+x"), 90))
check("...turned 90 left - 270", nearly(N.noseHeading(qAxis(0, 1, 0, 90), "-z"), 270), N.noseHeading(qAxis(0, 1, 0, 90), "-z"))
check("...no nose, no heading", N.noseHeading(qId, nil) == nil)
check("the turn: spinning left about the vertical is minus", nearly(N.turnRate(qId, { x = 0, y = 0.1, z = 0 }), -5.7296))
check("...the spin is in the craft's frame: banked 30, a spin about its own up is less of a turn",
  nearly(N.turnRate(qAxis(0, 0, 1, -30), { x = 0, y = -0.1, z = 0 }), 5.7296 * math.cos(math.rad(30)), 0.01))
check("...no orientation, no turn", N.turnRate(nil, { x = 0, y = 1, z = 0 }) == nil)
check("weight classes from Sable's mass", N.weightClass(66) == "L" and N.weightClass(1500) == "M"
  and N.weightClass(25000) == "H" and N.weightClass(nil) == nil and N.weightClass(0) == nil)
local ax, az = N.ahead({ x = 0, z = 0, spd = 10, hdg = 90 }, 3)
check("ahead, straight: 30 east in 3 s", nearly(ax, 30) and nearly(az, 0))
local sx, sz, sh = 0, 0, 0
for _ = 1, 3000 do
  sx, sz = sx + 10 * math.sin(math.rad(sh)) * 0.001, sz - 10 * math.cos(math.rad(sh)) * 0.001
  sh = sh + 12 * 0.001
end
local tx2, tz2 = N.ahead({ x = 0, z = 0, spd = 10, hdg = 0, tr = 12 }, 3)
check("ahead, turning: the circle matches a step-by-step path", nearly(tx2, sx, 0.05) and nearly(tz2, sz, 0.05),
  string.format("%.2f %.2f vs %.2f %.2f", tx2, tz2, sx, sz))
local rp = N.reading({ x = 0, y = 70, z = 0 }, { x = 0, y = 0, z = -10 })
rp.nose, rp.tr = 271.4, -3.26
local pp = N.ping(rp)
check("the ping carries the nose's heading and the turn", pp.nh == 271 and pp.tr == -3.3 and N.checkPing(pp) ~= nil)
local still = N.reading({ x = 0, y = 70, z = 0 }, nil)
still.tr = 2
check("...the turn only while it moves", N.ping(still).tr == nil)
local badP = function(f) local q = N.ping(rp) f(q) return N.checkPing(q) == nil end
check("...and the tower refuses nonsense in them", badP(function(q) q.tr = 500 end) and badP(function(q) q.nh = 360 end)
  and badP(function(q) q.mass = "heavy" end))
local tk = {}
local tc = N.track(tk, { unit = "nav-0009", n = 9, call = "KITE", kind = "air" },
  { x = 0, y = 70, z = 0, spd = 10, vs = 0, hdg = 0, nh = 5, tr = 2.5, st = "move", mass = 1500 }, 10)
check("the tower keeps the nose, the turn and the weight class", tc.nh == 5 and tc.tr == 2.5 and tc.wt == "M")
local pic = N.parsePicture(N.picture(tk, {}, 12), 12)
check("a centre's picture carries the turn and the weight class", pic.contacts[1].tr == 2.5 and pic.contacts[1].wt == "M")
local old = N.parsePicture({ type = "nav.pic", ct = "9,KITE,air,0,70,0,10,0,move,2", cn = "" }, 12)
check("...and a master from before them still reads", old.contacts[1] and old.contacts[1].tr == nil
  and old.contacts[1].call == "KITE")
-- a craft circling back at us: straight on it would miss by 100, round its turn it comes through
local circ = { unit = "nav-0010", n = 10, call = "LOOP", kind = "air", x = 100, y = 70, z = 0, spd = 10, hdg = 0,
               vx = 0, vz = -10, tr = -math.deg(10 / 50), t = 10 }
local still2 = { unit = "nav-0011", n = 11, call = "PARK", kind = "air", x = 0, y = 70, z = 0, spd = 0, vx = 0, vz = 0, t = 10 }
local straight = { unit = "nav-0010", n = 10, call = "LOOP", kind = "air", x = 100, y = 70, z = 0, spd = 10, hdg = 0,
                   vx = 0, vz = -10, t = 10 }
check("a turning craft on course to pass close: an advisory",
  N.traffic({ ["nav-0010"] = circ, ["nav-0011"] = still2 }, still2, 10)[1].warn)
check("...the same craft not turning: none",
  not N.traffic({ ["nav-0010"] = straight, ["nav-0011"] = still2 }, still2, 10)[1].warn)
check("clock positions off the nose: traffic due east with the nose east is 12 o'clock",
  N.advisory({ hdg = 0, nh = 90 }, { { warn = true, brg = 90, dist = 100, dy = 0 } }):find("12 O'CLOCK", 1, true)
  and N.advisory({ hdg = 0 }, { { warn = true, brg = 90, dist = 100, dy = 0 } }):find("3 O'CLOCK", 1, true))
local parked = view("air", { r = N.reading({ x = 0, y = 70, z = 0 }, nil) })
parked.r.nose = 268
local hp = shot(15, 10, parked, "heading")
check("the heading page shows where the nose points, parked", hp:find("WEST", 1, true)
  and not hp:find("NOT MOVING", 1, true), hp)

UI.SHOW_ATTITUDE = true            -- the page itself, as it will be when it is switched on
local function attView(kind, pitch, roll, extra)
  local v = view(kind, extra)
  v.att, v.r.pitch, v.r.roll = "ok", pitch, roll
  return v
end
local function skyRows(cv, x)
  local out = {}
  for y = 2, cv.h - 2 do
    local _, _, b = cv:row(y)
    out[#out + 1] = b:sub(x, x)
  end
  return table.concat(out)
end
local at, _, atc = shot(36, 24, attView("air", 0, 0), "attitude")
check("the horizon: the title, the figures under it", at:find("ATTITUDE", 1, true)
  and at:find("PITCH +0  ROLL 0", 1, true), at)
local col = skyRows(atc, 3)
check("...level: sky above, ground below, split in the middle", col:sub(1, 8) == string.rep(T.C.panel, 8)
  and col:sub(-8) == string.rep(T.C.ground, 8), col)
local _, _, up = shot(36, 24, attView("air", 15, 0), "attitude")
local colUp = skyRows(up, 3)
local function skyCount(s) local n = 0 for ch in s:gmatch(".") do if ch == T.C.panel then n = n + 1 end end return n end
check("...nose up: more sky", skyCount(colUp) > skyCount(col), colUp)
local _, _, rb = shot(36, 24, attView("air", 0, 30), "attitude")
check("...right wing down: the ground comes up on the right", skyCount(skyRows(rb, 34)) < skyCount(skyRows(rb, 3)))
local steep = shot(36, 24, attView("air", 5, -65), "attitude")
check("past 60 degrees of bank: it says so", steep:find("BANK ANGLE", 1, true) and steep:find("ROLL 65L", 1, true), steep)
check("a boat calls it heel and trim and minds a list", shot(36, 24, attView("sea", 0, 16), "attitude")
  :find("LIST", 1, true))
check("on a single block: the short figures", shot(15, 10, attView("air", -3, 12), "attitude"):find("P-3 R12R", 1, true))
local learn = shot(36, 10, view("air", { att = "learning" }), "attitude")
check("not knowing the nose yet: says to move ahead", learn:find("LEARNING WHICH WAY IS FORWARD", 1, true)
  and learn:find("MOVE AHEAD", 1, true), learn)
check("no orientation at all: says so", shot(15, 10, view("air", { att = "none" }), "attitude"):find("NO ATTITUDE", 1, true))
UI.SHOW_ATTITUDE = false


print("centres")
check("a centre's name: capitals, letters digits and dashes", N.validCentre(" chi ") == "CHI"
  and N.validCentre("north-2") == "NORTH-2" and not N.validCentre("x") and not N.validCentre("a b")
  and N.centreId("CHI") == "ctr-chi")
local cs2 = N.parseCentres(N.centresString({ { name = "chi", x = 2497.4, y = 70, z = -3297.6 },
  { name = "NORTH", x = 1200, y = 80, z = -400 }, { name = "?", x = 1, y = 1, z = 1 } }))
check("centres round-trip, the bad one dropped", #cs2 == 2 and cs2[1].name == "CHI" and cs2[1].z == -3298
  and cs2[2].x == 1200)
local near = N.centresFrom({ x = 1200, y = 70, z = 0 }, cs2)
check("nearest first, with bearing and distance", near[1].name == "NORTH" and near[1].dist == 400
  and near[1].brg == 0 and near[2].name == "CHI")
check("compass points", N.cardinal(0) == "N" and N.cardinal(44) == "NE" and N.cardinal(181) == "S"
  and N.cardinal(300) == "NW" and N.cardinal(359) == "N")
local cf = N.parseCentreFile(N.centreFile({ name = "NORTH", x = 1200, y = 80, z = -400, master = "CHI" }))
check("a centre's own file", cf and cf.name == "NORTH" and cf.x == 1200 and cf.z == -400 and cf.master == "CHI")
check("...and nonsense is not one", N.parseCentreFile("name=?\n") == nil and N.parseCentreFile(nil) == nil)
local pp = N.parsePong(N.pong({}, nil, { centres = cs2 }))
check("a pong carries the centres", #pp.centres == 2 and pp.centres[1].name == "CHI")
local pcs = {}
N.track(pcs, rec(1, "FALCON"), N.ping(N.reading({ x = 10, y = 90, z = 20 }, { x = 5, y = 0, z = 0 })), 100)
N.track(pcs, rec(2, "HAWK", "sea"), N.ping(N.reading({ x = -50, y = 63, z = 0 }, nil), "sos"), 95)
N.track(pcs, rec(3, "GONE"), N.ping(N.reading({ x = 0, y = 0, z = 0 }, nil)), 100 - N.PIC_AWAY - 10)
local pic = N.picture(pcs, cs2, 100)
local back3 = N.parsePicture(pic, 1000)
check("the master's picture: live and recently away contacts, not long gone", back3 and #back3.contacts == 2
  and #back3.centres == 2, pic.ct)
local byCall = {}
for _, ct in ipairs(back3.contacts) do byCall[ct.call] = ct end
check("...each with position, speed, heading, state, and how long ago", byCall.FALCON and byCall.FALCON.x == 10
  and byCall.FALCON.spd == 5 and byCall.FALCON.hdg == 90 and byCall.FALCON.t == 1000
  and byCall.HAWK.st == "sos" and byCall.HAWK.kind == "sea" and byCall.HAWK.t == 995 and byCall.HAWK.hdg == nil)
check("not a picture is nil", N.parsePicture({ type = "nav.pong" }) == nil)

print("the tower's screens")
local TU = dofile(DIR .. "/../lib/towerui.lua")
check("the radar wants a 3x3 or bigger", TU.wantsRadar(57, 38) and TU.wantsRadar(78, 52) and not TU.wantsRadar(36, 24))
local function tshot(fn, w, h, v)
  local c = D.canvas(w, h)
  TU[fn](T, c, v)
  local rows = {}
  for y = 1, h do rows[y] = (c:row(y)):gsub("[\128-\255]", " ") end
  return table.concat(rows, "\n"), c
end
local tv = { name = "CHI", x = 0, z = 0, range = 2000, now = 100, regs = 4, centres = {
    { name = "CHI", x = 0, z = 0 }, { name = "NORTH", x = 0, z = -1500 }, { name = "FAR", x = 9000, z = 0 } },
  contacts = {
    { n = 1, reg = "CR-0001", call = "FALCON", kind = "air", x = 600, y = 210, z = 300, spd = 80, hdg = 90, st = "move", t = 99,
      wt = "M" },
    { n = 2, reg = "CR-0002", call = "HAWK", kind = "air", x = -900, y = 150, z = 400, spd = 0, st = "sos", t = 98 },
    { n = 3, reg = "CR-0003", call = "OUTSIDE", kind = "sea", x = 5000, y = 63, z = 0, spd = 9, hdg = 0, st = "move", t = 99 },
    { n = 4, reg = "CR-0004", call = "PACKED", kind = "land", x = 100, y = 70, z = 100, spd = 0, st = "park", t = 10 } } }
local hid = {}
for k, v in pairs(tv) do hid[k] = v end
hid.cinder = "stealth"
check("stealth shows on the tower's own screens", tshot("board", 51, 19, hid):find("CINDER HIDDEN", 1, true)
  and tshot("radar", 57, 38, hid):find("CINDER HIDDEN", 1, true))
hid.cinder = "none"
check("and a lost feed from the base", tshot("board", 51, 19, hid):find("NO CINDER FEED", 1, true))
local btxt = tshot("board", 51, 19, tv)
check("the board lists the other centres in range, nearest first, not the far one", btxt:find("CENTRES  NORTH 1.5K N", 1, true)
  and not btxt:find("FAR", 1, true), btxt)
check("...and says so when there are none", tshot("board", 51, 19, { name = "CHI", x = 0, z = 0, range = 2000, now = 1,
  contacts = {}, centres = { { name = "CHI", x = 0, z = 0 } } }):find("CENTRES  NONE IN RANGE", 1, true))
local rtxt, rcan = tshot("radar", 57, 38, tv)
check("the radar: who, the range, how many live", rtxt:find("CINDER TRAFFIC  CHI", 1, true) and rtxt:find("RANGE 2K", 1, true)
  and rtxt:find("3 LIVE", 1, true), rtxt)
check("...north, the rings' ranges, a label for each vehicle on it, distress in red",
  rtxt:find("N", 1, true) and rtxt:find("1K", 1, true) and rtxt:find("FALCON", 1, true)
  and rtxt:find("SOS HAWK", 1, true), rtxt)
check("...other centres in range by name, nothing off the scope or away", rtxt:find("NORTH", 1, true)
  and not rtxt:find("FAR", 1, true) and not rtxt:find("OUTSIDE", 1, true) and not rtxt:find("PACKED", 1, true), rtxt)
local reds = 0
for _, v in pairs(rcan.px) do if v == T.C.accent then reds = reds + 1 end end
check("...the distress dot drawn red", reds == 4, reds)
local unset = tshot("radar", 57, 38, { name = "TOWER", range = 2000, now = 0, contacts = {} })
check("a tower that does not know where it is says how to tell it", unset:find("POSITION IS NOT SET", 1, true)
  and unset:find("tower here", 1, true), unset)
local btxt = tshot("board", 51, 19, tv)
local hawkRow, falconRow, packedRow = btxt:find("CR-0002", 1, true), btxt:find("CR-0001", 1, true), btxt:find("PACKED", 1, true)
check("the board: distress first, then live, then away", hawkRow and falconRow and packedRow
  and hawkRow < falconRow and falconRow < packedRow and btxt:find("AWAY", 1, true)
  and btxt:find("4 REG", 1, true), btxt)
check("...each one's weight class, X and Z on the tower's own screen", btxt:find("CR-0001 FALCON    M  MOVE   80  210    600    300", 1, true)
  and btxt:find("-900    400", 1, true), btxt)
local wideB = tshot("board", 79, 24, tv)
check("...a wide board: type, weight, coordinates and how long ago", wideB:find("AIR  M  MOVE   80   210    600    300    1S", 1, true)
  and wideB:find("1M", 1, true), wideB)
local narrow = tshot("board", 36, 24, tv)
check("...and a narrower one keeps callsign, state, height and where", narrow:find("FALCON     MOVE  210    600    300", 1, true),
  narrow)
local function leadX(tr)
  local _, cv = tshot("radar", 57, 38, { name = "CHI", x = 0, z = 0, range = 2000, now = 100, centres = {},
    contacts = { { n = 1, call = "K", kind = "air", x = 0, y = 70, z = 400, spd = 60, hdg = 0, tr = tr, st = "move", t = 99 } } })
  local sum, n = 0, 0
  for k, v in pairs(cv.px) do if v == T.C.faint then sum, n = sum + ((k - 1) % cv.pw) + 1, n + 1 end end
  return n > 0 and sum / n or 0
end
check("the radar's lead line bends round a right turn", leadX(15) > leadX(0) + 1 and leadX(-15) < leadX(0) - 1,
  string.format("%.1f %.1f %.1f", leadX(-15), leadX(0), leadX(15)))
local fed = tshot("radar", 57, 38, { name = "NORTH", x = 0, z = 0, range = 2000, now = 0, contacts = {}, feed = "none" })
check("a centre that hears nothing from its master says so", fed:find("NO FEED FROM MASTER", 1, true), fed)
print("")
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then error("nav tests failed", 0) end
