-- DroneNet places, one per line. kind = "dock" is a built facility the
-- craft latches onto and charges at; kind = "pad" is somewhere it is
-- simply safe to land. A craft FERRIES to a dock and LANDS at a pad.
-- x, y, z are F3 block coordinates and y is the PAD block, the same
-- number `fly dock <x> <y> <z>` takes. trimX/trimZ shift the park point
-- for a pad whose connector is not under the centre of mass; cruiseY is
-- the altitude to travel there at. label is what customers see it called
-- Written by `fly pad add <name> [dock|pad]` and `ops place add`, and
-- safe to edit by hand.
return {
  { name = "c_district", kind = "pad", x = 4242, y = 63, z = -3269 },
  { name = "spawn", kind = "pad", x = 958, y = 71, z = 505 },
}
