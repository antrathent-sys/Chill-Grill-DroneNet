-- Desktop tests for lib/cargo.lua: counting inventories, the cargo.csv rows,
-- matching a drop to its load, and what `ops cargo` reads back.
local DIR = ...
local pass, fail = 0, 0
local function check(n, c, d)
  if c then pass = pass + 1 print("  ok   " .. n)
  else fail = fail + 1 print("  FAIL " .. n .. (d and ("  " .. tostring(d)) or "")) end
end

local C = dofile(DIR .. "/../lib/cargo.lua")
local D = dofile(DIR .. "/../lib/deliver.lua")

print("counting")
local list = { [1] = { name = "minecraft:cobblestone", count = 64 }, [3] = { name = "minecraft:cobblestone", count = 10 },
               [7] = { name = "minecraft:iron_ingot", count = 5 } }
local t = C.tally(list)
check("an inventory's slots, as item -> count", t["minecraft:cobblestone"] == 74 and t["minecraft:iron_ingot"] == 5)
check("an empty or unreadable one is nothing", next(C.tally({})) == nil and next(C.tally(nil)) == nil)
local gone = C.diff({ ["a:x"] = 100, ["a:y"] = 5, ["a:z"] = 1 }, { ["a:x"] = 40, ["a:y"] = 5, ["a:w"] = 9 })
check("what left the intake: only what went down", gone["a:x"] == 60 and gone["a:y"] == nil and gone["a:z"] == 1
  and gone["a:w"] == nil)
check("totals", C.total(t) == 79)
check("described biggest first, without the mod name", C.describe(t) == "74 cobblestone, 5 iron ingot", C.describe(t))
check("...and trimmed", C.describe({ ["a:p"] = 3, ["a:q"] = 2, ["a:r"] = 1 }, 2) == "3 p, 2 q, +1 more")
check("nothing is 'nothing'", C.describe({}) == "nothing")

print("where each silo is going")
local dest = C.destinations(D, "deliver pier and 100 80 50", { "Create_Sticker_1", "Create_Sticker_0" })
check("deliver A and B: the first sticker by name to A, the other to B",
  dest.Create_Sticker_0 == "pier" and dest.Create_Sticker_1 == "100 80 50", tostring(dest.Create_Sticker_0))
dest = C.destinations(D, "deliver pier", { "Create_Sticker_0", "Create_Sticker_1" })
check("one drop: both silos there", dest.Create_Sticker_0 == "pier" and dest.Create_Sticker_1 == "pier")
dest = C.destinations(D, "ferry depot", { "Create_Sticker_0" })
check("anything else: the command itself", dest.Create_Sticker_0 == "ferry depot")
dest = C.destinations(D, nil, { "Create_Sticker_0" })
check("no liftoff: no destination yet", dest.Create_Sticker_0 == "")

print("the rows")
local rows = C.loadedRows(1000, "L1000", "drone-1", {
  { silo = "left", sticker = "Create_Sticker_0", items = { ["minecraft:cobblestone"] = 640, ["minecraft:iron_ingot"] = 64 } },
  { silo = "right", sticker = "Create_Sticker_1", items = {} },
}, { Create_Sticker_0 = "pier", Create_Sticker_1 = "market" })
check("one loaded row per item per silo, and one for a silo that was not counted", #rows == 3)
check("the columns line up with the header", select(2, rows[1]:gsub(",", "")) == select(2, C.HEADER:gsub(",", "")))
local parsed = C.parse(C.HEADER .. "\n" .. table.concat(rows, "\n") .. "\n")
check("and read back", #parsed == 3 and parsed[1].item == "minecraft:cobblestone" and parsed[1].count == 640
  and parsed[1].dest == "pier" and parsed[3].item == "?" and parsed[3].silo == "right", parsed[1] and parsed[1].item)
local evil = C.loadedRows(1, "L1", "d", { { silo = "left", sticker = "s", items = { ["a:x"] = 1 } } }, { s = "a, b\nc" })
check("a comma or newline in a field cannot shift the columns", #C.parse(evil[1]) == 1 and C.parse(evil[1])[1].state == "loaded")

print("which load a drop belongs to")
local text = C.HEADER .. "\n" .. table.concat(rows, "\n") .. "\n"
local load, silo, where = C.openFor(C.parse(text), "drone-1", "Create_Sticker_0")
check("the load that put a silo on that sticker", load == "L1000" and silo == "left" and where == "pier")
check("not another drone's", C.openFor(C.parse(text), "drone-2", "Create_Sticker_0") == nil)
text = text .. C.dropRow(1100, "L1000", "drone-1", "left", "Create_Sticker_0", "pier", true, 100.7, 80.2, 50.9) .. "\n"
check("once dropped, that silo is closed", C.openFor(C.parse(text), "drone-1", "Create_Sticker_0") == nil)
check("...the other silo of the load is still open", (C.openFor(C.parse(text), "drone-1", "Create_Sticker_1")) == "L1000")
local later = C.loadedRows(2000, "L2000", "drone-1", { { silo = "left", sticker = "Create_Sticker_0", items = { ["a:x"] = 1 } } }, {})
text = text .. later[1] .. "\n"
check("a newer load on the same sticker is the open one", (C.openFor(C.parse(text), "drone-1", "Create_Sticker_0")) == "L2000")
local both = C.loadedRows(3000, "L3000", "drone-3", { { silo = "left+right", sticker = "Create_Sticker_0+Create_Sticker_1",
  items = { ["a:x"] = 9 } } }, {})
check("a silo pair counted together matches either sticker",
  (C.openFor(C.parse(both[1]), "drone-3", "Create_Sticker_1")) == "L3000")

print("what ops cargo shows")
local sum = C.summary(C.parse(text), 10)
check("loads in order, oldest first", #sum == 2 and sum[1].load == "L1000" and sum[2].load == "L2000")
local left = sum[1].silos[1]
check("each silo with its items, where it was going, and its drop", left.silo == "left" and left.items["minecraft:iron_ingot"] == 64
  and left.dest == "pier" and #left.drops == 1 and left.drops[1].state == "delivered" and left.drops[1].x == 100)
check("a silo not dropped yet has no drop", #sum[1].silos[2].drops == 0)
check("the newest n only", #C.summary(C.parse(text), 1) == 1 and C.summary(C.parse(text), 1)[1].load == "L2000")
local held = C.parse(C.dropRow(1, "L", "d", "left", "s", "", false, 1, 2, 3))
check("a sticker that stayed out is held, not delivered", held[1].state == "held")

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then error("cargo tests failed", 0) end
