-- lib/stock.lua against a pretend Stock Ticker, shaped like Create's own:
-- stock(true) returns { [i] = { name, displayName, count, ... } }, and
-- requestFiltered(address, filter) sends whatever matches - ALL of it, unless
-- the filter carries _requestCount. So the test ticker does exactly that, and
-- the checks make sure no request can ever reach it without a count.
local DIR = ...
local pass, fail = 0, 0
local function check(n, c, d)
  if c then pass = pass + 1 print("  ok   " .. n)
  else fail = fail + 1 print("  FAIL " .. n .. (d and ("  " .. tostring(d)) or "")) end
end

local S = dofile(DIR .. "/../lib/stock.lua")

local HELD = { ["minecraft:cobblestone"] = 12400, ["minecraft:gravel"] = 900 }
local sentTo, filters = {}, {}
local function call(n, m, a, b)
  if n ~= "Create_StockTicker_0" then error("no such peripheral", 0) end
  if m == "stock" then
    return {
      [1] = { name = "minecraft:cobblestone", displayName = "Cobblestone", count = 12000 },
      [2] = { name = "minecraft:gravel", displayName = "Gravel", count = 900 },
      -- the same item with something inside it: a separate entry, same id
      [3] = { name = "minecraft:cobblestone", displayName = "Cobblestone", count = 400, nbt = "abc" },
      [4] = { name = "minecraft:iron_block", displayName = "Block of Iron", count = 1200 },
    }
  end
  if m == "requestFiltered" then
    sentTo[#sentTo + 1] = a
    filters[#filters + 1] = b
    local want = HELD[b.name] or 0
    if b._requestCount then want = math.min(want, b._requestCount) end   -- no count: EVERYTHING
    HELD[b.name] = (HELD[b.name] or 0) - want
    return want
  end
  error("no method " .. tostring(m), 0)
end
local METHODS = {
  ["redstone_relay_0"] = { "getInput", "setOutput" },
  ["minecraft:chest_0"] = { "list", "getItemDetail", "pushItems" },
  ["Create_StockTicker_0"] = { "stock", "getStockItemDetail", "requestFiltered", "list", "getItemDetail" },
}
local function methods(n) return METHODS[n] end

print("finding the ticker")
check("the one that answers stock and requestFiltered, not a chest or a relay",
  S.findTicker({ "minecraft:chest_0", "redstone_relay_0", "Create_StockTicker_0" }, methods) == "Create_StockTicker_0")
check("none on the network: nil", S.findTicker({ "minecraft:chest_0" }, methods) == nil)

print("")
print("reading the stock")
local e, why = S.read("Create_StockTicker_0", call)
check("every item across the linked vaults", e and #e == 3, why or (e and #e))
check("most first", e[1].name == "minecraft:cobblestone" and e[3].name == "minecraft:gravel")
check("the same item with different insides is added together, by id", e[1].count == 12400, e[1].count)
check("with the name the game shows", e[2].label == "Block of Iron")
local none, whyNot = S.read("Create_StockTicker_9", call)
check("a ticker that does not answer says so, rather than claiming an empty factory",
  none == nil and tostring(whyNot):find("did not answer", 1, true) ~= nil, whyNot)

print("")
print("asking it for items - never without a count")
local n = S.request("Create_StockTicker_0", call, "cinder-A", "minecraft:cobblestone", 3776)
check("a shipment's worth, to side A's packager", n == 3776 and sentTo[#sentTo] == "cinder-A", n)
check("the filter it sent always carries the count", filters[#filters]._requestCount == 3776
  and filters[#filters].name == "minecraft:cobblestone")
check("and the rest is still in the factory", HELD["minecraft:cobblestone"] == 12400 - 3776)
local before = #filters
local bad = {
  { nil, "no count" }, { 0, "zero" }, { -5, "negative" }, { 12.5, "a fraction" }, { "lots", "a word" },
}
local refused = 0
for _, b in ipairs(bad) do
  local r, w = S.request("Create_StockTicker_0", call, "cinder-A", "minecraft:cobblestone", b[1])
  if r == nil and w then refused = refused + 1 end
end
check("no count, zero, negative, a fraction or a word: all refused", refused == #bad, refused)
check("...without the ticker ever being called - so it can never send everything", #filters == before, #filters - before)
check("the refusal says why it matters",
  tostring(select(2, S.request("Create_StockTicker_0", call, "cinder-A", "minecraft:cobblestone"))):find("every one there is", 1, true) ~= nil)
check("more than the cap is refused too", S.request("Create_StockTicker_0", call, "cinder-A",
  "minecraft:cobblestone", 7553, 7552) == nil and #filters == before)
check("no address, or no item, is refused", S.request("Create_StockTicker_0", call, "", "minecraft:gravel", 10) == nil
  and S.request("Create_StockTicker_0", call, "cinder-B", nil, 10) == nil and #filters == before)
local short = S.request("Create_StockTicker_0", call, "cinder-B", "minecraft:gravel", 2000)
check("asking for more than the factory holds sends what there is, and says how many", short == 900, short)

print("")
print(string.format("%d passed, %d failed", pass, fail))
