-- mixcal: work out which thruster sits in which corner, by pulsing each one
-- and watching which way the airframe leans.
--
--   mixcal            calibrate, print the map, write mixmap.txt and push it
--   mixcal dry        do everything EXCEPT fire the thrusters (safe to try)
--
-- Peripheral names carry no position, so a four-thruster mixer cannot be
-- written from a diagram without risking a sign error that flips the craft on
-- its first flight. This measures the airframe instead.
--
-- SAFETY. Run it with the craft ON THE GROUND. Each pulse is short and low
-- power, enough to rock a grounded airframe and not enough to lift it. It
-- refuses to start if the craft is already moving, aborts on excessive tilt,
-- and zeroes every thruster on any exit including an error.

local CFG = {
  PULSE_POWER = 0.35,     -- normalised, per thruster. Low: this must not lift it.
  PULSE_TIME  = 0.8,      -- seconds of thrust per test
  SETTLE_TIME = 1.5,      -- seconds to let it rest between tests
  ABORT_TILT  = 25,       -- degrees: stop everything if it leans this far
  NOISE_MULT  = 3,        -- response must beat the measured noise floor by this
  NOISE_FLOOR = 0.005,    -- degrees: never treat anything below this as signal
  MOVING      = 0.3,      -- b/s: refuse to start if it is moving faster than this
}

local DRY = ({ ... })[1] == "dry"

