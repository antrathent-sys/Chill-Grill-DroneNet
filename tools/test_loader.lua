-- Desktop tests for lib/loader.lua: what a silo holds, how a load is split
-- across the bays, and whole loads run against a pretend station and drone.
local DIR = ...
local pass, fail = 0, 0
local function check(n, c, d)
  if c then pass = pass + 1 print("  ok   " .. n)
  else fail = fail + 1 print("  FAIL " .. n .. (d and ("  " .. tostring(d)) or "")) end
end

local L = dofile(DIR .. "/../lib/loader.lua")
local F = dofile(DIR .. "/../lib/fleet.lua")
local C = dofile(DIR .. "/../lib/cargo.lua")

local function R(n, side) return { relay = "redstone_relay_" .. n, side = side or "top" } end
local function station(over)
  local c = {
    dock = "home",
    place = { left = R(0), right = R(1) },
    assemble = { left = R(2), right = R(2, "bottom") },
    lift = R(3), retract = R(3, "bottom"),
    stick = { left = "Create_Sticker_0", right = "Create_Sticker_1" },
    fill = { secs = 10 },
    wait = { place = 1, assemble = 1, lift = 2, stick = 1, retract = 2, fill = 30, dock = 20 },
  }
  for k, v in pairs(over or {}) do if v == "none" then c[k] = nil else c[k] = v end end
  return c
end

