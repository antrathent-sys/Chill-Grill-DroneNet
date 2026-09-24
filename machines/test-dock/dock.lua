-- test-dock: the two-sided loading dock in the test world.
-- Relays from `depot probe map` 2026-09-24 21:35 (relays.lua beside this);
-- the order of each job is Alex's, 2026-09-24. Read by lib/dockseq.lua.
--
-- Belts never stop: HIGH loads into the cargo, LOW unloads. The walk showed
-- each belt draining its own side's storage when it went HIGH - relay 2
-- emptied item_silo_2 (A), relay 1 emptied item_silo_0 (B) - which is how
-- each side's storage is known.
--
-- SENSORS: optical_sensor_7 watches A and optical_sensor_6 watches B.
--           Proven 22:42: firing A's placer turned sensor 7 from no hit (air,
--           15.5 away) to a hit on create_connected:item_silo at 0.52. So a
--           HIT means a silo is there - not inverted; the earlier readings
--           only looked inverted with the sides the wrong way round.
--           Known: empty = no hit, placed = hit at 0.52 - so the sensor
--           decides whether a bay needs a silo, and confirms one was placed
--           (23:00 and 23:03 showed why: memory said an empty silo was
--           waiting, the sensor said none, and the sensor was right). Not yet
--           known: assembled - a physics object, which a ray may not see - so
--           the check after assembling only WATCHES, as do the checks around
--           the drone, which in test mode is a person pressing ENT.
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
  detect = { A = "optical_sensor_7", B = "optical_sensor_6" },
  silo_when = "high",      -- a silo when the sensor has a hit
  watch = { "assemble", "retract", "release" },   -- only log these checks, for now

  -- seconds. Generous on purpose for the first runs; trim once it is proven.
  wait = {
    pulse = 1,       -- how long the placer is pulsed
    assemble_hold = 3,  -- the assembler held on: 1 s did not finish the job (Alex, 2026-09-24)
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
