--- invoice: the page that rides in every silo.
--
-- A regular invoice: who is billed and where the goods go, what was ordered,
-- what this shipment holds, what was shipped before it and what is still to
-- follow, and the money. Every silo of an order is a shipment, numbered across
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
--   item       "cobble"
--   ordered    10000
--   before     3776                     counted into the shipments before this
--   this       3776                     counted into this one
--   total      1500                     the agreed price, spurs
--   paid       1500                     received so far, spurs
-- Returns the page title (what the printed page is called as an item) and the
-- lines, never more than I.H of them, never wider than I.W.
function I.page(inv)
  local ordered = math.floor(tonumber(inv.ordered) or 0)
  local before = math.floor(tonumber(inv.before) or 0)
  local this = math.floor(tonumber(inv.this) or 0)
  local total = math.floor(tonumber(inv.total) or 0)
  local paid = math.floor(tonumber(inv.paid) or 0)
  local toFollow = ordered - before - this
  local due = total - paid
  local no = I.number(inv.order, inv.shipment)

  local follow
  if toFollow <= 0 then follow = row("ORDER", "COMPLETE")
  else follow = row("TO FOLLOW", I.thousands(toFollow)) end

  local balance
  if total > 0 and due <= 0 then balance = row("BALANCE DUE", "PAID IN FULL")
  else balance = row("BALANCE DUE", I.money(math.max(0, due))) end

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
    RULE,
    I.itemName(inv.item),
    row("ORDERED", I.thousands(ordered)),
    row("THIS SHIPMENT", I.thousands(this)),
    row("SHIPPED BEFORE", I.thousands(before)),
    follow,
    RULE,
    row("TOTAL", I.money(total)),
    row("PAID", paid > 0 and I.money(paid) or "NOTHING YET"),
    balance,
    RULE,
    "CARGO AT CONSIGNEE'S RISK",
    "NO REFUNDS",
    "COMPLIANCE APPRECIATED",
  }
  return "CINDER INVOICE " .. no, lines
end

--- Shipments for an order: how many silos it takes, and how much goes in each.
-- A silo holds `slots` stacks (60 for a 3x1 vault) and gives one slot to this
-- page, so a 64-stack item fills 59 * 64 = 3,776 of it. The dual loader fills
-- two at once, but a shipment is a silo, not a flight. Returns a list of
-- amounts, the last one partial.
function I.shipments(amount, stack, slots)
  amount = math.floor(tonumber(amount) or 0)
  stack = math.floor(tonumber(stack) or 64)
  slots = math.floor(tonumber(slots) or 60)
  local per = math.max(1, (slots - 1) * math.max(1, stack))
  local out = {}
  while amount > 0 do
    local n = math.min(per, amount)
    out[#out + 1] = n
    amount = amount - n
  end
  return out
end

return I
