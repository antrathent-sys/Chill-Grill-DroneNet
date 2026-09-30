-- Desktop tests for lib/depotscreens.lua: the depot's two monitors - every
-- moment of the demo drawn at the real sizes and at others, the bays moved on
-- by each step as the docks report them, and the words each state should put
-- on the screens.
local DIR = ...
local pass, fail = 0, 0
local function check(n, c, d)
  if c then pass = pass + 1 print("  ok   " .. n)
  else fail = fail + 1 print("  FAIL " .. n .. (d and ("  " .. tostring(d)) or "")) end
end

local D = dofile(DIR .. "/../lib/display.lua")
local DV = dofile(DIR .. "/../lib/depotscreens.lua")
DV.use(dofile(DIR .. "/../lib/tui.lua"))

local function text(name, st, now, w, h)
  local c = D.canvas(w or (name == "order" and 36 or 57), h or 38)
  DV.render(name, c, st, now)
  local rows = {}
  for y = 1, c.h do
    local s = c:row(y)
    rows[y] = s:gsub("[\128-\255]", " ")
  end
  return table.concat(rows, "\n")
end
local function has(s, what) return s:find(what, 1, true) ~= nil end

print("every moment of the demo, at every size")
local sizes = { { "hero", 57, 38 }, { "order", 36, 38 }, { "hero", 29, 19 }, { "order", 18, 19 },
                { "hero", 79, 52 }, { "order", 50, 52 }, { "hero", 20, 12 }, { "order", 12, 12 } }
local bad
for t = 0, 99.5, 0.5 do
  local st = DV.demo(t)
  for _, s in ipairs(sizes) do
    local ok, err = pcall(text, s[1], st, t, s[2], s[3])
    if not ok and not bad then bad = string.format("%s %dx%d at %.1f: %s", s[1], s[2], s[3], t, tostring(err)) end
  end
end
check("200 moments x 8 sizes, not one error", bad == nil, bad)

print("the model")
local st = DV.new("CHID 1")
check("names: depot-chid-1 is CHID 1", DV.nameOf("depot-chid-1") == "CHID 1")
local o1, f1 = DV.orderOf("C-0042.1")
check("a load id is its order and flight: C-0042.1", o1 == "C-0042" and f1 == 1)
check("...and an older id is shown as it is", DV.orderOf("L1727000000") == "L1727000000")
check("sides: A, B, left, right", DV.sideOf("a") == "A" and DV.sideOf("left") == "A" and DV.sideOf("right") == "B"
  and DV.sideOf("middle") == nil)
DV.begin(st, "load", "left", { id = "L-1", items = 640, unit = "drone-1" }, 0)
check("a load on the station's left bay is side A, with its unit docked", st.job.sides[1] == "A"
  and st.unit.id == "drone-1" and st.unit.state == "docked")
local want = { place = "placing", assemble = "assembling", fill = "filling", dock = "full", push = "lifting",
               stick = "up", retract = "gone" }
