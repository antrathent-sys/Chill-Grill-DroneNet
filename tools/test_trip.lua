-- Desktop tests for lib/trip.lua: an admin's multi-leg trip - the legs, the
-- flights they make, and the base's step by step through them.
local DIR = ...
local pass, fail = 0, 0
local function check(n, c, d)
  if c then pass = pass + 1 print("  ok   " .. n)
  else fail = fail + 1 print("  FAIL " .. n .. (d and ("  " .. tostring(d)) or "")) end
end

local T = dofile(DIR .. "/../lib/trip.lua")

local PLACES = {
  { name = "home", x = 1892, y = 91, z = 365, kind = "dock" },
  { name = "rules", x = -40, y = 70, z = 812, kind = "pad" },
  { name = "market", x = 300, y = 64, z = 40, kind = "pad" },
  { name = "pier", x = 1950, y = 70, z = 400 },          -- no kind: a dock
}

print("legs")
local legs, why = T.parse("stop:rules;stop:Market;stop:home", PLACES)
check("three stops, names any case", legs and #legs == 3 and legs[2].place.name == "market", why)
check("back to the wire string", legs and T.encode(legs) == "stop:rules;stop:market;stop:home")
local function bad(text, want)
  local l, w = T.parse(text, PLACES)
  check("refused: " .. text, l == nil and tostring(w):find(want, 1, true) ~= nil, w)
end
bad("stop:nowhere", "no place called nowhere")
bad("stop:rules;via:market", "last leg must be a stop")
bad("land:rules", "a stop or a via")
bad("rules", "kind:place")
bad("", "no legs")
bad(string.rep("stop:rules;", 9), "8 at most")

print("the flights a trip makes")
local l2 = T.parse("via:rules;via:market;stop:home;stop:rules", PLACES)
local segs = T.segments(l2)
check("vias ride with the stop after them", #segs == 2 and #segs[1].vias == 2 and segs[1].stop.name == "home"
  and #segs[2].vias == 0 and segs[2].stop.name == "rules")
check("a pad is landed on, from the base's own record", T.command({ vias = {}, stop = PLACES[2] }) == "land -40 70 812")
check("a dock is ferried to by name", T.command({ vias = {}, stop = PLACES[1] }) == "ferry home at 1892 91 365"
  and T.command({ vias = {}, stop = PLACES[4] }) == "ferry pier at 1950 70 400")
local c, w = T.command(segs[1])
check("waypoints are refused until fly can fly them", c == nil and tostring(w):find("route mode", 1, true) ~= nil, w)
T.VIAS = true
check("...and then make one route command", T.command(segs[1]) == "route via rules via market ferry home at 1892 91 365",
  T.command(segs[1]))
T.VIAS = false

print("a trip, step by step")
local u = { seen = 0, x = 1892.5, z = 365.5, docked = true }
local trip = T.new("T-1", "drone-1", legs, "alex", 0)
check("first: send the first leg", T.step(trip, u, 1) == "send" and T.command(trip.segs[1]) == "land -40 70 812")
T.sent(trip, 1)
check("sent, still on the dock: nothing yet", T.step(trip, u, 5) == nil and trip.state == "sent")
u.seen, u.docked = 6, false
check("in the air: flying", T.step(trip, u, 6) == nil and trip.state == "flying")
u.seen, u.x, u.z, u.landed = 60, -39.5, 812.5, true
local a, text = T.step(trip, u, 60)
check("down at the stop: waiting for Go, and says so", a == nil and trip.state == "stopped"
  and tostring(text):find("down at rules", 1, true) ~= nil, text)
check("no Go yet: nothing", T.step(trip, u, 120) == nil)
local okGo, whyGo = T.go(trip)
check("Go: on to the next stop", okGo and whyGo:find("market", 1, true) ~= nil, whyGo)
check("...which is sent", T.step(trip, u, 121) == "send" and trip.seg == 2 and T.command(trip.segs[2]) == "land 300 64 40")
T.sent(trip, 121)
u.seen, u.landed = 125, false
T.step(trip, u, 125)
u.seen, u.x, u.z, u.landed = 170, 300.5, 40.5, true
T.step(trip, u, 170)
T.go(trip)
T.step(trip, u, 171) T.sent(trip, 171)
u.seen, u.landed = 175, false
T.step(trip, u, 175)
u.seen, u.x, u.z, u.docked = 240, 1892.5, 365.5, true
local e, done = T.step(trip, u, 240)
check("the last stop ends the trip: done", e == "end" and trip.state == "done" and done:find("home", 1, true) ~= nil, done)

print("when it goes wrong")
local function flying(tr)
  local uu = { seen = 0, x = 1892.5, z = 365.5, docked = true }
  T.step(tr, uu, 0) T.sent(tr, 0)
  uu.seen, uu.docked = 5, false
  T.step(tr, uu, 5)
  return uu
end
local t2 = T.new("T-2", "drone-1", T.parse("stop:rules", PLACES), "alex", 0)
T.step(t2, { seen = 0, docked = true, x = 0, z = 0 }, 0) T.sent(t2, 0)
check("never takes off: failed", T.step(t2, { seen = 70, docked = true, x = 0, z = 0 }, 70) == "end" and t2.state == "failed")
local t3 = T.new("T-3", "drone-1", T.parse("stop:rules", PLACES), "alex", 0)
local u3 = flying(t3)
u3.seen, u3.x, u3.z, u3.landed = 50, 500, 500, true
check("down somewhere else: given a moment", T.step(t3, u3, 50) == nil and t3.state == "flying")
u3.seen = 90
check("...then failed", T.step(t3, u3, 90) == "end" and t3.state == "failed" and t3.why:find("away", 1, true) ~= nil, t3.why)
local t4 = T.new("T-4", "drone-1", T.parse("stop:rules", PLACES), "alex", 0)
local u4 = flying(t4)
u4.sos = true
check("distress: failed", T.step(t4, u4, 10) == "end" and t4.state == "failed")
local t5 = T.new("T-5", "drone-1", T.parse("stop:rules;stop:home", PLACES), "alex", 0)
local u5 = flying(t5)
u5.seen, u5.x, u5.z, u5.landed = 60, -39.5, 812.5, true
T.step(t5, u5, 60)
u5.seen = 700
check("no Go at a stop in 10 min: ended there", T.step(t5, u5, 700) == "end" and t5.state == "ended")

print("cancel")
local t6 = T.new("T-6", "drone-1", T.parse("stop:rules;stop:home", PLACES), "alex", 0)
local okC, whyC, now = T.cancel(t6)
check("before it flies: ends at once", okC and now and t6.state == "cancelled")
local t7 = T.new("T-7", "drone-1", T.parse("stop:rules;stop:home", PLACES), "alex", 0)
local u7 = flying(t7)
local okC7, whyC7 = T.cancel(t7)
check("in the air: ends at this leg's stop", okC7 and whyC7:find("rules", 1, true) ~= nil and t7.state == "flying", whyC7)
u7.seen, u7.x, u7.z, u7.landed = 60, -39.5, 812.5, true
check("...and does, rather than waiting for Go", T.step(t7, u7, 60) == "end" and t7.state == "cancelled")
local t8 = T.new("T-8", "drone-1", T.parse("stop:rules;stop:home", PLACES), "alex", 0)
local u8 = flying(t8)
u8.seen, u8.x, u8.z, u8.landed = 60, -39.5, 812.5, true
T.step(t8, u8, 60)
T.cancel(t8)
check("at a stop: ends at the next look", T.step(t8, u8, 61) == "end" and t8.state == "cancelled")
check("Go is only for a trip at a stop", not T.go(T.new("T-9", "d", T.parse("stop:rules", PLACES), "a", 0)))

print("stopping in the air")
local t10 = T.new("T-10", "drone-1", T.parse("stop:rules;stop:home", PLACES), "alex", 0)
local u10 = flying(t10)
u10.ord, u10.seen, u10.legKind = true, 20, "cruise"
local okS, whyS, overS, actS = T.cancel(t10, u10, 20)
check("a drone that takes orders in the air is told to stop", okS and actS == "stop" and not overS
  and t10.state == "stopping" and whyS:find("hover", 1, true) ~= nil, whyS)
check("braking: still stopping", T.step(t10, u10, 30) == nil and t10.state == "stopping")
u10.seen, u10.legKind, u10.x, u10.z = 40, "wait", 1200.4, 600.7
local aS, tS = T.step(t10, u10, 40)
check("hovering: holding, and says where", aS == nil and t10.state == "holding" and tS:find("1200 600", 1, true) ~= nil, tS)
check("holding: it waits", T.step(t10, u10, 200) == nil and t10.state == "holding")
local okH, whyH, overH, actH = T.cancel(t10, u10, 201)
check("Cancel while holding: home, and the trip is over", okH and overH and actH == "home" and t10.state == "cancelled", whyH)
local t11 = T.new("T-11", "drone-1", T.parse("stop:rules", PLACES), "alex", 0)
local u11 = flying(t11)
u11.ord, u11.seen = true, 20
T.cancel(t11, u11, 20)
u11.seen, u11.legKind = 30, "wait"
T.step(t11, u11, 30)
u11.seen, u11.legKind = 400, "dock"
local eH, whyEH = T.step(t11, u11, 400)
check("no new trip before its own wait ran out: it went home, the trip ended", eH == "end" and t11.state == "ended", whyEH)
local t12 = T.new("T-12", "drone-1", T.parse("stop:rules", PLACES), "alex", 0)
local u12 = flying(t12)
u12.ord, u12.seen = true, 20
T.cancel(t12, u12, 20)
u12.seen = 150
check("never hovers: failed", T.step(t12, u12, 150) == "end" and t12.state == "failed" and t12.why:find("did not stop", 1, true), t12.why)
local t13 = T.new("T-13", "drone-1", T.parse("stop:rules", PLACES), "alex", 0)
local u13 = flying(t13)
u13.ord, u13.seen, u13.landed = true, 20, true
local _, why13, _, act13 = T.cancel(t13, u13, 20)
check("down already: no stop, it ends at its stop as before", act13 == nil and t13.state == "flying", why13)
local t14 = T.new("T-14", "drone-1", T.parse("stop:rules", PLACES), "alex", 0)
local u14 = flying(t14)
u14.ord, u14.seen = true, 1
check("heard from too long ago: no stop either", select(4, T.cancel(t14, u14, 40)) == nil)
check("canStop: in the air, fresh, takes orders", T.canStop({ seen = 10, ord = true }, 12)
  and not T.canStop({ seen = 10 }, 12) and not T.canStop({ seen = 10, ord = true, docked = true }, 12)
  and not T.canStop({ seen = 10, ord = true, phase = "sos" }, 12) and not T.canStop(nil, 12))
local t15 = T.new("T-15", "drone-1", T.parse("stop:rules", PLACES), "alex", 0, true)
check("a trip begun in the air says so", t15.air == true and T.step(t15, { seen = 0 }, 0) == "send")

print("the feed line")
check("id|drone|state|leg|stop|who", T.line(t5) == "T-5|drone-1|ended|1/2|rules|alex", T.line(t5))


print("a stop at a dock with a heading")
check("a trip's stop at CHID 1 ferries facing west", T.command({ vias = {}, stop = { name = "chid-1", kind = "dock",
  x = 2497, y = 71, z = -3297, heading = 270 } }) == "ferry chid-1 at 2497 71 -3297 facing 270")
print("")
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then error("trip tests failed", 0) end
