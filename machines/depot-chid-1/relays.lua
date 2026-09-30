-- relay map for depot-chid-1, from `depot probe map` 2026-09-30 07:42
-- device: place | assemble | belt | pusher; on: what ON does
return {
  { relay = "redstone_relay_0", device = "belt", side = "B", on = "fills" },
  { relay = "redstone_relay_1", device = "assemble", side = "B" },
  { relay = "redstone_relay_2", device = "belt", side = "A", on = "fills" },
  { relay = "redstone_relay_3", device = "assemble", side = "A" },
  { relay = "redstone_relay_4", device = "pusher", side = "A", on = "up" },
  { relay = "redstone_relay_5", device = "pusher", side = "B", on = "up" },
  { relay = "redstone_relay_6", device = "place", side = "B", on = "places" },
  { relay = "redstone_relay_7", device = "place", side = "A", on = "places" },
}
