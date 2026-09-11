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
  -- lift falls with cos(lean) on the quad so the throttle floor and the
  -- altitude-by-lean loop interact the way they do in the air
  local lift = sim.pwr
  if sim.quad then
    local tp, tr = sim.quadTilt()
    lift = sim.pwr * math.max(0.15, math.cos(math.rad(tp)) * math.cos(math.rad(tr)))
  end
  local accel = (lift - HOVER) * 25 - 0.4 * sim.vv
  sim.vv = sim.vv + accel * dt
  sim.h = sim.h + sim.vv * dt
  -- the craft starts ON the pad, so the ground is the start height: landing
  -- tests then exercise the real geometry rather than a 63-block creep
  if sim.h < 64 then sim.h = 64 sim.vv = 0 end
  -- horizontal: stand-in for the translation controller. Cruise toward the
  -- pad while leaning hard, bleed off otherwise.
  local dx, dz = sim.padX - sim.x, sim.padZ - sim.z
  local d = math.sqrt(dx * dx + dz * dz)
  local lean = math.sqrt(sim.vx * sim.vx + sim.vy * sim.vy)
  -- a quad in diff mode tilts by differential thrust, not by the nozzles;
  -- the legacy gimbal read vy*40, so a lean of 0.25 is 10 degrees
  if sim.quad then
    local qp, qr = sim.quadTilt()
    lean = math.sqrt(qp * qp + qr * qr) / 40
  end
  if lean > 0.25 and d > 0.4 then
    sim.speed = math.min(sim.speed + 6 * dt, 9)
  else
    sim.speed = math.max(sim.speed - 5 * dt, 0)
  end
  local mv = math.min(sim.speed * dt, d)
  local ox, oz = sim.x, sim.z
  if d > 1e-6 then sim.x = sim.x + dx / d * mv sim.z = sim.z + dz / d * mv end
  if dt > 0 then sim.wvx = (sim.x - ox) / dt sim.wvz = (sim.z - oz) / dt end
  -- DRIFT: real station keeping wanders around the target rather than parking
  -- on it. Needed to make GPS_QUANT cross block boundaries the way it will
  -- in game.
  -- DRIFT is REAL motion: the drone actually wanders, so the velocity sensors
  -- see it too. Only GPS additionally quantises. Perturbing just the GPS
  -- reading would have made the sensors unrealistically clean and rigged any
  -- comparison between the two signals.
  if os.getenv('DRIFT') then
    local prevx, prevz = sim.jx or 0, sim.jz or 0
    sim.dp = (sim.dp or 0) + dt
    -- amplitude and rate chosen so peak drift speed is ~0.5 b/s: a drone
    -- holding station imperfectly, not one being blown around.
    sim.jx = 0.30 * math.sin(sim.dp * 0.9) + 0.12 * math.sin(sim.dp * 2.6)
    sim.jz = 0.30 * math.cos(sim.dp * 0.7) + 0.12 * math.cos(sim.dp * 2.2)
    if dt > 0 then
      sim.driftSpeed = math.sqrt(((sim.jx - prevx) / dt) ^ 2 + ((sim.jz - prevz) / dt) ^ 2)
    end
  else
    sim.jx, sim.jz, sim.driftSpeed = 0, 0, 0
  end
  -- docking magnet: needs the connector extended and the drone parked close
  local extended = false
  for _, v in pairs(sim.rs) do if v then extended = true end end
  -- DOCK_EARLY: a generous magnet that takes hold from a long way up, to
  -- exercise the flight ending while still in align or descend rather than
  -- only in capture.
  local near
  if os.getenv('DOCK_EARLY') then
    near = sim.h - sim.padY < 40 and d < 8
  else
    near = math.abs(sim.h - (sim.padY + 3)) < 1.6 and d < 1.5
  end
  if os.getenv('NODOCK') then extended = false end
  -- PAD_SOLID: the craft cannot get below the pad surface, so a park height
  -- typed too low leaves the descent waiting for an altitude it can never
  -- reach. That hung a real flight on 2026-09-11.
  if os.getenv('PAD_SOLID') and d < 3 and sim.h < sim.padY + 3 then
    sim.h = sim.padY + 3
    if sim.vv < 0 then sim.vv = 0 end
  end
  if extended and near then
    if not sim.dockedSince then sim.dockedSince = to end
    if to - sim.dockedSince > 1.5 then sim.docked = true end
  else
    sim.dockedSince = nil
  end
end

-- ---------- CC API ----------
function sleep(n) coroutine.yield(n or 0) end
-- The harness has no keyboard and no radio. cmdLoop just has to be able to
-- park on os.pullEvent without ending (a coroutine that returns would end the
-- whole flight through parallel.waitForAny).
_G.os = _G.os or {}
-- CMD_AT="20:l" presses a key at T=20, so the in-flight command path can be
-- exercised the way it is actually used: mid-flight, without restarting.
local cmdAt = os.getenv('CMD_AT')
os.pullEvent = function()
  if cmdAt then
    local at, key = cmdAt:match("^([%d%.]+):(%a)$")
    at = tonumber(at)
    cmdAt = nil
    if at and T < at then coroutine.yield(at - T) end
    if key then return "char", key end
  end
  coroutine.yield(3600)
  return "timer", 0
