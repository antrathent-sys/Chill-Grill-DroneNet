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
src["src/kiosk.lua"] = "-- kiosk"
local function copy(t) local o = {} for k, v in pairs(t) do o[k] = v end return o end
local fsys = fakeFs(copy(src))
check("a blank computer", N.inspect(fsys, "disk").kind == "blank")
local KH = string.rep("ab", 32)
local okI, nI = N.install(fsys, "disk", { rec = good, keyHex = KH, src = "src", version = "abc1234" })
check("installed: every file, kiosk as its startup, running nav", okI and nI == #N.FILES + 1
  and fsys.files["disk/startup.lua"] == "-- kiosk" and fsys.files["disk/.kiosk"] == "nav\n"
  and fsys.files["disk/lib/navui.lua"] == "-- lib/navui.lua" and fsys.files["disk/ccryptolib/internal/hw.lua"])
check("its identity, label and key", fsys.files["disk/.pass"] == "nav-0001\n" and fsys.files["disk/.navkey"] == KH .. "\n"
  and N.parseUnitFile(fsys.files["disk/.nav"]).call == "FALCON ONE" and fsys.files["disk/.version"] == "abc1234\n")
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
check("somebody's files", N.inspect(fakeFs({ ["disk/game.lua"] = "x" }), "disk").kind == "other")
local missing = fakeFs({ ["disk/keep.lua"] = "mine", ["src/nav.lua"] = "x" })
local okM, whyM = N.install(missing, "disk", { rec = good, keyHex = KH, src = "src" })
check("a missing source file stops it before anything is deleted", not okM and whyM:find("missing", 1, true)
  and missing.files["disk/keep.lua"] == "mine")
check("no key on the unit and none given is refused", not N.install(fakeFs(copy(src)), "disk", { rec = good, src = "src" }))

print("the screen")
local function shot(w, h, view)
  local c = D.canvas(w, h)
  local hit = UI.render(T, c, view)
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
local tiny = shot(15, 10, view("air"))
check("one block: still speed, height and the key", tiny:find("SPD", 1, true) and tiny:find("ALT", 1, true)
  and tiny:find("147", 1, true) and tiny:find("SOS", 1, true), tiny)
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
check("no vehicle: says so, heading blank", still:find("NO CRAFT", 1, true) and still:find("HDG ---", 1, true), still)

print("")
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then error("nav tests failed", 0) end
