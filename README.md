# Chill & Grill DroneNet

Flight controller for a **Create Aeronautics** drone, written for **ComputerCraft (CC:Tweaked, Lua 5.1)**. A single vector thruster does everything: lift, attitude and translation. The controller runs on an advanced computer bolted to the pod and writes a `flightlog` CSV every flight.

## Files

| File | Purpose |
|---|---|
| `fly.lua` | The controller. Four modes, see below. |
| `kill.lua` | Panic stop: thruster power to 0, nozzle vector zeroed, all redstone outputs off, any electric motor stopped. |
| `startup.lua` | Runs on boot. Pulls the latest `.lua` files from this repo's raw GitHub URLs, writes them to the computer's root and prints what changed. |
| `BACKLOG.md` | Wanted but not built, plus known issues and what each is blocked on. |
| `ARCHITECTURE.md` | The layer stack for the autonomous controller: control, leg, mission, link. Decided before the code. |
| `COMMAND.md` | The ground side: order intake, package assembly, fleet dispatch, and the rednet protocol between depot and drone. |
| `lib/db.lua` | Log-structured key/value store for the depot, built for CC's 1 MB disk. Tested by `tools/run_db_test.py`. |
| `lib/attitude.lua` | Full orientation quaternion from three orthogonal nav tables plus the gimbal, by TRIAD. Tolerates any one table being at its singularity. |
| `lib/mixer.lua` | Four-thruster allocation: lift, pitch, roll from differential thrust; horizontal force and yaw rate from nozzle vectoring. |
| `lib/chime.lua` | Speaker tones on flight events. Silent without a speaker, and queued so it can never stall the control loop. |
| `lib/mission.lua` | Mission planning: places, leg queues, energy budgets, point of no return, and calibration from a flightlog. |
| `FRAMES.md` | **Read this first.** The one agreed coordinate frame for world, body and attitude. Every value in the project is expressed in one of these. |
| `mixcal.lua` | Works out which thruster sits in which corner by pulsing each one and watching the airframe lean. **Fires thrusters** - ground only. `mixcal dry` rehearses it safely. |
| `preflight.lua` | Read-only ground check: full device inventory, sensor names and axes, position, energy, docking wiring, files. `preflight save` writes and pushes the result. Run it before flying. |
| `upload.lua` | Pushes the last `flightlog` straight to this repo over the GitHub API, so logs can be read without touching the save. |
| `probe.lua` | Read-only. Dumps what CC: Sable reports on the drone and cross-checks it against GPS and the gimbal sensor. Never touches the thruster. |
| `logs/flightlog_summary.py` | Post-flight analysis of a `flightlog` CSV: per-phase summary and sampled rows. |

## Hardware

All peripherals are found by type except the velocity sensors, which are addressed **by name** because `peripheral.find` ordering is not stable between sessions.

| Peripheral | Count | Used for |
|---|---|---|
| `vector_thruster` | 1 or 4 | The only actuator. `setVector(vx, vy)` tilts the nozzle, `setPowerNormalized(p)` sets thrust 0..1. One thruster is driven directly; more than one engages `lib/mixer.lua` (see Four thrusters). |
| `gimbal_sensor` | 1 | `getAngles()` gives **pitch and roll only**. No yaw, which is why heading is derived from motion. |
| `altitude_sensor` | 1 | `getHeight()` for the altitude loop. |
| `navigation_table` | 1 | `getRelativeAngle()` bearing to its target. Measured in the pod's own tilted plane, so it is de-rotated by pitch/roll before use. Currently reads about 180 deg out and is only a fallback (`NAV_FALLBACK = false`). |
| `modular_accumulator` | 0..4 | Main battery. `getPercent()` of every accumulator, averaged, polled once per `MON_POLL` in the monitoring coroutine, logged as `energy`. `LOW ENERGY` warning with a minutes-to-empty estimate below `ENERGY_WARN`. |
| thruster buffer | 0..1 | The thruster's own FE buffer (or a liquid tank if `FUEL_MODE = "fluid"`), logged as `fuel` %. See Monitoring. |
| `docking_connector` | 0..1 | Optional. Extended by a redstone side (`DOCK_SIDE`), which is also what arms its magnet. `getConnectedName()` is the only dock-state signal and is polled in the monitoring coroutine. See Docking. |
| pump drive | 0..1 | Optional. A redstone side (`PUMP_SIDE`, e.g. a clutch on the pump shaft) and/or a CC&A electric motor (`PUMP_MOTOR`) that `fly` switches on before takeoff and off on exit. |
| `velocity_sensor` | 3 | Body-frame velocity, one per axis. `velocity_sensor_0` forward, `velocity_sensor_1` lateral, `velocity_sensor_3` vertical. Identified in freefall: the vertical one read -24 b/s while the others read ~0. |

The sensors (`gimbal_sensor`, `altitude_sensor`, `velocity_sensor`, `navigation_table`) come from **Create: Avionics**; the thruster comes from **Gadgets & Gizmos**, whose thrusters accept either FE or liquid fuel through a thruster gimbal or bearing. Method names used here were checked against the Avionics docs in September 2026 and are current.

**Altitude.** `HOVER + integ + AKD·(vWant − v)` with `vWant = (AKP/AKD)·e` capped at `CLIMB_RATE`: a rate cascade. Vertical speed comes from Sable's linear velocity, not differenced altitude (which skipped ticks and slammed the throttle on/off). The rate request ramps at `VRATE_SLEW` b/s² (a step to full rate rang 13→8→11 b/s for ten seconds) and the integrator acts on the rate error with anti-windup (frozen while the throttle is pinned at 0 or 1), so it trims a wrong `HOVER` at any point of a flight - the harness deliberately hovers at 0.5 against a configured 0.27 to prove it - without winding up during a full-throttle climb. The rate request is distance-aware: `min(CLIMB_RATE, √(2·DECEL·|e|), 0.5·|e|)`, so a long climb runs at whatever the throttle gives (50 b/s in 5 s on 0.55 power) and starts slowing exactly where `DECEL` says it must. Gravity in this world is ~10 b/s² (measured from the coast-down at zero throttle), so a climb arrests at ~8 b/s² without thrust.