end
_G.os = _G.os or {}
os.clock = function() return T end
os.epoch = function() return math.floor(T * 1000) end

-- rednet is only exercised by lib/rs.lua when a remote redstone target is
-- configured; the harness configures none, so this just has to exist.
_G.rednet = {
  open = function() end,
  broadcast = function() end,
  receive = function() return nil end,
}

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
  exists = function(p)
    -- UPLOAD_BOOM makes upload.lua present but explosive, to prove a failed
    -- auto-upload cannot take the flight down with it.
    if p == "upload.lua" then return os.getenv("UPLOAD_BOOM") ~= nil end
    if p == "lib/chime.lua" then return os.getenv("SPEAKER") ~= nil end
    return false
  end,
}
_G.shell = { run = function() error("simulated upload failure", 0) end }

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
    -- lean proportional to the commanded vector. NEGATIVE: vectoring a
    -- nozzle toward + tips the craft toward -, as on the real airframe
    -- (the tuned P_SIGN/R_SIGN assume that). The old positive sign was a
    -- hidden positive-feedback loop that only converged because KP*40 < 1.
    return { -sim.vy * 40, -sim.vx * 40 }
  end,
})
add("navigation_table_0", "navigation_table", { getRelativeAngle = function() return 90 end })
add("vector_thruster_0", "vector_thruster", {
  setVector = function(a, b) sim.vx, sim.vy = a, b end,
  setPowerNormalized = function(p) sim.pwr = p end,
  getEnergy = function() return 40000 end,
  getEnergyCapacity = function() return 50000 end,
})

-- QUAD=1 fits four thrusters at the corners of a 3x3, each with a known
-- offset, so mixcal can be tested against a ground truth it does not know.
if os.getenv("QUAD") then
  local corners = {
    vector_thruster_5 = {  1,  1 },
    vector_thruster_6 = {  1, -1 },
    vector_thruster_7 = { -1,  1 },
    vector_thruster_8 = { -1, -1 },
  }
  sim.quad = {}
  -- the single thruster goes: a quad is four thrusters, not five
  periphs["vector_thruster_0"] = nil
  for nm, c in pairs(corners) do
    sim.quad[nm] = { n = c[1], s = c[2], pwr = 0 }
    add(nm, "vector_thruster", {
      setPowerNormalized = function(p)
        sim.quad[nm].pwr = p
        -- lift is the mean of the four
        local sum = 0
        for _, q in pairs(sim.quad) do sum = sum + q.pwr end
        sim.pwr = sum / 4
      end,
      -- a common vector on all four tilts the craft like the single thruster did
      setVector = function(a, b) sim.vx, sim.vy = a, b end,
      getThrust = function() return sim.quad[nm].pwr * 100 end,
      getEnergy = function() return 40000 end,
      getEnergyCapacity = function() return 50000 end,
    })
  end
  -- the gimbal now reports the tilt those corner thrusters would produce
  -- Attitude is second order: nozzle vector and corner differential make
  -- torque, the airframe has inertia and a little aerodynamic damping.
  -- (A static or first-order model made the D-term see rates the real
  -- craft cannot produce and limit-cycled at the flight-sized gains.)
  -- Signs: vectoring toward + tips the craft toward -, as tuned for real.
  sim.tiltP, sim.tiltR, sim.rateP, sim.rateR, sim.tiltT = 0, 0, 0, 0, 0
  sim.quadTilt = function()
    local dt = math.max(0, math.min(0.2, T - sim.tiltT)) sim.tiltT = T
    if dt > 0 then
      local dP, dR = 0, 0
      for _, q in pairs(sim.quad) do
        dP = dP - q.n * q.pwr       -- lifting a +n corner pitches nose down
        dR = dR + q.s * q.pwr
      end
      local accP = -200 * sim.vy + 60 * dP - 2 * sim.rateP
      local accR = -200 * sim.vx + 60 * dR - 2 * sim.rateR
      sim.rateP = sim.rateP + accP * dt
      sim.rateR = sim.rateR + accR * dt
      sim.tiltP = math.max(-120, math.min(120, sim.tiltP + sim.rateP * dt))
      sim.tiltR = math.max(-120, math.min(120, sim.tiltR + sim.rateR * dt))
    end
    return sim.tiltP, sim.tiltR
  end
  periphs["gimbal_sensor_0"].getAngles = function()
    local p, r = sim.quadTilt()
    return { p, r }
  end
