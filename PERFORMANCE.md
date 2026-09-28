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

**The 22 s of closing is the single biggest piece of dead time.** Over 56
brakes the gap between where the brake ends and where the craft is going is
**95 blocks median, worst 225**, and closing it on the position hold runs at
roughly 5 b/s.

**That gap is sideways, not short** (found 2026-09-28, after the refit below
had flown once). Split along and across the route, 20 flights of the
3,669-block route:

| at | across the route | along the route |
|---|---|---|
| mid-cruise | 7 to 34 off the line | - |
| brake start | 3 to 43 off (one outlier 93) | - |
| **brake end** | **54 to 127, the same side every time** | **median +7** (-76 to +121) |

The old map already stopped on the mark along the route. It is the brake
itself that swings the craft 80-130 blocks to one side, and that is what the
closing pays for. The next lever is that swing, in the flight code.

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

**1. Tighten the brake. REVERTED - the premise was wrong (see above).**
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

That arithmetic compared the whole gap with the map, but the gap was
sideways. The first flight on the refit (2026-09-28 07-49-24) started braking
at 1,005 blocks instead of ~1,075, used 1,203 (one of the two longest brakes
on the route, both ballooning above 410), and ended **198 blocks past** the
target: 26 s closing back, 98.9 s for a route that takes 88. The map is back
to the 2026-09-20 one.

On the old map again (2026-09-28 08-00-51, home, dock): braking started at
1,086 blocks at 174 b/s and ended 75 short and 48 to the side, the sideways
swing 70 blocks (22 one side at brake start, 48 the other at the end).
Keep-the-height, flown alone: handed over at 370 still rising 17 b/s, so it
peaked at 387 and the throttle sat at zero for 1.9 s - but the craft did not
drift (gap 89 at handover, never more), unlike the 22-block coast it was
written for. Align 28.0 s, descend 12.1 s from 370, captured 1.4 s: the same
as the baseline. Harmless and kept; it is not where the time is.

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

### Both descent tumbles, in detail

They are not the same fault, and between them they say what the descent can
and cannot be pushed to.

**09-26 05-06-30** arrived too fast at a ground it did not know. Still doing
43 b/s at Y 133 and 26 b/s twelve blocks before contact, it needed 14.4 b/s^2
to stop and the craft can do 12. It hit and tipped. An open-ground landing
guesses the ground from the height it took off at; get that wrong low and the
profile is still diving when the real ground arrives. `LAND_REST_GAP` now aims
7.5 blocks higher, which helps, but the guess itself is the hazard.

**09-27 11-17-57** lost it in clean air at Y 265, descending 31 b/s on the
0.12 thrust floor. Attitude authority is thrust times lean, so at the floor
there is almost none: a disturbance appeared, the mixer asked for 0.50 against
the 0.25 it had, and the craft departed.

The second one is the answer to "can we descend faster": **a fast descent is
already the most fragile part of the flight**, because the way to descend fast
is to take the thrust away, and thrust is what holds the attitude.

The honest summary: the machine is flying near the edge of what its attitude
control can hold, and every remaining speed lever pushes on that edge. The
time levers do not, which is why they come first.

# The plan

Written 2026-09-28. One change per flight, in this order, because stacked
changes cost seven flights once before and nobody could say which one did it.

## What we are aiming at

| | now | target |
|---|---|---|
| fixed cost of a trip | 64 s | **48 s** |
| marginal speed | 171 b/s | leave it alone for now |
| tumbles | 4 in 61 (6.6%) | **under 2%** |
| landing miss | 0.6 blocks median | hold it |
| touchdown | 2.4 b/s median | hold it under 5 |

Reliability is a first-class number here, not a footnote. A passenger service
is judged on the flight that went wrong, and 6.6% is one bad flight in fifteen.

## How each change is judged

1. Fly it. **Ten landings minimum** before reading anything: the trip-time fit
   has a 2 s error, so a 5 s change needs a handful of trips to show.
