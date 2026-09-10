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

**Rewire the controller to CC:Sable.** Blocked on `probe`. Retires GPS, the
whole `HDG_*` motion-heading estimator, the gimbal sensor and the three
velocity sensors, and cuts the control loop from about 15 main-thread calls per
iteration to 5.

## Measured in game

First real run is saved at [data/probe-run1.txt](data/probe-run1.txt), taken on
a bare test rig with no sensors fitted, sitting still.

**The orientation quaternion came back as (0, 0, 0, w=0).** That is not a
rotation: a unit quaternion must have norm 1 and this has norm 0. So there is
no usable attitude from `getLogicalPose()` yet. Worse, a null quaternion makes
the standard rotate maths return its input unchanged, so the "body axes map
cleanly onto world axes" reading in that run is an artifact and proves nothing.
`probe.lua` now checks the norm and says so loudly.

Next: read `getLastPose()` as well (probe now prints both), and read again
while the contraption is actually **moving**, in case the pose is only
populated once physics has run.

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

## Known issues

**Heading oscillates.** Diagnosed: heading comes from GPS displacement, GPS is
block-quantised, and at `HDG_MIN_MOVE = 2` the estimate carries 9.7 degrees of
mean error and 22.9 at the 95th percentile. Bad heading leans the drone wrong,
which moves it, which produces another bad heading. Raising `HDG_MIN_MOVE` to
about 10 cuts the error five-fold as a stop-gap; the real fix is the Sable
quaternion.

**`upload.lua` has never talked to the real GitHub API.** Everything up to the
network hop is tested. Needs one live run.
