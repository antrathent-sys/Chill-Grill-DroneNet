--- mixer: turn one set of body-axis demands into four thruster commands.
--
-- The airframe is four vector thrusters at the corners of a 3x3, so a standard
-- quad X. Which peripheral sits in which corner was measured by mixcal, not
-- assumed, and is passed in via configure().
--
--   local mixer = dofile("lib/mixer.lua")
--   mixer.configure({ thrusters = {
--     { name = "vector_thruster_5", pitch = -1, roll =  1 },
--     { name = "vector_thruster_6", pitch = -1, roll = -1 },
--     { name = "vector_thruster_7", pitch =  1, roll = -1 },
--     { name = "vector_thruster_8", pitch =  1, roll =  1 },
--   }})
--   mixer.write({ lift = 0.5, pitch = 0.1, roll = 0, yawRate = 0, fwd = 0, lat = 0 })
--
-- `pitch` and `roll` are the SIGN of the gimbal response when that thruster
-- alone fires. Nothing here needs to know which way is physically forward, only
-- that the signs are consistent, which two mixcal runs confirmed.
--
-- WHAT THIS CAN AND CANNOT DO
--   lift, pitch, roll  - fully controllable from differential thrust
--   horizontal force   - from vectoring all four nozzles together, which moves
--                        the craft WITHOUT tilting it
--   yaw RATE           - from vectoring the nozzles tangentially. Damping only:
--                        there is no absolute yaw sensor on this airframe, so a
--                        heading cannot be held, only a spin arrested.

local mixer = {}

mixer.cfg = {
  thrusters = {},
  PITCH_AUTH = 0.4,    -- max share of range spent on pitch (0.25 until the 100 b/s departure)
  ROLL_AUTH  = 0.4,
  VEC_MAX    = 1.0,    -- nozzle vector clamp
  YAW_AUTH   = 0.35,   -- max nozzle deflection spent on yaw rate
  -- How setVector(x, y) maps onto the body axes. The single-thruster code used
  -- P_AXIS = "y", meaning x drove roll and y drove pitch; the same convention
  -- is kept here so a known-good mapping carries over.
  VEC_X_IS   = "lat",  -- what setVector's first argument pushes along
  VEC_Y_IS   = "fwd",
  VEC_X_SIGN = 1,
  VEC_Y_SIGN = 1,
  LIFT_SLACK = 0,            -- how far the mean may rise above the lift demand to buy differential.
                             -- 0 keeps the altitude loop honest; see allocate().
}

local wrapped = {}