local okSteps, got = true, {}
for _, step in ipairs({ "place", "assemble", "fill", "dock", "push", "stick", "retract" }) do
  DV.step(st, step, "", 1)
  got[#got + 1] = st.sides.A.silo
  if st.sides.A.silo ~= want[step] then okSteps = false end
end
check("each load step moves the bay on", okSteps, table.concat(got, " "))
DV.step(st, "fill", "352 items in", 2)
check("items moved are read from the report", st.job.moved == 352)
check("the steps before are ticked off", st.job.done.place and st.job.done.assemble and st.job.done.dock)
DV.finish(st, true, nil, 10)
check("done: counted, the bay clear, the silo under the drone", st.counts.loads == 1 and st.counts.items == 352
  and st.sides.A.silo == "none" and st.unit.carry and st.unit.carry[1] == "A" and st.job == nil and st.last.ok)
DV.left(st)
check("the unit goes, and what it carried with it", st.unit == nil)
local st2 = DV.new("X")
DV.begin(st2, "load", "A", {}, 0)
DV.step(st2, "lift", "", 1)
check("the station loader's lift is a push", st2.sides.A.silo == "lifting" and st2.job.step == "push")
DV.step(st2, "feed", "2 silo blocks in the feed", 2)
check("the feed count is read from the report", st2.sides.A.feed == 2)
DV.finish(st2, false, "2 silo blocks in the feed - a payload takes 3", 3)
check("called off: the side is marked, nothing counted", st2.sides.A.fault and st2.counts.loads == 0 and not st2.last.ok)
DV.begin(st2, "unload", { "A", "B" }, { items = 100 }, 4)
check("a new job on the side clears its fault", st2.sides.A.fault == nil)
for _, step in ipairs({ "push", "release", "retract", "empty" }) do DV.step(st2, step, "", 5) end
DV.finish(st2, true, nil, 6)
check("an unload leaves an empty silo on each side", st2.sides.A.silo == "empty" and st2.sides.B.silo == "empty"
  and st2.counts.unloads == 1)
local st3 = DV.new("X")
DV.begin(st3, "load", "B", {}, 0)
DV.step(st3, "fill", "", 1)
DV.finish(st3, false, "stuck", 2)
check("a fill called off leaves a part-filled silo", st3.sides.B.silo == "partial")

print("what the screens say")
local idle = DV.demo(1)
local h = text("hero", idle, 1)
check("standing by, no unit, the base alive", has(h, "STANDING BY") and has(h, "NO UNIT") and has(h, "BASE LINK OK"), h)
check("both sides, their silo stock, a short one called out", has(h, "SIDE A") and has(h, "SIDE B")
  and has(h, "SILO STOCK 9 = 3 LOADS") and has(h, "SILO STOCK 2 - NEEDS 3"), h)
check("the fleet's header", has(h, "CINDER") and has(h, "CHID 1 DEPOT"))
local o = text("order", idle, 1)
check("the order screen stands by, with the bays and the day", has(o, "LAST ORDER") and has(o, "BAYS")
  and has(o, "STOCK 2") and has(o, "TODAY"), o)
local filling = DV.demo(25)
h, o = text("hero", filling, 25), text("order", filling, 25)
check("filling: LOADING - SIDE A, items counting up", has(h, "LOADING - SIDE A") and has(h, "160 / 640 ITEMS"), h)
check("the order: its number and flight, where to, the unit, the sequence", has(o, "C-0042") and has(o, "FLIGHT 1")
  and has(o, "KODIAK") and has(o, "LAMBDA-001") and has(o, "SEQUENCE") and has(o, "PLACE SILO") and has(o, "COBBLESTONE"), o)
h = text("hero", DV.demo(32), 32)
check("waiting for the latch: AWAITING UNIT", has(h, "AWAITING UNIT"), h)
h = text("hero", DV.demo(6), 6)
check("a unit on its way", has(h, "UNIT INBOUND"), h)
h = text("hero", DV.demo(47), 47)
check("done: LOADED - SIDE A", has(h, "LOADED - SIDE A"), h)
h, o = text("hero", DV.demo(71), 71), text("order", DV.demo(71), 71)
check("an unload on both sides", has(h, "UNLOADING - SIDE A+B") and has(h, "1,024 / 2,560 ITEMS") and has(o, "C-0039")
  and has(o, "SIDE A+B") and has(o, "SHIPMENT 3-4 OF 4"), h)
h, o = text("hero", DV.demo(92), 92), text("order", DV.demo(92), 92)
check("called off: the header and the side say so, and why", has(h, "CALLED OFF") and has(h, "FAULT")
  and has(o, "CALLED OFF") and has(o, "NOTHING LEFT THE STORAGE"), o)
local stale = DV.demo(1)
stale.baseAt = 0
check("no word from the base for a while: BASE LINK LOST", has(text("hero", stale, 100), "BASE LINK LOST"))

print("")
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then error("depotscreens tests failed", 0) end
