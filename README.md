# Chill & Grill DroneNet

Flight controller for a **Create Aeronautics** drone, written for **ComputerCraft (CC:Tweaked, Lua 5.1)**. A single vector thruster does everything: lift, attitude and translation. The controller runs on an advanced computer bolted to the pod and writes a `flightlog` CSV every flight.

## Files

| File | Purpose |
|---|---|
| `fly.lua` | The controller. Four modes, see below. |
| `kill.lua` | Panic stop: thruster power to 0, nozzle vector zeroed, all redstone outputs off, any electric motor stopped. |
| `startup.lua` | Runs on boot. Pulls the latest `.lua` files from this repo's raw GitHub URLs, writes them to the computer's root and prints what changed. |
| `ARCHITECTURE.md` | The layer stack for the autonomous controller: control, leg, mission, link. Decided before the code. |
| `COMMAND.md` | The ground side: order intake, package assembly, fleet dispatch, and the rednet protocol between depot and drone. |
| `lib/db.lua` | Log-structured key/value store for the depot, built for CC's 1 MB disk. Tested by `tools/run_db_test.py`. |
| `FRAMES.md` | **Read this first.** The one agreed coordinate frame for world, body and attitude. Every value in the project is expressed in one of these. |
| `probe.lua` | Read-only. Dumps what CC: Sable reports on the drone and cross-checks it against GPS and the gimbal sensor. Never touches the thruster. |
| `logs/flightlog_summary.py` | Post-flight analysis of a `flightlog` CSV: per-phase summary and sampled rows. |

## Hardware

All peripherals are found by type except the velocity sensors, which are addressed **by name** because `peripheral.find` ordering is not stable between sessions.

| Peripheral | Count | Used for |
|---|---|---|
| `vector_thruster` | 1 | The only actuator. `setVector(vx, vy)` tilts the nozzle, `setPowerNormalized(p)` sets thrust 0..1. |
| `gimbal_sensor` | 1 | `getAngles()` gives **pitch and roll only**. No yaw, which is why heading is derived from motion. |
| `altitude_sensor` | 1 | `getHeight()` for the altitude loop. |
| `navigation_table` | 1 | `getRelativeAngle()` bearing to its target. Measured in the pod's own tilted plane, so it is de-rotated by pitch/roll before use. Currently reads about 180 deg out and is only a fallback (`NAV_FALLBACK = false`). |
| `modular_accumulator` | 1 (optional) | Main battery. `getPercent()` polled once per `MON_POLL` in the monitoring coroutine, logged as `energy`. `LOW ENERGY` warning with a minutes-to-empty estimate below `ENERGY_WARN`. |
| thruster buffer | 0..1 | The thruster's own FE buffer (or a liquid tank if `FUEL_MODE = "fluid"`), logged as `fuel` %. See Monitoring. |
| `docking_connector` | 0..1 | Optional. Extended by a redstone side (`DOCK_SIDE`), which is also what arms its magnet. `getConnectedName()` is the only dock-state signal and is polled in the monitoring coroutine. See Docking. |
| pump drive | 0..1 | Optional. A redstone side (`PUMP_SIDE`, e.g. a clutch on the pump shaft) and/or a CC&A electric motor (`PUMP_MOTOR`) that `fly` switches on before takeoff and off on exit. |
| `velocity_sensor` | 3 | Body-frame velocity, one per axis. `velocity_sensor_0` forward, `velocity_sensor_1` lateral, `velocity_sensor_3` vertical. Identified in freefall: the vertical one read -24 b/s while the others read ~0. |

The sensors (`gimbal_sensor`, `altitude_sensor`, `velocity_sensor`, `navigation_table`) come from **Create: Avionics**; the thruster comes from **Gadgets & Gizmos**, whose thrusters accept either FE or liquid fuel through a thruster gimbal or bearing. Method names used here were checked against the Avionics docs in September 2026 and are current.

The velocity sensors tilt with the airframe. With the vertical axis measured, the body vector is rotated back to level, so "forward speed" stays horizontal-forward even at 70 deg of lean.

### GPS hosts

`fly` needs a GPS fix for every mode except `find`. Four computers with ender modems running `gps host` are set up at the volcano and must stay **chunk-loaded**. CC: Sable can replace GPS *for the drone*, but not for customers: the `sublevel` API only answers on a sub-level, so a pocket computer on the ground still needs GPS to locate itself. Keep the array up. See [COMMAND.md](COMMAND.md). If the fix is lost, the position loop rejects updates after 5 bad samples and position hold stops leaning until the fix returns. Position hold is also disabled above `SPEED_GUARD` ground speed so a stale fix cannot command a big lean.

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
- **dash**: `dash` mode holds a fixed pitch. `go` mode steers toward the target with a velocity controller in the body frame, lean capped at `CRUISE_DEG`.
- **brake**: pitches the other way against forward speed until it drops below `BRAKE_DONE` or `BRAKE_MAX_T` runs out.
- **hold**: altitude plus position hold at the current spot (`dash`) or the target (`go`).
- **align**: `dock` only. Position hold over the pad, waiting for the drone to be within `DOCK_ALIGN` blocks and under `DOCK_ALIGN_SPD` for `DOCK_SETTLE_T` seconds.
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
| `DOCK_GAP` | Blocks above `padY` to park at. 3 is the connectors' own spacing. |
| `DOCK_BAND` | How close to the park altitude counts as arrived. |
| `DOCK_RATE` | b/s that the altitude goal walks down during the descent. |
| `DOCK_SINK` | Power bled off during capture so the magnet can pull down. 0 means pure altitude hold. |
| `DOCK_CAPTURE_T` | Seconds to wait for the magnet before aborting an attempt. |
| `DOCK_ABORT_DIST` | Blocks of drift that sends the descent back to align. |
| `DOCK_TRIES` | Capture attempts before giving up and just holding. |
| `DOCK_RELEASE_T` | Seconds of thrust before `undock` drops the connector. |

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
| `CKV` | Degrees of lean per b/s of velocity error. |
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
4. Every reboot after that pulls the current `fly.lua`, `kill.lua` and `startup.lua` and prints which ones changed. Run `startup` by hand to update without rebooting.

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

`fly.lua` can be run against a mock CC:Tweaked API on a desktop, which exercises the phase machine end to end without Minecraft. It stubs the peripherals, a cooperative `parallel`/`sleep` scheduler and a crude kinematic drone, then writes a real `flightlog` the analyser can read. It verifies phase transitions and argument handling only. It says nothing about whether the tuning constants fly well, because the physics model is a stand-in rather than the mod's.

## Lua constraints

CC:Tweaked is Lua 5.1: no `goto`, no integer division `//`, use `table.unpack` not `unpack`. Every peripheral call costs a game tick, so the control loop keeps peripheral reads to the minimum. Do not add reads per iteration when refactoring.
