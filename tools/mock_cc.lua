-- Mock CC:Tweaked harness. Stubs enough of the API to run fly.lua against a
-- crude kinematic drone so the PHASE MACHINE can be exercised end to end.
-- This is not a flight-dynamics model and proves nothing about tuning.

local SCRIPT, ARGS = ...
local T = 0.0

-- ---------- simulated world ----------
local sim = {
  h = 64.0, x = 0.0, z = 0.0,     -- drone
  vv = 0.0, speed = 0.0,
  pwr = 0.0, vx = 0.0, vy = 0.0,
  padX = 100, padZ = 50, padY = 70,
  rs = (os.getenv('START_DOCKED') and { bottom = true } or {}),
  dockedSince = nil, docked = false,
  phaseHint = "",
  lastT = 0.0,
}

local HOVER = 0.5
local function step(to)
  local dt = to - sim.lastT
  if dt <= 0 then return end
  sim.lastT = to
  -- vertical: power maps to ACCELERATION plus drag. Modelling it as a direct
  -- velocity made the controller's D term a divergent feedback term.
  local accel = (sim.pwr - HOVER) * 25 - 0.4 * sim.vv
  sim.vv = sim.vv + accel * dt
  sim.h = sim.h + sim.vv * dt
  if sim.h < 1 then sim.h = 1 sim.vv = 0 end
  -- horizontal: stand-in for the translation controller. Cruise toward the
  -- pad while leaning hard, bleed off otherwise.
  local dx, dz = sim.padX - sim.x, sim.padZ - sim.z
  local d = math.sqrt(dx * dx + dz * dz)
  local lean = math.sqrt(sim.vx * sim.vx + sim.vy * sim.vy)
  if lean > 0.25 and d > 0.4 then
    sim.speed = math.min(sim.speed + 6 * dt, 9)
  else
    sim.speed = math.max(sim.speed - 5 * dt, 0)
  end
  local mv = math.min(sim.speed * dt, d)
  if d > 1e-6 then sim.x = sim.x + dx / d * mv sim.z = sim.z + dz / d * mv end
  -- DRIFT: real station keeping wanders around the target rather than parking
  -- on it. Needed to make GPS_QUANT cross block boundaries the way it will
  -- in game.
  if os.getenv('DRIFT') then
    sim.dp = (sim.dp or 0) + dt
    sim.jx = 0.8 * math.sin(sim.dp * 0.7)
    sim.jz = 0.8 * math.cos(sim.dp * 0.53)
  else
    sim.jx, sim.jz = 0, 0
  end
  -- docking magnet: needs the connector extended and the drone parked close
  local extended = false
  for _, v in pairs(sim.rs) do if v then extended = true end end
  local near = math.abs(sim.h - (sim.padY + 3)) < 1.6 and d < 1.5
  if os.getenv('NODOCK') then extended = false end
  if extended and near then
    if not sim.dockedSince then sim.dockedSince = to end
    if to - sim.dockedSince > 1.5 then sim.docked = true end
  else
    sim.dockedSince = nil
  end
end

-- ---------- CC API ----------
function sleep(n) coroutine.yield(n or 0) end
_G.os = _G.os or {}
os.clock = function() return T end
os.epoch = function() return math.floor(T * 1000) end

_G.redstone = {
  setOutput = function(side, on) sim.rs[side] = on and true or false end,
  getOutput = function(side) return sim.rs[side] or false end,
  getSides = function() return { "top", "bottom", "left", "right", "front", "back" } end,
}

-- CC:Tweaked modems report position as Vec3.atLowerCornerOf(blockPos), so every
-- GPS fix is quantised to whole blocks. GPS_QUANT models that.
_G.gps = { locate = function()
  if os.getenv('GPS_QUANT') then
    return math.floor(sim.x + (sim.jx or 0)), math.floor(sim.h), math.floor(sim.z + (sim.jz or 0))
  end
  return sim.x + (sim.jx or 0), sim.h, sim.z + (sim.jz or 0)
end }

