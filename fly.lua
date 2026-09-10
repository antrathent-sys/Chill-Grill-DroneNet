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
  -- Four-thruster mixer (lib/mixer.lua), engaged automatically when more than
  -- one vector_thruster is fitted. The attitude PID above is unchanged; only
  -- where its output goes differs:
  --   "diff"   differential thrust holds attitude, nozzles stay straight
  --            (4 peripheral calls per iteration, the vectors are cached)
  --   "vector" legacy: every nozzle vectored together like the one thruster
  --   "both"   differential AND vectored, same signs as above
  MIX_MODE = "diff",
  MIX_GAIN = 0.5,                     -- PID output (nozzle units) -> differential demand, before PITCH_AUTH.
                                      -- 1.0 gave an undamped 2.5 s pitch oscillation at 0.25 s/iteration (flight 2026-09-10)
  MIX_P_SIGN = 1, MIX_R_SIGN = 1,     -- flip one if the craft diverges on that axis in diff mode
  -- Which thruster sits in which corner, as the SIGN of the gimbal response
  -- when it fires alone (mixcal run1 + run2 agreed). mixmap.csv on the
  -- computer, written by mixcal, overrides this.
  MIX_MAP = {
    { name = "vector_thruster_5", pitch = -1, roll =  1 },
    { name = "vector_thruster_6", pitch = -1, roll = -1 },
    { name = "vector_thruster_7", pitch =  1, roll = -1 },
    { name = "vector_thruster_8", pitch =  1, roll =  1 },
  },

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
  -- Heading source. The nav table (targeting the north magnet) plus the gimbal
  -- gives an absolute heading at any attitude short of the tilt singularity.
  -- Motion heading needed the velocity sensors, which the four-thruster
  -- airframe does not carry, so the nav table is primary now.
  NAV_PRIMARY = true,                 -- nav table is THE heading; motion heading is legacy fallback
  NAV_NAME = nil,                     -- which navigation_table (the FLAT one); nil = first found
  NAV_FALLBACK = true,                -- legacy: use nav table when motion heading has no lock
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

  -- docking. The connector is a magnet: it locks once the tips are within
  -- 0.5 blocks and 20 deg (server config docking_connector_distance/_angle)
  -- and pulls itself the last of the way, so these numbers only have to park
  -- the drone inside its reach, not hit the lock window by flying.
  DOCK_SIDE = nil,                    -- redstone side that extends the connector; nil = docking off
  DOCK_NAME = nil,                    -- docking_connector peripheral name; nil = peripheral.find
  DOCK_ALIGN = 1.5,                   -- blocks: horizontal error to sit inside before descending
  DOCK_ALIGN_SPD = 0.5,               -- b/s: ground speed to be under as well
  DOCK_SETTLE_T = 2.0,                -- seconds of holding both of those before the descent starts
  DOCK_ALIGN_GRACE = 6,               -- failing samples tolerated before the settle timer resets
  DOCK_GAP = 3,                       -- blocks above padY to park; 3 is the connectors' own spacing
  DOCK_BAND = 0.5,                    -- blocks: how close to the park altitude counts as arrived
  DOCK_RATE = 1.5,                    -- b/s: how fast the altitude goal walks down
  DOCK_SINK = 0.0,                    -- power bled off in capture so the magnet can pull down
  DOCK_CAPTURE_T = 25,                -- seconds to wait for the magnet before aborting
  DOCK_ABORT_DIST = 4,                -- blocks of drift that sends the descent back to align
  DOCK_TRIES = 3,                     -- capture attempts before giving up and just holding
  DOCK_RELEASE_T = 1.5,               -- seconds of thrust before 'undock' drops the connector

  -- Position source. Measured against ground truth 2026-09-10: CC:Sable's
  -- pose was accurate to 2.7 blocks while the GPS array was out by 45, so
  -- "sable" is the default. "gps" forces the old path, "auto" prefers sable
  -- and falls back.
  POS_SOURCE = "auto",
  POS_POLL = 0.05,                    -- seconds between position reads

  AUTO_UPLOAD = true,                 -- push the flightlog to GitHub when the flight ends
  CHIME = true,                       -- speaker tones on phase changes, if a speaker is attached
}