`fly spin <y> [deg]` is the pure-yaw exercise: hover at Y, settle, yaw clockwise by `deg` (default 90) about the thrust axis at `YAW_SLEW`, hold 3 s, yaw back, hold. It prints each step with the time it took, and the flightlog's `yerr,yrate,ydem` columns show the loop's behaviour with no translation mixed in. First run (2026-09-10): sign confirmed, 0.08 of demand gave 6.5°/s, so about 80°/s per unit of demand; the mixer scales lift by 1/cos of the tangential deflection so a fast spin does not sink.

**Yaw.** The airframe has no yaw sensor beyond the nav tables and no dedicated yaw actuator, but four corner thrusters vectored tangentially spin it about the thrust axis. The 1290-block flight of 2026-09-10 yawed 260° with nothing holding it, which matters because the sails are symmetric about a body plane and want the same angle to the airflow every flight. `YAW_HOLD` holds course + `YAW_OFFSET` in cruise. Sign confirmed on the first yaw flight (2026-09-10): the heading moved toward the target both times it was asked, at up to 45°/s - too hard, hence the slew limit and lower gains. That flight also showed the lean ceiling is real: at 72° cap and a 35 b/s target the attitude loop overshot to 92°, power saturated and it tumbled, so cruise is now 60° / 28 b/s.

The velocity sensors tilt with the airframe. With the vertical axis measured, the body vector is rotated back to level, so "forward speed" stays horizontal-forward even at 70 deg of lean.

### Four thrusters

With more than one `vector_thruster` fitted, `fly` loads `lib/mixer.lua` and refuses to start unless every fitted thruster is in the corner map. The map comes from `mixmap.csv` on the computer (written by `mixcal`) or, failing that, `CFG.MIX_MAP`, which holds the map both mixcal runs agreed on. The attitude PID is untouched; `MIX_MODE` decides where its output goes:

| Mode | Attitude from | Nozzles | Calls/iter |
|---|---|---|---|
| `diff` | differential thrust across the corners | straight, set once | 1 tick |
| `vector` | all four nozzles vectored together, exactly like the single thruster | move every iteration | 1 tick |
| `both` (default) | differential and vectored, same signs | move every iteration | 1 tick |

Each thruster call is a main-thread task (one game tick); written one after another, four thrusters cost four ticks and the loop measured 0.25 s per iteration. The mixer therefore issues every write from its own coroutine under `parallel.waitForAll`, so CC runs them in the same tick, and skips writes whose value has not changed by more than 1e-3. `HDG_EVERY` thins the nav-table read to every Nth iteration for the same reason; `preflight` prints the measured cost of every call the loop makes.

`fly go 100 100 100` flew 130 blocks, braked and held within 4 (2026-09-10) but cruised at only 3.6 b/s: the speed loop was P-only. It now has an integrator (`CKI`) and a 20 b/s target, and the hover feed-forward is scaled by 1/cos(tilt) in dash/brake so the altitude loop is not left to discover the extra thrust a lean needs. Lean is speed-scheduled: `LEAN_AT_0` (50°) from standstill rising to `CRUISE_DEG` (75°) at `LEAN_FULL_SPD` (60 b/s), because the sails carry the craft once it is moving - 45 b/s took 0.28 power - while the ballistic limit of ~74° only applies at rest. The cap is pulled back once the craft is more than `ALT_PROTECT` below its goal. **The lean cliff was the gimbal's projected angles.** Its roll is `atan2(−gx, −gy)`; at 65° of pitch `gy` is 0.42, so the same physical roll reads 2.4× (3.9× at 75°, 5.8× at 80°), multiplying the roll loop's gain with lean - every departure began as a second-axis runaway past ~65°. The attitude error is now the rotation between the measured and target down-vectors in the body frame (`lib/attitude.lua`), with body rates from that vector's motion: identical at level, correct at any lean.

With that fix and the proven dash gains the next flight ran **119 b/s at the 70° cap** (actual lean 74–79°, a steady aero bias), vectors under 0.25, altitude ±3, and arrived ([log](logs/flights/2026-09-10-quad-go-provengains-gravvec.csv)). The flight after that reached **136 b/s**, then ping-ponged dash/brake four times on a 125-block re-cruise because a short leg got the same lean-to-the-cap treatment as a long one; the cruise speed target is now distance-aware, `min(CRUISE_SPEED, √(2·CRUISE_DECEL·d))`, so lean eases off approaching the target and the brake is a formality. The paragraph below is kept as history.

There was an **airspeed cliff** around 85–90 b/s: the sails' pitching moment grows with v² and above that it out-muscles the thruster vectoring (65° tracked within 2° at 81 b/s; 70° ran 10° past command at 100 b/s, the altitude feed-forward then saturated power, and it departed). The departure log shows the vector command at 0.04–0.15 while the error grew to 17° - the loop was too soft, not out of authority - so the `*_DASH` gains are now sized for 10° of error to ask for half the vector. Vectoring torque is thrust × deflection, so `ATT_MIN_POWER` keeps 0.25 of throttle whenever the lean exceeds 15° - every departure log had the altitude loop at 0.00 power just before the trouble, i.e. no attitude authority at 60–70° of lean. Cruise is also flown aircraft-style: throttle floored at `CRUISE_MIN_POWER` (vectoring torque scales with thrust, and the altitude loop used to throttle back to 0.3 because the sails carry the craft), altitude trimmed by the lean cap (`ALT_LEAN_GAIN`), `CRUISE_SPEED` unlimited again.

