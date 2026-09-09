-- fly find <power>            -> hold fixed power, find hover point
-- fly <y> [x] [z]             -> hold Y, hold position or fly to x z
-- fly dash <y> <deg> <secs>   -> climb to Y, hold, pitch <deg> for <secs>, level, hold
-- writes flightlog on the computer every run
local CFG = {
  HOVER = 0.5,
  AKP = 0.03, AKI = 0.01, AKD = 0.1,
  PMAX = 0.35,                        -- altitude P clamp

  -- attitude gains, scheduled by tilt magnitude
  KP_HOVER = 0.010, KI_HOVER = 0.005, KD_HOVER = 0.012,
  KP_DASH  = 0.020, KI_DASH  = 0.003, KD_DASH  = 0.020,
  SCHED_LO = 10, SCHED_HI = 40,       -- deg: all-hover below LO, all-dash above HI
  IMAX = 0.4,
  VEC_MAX = 1.0,                      -- full nozzle authority
  P_AXIS = "y", P_SIGN = 1,
  R_SIGN = 1,

  PKP = 0.2, VMAX = 3, PKV = 1.0,
  PKI = 0.05, TRIM_MAX = 3,
  TILT_MAX = 3,
  SPEED_GUARD = 4,
  PITCH_DIR = -1, ROLL_DIR = 1,
  HDG_SIGN = 1,
  HDG_OFFSET = 270,
  HDG_ALPHA = 0.15,
  -- Velocity sensors, addressed BY NAME so peripheral.find ordering can't
  -- shuffle them. Identified in freefall: velocity_sensor_3 read -24 b/s while
  -- the others read ~0, so that one faces vertically (negative = falling).
  VRT_NAME = "velocity_sensor_3", VRT_SIGN = -1,
  FWD_NAME = "velocity_sensor_0", FWD_SIGN2 = -1,
  LAT_NAME = "velocity_sensor_1", LAT_SIGN = 1,
  -- Heading from MOTION: world displacement (gps) vs body travel direction
  -- (sensors). The difference is our facing. Latched between updates.
  HDG_WIN = 1.0,                      -- seconds of displacement per estimate
  HDG_MIN_MOVE = 2,                   -- blocks moved in the window to trust it
  HDG_RATE = 0.02,                    -- slow: the pod barely yaws, so latch hard
  NAV_FALLBACK = false,               -- nav table reads ~180 deg out: don't lean until motion locks
  TUMBLE = 85,
  DASH_SETTLE = 3.0,                  -- transition this many blocks below goal
  CLIMB_POWER = 0.9,                  -- throttle on the way up
  CLIMB_RATE = 10,                    -- b/s target climb rate
  DASH_DIR = -1,
  DASH_POWER = 0.25,
  TILT_RATE = 60,                     -- deg/s: how fast tilt targets may move

  -- brake: pitch the other way to kill forward speed
  BRAKE_DEG = 45,                     -- how hard to pitch back against the motion
  BRAKE_DONE = 3.0,                   -- b/s: below this, brake is finished
  BRAKE_MAX_T = 20,                   -- give up after this many seconds
  BRAKE_EASE = 4,                     -- b/s over which brake tilt ramps to full

  -- go mode
  CRUISE_DEG = 70,                    -- max lean during cruise
  CRUISE_SPEED = 8,                  -- b/s target closing speed
  CKV = 3,                            -- deg of lean per b/s of velocity error
  BRAKE_K = 1.0,                      -- brake distance = K * speed^2 / 10
  ARRIVE = 8,                         -- blocks: close enough to hand over to hold

  -- monitoring: accumulator and thruster buffer are polled in their own
  -- coroutine, never from the control loop
  MON_POLL = 1.0,                     -- seconds between reads (one peripheral call per source)
  ENERGY_WARN = 25,                   -- %: print LOW ENERGY (accumulator) when it drops below this
  FUEL_MODE = "fe",                   -- "fe": thruster FE buffer first; "fluid": liquid tank first
  FUEL_NAME = nil,                    -- thruster-side source; nil = the thruster itself
  FUEL_CAP = 0,                       -- mB; only needed when a fluid source reports amount but not capacity
  FUEL_WARN = 25,                     -- %: print LOW THRUSTER when the thruster buffer drops below this
  -- pump auto-start: switched on before takeoff, off when the program exits
  PUMP_SIDE = nil,                    -- redstone side to hold high, e.g. "back" -> clutch on the pump shaft
  PUMP_MOTOR = nil,                   -- CC&A electric motor peripheral name that spins the pump
  PUMP_RPM = 32,
  PUMP_PRIME = 0,                     -- seconds to wait after starting the pump before flying
}