local logLines = {}
_G.fs = {
  open = function()
    return {
      writeLine = function(s) logLines[#logLines + 1] = s end,
      write = function(s) logLines[#logLines + 1] = s end,
      close = function() end,
    }
  end,
  exists = function() return false end,
}

-- peripherals
local periphs, names = {}, {}
local function add(name, ptype, tbl)
  tbl.__type = ptype
  periphs[name] = tbl
  names[tbl] = name
end

add("altitude_sensor_0", "altitude_sensor", { getHeight = function() return sim.h end })
add("gimbal_sensor_0", "gimbal_sensor", {
  getAngles = function()
    -- lean roughly proportional to commanded vector, plus a little noise
    return { sim.vy * 40, sim.vx * 40 }
  end,
})
add("navigation_table_0", "navigation_table", { getRelativeAngle = function() return 90 end })
add("vector_thruster_0", "vector_thruster", {
  setVector = function(a, b) sim.vx, sim.vy = a, b end,
  setPowerNormalized = function(p) sim.pwr = p end,
  getEnergy = function() return 40000 end,
  getEnergyCapacity = function() return 50000 end,
})
add("modular_accumulator_0", "modular_accumulator", {
  getPercent = function() return math.max(0, 90 - T * 0.4) end,
})
add("docking_connector_0", "docking_connector", {
  getConnectedName = function()
    if os.getenv("START_DOCKED") and sim.rs["bottom"] then return "TestPad" end
    return sim.docked and "TestPad" or "" end,
})
-- three velocity sensors; 0 forward, 1 lateral, 3 vertical, signs per CFG
add("velocity_sensor_0", "velocity_sensor", { getVelocity = function() return -sim.speed end, getAxis = function() return "x" end })
add("velocity_sensor_1", "velocity_sensor", { getVelocity = function() return 0 end, getAxis = function() return "z" end })
add("velocity_sensor_3", "velocity_sensor", { getVelocity = function() return -sim.vv end, getAxis = function() return "y" end })

_G.peripheral = {
  find = function(ptype)
    local out = {}
    for _, p in pairs(periphs) do if p.__type == ptype then out[#out + 1] = p end end
    table.sort(out, function(a, b) return names[a] < names[b] end)
    return table.unpack(out)
  end,
  wrap = function(name) return periphs[name] end,
  getName = function(p) return names[p] end,
  getMethods = function(name)
    local p = periphs[name]
    if not p then return nil end
    local out = {}
    for k, v in pairs(p) do if type(v) == "function" then out[#out + 1] = k end end
    return out
  end,
}

-- cooperative scheduler
_G.parallel = {
  waitForAny = function(...)
    local fns = { ... }
    local cos, wake = {}, {}
    for i, f in ipairs(fns) do cos[i] = coroutine.create(f) wake[i] = T end
    local guard = 0
    while true do
      guard = guard + 1
      if guard > 400000 or T > tonumber(os.getenv('TMAX') or '400') then error(string.format("harness: gave up at T=%.0fs", T), 0) end
      local best, bt = nil, math.huge
      for i, c in ipairs(cos) do
        if coroutine.status(c) ~= "dead" and wake[i] < bt then best, bt = i, wake[i] end
      end
      if not best then return end
      T = math.max(T, bt)
      step(T)
      local ok, a = coroutine.resume(cos[best])
      if not ok then error(a, 0) end
      if coroutine.status(cos[best]) == "dead" then return end
      wake[best] = T + (tonumber(a) or 0)
    end
  end,
}

-- CC: Sable sublevel API stub, so probe.lua can be exercised. Position is
-- deliberately world-frame and continuous, which is the hypothesis probe.lua
-- is written to test in game.
_G.sublevel = {
  isInPlotGrid = function() return true end,
  getName = function() return "TestDrone" end,
  getUniqueId = function() return "0000-test" end,
  getLogicalPose = function()
    return { position = { x = sim.x, y = sim.h, z = sim.z },
             orientation = { x = 0, y = 0, z = 0, w = 1 },
             scale = { x = 1, y = 1, z = 1 },
             rotationPoint = { x = 0, y = 0, z = 0 } }
  end,
  getLastPose = function() return _G.sublevel.getLogicalPose() end,
  getLinearVelocity = function() return { x = sim.speed, y = sim.vv, z = 0 } end,
  getAngularVelocity = function() return { x = 0, y = 0, z = 0 } end,
  getVelocity = function() return { x = sim.speed, y = sim.vv, z = 0 } end,
  getCenterOfMass = function() return { x = 0, y = 0, z = 0 } end,
  getMass = function() return 1234.5 end,
}
_G.term = { clear = function() end, setCursorPos = function() end }

-- Lua 5.1 had math.atan2; this harness runs on a newer Lua where it is gone.
math.atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

_G.arg = ARGS

local f = assert(loadfile(SCRIPT))
local ok, err = pcall(f)
print("---- harness result ----")
print("ok:", ok, "err:", err)
print(string.format("final: h=%.2f x=%.1f z=%.1f docked=%s rs=%s",
  sim.h, sim.x, sim.z, tostring(sim.docked), tostring(sim.rs["bottom"])))
print("log rows:", #logLines)

-- write the flightlog out so the Python analyser can be run on it
local out = io.open(os.getenv("HARNESS_LOG") or "harness_flightlog", "w")
for _, l in ipairs(logLines) do out:write(l, "\n") end
out:close()

-- phase order actually visited
local seen, order = {}, {}
for i = 2, #logLines do
  local ph = logLines[i]:match("^[^,]*,([^,]*)")
  if ph and ph ~= seen.last then order[#order + 1] = ph seen.last = ph end
end
print("phases: " .. table.concat(order, " -> "))
