--- invoice: the page that rides in every silo.
--
-- A regular invoice: who is billed and where the goods go, what was ordered,
-- what this shipment holds, what was shipped before it and what is still to
-- follow, and the money. An order of one thing gets all of that; an order of
-- several gets a packing list of what is in this silo. Every silo of an order is a shipment, numbered across
-- the whole order (SHIPMENT 2 OF 3), because that is what the customer
-- receives: three vaults, each saying which one it is. How the shipments were
-- grouped into flights is ours to know, not theirs.
--
-- Laid out for a CC printed page, which is 25 columns by 21 lines and not a
-- character more. The base composes the page from the order and sends the
-- lines to the depot in load.start; the depot only prints what it is given
-- (DELIVERIES.md). Pure, so tools/test_invoice.lua renders every case on the
-- desktop and checks it fits.

local I = {}

I.W, I.H = 25, 21

local RULE = string.rep("-", I.W)

--- 10000 -> "10,000"
function I.thousands(n)
  local s = tostring(math.floor(tonumber(n) or 0))
  local sign, digits = s:match("^(-?)(%d+)$")
  if not digits then return s end
  local out = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  if out:sub(1, 1) == "," then out = out:sub(2) end
  return sign .. out
end

--- Exact, in the smallest coin. An invoice is not the place to round.
function I.money(spurs)
  spurs = math.floor(tonumber(spurs) or 0)
  if spurs == 0 then return "NO CHARGE" end
  return I.thousands(spurs) .. " SPUR"
end

--- "minecraft:cobblestone" -> "COBBLESTONE"; "oak_log" -> "OAK LOG"
function I.itemName(item)
  local s = tostring(item or "?"):gsub("^[%w_]+:", ""):gsub("_", " ")
  return s:upper():sub(1, I.W)
end

