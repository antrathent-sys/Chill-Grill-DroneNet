-- Desktop tests for lib/names.lua: what a unit is called wherever a person
-- reads it, and both names taken on the command line.
local DIR = ...
local pass, fail = 0, 0
local function check(n, c, d)
  if c then pass = pass + 1 print("  ok   " .. n)
  else fail = fail + 1 print("  FAIL " .. n .. (d and ("  " .. tostring(d)) or "")) end
end

local N = dofile(DIR .. "/../lib/names.lua")

check("drone-1 is LAMBDA-001", N.unit("drone-1") == "LAMBDA-001")
check("drone-12 is LAMBDA-012, and any case of label works", N.unit("drone-12") == "LAMBDA-012" and N.unit("DRONE-3") == "LAMBDA-003")
check("anything that is not a unit comes back as it is, in capitals", N.unit("depot-chid-1") == "DEPOT-CHID-1"
  and N.unit("LAMBDA-001") == "LAMBDA-001" and N.unit(nil) == nil)
N.CLASS_OF["drone-2"] = "ZETA"
check("a freighter is ZETA", N.unit("drone-2") == "ZETA-002")
N.CLASS_OF["drone-2"] = nil
check("both names back to the label", N.id("LAMBDA-001") == "drone-1" and N.id("lambda-1") == "drone-1"
  and N.id("zeta-002") == "drone-2" and N.id("drone-4") == "drone-4")
check("nothing else is a unit", N.id("pier") == nil and N.id("C-0042") == nil and N.id("gamma-001") == nil and N.id(nil) == nil)
check("a log line names its units", N.text("drone-1 sent to chid-1 for load C-0001.1; drone-12 docked")
  == "LAMBDA-001 sent to chid-1 for load C-0001.1; LAMBDA-012 docked")

print("")
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then error("names tests failed", 0) end