local alt = peripheral.find("altitude_sensor")
local gim = peripheral.find("gimbal_sensor")
local nav = CFG.NAV_NAME and peripheral.wrap(CFG.NAV_NAME) or peripheral.find("navigation_table")
local thrs = { peripheral.find("vector_thruster") }
local thr = thrs[1]
local accs = { peripheral.find("modular_accumulator") }
local acc = accs[1]
local vels = { peripheral.find("velocity_sensor") }
for k, v in pairs({ alt = alt, gim = gim, nav = nav, thr = thr }) do if not v then error("missing " .. k) end end

local function clamp(v, l) return math.max(-l, math.min(l, v)) end
local function rawHeading() return (CFG.HDG_SIGN * nav.getRelativeAngle() + CFG.HDG_OFFSET) % 360 end

-- ---------- thrusters ----------
-- One thruster: drive it directly, as before. More than one: lib/mixer.lua,
-- with a corner map that must name every fitted thruster or a corner would
-- sit idle and the craft would flip on lift-off.
local mixer = nil
if #thrs > 1 then
  local okM, lib = pcall(dofile, "lib/mixer.lua")
  if not okM or type(lib) ~= "table" then error(#thrs .. " thrusters but no lib/mixer.lua: " .. tostring(lib)) end
  mixer = lib
  local map = CFG.MIX_MAP
  if fs.exists("mixmap.csv") then
    local parsed = {}
    local f = fs.open("mixmap.csv", "r")
    f.readLine()                                   -- header
    for line in function() return f.readLine() end do
      local name, dp, dr = line:match("^([^,]+),([^,]+),([^,]+)")
      dp, dr = tonumber(dp), tonumber(dr)
      if name and dp and dr then
        parsed[#parsed + 1] = { name = name, pitch = dp >= 0 and 1 or -1, roll = dr >= 0 and 1 or -1 }
      end
    end
    f.close()
    if #parsed >= 2 then map = parsed print("mixer: corner map from mixmap.csv") end
  end
  local byName = {}
  for _, m in ipairs(map) do byName[m.name] = m end
  for _, t in ipairs(thrs) do
    local n = peripheral.getName(t)
    if not byName[n] then error("thruster " .. n .. " is not in the mixer map - run mixcal") end
  end
  local n, missing = mixer.configure({ thrusters = map, VEC_MAX = CFG.VEC_MAX })
  if #missing > 0 then error("mixer map names thrusters that are not fitted: " .. table.concat(missing, " ")) end
  print(string.format("mixer: %d thrusters, mode %s", n, CFG.MIX_MODE))
end
if #accs > 1 then print("accumulators: " .. #accs .. " (averaged)") end

-- Push one lift power and the attitude PID's raw pitch/roll outputs (before
-- P_SIGN/R_SIGN) to the hardware. Returns the two numbers that went out, for
-- the log: nozzle vector on the single thruster, differential demand in diff
-- mode.
local mixSat = false
local function drive(p, up, ur)
  local cp, cr = CFG.P_SIGN * up, CFG.R_SIGN * ur
  local vx = clamp(CFG.P_AXIS == "x" and cp or cr, CFG.VEC_MAX)
  local vy = clamp(CFG.P_AXIS == "x" and cr or cp, CFG.VEC_MAX)
  if not mixer then
    thr.setVector(vx, vy)
    thr.setPowerNormalized(math.max(0, math.min(1, p)))
    return vx, vy
  end
  local d = { lift = math.max(0, math.min(1, p)) }
  if CFG.MIX_MODE ~= "vector" then
    -- mixer pitch +1 raises gimbal pitch (that is how mixcal defines the
    -- signs), so a positive pitch error wants a negative demand
    d.pitch = clamp(-CFG.MIX_P_SIGN * CFG.MIX_GAIN * up, 1)
    d.roll  = clamp(-CFG.MIX_R_SIGN * CFG.MIX_GAIN * ur, 1)
  end
  if CFG.MIX_MODE ~= "diff" then d.lat, d.fwd = vx, vy end   -- VEC_X_IS lat, VEC_Y_IS fwd
  local _, _, sat = mixer.write(d)
  mixSat = sat
  if CFG.MIX_MODE == "diff" then return d.pitch, d.roll end
  return vx, vy
end
local function allStop()
  if mixer then mixer.stop() else drive(0, 0, 0) end
end
-- ---------- monitoring ----------
-- Accumulator % and the thruster's own buffer are read in monLoop once per
-- MON_POLL. The control loop never touches them, it only logs the latest.
local mon  = { energy = -1, rate = 0, t = 0 }   -- rate: accumulator %/min, negative = draining
local fuel = { pct = -1, amt = -1, cap = -1, t = 0 }

-- Docking connector. Redstone extends it, and extending is also what arms its
-- magnet, so nothing is attracted until DOCK_SIDE goes high. getConnectedName()
-- is the only dock-state signal the mod exposes; it is polled in monLoop and
-- only while a dock is actually armed.
local dock = { armed = false, connected = false, name = "" }
local dockP = CFG.DOCK_NAME and peripheral.wrap(CFG.DOCK_NAME) or peripheral.find("docking_connector")
if CFG.DOCK_NAME and not dockP then print("WARNING: docking connector " .. CFG.DOCK_NAME .. " not found") end
local function dockExtend(on)
  if CFG.DOCK_SIDE then redstone.setOutput(CFG.DOCK_SIDE, on) end
end

-- Chimes. Optional, silent without a speaker, and every call returns instantly
-- so nothing here can stall the control loop.
local chime = { play = function() end, loop = function() while true do sleep(1) end end }
if CFG.CHIME and fs.exists("lib/chime.lua") then
  local ok, lib = pcall(dofile, "lib/chime.lua")
  if ok and lib then
    local spk = peripheral.find("speaker")
    if spk and lib.attach(spk) then chime = lib print("speaker: chimes on") end
  end
end

-- Announce a phase change once, in one place.
local function enter(newPhase)
  chime.play(newPhase)
  print(newPhase)
end

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
      fuelLabel = "THRUSTER"
      if mixer and not CFG.FUEL_NAME then
        fuelRead = function()
          local e, c = 0, 0
          for _, t in ipairs(thrs) do e, c = e + t.getEnergy(), c + t.getEnergyCapacity() end
          return e, c
        end
        print("thrusters: FE summed over " .. #thrs .. " via getEnergy/getEnergyCapacity")
      else
        fuelRead = function() return p.getEnergy(), p.getEnergyCapacity() end
        print("thruster: " .. name .. " FE via getEnergy/getEnergyCapacity")
      end
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
      local sum, n = 0, 0
      for _, a in ipairs(accs) do
        local ok, pct = pcall(a.getPercent)
        if ok and pct then sum, n = sum + pct, n + 1 end
      end
      if n > 0 then
        local pct = sum / n
        local now = os.clock()
        if lastE and now > lastT then
          local r = (pct - lastE) / (now - lastT) * 60
          mon.rate = mon.rate + 0.2 * (r - mon.rate)
        end
        lastE, lastT = pct, now
        mon.energy, mon.t = pct, now
        if pct < CFG.ENERGY_WARN and not warnE then
          warnE = true
          chime.play("warn")
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
    if dock.armed and dockP then
      local ok, name = pcall(dockP.getConnectedName)
      if ok and type(name) == "string" and name ~= "" then
        dock.connected, dock.name = true, name
      else
        dock.connected = false
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
-- Velocity sensors are optional since the move to CC:Sable. Without them,
-- body-frame speed is world velocity from the pose loop rotated by heading,
-- which costs no peripheral calls at all.
local haveVelSensors = sFwd ~= nil
if not haveVelSensors then
  print("no velocity sensors - body speed derived from Sable velocity + heading")
else
  if not sLat then print("WARNING: no lateral velocity sensor") end
  if not sVrt then print("WARNING: no vertical sensor - tilt correction off") end
end

local function rawFwd() return sFwd and CFG.FWD_SIGN2 * sFwd.getVelocity() or 0 end
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
local function correctedHeading(p, r, rawH)
  local ang = math.rad(rawH or rawHeading())
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
-- Takes the gimbal angles and raw nav angle the caller already has, so this
-- adds NO peripheral calls to the loop.
local function navHeading(p, r0deg, rawH)
  local r = math.rad(correctedHeading(p, r0deg, rawH))
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

local function heading(p, r, rawH)
  if CFG.NAV_PRIMARY then return navHeading(p, r, rawH) end
  if motHdg then return motHdg end
  if CFG.NAV_FALLBACK then return navHeading(p, r, rawH) end
  return 0
end

-- World velocity into the body frame, using the same rotation position hold
-- uses. This is what replaces the velocity sensors when they are not fitted.
local function bodyFromWorld(hdg, vx, vz)
  local r = math.rad(hdg)
  local fwd   = vx * math.sin(r) - vz * math.cos(r)
  local right = vx * math.cos(r) + vz * math.sin(r)
  return fwd, right
end

-- ---------- position ----------
-- Both loops fill the same `pos` table, so nothing downstream cares which is
-- running. Neither runs in the control loop, so the per-iteration call budget
-- is unchanged either way.

local haveSable = false
if _G.sublevel then
  local okg, grid = pcall(sublevel.isInPlotGrid)
  haveSable = okg and grid == true
end

local usingSable = (CFG.POS_SOURCE == "sable") or (CFG.POS_SOURCE == "auto" and haveSable)
if CFG.POS_SOURCE == "sable" and not haveSable then
  error("POS_SOURCE is 'sable' but this computer is not on a sub-level", 0)
end

--- One position read from whichever source is configured.
-- Returns x, z, vx, vz (world frame) or nil.
local function readPos()
  if usingSable then
    local okp, pose = pcall(sublevel.getLogicalPose)
    if not okp or type(pose) ~= "table" or not pose.position then return nil end
    -- Velocity comes straight from the physics engine rather than being
    -- differenced, so it carries none of the noise the GPS path had.
    local vx, vz = 0, 0
    local okv, lv = pcall(sublevel.getLinearVelocity)
    if okv and type(lv) == "table" then vx, vz = lv.x or 0, lv.z or 0 end
    return pose.position.x, pose.position.z, vx, vz
  end
  local x, _, z = gps.locate(0.3)
  return x, z, nil, nil
end

local function posLoop()
  while true do
    local x, z, vx, vz = readPos()
    local now = os.clock()
    if x then
      if vx then
        -- trusted velocity: take it, no outlier gate needed
        pos.vx, pos.vz = vx, vz
        pos.x, pos.z, pos.t, pos.rej = x, z, now, 0
      else
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
    end
    sleep(CFG.POS_POLL)
  end
end


-- ---------- modes ----------
local mode, goal, goalX, goalZ, findP, dashDeg, dashSecs, tgtX, tgtZ
local padY, dockAlt, cruiseY, undockFirst
if arg[1] == "find" then
  mode = "find" findP = tonumber(arg[2]) or CFG.HOVER
else
  local px, pz = readPos()
  if not px then
    error(usingSable and "no pose from sublevel - is the pod assembled?" or "no GPS fix", 0)
  end
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
  elseif arg[1] == "dock" then
    mode = "dock"
    if not CFG.DOCK_SIDE then error("dock needs CFG.DOCK_SIDE set") end
    tgtX = tonumber(arg[2]) or error("dock needs x z padY")
    tgtZ = tonumber(arg[3]) or error("dock needs x z padY")
    padY = tonumber(arg[4]) or error("dock needs x z padY")
    goal = tonumber(arg[5]) or (alt.getHeight() + 25)
    dockAlt = padY + CFG.DOCK_GAP
    dashDeg = CFG.CRUISE_DEG
    dock.armed = true
  elseif arg[1] == "undock" then
    -- release, then hold like a normal flight. The connector is not dropped
    -- until the control loop has had DOCK_RELEASE_T of thrust behind it.
    mode = "fly" undockFirst = true
    goal = tonumber(arg[2]) or (alt.getHeight() + 5)
  else
    mode = "fly"
    goal = tonumber(arg[1]) or alt.getHeight()
  end
  goalX, goalZ = px, pz
  if mode == "fly" and not undockFirst then goalX = tonumber(arg[2]) or px goalZ = tonumber(arg[3]) or pz end
  if mode == "go" or mode == "dock" then goalX, goalZ = tgtX, tgtZ end
  cruiseY = goal
end

local log = fs.open("flightlog", "w")
log.writeLine("t,phase,height,err,pwr,gps,x,z,ex,ez,vxw,vzw,hdg,rawhdg,mothdg,tp,tr,p,r,vx,vy,sched,fwdRaw,latRaw,vrtRaw,fwdH,latH,energy,fuel,sat")
local t0 = os.clock()
print(mode == "find" and ("find: holding " .. findP)
   or mode == "dash" and string.format("dash: Y %.0f, %d deg for %ds", goal, dashDeg, dashSecs)
   or mode == "go" and string.format("go: to %.0f,%.0f via Y %.0f", tgtX, tgtZ, goal)
   or mode == "dock" and string.format("dock: pad %.0f,%.0f Y %.0f, park at %.1f via Y %.0f",
      tgtX, tgtZ, padY, dockAlt, goal)
   or undockFirst and string.format("undock: release then hold Y %.1f", goal)
   or string.format("fly: Y %.1f to %.1f,%.1f hdg %.0f", goal, goalX, goalZ, rawHeading()))
print("position: " .. (usingSable and "CC:Sable pose" or "gps") ..
      (usingSable and "" or "  (WARNING: the host array was 45 blocks out when last measured)"))
print("Ctrl+T stops")
pump(true)
if CFG.PUMP_PRIME > 0 then print("priming pump") sleep(CFG.PUMP_PRIME) end

local function controlLoop()
  local lastH, lastT, integ = alt.getHeight(), os.clock(), 0
  local a = gim.getAngles()
  local lp, lr = a[1], a[2]
  local ip, ir = 0, 0
  local trimP, trimR = 0, 0
  local phase = (mode == "dash" or mode == "go" or mode == "dock") and "climb" or mode
  local tpS, trS = 0, 0    -- rate-limited tilt targets
  local dashStart, brakeStart = nil, nil
  local alignStart, captureStart, released = nil, nil, false
  local alignBad = 0
  local dockTries = 0
  while true do
    local t = os.clock()
    local dt = math.max(t - lastT, 0.05)
    local h = alt.getHeight()
    local v = (h - lastH) / dt
    lastH, lastT = h, t

    -- One gimbal read and one nav read here serve heading AND body speed.
    local rawH = rawHeading()
    local hdgNow
    do
      local ga = gim.getAngles()
      hdgNow = heading(ga[1], ga[2], rawH)
      if haveVelSensors then
        bodyF, bodyL = bodyVel(ga[1], ga[2])
      else
        bodyF, bodyL = bodyFromWorld(hdgNow, pos.vx, pos.vz)
      end
    end
    if haveVelSensors then updateMotionHeading(t) end

    if undockFirst and not released and t - t0 > CFG.DOCK_RELEASE_T then
      released = true dock.armed = false dockExtend(false)
      chime.play("undocked") print("connector released")
    end

    if phase == "climb" then
      -- transition the instant we reach cruise height, still climbing
      if h >= goal - CFG.DASH_SETTLE then
        phase = "dash" dashStart = t enter("dash")
      end
    elseif phase == "dash" and mode == "dash" and t - dashStart > dashSecs then
      phase = "brake" brakeStart = t enter("brake")
    elseif phase == "dash" and (mode == "go" or mode == "dock") then
      local d = math.sqrt((tgtX - pos.x)^2 + (tgtZ - pos.z)^2)
      local f, l = fwdSpeed(), latSpeed()
      local fs = math.min(math.sqrt(f * f + l * l), 40)
      if d < math.max(CFG.ARRIVE, CFG.BRAKE_K * fs * fs / 10) then
        phase = "brake" brakeStart = t chime.play("brake")
        print(string.format("brake at %.0f blocks, %.1f b/s", d, fs))
      end
    elseif phase == "brake" then
      if math.abs(fwdSpeed()) < CFG.BRAKE_DONE or t - brakeStart > CFG.BRAKE_MAX_T then
        phase = (mode == "dock") and "align" or "hold"
        if mode ~= "go" and mode ~= "dock" then goalX, goalZ = pos.x, pos.z end
        enter(phase)
      end
    elseif phase == "align" then
      -- sit over the pad until position and speed are both settled. Plain
      -- arithmetic on the shared pos table, no peripheral reads.
      local dx, dz = tgtX - pos.x, tgtZ - pos.z
      local d = math.sqrt(dx * dx + dz * dz)
      -- Speed comes from the velocity SENSORS, not from differenced GPS.
      -- gps.locate is quantised to whole blocks, so a drone drifting 0.5 b/s
      -- reads as spikes of several b/s every time it crosses a boundary,
      -- which would reset the settle timer forever. bodyF/bodyL are already
      -- cached this iteration, so this costs no extra peripheral call.
      local sp = math.sqrt(bodyF * bodyF + bodyL * bodyL)
      if pos.t > 0 and (t - pos.t) < 1.5 and d < CFG.DOCK_ALIGN and sp < CFG.DOCK_ALIGN_SPD then
        if not alignStart then alignStart = t end
        alignBad = 0
        if t - alignStart > CFG.DOCK_SETTLE_T then
          phase = "descend" dockExtend(true) chime.play("descend")
          print(string.format("descend to %.1f, connector extended", dockAlt))
        end
      else
        -- Tolerate a few bad samples before giving up on the settle. Both
        -- available speed signals are noisy in their own way, so a gate that
        -- resets on any single sample can hang forever waiting for a run of
        -- perfectly clean ones. Sustained motion still resets it.
        alignBad = alignBad + 1
        if alignBad > CFG.DOCK_ALIGN_GRACE then alignStart = nil alignBad = 0 end
      end
    elseif phase == "descend" then
      local dx, dz = tgtX - pos.x, tgtZ - pos.z
      local d = math.sqrt(dx * dx + dz * dz)
      if d > CFG.DOCK_ABORT_DIST then
        phase = "align" alignStart = nil goal = cruiseY
        print(string.format("drifted %.1f blocks - back to align", d))
      else
        -- walk the altitude goal down; the existing altitude PID follows it
        goal = math.max(dockAlt, goal - CFG.DOCK_RATE * dt)
        if h <= dockAlt + CFG.DOCK_BAND then
          phase = "capture" captureStart = t chime.play("capture")
          print("capture - waiting for the magnet")
        end
      end
    elseif phase == "capture" then
      goal = dockAlt
      if dock.connected then
        phase = "docked" print("DOCKED to " .. dock.name)
      elseif t - captureStart > CFG.DOCK_CAPTURE_T then
        dockTries = dockTries + 1
        goal = cruiseY
        if dockTries >= CFG.DOCK_TRIES then
          phase = "hold" dockExtend(false) dock.armed = false
          print("capture failed " .. dockTries .. "x - holding, connector retracted")
        else
          phase = "align" alignStart = nil
          print("capture timed out - climbing back for retry " .. (dockTries + 1))
        end
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
      if phase == "capture" then pwr = pwr - CFG.DOCK_SINK end
      if phase == "docked" then pwr = 0 end
    end

    local hdg, raw = hdgNow, rawH
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
    if haveVelSensors then
      bodyF, bodyL = bodyVel(a[1], a[2])
    else
      bodyF, bodyL = bodyFromWorld(hdgNow, pos.vx, pos.vz)
    end
    if CFG.TUMBLE > 0 and (math.abs(a[1]) > CFG.TUMBLE or math.abs(a[2]) > CFG.TUMBLE) then
        chime.play("alarm")
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
    local vx, vy = drive(pwr, KP * ep + ip + KD * dp, KP * er + ir + KD * dr)

    local s0, s1, s2 = 0, 0, 0
    if haveVelSensors then s0, s1, s2 = rawFwd(), rawLat(), rawVrt() end
    log.writeLine(string.format("%.2f,%s,%.2f,%.2f,%.3f,%d,%.1f,%.1f,%.1f,%.1f,%.2f,%.2f,%.0f,%.0f,%.0f,%.1f,%.1f,%.1f,%.1f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.0f,%.0f,%d",
      t - t0, phase, h, e, math.max(0, math.min(1, pwr)), fresh and 1 or 0, pos.x, pos.z, ex, ez, pos.vx, pos.vz, hdg, raw,
      motHdg or -1, tp, tr, a[1], a[2], vx, vy, s, s0, s1, s2, fwdSpeed(), latSpeed(), mon.energy, fuel.pct, mixSat and 1 or 0))
    if phase == "docked" then return end
    sleep(0.05)
  end
end

local ok, err = pcall(parallel.waitForAny, controlLoop, posLoop, monLoop, chime.loop)
allStop() pump(false) log.close()
print("thrusters off, pump off - flightlog saved")
-- Sounded here, not in the loop: the control loop returns the instant it docks,
-- so a queued chime would be cut off before it played.
if chime.playNow then
  pcall(function()
    if dock.connected then chime.playNow("docked")
    elseif not ok then chime.playNow("alarm") end
  end)
end
if dock.connected then
  -- DOCK_SIDE is deliberately left high: dropping it is what undocks.
  print("docked to " .. dock.name .. " - " .. tostring(CFG.DOCK_SIDE) .. " held, 'fly undock' releases")
end

-- Push the log last, once the thruster is already off. Wrapped so a bad token,
-- a dead link or a disabled http API can never mask how the flight went.
if CFG.AUTO_UPLOAD and http and fs.exists("upload.lua") then
  local sent, why = pcall(function()
    if shell then return shell.run("upload") end
    return os.run({}, "upload.lua")
  end)
  if not sent then print("auto-upload failed: " .. tostring(why)) end
end
if not ok and not tostring(err):find("Terminated") then print(err) end
