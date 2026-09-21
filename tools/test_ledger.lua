local DIR = ...
local pass, fail = 0, 0
local function check(n, c, d)
  if c then pass = pass + 1 print("  ok   " .. n)
  else fail = fail + 1 print("  FAIL " .. n .. (d and ("  " .. tostring(d)) or "")) end
end

local L = dofile(DIR .. "/../lib/ledger.lua")

print("a line per event")
check("a credit", L.row(1789867493, "alex", "credit", 500, "depositor base")
  == "1789867493,alex,credit,500,depositor base", L.row(1789867493, "alex", "credit", 500, "depositor base"))
check("a fare is negative", L.row(1, "alex", "fare", -84, "pier to market") == "1,alex,fare,-84,pier to market")
check("a comma in a note cannot break the file",
  L.row(1, "a,b", "fare", -1, "x,y") == "1,a b,fare,-1,x y", L.row(1, "a,b", "fare", -1, "x,y"))

print("reading it back")
local text = L.HEADER .. "\n"
  .. L.row(100, "alex", "credit", 500, "depositor") .. "\n"
  .. L.row(140, "alex", "fare", -84, "to market") .. "\n"
  .. L.row(150, "sam", "credit", 64, "depositor") .. "\n"
  .. L.row(160, "sam", "fare", -120, "to quarry") .. "\n"
local rows, bad = L.parse(text)
check("every row", #rows == 4 and bad == 0, #rows .. " rows, " .. bad .. " bad")
check("in order, with their notes", rows[2].who == "alex" and rows[2].amount == -84 and rows[2].note == "to market")
local half = text .. "1700,alex,fare,-2"        -- a line cut off mid-write
rows, bad = L.parse(half)
check("a half-written last line is skipped, not guessed", #rows == 4 and bad == 1, bad)
rows = L.parse(text .. "1700,alex,bribe,-500,nice shuttle\n")
check("a kind it does not know is refused", #rows == 4)
check("comments and the header are not rows", #L.parse("# notes\n" .. L.HEADER .. "\n") == 0)

print("what people owe")
rows = L.parse(text)
local bal = L.balances(rows)
check("alex is up", bal["alex"].balance == 416, bal["alex"].balance)
check("sam is down", bal["sam"].balance == -56, bal["sam"].balance)
check("negative is allowed, on purpose", L.balanceOf(rows, "sam") == -56)
check("counted what they paid and spent", bal["alex"].paid == 500 and bal["alex"].spent == 84)
check("counted rides", bal["alex"].rides == 1 and bal["sam"].rides == 1)
check("someone with no history is simply zero", L.balanceOf(rows, "nobody") == 0)

print("what a ride costs")
local t = L.tariff({ perBlock = 0.1, minimum = 20, freeTo = { "home", "depot" } })
check("by distance", (L.fare(1000, "market", t)) == 100, L.fare(1000, "market", t))
check("never under the minimum", (L.fare(50, "market", t)) == 20)
local free, why = L.fare(5000, "home", t)
check("free to base, however far", free == 0 and why:match("free to home"), why)
check("free to any place on the list", (L.fare(5000, "DEPOT", t)) == 0)
check("case does not matter", (L.fare(5000, "Home", t)) == 0)
check("the default tariff still charges", (L.fare(1000, "market")) > 0)
local t2 = L.tariff({ freeUnder = 300 })
check("short hops can be free", (L.fare(200, "market", t2)) == 0)
check("but not long ones", (L.fare(400, "market", t2)) > 0)
check("a tariff of nonsense falls back to the default",
  (L.fare(1000, "market", L.tariff({ perBlock = "lots" }))) == (L.fare(1000, "market")))

print("a flat fare, if you would rather")
local flat = L.tariff({ flat = 6, freeTo = { "home" } })
check("the same for a short hop", (L.fare(200, "market", flat)) == 6, L.fare(200, "market", flat))
check("and for a long one", (L.fare(7000, "market", flat)) == 6)
check("free places are still free", (L.fare(7000, "home", flat)) == 0)
check("it says why", select(2, L.fare(500, "market", flat)) == "flat fare")
check("zero means charge by distance", (L.fare(1000, "market", L.tariff({ flat = 0 })))
  == (L.fare(1000, "market")))

print("money as people say it")
check("spurs", L.money(30) == "30 SPUR", L.money(30))
check("cogs", L.money(128) == "2.0 COG", L.money(128))
check("suns", L.money(8192) == "2.0 SUN", L.money(8192))
check("and owing", L.money(-128) == "-2.0 COG", L.money(-128))

print("")
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then error("ledger tests failed", 0) end