print("the station's layout")
local cfg, why = L.check(station())
check("the example layout is good", cfg ~= nil, why)
check("a 3x1 silo holds 60 stacks by default", cfg and cfg.capacity == 60)
check("two bays, left then right", cfg and #cfg.bays == 2 and cfg.bays[1] == "left" and cfg.bays[2] == "right")
check("the example file itself checks out", (L.check(dofile(DIR .. "/../station.example.lua"))) ~= nil,
  select(2, L.check(dofile(DIR .. "/../station.example.lua"))))
local function bad(over, what)
  local c, w = L.check(station(over))
  check(what, c == nil, w)
end
bad({ place = false }, "no place relay is refused")
bad({ lift = false }, "no lift relay is refused")
bad({ fill = false }, "no fill rule is refused")
bad({ stick = { left = "Create_Sticker_0" } }, "a bay with no sticker is refused")
bad({ stick = { left = "x; os.shutdown()", right = "y" } }, "a sticker name that is not a name is refused")
bad({ single = "middle" }, "single must be a bay")
bad({ place = { left = { side = 3 } } }, "a face with no side is refused")
local one = L.check(station({ place = R(0), stick = "Create_Sticker_0" }))
check("one shared place face is one bay", one and #one.bays == 1)

print("how much, and where")
local p = L.plan(cfg, 1000)
check("1000 of a 64-stack item: 16 stacks, one silo, left", p and p.stacks == 16 and p.silos == 1 and p.sides[1] == "left")
check("...27% full", p and p.full == 27, p and p.full)
p = L.plan(cfg, 3840)
check("3840 fills one silo exactly", p and p.silos == 1 and p.full == 100)
p = L.plan(cfg, 3841)
check("3841 takes two, both bays", p and p.silos == 2 and p.sides[1] == "left" and p.sides[2] == "right")
check("...split evenly across the drone", p and p.share.left == 1921 and p.share.right == 1920)
check("...both stickers", p and p.stickers[1] == "Create_Sticker_0" and p.stickers[2] == "Create_Sticker_1")
local nope, whyN = L.plan(cfg, 7681)
check("7681 does not fit, and says why", nope == nil and tostring(whyN):find("7680", 1, true), whyN)
check("the most is 7680 of a 64-stack item", L.maxItems(cfg, 64) == 7680)
p = L.plan(cfg, 961, 16)
check("eggs stack to 16: 961 is 61 stacks, two silos", p and p.stacks == 61 and p.silos == 2)
p = L.plan(cfg, 100, 64, 70)
check("stacks counted from the intake win", p and p.silos == 2)
local right = L.check(station({ single = "right" }))
p = L.plan(right, 10)
check("single = right puts one silo on the right", p and p.sides[1] == "right" and p.stickers[1] == "Create_Sticker_1")
check("nothing to load is refused", L.plan(cfg, 0) == nil)
local items, stacks = L.stacksOf({ { count = 100, max = 64 }, { count = 20, max = 16 }, { count = 3, max = 1 } })
check("stacks by item: 100 cobble + 20 eggs + 3 swords = 2 + 2 + 3", items == 123 and stacks == 7, stacks)
check("the sequence reads as 8 steps", #L.describe(cfg, L.plan(cfg, 10)) == 8)

-- --------------------------------------------------------------- a whole load
-- A pretend station: a clock that sleep() moves on, every relay change in a
-- list, an intake that empties, a drone that docks at some time.
local function world(opts)
  opts = opts or {}
  local w = { t = 0, sets = {}, said = {}, stuck = nil, flew = nil, level = {} }
  local function key(face) return (face.relay or "computer") .. ":" .. face.side end
  w.io = {
    set = function(face, on)
      if opts.brokenRelay and face.relay == opts.brokenRelay then return false, "no such peripheral" end
      w.sets[#w.sets + 1] = { t = w.t, k = key(face), on = on }
      w.level[key(face)] = on
      return true
    end,
    sleep = function(s) w.t = w.t + (s or 0) end,
    now = function() return w.t end,
    count = function(inv) return opts.count and opts.count(w, inv) end,
    input = function(face) return opts.input and opts.input(w, face) end,
    docked = function()
      if opts.dockAt and w.t < opts.dockAt then return false, "not docked" end
      return true
    end,
    stick = function(names)
      w.stuck = { t = w.t, names = names }
      if opts.stickFails then return false, "Create_Sticker_1 is not a sticker on this drone" end
      return true
    end,
    liftoff = function(args) w.flew = args return true end,
    say = function(step, text) w.said[#w.said + 1] = step .. ": " .. text end,
    stopped = function() return opts.stopAt and w.t >= opts.stopAt end,
  }
  return w
end
local function firstOn(w, k)
  for _, s in ipairs(w.sets) do if s.k == k and s.on then return s end end
end
local function onCount(w, k)
  local n = 0
  for _, s in ipairs(w.sets) do if s.k == k and s.on then n = n + 1 end end
  return n
end
local function allAtRest(w, c)
  for _, face in ipairs(L.allFaces(c)) do
    local k = (face.relay or "computer") .. ":" .. face.side
    local want = face.invert and true or false
    if w.level[k] ~= nil and w.level[k] ~= want then return false, k end
  end
  return true
end

print("a load, start to finish")
local w = world()
local plan = L.plan(cfg, 1000)
local ok, whyR, at = L.run(cfg, plan, w.io)
check("it finishes", ok and at == "done", whyR)
local place, asm, lift, ret = firstOn(w, "redstone_relay_0:top"), firstOn(w, "redstone_relay_2:top"),
  firstOn(w, "redstone_relay_3:top"), firstOn(w, "redstone_relay_3:bottom")
check("place, then assemble, then lift, then retract", place and asm and lift and ret
  and place.t < asm.t and asm.t < lift.t and lift.t < ret.t)
check("one silo: only the left bay is placed", onCount(w, "redstone_relay_1:top") == 0)
check("the fill waits its 10 s before the assembler", asm and place and asm.t - place.t >= 10 + 1)
check("the drone sticks once the lift has had its 2 s", w.stuck and lift and w.stuck.t >= lift.t + 2)
check("...the left sticker only", w.stuck and #w.stuck.names == 1 and w.stuck.names[1] == "Create_Sticker_0")
check("the lift is lowered only after the stick", ret and w.stuck and ret.t > w.stuck.t)
check("every pulse ends: all faces at rest", allAtRest(w, cfg))
check("no liftoff set: the drone is not flown", w.flew == nil)

print("two silos, and a liftoff")
w = world()
local cfg2 = L.check(station({ liftoff = "ferry pier" }))
ok = L.run(cfg2, L.plan(cfg2, 5000), w.io)
check("both bays placed", ok and onCount(w, "redstone_relay_0:top") == 1 and onCount(w, "redstone_relay_1:top") == 1)
check("both assemblers clicked", onCount(w, "redstone_relay_2:top") == 1 and onCount(w, "redstone_relay_2:bottom") == 1)
check("both stickers", w.stuck and #w.stuck.names == 2)
check("then it lifts off", w.flew == "ferry pier")

print("the drone arrives late")
w = world({ dockAt = 15 })
ok = L.run(cfg, L.plan(cfg, 10), w.io)
lift = firstOn(w, "redstone_relay_3:top")
check("fill and assembly go ahead without it; the lift waits", ok and lift and lift.t >= 15, lift and lift.t)
w = world({ dockAt = 1000 })
ok, whyR, at = L.run(cfg, L.plan(cfg, 10), w.io)
check("it never comes: called off at dock, nothing lifted", not ok and at == "dock" and
  onCount(w, "redstone_relay_3:top") == 0, whyR)

print("knowing the fill is done")
local fcfg = L.check(station({ fill = { intake = "minecraft:chest_0", settle = 2 } }))
-- the fill starts at 1.5 s (place pulse + wait); 100 a second leave the intake
w = world({ count = function(ww) return math.max(0, 1000 - math.floor(ww.t - 1.5) * 100) end })
ok, whyR = L.run(fcfg, L.plan(fcfg, 1000), w.io)
asm = firstOn(w, "redstone_relay_2:top")
check("intake: assembles once 1000 have left it (10 s) and settled", ok and asm and asm.t >= 12 and asm.t < 16, asm and asm.t)
w = world({ count = function() return 1000 end })
ok, whyR, at = L.run(fcfg, L.plan(fcfg, 1000), w.io)
check("intake that never empties: called off at fill, with how far it got", not ok and at == "fill"
  and tostring(whyR):find("0 of 1000", 1, true), whyR)
check("...and nothing assembled", onCount(w, "redstone_relay_2:top") == 0)
local vcfg = L.check(station({ fill = { inv = "create:item_vault_0" } }))
w = world({ count = function(ww) return math.floor(ww.t) * 50 end })
ok = L.run(vcfg, L.plan(vcfg, 500), w.io)
check("silo count: done when the silo holds the load", ok)
local scfg = L.check(station({ fill = { input = R(4, "back"), level = 15 } }))
w = world({ input = function(ww) return ww.t >= 6 and 15 or 3 end })
ok = L.run(scfg, L.plan(scfg, 500), w.io)
asm = firstOn(w, "redstone_relay_2:top")
check("signal: waits for the threshold switch", ok and asm and asm.t >= 6, asm and asm.t)

print("when it goes wrong")
w = world({ stickFails = true })
ok, whyR, at = L.run(cfg, L.plan(cfg, 10), w.io)
check("the drone cannot stick: called off at stick", not ok and at == "stick", whyR)
check("...and the lift comes back down", onCount(w, "redstone_relay_3:bottom") == 1)
check("...faces at rest", allAtRest(w, cfg))
w = world({ stopAt = 3 })
ok, whyR, at = L.run(cfg, L.plan(cfg, 10), w.io)
check("stopped by the operator during the fill", not ok and at == "fill" and tostring(whyR):find("operator"), whyR)
check("...nothing was lifted, so nothing is lowered", onCount(w, "redstone_relay_3:bottom") == 0)
w = world({ brokenRelay = "redstone_relay_2" })
ok, whyR, at = L.run(cfg, L.plan(cfg, 10), w.io)
check("a relay that is not there stops it and names it", not ok and tostring(whyR):find("redstone_relay_2", 1, true), whyR)

print("held and inverted faces")
local hcfg = L.check(station({ lift = { relay = "redstone_relay_3", side = "top", hold = true }, retract = "none" }))
w = world()
w.io.stick = function(names)
  w.stuck = { t = w.t, up = w.level["redstone_relay_3:top"] }
  return true
end
ok = L.run(hcfg, L.plan(hcfg, 10), w.io)
check("a held lift is still up when the drone sticks", ok and w.stuck and w.stuck.up == true)
check("...and let go after, with no retract relay at all", w.level["redstone_relay_3:top"] == false
  and onCount(w, "redstone_relay_3:bottom") == 0)
local icfg = L.check(station({ assemble = { relay = "redstone_relay_2", side = "top", invert = true } }))
w = world()
ok = L.run(icfg, L.plan(icfg, 10), w.io)
local sets = {}
for _, s in ipairs(w.sets) do if s.k == "redstone_relay_2:top" then sets[#sets + 1] = s.on end end
check("an inverted face rests ON, the action switches it off and back",
  ok and sets[1] == true and sets[2] == false and sets[3] == true, table.concat((function()
    local t = {} for i, v in ipairs(sets) do t[i] = tostring(v) end return t end)(), ","))

print("a relay on its own")
local allcfg = L.check(station({ place = { relay = "redstone_relay_7" }, stick = "Create_Sticker_0" }))
check("a relay with no side is a face spec", allcfg ~= nil and allcfg.place.relay == "redstone_relay_7"
  and allcfg.place.side == nil, select(2, L.check(station({ place = { relay = "redstone_relay_7" } }))))
check("...and says so when described", L.describeIO({ relay = "r" }) == "r:every face")
local P = { isPresent = function() return true end, call = function(n, m, side, on)
  allFired = allFired or {}
  if m == "setOutput" and on then allFired[#allFired + 1] = side end
  return true
end }
allFired = {}
local hands = L.station(allcfg, P, { setOutput = function() end, getAnalogInput = function() return 0 end }, C)
hands.set({ relay = "redstone_relay_7" }, true)
check("driving it drives every face", #allFired == 6, #allFired)
allFired = {}
hands.set({ relay = "redstone_relay_7", side = "top" }, true)
check("...and one named face drives only that one", #allFired == 1 and allFired[1] == "top")

print("counting what went in")
local ccfg = L.check(station({ silo = { left = "create:item_vault_0", right = "create:item_vault_1" },
                               intake = "minecraft:chest_0" }))
check("the silos and the intake to count from are kept", ccfg and ccfg.silo.right == "create:item_vault_1"
  and ccfg.intake == "minecraft:chest_0")
check("a fill that watches the intake is also where it counts from",
  L.check(station({ fill = { intake = "minecraft:barrel_0" } })).intake == "minecraft:barrel_0")
bad({ silo = 7 }, "a silo that is not a peripheral name is refused")
w = world()
local planC = L.plan(ccfg, 10)
local counted, before
w.io.beforeFill = function() before = w.t end
w.io.manifest = function() counted = w.t return { left = { ["minecraft:cobblestone"] = 10 } }, "read from the silos" end
ok = L.run(ccfg, planC, w.io)
asm = firstOn(w, "redstone_relay_2:top")
check("counted once the fill is done, while the silos are still blocks", ok and before and counted and asm
  and before < counted and counted <= asm.t and planC.manifest.left["minecraft:cobblestone"] == 10)
check("...and says how", planC.counted == "read from the silos")
w = world()
w.io.manifest = function() return { left = {} }, "read from the silos" end
ok, whyR, at = L.run(ccfg, L.plan(ccfg, 10), w.io)
check("silos that count empty call it off before anything is assembled", not ok and at == "fill"
  and tostring(whyR):find("empty", 1, true) and onCount(w, "redstone_relay_2:top") == 0, whyR)

print("the drone's messages")
local m = F.stick("load-1", { "Create_Sticker_0", "Create_Sticker_1" }, true, "n-1")
check("a stick order is a valid message", (F.check(m)))
check("...and the names come back out", #F.stickers(m) == 2 and F.stickers(m)[2] == "Create_Sticker_1")
check("on = false is a retract", F.stick("load-1", { "a" }, false, "n").on == false)
local evil = F.stick("load-1", { "a" }, true, "n")
evil.stickers = "a;shell.run('rm')"
check("a sticker list with anything but names is refused", not F.check(evil))
check("the answer is a valid message", (F.check(F.stuck("load-1", "drone-1", true, nil, "Create_Sticker_0 out", "n"))))

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then error("loader tests failed", 0) end
