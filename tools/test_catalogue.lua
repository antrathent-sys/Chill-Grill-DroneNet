-- lib/catalogue.lua against pretend reference inventories: a chest and a
-- vault with some of the same items in each, one inventory that is not there,
-- and the names an order might use for an item.
local DIR = ...
local pass, fail = 0, 0
local function check(n, c, d)
  if c then pass = pass + 1 print("  ok   " .. n)
  else fail = fail + 1 print("  FAIL " .. n .. (d and ("  " .. tostring(d)) or "")) end
end

local C = dofile(DIR .. "/../lib/catalogue.lua")

-- what each inventory holds: slot -> { name, count }, and what getItemDetail says
local DETAIL = {
  ["minecraft:cobblestone"] = { displayName = "Cobblestone", maxCount = 64 },
  ["minecraft:light_gray_concrete_powder"] = { displayName = "Light Gray Concrete Powder", maxCount = 64 },
  ["minecraft:ender_pearl"] = { displayName = "Ender Pearl", maxCount = 16 },
  ["create:andesite_alloy"] = { displayName = "Andesite Alloy", maxCount = 64 },
  ["minecraft:andesite"] = { displayName = "Andesite", maxCount = 64 },
  ["othermod:andesite"] = { displayName = "Polished Andesite Brick", maxCount = 64 },
  ["minecraft:iron_pickaxe"] = { displayName = "Iron Pickaxe", maxCount = 1 },
}
local INV = {
  ["minecraft:chest_0"] = {
    [1] = { name = "minecraft:cobblestone", count = 1 },
    [4] = { name = "minecraft:ender_pearl", count = 3 },
    [9] = { name = "minecraft:light_gray_concrete_powder", count = 1 },
  },
  ["create:item_vault_0"] = {
    [1] = { name = "minecraft:cobblestone", count = 64 },      -- also in the chest
    [2] = { name = "create:andesite_alloy", count = 1 },
    [3] = { name = "minecraft:andesite", count = 1 },
    [7] = { name = "othermod:andesite", count = 1 },
    [8] = { name = "minecraft:iron_pickaxe", count = 1 },
  },
}
local calls = {}
local function call(inv, method, slot)
  calls[#calls + 1] = inv .. "." .. method
  local t = INV[inv]
  if not t then error("no such peripheral", 0) end
  if method == "list" then return t end
  if method == "getItemDetail" then
    local it = t[slot]
    return it and { name = it.name, count = it.count, displayName = DETAIL[it.name].displayName,
                    maxCount = DETAIL[it.name].maxCount } or nil
  end
end

print("reading the reference inventories")
local e, problems = C.read({ "minecraft:chest_0", "create:item_vault_0", "minecraft:chest_9" }, call)
check("a chest and a vault read together, each item once", #e == 7, #e)
check("an inventory that is not there is reported, and the rest still read",
  #problems == 1 and problems[1]:find("chest_9", 1, true) ~= nil, problems[1])
local byName = {}
for _, x in ipairs(e) do byName[x.name] = x end
check("the exact id, modded namespaces included", byName["create:andesite_alloy"] ~= nil)
check("the display name", byName["minecraft:light_gray_concrete_powder"].label == "Light Gray Concrete Powder")
check("the stack size, from the game - no guessing", byName["minecraft:ender_pearl"].stack == 16
  and byName["minecraft:iron_pickaxe"].stack == 1)
check("sorted by name, the way a catalogue reads", e[1].label == "Andesite" and e[#e].label == "Polished Andesite Brick",
  e[1].label .. " .. " .. e[#e].label)
local details = 0
for _, c in ipairs(calls) do if c:find("getItemDetail", 1, true) then details = details + 1 end end
check("an item already seen is not asked about again", details == 7, details)

print("")
print("the file")
local text = C.serialize(e, { "minecraft:chest_0", "create:item_vault_0" })
check("one entry a line, so a script that is not Lua can read it",
  select(2, text:gsub("{ name = ", "")) == 7 and text:find('{ name = "minecraft:ender_pearl", label = "Ender Pearl", stack = 16 },', 1, true) ~= nil)
local back, sources = C.parse(text)
check("it reads back the same", #back == 7 and back[1].name == e[1].name and back[3].stack == e[3].stack)
check("and remembers where it was read from, so `read` alone refreshes",
  #sources == 2 and sources[1] == "minecraft:chest_0" and sources[2] == "create:item_vault_0")
check("a broken file reads as empty, not an error", #(C.parse("return {")) == 0)
check("an empty catalogue is still a valid file", #(C.parse(C.serialize({}, {}))) == 0)

print("")
print("naming an item in an order")
check("the exact id", (C.find(e, "minecraft:cobblestone")) == byName["minecraft:cobblestone"])
check("the id without its namespace", (C.find(e, "cobblestone")) == byName["minecraft:cobblestone"])
check("the display name with underscores", (C.find(e, "light_gray_concrete_powder")) ==
  byName["minecraft:light_gray_concrete_powder"])
check("or with spaces, any case", (C.find(e, "Ender Pearl")) == byName["minecraft:ender_pearl"])
local none, twins = C.find(e, "andesite")
check("the same bare name in two mods is not guessed at - both are offered",
  none == nil and #twins == 2, twins and #twins)
check("the full id settles it", (C.find(e, "othermod:andesite")) == byName["othermod:andesite"])
local miss, near = C.find(e, "concrete")
check("something close offers what it might have meant", miss == nil and #near == 1
  and near[1].name == "minecraft:light_gray_concrete_powder")
local nothing, nope = C.find(e, "netherite_block")
check("something we do not sell is refused, with nothing to suggest", nothing == nil and #nope == 0)

print("")
print(string.format("%d passed, %d failed", pass, fail))
