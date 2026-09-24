-- Desktop tests for lib/dockseq.lua: the two-sided dock's load and unload,
-- against a pretend dock whose clock moves when the sequence sleeps.
local DIR = ...
local pass, fail = 0, 0
local function check(n, c, d)
  if c then pass = pass + 1 print("  ok   " .. n)
  else fail = fail + 1 print("  FAIL " .. n .. (d and ("  " .. tostring(d)) or "")) end
end

local D = dofile(DIR .. "/../lib/dockseq.lua")

print("the layout")
local real, why = D.check(dofile(DIR .. "/../machines/test-dock/dock.lua"))
check("the test dock's own dock.lua checks out", real ~= nil, why)
check("...both sides, their pushers from the map", real and real.sides.A.pusher == "redstone_relay_7"
  and real.sides.B.pusher == "redstone_relay_9")
check("...its waits are its own", real and real.wait.assemble == 5 and real.fill.settle == 6)
local function bad(c, what) check(what, (D.check(c)) == nil, select(2, D.check(c))) end
bad(nil, "nothing is refused")
bad({ sides = {} }, "no side is refused")
bad({ sides = { A = { place = "r1" } } }, "a side with no pusher is refused")
bad({ sides = { A = { pusher = 7 } } }, "a relay that is not a name is refused")
bad({ sides = { A = { pusher = "r" } }, belt_on = "sideways" }, "a belt that neither fills nor empties is refused")

local CFG = D.check({
  sides = { A = { place = "r10", assemble = "r6", pusher = "r7", belt = "r1" },
            B = { place = "r11", assemble = "r8", pusher = "r9" } },
  storage = { "store" }, belt_on = "empties",
  wait = { pulse = 1, place = 2, assemble = 3, push = 2, retract = 2, step = 1 },
  fill = { settle = 4, start = 10, max = 60 }, empty = { settle = 4, start = 10, max = 60 },
})

