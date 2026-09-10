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
  PITCH_AUTH = 0.25,   -- max share of range spent on pitch
  ROLL_AUTH  = 0.25,
  VEC_MAX    = 1.0,    -- nozzle vector clamp
  YAW_AUTH   = 0.35,   -- max nozzle deflection spent on yaw rate
  -- How setVector(x, y) maps onto the body axes. The single-thruster code used
  -- P_AXIS = "y", meaning x drove roll and y drove pitch; the same convention
  -- is kept here so a known-good mapping carries over.
  VEC_X_IS   = "lat",  -- what setVector's first argument pushes along
  VEC_Y_IS   = "fwd",
  VEC_X_SIGN = 1,
  VEC_Y_SIGN = 1,
  ATTITUDE_PRIORITY = true,  -- on saturation, give up lift before attitude
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
  local pitch = (d.pitch or 0) * cfg.PITCH_AUTH
  local roll  = (d.roll  or 0) * cfg.ROLL_AUTH
  local n = #mixer.cfg.thrusters
  if n == 0 then return {}, false end

  local out, sat = {}, false
  local lo, hi = math.huge, -math.huge
  for i, t in ipairs(mixer.cfg.thrusters) do
    local v = lift + pitch * t.pitch + roll * t.roll
    out[i] = v
    if v < lo then lo = v end
    if v > hi then hi = v end
  end

  -- Saturation. Attitude is what keeps the craft the right way up, so when
  -- there is not enough range for both, move the whole set to make the
  -- differential fit and let lift suffer. Only if the differential ALONE
  -- cannot fit do we scale it down.
  if lo < 0 or hi > 1 then
    sat = true
    if cfg.ATTITUDE_PRIORITY then
      local span = hi - lo
      if span > 1 then
        -- differential is wider than the whole range: scale it
        local k = 1 / span
        local mid = (hi + lo) / 2
        for i = 1, n do out[i] = (out[i] - mid) * k + 0.5 end
      else
        local shift = 0
        if lo < 0 then shift = -lo elseif hi > 1 then shift = 1 - hi end
        for i = 1, n do out[i] = out[i] + shift end
      end
    else
      for i = 1, n do out[i] = math.max(0, math.min(1, out[i])) end
    end
  end

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

--- Allocate and push to the hardware. One power call per thruster plus a
-- vector call whenever that thruster's vector changes.
-- Returns thrusts, vectors, saturated.
function mixer.write(d)
  local thrusts, sat = mixer.allocate(d)
  local vecs = mixer.vectors(d)
  for i, w in ipairs(wrapped) do
    -- every call is a game tick, so write only what changed: power holds
    -- still in vector mode at fixed lift, vectors hold still in diff mode
    local pw = thrusts[i] or 0
    if not w.lp or math.abs(w.lp - pw) > 1e-3 then
      if pcall(w.p.setPowerNormalized, pw) then w.lp = pw end
    end
    local x = vecs[i] and vecs[i].x or 0
    local y = vecs[i] and vecs[i].y or 0
    if not w.lv or math.abs(w.lv.x - x) > 1e-6 or math.abs(w.lv.y - y) > 1e-6 then
      if pcall(w.p.setVector, x, y) then w.lv = { x = x, y = y } end
    end
  end
  return thrusts, vecs, sat
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
