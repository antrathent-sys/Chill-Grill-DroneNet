-- test-dock: the two-sided loading dock in the test world.
-- Relays from `depot probe map` 2026-09-24 20:41 (relays.lua beside this);
-- the order of each job is Alex's, 2026-09-24. Read by lib/dockseq.lua.
--
-- NOT MAPPED YET (the lasers are - see detect below):
--   belts   redstone_relay_1 and redstone_relay_2 moved nothing during the
--           walk - almost certainly the two belts, which show nothing with
--           empty storage. Until they are confirmed the belts are left alone
--           and run whichever way they already run. Once known, add
--           belt = "redstone_relay_N" to each side and set belt_on below.
--   relay 5 answered "pusher" with no side. Left out of both jobs.
--   storage the two 60-slot item silos are counted together, which is all a
--           one-side job needs to tell when items have stopped moving.
return {
  sides = {
    A = { place = "redstone_relay_10", assemble = "redstone_relay_6", pusher = "redstone_relay_7" },
    B = { place = "redstone_relay_11", assemble = "redstone_relay_8", pusher = "redstone_relay_9" },
  },
  storage = { "create_connected:item_silo_0", "create_connected:item_silo_2" },

  -- a laser across each bay (Create Avionics): a silo blocks the beam, so the
  -- dock SEES whether a bay has one instead of remembering. Alex, 2026-09-24:
  -- sensor 3 is A, 4 is B. `depot seq` says if a name is wrong.
  detect = { A = "laser_sensor_3", B = "laser_sensor_4" },
  silo_when = "blocked",

  -- what ON does to a belt, once the belts are mapped: "fills" or "empties"
  -- belt_on = "empties",

  -- seconds. Generous on purpose for the first runs; trim once it is proven.
  wait = {
    pulse = 1,       -- the assembler held on
    place = 4,       -- a silo placed: time to land
    assemble = 5,    -- assembled: time for the new physics object to settle
    push = 4,        -- pusher up
    retract = 4,     -- pusher down
    step = 2,        -- between steps
  },
  -- a fill or an empty is done when the storage has been still this long,
  -- stuck if nothing at all has moved by `start`, and stops at `max` anyway
  fill = { settle = 6, start = 30, max = 240 },
  empty = { settle = 6, start = 30, max = 300 },
}
