--- orders: the order record (ORDERS.md) - one number from the order to the
-- last invoice.
--
--   C-0042      an order: what somebody asked for, and the promise made
--   C-0042.1    its first flight - the load id every depot message, every
--               cargo.csv row and the drone's drops already carry
--   C-0042-2    its second shipment - one silo, and the invoice riding in it
--
-- orders.log on the base is the truth: one line per event, appended, never
-- rewritten -
--
--   when,order,leg,event,key=value;key=value
--
-- and every order is rebuilt from it (O.replay). The events:
--
--   accepted    kind, who, to (x y z), lines (item amount stack|...), price
--   paid        amount, note
--   flight      leg = the flight: load, depot, drone, first (shipment), count
--   loaded      leg = the flight: s<n> = what was counted into shipment n,
--               at_<side> = which shipment that side's silo was
--   dropped     leg = the flight: shipment, ok, x, y, z
--   received    leg = the flight: shipment, depot, items - unloaded into a
--               depot's storage instead of dropped; it counts as delivered
--   failed      leg = the flight: why (the order stays open for another)
--   done        every shipment counted and dropped
--   cancelled   why
--
-- Shipments are planned from what is LEFT - what was ordered, minus what has
-- actually been counted into silos - so a short fill is made up on the next
-- flight (DELIVERIES.md, "Batching"). Values are escaped, so a name with a
-- comma in it cannot break a line.
--
-- Pure: text in, tables out. lib/invoice.lua packs the shipments (O.use).
-- tools/test_orders.lua runs all of it on the desktop.

local O = {}

O.LOG = "orders.log"
O.SLOTS = 60          -- stacks a 3x1 silo holds; one goes to its invoice (lib/invoice.lua)
O.PER_FLIGHT = 2      -- silos a flight carries on the dual loader
O.KINDS = { parcel = true, load = true }

local floor = math.floor
local I
function O.use(invoice) I = invoice end
local function inv()
  if not I then I = dofile("lib/invoice.lua") end
  return I
end