First quad flights (2026-09-10, all at 0.25 s/iteration): `diff` - signs and authority fine, pitch rang at a steady ±10° / 2.5 s, then at 1 Hz once KD went up. `vector` with the same gains - divergent at 2.5 s, saturated the nozzles and tumbled at 14 s: stronger torque, same delay. The delay was the thruster writes, hence the batching above. With batching the loop measured 0.100 s/iteration and the same gains held ±1.7° over a 24 s climb in `both` mode ([log](logs/flights/2026-09-10-quad-find03-both-batched.csv)). Measured call costs on airframe 1: Avionics sensors 0 ms, every thruster setter 50 ms, every Sable call 50 ms ([preflight](data/preflight-airframe1-callcosts.txt)).

`MIX_GAIN` scales the PID output into differential demand (the mixer then caps it at `PITCH_AUTH`/`ROLL_AUTH` = 25 % of range), and `MIX_P_SIGN`/`MIX_R_SIGN` flip an axis if it diverges. The flightlog's `vx,vy` columns carry the differential pitch/roll demand in `diff` mode and the nozzle vector otherwise; `sat` is 1 when the mixer ran out of range and traded lift for attitude. The thruster FE buffer is summed across all four; `kill` stops all of them.

**In-flight commands.** Landing is a *command*, not just a mode: quitting the program to run `fly land` means no thrust while you type, which is a fall rather than a landing. A command coroutine reads events - no peripheral calls, so it cannot stall the control loop - and drops a single word for the control loop to pick up at the top of its next iteration:

| Key | Word | Effect |
|---|---|---|
| `L` | `land` | descend and touch down, wherever you are |
| `H` | `hold` | stop here, cancel the target |
| `U` | `undock` | release the connector |
| `M` | - | two bars of the cruise groove |
| `+` `-` | - | chime volume |

The same words arrive over rednet on `CMD_PROTO`, as a bare string or `{cmd="land"}`, so a ground station can fly the thing later. Harness cases `land from cruise` and `hold from cruise` inject a keypress mid-flight (`CMD_AT="20:l"`) and check the phase actually changes.

**Landing.** `fly land` descends where it is. `fly land <x> <y> <z> [cruiseY]` flies there first and lands on arrival - internally that *is* a `go`, reusing the cruise, brake and re-cruise machinery unchanged, with only the phase it finishes in changed. The middle argument is the **ground altitude at the destination**, straight off F3, which is exactly what the descent profile needs to know when to start braking. It descends as fast as the height remaining can arrest - `min(LAND_MAX_RATE, sqrt(2 * LAND_DECEL * drop))`, the same kinematics the horizontal approach uses - then flares to `LAND_CREEP` for the last `LAND_FLARE` blocks so the touchdown is soft and the detector has time to fire. `LAND_DECEL` is 15 b/s^2 against roughly 40 available at TWR 5.2, so most of the braking is margin.

The profile needs to know where the ground is, and the altitude sensor is not zeroed to it. The default reference is **the altitude the program started at**, which is exactly right when landing where you took off and wrong by the terrain difference anywhere else; a generous flare absorbs small errors, and the third argument sets a known pad. Too high an estimate means a long slow creep, too low means a late flare.

**Touchdown is measured on the altimeter, not on velocity.** The first version tested Sable's vertical speed for "not descending", and on 2026-09-11 it called touchdown while the craft was still in the air on an angle - a single zero from a stale pose read looks exactly like arriving on the ground. It now asks whether the *altitude* has moved: less than `TOUCH_DROP` over a 1.2 s window, while the profile is still commanding a descent and the throttle is below hover, sustained for `TOUCH_T`. At the 2 b/s creep a real descent moves 2.4 blocks in that window, so the margin is wide.

The loop also keeps running for `TOUCH_LOG_T` (3 s) after touchdown with thrust already off, logging normal rows. At the instant it fires a false touchdown is indistinguishable from a real one; only the next three seconds tell them apart. The flightlog's new `vv` column is the vertical speed the altitude loop is actually using - its absence is why a stale zero could masquerade as a landing without showing up anywhere.

One interaction worth knowing: the `ATT_MIN_POWER` floor that keeps vectoring authority while leaning is 0.25, and measured hover is 0.245 - so above `ATT_MIN_TILT` that floor *is* hover and the craft could never descend while still leaning off a cruise. Landing uses the lower `ATT_MIN_LAND` instead. It does not aim at a height, because the altitude sensor is not zeroed to the ground: touchdown is inferred from three things at once - we commanded a descent, we are not descending, and the throttle has fallen below what hovering costs, so something other than the thrusters is holding the craft up. All three must hold for `TOUCH_T` (0.6 s), or a single sensor glitch at 200 m would cut the thrust. After `LAND_MAX_T` with no touchdown it gives up into a hover rather than descending forever. No pad and no recharge - a landing site is a park or an abort, not a base.

**Chimes.** `lib/chime.lua` is a small note-block sequencer in its own coroutine - `play` queues a name and returns instantly, so nothing here can stall the control loop, and with no speaker every call is a silent no-op. There is a grammar rather than a pile of beeps: rising means something began and is going well, falling means it finished, repeated means attend, dissonant means broken, and a four-note signature (0 7 5 12) opens `boot`, closes `delivered` and runs backwards for `home`, so the same phrase brackets a whole delivery.

