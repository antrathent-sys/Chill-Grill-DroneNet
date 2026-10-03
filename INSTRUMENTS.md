# CINDER NAV instruments - proposal (2026-10-03)

Alex: "a proper pitch roll readout for flight units ... what avionics units
for each of the vehicle types would need".

**Decided, 2026-10-03.** Sable's orientation works. Alex tested it level and
got `1 + 0i + 0j + 0k`; the old "dead" reading was the probe looking for x/y/z/w
on what is an Advanced Math quaternion object. "We are not adding complexity
to the kit": no gimbal sensor and no optical sensor. **Built:** the attitude
page for every kind (AVIONICS.md, pages table), with the nose learned from
motion. Everything below that needs a sensor (height above ground, depth
under the keel, sonar, PULL UP) is parked unless the kit decision changes.

## What real vehicles carry

- **Aircraft.** The "basic six": airspeed, **attitude** (the artificial
  horizon, pitch and roll), altimeter, turn rate, heading, vertical speed.
  A glass cockpit puts these on one screen, the PFD: the horizon in the
  middle, speed and altitude as tapes either side, heading along the bottom.
  On top of that come a **radar altimeter** (height above the ground, used for
  landing), ground-proximity warnings (SINK RATE, PULL UP, BANK ANGLE) and
  traffic warnings.
- **Land.** A speedometer and odometer. Off-road vehicles add an
  **inclinometer**: the vehicle drawn from behind (roll) and from the side
  (pitch), with a red zone where it would tip over (about 30 to 40 deg).
- **Boats.** A compass, a speed log, a **depth sounder** (water under the
  keel), a chart plotter, AIS traffic, rate of turn, and a **clinometer**
  for heel (roll) and trim (pitch).
- **Submarines.** Depth, up/down angle (trim), roll, rate of ascent or
  descent, heading and speed, and **sonar**: clearance to the bottom and to
  anything ahead.

CINDER NAV already covers speed, heading, height or depth, traffic and SOS.
What is missing is attitude, clearance (to the ground or the bottom), and
warnings.

## What the game can measure

Checked in source (Simulated-Project main, CC-Sable master):

| Source | Gives | Cost |
|---|---|---|
| Sable `sublevel` (already read) | position, velocity, so: speed, track, vertical speed, flight-path angle, rate of turn | already paid |
| Sable `getLogicalPose().orientation` | the full attitude (pitch, roll, yaw) | free (same call) - **but it read 0,0,0,0 in every probe on 2026-09-10, including 45 deg and on-side tests** (`data/probe-pose-*.txt`). That was Sable 1.x; never re-tested on 2.0.5 |
| **Gimbal sensor** `getAngles()` | the craft's tilt about its own two level axes, in degrees, exact (computed from Sable's pose each tick, not the swinging visual) | free (not main-thread). Recipe: compass + gyroscopic mechanism + brass casing |
| **Optical sensor** `getDistance()`, `hasHit()` | distance along its beam. The beam passes **through water** unless a water filter is set, so pointing down on a boat it gives the depth under the keel | free (not main-thread). **Range is 15 blocks** by default (server config `optical_sensor_max_range`). Recipe: amethyst + electron tube + brass casing |

The gimbal sensor reads the tilt about the craft's *build* axes, so the unit
still has to learn which of the four build directions is the nose. The
gimbal tells it which way is down in the craft's frame. Each candidate nose
predicts a climb angle, and the real climb angle comes from the velocity.
Whichever candidate matches whenever the craft goes up or down (a plane
climbing, a car on a hill) is the nose. That fits "teaches itself":
`FORWARD: LEARNING - climb or take a slope` until it is sure, then it is
saved. A tap-through override on the setup page covers craft that never
climb nose-first (VTOL, flat-water boats).

## Proposed pages

Every type keeps speed, heading, radar and status. New pages are marked *.

- **Air:** *ATTITUDE (horizon, pitch ladder every 10 deg, bank scale with
  10/20/30/45/60 ticks, P and R numbers, a flight-path marker showing
  where the craft is really going), altimeter + vertical speed, heading
  with rate of turn. On 3-wide and bigger screens a *PFD: horizon, speed
  tape, altitude tape and heading strip on one page. Warnings: BANK ANGLE
  past 60 deg, SINK RATE / PULL UP when the optical sees ground within 15
  blocks and the craft is coming down fast, GROUND nn in the last 15 blocks.
- **Land:** *INCLINE (the vehicle from behind and from the side, red past
  30 deg, TIP warning), speedometer with trip distance.
- **Sea:** *HEEL & TRIM (clinometer, LIST warning past 15 deg), *DEPTH
  (water under the keel from the optical sensor, SHALLOW under 2 blocks),
  compass with rate of turn.
- **Sub:** *ANGLE (up/down angle and roll), depth with rate of ascent or
  descent, *SONAR (bottom clearance from a downward optical sensor, OBSTACLE
  from a forward one if fitted), SURFACE near sea level.

With no gimbal sensor fitted, the attitude pages are left out and the status
page says "FIT A GIMBAL SENSOR FOR PITCH AND ROLL" (a hint, not a blocking
setup problem). Units already handed out pick up a sensor as soon as it is
placed against them.

## Decisions for Alex

1. **Test Sable's orientation on 2.0.5 first.** On any computer on a
   craft, tilt the craft, type `lua`, then
   `sublevel.getLogicalPose().orientation`. If it is no longer all zeros we
   get pitch, roll and true yaw from the read we already make, with no extra
   part. It would also let fly.lua drop its heading estimator.
2. **The kit.** One kit for every type, adding a gimbal sensor and one optical
   sensor (two more stock chests at the kiosk) - recommended, it is simpler.
   The alternative is a kit per type.
3. **Optical range.** 15 blocks covers landing, shallow water and the
   seabed. Ask Sean whether `optical_sensor_max_range` could go to 32-64.
   The cost is one raycast per sensor per tick.
4. **Which warnings ring the speaker** (if one is fitted), or screen-only.