local alt = peripheral.find("altitude_sensor")
local gim = peripheral.find("gimbal_sensor")
local nav = peripheral.find("navigation_table")
local thr = peripheral.find("vector_thruster")
local acc = peripheral.find("modular_accumulator")
local vels = { peripheral.find("velocity_sensor") }
for k, v in pairs({ alt = alt, gim = gim, nav = nav, thr = thr }) do if not v then error("missing " .. k) end end

local function clamp(v, l) return math.max(-l, math.min(l, v)) end
local function rawHeading() return (CFG.HDG_SIGN * nav.getRelativeAngle() + CFG.HDG_OFFSET) % 360 end
local function drive(p, vx, vy)
  thr.setVector(vx, vy)
  thr.setPowerNormalized(math.max(0, math.min(1, p)))
end
-- ---------- monitoring ----------
-- Accumulator % and the thruster's own buffer are read in monLoop once per
-- MON_POLL. The control loop never touches them, it only logs the latest.
local mon  = { energy = -1, rate = 0, t = 0 }   -- rate: accumulator %/min, negative = draining
local fuel = { pct = -1, amt = -1, cap = -1, t = 0 }

-- Which method reads the thruster side depends on mode and mod version, so
-- probe once at startup and remember.
local fuelRead, fuelLabel = nil, "FUEL"
do
  local name = CFG.FUEL_NAME or peripheral.getName(thr)
  local p = CFG.FUEL_NAME and peripheral.wrap(CFG.FUEL_NAME) or thr
  local has = {}
  if p then for _, m in ipairs(peripheral.getMethods(name) or {}) do has[m] = true end end
  local function tryFE()
    -- CC:Tweaked generic energy_storage: the block's own FE buffer
    if has.getEnergy and has.getEnergyCapacity then
      fuelRead = function() return p.getEnergy(), p.getEnergyCapacity() end
      fuelLabel = "THRUSTER"
      print("thruster: " .. name .. " FE via getEnergy/getEnergyCapacity")
      return true
    end
    return false
  end
  local function tryFluid()
    if has.getFuelAmount and has.getFuelCapacity then
      fuelRead = function() return p.getFuelAmount(), p.getFuelCapacity() end
      print("fuel: " .. name .. " via getFuelAmount/getFuelCapacity")
      return true
    elseif has.tanks then
      -- CC:Tweaked generic fluid_storage: amounts only, capacity comes from CFG
      fuelRead = function()
        local sum = 0
        for _, tk in pairs(p.tanks() or {}) do sum = sum + (tk.amount or 0) end
        return sum, CFG.FUEL_CAP > 0 and CFG.FUEL_CAP or nil
      end
      print("fuel: " .. name .. " via tanks()" .. (CFG.FUEL_CAP > 0 and "" or " (set FUEL_CAP for %)"))
      return true
    end
    return false
  end
  if not p then
    print("WARNING: source " .. tostring(name) .. " not found - thruster monitoring off")
  elseif CFG.FUEL_MODE == "fe" then
    local _ = tryFE() or tryFluid()
  else
    local _ = tryFluid() or tryFE()
  end
  if p and not fuelRead then
    local list = {}
    for m in pairs(has) do list[#list + 1] = m end
    table.sort(list)
    print("WARNING: no energy/fuel method on " .. name .. " - thruster monitoring off")
    print("  methods: " .. table.concat(list, " "))
  end
end

local function monLoop()
  local warnE, warnF = false, false
  local lastE, lastT = nil, nil
  while true do
    if acc then
      local ok, pct = pcall(acc.getPercent)
      if ok and pct then
        local now = os.clock()
        if lastE and now > lastT then
          local r = (pct - lastE) / (now - lastT) * 60
          mon.rate = mon.rate + 0.2 * (r - mon.rate)
        end
        lastE, lastT = pct, now
        mon.energy, mon.t = pct, now
        if pct < CFG.ENERGY_WARN and not warnE then
          warnE = true
          local eta = mon.rate < 0 and string.format(" (~%.1f min to empty)", -pct / mon.rate) or ""
          print(string.format("LOW ENERGY %.0f%%%s", pct, eta))
        elseif pct >= CFG.ENERGY_WARN + 5 then
          warnE = false
        end
      end
    end
    if fuelRead then
      local ok, amt, cap = pcall(fuelRead)
      if ok and amt then
        fuel.amt, fuel.cap, fuel.t = amt, cap or -1, os.clock()
        fuel.pct = (cap and cap > 0) and (100 * amt / cap) or -1
        if fuel.pct >= 0 then
          if fuel.pct < CFG.FUEL_WARN and not warnF then
            warnF = true print(string.format("LOW %s %.0f%%", fuelLabel, fuel.pct))
          elseif fuel.pct >= CFG.FUEL_WARN + 5 then
            warnF = false
          end
        end
      end
    end
    sleep(CFG.MON_POLL)
  end
end

-- pump: hold a redstone side and/or spin a CC&A electric motor for the flight
local pumpMotor = CFG.PUMP_MOTOR and peripheral.wrap(CFG.PUMP_MOTOR) or nil
if CFG.PUMP_MOTOR and not pumpMotor then print("WARNING: pump motor " .. CFG.PUMP_MOTOR .. " not found") end
local function pump(on)
  if CFG.PUMP_SIDE then redstone.setOutput(CFG.PUMP_SIDE, on) end
  if pumpMotor then
    if on then pumpMotor.setSpeed(CFG.PUMP_RPM) else pumpMotor.stop() end
  end
end
-- forward (nose-axis) speed from the velocity sensor, positive = moving forward
local pos = { x = 0, z = 0, vx = 0, vz = 0, t = 0, rej = 0 }

-- raw sensor reads, in the AIRFRAME's own (tilted) frame
local sFwd = peripheral.wrap(CFG.FWD_NAME)
local sLat = CFG.LAT_NAME and peripheral.wrap(CFG.LAT_NAME) or nil
local sVrt = CFG.VRT_NAME and peripheral.wrap(CFG.VRT_NAME) or nil
if not sFwd then error("forward velocity sensor " .. tostring(CFG.FWD_NAME) .. " not found") end
if not sLat then print("WARNING: no lateral velocity sensor") end
if not sVrt then print("WARNING: no vertical sensor - tilt correction off") end

local function rawFwd() return CFG.FWD_SIGN2 * sFwd.getVelocity() end
local function rawLat() return sLat and CFG.LAT_SIGN * sLat.getVelocity() or 0 end
local function rawVrt() return sVrt and CFG.VRT_SIGN * sVrt.getVelocity() or 0 end

-- Sensors are bolted to the airframe and tilt with it. With the vertical axis
-- measured we can rotate the body vector back to level, so "forward" means
-- horizontal-forward even at 70 degrees of lean.
local function bodyVel(p, r)
  local f, l, u = rawFwd(), rawLat(), rawVrt()
  if not sVrt then return f, l end
  local cp, sp = math.cos(math.rad(p)), math.sin(math.rad(p))
  local cr, sr = math.cos(math.rad(r)), math.sin(math.rad(r))
  return f * cp + u * sp, l * cr + u * sr
end


local bodyF, bodyL = 0, 0
local function fwdSpeed() return bodyF end
local function latSpeed() return bodyL end

-- heading from the nav table, low-pass filtered
-- The navigation table measures a bearing IN ITS OWN PLANE. Bolted to the pod,
-- that plane tips with the airframe, so at 60 deg of lean the reported angle is
-- the target direction projected onto a tipped plane -- not the true bearing.
-- Undo it: build the unit vector the table implies, rotate it back out of the
-- pod's pitch/roll, then read the horizontal bearing off the result.
local function correctedHeading(p, r)
  local ang = math.rad(rawHeading())
  -- direction in the pod's own plane (x right, y forward, z up-out-of-plane)
  local vx, vy, vz = math.sin(ang), math.cos(ang), 0
  local cp, sp = math.cos(math.rad(p)), math.sin(math.rad(p))
  local cr, sr = math.cos(math.rad(r)), math.sin(math.rad(r))
  -- rotate out of roll (about the forward axis), then pitch (about the right axis)
  local x1, y1, z1 = vx * cr + vz * sr, vy, -vx * sr + vz * cr
  local x2, y2     = x1, y1 * cp + z1 * sp
  return math.deg(math.atan2(x2, y2)) % 360
end

local hs, hc = 0, 1
do local a0 = gim.getAngles() local r0 = math.rad(correctedHeading(a0[1], a0[2]))
   hs, hc = math.sin(r0), math.cos(r0) end
local function navHeading()
  local a0 = gim.getAngles()
  local r = math.rad(correctedHeading(a0[1], a0[2]))
  hs = hs + CFG.HDG_ALPHA * (math.sin(r) - hs)
  hc = hc + CFG.HDG_ALPHA * (math.cos(r) - hc)
  return math.deg(math.atan2(hs, hc)) % 360
end

-- heading derived from velocity: the angle between world motion (gps) and
-- body motion (sensors). Immune to spin, but only valid while moving.
-- Motion-derived heading. Over a window we measure how far we moved in the
-- world (gps, coarse but unbiased) and the average direction we were moving in
-- the body frame (sensors, smooth). The angle between them is our facing.
-- Latched: it only changes while there is real movement to measure.
local motHdg = nil
local win = { t = 0, x = 0, z = 0, sf = 0, sl = 0, n = 0 }

local function updateMotionHeading(now)
  if win.t == 0 then
    win.t, win.x, win.z, win.sf, win.sl, win.n = now, pos.x, pos.z, 0, 0, 0
    return
  end
  win.sf = win.sf + fwdSpeed()
  win.sl = win.sl + latSpeed()
  win.n  = win.n + 1
  if now - win.t < CFG.HDG_WIN then return end

  local dx, dz = pos.x - win.x, pos.z - win.z
  local moved = math.sqrt(dx * dx + dz * dz)
  local f, l = win.sf / win.n, win.sl / win.n
  local bodyMag = math.sqrt(f * f + l * l) * (now - win.t)

  if moved >= CFG.HDG_MIN_MOVE and bodyMag >= CFG.HDG_MIN_MOVE * 0.5 then
    local worldDir = math.deg(math.atan2(dx, -dz))
    local bodyDir  = math.deg(math.atan2(l, f))
    local h = (worldDir - bodyDir) % 360
    if motHdg == nil then motHdg = h else
      local d = (h - motHdg + 540) % 360 - 180
      motHdg = (motHdg + CFG.HDG_RATE * d) % 360
    end
  end
  win.t, win.x, win.z, win.sf, win.sl, win.n = now, pos.x, pos.z, 0, 0, 0
end

local function heading()
  if motHdg then return motHdg end
  if CFG.NAV_FALLBACK then return navHeading() end
  return 0
end

-- ---------- gps ----------
local function gpsLoop()
  while true do
    local x, _, z = gps.locate(0.3)
    local now = os.clock()
    if x then
      local dt = math.max(now - pos.t, 0.05)
      local ok = pos.t == 0 or (math.abs(x - (pos.x + pos.vx * dt)) < 12 and math.abs(z - (pos.z + pos.vz * dt)) < 12)
      if ok then
        if pos.t > 0 then
          pos.vx = 0.7 * pos.vx + 0.3 * (x - pos.x) / dt
          pos.vz = 0.7 * pos.vz + 0.3 * (z - pos.z) / dt
        end
        pos.x, pos.z, pos.t, pos.rej = x, z, now, 0
      else
        pos.rej = pos.rej + 1
        if pos.rej >= 5 then pos.t = 0 end
      end
    end
    sleep(0.05)
  end
end

-- ---------- modes ----------
local mode, goal, goalX, goalZ, findP, dashDeg, dashSecs, tgtX, tgtZ
if arg[1] == "find" then
  mode = "find" findP = tonumber(arg[2]) or CFG.HOVER
else
  local px, _, pz = gps.locate(1)
  if not px then error("no GPS fix") end
  pos.x, pos.z, pos.t = px, pz, os.clock()
  if arg[1] == "dash" then
    mode = "dash"
    goal = tonumber(arg[2]) or (alt.getHeight() + 10)
    dashDeg = tonumber(arg[3]) or 30
    dashSecs = tonumber(arg[4]) or 5
  elseif arg[1] == "go" then
    mode = "go"
    tgtX = tonumber(arg[2]) or error("go needs x z")
    tgtZ = tonumber(arg[3]) or error("go needs x z")
    goal = tonumber(arg[4]) or (alt.getHeight() + 25)
    dashDeg = CFG.CRUISE_DEG
  else
    mode = "fly"
    goal = tonumber(arg[1]) or alt.getHeight()
  end
  goalX, goalZ = px, pz
  if mode == "fly" then goalX = tonumber(arg[2]) or px goalZ = tonumber(arg[3]) or pz end
  if mode == "go" then goalX, goalZ = tgtX, tgtZ end
end

local log = fs.open("flightlog", "w")
log.writeLine("t,phase,height,err,pwr,gps,x,z,ex,ez,vxw,vzw,hdg,rawhdg,mothdg,tp,tr,p,r,vx,vy,sched,fwdRaw,latRaw,vrtRaw,fwdH,latH,energy,fuel")
local t0 = os.clock()
print(mode == "find" and ("find: holding " .. findP)
   or mode == "dash" and string.format("dash: Y %.0f, %d deg for %ds", goal, dashDeg, dashSecs)
   or mode == "go" and string.format("go: to %.0f,%.0f via Y %.0f", tgtX, tgtZ, goal)
   or string.format("fly: Y %.1f to %.1f,%.1f hdg %.0f", goal, goalX, goalZ, rawHeading()))
print("Ctrl+T stops")
pump(true)
if CFG.PUMP_PRIME > 0 then print("priming pump") sleep(CFG.PUMP_PRIME) end

local function controlLoop()
  local lastH, lastT, integ = alt.getHeight(), os.clock(), 0
  local a = gim.getAngles()
  local lp, lr = a[1], a[2]
  local ip, ir = 0, 0
  local trimP, trimR = 0, 0
  local phase = (mode == "dash" or mode == "go") and "climb" or mode
  local tpS, trS = 0, 0    -- rate-limited tilt targets
  local dashStart, brakeStart = nil, nil
  while true do
    local t = os.clock()
    local dt = math.max(t - lastT, 0.05)
    local h = alt.getHeight()
    local v = (h - lastH) / dt
    lastH, lastT = h, t

    do local ga = gim.getAngles() bodyF, bodyL = bodyVel(ga[1], ga[2]) end
    updateMotionHeading(t)

    if phase == "climb" then
      -- transition the instant we reach cruise height, still climbing
      if h >= goal - CFG.DASH_SETTLE then
        phase = "dash" dashStart = t print("dash")
      end
    elseif phase == "dash" and mode == "dash" and t - dashStart > dashSecs then
      phase = "brake" brakeStart = t print("brake")
    elseif phase == "dash" and mode == "go" then
      local d = math.sqrt((tgtX - pos.x)^2 + (tgtZ - pos.z)^2)
      local f, l = fwdSpeed(), latSpeed()
      local fs = math.min(math.sqrt(f * f + l * l), 40)
      if d < math.max(CFG.ARRIVE, CFG.BRAKE_K * fs * fs / 10) then
        phase = "brake" brakeStart = t print(string.format("brake at %.0f blocks, %.1f b/s", d, fs))
      end
    elseif phase == "brake" then
      if math.abs(fwdSpeed()) < CFG.BRAKE_DONE or t - brakeStart > CFG.BRAKE_MAX_T then
        phase = "hold"
        if mode ~= "go" then goalX, goalZ = pos.x, pos.z end
        print("hold")
      end
    end

    local pwr, e = findP, 0
    if mode ~= "find" then
      e = goal - h
      integ = clamp(integ + CFG.AKI * e * dt, 0.3)
      pwr = CFG.HOVER + clamp(CFG.AKP * e, CFG.PMAX) + integ - CFG.AKD * v
      if phase == "climb" then
        -- climb hard, but ease off as the climb rate reaches target
        pwr = CFG.CLIMB_POWER - CFG.AKD * (v - CFG.CLIMB_RATE)
      end
      if phase == "dash" or phase == "brake" then pwr = pwr + CFG.DASH_POWER end
    end

    local hdg, raw = heading(), rawHeading()
    local tp, tr, ex, ez = 0, 0, 0, 0
    local fresh = mode ~= "find" and pos.t > 0 and (t - pos.t) < 1.5
    local speed = math.sqrt(pos.vx * pos.vx + pos.vz * pos.vz)
    if phase == "dash" and mode == "go" then
      -- target direction into body frame (needs heading), then compare against
      -- BODY velocity from the sensors. No GPS velocity in this loop.
      ex, ez = tgtX - pos.x, tgtZ - pos.z
      local d = math.max(math.sqrt(ex * ex + ez * ez), 0.001)
      local ux, uz = ex / d, ez / d
      local r = math.rad(hdg)
      local wantF = CFG.CRUISE_SPEED * (ux * math.sin(r) - uz * math.cos(r))
      local wantL = CFG.CRUISE_SPEED * (ux * math.cos(r) + uz * math.sin(r))
      tp = CFG.PITCH_DIR * CFG.CKV * (wantF - fwdSpeed())
      tr = CFG.ROLL_DIR * CFG.CKV * (wantL - latSpeed())
      local mag = math.sqrt(tp * tp + tr * tr)
      if mag > dashDeg then tp, tr = tp * dashDeg / mag, tr * dashDeg / mag end
    elseif phase == "dash" then
      tp = CFG.DASH_DIR * dashDeg
    elseif phase == "brake" then
      -- lean against the direction of travel to kill speed
      local fs = fwdSpeed()
      local k = math.min(1, math.abs(fs) / CFG.BRAKE_EASE)
      tp = -CFG.DASH_DIR * CFG.BRAKE_DEG * k * (fs >= 0 and 1 or -1)
    elseif phase ~= "climb" and fresh and speed < CFG.SPEED_GUARD then
      ex, ez = goalX - pos.x, goalZ - pos.z
      local vdx = clamp(CFG.PKP * ex, CFG.VMAX)
      local vdz = clamp(CFG.PKP * ez, CFG.VMAX)
      local evx, evz = vdx - pos.vx, vdz - pos.vz
      local r = math.rad(hdg)
      local fwd   = evx * math.sin(r) - evz * math.cos(r)
      local right = evx * math.cos(r) + evz * math.sin(r)
      tp = clamp(CFG.PITCH_DIR * CFG.PKV * fwd, CFG.TILT_MAX)
      tr = clamp(CFG.ROLL_DIR * CFG.PKV * right, CFG.TILT_MAX)
      trimP = clamp(trimP + CFG.PKI * CFG.PITCH_DIR * fwd * dt, CFG.TRIM_MAX)
      trimR = clamp(trimR + CFG.PKI * CFG.ROLL_DIR * right * dt, CFG.TRIM_MAX)
    elseif fresh then
      ex, ez = goalX - pos.x, goalZ - pos.z
    end
    if phase ~= "dash" and phase ~= "brake" then tp, tr = tp + trimP, tr + trimR end

    -- rate-limit tilt targets so phase changes are smooth, not steps
    local maxStep = CFG.TILT_RATE * dt
    tpS = tpS + clamp(tp - tpS, maxStep)
    trS = trS + clamp(tr - trS, maxStep)
    tp, tr = tpS, trS

    a = gim.getAngles()
    bodyF, bodyL = bodyVel(a[1], a[2])
    if CFG.TUMBLE > 0 and (math.abs(a[1]) > CFG.TUMBLE or math.abs(a[2]) > CFG.TUMBLE) then
      error(string.format("tumbled (%.0f, %.0f) - thrust cut", a[1], a[2]))
    end

    -- gain schedule on total tilt
    local tilt = math.sqrt(a[1] * a[1] + a[2] * a[2])
    local s = math.max(0, clamp((tilt - CFG.SCHED_LO) / (CFG.SCHED_HI - CFG.SCHED_LO), 1))
    local KP = CFG.KP_HOVER + s * (CFG.KP_DASH - CFG.KP_HOVER)
    local KI = CFG.KI_HOVER + s * (CFG.KI_DASH - CFG.KI_HOVER)
    local KD = CFG.KD_HOVER + s * (CFG.KD_DASH - CFG.KD_HOVER)

    local ep, er = a[1] - tp, a[2] - tr
    local dp, dr = (a[1] - lp) / dt, (a[2] - lr) / dt
    lp, lr = a[1], a[2]
    ip = clamp(ip + KI * ep * dt, CFG.IMAX)
    ir = clamp(ir + KI * er * dt, CFG.IMAX)
    local cp = CFG.P_SIGN * (KP * ep + ip + KD * dp)
    local cr = CFG.R_SIGN * (KP * er + ir + KD * dr)
    local vx = clamp(CFG.P_AXIS == "x" and cp or cr, CFG.VEC_MAX)
    local vy = clamp(CFG.P_AXIS == "x" and cr or cp, CFG.VEC_MAX)
    drive(pwr, vx, vy)

    local s0, s1, s2 = rawFwd(), rawLat(), rawVrt()
    log.writeLine(string.format("%.2f,%s,%.2f,%.2f,%.3f,%d,%.1f,%.1f,%.1f,%.1f,%.2f,%.2f,%.0f,%.0f,%.0f,%.1f,%.1f,%.1f,%.1f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.0f,%.0f",
      t - t0, phase, h, e, math.max(0, math.min(1, pwr)), fresh and 1 or 0, pos.x, pos.z, ex, ez, pos.vx, pos.vz, hdg, raw,
      motHdg or -1, tp, tr, a[1], a[2], vx, vy, s, s0, s1, s2, fwdSpeed(), latSpeed(), mon.energy, fuel.pct))
    sleep(0.05)
  end
end

local ok, err = pcall(parallel.waitForAny, controlLoop, gpsLoop, monLoop)
drive(0, 0, 0) pump(false) log.close()
print("thrusters off, pump off - flightlog saved")
if not ok and not tostring(err):find("Terminated") then print(err) end
