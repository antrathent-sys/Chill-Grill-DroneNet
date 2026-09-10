-- preflight: check everything fly.lua assumes, on the ground, before it matters.
-- Read-only. Never touches the thruster.
--
--   preflight            checks for a local flight
--   preflight <x> <z>    also checks range and energy for a round trip there
--
-- Exit is advisory: read the FAILs, ignore nothing, WARNs are judgement calls.

local args = { ... }
local tgtX, tgtZ = tonumber(args[1]), tonumber(args[2])

-- Pulled from fly.lua's CFG. Keep in step if you retune.
local EXPECT = {
  FWD_NAME = "velocity_sensor_0",
  LAT_NAME = "velocity_sensor_1",
  VRT_NAME = "velocity_sensor_3",
  HOVER = 0.5,
  CRUISE_SPEED = 8,
  DOCK_SIDE = nil,          -- set this to match fly.lua once docking is wired
}

local pass, warn, bad = 0, 0, 0
local haveSable = false
local function ok(m)   pass = pass + 1 print("  ok   " .. m) end
local function wrn(m)  warn = warn + 1 print("  WARN " .. m) end
local function err(m)  bad = bad + 1  print("  FAIL " .. m) end
local function head(m) print("") print(m) end

-- ---------- peripherals ----------
head("peripherals")
local function need(ptype)
  local p = peripheral.find(ptype)
  if p then ok(ptype .. " present") else err(ptype .. " MISSING - fly.lua will not start") end
  return p
end

local alt = need("altitude_sensor")
local gim = need("gimbal_sensor")
local nav = need("navigation_table")
local thr = need("vector_thruster")

local acc = peripheral.find("modular_accumulator")
if acc then ok("modular_accumulator present") else wrn("no accumulator - energy will log as -1") end

local dockP = peripheral.find("docking_connector")
if dockP then ok("docking_connector present") else wrn("no docking connector - dock/undock unavailable") end

-- ---------- velocity sensors, the ones that bite ----------
head("velocity sensors")
local vs = { peripheral.find("velocity_sensor") }
if #vs == 0 then
  err("no velocity sensors - fly.lua will not start")
