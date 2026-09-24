-- test-dock: the two-sided loading dock in the test world.
-- Relays from `depot probe map` 2026-09-24 20:41 (relays.lua beside this);
-- the order of each job is Alex's, 2026-09-24. Read by lib/dockseq.lua.
--
-- BELTS: A's is redstone_relay_2, B's is redstone_relay_1 (Alex,
--           2026-09-24). HIGH loads items into the cargo, LOW unloads - said
--           of A's; B's is taken to be wired the same way.
-- NOT MAPPED YET:
--   relay 5 answered "pusher" with no side. Left out of both jobs.
--   storage the two 60-slot item silos are counted together, which is all a
--           one-side job needs to tell when items have stopped moving.
return {
  sides = {
    A = { place = "redstone_relay_10", assemble = "redstone_relay_6", pusher = "redstone_relay_7",
          belt = "redstone_relay_2", belt_on = "fills" },
    B = { place = "redstone_relay_11", assemble = "redstone_relay_8", pusher = "redstone_relay_9",
          belt = "redstone_relay_1", belt_on = "fills" },
  },
  storage = { "create_connected:item_silo_0", "create_connected:item_silo_2" },

  -- a laser sensor on each bay (Create Avionics), so the dock SEES whether a
  -- bay has a silo instead of remembering. Alex, 2026-09-24: sensor 1 is A,
  -- 6 is B, and they go LOW when there is no silo. `depot seq` shows each
  -- one's power, and says if a name is wrong.
  detect = { A = "laser_sensor_1", B = "laser_sensor_6" },
  silo_when = "high",


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
