-- relay map for test-dock, from `depot probe map` 2026-09-24 20:41
-- device: place | assemble | belt | pusher; on: what ON does
return {
  { relay = "redstone_relay_1", device = "none" },
  { relay = "redstone_relay_2", device = "none" },
  { relay = "redstone_relay_5", device = "pusher", on = "up" },
  { relay = "redstone_relay_6", device = "assemble", side = "A" },
  { relay = "redstone_relay_7", device = "pusher", side = "A", on = "up" },
  { relay = "redstone_relay_8", device = "assemble", side = "B" },
  { relay = "redstone_relay_9", device = "pusher", side = "B", on = "up" },
  { relay = "redstone_relay_10", device = "place", side = "A", on = "places" },
  { relay = "redstone_relay_11", device = "place", side = "B", on = "places" },
}