local function str(v) return type(v) == "string" and v ~= "" end
local function num(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

-- ------------------------------------------------------------ numbers

function O.format(n) return string.format("C-%04d", floor(n)) end
function O.number(id) return tonumber(tostring(id or ""):match("^C%-(%d+)$")) end
function O.loadId(order, flight) return tostring(order) .. "." .. floor(flight) end

--- "C-0042.1" -> "C-0042", 1; nil for anything else.
function O.parseLoad(load)
  local order, flight = tostring(load or ""):match("^(C%-%d+)%.(%d+)$")
  return order, tonumber(flight)
end

--- One past the highest number any order in the log has.
function O.nextId(orders)
  local top = 0
  for id in pairs(orders or {}) do top = math.max(top, O.number(id) or 0) end
  return O.format(top + 1)
end

-- ------------------------------------------------------------ the log

local function esc(v)
  return (tostring(v):gsub("[%%,;=\n\r]", function(c) return string.format("%%%02X", c:byte()) end))
end
local function unesc(v) return (tostring(v):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) end

--- One line of orders.log. kv: flat { key = value }, written in key order.
function O.encode(when, order, leg, event, kv)
  local keys = {}
  for k in pairs(kv or {}) do keys[#keys + 1] = k end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    if kv[k] ~= nil then parts[#parts + 1] = esc(k) .. "=" .. esc(kv[k]) end
  end
  return table.concat({ tostring(floor(tonumber(when) or 0)), esc(order), esc(leg or ""), esc(event),
                        table.concat(parts, ";") }, ",")
end

--- A line back: { when, order, leg, event, kv }, or nil.
function O.decode(line)
  local when, order, leg, event, rest = tostring(line or ""):match("^(%d+),([^,]*),([^,]*),([^,]*),?(.*)$")
  if not when then return nil end
  local kv = {}
  for pair in rest:gmatch("[^;]+") do
    local k, v = pair:match("^([^=]*)=(.*)$")
    if k then kv[unesc(k)] = unesc(v) end
  end
  return { when = tonumber(when), order = unesc(order), leg = unesc(leg), event = unesc(event), kv = kv }
end

--- lines <-> "minecraft:cobblestone 10000 64|minecraft:gravel 2000 64"
function O.packLines(lines)
  local out = {}
  for _, l in ipairs(lines or {}) do out[#out + 1] = string.format("%s %d %d", l.item, floor(l.amount), floor(l.stack or 64)) end
  return table.concat(out, "|")
end
function O.unpackLines(s)
  local out = {}
  for part in tostring(s or ""):gmatch("[^|]+") do
    local item, amount, stack = part:match("^(%S+) (%d+) (%d+)$")
    if item then out[#out + 1] = { item = item, amount = tonumber(amount), stack = tonumber(stack) } end
  end
  return out
end

-- counted items <-> "minecraft:cobblestone 3776|minecraft:gravel 12"
local function packCount(m)
  local names = {}
  for k in pairs(m or {}) do names[#names + 1] = k end
  table.sort(names)
  local out = {}
  for _, k in ipairs(names) do out[#out + 1] = k .. " " .. floor(m[k]) end
  return table.concat(out, "|")
end
local function unpackCount(s)
  local out = {}
  for part in tostring(s or ""):gmatch("[^|]+") do
    local item, n = part:match("^(%S+) (%d+)$")
    if item then out[item] = tonumber(n) end
  end
  return out
end
O.packCount, O.unpackCount = packCount, unpackCount

-- ------------------------------------------------------------ building

--- The event lines for the things that happen to an order.
function O.accepted(when, id, e)
  return O.encode(when, id, "", "accepted", { kind = e.kind or "parcel", who = e.who,
    to = e.to and string.format("%d %d %d", floor(e.to.x), floor(e.to.y), floor(e.to.z)) or nil,
    lines = e.lines and O.packLines(e.lines) or nil, price = e.price, note = e.note, items = e.items })
end
function O.paidLine(when, id, amount, note) return O.encode(when, id, "", "paid", { amount = floor(amount), note = note }) end
function O.flightLine(when, id, f, t)
  return O.encode(when, id, f, "flight", { load = O.loadId(id, f), depot = t.depot, drone = t.drone, first = t.first,
                                          count = t.count })
end
--- counted: { [shipment number] = { item = count } }; sides: { [side] = shipment }
function O.loadedLine(when, id, f, counted, how, sides)
  local kv = { how = how }
  for n, m in pairs(counted or {}) do kv["s" .. n] = packCount(m) end
  for side, n in pairs(sides or {}) do kv["at_" .. side] = n end
  return O.encode(when, id, f, "loaded", kv)
end
function O.droppedLine(when, id, f, shipment, ok, x, y, z)
  return O.encode(when, id, f, "dropped", { shipment = shipment, ok = ok and 1 or 0,
    x = x and floor(x), y = y and floor(y), z = z and floor(z) })
end
function O.failedLine(when, id, f, why) return O.encode(when, id, f, "failed", { why = why }) end
function O.receivedLine(when, id, f, shipment, depot, items)
  return O.encode(when, id, f, "received", { shipment = shipment, depot = depot, items = packCount(items) })
end
function O.doneLine(when, id) return O.encode(when, id, "", "done", {}) end
function O.cancelledLine(when, id, why) return O.encode(when, id, "", "cancelled", { why = why }) end

--- Check a new order. e: { kind, who, to = { x, y, z }, lines = { { item,
-- amount, stack } }, price }. Returns true, or nil and why.
function O.check(e)
  if type(e) ~= "table" then return nil, "no order" end
  if not O.KINDS[e.kind or "parcel"] then return nil, "kind is parcel or load" end
  if not str(e.who) then return nil, "who is it for?" end
  if (e.kind or "parcel") == "parcel" then
    if not (e.to and num(e.to.x) and num(e.to.y) and num(e.to.z)) then return nil, "to needs x y z" end
    if type(e.lines) ~= "table" or #e.lines == 0 then return nil, "what, and how many?" end
    for _, l in ipairs(e.lines) do
      if not str(l.item) or l.item:find("[%s|]") then return nil, "an item is named by its id" end
      if not (num(l.amount) and l.amount >= 1) then return nil, l.item .. ": how many?" end
      if not (num(l.stack) and l.stack >= 1) then return nil, l.item .. ": what does it stack to?" end
    end
    if not (num(e.price) and e.price >= 0) then return nil, "for how much?" end
  end
  return true
end

-- ------------------------------------------------------------ replaying

local function newOrder(id, when)
  return { id = id, n = O.number(id), kind = "parcel", lines = {}, price = 0, paid = 0, pays = {}, state = "accepted",
           at = when, flights = {}, shipped = {}, dropped = {}, events = {}, lastFlight = 0 }
end

local function apply(o, e)
  o.events[#o.events + 1] = e
  local kv, f = e.kv, tonumber(e.leg)
  if e.event == "accepted" then
    o.kind, o.who, o.price, o.note = kv.kind or "parcel", kv.who, tonumber(kv.price) or 0, kv.note
    o.items = tonumber(kv.items)
    local x, y, z = tostring(kv.to or ""):match("^(%-?%d+) (%-?%d+) (%-?%d+)$")
    if x then o.to = { x = tonumber(x), y = tonumber(y), z = tonumber(z) } end
    o.lines = O.unpackLines(kv.lines)
  elseif e.event == "paid" then
    local a = tonumber(kv.amount) or 0
    o.paid = o.paid + a
    o.pays[#o.pays + 1] = { amount = a, note = kv.note, when = e.when }
  elseif e.event == "flight" and f then
    o.flights[f] = { flight = f, load = kv.load, depot = kv.depot, drone = kv.drone, first = tonumber(kv.first) or 1,
                     count = tonumber(kv.count) or 1, state = "flying", at = e.when, sides = {} }
    o.lastFlight = math.max(o.lastFlight, f)
    if o.state == "accepted" then o.state = "active" end
  elseif e.event == "loaded" and f then
    local fl = o.flights[f]
    if fl then fl.state = "loaded" end
    for k, v in pairs(kv) do
      local n = tonumber(k:match("^s(%d+)$") or "")
      if n then o.shipped[n] = unpackCount(v) end
      local side = k:match("^at_(.+)$")
      if side and fl then fl.sides[side] = tonumber(v) end
    end
  elseif e.event == "dropped" and f then
    local n = tonumber(kv.shipment)
    if n then o.dropped[n] = kv.ok == "1" end
    local fl = o.flights[f]
    if fl then
      local all = true
      for k = fl.first, fl.first + fl.count - 1 do if o.shipped[k] and o.dropped[k] == nil then all = false end end
      if all then fl.state = "delivered" end
    end
  elseif e.event == "received" and f then
    local n = tonumber(kv.shipment)
    if n then
      o.dropped[n] = true
      o.received = o.received or {}
      o.received[n] = { depot = kv.depot, items = unpackCount(kv.items) }
    end
    local fl = o.flights[f]
    if fl then fl.state = "delivered" end
  elseif e.event == "failed" and f then
    local fl = o.flights[f]
    if fl then fl.state, fl.why = "failed", kv.why end
  elseif e.event == "done" then
    o.state = "done"
  elseif e.event == "cancelled" then
    o.state, o.why = "cancelled", kv.why
  end
end

--- Every order in the log: byId, and a list in the order they were taken.
function O.replay(text)
  local byId, list = {}, {}
  for line in tostring(text or ""):gmatch("[^\n]+") do
    local e = O.decode(line)
    if e and O.number(e.order) then
      local o = byId[e.order]
      if not o then
        o = newOrder(e.order, e.when)
        byId[e.order] = o
        list[#list + 1] = o
      end
      apply(o, e)
    end
  end
  return byId, list
end

-- ------------------------------------------------------------ the plan

--- What has been counted into silos so far: item -> count.
function O.counted(o)
  local out = {}
  for _, m in pairs(o.shipped) do
    for item, c in pairs(m) do out[item] = (out[item] or 0) + c end
  end
  return out
end

local function highest(t) local top = 0 for n in pairs(t) do top = math.max(top, n) end return top end

--- What is still to go: the order's lines less what has been counted.
function O.remaining(o)
  local have, out = O.counted(o), {}
  for _, l in ipairs(o.lines) do
    local left = l.amount - (have[l.item] or 0)
    if left > 0 then out[#out + 1] = { item = l.item, amount = left, stack = l.stack } end
  end
  return out
end

--- The shipments still to send (each a list of { item, amount }), and how
-- many shipments the whole order comes to as things stand.
function O.plan(o)
  local rest = inv().pack(O.remaining(o), O.SLOTS)
  return rest, highest(o.shipped) + #rest
end

function O.isOpen(o) return o.state == "accepted" or o.state == "active" end

--- A flight is in the air (or at the depot) that has not been counted or failed.
function O.flying(o)
  for _, fl in pairs(o.flights) do if fl.state == "flying" then return fl end end
  return nil
end

--- The next flight of an order: its number, load id, first shipment, how
-- many silos, what each holds, the items in all and the smallest stack, and
-- how many shipments the order comes to. nil and why when there is none.
function O.nextFlight(o)
  if not O.isOpen(o) then return nil, o.id .. " is " .. o.state end
  local busy = O.flying(o)
  if busy then return nil, busy.load .. " is not finished yet" end
  local rest, total = O.plan(o)
  if #rest == 0 then return nil, "everything is shipped" end
  local f = o.lastFlight + 1
  local silos = math.min(O.PER_FLIGHT, #rest)
  local out = { flight = f, load = O.loadId(o.id, f), first = highest(o.shipped) + 1, count = silos, silos = {},
                items = 0, total = total }
  local stacks = {}
  for _, l in ipairs(o.lines) do stacks[l.item] = l.stack end
  for k = 1, silos do
    out.silos[k] = rest[k]
    for _, it in ipairs(rest[k]) do
      out.items = out.items + it.amount
      out.stack = math.min(out.stack or 1e9, stacks[it.item] or 64)
    end
  end
  return out
end

--- The fields load.start carries so the depot can print each silo's
-- invoice from its own count (lib/invoice.lua I.fromFields). Flat, as the
-- sealed link wants.
function O.invoiceFields(o, fl, date)
  local f = { inv_order = o.id, inv_who = o.who, inv_total = floor(o.price or 0), inv_paid = floor(o.paid or 0),
              inv_date = date, inv_first = fl.first, inv_last = fl.total }
  if o.to then f.inv_x, f.inv_y, f.inv_z = o.to.x, o.to.y, o.to.z end
  if #o.lines == 1 then
    local l = o.lines[1]
    f.inv_item, f.inv_ordered, f.inv_before = l.item, l.amount, O.counted(o)[l.item] or 0
  else
    f.inv_multi = 1
  end
  return f
end

--- Which shipment a flight's silo is: the k-th silo loaded is shipment first + k - 1.
function O.shipmentOf(fl, k) return fl.first + k - 1 end

--- The shipment a load's silo on `side` was, once it has been counted.
function O.shipmentAt(o, f, side)
  local fl = o and o.flights[f]
  return fl and fl.sides and fl.sides[side] or nil
end

--- Every planned shipment counted, none still to go, and every one counted
-- has been let go of (or reported still held - then it is not done).
function O.complete(o)
  local rest = O.plan(o)
  if #rest > 0 or next(o.shipped) == nil then return false end
  for n in pairs(o.shipped) do if o.dropped[n] ~= true then return false end end
  return true
end

-- ------------------------------------------------------------ showing

local function thousands(n) return inv().thousands(n) end

--- "10,000 COBBLESTONE" / "5,000 COBBLESTONE +1 MORE"
function O.what(o)
  local l = o.lines[1]
  if not l then return o.items and (thousands(o.items) .. " ITEMS") or "--" end
  local s = thousands(l.amount) .. " " .. inv().itemName(l.item)
  if #o.lines > 1 then s = s .. " +" .. (#o.lines - 1) .. " MORE" end
  return s
end

--- One line for `ops orders`.
function O.summary(o)
  local rest, total = O.plan(o)
  local done = 0
  for n in pairs(o.shipped) do if o.dropped[n] then done = done + 1 end end
  local money = o.price > 0 and (o.paid >= o.price and "PAID" or ("OWES " .. thousands(o.price - o.paid))) or ""
  return string.format("%-7s %-10s %-9s %d/%d shipped  %s  %s", o.id, tostring(o.who or ""):sub(1, 10),
    o.state:upper(), done, total, money, O.what(o))
end

return O
