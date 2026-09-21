-- Desktop tests for lib/deliver.lua: the `fly deliver` grammar, and which
-- silo is let go of at which drop.
local DIR = ...
local pass, fail = 0, 0
local function check(n, c, d)
  if c then pass = pass + 1 print("  ok   " .. n)
  else fail = fail + 1 print("  FAIL " .. n .. (d and ("  " .. tostring(d)) or "")) end
end

local D = dofile(DIR .. "/../lib/deliver.lua")
local function words(s)
  local t = {}
  for w in s:gmatch("%S+") do t[#t + 1] = w end
  return t
end
local function parse(s) return pcall(D.parse, words(s)) end

print("reading the command")
local ok, p = parse("deliver 100 80 50")
check("one drop at coordinates", ok and #p.drops == 1 and p.drops[1].x == 100 and p.drops[1].y == 80
  and p.drops[1].z == 50 and p.cruiseY == nil and not p.empty, not ok and p)
ok, p = parse("deliver 100 80 50 90")
check("a fourth number is the cruise height", ok and p.cruiseY == 90)
ok, p = parse("deliver pier")
check("a place name", ok and p.drops[1].place == "pier")
ok, p = parse("deliver pier 120")
check("a place and a cruise height", ok and p.drops[1].place == "pier" and p.cruiseY == 120)
ok, p = parse("deliver 100 80 50 90 to 20 70 30")
check("to <x> <y> <z> docks there at the end", ok and p.to.x == 20 and p.to.y == 70 and p.to.z == 30
  and #p.drops == 1 and p.cruiseY == 90)
ok, p = parse("deliver pier to depot")
check("to <dock>", ok and p.to.place == "depot")
ok, p = parse("deliver 100 80 50 empty")
check("empty flies it with nothing aboard", ok and p.empty == true and #p.drops == 1)
ok, p = parse("deliver empty 100 80 50 90 to depot")
check("...wherever the word goes", ok and p.empty and p.cruiseY == 90 and p.to.place == "depot")

print("two drops")
ok, p = parse("deliver 100 80 50 90 and 20 80 30")
check("A and B: two drops, the cruise height from the first", ok and #p.drops == 2 and p.drops[2].x == 20
  and p.drops[2].z == 30 and p.cruiseY == 90, not ok and p)
ok, p = parse("deliver pier and market to depot")
check("two places, then another dock", ok and p.drops[1].place == "pier" and p.drops[2].place == "market"
  and p.to.place == "depot")
ok, p = parse("deliver 100 80 50 and market")
check("coordinates and a place mixed", ok and p.drops[1].x == 100 and p.drops[2].place == "market")

print("what it refuses")
local function refused(s, what, needle)
  local okR, why = parse(s)
  check(what, not okR and (not needle or tostring(why):find(needle, 1, true)), okR and "accepted" or why)
end
refused("deliver", "no drop at all", "deliver where?")
refused("deliver 100 80", "two numbers", "needs <x> <y> <z>")
refused("deliver 100 80 50 and", "and with nothing after it", "nothing after")
refused("deliver 100 80 50 and 20 80 30 90", "a cruise height on the second drop", "first drop")
refused("deliver 100 80 50 to", "to with nothing after it", "to needs")
refused("deliver 100 80 50 to 1 2", "to with two numbers", "to needs")
refused("deliver pier market", "two words with no and between", "unexpected market")
local _, why = parse("deliver")
check("a refusal shows the grammar", tostring(why):find("deliver <x> <y> <z>", 1, true) ~= nil)

print("which silo goes where")
local function assign(n, held, empty) return pcall(D.assign, n, held, empty) end
local okA, r = assign(1, { "Create_Sticker_0" })
check("one drop, one silo: let go of it there", okA and #r == 1 and r[1][1] == "Create_Sticker_0")
okA, r = assign(1, { "Create_Sticker_1", "Create_Sticker_0" })
check("one drop, two silos: both there", okA and #r[1] == 2)
okA, r = assign(2, { "Create_Sticker_1", "Create_Sticker_0" })
check("two drops, two silos: the first by name at the first drop", okA and r[1][1] == "Create_Sticker_0"
  and r[2][1] == "Create_Sticker_1" and #r[1] == 1 and #r[2] == 1)
okA, r = assign(2, { "a", "b", "c" })
check("two drops, three silos: the last drop takes the rest", okA and #r[1] == 1 and #r[2] == 2)
okA, r = assign(1, {})
check("no silo aboard: refused, and says how to fly it anyway", not okA and tostring(r):find("needs a payload", 1, true)
  and tostring(r):find("empty", 1, true), r)
okA, r = assign(2, { "Create_Sticker_0" })
check("two drops, one silo: refused", not okA and tostring(r):find("2 drops but 1 payload", 1, true), r)
okA, r = assign(2, {}, true)
check("empty: nothing to let go of anywhere, and no silo needed", okA and #r == 2 and #r[1] == 0 and #r[2] == 0)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then error("deliver tests failed", 0) end
