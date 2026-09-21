local DIR = ...
local pass, fail = 0, 0
local function check(n, c, d)
  if c then pass = pass + 1 print("  ok   " .. n)
  else fail = fail + 1 print("  FAIL " .. n .. (d and ("  " .. tostring(d)) or "")) end
end

local Q = dofile(DIR .. "/../lib/queue.lua")

local function req(who, px, pz, tx, tz, at, priority)
  return { who = who, px = px, pz = pz, tx = tx, tz = tz, at = at or 0, priority = priority }
end

print("joining the line")
local q = {}
check("first in", Q.add(q, req("alex", 0, 0, 100, 0)) == 1)
check("second in", Q.add(q, req("sam", 50, 0, 200, 0)) == 2)
local again, why = Q.add(q, req("alex", 0, 0, 1, 1))
check("you cannot be in it twice", again == nil and why == "already waiting", why)
check("and you can see your place", Q.position(q, "sam") == 2)
check("someone not waiting has no place", Q.position(q, "nobody") == nil)

print("who a free shuttle takes")
q = { req("alex", 0, 0, 100, 0), req("sam", 900, 0, 0, 0), req("kit", 20, 0, 0, 0) }
local who = Q.pick(q, { x = 10, z = 0 })
check("the longest wait, when nobody is much closer", who.who == "alex", who.who)
q = { req("alex", 900, 0, 0, 0), req("sam", 10, 0, 0, 0), req("kit", 800, 0, 0, 0) }
who = Q.pick(q, { x = 0, z = 0 })
check("someone close by in the next two, when the first is far", who.who == "sam", who.who)
check("being passed over is remembered", q[1].skips == 1 and q[3].skips == 1)

print("nobody waits for ever")
q = { req("alex", 900, 0), req("sam", 10, 0) }
q[1].skips = Q.SKIPS
who = Q.pick(q, { x = 0, z = 0 })
check("passed over twice, and you are next whatever the distance", who.who == "alex", who.who)

print("stranded first")
q = { req("alex", 10, 0), req("sam", 900, 0, 0, 0, 0, true) }
who = Q.pick(q, { x = 0, z = 0 })
check("no credit and heading home goes to the front", who.who == "sam", who.who)

print("leaving the line")
q = { req("alex", 0, 0), req("sam", 0, 0) }
check("by name", Q.removeWho(q, "alex").who == "alex" and #q == 1)
check("and by place", Q.removeAt(q, 1).who == "sam" and #q == 0)
q = { req("old", 0, 0, 0, 0, 100), req("new", 0, 0, 0, 0, 900) }
local gone = Q.expire(q, 1000, 600)
check("a request nobody answered is dropped", #gone == 1 and gone[1].who == "old" and #q == 1)

print("what to tell someone waiting")
-- one person, shuttle free and 1,070 blocks away: 50s of climb and descent
-- plus half a minute of cruise
q = { req("alex", 1070, 0, 1070, 0) }
local w = Q.wait(q, 1, 0, { x = 0, z = 0 })
check("first in line, shuttle free", w >= 75 and w <= 85, w)
check("a shuttle mid-job adds what it still has to do",
  Q.wait(q, 1, 120, { x = 0, z = 0 }) - w == 120)
q = { req("alex", 0, 0, 2140, 0), req("sam", 2140, 0, 2140, 0) }
local first = Q.wait(q, 1, 0, { x = 0, z = 0 })
local second = Q.wait(q, 2, 0, { x = 0, z = 0 })
check("second in line waits for the ride in front of them", second > first + 60, second - first)
check("the estimate is in whole seconds", math.floor(second) == second)

print("the flight model")
check("a 2,140-block leg is a minute of cruise plus the overhead",
  math.abs(Q.flightTime(2140) - (60 + Q.OVERHEAD)) < 1, Q.flightTime(2140))
check("a very short leg is almost all overhead", Q.flightTime(0) == Q.OVERHEAD)

print("")
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then error("queue tests failed", 0) end
