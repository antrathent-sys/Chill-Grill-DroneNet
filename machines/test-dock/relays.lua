-- relay map for test-dock, from `depot probe map` 2026-09-24 21:35
-- device: place | assemble | belt | pusher; on: what ON does
return {
  { relay = "redstone_relay_1", device = "belt", side = "B", on = "fills" },
  { relay = "redstone_relay_2", device = "belt", side = "A", on = "fills" },
  { relay = "redstone_relay_5", device = "pusher", on = "up" },
  { relay = "redstone_relay_7", device = "pusher", side = "A", on = "up" },
  { relay = "redstone_relay_9", device = "pusher", side = "B", on = "up" },
  { relay = "redstone_relay_10", device = "place", side = "A", on = "places" },
  { relay = "redstone_relay_11", device = "place", side = "B", on = "places" },
  { relay = "redstone_relay_12", device = "assemble", side = "A" },
  { relay = "redstone_relay_13", device = "assemble", side = "B" },
}
