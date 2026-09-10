# Backlog

Wanted but not built. Newest ideas at the top of each section.

## Flashy

**Navigation lights.** Gadgets & Gizmos laser pointers are a CC peripheral
(`laser_pointer`) with `setColor(argb)`, `setRainbow(bool)`, `getRange()`,
`isFiring()` and `getAxis()`. Aviation convention is red to port, green to
starboard, white strobe at the tail, which reads as deliberate rather than
decorative. Colour is a single ARGB number, so pack it as
`0xFF000000 + r*65536 + g*256 + b`.

Worth driving from the phase machine the same way chimes are: steady on the
ground, slow strobe in cruise, fast strobe during align and descend. Put it in
its own coroutine like `lib/chime.lua`, since `setColor` yields.

**Descent altimeter callouts.** `chime.pitchTick(frac)` already exists and is
unused. Feed it height above the pad normalised 0..1 during `descend` so the
tone rises as it settles. Needs a rate limit; the descend phase runs at 20 Hz
and the speaker takes 8 notes a tick.

**Pad lights on approach.** Drone rednets the pad during `align`, pad lights up
and beeps. Sells the automation more than anything mounted on the drone.

**Mission control monitor.** Monitor wall at the depot: live fleet positions,
order queue, ETAs. Mostly a rendering job once telemetry and `lib/db.lua` are
carrying real data.

## Plumbing

**Depot program.** Order intake, validation, dispatch. Design is settled in
[COMMAND.md](COMMAND.md); `lib/db.lua` and `lib/mission.lua` are the pieces.

**Mission and link layers.** L3 and L4 from [ARCHITECTURE.md](ARCHITECTURE.md).
`lib/mission.lua` covers the planning half; the queue runner and rednet
telemetry are unwritten.

**Four-thruster mixer.** Blocked on the airframe and on `probe` output. See
[FRAMES.md](FRAMES.md) for the axis convention it must use.

**Rewire the controller to CC:Sable.** Position and velocity: **done**, the
drone now flies on `getLogicalPose().position` and `getLinearVelocity()`.

Still outstanding, and now blocked upstream rather than on measurement: the
`HDG_*` motion-heading estimator and the gimbal sensor cannot be retired while
the orientation quaternion reads null, because that was the only source of
yaw. The three velocity sensors could go, since `getLinearVelocity` covers
world-frame speed, but body-frame speed still needs either them or a working
quaternion to rotate with.

## Measured in game

### Settled: pose.position IS world frame, and GPS is broken

Checked against ground truth at last, standing at F3 68 / 68 / 142
([data/probe-run3-groundtruth.txt](data/probe-run3-groundtruth.txt)):

| Source | Reading | Error vs F3 |
|---|---|---|
| `getLogicalPose().position` | 68.33 / 65.33 / 142.39 | 0.33 / -2.67 / 0.39, **2.7 blocks** |
| `gps.locate()` | 92.74 / 97.00 / 118.69 | +24.7 / +29.0 / -23.3, **44.7 blocks** |

Pose matches reality in x and z to within half a block; the 2.7 in y is just
the computer block sitting below where the player stands. **GPS is out by 45
blocks** and is the source that has been lying all along.

That inverts several earlier conclusions here, all of which compared the pose
against GPS and blamed the pose. `probe.lua` made the same mistake, so it now
takes ground truth: `probe here <x> <y> <z>`.

**So the drone should drop GPS and fly on `pose.position`.** It is accurate,
needs no host array, costs one main-thread call, and cannot be knocked out by
a chunk unloading at the volcano.

**The GPS host array still needs fixing regardless**, because customers on the
ground have no other way to locate themselves. It was rearranged once already
and is still 45 blocks out, so check each host's coordinates against F3 for
that exact block, and check no three are collinear.

**Still dead: the orientation quaternion.** Norm 0 in every sample of every
run. Attitude keeps coming from the gimbal sensor.

First real run is saved at [data/probe-run1.txt](data/probe-run1.txt), taken on
a bare test rig with no sensors fitted, sitting still.

