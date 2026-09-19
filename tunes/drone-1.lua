-- The server craft (hand-built airframe2: 4 thrusters, 2 sails a side
-- below the CoG, ballast to ~73 mass, tables 1/2/3). startup installs this
-- as tune.lua on the computer labelled (or numbered) drone-1; fly loads it
-- over CFG and prints what it took. Values from 2026-09-19:
--   YAW_MAX_LEAN 0.6   the yaw ran away both ways at 45-60 b/s with 0.3
--   YAW_OFFSET 225     puts the lean on the pitch/roll diagonal; 260 put it
--                      mostly on roll and the gimbal let go past ~75 deg
--   CRUISE_DEG 58      62 bought 7 b/s and brought back a roll swing
--   BRAKE_MAP          31 measured brakes, blocks needed from each speed
--   YAW_KP/YAW_KD 0.01 half the defaults: yaw twist scales with throttle and
--                      the defaults suit hover (~0.27); at cruise (~0.52) the
--                      yaw rang at 1.9 s, +-40 deg/s, demand bang-bang at
--                      +-0.6 (flightlog 13-19-39)
return {
  YAW_MAX_LEAN = 0.6,
  YAW_OFFSET = 225,
  CRUISE_DEG = 58,
  BRAKE_MAP = "40:170,55:265,80:420,110:560,135:720,160:950,190:1110",
  YAW_KP = 0.01,
  YAW_KD = 0.01,
}
