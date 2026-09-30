-- Desktop tests for lib/orders.lua: the order number from order to invoice,
-- orders.log written and read back, shipments planned from what was actually
-- counted, and the fields the depot prints each silo's invoice from.
local DIR = ...
local pass, fail = 0, 0
local function check(n, c, d)
  if c then pass = pass + 1 print("  ok   " .. n)
  else fail = fail + 1 print("  FAIL " .. n .. (d and ("  " .. tostring(d)) or "")) end
end

local I = dofile(DIR .. "/../lib/invoice.lua")
local O = dofile(DIR .. "/../lib/orders.lua")
O.use(I)

print("numbers")
check("C-0042, and its first flight C-0042.1", O.format(42) == "C-0042" and O.loadId("C-0042", 1) == "C-0042.1")
local po, pf = O.parseLoad("C-0042.3")
check("a load id back to its order and flight", po == "C-0042" and pf == 3 and O.parseLoad("L1727000000") == nil)
check("the first order is C-0001", O.nextId({}) == "C-0001")

print("the log")
local line = O.encode(100, "C-0001", "", "accepted", { who = "steve, the builder", note = "a;b=c%d" })
local back = O.decode(line)
check("a line survives commas, semicolons, equals and percents in its values", back and back.kv.who == "steve, the builder"
  and back.kv.note == "a;b=c%d" and back.order == "C-0001" and back.event == "accepted", line)
check("the log line has the ORDERS.md shape", line:match("^100,C%-0001,,accepted,") ~= nil, line)

print("an order, flown")
local order = { who = "steve", to = { x = 1200, y = 70, z = 340 }, price = 1500,
                lines = { { item = "minecraft:cobblestone", amount = 10000, stack = 64 } } }
check("a good order checks out", O.check(order))
check("no coordinates: refused", not O.check({ who = "a", lines = order.lines, price = 1 }))
check("no price: refused", not O.check({ who = "a", to = order.to, lines = order.lines }))
check("an item by a name with spaces: refused (ids only)",
  not O.check({ who = "a", to = order.to, price = 1, lines = { { item = "oak log", amount = 1, stack = 64 } } }))
local log = { O.accepted(1, "C-0001", order) }
local function replay() local byId = O.replay(table.concat(log, "\n")) return byId["C-0001"], byId end
local o, byId = replay()
check("read back: who, where, what, for how much", o.who == "steve" and o.to.z == 340 and o.lines[1].amount == 10000
  and o.price == 1500 and o.state == "accepted")
check("the next order number is one past it", O.nextId(byId) == "C-0002")
local rest, total = O.plan(o)
check("10k cobble is three shipments: 3,776 + 3,776 + 2,448", #rest == 3 and total == 3 and rest[1][1].amount == 3776
  and rest[3][1].amount == 2448)
local fl = O.nextFlight(o)
check("the first flight is C-0001.1: shipments 1 and 2, 7,552 items", fl and fl.load == "C-0001.1" and fl.first == 1
  and fl.count == 2 and fl.items == 7552 and fl.total == 3 and fl.stack == 64)
log[#log + 1] = O.flightLine(2, "C-0001", 1, { depot = "depot-chid-1", drone = "drone-1", first = 1, count = 2 })
o = replay()
check("flying: the order is active, and no second flight until it is counted", o.state == "active"
  and O.nextFlight(o) == nil)
-- the first silo came up short: 3,700, and the second full
log[#log + 1] = O.loadedLine(3, "C-0001", 1, { [1] = { ["minecraft:cobblestone"] = 3700 },
                                                [2] = { ["minecraft:cobblestone"] = 3776 } }, "read from the silos")
o = replay()
rest, total = O.plan(o)
check("the rest is planned from what was counted: 2,524 left, one shipment, three in all", #rest == 1
  and rest[1][1].amount == 2524 and total == 3, rest[1] and rest[1][1].amount)
fl = O.nextFlight(o)
check("the next flight is C-0001.2, shipment 3", fl and fl.load == "C-0001.2" and fl.first == 3 and fl.count == 1)
local f = O.invoiceFields(o, fl, "2026-09-30")
check("the invoice fields: order, who, where, money, shipments, and what went before", f.inv_order == "C-0001"
  and f.inv_who == "steve" and f.inv_x == 1200 and f.inv_total == 1500 and f.inv_first == 3 and f.inv_last == 3
  and f.inv_item == "minecraft:cobblestone" and f.inv_ordered == 10000 and f.inv_before == 7476)
