# Performance

What the craft actually does, what stops it doing more, and which levers are
worth pulling. Measured on 2026-09-28 from the 61 flights of 2026-09-26 and
09-27 (`python tools/fleetstats.py --since 2026-09-26`, and the phase and
brake analysis behind the numbers here). Everything below is drone-1, the
hand-built airframe2 rocket, at `CRUISE_DEG 58 / CRUISE_BODY_LEAN 30`.

## The one number that matters

Over 32 transits between 620 and 8,669 blocks:

    trip time  =  64 s  +  distance / 171 b/s        (typical error 2 s)

A dock-to-dock trip is the same with 156 in place of 171. Two things follow:

- **The cruise is fine.** The marginal speed is 171 b/s, which is what the
  craft cruises at. Every extra block costs what it should.
- **The fixed 64 s is the whole problem.** It is paid on every trip, however
  short. A 500-block hop takes 67 s, which is 7 b/s door to door. Only past
  about 5,000 blocks does the average beat half the cruise speed.

| distance | trip | door to door |
|---|---|---|
| 500 | 67 s | 7 b/s |
| 1,000 | 70 s | 14 b/s |
| 2,000 | 76 s | 26 b/s |
| 4,000 | 87 s | 46 b/s |
| 8,000 | 111 s | 72 b/s |

Use it for quoting: **a minute, plus a second for every 170 blocks.**

## Where the 64 s goes

Median over transits past 2,000 blocks (88 s total, 3,669 blocks):

| phase | time | what it is |
|---|---|---|
| climb | 8.5 s | 78 → 340, about 30 b/s |
| cruise | 25.3 s | the only part that covers ground fast |
| brake | 13.8 s | 170 → 8 b/s in about 1,050 blocks |
| **land** | **34.6 s** | 22 s closing and settling, 13 s coming down |
| touchdown | 3.1 s | logging after the thrust is off |

A dock landing replaces `land` with align 27.9 s + descend 11.7 s + capture
1.5 s, so it costs about the same.

**The 22 s of closing is the single biggest piece of dead time**, and it
exists because the brake stops short: over 56 brakes the gap between where
the brake ends and where the craft is going is **95 blocks median, worst
225**. Closing that gap on the position hold runs at roughly 5 b/s.

## Are we reaching the speeds? Yes

- Peak on a long leg: **172-188 b/s**, best logged 198.
- Commanded lean 58° produces 61-63° of actual tilt, peaking at 74-79°.
- Acceleration is the quiet limit: from the brake-to-brake slices, the craft
  reaches 122 b/s at 10-15 s, 167 at 20-25 s and 186 at 30-35 s. **A leg
  shorter than about 2,500 blocks never sees top speed** - it is braking
  before it finishes accelerating. The 800-block legs top out at 133 b/s.

## What is NOT the limit

**Thrust.** Mean throttle through a cruise is 0.47-0.51 and the mixer
saturates on about 1% of cruise and brake rows. There is roughly half the
throttle range spare at cruise.

**Energy.** 0.2% of a battery per 1,000 blocks. The longest leg flown, 8,669
blocks, cost 1%. Range is not a constraint on this world, and it will not
become one; charging matters for a parked craft, not for a trip.

**The log or the radio.** No dropped rows, no telemetry gaps on any of the 61.

## What IS the limit: attitude, and mostly yaw

Through a single cruise, measured in 5 s slices across all recent flights:

| into the cruise | lean error (rms) | yaw rate (rms) | speed |
|---|---|---|---|
| 5-10 s | 7.0° | 9.6°/s | 68 b/s |
| 10-15 s | 5.4° | 15.4°/s | 122 b/s |
| 20-25 s | 7.6° | 19.5°/s | 167 b/s |
| 30-35 s | 9.0° | 25.0°/s | 186 b/s |

The craft tracks its commanded lean to about 5° once settled, and then that
error grows again as speed rises, with the yaw rate growing faster than
anything else - it more than doubles between 60 and 186 b/s. That is the
same divergence that made `CRUISE_DEG 62` tumble: past about 58° the yaw
wander couples into roll faster than the controller pulls it back.

