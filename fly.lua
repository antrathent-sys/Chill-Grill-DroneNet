-- fly find <power>            -> hold fixed power, find hover point
-- fly <y> [x] [z]             -> hold Y, hold position or fly to x z
-- fly dock <x> <y> <z> [cruiseY] -> fly to the pad at x z and dock. y is the PAD altitude, the same
--                                shape as fly land, so both take coordinates straight off F3.
-- fly dash <y> <deg> <secs>   -> climb to Y, hold, pitch <deg> for <secs>, level, hold
-- fly spin <y> [deg]          -> climb to Y, hold, yaw clockwise <deg> (90) about the thrust axis, then back
-- fly deliver <x> <y> <z>     -> the round trip, starting docked: undock, fly to x z, hover at y,
--                                release (nothing to release yet), fly home, dock. Home is wherever
--                                the craft was standing when the command was given.
-- fly land                    -> descend where you are, detect touchdown, cut thrust. No pad, no recharge.
-- fly land <x> <y> <z> [cruiseY] -> fly to x z, then land there. y is the GROUND altitude at the
--                                destination (straight off F3), which is what the descent profile
--                                needs to know when to start braking.
--
-- IN FLIGHT, without stopping the program: press L to land where you are, H
-- to hold, U to undock, M for music, +/- for volume. The same words arrive
-- over rednet, so a ground station can send them. Landing had to be a command
-- rather than a mode: quitting to run "fly land" means no thrust while you
-- type, which is a fall, not a landing.
-- fly go <x> <z> y sweep [from] -> as go, but rotate the yaw offset 3 deg/s during cruise from <from> deg
--                                (drag-vs-yaw experiment, lean capped at 45; analyse with tools/yaw_sweep.py)
-- writes flightlog on the computer every run
local CFG = {
  HOVER = 0.25,                       -- measured 0.251 over 45 hovering rows, 2026-09-11                       -- quad: 0.3 still climbs ~7 b/s, 0.5 was the single thruster
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

  -- Landing. The ground height is not known in advance - the altitude sensor
  -- is not zeroed to it - so this descends at a fixed rate and detects the
  -- arrival instead of aiming at a number. Touchdown is "commanded to be
  -- going down, not going down, and not holding itself up": all three, for
  -- TOUCH_T, or a sensor glitch at 200 m would cut the thrust.
  -- Descent profile: fall at whatever the remaining height can arrest, then
  -- flare to a creep for the last few blocks so the touchdown is soft and the
  -- detector has time to fire. Allowed rate is sqrt(2 * LAND_DECEL * drop),
  -- the same kinematics the horizontal approach uses.
  --
  -- GROUND REFERENCE. The altitude sensor is not zeroed to the ground, so the
  -- profile needs to be told where the ground is. Default is the altitude the
  -- program started at, which is exactly right when landing where you took
  -- off and wrong by the terrain difference anywhere else. A generous flare
  -- absorbs small errors; give the third argument for a known pad.
  LAND_MAX_RATE = 60,                 -- b/s cap on the descent
  LAND_DECEL = 10,                    -- b/s^2 the profile plans to stop with. Horizontal braking measured
                                      -- 6-8, so 15 was optimistic about the vertical too and the craft
                                      -- arrived faster than the profile intended.
  LAND_APPROACH_K = 1.5,              -- 1/s: near the ground the allowed speed also tapers in proportion
                                      -- to the height left, so it eases in rather than meeting the last
                                      -- couple of blocks at whatever sqrt(2*DECEL*drop) happens to give
  LAND_FLARE = 2,                     -- blocks above the ground to be down to LAND_CREEP by. Was 10, which
                                      -- made the profile discontinuous - it wanted 17 b/s at ground+20 and
                                      -- 2 b/s at ground+10 - and the craft spent the difference hovering
                                      -- while the altitude integrator unwound. At 2 the curve is smooth
                                      -- all the way down and consistent with LAND_DECEL.
  LAND_CREEP = 2,                     -- b/s final approach
  LAND_GROUND = nil,                  -- ground altitude; nil = wherever the program started
  CRUISE_Y = 250,                     -- default transit altitude for go, dock and land-at-a-place
  LAND_CRUISE_UP = 60,                -- minimum clearance above the destination ground, if CRUISE_Y is lower
  ATT_MIN_LAND = 0.12,                -- thrust floor while landing: about half hover, so it can descend
                                      -- while leaning without giving up all attitude authority
  TOUCH_DROP = 0.6,                   -- blocks: less movement than this over TOUCH_WIN means something
                                      -- is holding us up. Measured on the altimeter, not on velocity.
  TOUCH_NEAR = 6,                     -- blocks: with a known ground altitude, touchdown cannot be declared
                                      -- above it. Generous, because the altimeter sits some way up the
                                      -- airframe (+2.8 on this one) and the craft rests on its legs, so
                                      -- "on the ground" is several blocks above the y you type. Its only
                                      -- job is to refuse a landing called from 9 blocks up.
                                      -- above it. Nothing else is as reliable, and on 2026-09-11 a landing
                                      -- was called 9 blocks up while the craft hovered out a flare transient.
  TOUCH_LOG_T = 3.0,                  -- seconds to keep logging after touchdown, thrust already off

  -- Come down straight. A burn while tilted is a sideways burn: at 0.5 thrust
  -- and TWR 5.2, ten degrees of lean is half a g of lateral push, which is
  -- most of why the first landings finished tens of blocks off. So stop and
  -- level BEFORE dropping, and keep the tilt small all the way down - hardest
  -- during the flare, where the thrust that makes the error is highest.
  LAND_SETTLE_TILT = 5,               -- deg: level enough to start falling
  LAND_SETTLE_DRIFT = 2,              -- b/s: still enough to start falling
  LAND_SETTLE_T = 0.8,                -- seconds both must hold
  LAND_SETTLE_MAX = 10,               -- seconds to wait for that before coming down anyway, at the creep
                                      -- rate. Hovering until the battery runs out is worse than a
                                      -- slightly crooked descent, and the pilot can still take over.
  LAND_TILT_MAX = 8,                  -- deg of position correction allowed while descending
  LAND_TILT_BURN = 3,                 -- deg once inside the flare, where thrust is high
  TOUCH_PWR = 0.9,                    -- fraction of HOVER: below this, the ground is taking the weight
  TOUCH_T = 0.6,                      -- seconds all three must hold
  LAND_MAX_T = 90,                    -- give up and hover rather than descend forever

  -- In-flight commands. Keys are read from an event coroutine, so they cost
  -- no peripheral calls and cannot stall the control loop.
  CMD_KEYS = true,                    -- accept single keypresses on the pod itself
  CMD_RADIO = true,                   -- accept the same words over rednet, for a ground station
  CMD_PROTO = "drone-cmd",
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
  -- Brake distance = K * speed^2 / 10, i.e. K = 5 / (b/s^2 achievable).
  -- MEASURED 2026-09-11: two brakes managed 8 and 6 b/s^2, taking 130 blocks
  -- to stop from 47 b/s where K = 0.3 predicted 72 - so it overshot and had
  -- to turn round. Not a tuning slip but the physics: braking is a lean
  -- against the travel, and past about 45 degrees the thrust that slows the
  -- craft starts lifting it instead. Set for 6 b/s^2, the worse of the two,
  -- because stopping short costs one re-cruise and overshooting costs a
  -- turn-around.
  BRAKE_K = 0.8,
  CRUISE_DECEL = 8,                   -- b/s^2 the cruise speed target plans for: v = min(CRUISE_SPEED, sqrt(2*DECEL*d)),
                                      -- so a short leg never leans to the cap (a 125-block re-cruise did, and
                                      -- ping-ponged dash/brake four times, 2026-09-10)
  RECRUISE_DIST = 60,                 -- blocks: a brake that ends further out than this goes back to dash
  ARRIVE = 8,                         -- blocks: close enough to hand over to hold

  -- monitoring: accumulator and thruster buffer are polled in their own
  -- coroutine, never from the control loop
  MON_POLL = 1.0,                     -- seconds between reads (one peripheral call per source)
  DOCK_POLL = 0.25,                   -- seconds between connector reads once the approach has started.
                                      -- The magnet can grab at any moment and that ends the flight, so
                                      -- this is the one thing worth asking about four times a second.
  ENERGY_WARN = 25,                   -- %: print LOW ENERGY (accumulator) when it drops below this
  FUEL_MODE = "fe",                   -- "fe": thruster FE buffer first; "fluid": liquid tank first
  FUEL_NAME = nil,                    -- thruster-side source; nil = the thruster itself
  FUEL_CAP = 0,                       -- mB; only needed when a fluid source reports amount but not capacity
  FUEL_WARN = 25,                     -- %: print LOW THRUSTER when the thruster buffer drops below this
  -- pump auto-start: switched on before takeoff, off when the program exits
  -- Redstone outputs. A plain string is a side of THIS computer. A table is
  -- somewhere else on the wired network - see lib/rs.lua:
  --   { relay = "redstone_relay_0", side = "back" }   CC:Tweaked relay, CC >= 1.109
  --   { slave = "drone-rs",         side = "back" }   a computer running rsio.lua
  PUMP_SIDE = nil,                    -- redstone side to hold high, e.g. "back" -> clutch on the pump shaft
  PUMP_MOTOR = nil,                   -- CC&A electric motor peripheral name that spins the pump
  PUMP_RPM = 32,
  PUMP_PRIME = 0,                     -- seconds to wait after starting the pump before flying

  -- docking. The connector is a magnet: it locks once the tips are within
  -- 0.5 blocks and 20 deg (server config docking_connector_distance/_angle)
  -- and pulls itself the last of the way, so these numbers only have to park
  -- the drone inside its reach, not hit the lock window by flying.
  DOCK_SIDE = "back",                 -- proved with `docktest back` on 2026-09-11: signal=true reached the
                                      -- connector. nil turns docking off. If the layout changes and there is no
                                      -- free face next to it, so this is the slave's REAR face:
                                      -- { slave = "drone-rs", side = "back" }
  DOCK_NAME = nil,                    -- docking_connector peripheral name; nil = peripheral.find
  DOCK_ALIGN = 1.0,                   -- blocks: horizontal error to sit inside before descending
  DOCK_TRIM_X = 0, DOCK_TRIM_Z = 0,   -- blocks added to the dock target, if the connector is not directly
                                      -- under the craft's centre of mass
  -- getConnectedName() is the connector's entire API and it returns "" even
  -- when physically latched, at least to an unnamed pad - confirmed on the
  -- ground 2026-09-11 while docked. So the dock is detected by the wired
  -- network instead: latching bridges the pad's peripherals in, and the count
  -- visible to this computer jumps. The baseline is taken at startup, before
  -- the connector is ever extended.
  -- The peripheral count does not change either: 32 docked and 32 undocked,
  -- measured on the ground. So neither thing the connector or the network can
  -- tell us distinguishes the two states.
  --
  -- What DOES change is the power. The pad only feeds the craft once latched,
  -- so an accumulator that is gaining charge while the thrusters are idle is
  -- a dock - a physical fact rather than an API's opinion.
  DOCK_BRIDGE_MIN = 2,                -- extra peripherals that count as a dock (kept; harmless if never true)
  DOCK_CHARGE_FE = 200,               -- FE of gain between polls that counts as charging
  DOCK_CHARGE_N = 3,                  -- consecutive polls of it before calling it a dock
  DOCK_ALIGN_SPD = 0.5,               -- b/s: ground speed to be under as well
  DOCK_SETTLE_T = 2.0,                -- seconds of holding both of those before the descent starts
  DOCK_ALIGN_GRACE = 6,               -- failing samples tolerated before the settle timer resets
  -- MEASURED, not guessed: with the pad at Y 63 the craft comes to rest with
  -- the altimeter reading 70.5, so the gap is 7.5 - the altimeter sits 2.8
  -- blocks up the airframe and the legs hold the rest. At the old value of 3
  -- the descent profile aimed 4.5 blocks below anything reachable, so it was
  -- still asking for 7 b/s when it arrived, and hit the pad at about 10.
  -- To re-measure on a new airframe: land on the pad and take the altimeter
  -- reading where it stops, minus the pad Y.
  DOCK_GAP = 7.5,
  DOCK_BAND = 0.5,                    -- blocks: how close to the park altitude counts as arrived
  DOCK_RATE = 1.5,                    -- b/s: how fast the altitude goal walks down
  DOCK_SINK = 0.0,                    -- power bled off in capture so the magnet can pull down
  DOCK_CAPTURE_T = 8,                 -- seconds to wait for the magnet before aborting. It either takes
                                      -- hold almost at once or it is not going to; 25 just meant three
                                      -- minutes of cycling before the craft gave up.
  DOCK_ABORT_DIST = 4,                -- blocks of drift that sends the descent back to align
  DOCK_TRIES = 3,                     -- capture attempts before giving up and just holding
  LEG_ARRIVE = 4,                     -- blocks: horizontal tolerance for calling a mission leg done
  LEG_ARRIVE_Y = 4,                   -- blocks: vertical tolerance for the same
  DROP_HOLD = 2.0,                    -- seconds to sit still over the drop point before releasing
  DROP_SETTLE_SPD = 1.5,              -- b/s: what counts as sitting still for that
  DOCK_RETRY_UP = 15,                 -- blocks above the park height to back off to for another try.
                                      -- Climbing back to cruise altitude cost 80 s of a 208 s flight:
                                      -- above SPEED_GUARD the position hold does not act at all, so
                                      -- the craft coasted 250 blocks away and then crawled back.
  -- Undocking. Dropping the connector and THEN spooling up is a fall: the
  -- pad lets go the instant the signal goes low. So hold full thrust against
  -- the magnet first and only release once the hardware confirms it has it.
  UNDOCK_THRUST = 1.0,                -- commanded while still attached
  UNDOCK_CONFIRM = 0.95,              -- fraction of it that athr must actually reach
  UNDOCK_HOLD = 0.3,                  -- seconds it must hold there before the connector drops
  DOCK_RELEASE_T = 8,                 -- seconds before giving up waiting for that and releasing anyway

  -- Square up to the pad. The connector locks within 20 degrees, so meeting
  -- it already square means the magnet has only to close the gap, not twist
  -- the craft. Cardinal because that is how pads get built.
  DOCK_CARDINAL = true,
  DOCK_YAW_TOL = 8,                   -- degrees off the nearest cardinal that still counts as square

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

-- F3 reports the block's integer coordinate, but a block at x=0 spans 0..1
-- and its centre is 0.5 - and a craft parks its centre of mass over a point,
-- not its corner. Typing pad coordinates straight off F3 therefore left the
-- drone exactly half a block out in BOTH axes: a 0.71 diagonal against a
-- connector that locks within 0.5, so it sat just outside the magnet's reach
-- for three whole flights (2026-09-11). Aim at the middle of the named block.
-- Idempotent for coordinates already given as centres.
local function blockCentre(v) return math.floor(v) + 0.5 end
local function rawHeading() return (CFG.HDG_SIGN * nav.getRelativeAngle() + CFG.HDG_OFFSET) % 360 end

-- ---------- thrusters ----------
-- One thruster: drive it directly, as before. More than one: lib/mixer.lua,
-- with a corner map that must name every fitted thruster or a corner would
-- sit idle and the craft would flip on lift-off.
local mixer = nil
local mixNames = {}
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
  for _, m in ipairs(map) do mixNames[#mixNames + 1] = m.name end
  local n, missing = mixer.configure({ thrusters = map, VEC_MAX = CFG.VEC_MAX })
  if #missing > 0 then error("mixer map names thrusters that are not fitted: " .. table.concat(missing, " ")) end
  -- Name them. A count alone hid a network picking up peripherals that were
  -- not on the craft; the mixer will drive whatever is in this list.
  local names = {}
  for _, m in ipairs(map) do names[#names + 1] = (m.name:gsub("^vector_thruster_", "#")) end
  print(string.format("mixer: %d thrusters (%s), mode %s", n, table.concat(names, " "), CFG.MIX_MODE))
end
do
  local okN, names = pcall(peripheral.getNames)
  if okN and type(names) == "table" then
    print(string.format("network: %d peripherals (docking should add at least %d more)",
      #names, CFG.DOCK_BRIDGE_MIN))
  end
end
if #accs > 1 then
  local an = {}
  for _, a in ipairs(accs) do an[#an + 1] = (peripheral.getName(a):gsub("^modular_accumulator_", "#")) end
  print("accumulators: " .. #accs .. " averaged (" .. table.concat(an, " ") .. ")")
end

-- Push one lift power and the attitude PID's raw pitch/roll outputs (before
-- P_SIGN/R_SIGN) to the hardware. Returns the two numbers that went out, for
-- the log: nozzle vector on the single thruster, differential demand in diff
-- mode.
-- What the thrusters were actually told, as opposed to what was asked for.
-- The two part company whenever the mixer saturates: attitude-priority
-- rescales the whole set to make the differential fit, which moves the MEAN.
-- A flight on 2026-09-11 logged pwr 0.00-0.25 the whole way up while climbing
-- at 45 b/s, because a saturated mixer pins the mean near 0.50 whatever lift
-- is asked for. Never diagnose from the demand alone again.
local mixSat = false
local mixThr, mixMax = 0, 0        -- mean and worst actual thrust, 0..1
local function drive(p, up, ur, yaw)
  local cp, cr = CFG.P_SIGN * up, CFG.R_SIGN * ur
  local vx = clamp(CFG.P_AXIS == "x" and cp or cr, CFG.VEC_MAX)
  local vy = clamp(CFG.P_AXIS == "x" and cr or cp, CFG.VEC_MAX)
  if not mixer then
    local pw = math.max(0, math.min(1, p))
    thr.setVector(vx, vy)
    thr.setPowerNormalized(pw)
    mixThr, mixMax = pw, pw
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
  local thrusts, _, sat = mixer.write(d)
  mixSat = sat
  local sum, worst, count = 0, 0, 0
  for _, v in ipairs(thrusts) do
    sum, count = sum + v, count + 1
    if v > worst then worst = v end
  end
  mixThr = count > 0 and sum / count or 0
  mixMax = worst
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
-- `npers` is how many peripherals the wired network can see. Docking bridges
-- the pad's network to the craft's, so the count jumps - an independent signal
-- that the connector has taken hold, for when getConnectedName() is unhelpful.
-- (It is also almost certainly why a preflight once reported 8 thrusters and 8
-- accumulators on a 4-of-each airframe.)
local dock = { armed = false, connected = false, name = "", extended = false,
               npers = 0, nbase = nil, bridged = false,
               lastFE = nil, chargeN = 0, charging = false }
local accCap = {}          -- accumulator capacities, read once
local dockP = CFG.DOCK_NAME and peripheral.wrap(CFG.DOCK_NAME) or peripheral.find("docking_connector")
if CFG.DOCK_NAME and not dockP then print("WARNING: docking connector " .. CFG.DOCK_NAME .. " not found") end
local function dockExtend(on)
  if CFG.DOCK_SIDE then
    local ok, err = RS.set(CFG.DOCK_SIDE, on)
    if not ok then print("DOCK REDSTONE FAILED: " .. tostring(err)) end
  end
end

-- Libraries. These load unconditionally: they were once nested inside the
-- chime block, which meant turning chimes off silently dropped the attitude
-- maths back to raw gimbal angles.
--
-- attitude maths (gravity vector from the gimbal's projected angles)
local okA, libA = pcall(dofile, "lib/attitude.lua")
ATT = okA and type(libA) == "table" and libA or nil
if not ATT then print("WARNING: lib/attitude.lua missing - attitude errors fall back to raw gimbal angles") end

-- redstone that is not necessarily on this computer's faces (see lib/rs.lua)
local okR, libR = pcall(dofile, "lib/rs.lua")
RS = okR and type(libR) == "table" and libR or nil
if not RS then
  RS = { set = function(t, on) if type(t) == "string" then redstone.setOutput(t, on) return true end
                               return false, "lib/rs.lua missing, cannot drive " .. tostring(t) end,
         clear = function(keep) for _, s in ipairs(redstone.getSides()) do
                   if s ~= keep then redstone.setOutput(s, false) end end end,
         poll = function() end, check = function() return {} end,
         describe = function(t) return tostring(t) end }
  print("WARNING: lib/rs.lua missing - only redstone on this computer's own faces will work")
end

-- Chimes. Optional, silent without a speaker, and every call returns instantly
-- so nothing here can stall the control loop.
local chime = { play = function() end, loop = function() while true do sleep(1) end end }
if CFG.CHIME and fs.exists("lib/chime.lua") then
  local ok, lib = pcall(dofile, "lib/chime.lua")
  if ok and lib then
    local spk = peripheral.find("speaker")
    if spk and lib.attach(spk) then
      chime = lib
      print("speaker: chimes on (" .. #chime.list() .. " sounds; 'chimes' to audition)")
      chime.play("boot")
    end
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
  local warnE, warnF, warnT, warnR = false, false, false, false
  local lastE, lastT = nil, nil
  while true do
    -- Thrusters still on the network? Losing one corner flips a quad, and
    -- every mixer write is pcall'd, so the failure is silent. Checked here
    -- once per MON_POLL, never in the control loop.
    if mixer then
      local lost = {}
      for _, nm in ipairs(mixNames) do
        local okp, present = pcall(peripheral.isPresent, nm)
        if okp and not present then lost[#lost + 1] = nm end
      end
      if #lost == 0 then
        for _, nm in ipairs(mixer.faults(3)) do lost[#lost + 1] = nm .. " (not responding)" end
      end
      if #lost > 0 then
        if not warnT then
          warnT = true
          chime.play("lost", true)
          print("THRUSTER LOST: " .. table.concat(lost, ", "))
          print("  attitude authority is gone on that corner - land now")
        end
      else
        warnT = false
      end
    end
    -- Remote redstone: a dead slave means the docking connector cannot be
    -- extended or released. Better to hear about it in the cruise than on
    -- final approach. rs.poll costs at most a tick, and only here.
    RS.poll()
    local rsBad = RS.check()
    if #rsBad > 0 then
      if not warnR then
        warnR = true
        chime.play("warn")
        print("REDSTONE: " .. table.concat(rsBad, "; "))
      end
    else
      warnR = false
    end
    if acc then
      -- getEnergy rather than getPercent: same one call per accumulator, but
      -- raw FE resolves a trickle of charge that a rounded percentage hides.
      local sumE, sumC, n = 0, 0, 0
      for i, a in ipairs(accs) do
        local ok, e = pcall(a.getEnergy)
        if ok and e then
          sumE, n = sumE + e, n + 1
          if not accCap[i] then
            local okc, c = pcall(a.getCapacity)
            accCap[i] = (okc and c) or 0
          end
          sumC = sumC + (accCap[i] or 0)
        end
      end
      -- Charging while docked is the one thing that tells the two states
      -- apart on this pad. Thrusters only ever take power out, so a rise is
      -- the pad feeding us.
      if dock.lastFE and sumE > dock.lastFE + CFG.DOCK_CHARGE_FE then
        dock.chargeN = (dock.chargeN or 0) + 1
      else
        dock.chargeN = 0
      end
      dock.lastFE = sumE
      dock.charging = (dock.chargeN or 0) >= CFG.DOCK_CHARGE_N
      if n > 0 then
        local pct = (sumC > 0) and (100 * sumE / sumC) or 0
        local now = os.clock()
        if lastE and now > lastT then
          local r = (pct - lastE) / (now - lastT) * 60
          mon.rate = mon.rate + 0.2 * (r - mon.rate)
        end
        lastE, lastT = pct, now
        mon.energy, mon.t = pct, now
        if pct < CFG.ENERGY_WARN and not warnE then
          warnE = true
          chime.play("lowpower")
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
            warnF = true chime.play("lowfuel")
            print(string.format("LOW %s %.0f%%", fuelLabel, fuel.pct))
          elseif fuel.pct >= CFG.FUEL_WARN + 5 then
            warnF = false
          end
        end
      end
    end
    do
      local okN, names = pcall(peripheral.getNames)
      if okN and type(names) == "table" then
        dock.npers = #names
        dock.nbase = dock.nbase or dock.npers      -- what we see on our own
        dock.bridged = dock.npers >= dock.nbase + CFG.DOCK_BRIDGE_MIN
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
    -- While the connector is extended the magnet can take hold at any moment,
    -- and that is what ends the flight, so ask often. Everything else in this
    -- loop is happy at MON_POLL.
    if dock.armed and dockP then
      local until_ = os.clock() + CFG.MON_POLL
      repeat
        sleep(CFG.DOCK_POLL)
        local ok, name = pcall(dockP.getConnectedName)
        if ok and type(name) == "string" and name ~= "" then
          dock.connected, dock.name = true, name
        else
          dock.connected = false
        end
      until dock.connected or os.clock() >= until_
    else
      sleep(CFG.MON_POLL)
    end
  end
end

-- pump: hold a redstone side and/or spin a CC&A electric motor for the flight
local pumpMotor = CFG.PUMP_MOTOR and peripheral.wrap(CFG.PUMP_MOTOR) or nil
if CFG.PUMP_MOTOR and not pumpMotor then print("WARNING: pump motor " .. CFG.PUMP_MOTOR .. " not found") end
local function pump(on)
  if CFG.PUMP_SIDE then
    local ok, err = RS.set(CFG.PUMP_SIDE, on)
    if not ok then print("PUMP REDSTONE FAILED: " .. tostring(err)) end
  end
  if pumpMotor then
    if on then pumpMotor.setSpeed(CFG.PUMP_RPM) else pumpMotor.stop() end
  end
end
-- forward (nose-axis) speed from the velocity sensor, positive = moving forward
local pos = { x = 0, z = 0, vx = 0, vz = 0, vy = nil, t = 0, rej = 0, wy = 0 }   -- vy: Sable vertical speed; wy: world yaw rate, deg/s

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
    if type(av) == "table" and av.y then pos.wy = -math.deg(av.y) end   -- +y spin turns heading DOWN
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
local landGround = CFG.LAND_GROUND   -- ground altitude for the descent profile
-- A mission is a list of legs run back to back. Each leg sets up the ordinary
-- mode machinery and finishes at a point the phase machine already reaches, so
-- nothing here duplicates the flying - it only decides what comes next.
local legs, legIdx, home = nil, 0, nil
local landAtEnd = false              -- a "go" that finishes by landing rather than holding
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
    tgtX = blockCentre(tonumber(arg[2]) or error("go needs x z"))
    tgtZ = blockCentre(tonumber(arg[3]) or error("go needs x z"))
    goal = tonumber(arg[4]) or CFG.CRUISE_Y
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
    -- <x> <y> <z>: the same order as fly land, y being the pad altitude
    tgtX = blockCentre(tonumber(arg[2]) or error("dock needs <x> <y> <z>", 0)) + CFG.DOCK_TRIM_X
    padY = tonumber(arg[3]) or error("dock needs <x> <y> <z>", 0)
    tgtZ = blockCentre(tonumber(arg[4]) or error("dock needs <x> <y> <z>", 0)) + CFG.DOCK_TRIM_Z
    goal = tonumber(arg[5]) or CFG.CRUISE_Y
    dockAlt = padY + CFG.DOCK_GAP
    dashDeg = CFG.CRUISE_DEG
    dock.armed = true
  elseif arg[1] == "undock" then
    -- release, then hold like a normal flight. The connector is not dropped
    -- until the control loop has had DOCK_RELEASE_T of thrust behind it.
    mode = "fly" undockFirst = true
    goal = tonumber(arg[2]) or (alt.getHeight() + 5)
  elseif arg[1] == "land" then
    local ax, ay, az = tonumber(arg[2]), tonumber(arg[3]), tonumber(arg[4])
    if ax and ay and az then
      -- <x> <y> <z>: fly there first. Internally this IS a go - all the
      -- cruise, brake and re-cruise machinery is reused unchanged - and only
      -- the phase it finishes in differs. y is the ground at the far end, so
      -- the descent profile knows where to start braking.
      mode = "go" landAtEnd = true
      tgtX, tgtZ = blockCentre(ax), blockCentre(az)
      landGround = ay
      goal = tonumber(arg[5]) or math.max(CFG.CRUISE_Y, ay + CFG.LAND_CRUISE_UP)
      dashDeg = CFG.CRUISE_DEG
    elseif ax and ay then
      -- <x> <z>: fly there, but the ground is a guess (the start height)
      mode = "go" landAtEnd = true
      tgtX, tgtZ = blockCentre(ax), blockCentre(ay)
      goal = tonumber(arg[4]) or CFG.CRUISE_Y
      dashDeg = CFG.CRUISE_DEG
    else
      -- straight down from here
      mode = "land"
      goal = alt.getHeight()
    end
  elseif arg[1] == "deliver" then
    -- The whole round trip in one command, which is the point: a dynamics
    -- change is worth judging over undock, cruise, descent, hover, cruise
    -- back and dock, not over whichever single leg happened to be flown.
    local dx = tonumber(arg[2]) or error("deliver needs <x> <y> <z>", 0)
    local dy = tonumber(arg[3]) or error("deliver needs <x> <y> <z>", 0)
    local dz = tonumber(arg[4]) or error("deliver needs <x> <y> <z>", 0)
    goal = tonumber(arg[5]) or CFG.CRUISE_Y
    -- Home is wherever the craft is standing when the command is given.
    -- Sitting on the pad the altimeter reads DOCK_GAP above it, which is
    -- exactly the pad altitude the dock leg wants back.
    home = { x = blockCentre(px), z = blockCentre(pz), padY = alt.getHeight() - CFG.DOCK_GAP }
    legs = {
      { leg = "cruise", x = blockCentre(dx), z = blockCentre(dz), y = goal, undock = true },
      { leg = "hover",  x = blockCentre(dx), z = blockCentre(dz), y = dy },
      { leg = "action", what = "drop" },
      -- no cruise leg home: the dock leg climbs, cruises and brakes on its
      -- own, which is the same path `fly dock` flies and the one with hours
      -- of logs behind it.
      { leg = "dock",   x = home.x, z = home.z, padY = home.padY, y = goal },
    }
    mode = "deliver"
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
  if mode == "land" then goalX = tonumber(arg[2]) or px goalZ = tonumber(arg[3]) or pz end
  if mode == "go" or mode == "dock" then goalX, goalZ = tgtX, tgtZ end
  cruiseY = goal
end

local log = fs.open("flightlog", "w")
-- athr/amax are what the thrusters were ACTUALLY given, mean and worst. pwr
-- is only what the altitude loop asked for; they part company whenever sat=1.
log.writeLine("t,phase,height,err,pwr,gps,x,z,ex,ez,vxw,vzw,hdg,rawhdg,mothdg,tp,tr,p,r,vx,vy,sched,fwdRaw,latRaw,vrtRaw,fwdH,latH,energy,fuel,sat,yerr,yrate,ydem,athr,amax,vv,dockc,npers,chg")
local t0 = os.clock()
print(mode == "find" and ("find: holding " .. findP)
   or mode == "dash" and string.format("dash: Y %.0f, %d deg for %ds", goal, dashDeg, dashSecs)
   or (mode == "go" and not landAtEnd) and string.format("go: to %.0f,%.0f via Y %.0f", tgtX, tgtZ, goal)
   or mode == "dock" and string.format("dock: pad %.0f,%.0f Y %.0f, park at %.1f via Y %.0f",
      tgtX, tgtZ, padY, dockAlt, goal)
   or mode == "deliver" and string.format("deliver: %.0f,%.0f drop at Y %.0f, home %.0f,%.0f pad %.0f, via Y %.0f",
      legs[1].x, legs[1].z, legs[2].y, home.x, home.z, home.padY, goal)
   or undockFirst and string.format("undock: release then hold Y %.1f", goal)
   or spinDeg and string.format("spin: hold Y %.0f, yaw +%d then back", goal, spinDeg)
   or (mode == "land" or landAtEnd) and string.format("land%s: up to %g b/s, flare %g above %s",
      landAtEnd and string.format(" at %.0f,%.0f via Y %.0f", tgtX, tgtZ, goal) or " here",
      CFG.LAND_MAX_RATE, CFG.LAND_FLARE,
      landGround and string.format("%.0f", landGround) or "the start height")
   or string.format("fly: Y %.1f to %.1f,%.1f hdg %.0f", goal, goalX, goalZ, rawHeading()))
print("position: " .. (usingSable and "CC:Sable pose" or "gps") ..
      (usingSable and "" or "  (WARNING: the host array was 45 blocks out when last measured)"))
print("Ctrl+T stops")
pump(true)
if CFG.PUMP_PRIME > 0 then print("priming pump") sleep(CFG.PUMP_PRIME) end

-- Set up the next leg, or report that the mission is over. Every line here
-- writes one of the same handful of variables the command line writes for a
-- single-purpose flight, so a leg flies down exactly the code path the
-- equivalent command would - there is no second flight controller in here.
local legKind = nil
local function nextLeg()
  if not legs then return false end
  legIdx = legIdx + 1
  local L = legs[legIdx]
  -- Actions happen between legs, instantly, and then we move on.
  while L and L.leg == "action" do
    -- Nothing is carried yet. The hook is here and named, so when there is a
    -- payload the change is this line and nothing else.
    print("action: " .. tostring(L.what) .. " (no payload fitted - nothing released)")
    chime.play(L.what == "drop" and "drop" or "ready", true)
    legIdx = legIdx + 1
    L = legs[legIdx]
  end
  if not L then return false end
  legKind = L.leg
  undockFirst = L.undock or false
  landAtEnd = false
  dock.armed = false
  if L.leg == "cruise" then
    mode = "go"
    tgtX, tgtZ = L.x, L.z
    goalX, goalZ = L.x, L.z
    goal = L.y
    dashDeg = CFG.CRUISE_DEG
    cruiseY = goal
  elseif L.leg == "hover" then
    mode = "fly"
    goalX, goalZ = L.x, L.z
    goal = L.y
  elseif L.leg == "dock" then
    mode = "dock"
    tgtX, tgtZ = L.x + CFG.DOCK_TRIM_X, L.z + CFG.DOCK_TRIM_Z
    goalX, goalZ = tgtX, tgtZ
    padY = L.padY
    dockAlt = padY + CFG.DOCK_GAP
    goal = L.y or CFG.CRUISE_Y
    dashDeg = CFG.CRUISE_DEG
    cruiseY = goal
    dock.armed = true
  else
    error("unknown leg " .. tostring(L.leg), 0)
  end
  print(string.format("--- leg %d: %s to %.1f,%.1f at Y %.0f%s",
    legIdx, L.leg, goalX, goalZ, goal, undockFirst and " (undock first)" or ""))
  if L.leg == "dock" then chime.play("home") end
  return true
end

local function flyLeg()
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
  local touchT, landStart = 0, nil     -- touchdown debounce, and the giving-up clock
  local undockT = 0                    -- seconds at full thrust while still attached
  local descStuck = 0                  -- seconds the dock descent has not been descending
  local hHist, touchWin = {}, 12       -- ring of recent altitudes, ~1.2 s at 10 Hz
  local touchAt = nil                  -- when touchdown fired, for the post-landing log
  local landSettled, settleT, settleWarned = false, 0, false  -- stopped and level before the drop
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
  local lastPhase = nil
  local legT = 0            -- seconds settled over this leg's waypoint
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

    if undockFirst and not released then
      -- Spool up against the magnet BEFORE letting go. The pad releases the
      -- instant the signal drops, so releasing first and building thrust
      -- afterwards is a fall with extra steps.
      if mixThr >= CFG.UNDOCK_THRUST * CFG.UNDOCK_CONFIRM then
        undockT = undockT + dt
      else
        undockT = 0
      end
      if undockT >= CFG.UNDOCK_HOLD then
        released = true dock.armed = false dock.extended = false dockExtend(false)
        chime.play("undocked")
        print(string.format("released at %.2f thrust", mixThr))
      elseif t - t0 > CFG.DOCK_RELEASE_T then
        released = true dock.armed = false dock.extended = false dockExtend(false)
        chime.play("warn")
        print(string.format("released WITHOUT full thrust (%.2f) after %ds", mixThr, CFG.DOCK_RELEASE_T))
      end
    end

    -- Has the altimeter stopped moving? Both landing and docking need this,
    -- and it must be sampled every iteration or the ring buffer is meaningless.
    local hSlot = iter % touchWin + 1
    local hAgo = hHist[hSlot]
    hHist[hSlot] = h
    local hStuck = hAgo ~= nil and math.abs(h - hAgo) < CFG.TOUCH_DROP

    lastPhase = phase
    -- A command from the keyboard or the radio, taken at a clean point.
    if cmdReq then
      local r = cmdReq cmdReq = nil
      if r == "land" and phase ~= "land" and phase ~= "touchdown" and phase ~= "docked" then
        phase = "land" landStart, touchT = t, 0
        goalX, goalZ = pos.x, pos.z
        enter("land")
      elseif r == "hold" and phase ~= "touchdown" and phase ~= "docked" then
        phase = "hold" goal = h goalX, goalZ = pos.x, pos.z
        dock.armed = false
        enter("hold")
      elseif r == "undock" then
        dock.armed = false dockExtend(false)
        chime.play("undocked") print("connector released")
      end
    end

    if phase == "land" then
      -- Three things at once, sustained: we asked to descend, we are not
      -- descending, and the throttle is below what hovering costs - so
      -- something other than the thrusters is holding the craft up.
      landStart = landStart or t
      -- Settle first: arrive, stop, level. Falling while still leaning off
      -- the brake is what put the last one 38 blocks out.
      if not landSettled then
        local gs = math.sqrt(pos.vx * pos.vx + pos.vz * pos.vz)
        local lean = math.sqrt(a[1] * a[1] + a[2] * a[2])
        if lean < CFG.LAND_SETTLE_TILT and gs < CFG.LAND_SETTLE_DRIFT then
          settleT = settleT + dt
          if settleT >= CFG.LAND_SETTLE_T then
            landSettled = true
            print(string.format("settled: %.1f deg, %.1f b/s, %.0f blocks out - dropping",
              lean, gs, math.sqrt((goalX - pos.x)^2 + (goalZ - pos.z)^2)))
          end
        else
          settleT = 0
        end
        if not settleWarned and t - landStart > CFG.LAND_SETTLE_MAX then
          -- Could not get straight. Something is wrong - aero moment, a weak
          -- corner - and hovering until the battery dies is not better than
          -- coming down crooked. Go, but keep the tight tilt cap and say so.
          settleWarned, landSettled = true, true
          chime.play("warn")
          print(string.format("did not settle in %ds (%.0f deg, %.1f b/s) - coming down anyway",
            CFG.LAND_SETTLE_MAX, lean, gs))
        end
      end
      -- Measure the ALTITUDE, not the velocity. `v` comes from Sable's
      -- vertical speed, and a single zero from it - stale pose, a dropped
      -- read - looks exactly like arriving on the ground. A flight on
      -- 2026-09-11 called touchdown while still in the air on an angle.
      -- Altitude is a direct reading: if it has not moved while we are asking
      -- to come down, something is holding us up.
      local stuck = hStuck
      local unloaded = lastPwr < CFG.HOVER * CFG.TOUCH_PWR
      -- If the ground altitude was given, believe it: no amount of hovering
      -- counts as a landing while still well above it.
      local nearGround = (not landGround) or (h - landGround < CFG.TOUCH_NEAR)
      if stuck and unloaded and nearGround and vWantS < -0.5 then
        touchT = touchT + dt
      else
        touchT = 0
      end
      if touchT >= CFG.TOUCH_T then
        phase = "touchdown" enter("touchdown")
        print(string.format("down at %.1f,%.1f after %.0fs", pos.x, pos.z, t - landStart))
      elseif t - landStart > CFG.LAND_MAX_T then
        phase = "hold" goal = h goalX, goalZ = pos.x, pos.z
        print("land: no touchdown in " .. CFG.LAND_MAX_T .. "s - holding instead")
        chime.play("warn", true)
      end
    elseif phase == "climb" then
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
      local f, l = fwdSpeed(), latSpeed()
      -- ground speed from Sable (the body-frame sensors are legacy); the old
      -- 40 b/s cap limited the brake point to 160 blocks and an 82 b/s
      -- cruise ran straight through the target (2026-09-10)
      local fs = math.min(math.sqrt(pos.vx * pos.vx + pos.vz * pos.vz), 150)
      if d < math.max(CFG.ARRIVE, CFG.BRAKE_K * fs * fs / 10) then
        phase = "brake" brakeStart = t chime.play("brake")
        print(string.format("brake at %.0f blocks, %.1f b/s", d, fs))
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
          phase = (mode == "dock") and "align" or (landAtEnd and "land" or "hold")
          if mode ~= "go" and mode ~= "dock" then goalX, goalZ = pos.x, pos.z end
          if phase == "land" then landStart, touchT = t, 0 end
          enter(phase)
        end
      end
    elseif (dock.connected or dock.bridged or dock.charging)
           and (phase == "align" or phase == "descend" or phase == "capture") then
      -- The magnet has it. That is the whole objective, whichever phase we
      -- happened to be in when it took hold - there is nothing left to fly.
      phase = "docked"
      print(string.format("DOCKED to %s (from %s, %s)", 
        dock.name ~= "" and dock.name or "unnamed pad", tostring(lastPhase),
        dock.connected and "connector reports it" or
        dock.charging and "the pad is charging us" or
          string.format("network went %d -> %d peripherals", dock.nbase or 0, dock.npers)))
    elseif phase == "align" then
      -- Extend on entry, not on exit: the connector is magnet-assisted, so
      -- arming it while we settle over the pad lets it help pull the last
      -- half block in rather than waiting until we are already there.
      if not dock.extended then dockExtend(true) dock.extended = true
        print("connector extended") end
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
      local offCard = math.abs(((hdgNow + 45) % 90) - 45)   -- degrees from the nearest cardinal
      local square = (not CFG.DOCK_CARDINAL) or offCard < CFG.DOCK_YAW_TOL
      if pos.t > 0 and (t - pos.t) < 1.5 and d < CFG.DOCK_ALIGN and sp < CFG.DOCK_ALIGN_SPD and square then
        if not alignStart then alignStart = t end
        alignBad = 0
        if t - alignStart > CFG.DOCK_SETTLE_T then
          phase = "descend" chime.play("descend")
          print(string.format("descend to %.1f", dockAlt))
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
        phase = "align" alignStart = nil
        goal = math.min(cruiseY, dockAlt + CFG.DOCK_RETRY_UP)
        print(string.format("drifted %.1f blocks - back to align at %.0f", d, goal))
      else
        -- The descent itself is the landing profile - fall at whatever the
        -- height left can arrest, flare to a creep - with dockAlt as the
        -- ground. See the altitude section; goal is only kept in step so the
        -- error term reads sensibly in the log.
        goal = dockAlt
        -- Two ways to have arrived. The park height is a number someone typed
        -- and can be wrong - on 2026-09-11 the craft physically stopped 4.5
        -- blocks above it, so this phase waited for a height it could never
        -- reach, with thrust at zero, indefinitely. Stopping is arriving.
        if h <= dockAlt + CFG.DOCK_BAND then
          phase = "capture" captureStart = t chime.play("capture")
          print("capture - waiting for the magnet")
        elseif hStuck and vWantS < -0.5 then
          descStuck = descStuck + dt
          if descStuck >= CFG.TOUCH_T then
            phase = "capture" captureStart = t chime.play("capture")
            print(string.format("stopped descending at %.1f (park height %.1f) - trying the magnet here", h, dockAlt))
          end
        else
          descStuck = 0
        end
      end
    elseif phase == "capture" then
      goal = dockAlt
      if dock.connected then
        phase = "docked" print("DOCKED to " .. dock.name)
      elseif t - captureStart > CFG.DOCK_CAPTURE_T then
        dockTries = dockTries + 1
        goal = math.min(cruiseY, dockAlt + CFG.DOCK_RETRY_UP)
        if dockTries >= CFG.DOCK_TRIES then
          phase = "hold" dockExtend(false) dock.armed = false dock.extended = false
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
      if phase == "land" or phase == "descend" then
        -- descend (docking) uses the same profile, with the park height as
        -- its ground; align has already done the settling for it
        local settled = (phase == "descend") or landSettled
        if not settled then
          vWant = 0                    -- hold this height until we are straight
        else
          -- go down, not to a number: as fast as the height left can arrest
          local ground = (phase == "descend") and dockAlt or (landGround or h0)
          local drop = math.max(0, h - ground - CFG.LAND_FLARE)
          -- two limits, whichever is slower: what the height left can arrest,
          -- and a proportional taper that goes to nothing at the ground
          vWant = -math.max(CFG.LAND_CREEP,
                    math.min(CFG.LAND_MAX_RATE,
                             math.sqrt(2 * CFG.LAND_DECEL * drop),
                             CFG.LAND_APPROACH_K * math.max(0, h - ground)))
        end
      end
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
        pwr = pwr + CFG.HOVER * (1 / math.max(ct, 0.42) - 1) + CFG.DASH_POWER
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
        -- Measured hover is about 0.245, so the normal 0.25 floor IS hover:
        -- above ATT_MIN_TILT it would hold altitude and the craft could never
        -- come down while still leaning off a cruise. Descending deliberately
        -- gets a lower floor - still half the vectoring authority, but light
        -- enough to fall.
        local floor = (phase == "land") and CFG.ATT_MIN_LAND or CFG.ATT_MIN_POWER
        if tiltA > CFG.ATT_MIN_TILT then pwr = math.max(pwr, floor) end
      end
      if phase == "docked" or phase == "touchdown" then pwr = 0 end
      -- still bolted to the pad: ask for everything, so the release has
      -- something to confirm and the craft leaves positively
      if undockFirst and not released then pwr = CFG.UNDOCK_THRUST end
    end

    local hdg, raw = hdgNow, rawH
    local tp, tr, ex, ez = 0, 0, 0, 0
    local fresh = mode ~= "find" and pos.t > 0 and (t - pos.t) < 1.5
    local speed = math.sqrt(pos.vx * pos.vx + pos.vz * pos.vz)
    -- DOCK BELONGS HERE TOO. It did not, until 2026-09-11: dock fell through
    -- to the open-loop branch below and cruised at a fixed 70 degree lean,
    -- accelerating with nothing watching the speed. It reached 80 b/s and 83
    -- degrees of actual lean before departing, on a pad 140 blocks away.
    if phase == "dash" and (mode == "go" or mode == "dock") then
      -- target direction into body frame (needs heading), then compare against
      -- BODY velocity from the sensors. No GPS velocity in this loop.
      ex, ez = tgtX - pos.x, tgtZ - pos.z
      local d = math.max(math.sqrt(ex * ex + ez * ez), 0.001)
      local ux, uz = ex / d, ez / d
      -- world-frame velocity error and integrator; heading enters only at
      -- the split into pitch and roll, and a wrong heading there merely
      -- rotates the lean, it cannot unwind the integrator
      local vCruise = math.min(CFG.CRUISE_SPEED, math.sqrt(2 * CFG.CRUISE_DECEL * d))
      local eWx, eWz = vCruise * ux - pos.vx, vCruise * uz - pos.vz
      local cWx, cWz = CFG.CKV * eWx + cruiseIx, CFG.CKV * eWz + cruiseIz
      if CFG.CRUISE_NO_BRAKE and speed > 1 then
        -- drop any component of the lean that points against the travel
        -- direction: overspeed is bled off by drag, not by leaning back
        local along = (cWx * pos.vx + cWz * pos.vz) / speed
        if along < 0 then
          cWx, cWz = cWx - along * pos.vx / speed, cWz - along * pos.vz / speed
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
      -- altitude by lean: above the goal (e < 0) lean more, below it lean less
      cap = clamp(cap - CFG.ALT_LEAN_GAIN * e, dashDeg)
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
      -- While landing the thrust vector has to stay pointed down: any tilt
      -- during a burn is lateral push. Full authority until settled (that is
      -- when the drift gets killed), then tight, tightest inside the flare.
      local tiltCap = CFG.TILT_MAX
      local ground = (phase == "descend") and dockAlt or (landGround or h0)
      if (phase == "land" and landSettled) or phase == "descend" or phase == "capture" then
        tiltCap = (h - ground < CFG.LAND_FLARE)
                  and CFG.LAND_TILT_BURN or CFG.LAND_TILT_MAX
      end
      tp = clamp(CFG.PITCH_DIR * CFG.PKV * fwd, tiltCap)
      tr = clamp(CFG.ROLL_DIR * CFG.PKV * right, tiltCap)
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
      local docking = (phase == "align" or phase == "descend" or phase == "capture")
      if CFG.YAW_SWEEP ~= 0 and dashStart then yawOff = (yawOff + CFG.YAW_SWEEP * (t - dashStart)) % 360 end
      if docking and CFG.DOCK_CARDINAL then
        -- square up to the nearest cardinal so the connector meets the pad
        -- already aligned; its lock window is 20 degrees and the magnet
        -- should only have to close the gap, not twist the craft
        src = "cardinal"
        yawTgt = (math.floor(hdgNow / 90 + 0.5) * 90) % 360
      elseif phase == "dash" and CFG.CRUISE_COORD and (mode == "go" or mode == "dock") then
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
          chime.play("spin")
          print(string.format("yaw: turned %.0f deg in 2 s - damping hard", turned))
        end
      end
    end

    local vx, vy = drive(pwr, KP * ep + ip + KD * dp, KP * er + ir + KD * dr, yawDem)

    local s0, s1, s2 = 0, 0, 0
    if haveVelSensors then s0, s1, s2 = rawFwd(), rawLat(), rawVrt() end
    log.writeLine(string.format("%.2f,%s,%.2f,%.2f,%.3f,%d,%.1f,%.1f,%.1f,%.1f,%.2f,%.2f,%.0f,%.0f,%.0f,%.1f,%.1f,%.1f,%.1f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.0f,%.0f,%d,%.0f,%.1f,%.2f,%.3f,%.3f,%.2f,%d,%d,%d",
      t - t0, phase, h, e, math.max(0, math.min(1, pwr)), fresh and 1 or 0, pos.x, pos.z, ex, ez, pos.vx, pos.vz, hdg, raw,
      motHdg or -1, tp, tr, a[1], a[2], vx, vy, s, s0, s1, s2, fwdSpeed(), latSpeed(), mon.energy, fuel.pct, mixSat and 1 or 0,
      yawErr, pos.wy, yawDem, mixThr, mixMax, v, dock.connected and 1 or 0, dock.npers,
      dock.charging and 1 or 0))
    if phase == "touchdown" then
      -- Thrust is already zero (see the power section). Keep flying the loop
      -- for a few more seconds purely to log: at the instant it fires, a
      -- false touchdown looks exactly like a real one, and only what happens
      -- next tells them apart. Normal rows, so height, tilt and vv are all
      -- there.
      touchAt = touchAt or t
      if t - touchAt > CFG.TOUCH_LOG_T then return end
    end
    if phase == "docked" then return end
    -- A cruise or hover leg ends where an ordinary flight would sit and hold:
    -- over the waypoint, at the height asked for, not moving. Dock and land
    -- legs end themselves (docked, touchdown) and are deliberately NOT tested
    -- here - a dock that gave up and fell back to holding must keep holding,
    -- not return and have the thrusters shut off underneath it.
    if legs and (legKind == "cruise" or legKind == "hover")
       and (phase == "hold" or phase == "fly") then
      local gs = math.sqrt(pos.vx * pos.vx + pos.vz * pos.vz)
      if fresh and math.abs(e) < CFG.LEG_ARRIVE_Y and gs < CFG.DROP_SETTLE_SPD
         and math.sqrt(ex * ex + ez * ez) < CFG.LEG_ARRIVE then
        legT = legT + dt
      else
        legT = 0
      end
      if legT >= CFG.DROP_HOLD then
        print(string.format("leg %d done at %.1f,%.1f Y %.1f", legIdx, pos.x, pos.z, h))
        return
      end
    end
    sleep(0.05)
  end
end

-- A mission is legs flown back to back. Each call to flyLeg starts with all
-- of its own state fresh, which is what makes a leg boundary a clean break.
local function controlLoop()
  if not legs then return flyLeg() end
  while nextLeg() do flyLeg() end
  chime.play("delivered", true)
  print("mission complete")
end

-- ---------- in-flight commands ----------
-- A request is a single word dropped here; the control loop picks it up at the
-- top of its next iteration, so nothing changes phase halfway through a
-- calculation. Unknown words are ignored.
local WORDS = { land = true, hold = true, undock = true }

local function cmdLoop()
  if not (CFG.CMD_KEYS or CFG.CMD_RADIO) then while true do sleep(3600) end end
  if CFG.CMD_RADIO and rednet and peripheral.getNames then
    for _, nm in ipairs(peripheral.getNames()) do
      if peripheral.getType(nm) == "modem" then pcall(rednet.open, nm) end
    end
  end
  local keymap = { l = "land", h = "hold", u = "undock" }
  while true do
    local ev, a, b = os.pullEvent()
    if ev == "char" and CFG.CMD_KEYS then
      local c = tostring(a):lower()
      if keymap[c] then
        cmdReq = keymap[c]
        print("command: " .. cmdReq)
      elseif c == "m" then chime.play("cruise")
      elseif c == "+" or c == "=" then print(string.format("volume %.1f", chime.volume(math.min(1, chime.volume() + 0.2))))
      elseif c == "-" then print(string.format("volume %.1f", chime.volume(math.max(0, chime.volume() - 0.2))))
      end
    elseif ev == "rednet_message" and CFG.CMD_RADIO then
      local word = type(b) == "table" and b.cmd or b
      if WORDS[word] then
        cmdReq = word
        print("command from " .. tostring(a) .. ": " .. word)
      end
    end
  end
end

if CFG.CMD_KEYS then print("in flight: L land, H hold, U undock, M music, +/- volume") end

local ok, err = pcall(parallel.waitForAny, controlLoop, posLoop, monLoop, chime.loop, cmdLoop)
allStop() pump(false) log.close()
print("thrusters off, pump off - flightlog saved")
-- Sounded here, not in the loop: the control loop returns the instant it docks,
-- so a queued chime would be cut off before it played.
if chime.playNow then
  pcall(function()
    if dock.connected then chime.playNow("docked")
    elseif not ok then chime.playNow("alarm")
    else chime.playNow("shutdown") end
  end)
end
if dock.connected then
  -- DOCK_SIDE is deliberately left high: dropping it is what undocks.
  print("docked to " .. dock.name .. " - " .. RS.describe(CFG.DOCK_SIDE) .. " held, 'fly undock' releases")
end

-- Push the log last, once the thruster is already off. Wrapped so a bad token,
-- a dead link or a disabled http API can never mask how the flight went.
if CFG.AUTO_UPLOAD and http and fs.exists("upload.lua") then
  if chime.playNow then pcall(chime.playNow, "upload") end
  local sent, why = pcall(function()
    if shell then return shell.run("upload") end
    return os.run({}, "upload.lua")
  end)
  if not sent then print("auto-upload failed: " .. tostring(why)) end
end
if not ok and not tostring(err):find("Terminated") then print(err) end