elseif #vs < 3 then
  wrn(#vs .. " velocity sensor(s), fly.lua expects 3")
else
  ok(#vs .. " velocity sensors found")
end

-- The names in CFG must actually exist, or the drone flies on the wrong axis.
for label, name in pairs({ FWD = EXPECT.FWD_NAME, LAT = EXPECT.LAT_NAME, VRT = EXPECT.VRT_NAME }) do
  local p = peripheral.wrap(name)
  if not p then
    err(label .. " sensor " .. name .. " NOT FOUND - check CFG names against the build")
  else
    local okA, axis = pcall(p.getAxis)
    local okV, vel = pcall(p.getVelocity)
    ok(string.format("%s = %s (axis %s, reads %.2f)", label, name,
      okA and tostring(axis) or "?", okV and vel or 0))
  end
end

-- Three sensors on the same axis is a build error that flies very badly.
if #vs >= 2 then
  local axes, dup = {}, false
  for _, s in ipairs(vs) do
    local okA, a = pcall(s.getAxis)
    if okA and a then
      if axes[a] then dup = true end
      axes[a] = (axes[a] or 0) + 1
    end
  end
  if dup then
    err("two or more velocity sensors share an axis - they must be perpendicular")
  else
    ok("velocity sensor axes are distinct")
  end
end

-- ---------- attitude and altitude sanity ----------
head("sensor readings")
if gim then
  local a = gim.getAngles()
  local tilt = math.sqrt(a[1] * a[1] + a[2] * a[2])
  if tilt > 15 then
    wrn(string.format("sitting at %.0f deg of tilt - is the pad level?", tilt))
  else
    ok(string.format("attitude %.1f / %.1f deg", a[1], a[2]))
  end
end
if alt then
  local h = alt.getHeight()
  if h ~= h or h < -64 or h > 400 then
    err("altitude reads " .. tostring(h) .. " - sensor is wrong")
  else
    ok(string.format("altitude %.1f", h))
  end
end

-- ---------- position ----------
head("position")
haveSable = false
if _G.sublevel then
  local okg, grid = pcall(sublevel.isInPlotGrid)
  if okg and grid then
    haveSable = true
    local okp, pose = pcall(sublevel.getLogicalPose)
    if okp and pose and pose.position then
      ok(string.format("CC:Sable pose %.2f %.2f %.2f", pose.position.x, pose.position.y, pose.position.z))
    else
      wrn("sublevel present but getLogicalPose failed")
    end
  else
    wrn("CC:Sable present but this computer is not on a sub-level - is the pod assembled?")
  end
else
  wrn("no CC:Sable - running on GPS alone")
end

local gx, gy, gz = gps.locate(2)
if gx then
  ok(string.format("gps fix %.0f %.0f %.0f", gx, gy, gz))
else
  if haveSable then
    wrn("no GPS fix - fine for the drone, but customers cannot locate themselves")
  else
    err("NO GPS FIX - every mode except 'find' needs one. Are the volcano hosts loaded?")
  end
end

-- ---------- energy ----------
head("energy")
local pct = nil
if acc then
  local oke, p = pcall(acc.getPercent)
  if oke then
    pct = p
    if p < 25 then err(string.format("accumulator at %.0f%% - charge before flying", p))
    elseif p < 60 then wrn(string.format("accumulator at %.0f%%", p))
    else ok(string.format("accumulator at %.0f%%", p)) end
  end
end
if thr then
  local oke, e = pcall(thr.getEnergy)
  local okc, c = pcall(thr.getEnergyCapacity)
  if oke and okc and c and c > 0 then
    ok(string.format("thruster buffer %.0f%%", 100 * e / c))
  else
    wrn("thruster reports no FE buffer - check FUEL_MODE")
  end
end

-- ---------- range, if a target was given ----------
if tgtX and tgtZ and gx then
  head("range to " .. tgtX .. "," .. tgtZ)
  local d = math.sqrt((tgtX - gx) ^ 2 + (tgtZ - gz) ^ 2)
  local round = d * 2
  ok(string.format("%.0f blocks out, %.0f round trip", d, round))
  local secs = round / EXPECT.CRUISE_SPEED
  ok(string.format("about %.0f s of cruise at %d b/s", secs, EXPECT.CRUISE_SPEED))
  if pct then
    -- No drain rate until a flight has been logged, so this is a rough guard.
    wrn(string.format("cannot judge %.0f%% against an unknown drain rate - fly a short leg first", pct))
  end
end

-- ---------- docking wiring ----------
head("docking")
if EXPECT.DOCK_SIDE == nil then
  wrn("DOCK_SIDE not set in this script - dock/undock will refuse to run")
else
  local sides = {}
  for _, s in ipairs(redstone.getSides()) do sides[s] = true end
  if not sides[EXPECT.DOCK_SIDE] then
    err("DOCK_SIDE '" .. EXPECT.DOCK_SIDE .. "' is not a valid side")
  else
    ok("DOCK_SIDE = " .. EXPECT.DOCK_SIDE)
    if redstone.getOutput(EXPECT.DOCK_SIDE) then
      wrn("DOCK_SIDE is already high - connector extended, or a previous flight left it on")
    end
  end
  if dockP then
    local okn, name = pcall(dockP.getConnectedName)
    if okn and name and name ~= "" then
      ok("currently docked to " .. name)
    else
      ok("not currently docked")
    end
  end
end

-- ---------- everything actually attached ----------
-- Not just what fly.lua wants: the full inventory, so a device that is fitted
-- but unused, or fitted and misnamed, shows up.
head("devices attached")
local names = peripheral.getNames and peripheral.getNames() or {}
if #names == 0 then
  err("no peripherals found at all - is anything actually attached?")
else
  local byType = {}
  for _, nm in ipairs(names) do
    local ty = peripheral.getType(nm) or "?"
    byType[ty] = (byType[ty] or 0) + 1
    local ms = peripheral.getMethods(nm) or {}
    print(string.format("  %-24s %-24s %d methods", nm, ty, #ms))
  end
  pass = pass + 1
  local kinds = {}
  for ty, n in pairs(byType) do kinds[#kinds + 1] = ty .. " x" .. n end
  table.sort(kinds)
  print("  -> " .. #names .. " devices: " .. table.concat(kinds, ", "))
end

-- ---------- what is missing, by what it would unlock ----------
head("capability check")
local function want(label, present, why, fatal)
  if present then ok(label .. " - " .. why)
  elseif fatal then err(label .. " MISSING - " .. why)
  else wrn(label .. " absent - " .. why) end
end

want("vector_thruster", thr ~= nil, "the only actuator", true)
want("altitude_sensor", alt ~= nil, "altitude hold and the dock gap", true)
want("gimbal_sensor",  gim ~= nil, "attitude; still needed, the Sable quaternion reads null", true)
want("velocity_sensor x3", #vs >= 3, "body-frame speed for brake and the dock align gate", true)
want("CC:Sable sublevel", haveSable, "position and velocity; 45x better than the GPS array here", true)
want("modular_accumulator", acc ~= nil, "energy monitoring and range planning", false)
want("docking_connector", dockP ~= nil, "docking, and payload release", false)
want("speaker", peripheral.find("speaker") ~= nil, "flight chimes", false)
want("modem", peripheral.find("modem") ~= nil, "telemetry and remote recall", false)
want("navigation_table", nav ~= nil, "bearing to a lodestone target; heading no longer needs it", false)

-- ---------- files ----------
head("files")
for _, f in ipairs({ "fly.lua", "kill.lua", "upload.lua" }) do
  if fs.exists(f) then ok(f .. " present") else wrn(f .. " missing - run startup to fetch it") end
end
if fs.exists(".ghtoken") then
  ok(".ghtoken present (auto-upload will try)")
else
  wrn("no .ghtoken - flight logs will not upload")
end
if not http then wrn("http API disabled - no updates, no log upload") end

-- ---------- verdict ----------
print("")
print(string.format("%d ok, %d warnings, %d failures", pass, warn, bad))
if bad > 0 then
  print("DO NOT FLY until the failures are cleared.")
else
  print("clear to fly" .. (warn > 0 and " - read the warnings first" or ""))
end
