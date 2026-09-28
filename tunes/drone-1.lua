-- The server craft (hand-built airframe2: 4 thrusters, 2 sails a side
-- below the CoG, ballast to ~73 mass, tables 1/2/3). startup installs this
-- as tune.lua on the computer labelled (or numbered) drone-1; fly loads it
-- over CFG and prints what it took. Values from 2026-09-19:
--   YAW_MAX_LEAN 0.6   the yaw ran away both ways at 45-60 b/s with 0.3
--   YAW_OFFSET 225     puts the lean on the pitch/roll diagonal; 260 put it
--                      mostly on roll and the gimbal let go past ~75 deg
--   CRUISE_DEG 58      62 (13-49) topped out lower at 185, roll swing grew to 60+ deg, thrust
--                      hit the 0.80 cap and it tumbled at 150 b/s: 58 is the ceiling on this frame
--   BRAKE_MAP          31 measured brakes, blocks needed from each speed. The
--                      top points re-fitted 2026-09-19 night: with
--                      BRAKE_TURN_POWER the reversal takes ~2.5 s instead of
--                      ~3.2 and four brakes from 187-192 needed 1039-1146
--                      blocks (23-40-25, 23-47-46). Re-fitted again on
--                      2026-09-20 against the first flights that really flew
--                      58 + the floor: 175 b/s needed 1092-1099, 195 needed
--                      1218, so the top of the map rises with a 175 point.
--                      Mid band raised too: 145-148 b/s needed 913-962
--                      (00-09-35), where the map said 804-833
--   BRAKE_EASE 60      the brake held its full 45 deg lean down to 15 b/s;
--                      below ~85 b/s that saturated the mixer in bursts,
--                      roll missed by 30, yaw kicked to 90 deg/s (13-15-51).
--                      Now it fades below 60 b/s: 30 deg at 40, 15 at 20.
-- Tried and reverted 2026-09-19: YAW_KP/KD 0.01 and CRUISE_AIM_TAU 0.8 each
-- trimmed the cruise yaw swing a little (rms 25 -> 16.5 -> 13.9 deg/s) but
-- roll tracking went 3.8 -> 9.5 -> 11.9 deg rms (flightlogs 13-15-51,
-- 13-27-24, 13-33-44) - back to the default yaw gains and no aim smoothing.
-- 13-57-32 at 58 WITHOUT body lean (tune not yet pulled) tumbled on the
-- return leg: heading error grew to 70 deg from 40 b/s, thrust capped. So
-- 58 is marginal too, and the return leg always wobbles about twice as much.
--   CRUISE_BODY_LEAN 30  lean held on the body while the nose wobbles, so yaw
--                      stops moving the roll command: roll command swing 7.0
--                      -> 3.2 deg, heading error 8.6 -> 6.3, return leg steady
--                      for the first time (14-04-32, 22-38-47, 22-53-13). It
--                      costs ~11 b/s, which is why 62 is worth another go.
--   BRAKE_TURN_POWER   on test from 2026-09-20: 0.55 throttle while the craft
--                      swings from the cruise lean to the brake lean, so the
--                      thrusters keep the torque to turn with. The first 3 s
--                      of a brake from 200 took off only 10-20 b/s
-- 2026-09-19 night, 11 legs measured in 5 s slices: at 58 the roll swing
-- grows slowly and settles around 8-9 deg; at 62 it grows about half as fast
-- again every 5 s (2.6 -> 4.6 -> 7.6 on the calmest leg, 9.6 -> 20.3 on the
-- worst) and tumbled twice. 62 is divergent on this frame, so 58 it is - the
-- good 62 legs were short ones that ended before the swing had grown.
--   LAND_SETTLE_XZ 4   a taxi ride landed 26 blocks from the customer: level
--                      and stopped was enough to start the descent, wherever
--                      it had stopped (02-35-46). Now it closes to 4 blocks
--                      first; LAND_SETTLE_MAX still forces it down after 10 s
--   LAND_SETTLE_MAX 40 the 10 s default ran out on every ride of 2026-09-25:
--                      the brake hands over 45-111 blocks short and already
--                      drifting back at ~10 b/s, closing that takes 12-16 s,
--                      so it dropped 12-33 blocks out still moving 7-13 b/s
--                      and touched down 7-19 off (01-03-25, 01-24-01,
--                      01-40-27). The fall itself can hardly correct (0.12
--                      thrust floor, 8 deg cap, 3 in the flare). 40 s lets
--                      it close to 4 blocks and stop before it drops.
--   LAND_REST_GAP 7.5  the altimeter rests 5.5-7.5 above the pad block (rules
--                      5.5, spawn 6.5, c_district 7.5), and the descent aimed
--                      at the block: every pad landing of 2026-09-25 touched
--                      down 3.5-5.5 blocks before its flare, at 14-18 b/s
--                      (04-02-28, 04-31-17, 04-35-26, 04-38-49). The largest
--                      gap, so the worst case is ~2 s more creep, never an
--                      early contact.
--   BRAKE_MAP          back to the 2026-09-20 map after a one-flight refit
--                      (7986a21, 09-28). The refit read the ~90-block gap at
--                      the end of every brake as stopping SHORT and started
--                      brakes ~65 blocks later. Split along and across the
--                      route, the old map already stopped on the mark along
--                      it (20 flights of the 3,669-block route: median +7,
--                      -76..+121); the gap is SIDEWAYS - the brake swings the
--                      craft 80-130 blocks to the same side every time, from
--                      ~20 off the line at brake start. The first flight on
--                      the refit (07-49-24) ran 198 PAST and took 26 s to
--                      close back, 98.9 s against 88. The sideways swing is
--                      the real target, and it is flight code, not this map.
--   BRAKE_SIDE_K       tried 2026-09-28 at 1.5 for one flight (08-11-54) and
--                      removed: the brake's sideways speed was 7-14 b/s as
--                      before and it moved 73 blocks across its path (61 the
--                      flight before). During the brake the attitude misses
--                      its command by 20-30 deg; a 15-deg correction is lost
--                      in that. Off (fly.lua default 0).
--   YAW_MAX_LEAN 0.8   on test from 2026-09-28 (was 0.6). The cruise wobble -
--                      a ~1.8 s heading swing in nearly every cruise, growing
--                      with speed - tracks the yaw demand sitting on this
--                      clamp: calm cruises never reach it (peak 0.14-0.28),
--                      normal ones sit on 0.6 for 4-39% of the late cruise,
--                      and the three that reached 83-87 deg of tilt (09-27
--                      06-38-38, 06-46-11; 09-28 08-11-54) for 48-73%, with
--                      the thrust cap hit as well. The yaw runs out of
--                      authority as the air's yaw moment grows with speed.
--                      It only acts when the demand is past 0.6, so a calm
--                      cruise flies as before. Revert: back to 0.6.
return {
  YAW_MAX_LEAN = 0.8,
  BRAKE_EASE = 60,
  YAW_OFFSET = 225,
  CRUISE_DEG = 58,
  CRUISE_BODY_LEAN = 30,
  LAND_SETTLE_XZ = 4,
  LAND_SETTLE_MAX = 40,
  LAND_REST_GAP = 7.5,
  BRAKE_TURN_POWER = 0.55,
  BRAKE_MAP = "40:170,55:265,80:420,110:560,135:800,150:950,175:1100,190:1180,205:1280",
}