Any phase name with a matching set chimes automatically, because `enter()` plays the phase name - so `land`, `touchdown` and `drop` are already written and will sound the moment those phases exist. Faults have distinct voices instead of one generic alarm: `lost` (a tritone - a corner stopped answering), `spin`, `lowpower`, `lowfuel`, `warn`. `chime.play(name, true)` jumps the queue for anything that should not wait behind three phase chimes. `chime.volume(0..1)` scales everything, `chime.melody{...}` plays an ad-hoc sequence, and `cruise` is an opt-in two-bar groove you can queue during a long dash.

Audition them on the pad with `chimes` (all of them, named as they play), `chimes docked` (one), `chimes cruise 4` (four times) or `chimes list`. Tests: `python tools/run_chime_test.py` - 25 cases, including that every set terminates, no chord exceeds the speaker's 8 notes per tick, and a speaker that throws cannot kill the loop.

**Redstone that is not on this computer.** The 3x3 airframe has no free face next to the docking connector - the outer ring is accumulators and network cable, the centre column above it is the CC&A power connector, and the connector's API has no extend method (`getConnectedName` only, confirmed twice by `preflight`). So `DOCK_SIDE`, `PUMP_SIDE` and the coming payload side accept either a plain side string (a face of the flight computer) or a remote target:

| Target | Meaning |
|---|---|
| `"back"` | a side of the flight computer, free, instant |
| `{ relay = "redstone_relay_0", side = "back" }` | a CC:Tweaked Redstone Relay on the wired network (needs CC >= 1.109 - check with `print(_HOST)` on the pod) |
| `{ slave = "drone-rs", side = "back" }` | a small computer running `rsio.lua`, reached by rednet over the craft's own cable |

The slave path is fire-and-forget: waiting for an acknowledgement would stall whichever coroutine asked, and `dockExtend()` is called from the control loop. `rsio.lua` instead broadcasts its whole output state once a second, `monLoop` picks that up with `rs.poll()`, and `rs.check()` warns if the slave goes quiet or is holding something other than what was asked - so a dead slave shows up during the cruise rather than on final approach. `kill.lua` clears remote sides too, and never the docking one. Wired modems are preferred over wireless when opening rednet, so one drone cannot drive another's connector. Tests: `python tools/run_rs_test.py`.

**Lift is preserved; the differential is what gives way.** When the four thrusts will not fit in 0..1, the mixer scales the *differential* down around the lift demand rather than shifting the whole set. The old rule did the opposite - shift to make the differential fit, let lift suffer - and that silently pinned mean thrust near 0.50 whenever both axes saturated. Measured in flight on 2026-09-11: a commanded 1.00 and a commanded 0.00 both came out at 0.500, so the altitude loop was disconnected from the hardware exactly when it mattered. A departure became a climb from 210 m to 1457 m that `land` could not stop, and a landing creep asking for 0.02 got 0.30 and hung above the ground.

The cost is attitude authority when lift is low - and lift is only low when descending. In cruise the 1/cos(tilt) feed-forward already puts lift at 0.5-0.6, where nearly all of the differential still fits. `LIFT_SLACK` (default 0) allows a bounded rise of the mean if an airframe ever needs the authority back.

**`pwr` is a demand, `athr` is the truth.** The flightlog's `pwr` is what the altitude loop asked for; `athr` and `amax` are the mean and worst thrust the four thrusters were actually given. They agree until the mixer saturates (`sat` 1), and then they don't: attitude-priority rescales the whole set to make the differential fit, which moves the mean. With pitch and roll both demanding full authority the mean pins near 0.50 *whatever lift is asked for* - 0.00 included. A flight on 2026-09-11 departed at 78 b/s and then climbed from 210 m to 1457 m with `pwr` logged at 0.00-0.25, and pressing `L` to land did nothing, because `land` commanded zero thrust and the hardware got half. Diagnose from `athr`.

**Losing a thruster.** Every mixer write is `pcall`ed, so a thruster that drops off the wired network fails silently and a quad flips on the remaining three. `monLoop` checks `peripheral.isPresent` for each mapped thruster once per `MON_POLL` and, as a free backstop, `mixer.faults()` reports any thruster whose last three writes failed. Either one sounds the alarm chime and prints `THRUSTER LOST`. Worth knowing before you re-route network cable on the airframe.

**First flight in diff mode:** `fly find 0.5` on the pad with `TUMBLE` low. If it rolls or pitches away instead of levelling, flip the matching `MIX_*_SIGN`. If it holds level but wallows, raise `MIX_GAIN`; if it twitches, lower it. Nothing about the tuning constants has been changed, so the hover gains are the single-thruster ones and will need a pass.

### Position

**The drone flies on CC:Sable's `getLogicalPose().position`, not GPS.** Measured
against ground truth on 2026-09-10: the pose was accurate to 2.7 blocks (and
that 2.7 is just the computer block sitting below the player), while the GPS
array was out by 45 blocks. `CFG.POS_SOURCE` is `"auto"`, which prefers the
pose and falls back to GPS off a sub-level; `"gps"` forces the old path.

Velocity comes from `getLinearVelocity()` too, straight from the physics
engine, so it carries none of the noise that differencing GPS produced.

Both run in their own coroutine, so the control loop's per-iteration call
budget is unchanged.

### GPS hosts

GPS is no longer used by the drone, but customers on the ground still need it:
`sublevel` only answers on a sub-level, so a pocket computer has no other way
to locate itself. Four computers with ender modems running `gps host` are set up at the volcano and must stay **chunk-loaded**. They must also not be collinear or coplanar: CC distances are exact so the hosts need not be far apart, but four at one height cannot solve the vertical and will return a plausible-looking, wrong `y`. Offset one host in Y. CC: Sable can replace GPS *for the drone*, but not for customers: the `sublevel` API only answers on a sub-level, so a pocket computer on the ground still needs GPS to locate itself. Keep the array up. See [COMMAND.md](COMMAND.md). If the fix is lost, the position loop rejects updates after 5 bad samples and position hold stops leaning until the fix returns. Position hold is also disabled above `SPEED_GUARD` ground speed so a stale fix cannot command a big lean.

