--- stock: what the factory holds, through a Create 6 Stock Ticker.
--
-- Stock Links on every storage vault at the factory put them all on one
-- logistics network, and a Stock Ticker tuned to it sees the lot as one
-- inventory. A wired modem on the ticker joins it to the depot computer's
-- network, and then two calls are all there is (Create's own source,
-- compat/computercraft StockTickerPeripheral):
--
--   stock(true)                        every item across every linked vault:
--                                      { [i] = { name, displayName, count, .. } }
--   requestFiltered(address, filter)   pack what matches and send it to a
--                                      packager with that address; returns how
--                                      many items went
--
-- One line of that source decides how requests are made here: a filter's
-- `_requestCount` is how many to send, and **without it the ticker sends every
-- matching item there is**. A request that forgets its count empties the
-- factory of that item. So nothing in this repo builds a filter by hand:
-- S.request is the only way to ask, and it refuses without a whole count above
-- zero, and anything over the cap it is given.
--
-- Both calls run on the main thread, one per tick, and the ticker only sees
-- storage whose chunks are loaded: a Stock Link drops out about 20 s after its
-- chunk unloads. Pure - the peripheral comes in through `call` - so
-- tools/test_stock.lua runs all of it on the desktop.

local S = {}

local function str(v) return type(v) == "string" and v ~= "" end

--- The ticker: the first peripheral that answers both stock and requestFiltered.
-- names is peripheral.getNames(); methods(name) is peripheral.getMethods or a
-- stand-in.
function S.findTicker(names, methods)
  for _, n in ipairs(names or {}) do
    local has = {}
    for _, m in ipairs(methods(n) or {}) do has[m] = true end
    if has.stock and has.requestFiltered then return n end
  end
  return nil
end

--- Everything the factory holds: { name, label, count, stack }, one per item id, most
-- first. The same item with different data inside (enchanted, named) arrives
-- as separate entries and is added together here - items are told apart by id,
-- as the catalogue does. Returns entries, or nil and why.
function S.read(ticker, call)
  local ok, t = pcall(call, ticker, "stock", true)
  if not (ok and type(t) == "table") then
    return nil, "the ticker did not answer: " .. tostring(t)
  end
  local byName, out = {}, {}
  for _, d in pairs(t) do
    if type(d) == "table" and str(d.name) then
      local e = byName[d.name]
      if not e then
        e = { name = d.name, label = str(d.displayName) and d.displayName or d.name, count = 0,
              stack = tonumber(d.maxCount) or 64 }
        byName[d.name] = e
        out[#out + 1] = e
      end
      e.count = e.count + math.floor(tonumber(d.count) or 0)
    end
  end
  table.sort(out, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a.name < b.name
  end)
  return out
end

--- Send `count` of `item` to the packager called `address` - the only way this
-- repo asks the ticker for anything. Refuses, without calling it, unless the
-- count is whole and above zero and no more than `cap` (one shipment, say).
-- Returns how many the ticker says it sent, or nil and why.
function S.request(ticker, call, address, item, count, cap)
  if not str(address) then return nil, "no address to send to" end
  if not str(item) then return nil, "no item" end
  count = tonumber(count)
  if not count or count < 1 or count ~= math.floor(count) then
    return nil, "a request needs a whole count above zero - without one the ticker sends every one there is"
  end
  if cap and count > cap then
    return nil, string.format("%d is more than the %d a request may ask for", count, cap)
  end
  local ok, sent = pcall(call, ticker, "requestFiltered", address, { name = item, _requestCount = count })
  if not ok then return nil, tostring(sent) end
  return math.floor(tonumber(sent) or 0)
end

return S
