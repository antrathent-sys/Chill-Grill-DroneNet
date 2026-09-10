-- fly find <power>            -> hold fixed power, find hover point
-- fly <y> [x] [z]             -> hold Y, hold position or fly to x z
-- fly dash <y> <deg> <secs>   -> climb to Y, hold, pitch <deg> for <secs>, level, hold
-- fly spin <y> [deg]          -> climb to Y, hold, yaw clockwise <deg> (90) about the thrust axis, then back
-- fly go <x> <z> y sweep [from] -> as go, but rotate the yaw offset 3 deg/s during cruise from <from> deg
--                                (drag-vs-yaw experiment, lean capped at 45; analyse with tools/yaw_sweep.py)
-- writes flightlog on the computer every run
local CFG = {
  HOVER = 0.27,                       -- quad: 0.3 still climbs ~7 b/s, 0.5 was the single thruster
  -- quad 2026-09-10: AKD 0.1 (about 12 b/s^2 per b/s of rate error) rang
  -- against a 0.2 s vertical-speed sample; halved, with AKP/AKD raised to 0.5
  -- so the final approach tapers in 5 s instead of 10
  AKP = 0.025, AKI = 0.02, AKD = 0.05,   -- AKI acts on the RATE error (power per b/s per s), tau = AKD/AKI = 2.5 s
  PMAX = 0.35,                        -- altitude P clamp near the goal (legacy; the rate cap below governs climbs)

  -- attitude gains, scheduled by tilt magnitude
  -- quad, 2026-09-10: KI 0.005 made the loop unstable at low stiffness (the
  -- I-term matched P with 45 deg of lag at 1 rad/s). KD 0.020 then rang at
  -- 1 Hz with +-0.4 demand: the loop was 0.25 s per iteration and the D-term
  -- cannot outrun that. Loop trimmed to one gimbal read and a nav read every
  -- HDG_EVERY iterations; KD pulled back to the middle.
  KP_HOVER = 0.010, KI_HOVER = 0.001, KD_HOVER = 0.015,
  -- Above SCHED_HI the sails' pitching moment grows with airspeed: at 100 b/s
  -- the lean ran 25 deg past command and tumbled (2026-09-10). More P and a
  -- real integrator so a steady aero moment is trimmed out, not tolerated.
  -- 2026-09-10: 0.015/0.015 held 65 deg within 2 deg at 81 b/s. The 100 b/s
  -- departure that looked like softness was the gimbal's projected roll
  -- (fixed below); x3 rang bang-bang, x2 oscillated at 0.77 Hz and grew over
  -- five cycles at 66 deg - KD adds lag, not damping, at that period with
  -- 0.1-0.2 s of loop delay. Back to the proven set.
  KP_DASH  = 0.015, KI_DASH  = 0.004, KD_DASH  = 0.015,
  SCHED_LO = 10, SCHED_HI = 40,       -- deg: all-hover below LO, all-dash above HI
  IMAX = 0.6,
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
  MIX_MODE = "both",                  -- 2026-09-10 A/B at 0.25 s/iter: diff = steady +-10 deg wobble,
                                      -- vector = divergent, tumbled at 14 s (stronger torque, same delay).
                                      -- Thruster writes are now batched into one tick; flying "both".
  MIX_GAIN = 1.0,                     -- PID output (nozzle units) -> differential demand, before PITCH_AUTH.
                                      -- 1.0: steady +-10 deg / 2.5 s pitch wobble; 0.5: growing +-22 deg / 6 s.
                                      -- Lower stiffness made it WORSE, so the fix is in KI/KD, not here.
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

  PKP = 0.2, VMAX = 8, PKV = 3.0,     -- PKV 1 settled at 5.5 b/s on 8 deg; 3 leans harder toward VMAX
  PKI = 0.05, TRIM_MAX = 3,
  TILT_MAX = 20,                      -- quad: 8 deg of lean only bought 2.5 b/s; 20 lets the hold reach VMAX
  SPEED_GUARD = 6,                    -- b/s: position hold engages below this (4 let a 12 b/s residual coast 148 blocks)
  PITCH_DIR = -1, ROLL_DIR = 1,
  -- Quad frame, fitted from two position-hold flights on 2026-09-10 (world
  -- velocity response to pitch and roll, tools/fit_heading.py): the flat nav
  -- table faces DOWN, so it reads mirrored (HDG_SIGN -1). Both flights give
  -- the same offset, 269, and PITCH_DIR/ROLL_DIR stay as on the old frame.
  HDG_SIGN = -1,
  HDG_OFFSET = 269,
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
  HDG_EVERY = 4,                      -- read the nav table every N control iterations (each read is a tick;
                                      -- the craft yaws slowly, so heading tolerates being ~0.5 s stale)
  TUMBLE = 85,
  DASH_SETTLE = 3.0,                  -- transition this many blocks below goal
  CLIMB_POWER = 0.9,                  -- (legacy, unused: the climb phase runs the altitude cascade)
  -- Vertical rate request: as fast as the remaining distance can stop.
  -- 50 b/s reached in 5 s on 0.55 power (2026-09-10) but overshot 35 blocks:
  -- gravity here is ~10 b/s^2 (measured on the coast-down), so 50 b/s needs
  -- 125 blocks to arrest at zero throttle and the linear taper gave it 100.
  -- vWant = min(CLIMB_RATE, sqrt(2 * DECEL * |e|), (AKP/AKD) * |e|).
  CLIMB_RATE = 100,                   -- b/s: hard cap; distance governs long before this
  DECEL = 8,                          -- b/s^2 the taper plans for (coasting climb ~10, descents have thrust to spare)
  VRATE_SLEW = 50,                    -- b/s^2: full throttle within a fraction of a second of takeoff
  DASH_DIR = -1,
  DASH_POWER = 0.05,                  -- margin on top of the tilt-compensated hover (HOVER / cos tilt)
  TILT_RATE = 60,                     -- deg/s: how fast tilt targets may move

  -- brake: pitch the other way to kill forward speed
  BRAKE_DEG = 45,                     -- how hard to pitch back against the motion
  BRAKE_DONE = 3.0,                   -- b/s: below this, brake is finished
  BRAKE_MAX_T = 20,                   -- give up after this many seconds
  BRAKE_EASE = 4,                     -- b/s over which brake tilt ramps to full

  -- go mode
  -- Lean is bounded by thrust: holding altitude at tilt T needs HOVER / cos T
  -- of full power, and HOVER is 0.27, so 74 deg is the absolute ceiling and
  -- 72 leaves a sliver for the altitude loop. 80 would sink.
  -- 2026-09-10: 72 / 35 b/s ran lean to the cap, attitude overshot to 92,
  -- power saturated (no differential headroom left for attitude), altitude
  -- went and it tumbled. 60 deg needs 0.54 of full power to hold height.
  -- Lean is scheduled by speed: the sails carry the craft once it is moving
  -- (45 b/s took 0.28 power, barely above hover), so the ballistic limit of
  -- ~74 deg only applies at standstill. Allowed lean = LEAN_AT_0 at rest,
  -- rising linearly to CRUISE_DEG at LEAN_FULL_SPD; pulled back by
  -- ALT_PROTECT_GAIN deg per block once more than ALT_PROTECT below goal.
  CRUISE_DEG = 70,                    -- max lean during cruise, at speed (65 tracked within 2 deg at 81 b/s)
  LEAN_AT_0 = 50,                     -- deg allowed from standstill
  LEAN_FULL_SPD = 60,                 -- b/s at which CRUISE_DEG is allowed
  ALT_PROTECT = 15,                   -- blocks below goal before the lean cap is reduced
  ALT_PROTECT_GAIN = 2,               -- deg of cap per block beyond ALT_PROTECT (floor 30)
  -- The airspeed cliff (2026-09-10): the sails' pitching moment grows with
  -- v^2 and above ~85 b/s it out-muscles the vectoring - 65 deg tracked
  -- within 2 deg at 81 b/s, 70 deg ran 10 deg past command at 100 b/s and
  -- departed. Until attitude authority at speed improves, speed is the limit.
  CRUISE_SPEED = 500,                 -- b/s: not a limit; the loop leans to the cap and speed is what that gives
  -- Aircraft-style cruise: throttle high and fixed, altitude by lean. With
  -- the sails carrying the craft the altitude loop used to throttle back to
  -- 0.3, and vectoring torque scales with thrust, so attitude authority was
  -- a third of what was available exactly where the aero moment peaks.
  CRUISE_MIN_POWER = 0.6,             -- throttle floor in cruise
  -- Vectoring torque is thrust x deflection: at zero throttle the attitude
  -- loop has NO authority. Every departure log has pwr 0.00 just before the
  -- trouble (the altitude loop cutting power while leaning 60-70 deg). Keep
  -- enough thrust to steer whenever leaning; altitude can give, control not.
  ATT_MIN_POWER = 0.25,               -- throttle floor whenever lean exceeds ATT_MIN_TILT
  ATT_MIN_TILT = 15,                  -- deg
  ALT_LEAN_GAIN = 1.0,                -- deg of lean cap per block above goal (high -> lean more -> less lift)
  -- Velocity loop runs in the WORLD frame (Sable velocity needs no heading);
  -- heading only splits the final lean into pitch and roll. 1290-block flight
  -- 2026-09-10: CKV 3 turned every 5 b/s wobble into 15 deg of lean and the
  -- nav heading swung +-40 at 50 deg of tilt, scrambling body-frame integrators.
  CKV = 1.0,                          -- deg of lean per b/s of velocity error
  CKI = 0.3,                          -- deg/s of lean per b/s of velocity error (P alone left a drag offset)
  -- Smooth cruise (2026-09-10 rework): commit to a lean and hold it.
  DASH_ENTRY_FRAC = 0.6,              -- go/dock: start the cruise lean once this fraction of the climb is done;
                                      -- the altitude cascade finishes the climb underneath (feed-forward covers the lean)
  CRUISE_TILT_RATE = 20,              -- deg/s: lean target slew in cruise (TILT_RATE elsewhere); no twitching
  CRUISE_NO_BRAKE = true,             -- never lean against the direction of travel in cruise: coast, don't fight
  -- Coordinated cruise: the sails are symmetric about one body plane and
  -- want a single angle of attack, not a compound one. With CRUISE_COORD the
  -- lean is applied along CRUISE_LEAN_AXIS only, the yaw hold points the
  -- craft at the TARGET (bearing + YAW_OFFSET) rather than the current
  -- course, and steering comes from yaw - like an aircraft. Lean is scaled
  -- by cos(yaw error) so it does not push off sideways while still turning.
  CRUISE_COORD = false,               -- flip on once the sweep has fixed the axis
  CRUISE_LEAN_AXIS = 45,              -- deg clockwise from the nose along which the lean is applied:
                                      -- 0 = pitch (nose leads), 90 = roll (starboard leads), 45 = diagonal
                                      -- (fins on the corners: tools/yaw_sweep.py on the 83 b/s log says ~+45)
  HDG_CRUISE_ALPHA = 0.01,            -- per-iteration blend of the cruise heading (tau ~10 s at 10 Hz):
                                      -- the flat table's reading wanders with tilt, the craft's yaw does not

  -- Yaw hold, four thrusters only: the mixer vectors the nozzles tangentially
  -- to spin the craft about its thrust axis. In cruise the target is the
  -- course plus YAW_OFFSET, so the sails meet the airflow the same way every
  -- flight; otherwise the heading at phase entry. The 1290-block flight of
  -- 2026-09-10 yawed 260 deg with nothing holding it. YAW_SIGN is unknown
  -- until flown: a spin guard drops yaw hold for the rest of the flight if
  -- the heading turns more than YAW_ABORT_DEG in 2 s.
  YAW_HOLD = true,
  -- First yaw flight 2026-09-10: sign confirmed (heading moved toward the
  -- target both times) but KP 0.01 / MAX 0.25 was bang-bang: a 157 deg
  -- initial error slewed at 20-45 deg/s mid-transition and tripped the guard.
  YAW_SIGN = 1,
  -- Two full yaw sweeps at 45 deg / 35 b/s (2026-09-10, tools/yaw_sweep.py):
  -- speed per degree of lean is 0.70-0.80 in every 30-degree bin, yaw quiet
  -- everywhere. Orientation about the thrust axis does not change drag, so
  -- cruise yaw just holds still: "hold" = entry heading, "course" = follow
  -- the track + YAW_OFFSET (the old behaviour, more yaw activity for nothing).
  YAW_CRUISE = "hold",
  YAW_OFFSET = 0,                     -- deg between held heading and course when YAW_CRUISE = "course"
  -- 2026-09-10: with P capped at 0.05 the yaw sat 100 deg off the course all
  -- cruise (lean was all roll, sails sideways). P/KD now settle at ~10 deg/s.
  -- fly spin 40 (2026-09-10): sign confirmed (+ = heading up = clockwise),
  -- 0.08 of demand gave 6.5 deg/s, so ~80 deg/s per unit; 90 deg took 18 s
  -- on the 10 deg/s slew. Gains sized for a 30 deg/s slew: P/KD = 30 deg/s.
  YAW_KP = 0.02,                      -- yaw demand per deg of heading error
  YAW_KD = 0.02,                      -- yaw demand per deg/s of heading rate (Sable gives rad/s; converted)
  -- 2026-09-10, 83 b/s at 68 deg: yaw was gated off above 55 deg of lean, the
  -- sails spun the craft up to 60 deg/s, the guard then disabled yaw for the
  -- flight and it corkscrewed for a minute. Yaw damping now runs at every
  -- lean (the gyro-integrated heading is safe there) and the guard only warns.
  YAW_MAX = 0.9,                      -- demand clamp at hover (the mixer scales it by YAW_AUTH = 0.35 of nozzle range)
  YAW_MAX_LEAN = 0.3,                 -- demand clamp above YAW_LEAN_HI of lean: the sweep flight thrashed
                                      -- +-55 deg/s at 60-80 deg and tumbled; tangential deflection also
                                      -- steals attitude authority exactly where it is scarcest
  YAW_LEAN_LO = 20, YAW_LEAN_HI = 45, -- deg: clamp blends from YAW_MAX to YAW_MAX_LEAN across this band
  YAW_P_MAX = 0.8,                    -- cap on the heading term: equilibrium rate = (P_MAX - demand)/KD; 0.5 gave 15 deg/s
  YAW_SWEEP = 0,                      -- deg/s: rotate YAW_OFFSET continuously during cruise (drag-vs-yaw experiment,
                                      -- analyse with tools/yaw_sweep.py); 0 = off
  YAW_SLEW = 30,                      -- deg/s: the held target walks toward the wanted heading, never jumps
  YAW_TILT_MAX = 180,                 -- deg: lean above which yaw is not commanded (off)
  YAW_MIN_SPEED = 5,                  -- b/s: below this the course is meaningless, hold heading instead
  YAW_ABORT_DEG = 90,                 -- heading change in 2 s that counts as a spin
  BRAKE_K = 0.12,                     -- backstop only: brake distance = K * speed^2 / 10
  -- Continuous approach (2026-09-10): one controller from cruise to the
  -- hold. Allowed speed at distance d is sqrt(2 * CRUISE_DECEL * d); the
  -- along-track lean is CKV * (allowed - actual), positive to accelerate and
  -- NEGATIVE up to BRAKE_DEG to decelerate, so lean tapers with distance by
  -- construction and there is no brake phase to overshoot. The hold takes
  -- over inside APPROACH_HOLD_DIST below APPROACH_HOLD_SPD. The old brake
  -- phase remains only as a backstop (BRAKE_K small).
  CRUISE_DECEL = 10,                  -- b/s^2 (132 b/s stopped in ~575 blocks: ~15 available)
  GRAV = 10,                          -- b/s^2, measured on a zero-throttle coast: braking lean = atan(decel / GRAV)
  BRAKE_BACKSTOP_SPD = 15,            -- b/s: the old brake phase fires only if still faster than this inside 20 blocks
  APPROACH_HOLD_DIST = 30,            -- blocks
  APPROACH_HOLD_SPD = 10,             -- b/s
  ALT_LEAN_MAX = 10,                  -- deg: bound on the altitude-by-lean cap adjustment
  RECRUISE_DIST = 60,                 -- blocks: a brake that ends further out than this goes back to dash
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
local function drive(p, up, ur, yaw)
  local cp, cr = CFG.P_SIGN * up, CFG.R_SIGN * ur
  local vx = clamp(CFG.P_AXIS == "x" and cp or cr, CFG.VEC_MAX)
  local vy = clamp(CFG.P_AXIS == "x" and cr or cp, CFG.VEC_MAX)
  if not mixer then
    thr.setVector(vx, vy)
    thr.setPowerNormalized(math.max(0, math.min(1, p)))
    return vx, vy
  end
  local d = { lift = math.max(0, math.min(1, p)), yawRate = yaw or 0 }
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
  -- attitude maths (gravity vector from the gimbal's projected angles)
  local okA, libA = pcall(dofile, "lib/attitude.lua")
  ATT = okA and type(libA) == "table" and libA or nil
  if not ATT then print("WARNING: lib/attitude.lua missing - attitude errors fall back to raw gimbal angles") end
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
local pos = { x = 0, z = 0, vx = 0, vz = 0, vy = nil, t = 0, rej = 0, wy = 0,   -- vy: Sable vertical speed; wy: heading rate deg/s
              wvx = 0, wvy = 0, wvz = 0 }                                        -- raw world angular velocity, rad/s

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
local unpack_ = unpack or table.unpack
local function readPos()
  if usingSable then
    -- Each Sable call is a game tick. Issued from separate coroutines they
    -- land in the same tick (see lib/mixer.lua), so pose, linear and angular
    -- velocity together cost one tick instead of three, and the vertical
    -- speed the altitude loop damps on is 0.1 s old rather than 0.2.
    local pose, lv, av
    local jobs = {
      function() local ok, r = pcall(sublevel.getLogicalPose) if ok then pose = r end end,
      function() local ok, r = pcall(sublevel.getLinearVelocity) if ok then lv = r end end,
    }
    if CFG.YAW_HOLD then
      jobs[#jobs + 1] = function() local ok, r = pcall(sublevel.getAngularVelocity) if ok then av = r end end
    end
    if parallel and parallel.waitForAll then parallel.waitForAll(unpack_(jobs))
    else for _, j in ipairs(jobs) do j() end end
    if type(pose) ~= "table" or not pose.position then return nil end
    -- Velocity comes straight from the physics engine rather than being
    -- differenced, so it carries none of the noise the GPS path had.
    local vx, vy, vz = 0, 0, 0
    if type(lv) == "table" then vx, vy, vz = lv.x or 0, lv.y or 0, lv.z or 0 end
    if type(av) == "table" and av.y then
      pos.wvx, pos.wvy, pos.wvz = av.x or 0, av.y or 0, av.z or 0   -- world frame, rad/s
      if not ATT then pos.wy = -math.deg(av.y) end                -- level-only fallback
    end
    return pose.position.x, pose.position.z, vx, vz, vy
  end
  local x, _, z = gps.locate(0.3)
  return x, z, nil, nil, nil
end

local function posLoop()
  while true do
    local x, z, vx, vz, vy = readPos()
    local now = os.clock()
    if x then
      if vx then
        -- trusted velocity: take it, no outlier gate needed
        pos.vx, pos.vz, pos.vy = vx, vz, vy or 0
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
local padY, dockAlt, cruiseY, undockFirst, spinDeg
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
    for i = 4, 5 do
      if arg[i] == "sweep" then
        -- a calm measurement: moderate lean, slow rotation, optional start offset
        CFG.YAW_SWEEP = 3 dashDeg = math.min(dashDeg, 45) CFG.LEAN_AT_0 = math.min(CFG.LEAN_AT_0, 45)
        CFG.YAW_OFFSET = (CFG.YAW_OFFSET + (tonumber(arg[i + 1]) or 0)) % 360
        print(string.format("yaw sweep 3 deg/s during cruise from offset %.0f, lean capped at 45", CFG.YAW_OFFSET))
      end
    end
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
  elseif arg[1] == "spin" then
    -- pure yaw practice: hover at Y, then rotate about the thrust axis
    mode = "fly" spinDeg = tonumber(arg[3]) or 90
    goal = tonumber(arg[2]) or (alt.getHeight() + 10)
  else
    mode = "fly"
    goal = tonumber(arg[1]) or alt.getHeight()
  end
  goalX, goalZ = px, pz
  if mode == "fly" and not undockFirst and not spinDeg then goalX = tonumber(arg[2]) or px goalZ = tonumber(arg[3]) or pz end
  if mode == "go" or mode == "dock" then goalX, goalZ = tgtX, tgtZ end
  cruiseY = goal
end

local log = fs.open("flightlog", "w")
log.writeLine("t,phase,height,err,pwr,gps,x,z,ex,ez,vxw,vzw,hdg,rawhdg,mothdg,tp,tr,p,r,vx,vy,sched,fwdRaw,latRaw,vrtRaw,fwdH,latH,energy,fuel,sat,yerr,yrate,ydem")
local t0 = os.clock()
print(mode == "find" and ("find: holding " .. findP)
   or mode == "dash" and string.format("dash: Y %.0f, %d deg for %ds", goal, dashDeg, dashSecs)
   or mode == "go" and string.format("go: to %.0f,%.0f via Y %.0f", tgtX, tgtZ, goal)
   or mode == "dock" and string.format("dock: pad %.0f,%.0f Y %.0f, park at %.1f via Y %.0f",
      tgtX, tgtZ, padY, dockAlt, goal)
   or undockFirst and string.format("undock: release then hold Y %.1f", goal)
   or spinDeg and string.format("spin: hold Y %.0f, yaw +%d then back", goal, spinDeg)
   or string.format("fly: Y %.1f to %.1f,%.1f hdg %.0f", goal, goalX, goalZ, rawHeading()))
print("position: " .. (usingSable and "CC:Sable pose" or "gps") ..
      (usingSable and "" or "  (WARNING: the host array was 45 blocks out when last measured)"))
print("Ctrl+T stops")
pump(true)
if CFG.PUMP_PRIME > 0 then print("priming pump") sleep(CFG.PUMP_PRIME) end

local function controlLoop()
  local lastH, lastT, integ = alt.getHeight(), os.clock(), 0
  local h0 = lastH          -- start height, for the early dash entry
  local vWantS = 0          -- slew-limited vertical rate request
  local leanAtCap = false   -- cruise lean pinned at CRUISE_DEG (releases the throttle floor)
  local floorOn = false     -- cruise throttle floor engaged (hysteresis)
  local floorLvl = 0        -- ramped floor level actually applied
  local lastPwr = CFG.HOVER -- last commanded throttle, for integrator anti-windup
  local a = gim.getAngles()
  local lp, lr = a[1], a[2]
  local gLast = nil         -- last body-frame down vector, for body rates
  local iter, rawH = 0, rawHeading()
  local ip, ir = 0, 0
  local trimP, trimR = 0, 0
  local phase = (mode == "dash" or mode == "go" or mode == "dock") and "climb" or mode
  local tpS, trS = 0, 0    -- rate-limited tilt targets
  local cruiseIx, cruiseIz = 0, 0   -- go-mode speed integrators, world frame (deg of lean)
  local cruiseHdg = nil             -- slow-filtered heading used for the cruise split
  local yawOK = CFG.YAW_HOLD and mixer ~= nil
  local yawTgt, yawSrc, yawErr, yawDem = nil, nil, 0, 0
  local yawTgtS = nil               -- slew-limited target actually held
  local yawWarned = false
  local spinBase, spinStep, spinT, spinHeld, spinSettle = nil, 0, 0, nil, 0
  local hdgHist = {}                -- heading 2 s ago, for the spin guard
  local dashStart, brakeStart = nil, nil
  local alignStart, captureStart, released = nil, nil, false
  local alignBad = 0
  local dockTries = 0
  while true do
    local t = os.clock()
    local dt = math.max(t - lastT, 0.05)
    local h = alt.getHeight()
    -- Vertical speed from Sable when we have it: differenced altitude at
    -- 10 Hz jumped between 0 and double whenever the sensor skipped a tick,
    -- which slammed the throttle on and off (fly 500, 2026-09-10).
    local v = (usingSable and pos.vy and pos.t > 0 and (t - pos.t) < 1.5) and pos.vy or (h - lastH) / dt
    lastH, lastT = h, t

    -- ONE gimbal read per iteration serves heading, body speed and the
    -- attitude PID (nothing else is called before the PID uses it, so it is
    -- as fresh there as a second read would be). The nav table is read every
    -- HDG_EVERY iterations and the raw angle cached between.
    iter = iter + 1
    if iter % CFG.HDG_EVERY == 1 or CFG.HDG_EVERY <= 1 then rawH = rawHeading() end
    a = gim.getAngles()
    local hdgNow = heading(a[1], a[2], rawH)
    -- Heading rate = angular velocity about the THRUST axis, not about world
    -- vertical. At 70 deg of lean world-vertical is 0.94 roll / 0.34 yaw, so
    -- attitude motion was being integrated into the heading, the estimate
    -- swung +-25 deg, the lean split rotated with it and the attitude loop
    -- chased its own tail at 117 b/s (2026-09-10). Thrust axis in world from
    -- the gimbal's gravity vector and the current heading estimate.
    if ATT then
      local gB0 = ATT.gravityFromGimbal(a[1], a[2])
      local L = math.acos(math.max(-1, math.min(1, -gB0.y)))                 -- lean
      local bL = math.rad((cruiseHdg or hdgNow) + math.deg(math.atan2(gB0.x, -gB0.z)))  -- world bearing of the lean
      local tx, ty, tz = math.sin(L) * math.sin(bL), math.cos(L), -math.sin(L) * math.cos(bL)
      pos.wy = -math.deg(pos.wvx * tx + pos.wvy * ty + pos.wvz * tz)
    end
    -- cruise heading: complementary filter. Sable's yaw rate is integrated
    -- every iteration (no lag when the craft really yaws), and the result is
    -- pulled slowly toward the nav heading (no drift). A plain slow filter
    -- lagged 120 deg behind a 12 deg/s yaw and the yaw hold chased it round
    -- in circles (fly go 0 0 500, 2026-09-10).
    if phase == "dash" or phase == "brake" then
      if not cruiseHdg then cruiseHdg = hdgNow end
      cruiseHdg = cruiseHdg + pos.wy * dt
      local dh = ((hdgNow - cruiseHdg + 540) % 360) - 180
      cruiseHdg = (cruiseHdg + CFG.HDG_CRUISE_ALPHA * dh) % 360
    else
      cruiseHdg = hdgNow
    end
    if haveVelSensors then
      bodyF, bodyL = bodyVel(a[1], a[2])
    else
      bodyF, bodyL = bodyFromWorld(hdgNow, pos.vx, pos.vz)
    end
    if haveVelSensors then updateMotionHeading(t) end

    if undockFirst and not released and t - t0 > CFG.DOCK_RELEASE_T then
      released = true dock.armed = false dockExtend(false)
      chime.play("undocked") print("connector released")
    end

    if phase == "climb" then
      -- transition the instant we reach cruise height, still climbing
      -- go/dock: lean in once most of the climb is done and let the altitude
      -- loop finish it underneath; plain dash mode still waits for the top
      local entryH = goal - CFG.DASH_SETTLE
      if mode == "go" or mode == "dock" then
        entryH = math.min(entryH, h0 + CFG.DASH_ENTRY_FRAC * (goal - h0))
      end
      if h >= entryH then
        phase = "dash" dashStart = t enter("dash")
      end
    elseif phase == "dash" and mode == "dash" and t - dashStart > dashSecs then
      phase = "brake" brakeStart = t enter("brake")
    elseif phase == "dash" and (mode == "go" or mode == "dock") then
      local d = math.sqrt((tgtX - pos.x)^2 + (tgtZ - pos.z)^2)
      local gsNow = math.sqrt(pos.vx * pos.vx + pos.vz * pos.vz)
      if d < CFG.APPROACH_HOLD_DIST and gsNow < CFG.APPROACH_HOLD_SPD then
        phase = (mode == "dock") and "align" or "hold"
        enter(phase)
      end
      local f, l = fwdSpeed(), latSpeed()
      -- ground speed from Sable (the body-frame sensors are legacy); the old
      -- 40 b/s cap limited the brake point to 160 blocks and an 82 b/s
      -- cruise ran straight through the target (2026-09-10)
      local fs = math.min(math.sqrt(pos.vx * pos.vx + pos.vz * pos.vz), 150)
      if d < 20 and fs > CFG.BRAKE_BACKSTOP_SPD then
        -- backstop only: the approach should have done this
        phase = "brake" brakeStart = t chime.play("brake")
        print(string.format("BACKSTOP brake at %.0f blocks, %.1f b/s", d, fs))
      end
    elseif phase == "brake" then
      -- done on TOTAL ground speed: this craft cruises largely sideways, and
      -- judging by forward speed alone ended a brake at 12 b/s (2026-09-10)
      local gs = math.sqrt(pos.vx * pos.vx + pos.vz * pos.vz)
      if gs < CFG.BRAKE_DONE or t - brakeStart > CFG.BRAKE_MAX_T then
        local dLeft = (mode == "go" or mode == "dock") and math.sqrt((tgtX - pos.x)^2 + (tgtZ - pos.z)^2) or 0
        if dLeft > CFG.RECRUISE_DIST then
          -- stopped short: cruise again rather than crawl in on the hold
          phase = "dash" dashStart = t cruiseIx, cruiseIz = 0, 0
          print(string.format("stopped %.0f blocks short - cruising again", dLeft))
          chime.play("dash")
        else
          phase = (mode == "dock") and "align" or "hold"
          if mode ~= "go" and mode ~= "dock" then goalX, goalZ = pos.x, pos.z end
          enter(phase)
        end
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
      -- The law HOVER + AKP*e + integ - AKD*v is a rate cascade: it asks for
      -- a climb rate of (AKP/AKD)*e and damps toward it with AKD. Cap that
      -- rate at CLIMB_RATE (not PMAX, which capped it at 3.5 b/s), and only
      -- integrate when the rate request is not saturated, so a long climb
      -- does not wind the integrator up and overshoot the top.
      local ae = math.abs(e)
      local vMag = math.min(CFG.AKP / CFG.AKD * ae, math.sqrt(2 * CFG.DECEL * ae), CFG.CLIMB_RATE)
      local vWant = (e >= 0) and vMag or -vMag
      vWantS = vWantS + clamp(vWant - vWantS, CFG.VRATE_SLEW * dt)      -- ramp, never step
      -- PI on the rate error. The integrator trims a wrong HOVER (payload,
      -- fuel) at any point of the flight, and is frozen while the throttle is
      -- pinned at either end so a full-throttle climb cannot wind it up.
      local rateErr = vWantS - v
      if lastPwr > 0.01 and lastPwr < 0.99 then integ = clamp(integ + CFG.AKI * rateErr * dt, 0.4) end
      pwr = CFG.HOVER + integ + CFG.AKD * rateErr
      lastPwr = math.max(0, math.min(1, pwr))
      -- (the climb phase used to have its own full-throttle law here; with
      -- CLIMB_RATE 100 it handed over to dash at 197 m still doing 60 b/s and
      -- coasted to 348. The distance-aware cascade above covers it.)
      if phase == "dash" or phase == "brake" then
        -- leaning tips the thrust over: scale the hover feed-forward by
        -- 1 / cos(tilt) so the altitude loop is not left to find it
        -- floored at 1/cos 65: past that an overshoot costs a little altitude,
        -- not all the attitude authority (full power leaves the mixer no
        -- differential headroom, which is how the 100 b/s departure went)
        local ct = math.cos(math.rad(a[1])) * math.cos(math.rad(a[2]))
        -- in brake the sails already carry the craft: cap the feed-forward at
        -- 1/cos 45 or it climbs 25 blocks while stopping
        local ctFloor = (phase == "brake") and 0.71 or 0.42
        pwr = pwr + CFG.HOVER * (1 / math.max(ct, ctFloor) - 1) + CFG.DASH_POWER
        -- throttle floor in cruise: altitude is trimmed by the lean cap
        -- instead. The floor yields whenever we are above the goal or still
        -- climbing hard (it once held 0.6 through the goal at 50 b/s and
        -- put the craft 100 blocks high), with hysteresis so it does not
        -- chatter around the goal.
        if phase == "dash" and mode ~= "dash" then
          if floorOn and (e < -5 or v > 10 or (leanAtCap and e < -2)) then floorOn = false
          elseif not floorOn and e > -2 and v < 5 then floorOn = true end
          -- ramp the floor in and out (0.3/s) so engaging or releasing it
          -- is not a step the attitude loop has to absorb
          floorLvl = floorLvl + clamp((floorOn and CFG.CRUISE_MIN_POWER or 0) - floorLvl, 0.3 * dt)
          pwr = math.max(pwr, floorLvl)
        end
      end
      if phase == "capture" then pwr = pwr - CFG.DOCK_SINK end
      -- attitude authority floor: never coast at zero thrust while leaning
      if phase ~= "capture" and phase ~= "docked" then
        local tiltA = math.sqrt(a[1] * a[1] + a[2] * a[2])
        if tiltA > CFG.ATT_MIN_TILT then pwr = math.max(pwr, CFG.ATT_MIN_POWER) end
      end
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
      -- world-frame velocity error and integrator; heading enters only at
      -- the split into pitch and roll, and a wrong heading there merely
      -- rotates the lean, it cannot unwind the integrator
      -- Speed TARGET rides a curve at half the planned deceleration, ending
      -- at the hold radius, so it always sits under the kinematic braking
      -- curve below. (Using the braking curve itself as the target made the
      -- loop re-accelerate to 59 b/s with 33 blocks to go, 2026-09-10.)
      local vCruise = math.min(CFG.CRUISE_SPEED,
        math.sqrt(2 * (CFG.CRUISE_DECEL * 0.5) * math.max(d - CFG.APPROACH_HOLD_DIST, 0)))
      local eWx, eWz = vCruise * ux - pos.vx, vCruise * uz - pos.vz
      local cWx, cWz = CFG.CKV * eWx + cruiseIx, CFG.CKV * eWz + cruiseIz
      if speed > 1 then
        -- Along-track: kinematics decide. The deceleration that stops us at
        -- the hold radius is v^2 / 2d; the lean that produces it is
        -- atan(decel / GRAV). When that exceeds what the cruise loop is
        -- asking for, command it directly against the velocity (bounded by
        -- BRAKE_DEG); otherwise keep the CRUISE_NO_BRAKE behaviour (never
        -- fight drag for a few b/s of overspeed).
        local along = (cWx * pos.vx + cWz * pos.vz) / speed
        local dStop = math.max(d - CFG.APPROACH_HOLD_DIST, 1)
        local aReq = speed * speed / (2 * dStop)
        local brakeLean = 0
        if aReq > CFG.CRUISE_DECEL * 0.5 then
          brakeLean = math.min(CFG.BRAKE_DEG, math.deg(math.atan(aReq / CFG.GRAV)))
        end
        local want = -brakeLean
        if along > want or (brakeLean == 0 and along < 0) then
          local fix = along - (brakeLean > 0 and want or 0)
          if brakeLean > 0 or along < 0 then
            cWx, cWz = cWx - fix * pos.vx / speed, cWz - fix * pos.vz / speed
          end
        end
      end
      local r = math.rad(cruiseHdg)
      local cF = cWx * math.sin(r) - cWz * math.cos(r)
      local cL = cWx * math.cos(r) + cWz * math.sin(r)
      if CFG.CRUISE_COORD then
        -- project the world command onto the one body direction the fins
        -- allow (bearing cruiseHdg + axis), fade it in as the yaw comes round
        local A = math.rad(CFG.CRUISE_LEAN_AXIS)
        local ra = r + A
        local L = (cWx * math.sin(ra) - cWz * math.cos(ra)) * math.max(0, math.cos(math.rad(yawErr)))
        cF, cL = L * math.cos(A), L * math.sin(A)
      end
      tp = CFG.PITCH_DIR * cF
      tr = CFG.ROLL_DIR * cL
      -- lean cap: speed-scheduled, altitude-protected
      local cap = math.min(dashDeg, CFG.LEAN_AT_0 + (dashDeg - CFG.LEAN_AT_0) * math.min(1, speed / CFG.LEAN_FULL_SPD))
      if e > CFG.ALT_PROTECT then cap = math.max(30, cap - CFG.ALT_PROTECT_GAIN * (e - CFG.ALT_PROTECT)) end
      -- altitude by lean: above the goal (e < 0) lean more, below it lean
      -- less - bounded, it once added 25 deg to a low-speed leg and put the
      -- craft past horizontal
      cap = clamp(cap - clamp(CFG.ALT_LEAN_GAIN * e, CFG.ALT_LEAN_MAX), dashDeg)
      cap = math.max(30, cap)
      local mag = math.sqrt(tp * tp + tr * tr)
      leanAtCap = cap >= dashDeg - 0.5 and mag > cap
      if mag > cap then
        tp, tr = tp * cap / mag, tr * cap / mag
      else
        -- integrate only while unsaturated (anti-windup)
        cruiseIx = clamp(cruiseIx + CFG.CKI * eWx * dt, cap)
        cruiseIz = clamp(cruiseIz + CFG.CKI * eWz * dt, cap)
      end
    elseif phase == "dash" then
      tp = CFG.DASH_DIR * dashDeg
    elseif phase == "brake" then
      -- lean against the WORLD velocity vector, both axes, split into body
      -- exactly as cruise does; ramps in over BRAKE_EASE so it is not a step
      local k = math.min(1, speed / CFG.BRAKE_EASE)
      if speed > 0.1 then
        local bx, bz = -pos.vx / speed * CFG.BRAKE_DEG * k, -pos.vz / speed * CFG.BRAKE_DEG * k
        local r = math.rad(cruiseHdg)
        tp = CFG.PITCH_DIR * (bx * math.sin(r) - bz * math.cos(r))
        tr = CFG.ROLL_DIR  * (bx * math.cos(r) + bz * math.sin(r))
      end
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
    local maxStep = ((phase == "dash" and mode ~= "dash") and CFG.CRUISE_TILT_RATE or CFG.TILT_RATE) * dt
    tpS = tpS + clamp(tp - tpS, maxStep)
    trS = trS + clamp(tr - trS, maxStep)
    tp, tr = tpS, trS

    if CFG.TUMBLE > 0 and (math.abs(a[1]) > CFG.TUMBLE or math.abs(a[2]) > CFG.TUMBLE) then
        chime.play("alarm")
      error(string.format("tumbled (%.0f, %.0f) - thrust cut", a[1], a[2]))
    end

    -- gain schedule on total tilt
    local tilt = math.sqrt(a[1] * a[1] + a[2] * a[2])
    if ATT then
      local gB0 = ATT.gravityFromGimbal(a[1], a[2])
      tilt = math.deg(math.acos(math.max(-1, math.min(1, -gB0.y))))   -- true lean
    end
    local s = math.max(0, clamp((tilt - CFG.SCHED_LO) / (CFG.SCHED_HI - CFG.SCHED_LO), 1))
    local KP = CFG.KP_HOVER + s * (CFG.KP_DASH - CFG.KP_HOVER)
    local KI = CFG.KI_HOVER + s * (CFG.KI_DASH - CFG.KI_HOVER)
    local KD = CFG.KD_HOVER + s * (CFG.KD_DASH - CFG.KD_HOVER)

    -- Attitude error as the rotation between the measured and the target
    -- down-vector in the body frame, and body rates from that vector's
    -- motion. The gimbal's pitch/roll are PROJECTED angles: roll is
    -- atan2(-gx, -gy), and at 65 deg of pitch gy is 0.42, so the same physical
    -- roll reads 2.4x (3.9x at 75, 5.8x at 80). Using them raw multiplied the
    -- second axis's loop gain with lean, which is why every departure began
    -- as a roll runaway past ~65 deg (2026-09-10). Identical to a[1]-tp at
    -- level; correct at any lean.
    local ep, er, dp, dr
    if ATT then
      local gB = ATT.gravityFromGimbal(a[1], a[2])
      local gT = ATT.gravityFromGimbal(tp, tr)
      ep = math.deg(gB.y * gT.z - gB.z * gT.y)      -- about body x (pitch)
      er = math.deg(gB.x * gT.y - gB.y * gT.x)      -- about body z (roll)
      if gLast then
        local gx, gy, gz = (gB.x - gLast.x) / dt, (gB.y - gLast.y) / dt, (gB.z - gLast.z) / dt
        dp = math.deg(gy * gB.z - gz * gB.y)        -- (gdot x g).x
        dr = math.deg(gx * gB.y - gy * gB.x)        -- (gdot x g).z
      else
        dp, dr = 0, 0
      end
      gLast = gB
    else
      ep, er = a[1] - tp, a[2] - tr
      dp, dr = (a[1] - lp) / dt, (a[2] - lr) / dt
    end
    lp, lr = a[1], a[2]
    ip = clamp(ip + KI * ep * dt, CFG.IMAX)
    ir = clamp(ir + KI * er * dt, CFG.IMAX)
    -- yaw hold
    yawErr, yawDem = 0, 0
    if yawOK then
      local hdgUsed = (phase == "dash" or phase == "brake") and cruiseHdg or hdgNow
      local src = "hold"
      local yawOff = CFG.YAW_OFFSET
      if CFG.YAW_SWEEP ~= 0 and dashStart then yawOff = (yawOff + CFG.YAW_SWEEP * (t - dashStart)) % 360 end
      if phase == "dash" and CFG.CRUISE_COORD and (mode == "go" or mode == "dock") then
        -- point the lean axis (CRUISE_LEAN_AXIS clockwise from the nose) at the target
        src = "target"
        yawTgt = (math.deg(math.atan2(tgtX - pos.x, -(tgtZ - pos.z))) - CFG.CRUISE_LEAN_AXIS + yawOff) % 360
      elseif (phase == "dash" or phase == "brake") and speed > CFG.YAW_MIN_SPEED
             and (CFG.YAW_CRUISE == "course" or CFG.YAW_SWEEP ~= 0) then
        src = "course"
        yawTgt = (math.deg(math.atan2(pos.vx, -pos.vz)) + yawOff) % 360
      elseif spinDeg then
        -- spin exercise: settle at altitude, yaw +spinDeg (clockwise = heading
        -- up), hold, yaw back, hold. Progress printed with the live error.
        src = "spin"
        if not spinBase then
          if math.abs(e) < 3 then spinSettle = (spinSettle or 0) + dt else spinSettle = 0 end
          yawTgt = hdgNow
          if spinSettle > 2 then spinBase = hdgNow spinStep = 1 spinT = t print(string.format("spin: base heading %.0f, yawing +%d", spinBase, spinDeg)) end
        elseif spinStep == 1 or spinStep == 2 then
          yawTgt = (spinBase + (spinStep == 1 and spinDeg or 0)) % 360
          local reached = math.abs(((yawTgt - hdgNow + 540) % 360) - 180) < 5
          if reached and not spinHeld then spinHeld = t end
          if not reached then spinHeld = nil end
          if spinHeld and t - spinHeld > 3 then
            print(string.format("spin: step %d reached (%.1fs), heading %.0f", spinStep, t - spinT, hdgNow))
            spinStep, spinT, spinHeld = spinStep + 1, t, nil
            if spinStep == 3 then print("spin: done, holding") end
          end
        else
          yawTgt = spinBase
        end
      elseif src ~= yawSrc or not yawTgt then
        yawTgt = hdgNow                       -- re-seed at the heading we have now
      end
      yawSrc = src
      -- walk the held target toward the wanted one at YAW_SLEW deg/s
      if not yawTgtS then yawTgtS = hdgUsed end
      local want = ((yawTgt - yawTgtS + 540) % 360) - 180
      yawTgtS = (yawTgtS + clamp(want, CFG.YAW_SLEW * dt)) % 360
      yawErr = ((yawTgtS - hdgUsed + 540) % 360) - 180
      -- rate damping is the part we trust; the heading term is capped so a
      -- bad heading can never out-shout it
      local pTerm = clamp(CFG.YAW_KP * yawErr, CFG.YAW_P_MAX)
      local tiltNow0 = math.sqrt(a[1] * a[1] + a[2] * a[2])
      local sLean = clamp((tiltNow0 - CFG.YAW_LEAN_LO) / (CFG.YAW_LEAN_HI - CFG.YAW_LEAN_LO), 1)
      sLean = math.max(0, sLean)
      local yMax = CFG.YAW_MAX + sLean * (CFG.YAW_MAX_LEAN - CFG.YAW_MAX)
      yawDem = clamp(CFG.YAW_SIGN * (pTerm - CFG.YAW_KD * pos.wy), yMax)
      local tiltNow = math.sqrt(a[1] * a[1] + a[2] * a[2])
      if tiltNow > CFG.YAW_TILT_MAX then yawDem = 0 end
      -- spin guard on the raw heading: more than YAW_ABORT_DEG in 2 s
      local slot = iter % 20
      local old = hdgHist[slot]
      hdgHist[slot] = hdgNow
      if old then
        local turned = math.abs(((hdgNow - old + 540) % 360) - 180)
        if turned > CFG.YAW_ABORT_DEG and not yawWarned then
          -- sign is confirmed in flight; a fast turn now is aero, and the
          -- damping is the only thing fighting it, so warn but keep going
          yawWarned = true
          chime.play("warn")
          print(string.format("yaw: turned %.0f deg in 2 s - damping hard", turned))
        end
      end
    end

    local vx, vy = drive(pwr, KP * ep + ip + KD * dp, KP * er + ir + KD * dr, yawDem)

    local s0, s1, s2 = 0, 0, 0
    if haveVelSensors then s0, s1, s2 = rawFwd(), rawLat(), rawVrt() end
    log.writeLine(string.format("%.2f,%s,%.2f,%.2f,%.3f,%d,%.1f,%.1f,%.1f,%.1f,%.2f,%.2f,%.0f,%.0f,%.0f,%.1f,%.1f,%.1f,%.1f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.0f,%.0f,%d,%.0f,%.1f,%.2f",
      t - t0, phase, h, e, math.max(0, math.min(1, pwr)), fresh and 1 or 0, pos.x, pos.z, ex, ez, pos.vx, pos.vz, hdg, raw,
      motHdg or -1, tp, tr, a[1], a[2], vx, vy, s, s0, s1, s2, fwdSpeed(), latSpeed(), mon.energy, fuel.pct, mixSat and 1 or 0,
      yawErr, pos.wy, yawDem))
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