**CONFIRMED over 44 moving samples ([data/probelog-run2.csv](data/probelog-run2.csv)):
the orientation quaternion is never populated.** Norm is 0.00000 in every
sample, including the 13 samples with real angular velocity where the craft was
demonstrably rotating. `getLastPose()` is identical to `getLogicalPose()` in
every row, so there is no alternative source. **CC:Sable gives no attitude in
this version.** The gimbal sensor stays; the plan to retire it and take yaw
from the quaternion is dead until this is fixed upstream. Worth raising with
TechTastic1.

**`pose.position` is not self-consistent either.** Its frame-to-frame movement
disagrees with `getLinearVelocity()` integrated over the same interval by about
87 percent, and that comparison involves GPS not at all. Between the two
stationary stretches, pose says the craft rose 7.6 blocks while GPS says it
fell 5.5. Both cannot be right, and until one is checked against F3 neither can
be trusted. Note one confound in the measurement: `gps.locate(0.5)` blocks, so
pose and GPS are not sampled at the same instant during motion.

Earlier finding, now superseded by the above:

**The orientation quaternion came back as (0, 0, 0, w=0).** That is not a
rotation: a unit quaternion must have norm 1 and this has norm 0. So there is
no usable attitude from `getLogicalPose()` yet. Worse, a null quaternion makes
the standard rotate maths return its input unchanged, so the "body axes map
cleanly onto world axes" reading in that run is an artifact and proves nothing.
`probe.lua` now checks the norm and says so loudly.

Next: `probe log 30` while the craft is **moving**. It samples position,
quaternion with its norm, GPS, both velocities and `getLastPose` twice a
second into `probelog.csv` and pushes it. Motion is what answers both open
questions: whether the quaternion populates once physics has run, and whether
`pose.position` tracks GPS (world with an offset) or stays put (something
else entirely).

**Sub-levels live in Sable's plot grid, far from the world.** `rotationPoint`
and `getCenterOfMass()` both returned about 20,481,033 / 127 / 20,489,224, so
both are plot-grid coordinates rather than world or body-relative.

**`pose.position` is not world either.** It read 371.79 / 65.55 / 421.90 while
`gps.locate` said 847.71 / -48.56 / 650.94. Those disagree by hundreds of
blocks, so the pose cannot replace GPS until we know what frame it is in.

**GPS on a sub-level returns FRACTIONAL coordinates**, correcting the earlier
finding here. Block quantisation applies to a static computer, whose modem sits
at an integer block position; on a sub-level the modem is at a real position so
trilateration solves to fractions. The heading-error table below is therefore
pessimistic for the drone, though the closed-loop oscillation it describes was
still observed.

**That GPS fix WAS wrong, and it is now fixed.** The run showed a y of -48.56
against a real position nowhere near it. Cause: the host constellation was
degenerate. CC distances are exact so hosts need not be far apart, but they
must not be collinear or coplanar, and four hosts at one height cannot solve
the vertical at all. Rearranged so one host is offset in Y and fixes are good.

**Refly before touching any gains.** Heading is derived from GPS displacement,
so bad fixes produced a bad heading, which leaned the drone the wrong way,
which moved it, which produced another bad heading. The oscillation being
chased in tuning may simply have been this. Measure again before changing
anything.

## The four-thruster airframe, as built

First inventory: [data/preflight-airframe1.txt](data/preflight-airframe1.txt).

Fitted: 4x `vector_thruster` (13 methods each), 4x `modular_accumulator`,
1x `docking_connector`, 1x `createaddition:large_connector`, and two modems
(`bottom` with 13 methods, so wired; `top` with 6, so wireless).

**Blocking, must be fitted before it can fly:**

- **`gimbal_sensor`.** There is no attitude source without it. Sable's
  quaternion reads null, so this is the only one. Hard blocker.

**Should be fitted:**

- **`altitude_sensor`.** `pose.position.y` could substitute, but the altitude
  sensor reads a specific block and is what `DOCK_GAP` is calibrated against.

**No longer needed:**

- **Velocity sensors.** `getLinearVelocity()` gives world-frame velocity
  directly. Body-frame speed would need attitude to rotate into anyway, and
  position hold and braking can both be done in world frame.
