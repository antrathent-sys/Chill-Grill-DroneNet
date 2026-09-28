-- lib/invoice.lua: every page must fit a CC printed page, 25 x 21, whatever
-- the order throws at it - long names, far coordinates, big numbers, the last
-- shipment, nothing paid. A page that overflows prints cut off in a customer's
-- vault, so the width and height are checked on every case, and the pages are
-- printed here so the layout can be looked at.
local DIR = ...
local pass, fail = 0, 0
local function check(n, c, d)
  if c then pass = pass + 1 print("  ok   " .. n)
  else fail = fail + 1 print("  FAIL " .. n .. (d and ("  " .. tostring(d)) or "")) end
end

local I = dofile(DIR .. "/../lib/invoice.lua")

local function fits(title, lines, name)
  local wide = 0
  for _, l in ipairs(lines) do wide = math.max(wide, #l) end
  check(name .. ": 21 lines, none wider than 25", #lines == I.H and wide <= I.W,
    #lines .. " lines, widest " .. wide)
end

local function show(title, lines)
  print("   .-------------------------.   " .. title)
  for _, l in ipairs(lines) do print("   |" .. l .. string.rep(" ", I.W - #l) .. "|") end
  print("   '-------------------------'")
end

local function has(lines, s)
  for _, l in ipairs(lines) do if l:find(s, 1, true) then return true end end
  return false
end

print("shipments from an order")
local s = I.shipments(10000, 64)
check("10,000 cobble is three shipments: 3,776 + 3,776 + 2,448",
  #s == 3 and s[1] == 3776 and s[2] == 3776 and s[3] == 2448, table.concat(s, " + "))
check("one slot per silo goes to the invoice: 59 x 64 = 3,776", I.shipments(3776, 64)[1] == 3776
  and #I.shipments(3777, 64) == 2)
s = I.shipments(2000, 16)
check("a 16-stack item: 944 a silo", s[1] == 944 and #s == 3, table.concat(s, " + "))
check("nothing ordered, no shipments", #I.shipments(0, 64) == 0)

print("")
print("the middle shipment of three, paid in full")
local t, lines = I.page({ order = "C-0042", shipment = 2, shipments = 3, date = "2026-09-28",
  who = "steve", x = 1200, y = 70, z = 340, item = "minecraft:cobblestone",
  ordered = 10000, before = 3776, this = 3776, total = 1500, paid = 1500 })
show(t, lines)
fits(t, lines, "middle")
check("it says which shipment it is, of how many", has(lines, "2 OF 3"))
check("the invoice number is the order and the shipment", has(lines, "C-0042-2") and t == "CINDER INVOICE C-0042-2")
check("ordered, this shipment, shipped before, to follow",
  has(lines, "10,000") and has(lines, "THIS SHIPMENT") and has(lines, "SHIPPED BEFORE")
  and has(lines, "TO FOLLOW") and has(lines, "2,448"))
check("the item by its plain name", has(lines, "COBBLESTONE") and not has(lines, "MINECRAFT"))
check("paid in full says so", has(lines, "PAID IN FULL"))
check("the terms, in the Directorate's words", has(lines, "CARGO AT CONSIGNEE'S RISK")
  and has(lines, "NO REFUNDS") and has(lines, "COMPLIANCE APPRECIATED"))

print("")
print("the last shipment, nothing paid yet")
t, lines = I.page({ order = "C-0042", shipment = 3, shipments = 3, date = "2026-09-28",
  who = "steve", x = 1200, y = 70, z = 340, item = "cobble",
  ordered = 10000, before = 7552, this = 2448, total = 1500, paid = 0 })
show(t, lines)
fits(t, lines, "last")
check("the last one says the order is complete", has(lines, "ORDER") and has(lines, "COMPLETE")
  and not has(lines, "TO FOLLOW"))
check("unpaid shows the balance due, exactly", has(lines, "1,500 SPUR") and has(lines, "NOTHING YET"))

print("")
print("the worst the world can throw at it")
t, lines = I.page({ order = "C-9999", shipment = 118, shipments = 120, date = "2026-12-31",
  who = "a_very_long_minecraft_name", x = -29999984, y = 319, z = -29999984,
  item = "createaddition:electrum_wire_spool_extra", ordered = 1234567, before = 1200000,
  this = 3776, total = 98765432, paid = 12345 })
show(t, lines)
fits(t, lines, "extremes")
check("a long name is cut to fit, and BILL TO stays on the line", has(lines, "BILL TO A_VERY_LONG"))
check("world-border coordinates keep every digit", has(lines, "-29999984 319 -29999984"))
check("a partial payment leaves the difference due", has(lines, "98,753,087 SPUR"))

print("")
print("a free delivery")
t, lines = I.page({ order = "C-0001", shipment = 1, shipments = 1, date = "2026-09-28",
  who = "alex", x = 0, y = 64, z = 0, item = "stone", ordered = 100, before = 0, this = 100, total = 0, paid = 0 })
fits(t, lines, "free")
check("no charge says so, rather than owing zero", has(lines, "NO CHARGE"))

print("")
print("several items: packing an order into silos")
local sh = I.pack({ { item = "cobble", amount = 5000 }, { item = "gravel", amount = 2000 } })
check("5,000 cobble + 2,000 gravel is two silos", #sh == 2, #sh)
check("the first is all cobble: 3,776", #sh[1] == 1 and sh[1][1].item == "cobble" and sh[1][1].amount == 3776)
check("the second holds the rest of the cobble and all the gravel",
  #sh[2] == 2 and sh[2][1].amount == 1224 and sh[2][2].item == "gravel" and sh[2][2].amount == 2000)
sh = I.pack({ { item = "cobble", amount = 3000 }, { item = "gravel", amount = 1000 } })
check("an item that runs out part way shares its silo with the next",
  #sh == 2 and sh[1][2].item == "gravel" and sh[1][2].amount == 768 and sh[2][1].amount == 232,
  sh[1][2] and sh[1][2].amount)
sh = I.pack({ { item = "cobble", amount = 3776 }, { item = "ender_pearl", amount = 500, stack = 16 } })
check("a 16-stack item counts its own slots", #sh == 2 and sh[2][1].amount == 500)
local slotsUsed = 0
for _, it in ipairs(I.pack({ { item = "a", amount = 100 }, { item = "b", amount = 1 },
                             { item = "c", amount = 1 } })[1]) do slotsUsed = slotsUsed + math.ceil(it.amount / 64) end
check("every part-stack takes a whole slot", slotsUsed == 4, slotsUsed)

print("")
print("several items: the page")
t, lines = I.page({ order = "C-0050", shipment = 2, shipments = 3, date = "2026-09-28",
  who = "kodiak", x = 2400, y = 72, z = -3269, total = 2400, paid = 0,
  items = { { item = "minecraft:cobblestone", this = 1224 }, { item = "minecraft:gravel", this = 2000 } } })
show(t, lines)
fits(t, lines, "packing list")
check("it lists what is in this silo", has(lines, "THIS SHIPMENT") and has(lines, "COBBLESTONE")
  and has(lines, "1,224") and has(lines, "GRAVEL") and has(lines, "2,000"))
check("and says more is coming", has(lines, "MORE TO FOLLOW"))
check("money owing says where to pay it", has(lines, "PAY AT ANY CINDER TILL")
  and not has(lines, "COMPLIANCE APPRECIATED"))
t, lines = I.page({ order = "C-0050", shipment = 3, shipments = 3, date = "2026-09-28",
  who = "kodiak", x = 2400, y = 72, z = -3269, total = 2400, paid = 2400, complete = true,
  items = { { item = "iron_block", this = 640 } } })
fits(t, lines, "last of several")
check("the last says the order is complete", has(lines, "COMPLETE") and not has(lines, "MORE TO FOLLOW"))
check("paid, it signs off the usual way", has(lines, "COMPLIANCE APPRECIATED") and not has(lines, "PAY AT"))
local many = {}
for i = 1, 6 do many[i] = { item = "thing_" .. i, this = 10 } end
t, lines = I.page({ order = "C-0051", shipment = 1, shipments = 1, date = "2026-09-28",
  who = "un", x = 1285, y = 93, z = -22, total = 100, paid = 100, complete = true, items = many })
show(t, lines)
fits(t, lines, "six items in one silo")
check("more items than lines: the rest are counted, not dropped silently", has(lines, "+ 3 MORE ITEMS"))

print("")
print("helpers")
check("thousands", I.thousands(0) == "0" and I.thousands(999) == "999" and I.thousands(1000) == "1,000"
  and I.thousands(1234567) == "1,234,567" and I.thousands(-4096) == "-4,096")
check("money is exact, never rounded to cogs", I.money(1500) == "1,500 SPUR")

print("")
print(string.format("%d passed, %d failed", pass, fail))
