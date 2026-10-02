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
check("a one-block screen cycles speed, height, heading, radar, status", table.concat(UI.pages("air", 15), ",")
  == "speed,height,heading,radar,status")
check("a wide one starts on the overview", UI.pages("air", 36)[1] == "overview" and #UI.pages("air", 36) == 6)
check("a boat has no height page", table.concat(UI.pages("sea", 15), ",") == "speed,heading,radar,status")
check("a land vehicle puts heading before height", UI.pages("land", 15)[2] == "heading")
check("the next page, and round again", UI.nextPage("air", 15, "speed") == "height"
  and UI.nextPage("air", 15, "status") == "speed" and UI.nextPage("air", 15, "nonsense") == "speed")
local sp = shot(15, 10, view("air"), "speed")
check("speed: the title, which page of how many, B/S, heading under it, the key", sp:find("SPEED", 1, true)
  and sp:find("1/5", 1, true) and sp:find("B/S", 1, true) and sp:find("HDG 037", 1, true)
  and sp:find("TOWER", 1, true) and sp:find("SOS", 1, true), sp)
local ht = shot(15, 10, view("air"), "height")
check("height: ALTITUDE, Y and the climb", ht:find("ALTITUDE", 1, true) and ht:find("2/5", 1, true)
  and ht:find("V/S +1.5", 1, true), ht)
local dp = shot(15, 10, view("sub"), "height")
check("a submarine's height page is depth below sea", dp:find("DEPTH", 1, true) and dp:find("BELOW SEA", 1, true), dp)
local hd = shot(15, 10, view("air"), "heading")
check("heading: the compass point in words", hd:find("HEADING", 1, true) and hd:find("NORTHEAST", 1, true), hd)
local high = shot(15, 10, view("air", { r = N.reading({ x = 0, y = 1079, z = 0 }, nil) }), "height")
check("a four-figure height still fits a block", high:find("ALTITUDE", 1, true), high)
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
check("no vehicle: says so, heading blank", still:find("NO CRAFT", 1, true) and still:find("HDG ---", 1, true), still)


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
    { n = 1, reg = "CR-0001", call = "FALCON", kind = "air", x = 600, y = 210, z = 300, spd = 80, hdg = 90, st = "move", t = 99 },
    { n = 2, reg = "CR-0002", call = "HAWK", kind = "air", x = -900, y = 150, z = 400, spd = 0, st = "sos", t = 98 },
    { n = 3, reg = "CR-0003", call = "OUTSIDE", kind = "sea", x = 5000, y = 63, z = 0, spd = 9, hdg = 0, st = "move", t = 99 },
    { n = 4, reg = "CR-0004", call = "PACKED", kind = "land", x = 100, y = 70, z = 100, spd = 0, st = "park", t = 10 } } }
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
check("the board: distress first, then live, then away with how long ago", hawkRow and falconRow and packedRow
  and hawkRow < falconRow and falconRow < packedRow and btxt:find("AWAY", 1, true) and btxt:find("1M", 1, true)
  and btxt:find("4 REG", 1, true), btxt)
local narrow = tshot("board", 36, 24, tv)
check("...and a narrower one keeps callsign, state, speed and height", narrow:find("FALCON", 1, true)
  and narrow:find("MOVE", 1, true) and narrow:find("210", 1, true), narrow)
local fed = tshot("radar", 57, 38, { name = "NORTH", x = 0, z = 0, range = 2000, now = 0, contacts = {}, feed = "none" })
check("a centre that hears nothing from its master says so", fed:find("NO FEED FROM MASTER", 1, true), fed)
print("")
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then error("nav tests failed", 0) end
