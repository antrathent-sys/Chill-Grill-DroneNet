-- Desktop tests for lib/state.lua and lib/screens.lua: the control room's one
-- state table, the job it follows from telemetry, and the three screens drawn
-- at the real monitor sizes.
local DIR = ...
local pass, fail = 0, 0
local function check(n, c, d)
  if c then pass = pass + 1 print("  ok   " .. n)
  else fail = fail + 1 print("  FAIL " .. n .. (d and ("  " .. tostring(d)) or "")) end
end

local D = dofile(DIR .. "/../lib/display.lua")
local S = dofile(DIR .. "/../lib/state.lua")
local SC = dofile(DIR .. "/../lib/screens.lua")

local function fakeTerm(w, h)
  local t = { w = w, h = h, grid = {} }
  function t.setCursorPos(x, y) t.cy = y end
  function t.blit(s, f, b)
    assert(#s == #f and #f == #b, "blit length mismatch")
    t.grid[t.cy] = { s = s, f = f, b = b }
  end
  return t
end

local function render(name, w, h, st)
  local c = D.canvas(w, h)
  local t = fakeTerm(w, h)
  SC.render(name, c, st)
  c:flush(t)
  return t, c
end

local function rowOf(t, needle, x0, x1)
  for y = 1, t.h do
    local r = t.grid[y]
    local s = r and r.s:sub(x0 or 1, x1 or t.w)
    if s and s:find(needle, 1, true) then return y end
  end
  return nil
end

local function wellFormed(t)
  for y = 1, t.h do
    local r = t.grid[y]
    if not r or #r.s ~= t.w or not r.f:match("^[0-9a-f]+$") or not r.b:match("^[0-9a-f]+$") then return false, y end
  end
  return true
end

print("formats")
check("signed 4-digit coordinates", SC.signed4(123) == "+0123" and SC.signed4(-450) == "-0450" and SC.signed4(nil) == "-----",
  SC.signed4(123) .. " " .. SC.signed4(-450))
check("countdown MM:SS, HH:MM above an hour", SC.countdown(125) == "02:05" and SC.countdown(3725) == "01:02"
  and SC.countdown(nil) == "--:--", SC.countdown(3725))
check("range in blocks, k above 1000", SC.range(1234) == "1.2k" and SC.range(850) == "850")
check("words drops whole words", SC.words("TRK-0001 DROP", 12) == "TRK-0001" and SC.words("ABCDEFGHIJ", 5) == nil
  and SC.words("SHORT", 9) == "SHORT")
check("clock hhmm from in-game hours", S.clock(13.5) == "1330" and S.clock(25.25) == "0115", S.clock(13.5))

print("state words")
check("no packet is OFFLINE", S.stateWord(nil, "NONE") == "OFFLINE")
check("a lost link is OFFLINE", S.stateWord({ phase = "cruise" }, "LOST") == "OFFLINE")
check("latched is CRADLED", S.stateWord({ phase = "cruise", dock = 1 }, "LIVE") == "CRADLED")
check("on the ground, not latched, is LANDED - not CRADLED", S.stateWord({ phase = "landed", dock = 0 }, "LIVE") == "LANDED")
check("a cruise leg is CRUISE", S.stateWord({ phase = "cruise", legKind = "cruise" }, "LIVE") == "CRUISE")
check("heading for a pad is INBOUND", S.stateWord({ phase = "cruise", legKind = "dock" }, "LIVE") == "INBOUND"
  and S.stateWord({ phase = "descend" }, "LIVE") == "INBOUND")
check("hovering is HOLD", S.stateWord({ phase = "hold", legKind = "hover" }, "LIVE") == "HOLD")
check("the beacon on the ground, not docked, is STANDBY", S.stateWord({ phase = "idle", dock = 0 }, "LIVE") == "STANDBY")
check("the beacon docked is CRADLED", S.stateWord({ phase = "docked", dock = 1 }, "LIVE") == "CRADLED")

print("a job followed from telemetry (mock loop)")
local sim = S.mock(D)
local states, maxStage, sawCode = {}, 0, nil
local st = sim.state()
states[0] = st
for i = 1, 262 do
  sim.tick(0.5)
  st = sim.state()
  states[i / 2] = st
  if st.order then
    maxStage = math.max(maxStage, st.order.stage)
    sawCode = sawCode or st.order.code
  end
end
local msgs = {}
for _, e in ipairs(st.log) do msgs[#msgs + 1] = e.msg end
local logText = table.concat(msgs, " | ")
check("idle at the start: no job", states[4].order == nil and states[4].unit.state == "CRADLED")
check("leaving the pad opens TRK-0001", sawCode == "TRK-0001", sawCode)
check("the job reaches DRP", maxStage == 4, maxStage)
local mid = states[30]
check("mid cruise: CRUISE, stage FLY, bound for DEPOT", mid.unit.state == "CRUISE" and mid.order.stage == 3
  and mid.dest and mid.dest.name == "DEPOT" and mid.order.to == "DEPOT", mid.dest and mid.dest.name)
check("destination has range, bearing and ETA", mid.dest.range > 100 and mid.dest.brg >= 0 and mid.dest.brg < 360
  and mid.dest.eta and mid.dest.eta > 0)
check("the drop hover is HOLD at stage DRP", states[60].unit.state == "HOLD" and states[60].order.stage == 4)
check("coming home is INBOUND to M1", states[90].unit.state == "INBOUND" and states[90].dest.name == "M1")
check("cradled at home closes the job", st.order == nil and st.unit.state == "CRADLED")
check("today: one out, one returned", st.counters.out == 1 and st.counters.returned == 1,
  st.counters.out .. "/" .. st.counters.returned)
check("the log tells the story", logText:find("TRK-0001 OPEN", 1, true) and logText:find("TRK-0001 DROP", 1, true)
  and logText:find("TRK-0001 DONE", 1, true) and logText:find("CRADLED M1", 1, true) and logText:find("INBOUND", 1, true),
  logText)
check("log entries carry the clock", st.log[#st.log].t:match("^%d%d%d%d$") ~= nil)
check("system: pad and link", st.system[1].name == "PAD M1" and st.system[1].value == "OCCUPIED"
  and st.system[2].name == "LINK" and st.system[2].value == "OK")
check("a new day resets the counts", (function()
  local sim2 = S.mock(D)
  for _ = 1, 262 do sim2.tick(0.5) sim2.state() end
  local st2 = S.build(sim2.model, sim2.t, { D = D, track = sim2.track, pads = sim2.pads, clock = "0600", day = 2 })
  return st2.counters.out == 0 and st2.counters.returned == 0
end)())
check("a lost signal is logged", (function()
  local sim3 = S.mock(D)
  sim3.state()
  local s3 = S.build(sim3.model, sim3.t + 60, { D = D, track = sim3.track, clock = "1400" })
  return s3.unit.state == "OFFLINE" and s3.log[#s3.log].msg == "SIGNAL LOST"
end)())
check("rejected packets fault the link", (function()
  local sim4 = S.mock(D)
  sim4.model.rejected = 3
  local s4 = sim4.state()
  return s4.system[2].value == "REJ 3" and s4.system[2].level == "fault"
end)())
check("the display demo fleet builds three units", (function()
  local s5 = S.build(D.demoModel(100), 100, { D = D, track = S.newTrack(), clock = "1200" })
  return #s5.units == 3 and s5.units[1].id == "DRONE-1" and s5.unit == s5.units[1]
end)())

print("screens at their sizes")
local SIZES = { drone = { { 28, 26 }, { 31, 27 } }, tactical = { { 60, 26 }, { 63, 27 } }, order = { { 28, 26 }, { 31, 27 } } }
local allGood, bad = true, nil
for name, sizes in pairs(SIZES) do
  for _, sz in ipairs(sizes) do
    for _, when in ipairs({ 0, 4, 30, 60, 90, 118, 131 }) do
      local ok, err = pcall(function()
        local t = render(name, sz[1], sz[2], states[when])
        local good, y = wellFormed(t)
        assert(good, "row " .. tostring(y) .. " malformed")
      end)
      if not ok then allGood, bad = false, string.format("%s %dx%d at %s: %s", name, sz[1], sz[2], when, err) end
    end
  end
end
check("every screen renders at every size through the loop", allGood, bad)

print("drone screen")
local t = render("drone", 28, 26, states[4])
check("head: unit id and clock", rowOf(t, "DRONE-1") == 1 and rowOf(t, states[4].clock) == 1)
check("fuel label", rowOf(t, "FUEL") == 3)
check("state strip says CRADLED", rowOf(t, "CRADLED") == 11)
check("position block", rowOf(t, "POSITION") == 13 and rowOf(t, "X +0001") == 14 and rowOf(t, "Z +0001") == 14
  and rowOf(t, "ALT 70") == 15 and rowOf(t, "HDG 000") == 15
  and rowOf(t, "SPD 0 B/S") == 16)
check("idle: STANDING BY", rowOf(t, "STANDING BY") == 19)
check("no payload panel - nothing carries one yet", rowOf(t, "PAYLOAD") == nil)
check("footer: base and unit count", rowOf(t, "M1") == 26 and rowOf(t, "ONE UNIT") == 26)
t = render("drone", 28, 26, states[30])
check("on a job: DELIVER TRK-0001 TO DEPOT", rowOf(t, "DELIVER TRK-0001") == 19 and rowOf(t, "TO DEPOT") == 20)
check("under way: CRUISE", rowOf(t, "CRUISE") == 11)
local low = S.mock(D)
low.model.drones["drone-1"].pkt.energy = 20
local tl = render("drone", 28, 26, low.state())
check("fuel below 35 turns amber", tl.grid[8].b:find(SC.K.amber, 1, true) ~= nil)
t = render("drone", 28, 26, S.build(D.newModel(), 0, { D = D, track = S.newTrack(), clock = "0000" }))
check("no units: awaiting signal", rowOf(t, "NO UNIT") == 1 and rowOf(t, "AWAITING SIGNAL") == 3)

print("tactical screen")
local function gapClear(tt)
  for y = 1, tt.h do
    if tt.grid[y].s:sub(41, 41) ~= " " then return false, y end
  end
  return true
end
t = render("tactical", 60, 26, states[4])
check("rail head", rowOf(t, "TACTICAL", 42) == 1)
check("no job: no destination, LOG starts at r7", rowOf(t, "DESTINATION") == nil and rowOf(t, "LOG", 42) == 8)
check("no job: no DEST marker", rowOf(t, "DEST", 1, 40) == nil)
check("base marker labelled on the map", rowOf(t, "M1", 1, 40) ~= nil)
check("caption", rowOf(t, "1 PX = 128 BLOCKS", 1, 40) == 26)
check("system panel at the foot of the rail", rowOf(t, "SYSTEM", 42) ~= nil and rowOf(t, "PAD M1", 42) ~= nil
  and rowOf(t, "LINK", 42) ~= nil and rowOf(t, "M1 TACTICAL", 42) == 26)
check("nothing ever lands in the gap column", gapClear(t))
t = render("tactical", 60, 26, states[30])
check("on a job: DESTINATION at r7, name, bearing, ETA", rowOf(t, "DESTINATION", 42) == 8 and rowOf(t, "DEPOT", 42) == 9
  and rowOf(t, "BRG", 42) == 10 and rowOf(t, "ETA", 42) == 11)
check("on a job: LOG moves down to r12", rowOf(t, "LOG", 42) == 13)
check("DEST labelled inside the map", rowOf(t, "DEST", 1, 40) ~= nil)
check("unit labelled inside the map", rowOf(t, "DRONE-1", 1, 40) ~= nil)
check("still nothing in the gap column", gapClear(t))
check("every rail row fits 19 columns", (function()
  for y = 1, t.h do if t.grid[y].s:sub(42) ~= t.grid[y].s:sub(42, 60) then return false end end
  return true
end)())
-- a unit at the east edge with a long id: its label must flip left, not spill into the rail
local edge = S.mock(D)
edge.tick(30)
local est = edge.state()
est.units[1].x, est.units[1].id = 4950, "DRONE-LONGNAME"
t = render("tactical", 60, 26, est)
check("a label at the east edge flips left and stays in the map", rowOf(t, "DRONE-LONGNAME", 1, 40) ~= nil and gapClear(t))
local lc = D.canvas(60, 26)
check("label helper: right of the marker when there is room", SC.label(lc, 21, 30, "DEST", "0", 40) == 13)
check("label helper: flips left near column 40", SC.label(lc, 79, 30, "DEST", "0", 40) == 35)
check("label helper: gives up rather than cross column 40", SC.label(lc, 3, 30, "A-VERY-LONG-LABEL-THAT-WONT-FIT-ANYWHERE", "0", 40) == nil)

print("order screen")
t = render("order", 28, 26, states[4])
check("no job: NO ORDER", rowOf(t, "ORDER") == 1 and rowOf(t, "NO ORDER") == 1)
check("no job: no type row", rowOf(t, "TYPE") == nil)
check("stage labels", rowOf(t, "QUE") == 16 and rowOf(t, "DRP") == 16)
check("today counters", rowOf(t, "TODAY") == 18 and rowOf(t, "OUT") == 20)
t = render("order", 28, 26, states[30])
check("on a job: tracking code and type", rowOf(t, "TRK-0001") == 1 and rowOf(t, "TYPE") == 11 and rowOf(t, "DELIVER") == 11)
check("on a job: destination", rowOf(t, "DEPOT") == 12)
check("current stage label white", t.grid[16].f:sub(t.grid[16].s:find("FLY", 1, true), t.grid[16].s:find("FLY", 1, true)) == SC.K.white)
t = render("order", 31, 27, states[131])
check("after the loop: returned counted with its label", rowOf(t, "RETURNED") == 20 or rowOf(t, "RTN") == 20)

print("guards")
local tiny = render("drone", 15, 10, states[30])
check("too small says so", rowOf(tiny, "TOO SMALL") == 1)
check("an unknown screen is an error", not pcall(SC.render, "radar", D.canvas(28, 26), states[30]))

print("")
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then error("screens tests failed", 0) end
