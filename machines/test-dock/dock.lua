-- test-dock: the two-sided loading dock in the test world.
-- Relays from `depot probe map` 2026-09-24 21:35 (relays.lua beside this);
-- the order of each job is Alex's, 2026-09-24. Read by lib/dockseq.lua.
--
-- Belts never stop: HIGH loads into the cargo, LOW unloads. The walk showed
-- each belt draining its own side's storage when it went HIGH - relay 2
-- emptied item_silo_2 (A), relay 1 emptied item_silo_0 (B) - which is how
-- each side's storage is known.
--
-- SENSORS: optical_sensor_6 on A and optical_sensor_7 on B (confirmed:
--           a silo in A read as a silo, empty B as clear, 22:40).
--           Taken as INVERTED - no hit means a silo. But a silo that is
--           only placed is an ordinary block and one that is assembled is a
--           physics object, and a ray may see the two differently, so for
--           now the sensors WATCH: every check logs what each one read and
--           whether that agrees, and memory decides. Once each state's
--           reading is known (empty, placed, assembled), take watch out.
-- PLACERS place on the falling edge (Alex, 2026-09-24): pulsed, then
--           `place` seconds for the silo to land.
-- NOT MAPPED YET:
--   relay 5 answered "pusher" with no side, twice. Left out of both jobs.
return {
  sides = {
    A = { place = "redstone_relay_10", assemble = "redstone_relay_12", pusher = "redstone_relay_7",
          belt = "redstone_relay_2", belt_on = "fills", storage = "create_connected:item_silo_2" },
    B = { place = "redstone_relay_11", assemble = "redstone_relay_13", pusher = "redstone_relay_9",
          belt = "redstone_relay_1", belt_on = "fills", storage = "create_connected:item_silo_0" },
  },
  detect = { A = "optical_sensor_6", B = "optical_sensor_7" },
  silo_when = "low",       -- a silo when the sensor has NO hit
  watch = true,            -- read and log the sensors, do not act on them yet

  -- seconds. Generous on purpose for the first runs; trim once it is proven.
  wait = {
    pulse = 1,       -- how long the assembler and the placer are pulsed
    place = 6,       -- after the placer's pulse: time for the silo to land
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
