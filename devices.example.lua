-- devices.example.lua: copy it to devices.lua on the base computer and edit.
--
--   copy devices.example.lua devices.lua
--   basectl find          the peripheral names on this computer
--   basectl               every device and its state
--   basectl hangar-door open
--
-- Peripheral and relay names below are examples; use the ones basectl find
-- shows. Delete the lines you do not have. The file only describes devices:
-- it runs with no access to anything.
return {
  -- a light on a Create Redstone Link, driven from a Redstone Relay face; no read-back
  { name = "hangar-lights", label = "Hangar lights", kind = "output",
    out = { relay = "redstone_relay_0", side = "top" } },

  -- a klaxon on this computer's own back face
  { name = "alarm", kind = "output", out = { side = "back" } },

  -- a simple door on a link, with a Redstone Contact that is powered when the
  -- door is CLOSED coming back on another link into the relay (invert: signal = off)
  { name = "side-door", kind = "output", labels = { "OPEN", "CLOSED" },
    out = { relay = "redstone_relay_0", side = "north" },
    status = { relay = "redstone_relay_0", side = "south", invert = true } },

  -- the hangar door: a Sequenced Gearshift driving a gantry 6 blocks, with a
  -- contact that reads true when it is fully closed
  { name = "hangar-door", kind = "gearshift", periph = "Create_SequencedGearshift_0", travel = 6,
    closed = { relay = "redstone_relay_1", side = "top" } },

  -- the main line, proved by a speedometer on the driven shaft
  { name = "main-line", kind = "speed", periph = "Create_RotationSpeedController_0",
    gauge = "Create_Speedometer_0", max = 128 },

  -- readings for the statistics screens
  { name = "su", label = "Kinetic stress", kind = "stress", periph = "Create_Stressometer_0" },
  { name = "power", kind = "energy", periph = "modular_accumulator_0", warn = 25 },
  { name = "lava", kind = "fluid", periph = "fluid_tank_0", capacity = 64000 },
  { name = "vault", kind = "items", periph = "create:item_vault_0" },
  { name = "heat", kind = "level", input = { relay = "redstone_relay_1", side = "west" } },
}