end
add("modular_accumulator_0", "modular_accumulator", {
  getPercent = function() return math.max(0, 90 - T * 0.4) end,
})
-- SPEAKER=1 attaches a speaker so the chime path is exercised
if os.getenv("SPEAKER") then
  _G.notesPlayed = {}
  add("speaker_0", "speaker", {
    playNote = function(i, v, p) notesPlayed[#notesPlayed+1] = i .. ":" .. tostring(p) return true end,
  })
end
add("docking_connector_0", "docking_connector", {
  getConnectedName = function()
    -- UNNAMED_PAD reproduces the real one: latched, but the name reads "".
    -- The only way to know is the network bridge, which is what fly.lua uses.
    if os.getenv("UNNAMED_PAD") then return "" end
    if os.getenv("START_DOCKED") and sim.rs["bottom"] then return "TestPad" end
    return sim.docked and "TestPad" or "" end,
})
-- three velocity sensors; 0 forward, 1 lateral, 3 vertical, signs per CFG
if not os.getenv("NOVEL") then
add("velocity_sensor_0", "velocity_sensor", { getVelocity = function() return -(sim.speed + (sim.driftSpeed or 0)) end, getAxis = function() return "x" end })
add("velocity_sensor_1", "velocity_sensor", { getVelocity = function() return 0 end, getAxis = function() return "z" end })
add("velocity_sensor_3", "velocity_sensor", { getVelocity = function() return -sim.vv end, getAxis = function() return "y" end })
end

-- Docking bridges the pad's wired network in, so more peripherals become
-- visible. Named pad_* so they cannot be confused with the craft's own.
local padPeriphs = {}
for i = 1, 4 do padPeriphs["pad_device_" .. i] = { __type = "modem" } end

_G.peripheral = {
  find = function(ptype)
    local out = {}
    for _, p in pairs(periphs) do if p.__type == ptype then out[#out + 1] = p end end
    table.sort(out, function(a, b) return names[a] < names[b] end)
    return table.unpack(out)
  end,
  wrap = function(name) return periphs[name] end,
  getType = function(name) local p = periphs[name] return p and p.__type or nil end,
  isPresent = function(name)
    -- LOSE_THRUSTER=<name> makes that peripheral vanish after 10 s, to
    -- exercise the monitoring path
    if os.getenv('LOSE_THRUSTER') == name and T > 10 then return false end
    return periphs[name] ~= nil
  end,
  getName = function(p) return names[p] end,
  getNames = function()
    local out = {}
    for nm in pairs(periphs) do out[#out+1] = nm end
    -- latching bridges the pad's network in, which is the only dock signal an
    -- unnamed pad gives
    if sim.docked then for nm in pairs(padPeriphs) do out[#out+1] = nm end end
    table.sort(out)
    return out
  end,
  getType = function(name) return periphs[name] and periphs[name].__type or nil end,
  getMethods = function(name)
    local p = periphs[name]
    if not p then return nil end
    local out = {}
    for k, v in pairs(p) do if type(v) == "function" then out[#out + 1] = k end end
    return out
  end,
}

-- cooperative scheduler
local function scheduler(untilAll, ...)
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
      if coroutine.status(cos[best]) == "dead" and not untilAll then return end
      wake[best] = T + (tonumber(a) or 0)
    end
end
_G.parallel = {
  waitForAny = function(...) return scheduler(false, ...) end,
  waitForAll = function(...) return scheduler(true, ...) end,
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
  getLinearVelocity = function() return { x = sim.wvx or 0, y = sim.vv, z = sim.wvz or 0 } end,
  getAngularVelocity = function() return { x = 0, y = 0, z = 0 } end,
  getVelocity = function() return { x = sim.speed, y = sim.vv, z = 0 } end,
  getCenterOfMass = function() return { x = 0, y = 0, z = 0 } end,
  getMass = function() return 1234.5 end,
}
_G.term = { clear = function() end, setCursorPos = function() end }

-- Lua 5.1 had math.atan2; this harness runs on a newer Lua where it is gone.
math.atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

_G.arg = ARGS

-- CraftOS runs every program inside a coroutine, so `sleep` works at the top
-- level of a script. Run it the same way or the harness lies about that.
local f = assert(loadfile(SCRIPT))
local ok, err = true, nil
do
  local co = coroutine.create(f)
  local guard = 0
  local first = true
  while coroutine.status(co) ~= "dead" do
    guard = guard + 1
    if guard > 500000 then ok, err = false, "harness: top-level step limit" break end
    -- CraftOS passes a program's arguments as varargs as well as setting the
    -- global `arg`. Programs use either, so the harness must do both.
    local res, a
    if first then
      first = false
      res, a = coroutine.resume(co, table.unpack(ARGS or {}))
    else
      res, a = coroutine.resume(co)
    end
    if not res then ok, err = false, a break end
    if type(a) == "number" then T = T + a step(T) end
  end
end
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
if _G.notesPlayed then print("notes played: " .. #notesPlayed .. "  " .. table.concat(notesPlayed, " ")) end
