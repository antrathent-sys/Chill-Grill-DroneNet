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

**Sub-levels live in Sable's plot grid, far from the world.** A first probe run
on a real contraption returned a centre of mass of about 20,481,033 / 127 /
20,489,224. So `getCenterOfMass()` is in plot-grid coordinates, neither world
nor body-relative, and the same is likely true of `getLogicalPose().position`.
Confirm against `gps.locate` before letting the pose replace GPS, and update
[FRAMES.md](FRAMES.md) with the answer.

Also seen on that run: mass 51, an identity orientation quaternion while level
with body +x/+y/+z mapping cleanly onto world X/Y/Z, and a getLogicalPose call
costing 0.05s, which is the one tick expected of a main-thread call.

## Known issues

**Heading oscillates.** Diagnosed: heading comes from GPS displacement, GPS is
block-quantised, and at `HDG_MIN_MOVE = 2` the estimate carries 9.7 degrees of
mean error and 22.9 at the 95th percentile. Bad heading leans the drone wrong,
which moves it, which produces another bad heading. Raising `HDG_MIN_MOVE` to
about 10 cuts the error five-fold as a stop-gap; the real fix is the Sable
quaternion.

**`upload.lua` has never talked to the real GitHub API.** Everything up to the
network hop is tested. Needs one live run.