--- A label on the left and its value on the right, exactly I.W wide. A
-- number too long to share the line keeps every digit and the label gives way;
-- a name (cut = true) is shortened instead, so its label always survives.
local function row(label, value, cut)
  label = tostring(label):upper()
  value = tostring(value):upper()
  if cut then value = value:sub(1, I.W - #label - 1) end
  value = value:sub(1, I.W)
  local room = I.W - #value - 1
  if room < 1 then return value end
  if #label > room then label = label:sub(1, room) end
  return label .. string.rep(" ", I.W - #label - #value) .. value
end

--- The number a customer quotes: the order and its shipment, "C-0042-2".
function I.number(order, shipment)
  return string.format("%s-%d", tostring(order), math.floor(tonumber(shipment) or 0))
end

--- The page. inv:
--   order      "C-0042"                 the order's number
--   shipment   2, shipments 3          this silo, and how many the order has
--   date       "2026-09-28"
--   who        "steve"                  billed to
--   x, y, z                             where it goes
--   total      1500                     the agreed price, spurs
--   paid       1500                     received so far, spurs
-- and then either ONE item, laid out in full:
--   item       "cobble"
--   ordered    10000
--   before     3776                     counted into the shipments before this
--   this       3776                     counted into this one
-- or SEVERAL, as a packing list of what is in this silo:
--   items      { { item = "cobble", this = 1224 }, { item = "gravel", this = 2000 } }
--   complete   true on the order's last shipment
-- Returns the page title (what the printed page is called as an item) and the
-- lines, never more than I.H of them, never wider than I.W.
I.ITEM_LINES = 4          -- item lines a several-item page has room for

function I.page(inv)
  local total = math.floor(tonumber(inv.total) or 0)
  local paid = math.floor(tonumber(inv.paid) or 0)
  local due = total - paid
  local no = I.number(inv.order, inv.shipment)

  local lines = {
    "CINDER",
    "TRANSIT DIRECTORATE",
    row("INVOICE", no),
    row("SHIPMENT", string.format("%d OF %d", math.floor(tonumber(inv.shipment) or 0),
      math.floor(tonumber(inv.shipments) or 0))),
    row("DATE", inv.date or ""),
    row("BILL TO", inv.who or "", true),
    row("SHIP TO", string.format("%d %d %d", math.floor(tonumber(inv.x) or 0),
      math.floor(tonumber(inv.y) or 0), math.floor(tonumber(inv.z) or 0))),
  }
  local function add(l) lines[#lines + 1] = l end

  if type(inv.items) == "table" then
    -- several items: what is physically in THIS silo, then whether more of the
    -- order is coming. Each item's running total is on the base (`ops order`);
    -- the page is what the customer holds.
    add(("--- THIS SHIPMENT " .. RULE):sub(1, I.W))
    local shown = 0
    for i, it in ipairs(inv.items) do
      if i == I.ITEM_LINES and #inv.items > I.ITEM_LINES then
        add(row("+ " .. (#inv.items - I.ITEM_LINES + 1) .. " MORE ITEMS", ""))
        shown = shown + 1
        break
      end
      add(row(I.itemName(it.item), I.thousands(it.this), true))
      shown = shown + 1
    end
    for _ = shown + 1, I.ITEM_LINES do add("") end
    add(inv.complete and row("ORDER", "COMPLETE") or row("ORDER", "MORE TO FOLLOW"))
  else
    local ordered = math.floor(tonumber(inv.ordered) or 0)
    local before = math.floor(tonumber(inv.before) or 0)
    local this = math.floor(tonumber(inv.this) or 0)
    local toFollow = ordered - before - this
    add(RULE)
    add(I.itemName(inv.item))
    add(row("ORDERED", I.thousands(ordered)))
    add(row("THIS SHIPMENT", I.thousands(this)))
    add(row("SHIPPED BEFORE", I.thousands(before)))
    add(toFollow <= 0 and row("ORDER", "COMPLETE") or row("TO FOLLOW", I.thousands(toFollow)))
  end

  add(RULE)
  add(row("TOTAL", I.money(total)))
  add(row("PAID", paid > 0 and I.money(paid) or "NOTHING YET"))
  add((total > 0 and due <= 0) and row("BALANCE DUE", "PAID IN FULL")
    or row("BALANCE DUE", I.money(math.max(0, due))))
  add(RULE)
  add("CARGO AT CONSIGNEE'S RISK")
  add("NO REFUNDS")
  -- an invoice with money owing says where to pay it: bring this page to a
  -- till (DELIVERIES.md). Paid, it signs off the usual way.
  add(due > 0 and "PAY AT ANY CINDER TILL" or "COMPLIANCE APPRECIATED")
  return "CINDER INVOICE " .. no, lines
end

--- Pack an order into shipments. lines: { { item = "cobble", amount = 5000,
-- stack = 64 }, ... } in the order given. A silo holds `slots` stacks (60 for a
-- 3x1 vault) and gives one slot to its invoice; every item takes whole slots, a
-- part-stack included. Items fill a silo in order and spill into the next, so
-- a silo holds one item where it can and two where one runs out part way.
-- Returns a list of shipments, each a list of { item, amount }.
function I.pack(lines, slots)
  slots = math.floor(tonumber(slots) or 60)
  local room = math.max(1, slots - 1)
  local out, cur, free = {}, nil, 0
  for _, l in ipairs(lines or {}) do
    local left = math.floor(tonumber(l.amount) or 0)
    local stack = math.max(1, math.floor(tonumber(l.stack) or 64))
    while left > 0 do
      if free == 0 then
        cur = {}
        out[#out + 1] = cur
        free = room
      end
      local n = math.min(left, free * stack)
      cur[#cur + 1] = { item = l.item, amount = n }
      free = free - math.ceil(n / stack)
      left = left - n
    end
  end
  return out
end

--- The page for the k-th silo of a flight, at the depot: the fields the base
-- sent in load.start (inv_*, from lib/orders.lua O.invoiceFields) and what the
-- depot itself counted into that silo, { item = count } - so the page says
-- what was measured, never what was planned (DELIVERIES.md). beforeExtra is
-- what went into this flight's earlier silos: SHIPPED BEFORE counts the one
-- flying alongside. Returns the inv table I.page takes, or nil without an order.
function I.fromFields(f, k, counted, beforeExtra)
  if type(f) ~= "table" or type(f.inv_order) ~= "string" then return nil end
  local shipment = math.floor(tonumber(f.inv_first) or 1) + (k or 1) - 1
  local inv = { order = f.inv_order, shipment = shipment,
                shipments = math.max(shipment, math.floor(tonumber(f.inv_last) or shipment)),
                date = f.inv_date, who = f.inv_who, x = f.inv_x, y = f.inv_y, z = f.inv_z,
                total = f.inv_total, paid = f.inv_paid }
  counted = counted or {}
  if f.inv_multi or not f.inv_item then
    local list = {}
    for item, n in pairs(counted) do list[#list + 1] = { item = item, this = n } end
    table.sort(list, function(a, b) if a.this ~= b.this then return a.this > b.this end return a.item < b.item end)
    inv.items, inv.complete = list, shipment >= inv.shipments
  else
    inv.item, inv.ordered = f.inv_item, f.inv_ordered
    inv.before = (tonumber(f.inv_before) or 0) + (beforeExtra or 0)
    inv.this = counted[f.inv_item] or 0
  end
  return inv
end

--- One item's shipments as plain amounts, for an order of a single thing.
function I.shipments(amount, stack, slots)
  local out = {}
  for _, sh in ipairs(I.pack({ { item = "x", amount = amount, stack = stack } }, slots)) do
    out[#out + 1] = sh[1].amount
  end
  return out
end

return I