- **`navigation_table`.** Only useful now for lodestone targeting.

**Two code changes the build forces:**

1. **Four thrusters, four separate peripherals.** They are not on a shared
   bearing, so `peripheral.find("vector_thruster")` takes one and ignores
   three. `fly.lua` cannot fly this airframe until the mixer exists.
2. **Four accumulators.** Only the first is read, so energy is understated to
   a quarter of the truth.

### The thruster API, as measured

Each `vector_thruster` exposes 13 methods
([data/preflight-airframe2.txt](data/preflight-airframe2.txt)):

```
getPower  setPower  setPowerNormalized
getThrust setThrust setThrustNormalized
getVectorX getVectorY  getTargetVectorX getTargetVectorY
setVector  setVectorX  setVectorY
```

Three things matter for the mixer, none of which the single-thruster code uses:

- **`getThrust()` reads back real thrust.** So allocation can work in thrust
  units rather than normalised power, and a thruster that is saturated, starved
  or dead can be detected in flight rather than inferred from a crash.
- **`getVectorX/Y` differs from `getTargetVectorX/Y`.** The nozzle slews toward
  a commanded angle rather than snapping to it, so the actuator has lag. The
  mixer can measure that lag instead of guessing, and the attitude loop should
  be tuned against the actual vector, not the commanded one.
- **`setVectorX` and `setVectorY` are separate**, so one axis can be commanded
  without disturbing the other.

Other APIs worth knowing: `modular_accumulator` has
`getEnergy`/`getCapacity`/`getMaxExtract`/`getMaxInsert`, so the four can be
summed for true pack energy instead of reading one percentage.
`altitude_sensor` also has `getAirPressure`, which is the input to the
thrust-versus-altitude question. `gimbal_sensor` has `getAnglesRad`, avoiding a
conversion in the loop.

**Both modems are wired** (`isWireless` false, 13 methods each). Wired rednet
works across the dock but there is no air-to-ground link, so telemetry and
remote recall need a wireless or ender modem fitted.

### What the mixer still needs

Geometry is known: **four thrusters at the corners of a 3x3**, so a moment arm
of one block in each axis. A standard quad X layout.

What is still unknown is which peripheral name sits in which corner, since
names carry no position. `mixcal.lua` measures it: pulse one thruster at a
time at low power on the ground, record which way the gimbal leans, and read
the corner off the sign pair. Verified against a rig with a known layout that
it is not told about (`tools/run_mixcal_test.py`).

**First live run ([data/mixmap-run1.csv](data/mixmap-run1.csv)) produced a
clean map**, though `mixcal` threw it away at the time because the tilts were
below a fixed 0.4 degree threshold:

| Thruster | pitch | roll | corner |
|---|---|---|---|
| `vector_thruster_5` | -0.0456 | +0.0427 | B1 |
| `vector_thruster_6` | -0.0307 | -0.0313 | B2 |
| `vector_thruster_7` | +0.0342 | -0.0333 | A2 |
| `vector_thruster_8` | +0.0342 | +0.0343 | A1 |

**Confirmed by a second independent run**
([data/mixmap-run2.csv](data/mixmap-run2.csv)): identical corner for all four
thrusters, magnitudes agreeing to a factor of 1.23. Two runs agreeing on all
four assignments by chance is 0.39%. The map is settled:

```
                     pitch +
              vt_8  --------  vt_7
              (A1)            (A2)
        roll +   |            |   roll -
              vt_5  --------  vt_6
              (B1)            (B2)
                     pitch -
```

Diagonal pairs are `vt_5`/`vt_7` and `vt_6`/`vt_8`. The mixing follows
directly:

| Axis | Combination |
|---|---|
| lift | all four equally |
| pitch | `(vt_7 + vt_8) - (vt_5 + vt_6)` |
| roll | `(vt_5 + vt_8) - (vt_6 + vt_7)` |
| yaw | not available from thrust; needs tangential vectoring |

Which physical direction "pitch +" points depends on how the gimbal is
mounted, and the mixer does not care as long as it is consistent, which two
runs show it is.

