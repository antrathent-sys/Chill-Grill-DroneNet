-- The server craft (hand-built airframe2: 4 thrusters, 2 sails a side
-- below the CoG, ballast to ~73 mass, tables 1/2/3). startup installs this
-- as tune.lua on the computer labelled (or numbered) drone-1; fly loads it
-- over CFG and prints what it took. Values from 2026-09-19:
--   YAW_MAX_LEAN 0.6   the yaw ran away both ways at 45-60 b/s with 0.3
--   YAW_OFFSET 225     puts the lean on the pitch/roll diagonal; 260 put it
--                      mostly on roll and the gimbal let go past ~75 deg
--   CRUISE_DEG 62      62 (13-49) topped out lower at 185, roll swing grew to 60+ deg, thrust
--                      hit the 0.80 cap and it tumbled at 150 b/s: 58 is the ceiling on this frame
--   BRAKE_MAP          31 measured brakes, blocks needed from each speed. The
--                      top two points raised 2026-09-19: at 62 deg the craft
--                      reaches 204 and the brakes from 188-204 ran 124-163
--                      blocks long (22-38-47, 23-06-53)
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
return {
  YAW_MAX_LEAN = 0.6,
  BRAKE_EASE = 60,
  YAW_OFFSET = 225,
  CRUISE_DEG = 62,
  CRUISE_BODY_LEAN = 30,
  BRAKE_TURN_POWER = 0.55,
  BRAKE_MAP = "40:170,55:265,80:420,110:560,135:720,160:950,190:1180,205:1330",
}