2. `python tools/fleetstats.py --split <the date the change went in>`.
3. Pass means the number it targeted moved, **and** miss, touchdown speed and
   tumbles did not get worse.
4. Two regressions in a row and it goes back to the last known-good tune.

## The queue

**1. Brake on the mark** - committed 7986a21, not yet flown.
The refitted map. Expected: the gap the landing has to close drops from 112
blocks to about 24, and with it most of the 22 s of crawling. **Worth about
12 s of the 64.** Watch for: a brake that overshoots more than 60 blocks and
triggers a re-cruise, which would cost far more than it saves.

**2. Keep the height the brake gained** - committed a98fa8e, not yet flown.
Expected: no more zero-thrust coasting at the start of an approach. Only the
20% of flights that balloon will show it, so read it on those. **About 5 s on
those flights.** Watch for: an approach that starts so high the descent
overruns the `LAND_MAX_T` timeout.

**3. `TOUCH_LOG_T` 3.0 -> 1.5** - not written yet.
Three seconds of every trip are spent logging after the thrust is already off.
It earned its keep catching the false touchdown, and that bug is now fixed and
guarded in the mock. **1.5 s, near zero risk** - the craft is on the ground and
the thrusters are cold. Do it once 1 and 2 have been read.

**4. `LAND_DECEL` 10 -> 12** - not written yet.
The profile plans to stop at 10 b/s^2 and the craft actually arrests at 11.9
median, 12.9 best, so the descent is held back by a plan more conservative than
the machine. **1.5-2 s of the 13 s descent.** The risk is real: 15 was tried
before and the craft arrived faster than the profile intended, and an arrival
that does not finish its arrest is what tipped 05-06-30. Pass requires
touchdown speed to stay under 5 b/s.

**5. The dock approach** - needs 1 flown first.
Align is 27.9 s against the land path's 34.6, and most of it is the same
closing problem, so measure it after the brake change before touching
`DOCK_SETTLE_T` (2.0 s) or `DOCK_ALIGN` (2.0 blocks). There may be nothing
left to win here.

**6. The climb** - measure first, no change yet.
250 blocks in 8.5 s, peaking at 56 b/s, with the mixer saturated on a third of
the rows. `CLIMB_RATE` is 100 and not the cap; the ascent is governed by
`DECEL`, the same figure the descent uses, at about 6.3 b/s^2. Stopping a climb
is easier than stopping a fall - gravity and drag both help - so the ascent
could plausibly plan on more. **Perhaps 1.5 s.** Measure the deceleration
actually achieved at the top of a climb before proposing a number, and note
`DECEL` is shared with every other altitude change.

**7. Cruise acceleration** - the big one, and the last one.
Reaching 186 b/s takes 30 s, so nothing under about 2,500 blocks ever sees top
speed. The instability that sets the 58 deg ceiling is speed-dependent: yaw
rate is 9.6 deg/s rms at 68 b/s and 25 at 186. That suggests **leaning harder
while still slow and easing back as speed builds** - a lean schedule rather
than one number. It is the only remaining lever on the marginal speed without
new hardware, and it is the one most likely to end in the sea. Do not start it
until 1-4 are flown and stable, and fly it over land, short, with a full log.

## Ruled out

- **Cruise altitude.** 350 is the safety altitude (Alex, 2026-09-28). The 21 s
  of climb and descent it costs stays.
- **Lowering the thrust floor** (`ATT_MIN_LAND` 0.12) to fall faster. Thrust
  times lean is the only attitude authority there is, and 11-17-57 departed at
  the floor in clean air. If anything this wants to go up during a fast
  descent, not down.
- **`CRUISE_DEG` past 58.** 62 was flown and diverges on this frame.
- **More thrust.** There is half the throttle range spare at cruise; it is not
  the limit.

## Not speed, but on the same list