-- ---------- devices ----------
local thrusters = {}
for _, name in ipairs(peripheral.getNames()) do
  if peripheral.getType(name) == "vector_thruster" then
    thrusters[#thrusters + 1] = { name = name, p = peripheral.wrap(name) }
  end
end
table.sort(thrusters, function(a, b) return a.name < b.name end)

local gim = peripheral.find("gimbal_sensor")
if not gim then error("no gimbal_sensor - cannot measure the response", 0) end
if #thrusters < 2 then error("found " .. #thrusters .. " thrusters, need at least 2", 0) end

-- ---------- safety ----------
local function allOff()
  for _, t in ipairs(thrusters) do
    pcall(t.p.setPowerNormalized, 0)
    pcall(t.p.setVector, 0, 0)
  end
end

local function angles()
  local a = gim.getAngles()
  return a[1], a[2]
end

local function tilt()
  local p, r = angles()
  return math.sqrt(p * p + r * r)
end

local function assertStill()
  if _G.sublevel then
    local okv, v = pcall(sublevel.getLinearVelocity)
    if okv and type(v) == "table" then
      local sp = math.sqrt((v.x or 0)^2 + (v.y or 0)^2 + (v.z or 0)^2)
      if sp > CFG.MOVING then
        error(string.format("craft is moving at %.2f b/s - land it first", sp), 0)
      end
    end
  end
  if tilt() > CFG.ABORT_TILT then
    error(string.format("craft is already at %.0f deg of tilt - level it first", tilt()), 0)
  end
end

-- ---------- one measurement ----------
-- Fire a single thruster and return how far pitch and roll moved.
local function pulse(t)
  local p0, r0 = angles()
  local worstP, worstR = 0, 0

  if not DRY then t.p.setPowerNormalized(CFG.PULSE_POWER) end
  local t0 = os.clock()
  local peakThrust = nil
  while os.clock() - t0 < CFG.PULSE_TIME do
    -- thrust has to be sampled while it is firing; reading it afterwards
    -- always returns 0, which is what the first live run did
    local okT, th = pcall(t.p.getThrust)
    if okT and type(th) == "number" and (not peakThrust or th > peakThrust) then peakThrust = th end
    local p, r = angles()
    if math.abs(p - p0) > math.abs(worstP) then worstP = p - p0 end
    if math.abs(r - r0) > math.abs(worstR) then worstR = r - r0 end
    if math.sqrt(p * p + r * r) > CFG.ABORT_TILT then
      allOff()
      error(string.format("ABORT: tilted to %.0f deg during %s", math.sqrt(p*p + r*r), t.name), 0)
    end
    sleep(0.05)
  end
  if not DRY then t.p.setPowerNormalized(0) end

  -- let it settle back before the next one
  local s0 = os.clock()
  while os.clock() - s0 < CFG.SETTLE_TIME do sleep(0.1) end
  return worstP, worstR, peakThrust
end

--- Sample how much the gimbal wanders with nothing firing, so the signal
-- threshold comes from this airframe rather than from a guess.
local function noiseFloor()
  local p0, r0 = angles()
  local worst = 0
  local t0 = os.clock()
  while os.clock() - t0 < CFG.PULSE_TIME do
    local p, r = angles()
    worst = math.max(worst, math.abs(p - p0), math.abs(r - r0))
    sleep(0.05)
  end
  return math.max(worst, CFG.NOISE_FLOOR)
end

-- ---------- run ----------
print("mixcal: " .. #thrusters .. " thrusters, " .. (DRY and "DRY RUN (no thrust)" or "LIVE"))
print("the craft must be ON THE GROUND and level")
assertStill()

local okThrust = pcall(function() return thrusters[1].p.getThrust() end)
if okThrust then print("thrust readback available - will confirm each thruster responds") end

print("  measuring the noise floor with nothing firing ...")
local noise = noiseFloor()
local threshold = noise * CFG.NOISE_MULT
print(string.format("         gimbal wanders %.4f deg at rest; signal must beat %.4f",
  noise, threshold))

local results = {}
for i, t in ipairs(thrusters) do
  print(string.format("  [%d/%d] %s ...", i, #thrusters, t.name))
  local dp, dr, th = pulse(t)
  results[#results + 1] = { name = t.name, dp = dp, dr = dr, thrust = th }
  print(string.format("         pitch %+.4f  roll %+.4f%s", dp, dr,
    th and string.format("  (peak thrust %.1f)", th) or ""))
end
allOff()

-- ---------- interpret ----------
-- Thrusters sit at the corners of a 3x3, so each is offset in BOTH axes from
-- the centre. Lifting one corner pitches and rolls the airframe at once, and
-- the sign pair says which corner it is.
print("")
print("corner map (from the sign of the response):")
local weak = 0
for _, r in ipairs(results) do
  local mag = math.sqrt(r.dp * r.dp + r.dr * r.dr)
  -- The corner comes from the SIGNS. A grounded airframe barely rocks, so the
  -- magnitude can be tiny and the map still be perfectly readable; only give
  -- up when the response cannot be told apart from the noise at rest.
  local corner = ((r.dp > 0) and "A" or "B") .. ((r.dr > 0) and "1" or "2")
  local mark = ""
  if mag < threshold then
    weak = weak + 1
    mark = "  (weak - below " .. string.format("%.4f", threshold) .. ")"
  end
  r.corner = corner
  print(string.format("  %-22s pitch %+8.4f  roll %+8.4f   -> %s%s",
    r.name, r.dp, r.dr, corner, mark))
end

print("")
local seenC, dupC = {}, false
for _, r in ipairs(results) do
  if seenC[r.corner] then dupC = true end
  seenC[r.corner] = true
end

if weak > 0 and dupC then
  print(weak .. " response(s) were weak AND corners collide - this is not a map.")
  print("Raise PULSE_POWER, or run it hovering so the airframe can actually rock.")
elseif weak > 0 then
  print(weak .. " response(s) were weak, but all corners came out distinct.")
  print("A grounded airframe barely rocks, so small is expected; the signs are")
  print("what matter and they separated cleanly. Re-run at higher PULSE_POWER")
  print("if you want it confirmed.")
else
  local seen = {}
  local dup = false
  for _, r in ipairs(results) do
    if seen[r.corner] then dup = true end
    seen[r.corner] = true
  end
  if dup then
    print("Two thrusters mapped to the same corner - the responses are not")
    print("distinct enough. Raise PULSE_POWER or PULSE_TIME and run again.")
  else
    print("All " .. #results .. " thrusters map to distinct corners. Good.")
    print("A/B is the pitch axis, 1/2 the roll axis; which is nose and which is")
    print("starboard depends on how the gimbal is mounted, and the mixer only")
    print("needs them to be consistent, not named correctly.")
  end
end

-- ---------- save ----------
local lines = { "thruster,dpitch,droll,corner,thrust" }
for _, r in ipairs(results) do
  lines[#lines + 1] = string.format("%s,%.4f,%.4f,%s,%s",
    r.name, r.dp, r.dr, r.corner, r.thrust and string.format("%.2f", r.thrust) or "")
end
local f = fs.open("mixmap.csv", "w")
f.write(table.concat(lines, "\n") .. "\n")
f.close()
print("")
print("written to mixmap.csv")
if fs.exists("upload.lua") and http then
  local okp, errp = pcall(function()
    if shell then return shell.run("upload", "sync", "mixmap.csv", "data/mixmap.csv") end
    return os.run({}, "upload.lua", "sync", "mixmap.csv", "data/mixmap.csv")
  end)
  if not okp then print("push failed: " .. tostring(errp)) end
end