--- Attach to the thrusters named in the config. Returns count, missing names.
function mixer.configure(opts)
  for k, v in pairs(opts or {}) do mixer.cfg[k] = v end
  wrapped = {}
  local missing = {}
  for i, t in ipairs(mixer.cfg.thrusters) do
    local p = peripheral and peripheral.wrap(t.name) or nil
    if p then
      wrapped[i] = { p = p, pitch = t.pitch, roll = t.roll, name = t.name }
    else
      missing[#missing + 1] = t.name
    end
  end
  return #wrapped, missing
end

function mixer.count() return #wrapped end

--- Work out per-thruster thrust for a set of demands.
-- Pure arithmetic: no peripheral calls, so it is cheap and testable.
-- Returns an array of normalised thrusts and a saturation flag.
function mixer.allocate(d)
  local cfg = mixer.cfg
  local lift = d.lift or 0
  -- tangential (yaw) deflection tips every nozzle off the thrust axis by
  -- about yawRate * YAW_AUTH radians; scale lift up by 1/cos so the vertical
  -- component is what was asked for
  local ydef = math.abs(d.yawRate or 0) * cfg.YAW_AUTH
  if ydef > 0 then lift = lift / math.max(0.5, math.cos(math.min(ydef, 1.2))) end
  local pitch = (d.pitch or 0) * cfg.PITCH_AUTH
  local roll  = (d.roll  or 0) * cfg.ROLL_AUTH
  local n = #mixer.cfg.thrusters
  if n == 0 then return {}, false end

  -- The differential, as a set with mean zero. Subtracting its own mean is
  -- what lets the lift demand survive: whatever happens to the shape below,
  -- the average of the four thrusts stays where the altitude loop put it.
  local out, sat = {}, false
  local diff, dsum = {}, 0
  for i, t in ipairs(mixer.cfg.thrusters) do
    diff[i] = pitch * t.pitch + roll * t.roll
    dsum = dsum + diff[i]
  end
  local dmean = dsum / n
  local lo, hi = math.huge, -math.huge
  for i = 1, n do
    diff[i] = diff[i] - dmean
    if diff[i] < lo then lo = diff[i] end
    if diff[i] > hi then hi = diff[i] end
  end

  -- LIFT IS PRESERVED, THE DIFFERENTIAL IS SCALED TO FIT.
  --
  -- The old rule was the other way round: shift the whole set so the
  -- differential fits and let lift suffer. That silently pinned mean thrust
  -- near 0.50 whenever both axes saturated - measured in flight on
  -- 2026-09-11, where a commanded 1.00 and a commanded 0.00 both came out at
  -- 0.500 - so the altitude loop was disconnected from the hardware exactly
  -- when it mattered. A departure became a climb to 1457 m, and a landing
  -- creep asking for 0.02 got 0.30 and hung above the ground.
  --
  -- Losing differential instead costs attitude authority only when lift is
  -- low, and lift is low only when descending. In cruise the tilt
  -- feed-forward already puts lift at 0.5-0.6, where almost all of the
  -- differential still fits. LIFT_SLACK allows a little shift back if an
  -- airframe ever needs it; 0 means the mean is exactly what was asked for.
  local base = lift
  if lo < 0 then
    local need = -lo - lift              -- how far the lowest thruster goes below zero
    if need > 0 then base = lift + math.min(need, cfg.LIFT_SLACK or 0) end
  end
  local k = 1
  if hi > 0 then k = math.min(k, (1 - base) / hi) end
  if lo < 0 then k = math.min(k, base / -lo) end
  k = math.max(0, math.min(1, k))
  sat = k < 1 - 1e-9
  for i = 1, n do out[i] = base + k * diff[i] end

  for i = 1, n do out[i] = math.max(0, math.min(1, out[i])) end
  return out, sat
end

--- Nozzle vector for each thruster: a common part that translates the craft,
-- plus a tangential part that spins it.
function mixer.vectors(d)
  local cfg = mixer.cfg
  local fwd, lat = d.fwd or 0, d.lat or 0
  local yaw = (d.yawRate or 0) * cfg.YAW_AUTH
  local out = {}
  for i, t in ipairs(mixer.cfg.thrusters) do
    -- Tangential direction at a corner: rotate the corner's own offset a
    -- quarter turn. Using the measured pitch/roll signs as that offset means
    -- this needs no separate geometry.
    local tanFwd = -t.roll * yaw
    local tanLat =  t.pitch * yaw
    local bodyFwd = fwd + tanFwd
    local bodyLat = lat + tanLat

    local x = (cfg.VEC_X_IS == "fwd") and bodyFwd or bodyLat
    local y = (cfg.VEC_Y_IS == "fwd") and bodyFwd or bodyLat
    x = x * cfg.VEC_X_SIGN
    y = y * cfg.VEC_Y_SIGN
    local m = cfg.VEC_MAX
    out[i] = {
      x = math.max(-m, math.min(m, x)),
      y = math.max(-m, math.min(m, y)),
    }
  end
  return out
end

--- Allocate and push to the hardware.
--
-- Every thruster call is a main-thread task, i.e. one game tick, and four
-- thrusters written one after another cost four ticks - the control loop
-- measured 0.25 s per iteration that way, which is what made the attitude
-- loop ring. Tasks queued from DIFFERENT coroutines run in the same tick, so
-- each write is issued from its own coroutine under parallel.waitForAll and
-- the whole set costs one tick. Writes whose value has not changed are
-- skipped altogether.
-- Returns thrusts, vectors, saturated.
local unpack_ = unpack or table.unpack
function mixer.write(d)
  local thrusts, sat = mixer.allocate(d)
  local vecs = mixer.vectors(d)
  local jobs = {}
  for i, w in ipairs(wrapped) do
    local pw = thrusts[i] or 0
    if not w.lp or math.abs(w.lp - pw) > 1e-3 then
      jobs[#jobs + 1] = function()
        if pcall(w.p.setPowerNormalized, pw) then w.lp = pw w.fail = 0
        else w.fail = (w.fail or 0) + 1 end
      end
    end
    local x = vecs[i] and vecs[i].x or 0
    local y = vecs[i] and vecs[i].y or 0
    if not w.lv or math.abs(w.lv.x - x) > 1e-6 or math.abs(w.lv.y - y) > 1e-6 then
      jobs[#jobs + 1] = function()
        if pcall(w.p.setVector, x, y) then w.lv = { x = x, y = y } w.fail = 0
        else w.fail = (w.fail or 0) + 1 end
      end
    end
  end
  if #jobs > 1 and parallel and parallel.waitForAll then
    parallel.waitForAll(unpack_(jobs))
  else
    for _, j in ipairs(jobs) do j() end
  end
  return thrusts, vecs, sat
end

--- Thrusters whose last `n` writes all failed. Free: the counter is kept by
-- write() itself, no extra peripheral calls. A thruster that has dropped off
-- the wired network fails silently otherwise, because every write is pcall'd.
-- Blind spot: a thruster whose command has not changed is not written at all,
-- so pair this with a presence check in the slow loop.
function mixer.faults(n)
  local out = {}
  for _, w in ipairs(wrapped) do
    if (w.fail or 0) >= (n or 3) then out[#out + 1] = w.name end
  end
  return out
end

--- Cut everything. Used by the exit path and by kill.
function mixer.stop()
  for _, w in ipairs(wrapped) do
    pcall(w.p.setPowerNormalized, 0)
    pcall(w.p.setVector, 0, 0)
    w.lv, w.lp = nil, nil
  end
end

--- Read actual thrust back, to catch a thruster that is dead, starved or
-- saturated. Costs one call per thruster, so this belongs in the monitoring
-- coroutine and NOT in the control loop.
function mixer.health()
  local out = {}
  for i, w in ipairs(wrapped) do
    local okT, th = pcall(w.p.getThrust)
    local okP, pw = pcall(w.p.getPower)
    out[i] = { name = w.name, thrust = okT and th or nil, power = okP and pw or nil }
  end
  return out
end

--- The map mixcal produced, as a config table. Corner strings are the "A1"
-- style labels mixcal prints.
function mixer.fromCorners(map)
  local ts = {}
  for name, corner in pairs(map) do
    ts[#ts + 1] = {
      name = name,
      pitch = corner:sub(1, 1) == "A" and 1 or -1,
      roll  = corner:sub(2, 2) == "1" and 1 or -1,
    }
  end
  table.sort(ts, function(a, b) return a.name < b.name end)
  return ts
end

return mixer
