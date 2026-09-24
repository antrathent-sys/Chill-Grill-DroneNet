-- Desktop tests for lib/machine.lua: which files are one machine's own, where
-- they live in the repo, and what may never go there.
local DIR = ...
local pass, fail = 0, 0
local function check(n, c, d)
  if c then pass = pass + 1 print("  ok   " .. n)
  else fail = fail + 1 print("  FAIL " .. n .. (d and ("  " .. tostring(d)) or "")) end
end

local M = dofile(DIR .. "/../lib/machine.lua")

print("where a machine's settings live")
check("under its own name", M.folder("test-dock") == "machines/test-dock")
check("a drone's too", M.folder("drone-1") == "machines/drone-1")
check("no label, no folder", M.folder(nil) == nil and M.folder("") == nil)
check("a name that is not plain is refused", M.folder("../base") == nil and M.folder("a b") == nil)

print("what a machine keeps")
local dock = M.wanted("depot")
local function has(list, name)
  for _, f in ipairs(list) do if f == name then return true end end
  return false
end
check("a dock keeps its station and its probe", has(dock, "station.lua") and has(dock, "probe.txt"))
check("...and the places every machine shares", has(dock, "pads.lua"))
check("...and nothing a drone keeps", not has(dock, "cal.lua") and not has(dock, "tune.lua"))
local drone = M.wanted("drone")
check("a drone keeps its cal, tune and mix map", has(drone, "cal.lua") and has(drone, "tune.lua")
  and has(drone, "mixmap.csv"))
check("a base keeps its prices and devices", has(M.wanted("base"), "tariff.lua")
  and has(M.wanted("base"), "devices.lua"))
check("an unknown role keeps everything, rather than losing something", has(M.wanted(nil), "station.lua")
  and has(M.wanted("nonsense"), "cal.lua"))
check("the list is sorted, and each file appears once", (function()
  local seen, last = {}, ""
  for _, f in ipairs(M.wanted(nil)) do
    if seen[f] or f < last then return false end
    seen[f], last = true, f
  end
  return true
end)())

print("what may never go in the repo")
local function refused(name) return (M.allowed(name)) == false end
check("a drone key", refused(".dronekey"))
check("the fleet's keys", refused(".fleetkeys"))
check("a customer's key", refused(".custkey") and refused(".custkeys"))
check("the repo token", refused(".ghtoken"))
check("a replay counter", refused("drone-1.ctr") and refused(".dronekey.ctr"))
check("anything with key in the name", refused("mykeys.lua") and refused("KEYRING.txt"))
check("any dotfile at all", refused(".role") and refused(".autorun") and refused(".hailstats"))
check("a path, rather than a file", refused("lib/machine.lua") and refused("../ops.lua"))
check("...and a station or a cal is fine", (M.allowed("station.lua")) and (M.allowed("cal.lua")))
check("no name at all", refused(nil) and refused(""))
check("every file on every list is allowed", (function()
  for _, list in pairs(M.FILES) do
    for _, f in ipairs(list) do if not (M.allowed(f)) then return false, f end end
  end
  return true
end)())

print("reading a folder listing")
local json = '[{"name":"station.lua","path":"machines/test-dock/station.lua"},' ..
             '{"name":"probe.txt"},{"name":".ghtoken"},{"name":"nested/thing.lua"}]'
local names = M.namesIn(json)
check("the names come out", has(names, "station.lua") and has(names, "probe.txt"))
check("...and a key in the listing is not one of them", not has(names, ".ghtoken"))
check("...nor a path", not has(names, "nested/thing.lua"))
check("nonsense gives nothing", #M.namesIn("") == 0 and #M.namesIn(nil) == 0)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then error("machine tests failed", 0) end
