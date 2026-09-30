-- depot-chid-1: the two-sided dock at CHID 1 (2497 71 -3297), CINDER's own.
-- Relays from `depot probe map` 2026-09-30 07:42 (relays.lua beside this).
-- Storage sides from Alex: item_silo_0 is A, item_silo_1 is B. Timings are
-- the test dock's proven ones; trim once this dock has run. Read by
-- lib/dockseq.lua.
--
-- TO CHECK before the first load with a drone:
--  1. BELT AND ASSEMBLER SHARE A POWERED BLOCK on each side. In the walk,
--     the belt relay on lit the assembler relay's input, and the assembler
--     relay on lit the belt relay's (0 and 1 on B, 2 and 3 on A). The test
--     dock showed nothing like it. If the belt relay also works the
--     assembler, every fill keeps the assembler powered. Fire each alone and
--     watch the other machine: `depot probe fire redstone_relay_0` (B's belt)
--     and `depot probe fire redstone_relay_2` (A's).
--  2. WHICH SENSOR WATCHES WHICH BAY. The only sensor change in the walk was
--     optical_sensor_0 seeing a silo land during relay 7 (A's placer). But
--     placers place on the falling edge, and B's silo from relay 6 may have
--     landed late, inside relay 7's window. Guessed A = sensor 0; `watch`
--     logs the sensors without letting them stop a job until it is proven.
--  3. THE DRONE'S STICKER FACING EACH SIDE (stick), once LAMBDA-001 docks
--     here: it must dock the same way round every time.
-- NOT ON THE NETWORK YET: the printer (invoices), the feed chests, the intake.
return {
  sides = {
    A = { place = "redstone_relay_7", assemble = "redstone_relay_3", pusher = "redstone_relay_4",
          belt = "redstone_relay_2", belt_on = "fills", storage = "create_connected:item_silo_0" },
    B = { place = "redstone_relay_6", assemble = "redstone_relay_1", pusher = "redstone_relay_5",
          belt = "redstone_relay_0", belt_on = "fills", storage = "create_connected:item_silo_1" },
  },
  detect = { A = "optical_sensor_0", B = "optical_sensor_1" },
  silo_when = "high",      -- a silo when the sensor hits the silo block (anything else is a clear bay)
  watch = true,            -- log the sensors, go by memory, until check 2 is done

  stick = { A = "Create_Sticker_0", B = "Create_Sticker_1" },   -- check 3

  -- seconds, from the test dock (2026-09-24)
  wait = {
    pulse = 1,          -- how long the placer is pulsed
    assemble_hold = 3,  -- the assembler held on: 1 s did not finish the job
    place = 6,          -- after the placer's pulse: time for the silo to land
    assemble = 5,       -- assembled: time for the new physics object to settle
    push = 4,           -- pusher up
    retract = 4,        -- pusher down
    step = 2,           -- between steps
  },
  -- a fill or an empty is done when the storage has been still this long,
  -- stuck if nothing at all has moved by `start`, and stops at `max` anyway
  fill = { settle = 6, start = 30, max = 240 },
  empty = { settle = 6, start = 30, max = 300 },
}
