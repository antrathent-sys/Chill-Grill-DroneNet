# Chill & Grill DroneNet

Flight controller for a **Create Aeronautics** drone, written for **ComputerCraft (CC:Tweaked, Lua 5.1)**. A single vector thruster does everything: lift, attitude and translation. The controller runs on an advanced computer bolted to the pod and writes a `flightlog` CSV every flight.

## Files

| File | Purpose |
|---|---|
| `fly.lua` | The controller. Four modes, see below. |
| `kill.lua` | Panic stop: thruster power to 0, nozzle vector zeroed, all redstone outputs off, any electric motor stopped. |
| `startup.lua` | Runs on boot. Pulls the latest `.lua` files from this repo's raw GitHub URLs, writes them to the computer's root and prints what changed. |
| `logs/flightlog_summary.py` | Post-flight analysis of a `flightlog` CSV: per-phase summary and sampled rows. |

## Hardware

All peripherals are found by type except the velocity sensors, which are addressed **by name** because `peripheral.find` ordering is not stable between sessions.

| Peripheral | Count | Used for |
|---|---|---|
| `vector_thruster` | 1 | The only actuator. `setVector(vx, vy)` tilts the nozzle, `setPowerNormalized(p)` sets thrust 0..1. |
| `gimbal_sensor` | 1 | `getAngles()` gives **pitch and roll only**. No yaw, which is why heading is derived from motion. |
| `altitude_sensor` | 1 | `getHeight()` for the altitude loop. |
| `navigation_table` | 1 | `getRelativeAngle()` bearing to its target. Measured in the pod's own tilted plane, so it is de-rotated by pitch/roll before use. Currently reads about 180 deg out and is only a fallback (`NAV_FALLBACK = false`). |
| `modular_accumulator` | 1 (optional) | `getPercent()` energy, logged only. |
| fuel source | 0..1 | The thruster itself by default, or any tank named in `FUEL_NAME`. Read once a second in its own coroutine, logged as `fuel` %. See Fuel monitoring. |
| pump drive | 0..1 | Optional. A redstone side (`PUMP_SIDE`, e.g. a clutch on the pump shaft) and/or a CC&A electric motor (`PUMP_MOTOR`) that `fly` switches on before takeoff and off on exit. |
| `velocity_sensor` | 3 | Body-frame velocity, one per axis. `velocity_sensor_0` forward, `velocity_sensor_1` lateral, `velocity_sensor_3` vertical. Identified in freefall: the vertical one read -24 b/s while the others read ~0. |

The sensors (`gimbal_sensor`, `altitude_sensor`, `velocity_sensor`, `navigation_table`) come from **Create: Avionics**; the thruster comes from **Gadgets & Gizmos**, whose thrusters accept either FE or liquid fuel through a thruster gimbal or bearing. Method names used here were checked against the Avionics docs in September 2026 and are current.

The velocity sensors tilt with the airframe. With the vertical axis measured, the body vector is rotated back to level, so "forward speed" stays horizontal-forward even at 70 deg of lean.

### GPS hosts

`fly` needs a GPS fix for every mode except `find`. Four computers with ender modems running `gps host` are set up at the volcano and must stay **chunk-loaded**. If the fix is lost, the position loop rejects updates after 5 bad samples and position hold stops leaning until the fix returns. Position hold is also disabled above `SPEED_GUARD` ground speed so a stale fix cannot command a big lean.

### Fuel monitoring

`fly` probes the fuel source once at startup and prints which method it found:

- `getFuelAmount` / `getFuelCapacity` if the peripheral has them.
- Otherwise CC:Tweaked's generic `tanks()`, which reports amount only. Set `FUEL_CAP` in mB to get a percentage.
- If neither exists it prints the peripheral's full method list so you can see what the current mod version exposes, and flies with fuel logged as -1. Gadgets & Gizmos ships its own peripheral docs in-game: run `/rom/thrusters/docs.lua` on any computer.

Reads happen in a separate coroutine every `FUEL_POLL` seconds, so they add nothing to the control loop. Below `FUEL_WARN` % it prints `LOW FUEL` once and re-arms if the level recovers. It never changes the flight on its own.

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
```

Ctrl+T stops the program. On any exit, including a tumble error, the thruster is cut and `flightlog` is closed.

Phases as they appear in the log:

- **find / fly**: single phase, altitude PID plus position hold.
- **climb**: fixed `CLIMB_POWER` eased by climb rate, no lean. Transitions `DASH_SETTLE` blocks below the goal while still climbing.
- **dash**: `dash` mode holds a fixed pitch. `go` mode steers toward the target with a velocity controller in the body frame, lean capped at `CRUISE_DEG`.
- **brake**: pitches the other way against forward speed until it drops below `BRAKE_DONE` or `BRAKE_MAX_T` runs out.
- **hold**: altitude plus position hold at the current spot (`dash`) or the target (`go`).

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

**Fuel and pump**

| Key | What it does |
|---|---|
| `FUEL_NAME` | Peripheral to read fuel from. `nil` reads the thruster itself. |
| `FUEL_CAP` | Tank capacity in mB, needed only when the source reports amount but not capacity. |
| `FUEL_POLL` | Seconds between fuel reads. Each read is one peripheral call. |
| `FUEL_WARN` | Percent below which `LOW FUEL` is printed. |
| `PUMP_SIDE` | Redstone side held high while flying. `nil` disables. |
| `PUMP_MOTOR`, `PUMP_RPM` | CC&A electric motor name and speed for the pump. `nil` disables. |
| `PUMP_PRIME` | Seconds to wait after the pump starts before flying. |

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

## Lua constraints

CC:Tweaked is Lua 5.1: no `goto`, no integer division `//`, use `table.unpack` not `unpack`. Every peripheral call costs a game tick, so the control loop keeps peripheral reads to the minimum. Do not add reads per iteration when refactoring.
