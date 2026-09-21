-- station.example.lua: the loading station at the dock. Copy it to station.lua
-- on the base computer (the one that runs ops) and fill in your own relays;
-- station.lua is not in the repo. `ops load` checks it and lists what it found.
--
-- A load runs:  place -> fill -> assemble -> dock -> lift -> stick -> retract -> liftoff
--
-- Every machine action is one Redstone Relay face: { relay = "<name>", side = "<face>" }.
-- The relay must be on this computer's wired network (its name is what
-- `peripheral.getNames()` shows once its modem is switched on). A face of this
-- computer itself is { side = "back" }. Per face, optionally:
--   pulse = 1.0     hold the signal this long for this face (default `pulse` below)
--   hold = true     switch on and STAY on until the lifter comes down (a lift
--                   that has to be held up; retract can then be left out)
--   invert = true   the machine is stopped BY the signal (a Create deployer or
--                   clutch): rests on, and the action switches it off
-- An action can have a face per bay - { left = {...}, right = {...} } - or one
-- face shared by both, which fires once.
return {
  -- the dock the drone latches onto to be loaded (a place: ops place add ... dock)
  dock = "home",

  -- stacks one silo holds. A 3x1 Create item vault is 3 blocks x 20 stacks = 60
  -- (3,840 of a 64-stack item). Only change it if the server's vaultCapacity is
  -- not the default 20.
  capacity = 60,

  -- place a silo in each bay the load needs: one silo goes in `single`, two
  -- use both. A single silo hangs off one side of the drone.
  place = {
    left  = { relay = "redstone_relay_0", side = "top" },
    right = { relay = "redstone_relay_1", side = "top" },
  },
  single = "left",

  -- how a fill is known to be done - pick ONE:
  --   { secs = 30 }                                a fixed time
  --   { intake = "minecraft:chest_0" }             until the load has left the
  --                                                intake (it also counts the load,
  --                                                so `ops load run drone-1` needs no number)
  --   { inv = { "create:item_vault_0", ... } }     until the silos hold the load
  --   { input = { relay = "redstone_relay_4", side = "back" }, level = 15 }
  --                                                until a signal (threshold switch,
  --                                                comparator) reaches the level
  -- settle = 2 waits that long after, for items still on a belt or in a funnel
  fill = { secs = 30 },

  -- a deployer clicking each Physics Assembler (redstone alone does nothing to
  -- one, and each click toggles, so it must fire once)
  assemble = {
    left  = { relay = "redstone_relay_2", side = "top" },
    right = { relay = "redstone_relay_2", side = "bottom" },
  },

  -- the lifter up to the drone, and back down
  lift    = { relay = "redstone_relay_3", side = "top" },
  retract = { relay = "redstone_relay_3", side = "bottom" },

  -- the drone's stickers above each bay, by the names ITS computer sees them
  -- under (run `stickers` on the drone)
  stick = { left = "Create_Sticker_0", right = "Create_Sticker_1" },

  -- seconds: `pulse` is how long an action's signal is held; `wait` is the pause
  -- after each action before the next. fill and dock are how long to wait at
  -- most before the load is called off.
  pulse = 0.5,
  wait = { place = 2, assemble = 2, lift = 3, stick = 2, retract = 3, fill = 120, dock = 300 },

  -- what the drone flies once loaded; leave it out and it stays on the dock,
  -- loaded, until you send it. A load can name its own after the item count:
  -- ops load run drone-1 5000 deliver pier and market   (a silo at each)
  -- liftoff = "deliver pier",
}