### Monitoring

All slow reads live in one coroutine that wakes every `MON_POLL` seconds, so the control loop itself makes no accumulator or fuel calls. Monitoring never changes the flight on its own; it prints and logs.

**Accumulator.** `getPercent()` once per poll, logged as `energy`. A filtered drain rate in %/min is kept between polls. Below `ENERGY_WARN` it prints `LOW ENERGY 24% (~3.1 min to empty)` once and re-arms if the level climbs back 5 points.

**Thruster side.** Probed once at startup, in the order set by `FUEL_MODE`:

- `"fe"` (default, FE thrust): the thruster's own buffer via CC:Tweaked's generic `getEnergy` / `getEnergyCapacity`, then the fluid methods as a fallback.
- `"fluid"`: `getFuelAmount` / `getFuelCapacity`, then generic `tanks()` with `FUEL_CAP` in mB for a percentage, then FE.

Whatever it finds is logged as `fuel` % and warned as `LOW THRUSTER` or `LOW FUEL` below `FUEL_WARN`. If nothing matches it prints the peripheral's full method list so you can see what the current mod version exposes, and flies with `fuel` logged as -1. Gadgets & Gizmos ships its own peripheral docs in-game: run `/rom/thrusters/docs.lua` on any computer.

### Pump auto-start

A Create mechanical pump only needs rotation, so "starting" it means gating the shaft. Two hooks, both optional and both released when `fly` exits or `kill` runs:

- `PUMP_SIDE`: a redstone side the computer holds high, for a clutch or gearshift on the pump shaft.
- `PUMP_MOTOR` + `PUMP_RPM`: a Create Crafts & Additions electric motor spun by name, fed from the onboard accumulator.
- `PUMP_PRIME`: seconds to wait after the pump starts before the flight begins, if the thruster needs its tank filled first.

If the thruster is fed through a Gadgets & Gizmos thruster gimbal or vector bearing, fuel is distributed for you and no pump may be needed at all.

### Refuelling / recharging on a dock

Aeronautics 1.3.0 (June 2026) added native FE transfer through Docking Connectors, so an FE-mode thruster can recharge from a dock without extra mods. For liquid fuel the Docking Connector moves fluids natively but only through Create pipes.

## Modes

```
fly find <power>            hold a fixed throttle to find the hover point
fly <y> [x] [z]             hold altitude y; hold position, or fly to x z if given
fly dash <y> <deg> <secs>   climb to y, pitch <deg> for <secs>, brake, then hold
fly go <x> <z> [y]          climb to y (default +25), cruise to x z, brake, hold there
fly dock <x> <z> <padY> [y]  cruise to the pad, settle over it, descend and dock
fly undock [y]              release the connector once thrust is up, then hold y
```

Ctrl+T stops the program. On any exit, including a tumble error, the thruster is cut and `flightlog` is closed.

Phases as they appear in the log:

- **find / fly**: single phase, altitude PID plus position hold.
- **climb**: fixed `CLIMB_POWER` eased by climb rate, no lean. Transitions `DASH_SETTLE` blocks below the goal while still climbing.
- **dash**: `dash` mode holds a fixed pitch. `go` mode steers toward the target with a velocity controller in the world frame, lean capped at `CRUISE_DEG`.
- **cruise rework (2026-09-10)**: `go`/`dock` start leaning at `DASH_ENTRY_FRAC` of the climb and let the altitude cascade finish underneath; the lean target slews at `CRUISE_TILT_RATE`; with `CRUISE_NO_BRAKE` the speed loop never leans against the travel direction (overspeed bleeds off by drag). Smooth and committed beats exact.
- **result of the sweeps (2026-09-10)**: two full circles at 45° lean / 35 b/s gave speed-per-degree-of-lean of 0.70–0.80 in every 30° bin with yaw quiet throughout ([sweep 2](logs/flights/2026-09-10-quad-go-yawsweep2.csv), [sweep 3](logs/flights/2026-09-10-quad-go-yawsweep3-from180.csv)). Orientation about the thrust axis does not change drag at that regime, so `YAW_CRUISE = "hold"` keeps the entry heading and `CRUISE_COORD` stays off. The high-speed instabilities were the sails' pitching moment and undamped yaw at 60°+ lean, not compound fin angles.
- **yaw sweep** (`YAW_SWEEP` deg/s): rotates the yaw offset through 360° during cruise so `tools/yaw_sweep.py` can bin speed, lean and yaw disturbance against relative yaw. The fins are drag-only panels along the length, so the least-drag bin is where the crossflow runs edge-on to them - that fixes `YAW_OFFSET` / `CRUISE_LEAN_AXIS` from data rather than from the photo.
- **coordinated cruise** (`CRUISE_COORD`, off until the sweep fixes the axis): lean only along the body direction `CRUISE_LEAN_AXIS` degrees clockwise from the nose (0 pitch, 90 roll, 45 diagonal - the fins are on the corners), yaw hold turns that axis onto the target, steering by yaw - so the symmetric sails see one angle of attack instead of a compound one. Lean fades in with cos(yaw error).
- **brake**: leans against the world velocity vector on both axes (the craft cruises largely sideways, so a forward-only brake left the lateral speed alone) and finishes on total ground speed below `BRAKE_DONE`.
- **brake**: pitches the other way against forward speed until it drops below `BRAKE_DONE` or `BRAKE_MAX_T` runs out.
- **hold**: altitude plus position hold at the current spot (`dash`) or the target (`go`).
- **align**: `dock` only. Position hold over the pad, waiting for the drone to be within `DOCK_ALIGN` blocks and under `DOCK_ALIGN_SPD` for `DOCK_SETTLE_T` seconds. Speed comes from the velocity sensors rather than differenced GPS, and up to `DOCK_ALIGN_GRACE` bad samples are tolerated before the timer resets. **If a dock hangs in align, this gate is why**: raise `DOCK_ALIGN_SPD` first, then `DOCK_ALIGN_GRACE`.
- **descend**: `dock` only. Extends the connector, then walks the altitude goal down at `DOCK_RATE` until the park altitude is reached. Drifting more than `DOCK_ABORT_DIST` from the pad sends it back to align.
- **capture**: `dock` only. Holds at the park altitude and waits for the magnet to pull the connectors together, up to `DOCK_CAPTURE_T` seconds.
- **docked**: thrust to zero and the program exits, leaving `DOCK_SIDE` high.

