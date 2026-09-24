-- test-dock: the two-sided loading dock in the test world.
-- Relays from `depot probe map` 2026-09-24 21:35 (relays.lua beside this);
-- the order of each job is Alex's, 2026-09-24. Read by lib/dockseq.lua.
--
-- Belts never stop: HIGH loads into the cargo, LOW unloads. The walk showed
-- each belt draining its own side's storage when it went HIGH - relay 2
-- emptied item_silo_2 (A), relay 1 emptied item_silo_0 (B) - which is how
-- each side's storage is known.
--
-- NOT MAPPED YET:
--   sensors optical_sensor_6 and optical_sensor_7 watch the bays, but which
--           is which, and how one says "a silo is here", is not known yet
--           (`depot probe` lists their methods). Until then there is no
--           detect below, and the dock goes by what it remembers - check
--           `depot seq` says what is really in each bay before a run, and
--           correct it with `depot seq silo A none`.
--   relay 5 answered "pusher" with no side, twice. Left out of both jobs.
return {
  sides = {
    A = { place = "redstone_relay_10", assemble = "redstone_relay_12", pusher = "redstone_relay_7",
          belt = "redstone_relay_2", belt_on = "fills", storage = "create_connected:item_silo_2" },
    B = { place = "redstone_relay_11", assemble = "redstone_relay_13", pusher = "redstone_relay_9",
          belt = "redstone_relay_1", belt_on = "fills", storage = "create_connected:item_silo_0" },
  },

  -- seconds. Generous on purpose for the first runs; trim once it is proven.
  -- place is how long the placer is held on: the map walk's 3 s saw no silo
  -- land, so this is longer
  wait = {
    pulse = 1,       -- the assembler held on
    place = 6,       -- the placer held on, for a silo to land
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