- **Open-ground ground height.** The landing guesses the ground from the
  takeoff height when nobody surveyed the far end, and guessing low is what put
  05-06-30 into the dirt. Platforms carry a real y; open ground does not. This
  is a reliability item that also happens to be the difference between a
  landing and an incident.
- **Attitude margin on descent.** Median worst tilt is 76 deg against a cut at
  85. Worth knowing whether a higher thrust floor through the fast part of a
  descent buys margin for a second or two of trip time.

## Results

Fill this in as each change is flown. `fleetstats --split <date>` gives every
column.

| change | flown | trips | trip constant | miss | touchdown | tumbles |
|---|---|---|---|---|---|---|
| baseline 09-26/27 | - | 61 | 64 s | 0.6 | 2.4 b/s | 4 |
| 1 brake map refit | 09-28 07-49-24 | 1 | 98.9 s on an 88 s route | 0.6 | ~2.5 b/s | 0 |
| - reverted: premise wrong, the gap is sideways | | | | | | |
| 2 keep the height | 09-28 07-49-24 (with 1) | 1 | - | - | - | 0 |
| 2 keep the height, alone (old map back) | 09-28 08-00-51 | 1 | 85.6 s dock-to-dock, model 87.5 | 0 (docked) | ~1.5 b/s | 0 |
| 3 sideways brake (`BRAKE_SIDE_K 1.5`) | 09-28 08-11-54 | 1 | 76.8 s (cruise wobbled) | 1.5 | - | 0 |
| - removed: sideways speed unchanged (7-14 b/s), 73 blocks across vs 61 | | | | | | |
| 4 yaw authority (`YAW_MAX_LEAN 0.6 -> 0.8`) | 09-28 08-28-07 | 1 | 82.3 s | 0.6 | - | 0 |
| - put back: the swing grew (yaw rate 33 deg/s rms, ~20 normally); the clamp was capping it | | | | | | |
| 5 yaw damping (`YAW_KD 0.02 -> 0.014`) | 09-28 08-32-20, 08-35-07 | 2 | - | - | - | **2** |
| - reverted: the heading swing grew from the climb until it rolled over, twice | | | | | | |
| known-good again (KD 0.02, max 0.6) | 09-28 08-39-44 | 1 | 86.5 s | 1 | - | 0 |
| 6 heading gain (`YAW_KP 0.02 -> 0.01`): margin 30/16 -> 45/25 deg (climb/cruise) | 09-28 08-45-40 | 1 | 90.1 s dock-to-dock | 1 (docked) | - | 0 |
| - calm cruise (yaw rate 2.4 deg/s late, tilt 75, thrust 0.56); heading error 2.5 rms vs 1.0; the climb turn to heading is slower (77 deg behind at 6 s, no overshoot). One flight - on 0.02 3 of 23 were calm too | | | | | | |
| 7 speed (`CRUISE_DEG 58 -> 60`) on KP 0.01 | 09-28 08-55-38 | 1 | 86.8 s | - | - | 0 |
| - 184 b/s (172 at 58), throttle 0.59, yaw calm, tilt 69 mean / 71.5 peak | | | | | | |
| 8 speed (`CRUISE_DEG 60 -> 65`) + brake map to 235 b/s | 09-28 09-02-59 | 1 | 79.3 s (87 at 58-60) | 3.3 | - | 0 |
| - 212 b/s, still accelerating; wobble back (yaw 17 deg/s), tilt peak 82.6 - 2.4 under the cutoff | | | | | | |
| 9 plain yaw cut (`KP 0.005, KD 0.012`) at 65: margin 12 -> 38 deg modelled | 09-28 09-13-09 | 1 | 89.2 s dock | 1 (docked) | - | 0 |
| - wobble gone (yaw rate 2.4 deg/s); heading looser (5.6 rms); climb +2.3 s; brake 84 past; 210 b/s | | | | | | |