## Docking

The Docking Connector is a magnet, and that changes what the flight controller has to do. Numbers below are read from the Aeronautics source, and the two tolerances are server config keys you can raise.

| What | Default | Server config key | Range |
|---|---|---|---|
| Distance tolerance | 0.5 blocks | `docking_connector_distance` | 0 to 4 |
| Angle tolerance | 20 degrees | `docking_connector_angle` | 0 to 365 |
| Pull force | 1000 | `dockingConnectorStrength` | any |

Both tolerances are compared as 3D vector magnitudes, so 0.5 blocks is total offset rather than per axis, and it is measured tip to tip between the extended connectors rather than block to block. The connectors only become magnetic once extended, and the search picks up a partner from roughly 16 to 32 blocks away, after which the magnet pulls and rotates the ship into alignment on its own. **`dock` mode therefore only has to park the drone inside magnetic reach.** It does not try to fly to the lock window.

**Build.** Point the drone's connector down and the pad's connector up, and keep the pad's connector permanently powered. Two connectors facing each other meet at 3 blocks of block-to-block separation, which is where `DOCK_GAP` comes from. Because the altitude sensor is not the connector block, treat `DOCK_GAP` as the value that makes the drone park about 3 blocks above the pad and calibrate it on the first attempt.

**Sequence.** `fly dock <x> <z> <padY>` cruises to the pad using the same climb, dash and brake phases as `go`, settles over it, extends the connector, walks the altitude down, then waits for the magnet. On success it prints the pad name, cuts thrust and exits with `DOCK_SIDE` still high. A capture that times out climbs back and retries up to `DOCK_TRIES` times, then retracts and holds.

**Undocking is a redstone release.** Dropping `DOCK_SIDE` is what the mod treats as an undock command. `fly undock` waits `DOCK_RELEASE_T` seconds so thrust is already supporting the drone before the connector lets go, then holds altitude normally.

**`kill.lua` has a `DOCK_SIDE` of its own.** A panic stop clears every redstone output, which would release the drone from the pad. Set `DOCK_SIDE` at the top of `kill.lua` to the same side as in `fly.lua` and that one side is left alone.

Dock state is polled once per `MON_POLL`, so lowering it to 0.5 makes capture detection more responsive.

## CFG block

Everything tunable lives at the top of `fly.lua`. Edit the file and redeploy; the README does not drive anything.

**Altitude**

| Key | What it does |
|---|---|
| `HOVER` | Throttle that roughly holds altitude. Base for the altitude PID output. |
| `AKP`, `AKI`, `AKD` | Altitude PID gains on height error / integral / vertical speed. |
| `PMAX` | Clamp on the altitude P term so a big error cannot saturate the throttle. |
| `CLIMB_POWER`, `CLIMB_RATE` | Throttle during climb, and the b/s climb rate it eases toward. |
| `DASH_SETTLE` | Blocks below the goal at which climb hands over to dash. |
| `DASH_POWER` | Extra throttle added during dash and brake to make up for tilted thrust. |

**Attitude (inner loop)**

| Key | What it does |
|---|---|
| `KP_HOVER`, `KI_HOVER`, `KD_HOVER` | Attitude PID gains when near level. |
| `KP_DASH`, `KI_DASH`, `KD_DASH` | Attitude PID gains at high lean. |
| `SCHED_LO`, `SCHED_HI` | Tilt in degrees over which gains blend from hover to dash values. |
| `IMAX` | Attitude integrator clamp. |
| `VEC_MAX` | Nozzle vector clamp. 1.0 is full authority. |
| `P_AXIS`, `P_SIGN`, `R_SIGN` | Which thruster axis is pitch, and the sign of each axis. Airframe wiring. |
| `MIX_MODE`, `MIX_GAIN`, `MIX_P_SIGN`, `MIX_R_SIGN`, `MIX_MAP` | Four-thruster mixer: diff / vector / both, PID-to-differential gain, per-axis sign, built-in corner map. See Four thrusters. |
| `TILT_RATE` | Max deg/s the tilt *targets* may move, so phase changes ramp instead of step. |
| `TUMBLE` | Abort and cut thrust if pitch or roll exceeds this many degrees. 0 disables. |

**Monitoring and pump**

| Key | What it does |
|---|---|
| `MON_POLL` | Seconds between monitoring reads. One peripheral call per source per poll. |
| `ENERGY_WARN` | Accumulator percent below which `LOW ENERGY` is printed. |
| `FUEL_MODE` | `"fe"` reads the thruster's FE buffer first, `"fluid"` reads a liquid tank first. |
| `FUEL_NAME` | Thruster-side peripheral to read. `nil` reads the thruster itself. |
| `FUEL_CAP` | Tank capacity in mB, needed only when a fluid source reports amount but not capacity. |
| `FUEL_WARN` | Thruster-side percent below which `LOW THRUSTER` / `LOW FUEL` is printed. |
| `PUMP_SIDE` | Redstone side held high while flying. `nil` disables. |
| `PUMP_MOTOR`, `PUMP_RPM` | CC&A electric motor name and speed for the pump. `nil` disables. |
| `PUMP_PRIME` | Seconds to wait after the pump starts before flying. |