-- a pretend dock: every relay change with its time, a storage that moves
-- while the belt runs, and a drone (a person, in test mode) that answers
local function dock(opts)
  opts = opts or {}
  local w = { t = 0, sets = {}, level = {}, said = {}, silos = { A = opts.silo or "none", B = "none" },
              store = opts.store or 1000, asked = {} }
  w.io = {
    set = function(relay, on)
      w.sets[#w.sets + 1] = { t = w.t, relay = relay, on = on }
      w.level[relay] = on
      return true
    end,
    sleep = function(s)
      -- items move a second at a time while the storage is being drained or fed
      local steps = math.max(1, math.floor(s + 0.5))
      for _ = 1, steps do
        w.t = w.t + s / steps
        if w.flow then w.store = math.max(0, w.store + w.flow) end
        if w.flowUntil and w.t >= w.flowUntil then w.flow = nil end
      end
    end,
    now = function() return w.t end,
    count = function() return w.store end,
    silo = function(side, st) if st then w.silos[side] = st end return w.silos[side] end,
    say = function(step, text) w.said[#w.said + 1] = step .. ": " .. text end,
    drone = function(what)
      w.asked[#w.asked + 1] = { what = what, t = w.t, pusherUp = w.level.r7 or w.level.r9, belt = w.level.r1 }
      if opts.droneSays and opts.droneSays[what] == false then return false, "no" end
      return true
    end,
    stopped = function() return opts.stopAt and w.t >= opts.stopAt end,
  }
  return w
end
local function firstOn(w, relay)
  for _, s in ipairs(w.sets) do if s.relay == relay and s.on then return s end end
end
local function allOff(w, but)
  for k, v in pairs(w.level) do if v and k ~= but then return false, k end end
  return true
end

print("loading, with no silo on the side")
local w = dock({ store = 3000 })
w.flow = -64                           -- the storage drains 64 a second into the cargo, steadily
local ok, whyL, at, moved = D.load(CFG, "A", w.io, 640)
check("it finishes", ok and at == "done", whyL)
local place, asm, up = firstOn(w, "r10"), firstOn(w, "r6"), firstOn(w, "r7")
check("place, then assemble, then the pusher: in that order", place and asm and up and place.t < asm.t and asm.t < up.t)
check("the placer is held its 2 s, then let go", (function()
  for _, s in ipairs(w.sets) do if s.relay == "r10" and not s.on and s.t >= place.t + 2 then return true end end
end)())
check("the assembler is a pulse", (function()
  local on, off = 0, 0
  for _, s in ipairs(w.sets) do if s.relay == "r6" then if s.on then on = on + 1 else off = off + 1 end end end
  return on == 1 and off >= 1
end)())
check("it waits after assembling before it fills", asm and w.said[4] and true)
check("this belt's ON empties, so it loads at OFF: OFF through the fill and the stick",
  w.asked[2] and w.asked[2].belt == false)
check("...and back to its unloading level, ON, once the silo has gone", w.level.r1 == true)
check("...and stops once the 640 have left the storage", moved and moved >= 640, moved)
check("the drone is asked to latch, and only then the pusher goes up", w.asked[1].what == "dock"
  and w.asked[1].t <= up.t)
check("the drone sticks while the pusher is up", w.asked[2] and w.asked[2].what == "stick" and w.asked[2].pusherUp == true)
check("then the pusher comes down, and everything but the belt is off", w.level.r7 == false and allOff(w, "r1"))
check("side A now has no silo: it went with the drone", w.silos.A == "none")

print("loading, with an empty silo already waiting")
w = dock({ silo = "empty" })
w.flow, w.flowUntil = -50, 10
ok = D.load(CFG, "A", w.io)
check("no silo is placed, nothing assembled", ok and not firstOn(w, "r10") and not firstOn(w, "r6"))
check("with no count, the fill ends when the storage goes still", ok)

print("unloading")
w = dock()
w.io.drone = function(what)
  w.asked[#w.asked + 1] = { what = what, t = w.t, pusherUp = w.level.r7 }
  if what == "release" then w.flow, w.flowUntil = 32, w.t + 30 end   -- a silo arrives, then drains into storage
  return true
end
ok, whyL, at, moved = D.unload(CFG, "A", w.io)
check("it finishes", ok and at == "done", whyL)
check("the pusher is up before the drone lets go", w.asked[1].what == "release" and w.asked[1].pusherUp == true)
check("the belt runs the emptying way: ON", firstOn(w, "r1") ~= nil)
check("...and it counts what came out", moved and moved > 0, moved)
check("an empty silo is waiting on side A afterwards", w.silos.A == "empty")
check("everything but the belt is off at the end", allOff(w, "r1"))
check("...and the belt stays at unloading, the level an empty silo wants", w.level.r1 == true)
w = dock({ silo = "empty" })
ok, whyL = D.unload(CFG, "A", w.io)
check("a side that already has a silo is refused before anything moves", not ok
  and (function() for _, st in ipairs(w.sets) do if st.on then return false end end return true end)(), whyL)

print("when it goes wrong")
w = dock()
ok, whyL, at = D.load(CFG, "A", w.io)        -- the storage never moves
check("nothing to fill with: called off at fill, and says why", not ok and at == "fill"
  and tostring(whyL):find("nothing moved", 1, true), whyL)
check("...the silo it made is remembered, ready for next time", w.silos.A == "empty")
w = dock({ droneSays = { stick = false } })
w.flow, w.flowUntil = -64, 20
ok, whyL, at = D.load(CFG, "A", w.io, 640)
check("the drone does not stick: called off, and the pusher comes back down", not ok and at == "stick"
  and w.level.r7 == false, whyL)
w = dock({ stopAt = 3 })
w.flow = -10
ok, whyL, at = D.load(CFG, "A", w.io)
check("stopped by the operator part way: called off, all off", not ok and tostring(whyL):find("operator", 1, true)
  and allOff(w), whyL)
w = dock()
ok, whyL = D.load(CFG, "C", w.io)
check("a side the dock does not have is refused", not ok and tostring(whyL):find("no side C", 1, true), whyL)

print("with a laser across each bay")
local DCFG = D.check({
  sides = { A = { place = "r10", assemble = "r6", pusher = "r7" } },
  storage = { "store" }, detect = { A = "laser_sensor_0" },
  wait = { pulse = 1, place = 2, assemble = 3, push = 2, retract = 2, step = 1 },
  fill = { settle = 4, start = 10, max = 60 }, empty = { settle = 4, start = 10, max = 60 },
})
check("detect is kept, and a silo means the sensor is high by default", DCFG.detect.A == "laser_sensor_0"
  and DCFG.silo_when == "high")
check("the older words mean the same two things", D.check({ sides = { A = { pusher = "r" } }, silo_when = "blocked" })
  .silo_when == "low" and D.check({ sides = { A = { pusher = "r" } }, silo_when = "hit" }).silo_when == "high")
check("the test dock, from the second walk: assemblers 12 and 13, each side its own storage",
  real.sides.A.assemble == "redstone_relay_12" and real.sides.B.assemble == "redstone_relay_13"
  and real.sides.A.storage[1] == "create_connected:item_silo_2"
  and real.sides.B.storage[1] == "create_connected:item_silo_0")
check("...optical sensor 6 on A, 7 on B, inverted: no hit means a silo", real.detect.A == "optical_sensor_6"
  and real.detect.B == "optical_sensor_7" and real.silo_when == "low")
check("a side's own storage is counted on its own", (function()
  local c = D.check({ sides = { A = { pusher = "p", storage = { "a1", "a2" } }, B = { pusher = "q" } },
                     storage = { "shared" } })
  return c.sides.A.storage[2] == "a2" and c.sides.B.storage == nil and c.storage[1] == "shared"
end)())
bad({ sides = { A = { pusher = "r" } }, silo_when = "sometimes" }, "silo_when that is neither is refused")
-- a bay the laser watches: a silo appears when the placer runs, goes when
-- the pusher comes down after a stick, arrives when the drone lets go
local function laserDock(opts)
  opts = opts or {}
  local w = dock({ store = opts.store or 3000, silo = opts.memory })
  w.inBay = opts.inBay or false
  local set = w.io.set
  w.io.set = function(relay, on)
    if relay == "r10" and on and not opts.placerBroken then w.inBay = true end
    if relay == "r7" and not on and w.stuck and not opts.droneKeeps then w.inBay = false end
    return set(relay, on)
  end
  w.io.present = function(side)
    if side ~= "A" then return nil end
    return w.inBay == true
  end
  w.io.drone = function(what)
    w.asked[#w.asked + 1] = { what = what, t = w.t }
    if what == "stick" then w.stuck = true end
    if what == "release" and not opts.nothingArrives then w.inBay = true w.flow, w.flowUntil = 30, w.t + 20 end
    return true
  end
  return w
end
w = laserDock()
w.flow = -64
ok, whyL = D.load(DCFG, "A", w.io, 640)
check("a load it can see: place, confirm, assemble, fill, stick, confirm gone", ok, whyL)
check("...and the bay is clear at the end", w.inBay == false and w.silos.A == "none")

w = laserDock({ inBay = true })
w.flow = -64
ok = D.load(DCFG, "A", w.io, 640)
check("a silo in the bay that memory did not know about is used, not placed over", ok and not firstOn(w, "r10"))

w = laserDock({ inBay = true, memory = "full" })
ok = D.load(DCFG, "A", w.io)
check("a silo it filled before is sent as it is: no second fill", ok and not firstOn(w, "r10")
  and (function() for _, l in ipairs(w.said) do if l:find("^fill:") then return false end end return true end)())

w = laserDock({ memory = "empty" })
w.flow = -64
ok = D.load(DCFG, "A", w.io, 640)
check("memory says a silo, the laser says none: it believes the laser and places one", ok and firstOn(w, "r10") ~= nil)

w = laserDock({ placerBroken = true })
ok, whyL, at = D.load(DCFG, "A", w.io)
check("the placer ran but no silo appeared: called off, and says so", not ok and at == "place"
  and tostring(whyL):find("does not see one", 1, true) ~= nil, whyL)
check("...before anything was assembled", not firstOn(w, "r6"))

w = laserDock({ droneKeeps = true })
w.flow = -64
ok, whyL, at = D.load(DCFG, "A", w.io, 640)
check("the pusher came down and the silo is still there: the drone did not take it", not ok
  and tostring(whyL):find("did not take it", 1, true) ~= nil, whyL)

w = laserDock()
ok, whyL, at, moved = D.unload(DCFG, "A", w.io)
check("an unload it can see: clear bay, release, silo arrives, emptied", ok and moved and moved > 0
  and w.silos.A == "empty", whyL)
w = laserDock({ inBay = true, memory = "none" })
ok, whyL = D.unload(DCFG, "A", w.io)
check("the laser sees a silo in the bay: unload refused, whatever memory says", not ok
  and tostring(whyL):find("already has a silo", 1, true) ~= nil, whyL)
w = laserDock({ nothingArrives = true })
ok, whyL, at = D.unload(DCFG, "A", w.io)
check("the drone let go but nothing arrived: called off, says so", not ok and at == "retract"
  and tostring(whyL):find("no silo arrived", 1, true) ~= nil, whyL)

print("a sensor that cannot be read")
w = laserDock({ memory = "empty" })
w.io.present = function() return nil end        -- the name in dock.lua is not what the dock sees
ok, whyL, at = D.load(DCFG, "A", w.io)
check("a side with a sensor it cannot read stops before anything moves", not ok and at == "silo"
  and tostring(whyL):find("cannot be read", 1, true) ~= nil
  and (function() for _, st in ipairs(w.sets) do if st.on then return false end end return true end)(), whyL)
check("...rather than trusting memory's empty silo", w.silos.A == "empty")
w = laserDock({ memory = "empty" })
w.io.present = function() return nil end
ok, whyL = D.unload(DCFG, "A", w.io)
check("an unload the same", not ok and tostring(whyL):find("cannot be read", 1, true) ~= nil, whyL)
w = laserDock({ memory = "full" })          -- memory says full; the sensor sees nothing
w.flow = -64
ok, whyL, at = D.load(DCFG, "A", w.io, 640)
check("memory says a filled silo, the sensor says none: it makes a new one, never loads toward nothing",
  ok and firstOn(w, "r10") ~= nil, whyL)

print("a belt that never stops (Alex's: HIGH loads, LOW unloads)")
local BCFG = D.check({
  sides = { A = { place = "r10", assemble = "r6", pusher = "r7", belt = "r2", belt_on = "fills" },
            B = { pusher = "r9", belt = "r1" } },
  storage = { "store" },
  wait = { pulse = 1, place = 2, assemble = 3, push = 2, retract = 2, step = 1 },
  fill = { settle = 4, start = 10, max = 60 }, empty = { settle = 4, start = 10, max = 60 },
})
check("a belt's direction can be set per side", BCFG.sides.A.belt_on == "fills" and BCFG.sides.B.belt_on == nil)
check("...and a side whose direction is unknown is left alone", D.beltFor(BCFG, "fill", "B") == nil)
local function beltDock(opts)
  local w = dock(opts)
  w.io.drone = function(what)
    w.asked[#w.asked + 1] = { what = what, belt = w.level.r2 }
    if opts and opts.noStick and what == "stick" then return false, "no" end
    if what == "release" then w.flow, w.flowUntil = 30, w.t + 20 end
    return true
  end
  return w
end
w = beltDock({ store = 3000 })
w.flow = -64
ok = D.load(BCFG, "A", w.io, 640)
check("HIGH from the fill, still HIGH while the drone latches and sticks", ok and w.asked[1].belt == true
  and w.asked[2].belt == true)
check("LOW once the silo has gone with the drone", w.level.r2 == false)
check("never LOW between the fill and the silo leaving", (function()
  local filling = false
  for _, s in ipairs(w.sets) do
    if s.relay == "r2" and s.on then filling = true end
    if s.relay == "r2" and not s.on and filling and s.t < (firstOn(w, "r7") or { t = 1e9 }).t + 2 then return false end
  end
  return true
end)())
w = beltDock({ store = 3000, noStick = true })
w.flow = -64
ok = D.load(BCFG, "A", w.io, 640)
check("the drone would not stick: the belt is left HIGH, so the filled silo stays filled",
  not ok and w.level.r2 == true and w.silos.A == "full")
w = beltDock({ silo = "full" })
ok = D.load(BCFG, "A", w.io)
check("sending a silo filled earlier: HIGH while it waits, even with no fill", ok and w.asked[1].belt == true)
w = beltDock()
ok = D.unload(BCFG, "A", w.io)
check("an unload runs it LOW, and leaves it LOW", ok and w.level.r2 == false and not firstOn(w, "r2"))
check("the test dock: A's belt is relay 2, B's is relay 1, both load at HIGH",
  real.sides.A.belt == "redstone_relay_2" and real.sides.B.belt == "redstone_relay_1"
  and D.beltFor(real, "fill", "A") == true and D.beltFor(real, "empty", "B") == false)

print("the belt's direction")
check("ON empties: fill is OFF, empty is ON", D.beltFor(CFG, "fill", "A") == false
  and D.beltFor(CFG, "empty", "A") == true)
check("a side with no belt: left alone", D.beltFor(CFG, "fill", "B") == nil)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then error("dockseq tests failed", 0) end
