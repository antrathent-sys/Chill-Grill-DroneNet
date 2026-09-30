-- dock.example.lua: a two-sided loading dock (lib/dockseq.lua), A and B.
-- Copy it into this depot's own folder in the repo as
-- machines/depot-<dock>/dock.lua (startup puts it on the computer), and fill
-- in your own names. `depot probe map` finds which relay does what and writes
-- relays.lua beside it; machines/test-dock/dock.lua is a worked example.
--
-- With a dock.lua, `depot` runs the base's loads and unloads on it - a flight
-- of two silos loads A and B at once, with one stick for both - and `depot
-- seq load A` (or B, or AB) runs one by hand. Per side, a load: stage its silo's share from the intake into the
-- side's storage; place and assemble a silo if none is waiting; fill it
-- through the belt; print its invoice into the storage for the belt to carry
-- in after the goods; push up, the drone sticks it, pusher down. An unload:
-- push up, the drone lets go, pusher down, empty it into storage.
return {
  sides = {
    A = {
      place = "redstone_relay_10",      -- places a silo (on the FALLING edge: pulsed)
      assemble = "redstone_relay_12",   -- deploys and fires a Physics Assembler
      pusher = "redstone_relay_7",      -- lifts the silo to the drone, and back down
      belt = "redstone_relay_2",        -- the funnel belt: into the silo, or out of it
      storage = "create:item_vault_2",  -- the vault this side's belt fills from and empties into
      feed = "minecraft:chest_1",       -- silo blocks for the placer (a payload takes 3)
    },
    B = {
      place = "redstone_relay_11", assemble = "redstone_relay_13", pusher = "redstone_relay_9",
      belt = "redstone_relay_1", storage = "create:item_vault_0", feed = "minecraft:chest_2",
    },
  },
  belt_on = "fills",                    -- what a belt relay ON does: "fills" the silo, or "empties" it

  -- a silo sensor per side, when there is one (optical_sensor or laser_sensor)
  -- detect = { A = "optical_sensor_7", B = "optical_sensor_6" },
  -- silo_when = "high",                -- the sensor reads high when a silo is there

  -- the drone's sticker that faces each side when it is latched here
  -- (orientation matters: it must dock the same way round every time)
  stick = { A = "Create_Sticker_0", B = "Create_Sticker_1" },

  -- where an order's goods are staged from: each flight moves each silo's
  -- share out of here into that side's storage before the fill. Leave it out
  -- and whatever is already in a side's storage is what gets loaded.
  -- intake = "create:item_vault_5",

  -- the invoice printer, when it is not the first one on the network
  -- printer = "printer_0",

  -- seconds; generous is fine to start with, trim once it is proven
  wait = { pulse = 1, assemble_hold = 1, place = 3, assemble = 4, push = 3, retract = 3, step = 1 },
  fill = { settle = 5, start = 20, max = 180 },    -- still for `settle` s = done; nothing by `start` = stuck
  empty = { settle = 5, start = 20, max = 240 },
}