**Tilt, corrected (2026-09-28).** The "tilt" quoted above for 65 (82.6 peak) was hypot(pitch, roll) of the
gimbal angles, which overstates it. TUMBLE (85) checks each axis on its own; true tilt is
acos(cos p x cos r). At 65: pitch peak 68-69, roll 52-57, true tilt 62-64 mean / 76 peak - 16 deg clear of
the cutoff. The next speed limit is lift: throttle 0.63 at 65, and ~80 true tilt sank at full throttle.

| change | flown | trips | trip constant | miss | touchdown | tumbles |
|---|---|---|---|---|---|---|
| 10 speed (`CRUISE_DEG 65 -> 70`) + brake map top raised (205:1310 ... 250:1730) | 09-28 09-42-03 | 1 | 83.8 s (79.3 at 65) | 2 | - | 0 |
| - 227 b/s, but throttle on its 0.80 ceiling and 15 blocks low; lean error doubled; brake 78 past | | | | | | |
| 11 lean 67, brake map top refitted to 1,365 @ 211 and 1,591 @ 227 | 09-28 09-55-21 | 1 | 81.9 s | 0.9 | - | 0 |
| - 215 b/s, throttle 0.66, 7 low at worst, pitch 71.7; brake 99 short (brakes up here scatter +-50) | | | | | | |
| 12 heading gain `YAW_KP 0.005 -> 0.007`: slow wander, 27-42 blocks rms off the centreline at 0.005 | 09-28 10-03-51 (6,825 blocks) | 1 | 96.0 s (104 by the 58 model) | 0 | - | 0 |
| - 255 b/s; heading 6.4 rms, yaw rate 3.7; line 38 rms / 66 worst; brake 196 short (map past its end) | | | | | | |
| 13 brake map top refitted to six fast brakes: blocks = 9.8 x speed - 700 | 09-28 10-12-24, 10-18-21 | 2 | 86.7, 87.0 s | 0.0, 0.4 | - | 0 |
| - along: 40 short, 132 past - the scatter follows the brake's balloon (r 0.80 over 46 brakes); across: 127, 110 | | | | | | |
| 13, long route again (before 14) | 09-28 10-21-41 (6,826 blocks) | 1 | **91.3 s** (96.0 before, 104 by the 58 model) | 1 | - | 0 |
| - 260 b/s; brake 67 short (balloon 26 - small balloon, short brake), 60 across (swing 73); closing 16 s | | | | | | |
| 14 sideways brake `BRAKE_SIDE_K 1.5` back on (the swing is 130-167 blocks at 214-256 b/s) | 09-28 10-24-27 | 1 | 82.7 s dock | 0 (docked) | - | 0 |
| - works: sideways speed 0.3 b/s mean (2.7-9.3 before), drift 4 blocks (43-136), 14 off the line (73-167); along 72 past | | | | | | |
| 15 brake throttle floor `BRAKE_HOLD_POWER 0.38` (decel follows throttle, r 0.56 over 38 brakes) | 09-28 10-31-58 | 1 | **78.5 s** (best on the route) | 2 | - | 0 |
| - brake 35 past, 28 across; steady decel 21.6 (18.6 on the last ballooned brake); approach 15.7 s; balloon 60 - at the floor's release | | | | | | |
| 15, long route | 09-28 10-36-02 (6,824) | 1 | 96.8 s | 0 | - | 0 |
| - brake +1 along (on the mark), 107 across - from the cruise: 93 off the line, back at 21 b/s; balloon 67 | | | | | | |
| 16 body lean `CRUISE_BODY_LEAN 30 -> 15`: sideways accel follows heading error, r -0.83..-0.94 | 09-28 11-04-00 | 1 | **69.3 s** (78.5 best before) | 1 | - | 0 |
| - line 16 rms / 28 worst (12-68 / up to 97 at 30); brake 31 short, 25 across; approach 7.5 s (15.5-20.7); roll and lean error unchanged | | | | | | |