**Docking**

| Key | What it does |
|---|---|
| `DOCK_SIDE` | Redstone side that extends the connector. `nil` disables docking entirely. |
| `DOCK_NAME` | `docking_connector` peripheral name. `nil` uses `peripheral.find`. |
| `DOCK_ALIGN`, `DOCK_ALIGN_SPD` | Horizontal error in blocks and ground speed in b/s to be inside before descending. |
| `DOCK_SETTLE_T` | Seconds of holding both of those before the descent starts. |
| `DOCK_ALIGN_GRACE` | Failing samples tolerated before the settle timer resets. Raise if align hangs. |
| `DOCK_GAP` | Blocks above `padY` to park at. 3 is the connectors' own spacing. |
| `DOCK_BAND` | How close to the park altitude counts as arrived. |
| `DOCK_RATE` | b/s that the altitude goal walks down during the descent. |
| `DOCK_SINK` | Power bled off during capture so the magnet can pull down. 0 means pure altitude hold. |
| `DOCK_CAPTURE_T` | Seconds to wait for the magnet before aborting an attempt. |
| `DOCK_ABORT_DIST` | Blocks of drift that sends the descent back to align. |
| `DOCK_TRIES` | Capture attempts before giving up and just holding. |
| `DOCK_RELEASE_T` | Seconds of thrust before `undock` drops the connector. |
| `CHIME` | Speaker tones on phase changes. Silent if no speaker is attached. |

**Position hold (outer loop)**

| Key | What it does |
|---|---|
| `PKP`, `VMAX` | Position error to desired velocity gain, and clamp on that velocity. |
| `PKV` | Velocity error to tilt gain. |
| `PKI`, `TRIM_MAX` | Slow integrator on velocity error that becomes a standing trim tilt, and its clamp. |
| `TILT_MAX` | Max lean commanded by position hold. |
| `SPEED_GUARD` | Ground speed above which position hold stops commanding lean. |
| `PITCH_DIR`, `ROLL_DIR` | Sign of tilt per body axis. Airframe wiring. |

**Heading**

| Key | What it does |
|---|---|
| `HDG_SIGN`, `HDG_OFFSET` | Sign and offset applied to the nav table angle. |
| `HDG_ALPHA` | Low-pass factor on the nav table heading. |
| `HDG_WIN` | Seconds of GPS displacement per motion-heading estimate. |
| `HDG_MIN_MOVE` | Blocks moved in the window before an estimate is trusted. |
| `HDG_RATE` | How fast the latched motion heading follows a new estimate. |
| `NAV_FALLBACK` | Use the nav table heading before motion heading locks. Currently false. |

**Velocity sensors**

| Key | What it does |
|---|---|
| `FWD_NAME`, `LAT_NAME`, `VRT_NAME` | Peripheral names for forward, lateral and vertical sensors. |
| `FWD_SIGN2`, `LAT_SIGN`, `VRT_SIGN` | Sign so positive means forward, right and up. |

**Dash and brake**

| Key | What it does |
|---|---|
| `DASH_DIR` | Sign of the dash pitch. |
| `BRAKE_DEG` | Pitch-back angle against the motion. |
| `BRAKE_EASE` | b/s over which brake tilt ramps from 0 to full, so it does not slam. |
| `BRAKE_DONE` | Forward speed below which brake ends. |
| `BRAKE_MAX_T` | Give up braking after this many seconds. |

**Go mode**

| Key | What it does |
|---|---|
| `CRUISE_DEG` | Max lean during cruise. |
| `CRUISE_SPEED` | Target closing speed in b/s. |
| `CKV`, `CKI` | Degrees of lean per b/s of velocity error, and deg/s per b/s for the integrator that removes the drag steady-state error. Both act on the world-frame velocity error. |
| `YAW_HOLD`, `YAW_SIGN`, `YAW_OFFSET`, `YAW_KP`, `YAW_KD`, `YAW_MAX`, `YAW_SLEW`, `YAW_TILT_MAX`, `YAW_MIN_SPEED`, `YAW_ABORT_DEG` | Yaw hold via tangential nozzle vectoring (four thrusters only). Cruise target = course + `YAW_OFFSET`; otherwise the heading at phase entry. The held target slews at `YAW_SLEW` deg/s toward the wanted one. Yaw damping runs at every lean: gating it off above 55° let the sails spin the craft to 60°/s at 83 b/s (2026-09-10), and a spin at high lean also rotates the tilt between the pitch and roll axes, so the whole attitude loop thrashes until the spin is damped. Yaw rate from Sable's angular velocity, read in `posLoop`. A spin guard switches yaw hold off for the flight if the heading turns more than `YAW_ABORT_DEG` in 2 s. Logged as `yerr,yrate,ydem`. |
| `HDG_CRUISE_ALPHA` | Complementary filter for the cruise heading: Sable's yaw rate is integrated every iteration and the result is blended toward the nav heading at this rate per iteration. The flat nav table's reading swings ±40° at 50° of tilt, so cruise trusts the gyro short-term and the compass long-term. |
| `BRAKE_K` | Brake distance = `BRAKE_K * speed^2 / 10`. |
| `ARRIVE` | Blocks from target at which cruise hands over to brake regardless of speed. |

## Deploying to the drone