The threshold was the bug. A grounded airframe barely rocks, so the signal is
genuinely tiny and the SIGNS are what carry the map. `mixcal` now measures the
gimbal's noise floor with nothing firing and judges against that, and reports
the map even when weak rather than discarding it. It also reads `getThrust()`
during the pulse rather than after, which is why every thrust column in that
run reads 0.00.

**The mixer is written**: `lib/mixer.lua`, 24 tests. It takes the measured
corner signs rather than any assumed geometry, so a sign error is not possible
without mixcal having lied twice.

What it does and does not give, on this airframe as fitted:

| Axis | Source | Closed loop? |
|---|---|---|
| lift, pitch, roll | differential thrust | yes, from the gimbal |
| horizontal force | all four nozzles vectored together, **without tilting** | yes, from `getLinearVelocity` |
| yaw **rate** | nozzles vectored tangentially | yes, from `getAngularVelocity` |
| yaw **heading** | - | **no. There is no absolute yaw sensor.** |

The gimbal reads pitch and roll only and Sable's quaternion is null, so as
fitted the craft can arrest a spin but not hold a heading.

**Tested, and it does not.** `getHeading` and `getOrientation` are **nil in
this pack's Avionics build** ([data/probe-run4-navtable.txt](data/probe-run4-navtable.txt)):
the fitted nav table exposes only `getRelativeAngle`. Those methods exist in the
current Avionics documentation but not in the version installed, and the mod
list is not ours to change.

So yaw is back to the one hard route: `getRelativeAngle` is measured in the
block's own tilted plane, and de-rotating it by the gimbal's pitch and roll
gives a bearing to whatever the table is targeting. `fly.lua` already
implements exactly that as `correctedHeading()`, and its CFG notes the reading
came out about 180 degrees out, which was never resolved. It also needs a
target set in the table, and a lodestone is the way to set one.

Otherwise the mixer's honest limit stands: **yaw rate damping yes, heading hold
no.**

`probe` now lists a peripheral's real method names before calling any of them,
so a docs-versus-build mismatch shows up as a line of output rather than an
error. Superseded reasoning follows.

**Refitting the navigation table probably fixes this outright.** `fly.lua` only
ever used `getRelativeAngle`, which is the one method measured in the block's
own tilted plane and needs de-rotating. The Avionics docs describe two others
that are already world frame:

| Method | Documented as |
|---|---|
| `getHeading()` | world-frame yaw, already corrected for the contraption's rotation. Ship's +Z rotated into world, `atan2(x, z)`, 0 = Minecraft south, player-yaw convention |
| `getOrientation()` | quaternion `{x,y,z,w}` of the host sub-level's orientation |

If `getOrientation` is populated where Sable's is not, it is a drop-in
replacement for the attitude source this project has been missing, and would
retire the gimbal sensor and the whole `HDG_*` estimator at once. `probe` now
reads both and checks the quaternion norm.

**Answered: neither method exists in the installed build.** See above.

Also measured on that run: the altitude sensor sits a steady **3.06 blocks
above `pose.position.y`** (68.50 against 65.44), matching the 3.19 seen
earlier. That offset is stable and is what `DOCK_GAP` has to absorb.

On saturation the mixer sacrifices lift before attitude, since attitude is what
keeps the craft the right way up. Verified: a pitch differential commanded at
0.98 lift survives intact while the whole set shifts down to fit.

The allocation, for reference:

- **collective** thrust on all four for lift
- **front minus back** for pitch
- **left minus right** for roll
- **tangential vectoring** for yaw, which differential thrust cannot produce
  at all
- **common vectoring** for horizontal force without tilting, which is the part
  that makes docking easy

## Known issues

**Heading oscillates.** Diagnosed: heading comes from GPS displacement, GPS is
block-quantised, and at `HDG_MIN_MOVE = 2` the estimate carries 9.7 degrees of
mean error and 22.9 at the 95th percentile. Bad heading leans the drone wrong,
which moves it, which produces another bad heading. Raising `HDG_MIN_MOVE` to
about 10 cuts the error five-fold as a stop-gap; the real fix is the Sable
quaternion.

**`upload.lua` has never talked to the real GitHub API.** Everything up to the
network hop is tested. Needs one live run.