So the ceiling is **rotational authority, not thrust**. Worth remembering
from FRAMES.md: differential thrust across spread thrusters gives rotation
about the nose and starboard axes and **exactly zero about the thrust axis**,
which is why yaw is the weakest axis on this frame and the first to go.

## The levers, worst payoff last

**1. Tighten the brake. One number, about 10 s a trip.**
`BRAKE_MAP_SCALE` multiplies the whole brake map. Over 56 brakes the map
asks for 13% more room than the craft actually used (median needed/map 0.87),
and the tightest brake of the lot still only needed 0.94 of it.

**Done on 2026-09-28 (7986a21).** A flat `BRAKE_MAP_SCALE` was the first
idea, but the error is not flat: the map is 6-14% generous at 170-190 b/s and
**20-32% at 77-106 b/s**, where a short leg has no cruise time to hide it. So
the map itself was refitted, to the 90th percentile of what each band actually
used:

| what the craft needed | 85 b/s | 105 | 134 | 174 | 189 |
|---|---|---|---|---|---|
| median | 329 | 406 | 687 | 992 | 1035 |
| worst | 342 | 428 | 712 | 1036 | 1097 |
| map now asks | 443 | 536 | 795 | 1095 | 1165 |
| **refitted** | **352** | **440** | **715** | **1035** | **1055** |

Against all 56 logged brakes: gap **24 blocks median** against 112, and 7 of
them overshoot by up to 16 blocks - inside `RECRUISE_DIST` (60), so those land
from the other side rather than cruising again.

**2. Refit the slow end of the brake map.** The gap is 6-14% of the trigger
distance at 170-190 b/s but **20-32% at 77-106 b/s** (93-138 blocks of crawl
on a short leg, where there is no cruise time to hide it). At 85 b/s the map
asks 443 and the craft used 345. Short legs are most of a taxi service, so
this is worth doing properly once the scale factor is flown.

**3. Cruise altitude.** `CRUISE_Y 350` costs 8.5 s climbing and about 13 s
coming back down: 24% of a trip, paid whatever the distance. Dropping to 250
would save roughly 7 s. **Ruled out** (Alex, 2026-09-28): 350 is the safety
altitude and is not negotiable.

**4. Keep the height the brake gained. Done 2026-09-28 (a98fa8e).** Braking
leans the craft back, which turns speed into lift: 12 of 56 brakes ended
17-66 blocks above the cruise altitude. The approach used to chase that height
back down, which **cut the throttle to zero** - and with no thrust there is no
lean force either, so the craft coasted 22 blocks *further* from the pad over
the first 4 s before it began closing (06-46-11, 04-05-50). It now keeps the
height; the extra descent costs about a second.

**5. Faster closing on the last 50 blocks.** They are flown on the position
hold at about 5 b/s. Letting the approach carry speed later would save several
seconds, but it trades against the landing accuracy only just won (0.6 blocks
median). Not until the two changes above have been flown.

**6. More speed.** Needs rotational authority, not throttle:
wider spacing between the thrusters for a longer moment arm; canted thrusters
or vector bearings so there is real torque about the thrust axis; a lower
centre of mass. Without one of those, 58° is the ceiling this frame has
already been proved at, and 62° tumbles.

## Stability, plainly

- 4 tumbles in 61 flights (6.6%), against 36 in 238 before. Of the 4: one was
  a craft flown while lying on its side (now refused, db2f258), one was the
  58° cruise divergence, and two lost attitude on the way down.
- Median worst tilt on a normal flight is 76°, against a `TUMBLE` cut at 85°
  per axis. **That is a 9° margin on a craft whose lean error is already 9°
  rms at speed** - which is exactly why 62° had nothing left.
- Landings now touch down at 2.4 b/s median, every one under 5, and 30 of 31
  within 5 blocks of the mark.

The honest summary: the machine is flying near the edge of what its attitude
control can hold, and every remaining speed lever pushes on that edge. The
time levers (brake, altitude) do not, which is why they come first.