1. Enable `http` in the CC:Tweaked server config and make sure `raw.githubusercontent.com` is allowed.
2. **If the repo is private**, `raw.githubusercontent.com` returns 404 without auth. Either make the repo public, or create a fine-grained personal access token with read-only *Contents* permission on this repo only and save it on the drone's computer as `.ghtoken` (just the token, nothing else). `startup.lua` sends it as an Authorization header. The token stays on the CC computer; never commit it.
3. On the drone's computer, once (public repo shown; for a private one, paste `startup.lua` in with `edit startup.lua` the first time):
   ```
   wget https://raw.githubusercontent.com/antrathent-sys/Chill-Grill-DroneNet/main/startup.lua startup.lua
   reboot
   ```
4. Every reboot after that pulls the current files and prints which ones changed. Run `startup` by hand to update without rebooting. It prints the commit it pulled, e.g. `pulling commit 68087ff`, so you can see it is current.

**Why it pins to a commit.** `raw.githubusercontent.com` caches a branch path for 5 minutes and ignores query strings, so fetching `main` within 5 minutes of a push returns the *previous* version. `startup` makes one API call for the latest commit SHA and fetches every file by that SHA, which is immutable and therefore always correct. If the API call fails it falls back to the branch and warns.

## Analysing a flight

Copy `flightlog` off the CC computer. It lives in the world save under `computercraft/computer/<id>/flightlog`. Then:

```
python logs/flightlog_summary.py path/to/flightlog
python logs/flightlog_summary.py path/to/flightlog --rows 40 --phase brake
```

Flight logs are gitignored, so you can keep them next to the script locally.

## CC: Sable, and why GPS is the weak link

Two facts, both read from source rather than docs.

**CC:Tweaked GPS is quantised to whole blocks.** Wireless modems report their position as `Vec3.atLowerCornerOf(blockPos)`, and the distance trilateration consumes is computed between those integers, so a fix can only ever resolve which block a computer is in. The `round(0.01)` inside the GPS API is floating-point cleanup, not sub-block precision. Differencing that for velocity is worse than it sounds: measured in the mock harness with `GPS_QUANT=1 DRIFT=1`, a drone truly drifting 0.5 b/s showed GPS-derived speed peaking at 6.1 b/s and exceeding `SPEED_GUARD` on about 4% of station-keeping samples.

**CC: Sable makes all of that unnecessary.** If the pack has it, the `sublevel` API gives the pod's own rigid body straight from the physics engine:

| Call | Returns |
|---|---|
| `sublevel.getLogicalPose()` | `position` and `orientation` as double-precision `{x,y,z}` and `{x,y,z,w}` |
| `sublevel.getLinearVelocity()` | true linear velocity, no differencing |
| `sublevel.getAngularVelocity()` | true angular rates |
| `sublevel.getMass()`, `getCenterOfMass()`, `getInertiaTensor()` | full rigid-body properties |

That replaces GPS with exact position, and the orientation quaternion carries **yaw**, which the gimbal sensor cannot report and which the whole `HDG_*` motion-heading estimator exists to work around. Run `probe.lua` on the pod to confirm the pose is world-frame and to pin down the quaternion direction and body-axis mapping, before changing any flight code. Run it once stationary and once at speed: the axis-mapping test needs real motion to resolve. The conventions it is checking against, and the open questions it answers, are in [FRAMES.md](FRAMES.md).

## Testing without the game

Three suites, all runnable on a desktop with `pip install lupa`:

```
python tools/run_mock.py --selftest    all eight fly.lua modes, phase sequences
python tools/run_db_test.py            lib/db.lua, 27 cases
python tools/run_upload_test.py        upload.lua against a mocked GitHub API
python tools/run_mission_test.py       lib/mission.lua, 24 cases
python tools/run_chime_test.py         lib/chime.lua, 13 cases
python tools/run_mixcal_test.py        mixcal.lua against a known corner rig
python tools/run_mixer_test.py         lib/mixer.lua, 24 cases
python tools/run_rs_test.py            lib/rs.lua, 19 cases
python tools/run_attitude_test.py      lib/attitude.lua, 18 cases incl. singularities
```

Set `SPEAKER=1` on the mock harness to attach a speaker and see which notes a
flight actually plays.

### What a successful flight needs

`lib/mission.lua` exists because a flight fails for boring reasons, not exotic
ones. In order of how often they bite:

1. **A surveyed destination.** A place needs a ground height before a drop
   altitude can be computed. `plan()` silently omits the hover and release legs
   for an unsurveyed place, and `validate()` refuses it.
2. **Round-trip energy with a reserve held back.** Every estimate is multiplied
   by `MARGIN` because estimates are optimistic, and `RESERVE_PCT` is never
   spendable.
3. **Cruise altitude above the terrain.** Taken from the highest known ground
   height at either end plus `MIN_CLEARANCE`. There is no forward-looking
   sensor on this airframe, so this is only as good as the survey.
4. **A point of no return.** `checkReturn()` answers go / turn back / land now
   from where the drone is, what it has left, and how far home is.
5. **Measured performance.** Everything above is arithmetic on `mission.perf`.
   Until `calibrateFromLog()` has read a real flightlog, `perf.calibrated` is
   false and `validate()` says so instead of pretending the defaults are real.


`fly.lua` can be run against a mock CC:Tweaked API on a desktop, which exercises the phase machine end to end without Minecraft. It stubs the peripherals, a cooperative `parallel`/`sleep` scheduler and a crude kinematic drone, then writes a real `flightlog` the analyser can read. It verifies phase transitions and argument handling only. It says nothing about whether the tuning constants fly well, because the physics model is a stand-in rather than the mod's.

## Lua constraints

CC:Tweaked is Lua 5.1: no `goto`, no integer division `//`, use `table.unpack` not `unpack`. Every peripheral call costs a game tick, so the control loop keeps peripheral reads to the minimum. Do not add reads per iteration when refactoring.