check("not complete while shipments are still to drop", not O.complete(o))
log[#log + 1] = O.droppedLine(4, "C-0001", 1, 1, true, 1200, 70, 340)
log[#log + 1] = O.droppedLine(5, "C-0001", 1, 2, true, 1200, 70, 340)
log[#log + 1] = O.flightLine(6, "C-0001", 2, { first = 3, count = 1 })
log[#log + 1] = O.loadedLine(7, "C-0001", 2, { [3] = { ["minecraft:cobblestone"] = 2524 } })
o = replay()
check("all counted, the last not yet dropped: not complete", not O.complete(o) and O.nextFlight(o) == nil)
log[#log + 1] = O.droppedLine(8, "C-0001", 2, 3, true, 1200, 70, 340)
o = replay()
check("all counted and dropped: complete", O.complete(o))
log[#log + 1] = O.paidLine(9, "C-0001", 1500, "by hand")
log[#log + 1] = O.doneLine(10, "C-0001")
o = replay()
check("paid and done", o.paid == 1500 and o.state == "done" and O.nextFlight(o) == nil)
check("its summary line", O.summary(o):find("C-0001", 1, true) and O.summary(o):find("3/3 shipped", 1, true)
  and O.summary(o):find("PAID", 1, true) and O.summary(o):find("10,000 COBBLESTONE", 1, true), O.summary(o))

print("a flight that failed")
local log2 = { O.accepted(1, "C-0002", order), O.flightLine(2, "C-0002", 1, { first = 1, count = 2 }),
               O.failedLine(3, "C-0002", 1, "the depot went quiet") }
local o2 = O.replay(table.concat(log2, "\n"))["C-0002"]
local fl2 = O.nextFlight(o2)
check("the order stays open, and the next flight is .2 with the same shipments", fl2 and fl2.load == "C-0002.2"
  and fl2.first == 1 and fl2.count == 2)
local log3 = { O.accepted(1, "C-0003", order), O.cancelledLine(2, "C-0003", "changed their mind") }
check("cancelled: nothing more flies", O.nextFlight(O.replay(table.concat(log3, "\n"))["C-0003"]) == nil)

print("several items")
local mixed = { who = "kodiak", to = { x = 2400, y = 72, z = -3269 }, price = 2400,
                lines = { { item = "minecraft:cobblestone", amount = 5000, stack = 64 },
                          { item = "minecraft:gravel", amount = 2000, stack = 64 } } }
local om = O.replay(O.accepted(1, "C-0004", mixed))["C-0004"]
local flm = O.nextFlight(om)
check("5,000 cobble + 2,000 gravel: one flight of two silos, the second holding both", flm and flm.count == 2
  and #flm.silos[2] == 2 and flm.silos[1][1].amount == 3776, flm and #flm.silos)
local fm = O.invoiceFields(om, flm, "2026-09-30")
check("a several-item order's fields say so", fm.inv_multi == 1 and fm.inv_item == nil)

print("received at a depot instead of dropped")
local logR = { O.accepted(1, "C-0009", { who = "ops", kind = "parcel", to = { x = 1, y = 2, z = 3 }, price = 0,
                 lines = { { item = "minecraft:iron_ingot", amount = 3000, stack = 64 } } }),
               O.flightLine(2, "C-0009", 1, { first = 1, count = 1 }),
               O.loadedLine(3, "C-0009", 1, { [1] = { ["minecraft:iron_ingot"] = 3000 } }, "x", { A = 1 }) }
local oR = O.replay(table.concat(logR, "\n"))["C-0009"]
check("the side a shipment was loaded on is kept", O.shipmentAt(oR, 1, "A") == 1 and O.shipmentAt(oR, 1, "B") == nil)
logR[#logR + 1] = O.receivedLine(4, "C-0009", 1, 1, "chid-2", { ["minecraft:iron_ingot"] = 3000 })
oR = O.replay(table.concat(logR, "\n"))["C-0009"]
check("received counts as delivered, where and what", oR.dropped[1] == true and oR.received[1].depot == "chid-2"
  and oR.received[1].items["minecraft:iron_ingot"] == 3000 and O.complete(oR))

print("invoices from the depot's own count")
local inv1 = I.fromFields(f, 1, { ["minecraft:cobblestone"] = 2524 })
local title, lines = I.page(inv1)
check("the last shipment: C-0001-3, 3 OF 3, what was counted, ORDER COMPLETE", title == "CINDER INVOICE C-0001-3"
  and table.concat(lines, "\n"):find("3 OF 3", 1, true) and table.concat(lines, "\n"):find("2,524", 1, true)
  and table.concat(lines, "\n"):find("ORDER", 1, true) and table.concat(lines, "\n"):find("COMPLETE", 1, true))
local ff = O.invoiceFields(O.replay(O.accepted(1, "C-0005", order))["C-0005"],
  O.nextFlight(O.replay(O.accepted(1, "C-0005", order))["C-0005"]), "2026-09-30")
local a = I.fromFields(ff, 1, { ["minecraft:cobblestone"] = 3776 })
local b = I.fromFields(ff, 2, { ["minecraft:cobblestone"] = 3700 }, 3776)
check("two silos of one flight: 1 OF 3 and 2 OF 3, the second counting the first as shipped before",
  a.shipment == 1 and b.shipment == 2 and a.shipments == 3 and b.before == 3776 and b.this == 3700)
local mx = I.fromFields(fm, 2, { ["minecraft:cobblestone"] = 1224, ["minecraft:gravel"] = 2000 })
local mt, ml = I.page(mx)
check("a several-item silo is a packing list of what was counted", table.concat(ml, "\n"):find("GRAVEL", 1, true)
  and table.concat(ml, "\n"):find("1,224", 1, true) and mt == "CINDER INVOICE C-0004-2")
local fits = true
for _, l in ipairs(ml) do if #l > I.W then fits = false end end
check("and it fits the page", fits and #ml <= I.H)
check("no order in the fields, no invoice", I.fromFields({}, 1, {}) == nil)

print("")
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then error("orders tests failed", 0) end
