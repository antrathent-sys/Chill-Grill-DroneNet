-- depot-chid-1: the two-sided dock at CHID 1 (2497 71 -3297), CINDER's own.
-- Relays from `depot probe map` 2026-09-30 07:42 (relays.lua beside this).
-- Storage sides from Alex: item_silo_0 is A, item_silo_1 is B. Timings are
-- the test dock's proven ones; trim once this dock has run. Read by
-- lib/dockseq.lua.
--
-- The belt and assembler relays on each side light each other's inputs in
-- the walk: they share a modem, and it is fine (Alex, 2026-09-30).
-- SENSORS: optical_sensor_0 watches A, optical_sensor_1 watches B (Alex,
-- 2026-09-30). Sensor 0 read a placed silo as create_connected:item_silo at
-- 0.52; an empty bay reads air, or the deployer beyond it at 2.75, which is
-- a clear bay. B's placer put down the wrong block in the walk: its supply
-- needs silo blocks.
-- TO CHECK: the drone's sticker facing each side (stick), once LAMBDA-001
-- docks here - it must dock the same way round every time.
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
  -- the sensors decide placing and assembling; around the drone they are
  -- only logged until a real drone has taken a silo and given one back
  watch = { "retract", "release" },

  stick = { A = "Create_Sticker_0", B = "Create_Sticker_1" },   -- to check when LAMBDA-001 docks

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
