-- Desktop tests for navprep.lua: the turtle that switches the kiosk's new
-- computers on once, against a fake turtle with a chest above, a chest
-- below and whatever stands in front of it.
local DIR = ...
local pass, fail = 0, 0
local function check(n, c, d)
  if c then pass = pass + 1 print("  ok   " .. n)
  else fail = fail + 1 print("  FAIL " .. n .. (d and ("  " .. tostring(d)) or "")) end
end
local SRC = DIR .. "/../navprep.lua"
local PC = "computercraft:computer_advanced"

local function world(o)
  o = o or {}
  local w = { above = o.above or {}, below = {}, belowCap = o.belowCap or 99, slots = {}, sel = 1,
              front = o.front, nextId = 40, out = {}, sleeps = 0, pick = o.pick ~= false,
              idDelay = o.idDelay or 1, onSleep = o.onSleep }
  local t = {}
  function t.select(s) w.sel = s return true end
  function t.getItemCount(s) return w.slots[s or w.sel] and 1 or 0 end
  function t.getItemDetail(s)
    local it = w.slots[s or w.sel]
    return it and { name = it.name, count = 1 }
  end
  function t.suckUp()
    if #w.above == 0 or w.slots[w.sel] then return false end
    w.slots[w.sel] = table.remove(w.above, 1)
    return true
  end
  function t.dropUp()
    local it = w.slots[w.sel]
    if not it then return false end
    table.insert(w.above, it) w.slots[w.sel] = nil
    return true
  end
  function t.dropDown()
    local it = w.slots[w.sel]
    if not it or #w.below >= w.belowCap then return false end
    w.below[#w.below + 1] = it w.slots[w.sel] = nil
    return true
  end
  function t.detect() return w.front ~= nil end
  function t.place()
    local it = w.slots[w.sel]
    if w.front or not it then return false end
    w.front = it.name == PC and { computer = true, id = it.id } or { block = it.name }
    w.slots[w.sel] = nil
    return true
  end
  -- what is dug goes to the selected slot, or the first free one
  function t.dig()
    if not w.front then return false, "Nothing to dig here" end
    if not w.pick then return false, "No tool to dig with" end
    local drop = w.front.computer and { name = PC, id = w.front.id } or { name = w.front.block }
    w.front = nil
    local s = w.sel
    if w.slots[s] then for i = 1, 16 do if not w.slots[i] then s = i break end end end
    w.slots[s] = drop
    return true
  end
  function t.getEquippedLeft() return nil end
  function t.getEquippedRight() return w.pick and { name = "minecraft:diamond_pickaxe", count = 1 } or nil end
  local per = {}
  function per.getType(side) if side == "front" and w.front and w.front.computer then return "computer" end end
  -- an ID only the tick after it is switched on, as CC:Tweaked does it
  function per.call(side, m)
    local f = side == "front" and w.front and w.front.computer and w.front
    if not f then error("no peripheral on " .. side) end
    if m == "turnOn" then f.on, f.since = true, w.sleeps
    elseif m == "getID" then
      if f.id == nil and f.on and w.sleeps - f.since >= w.idDelay then f.id = w.nextId w.nextId = w.nextId + 1 end
      return f.id or -1
    end
  end
  w.turtle, w.peripheral = t, per
  return w
end

local function run(w, ...)
  local f = assert(loadfile(SRC))
  setfenv(f, setmetatable({ turtle = w.turtle, peripheral = w.peripheral,
    sleep = function(s)
      w.sleeps = w.sleeps + 1
      if w.sleeps > 5000 then error("ran forever", 0) end
      if w.onSleep then w.onSleep(w, s) end
    end,
    print = function(s) w.out[#w.out + 1] = tostring(s) end,
    printError = function(s) w.out[#w.out + 1] = "ERR " .. tostring(s) end }, { __index = _G }))
  local ok, err = pcall(f, ...)
  w.err = not ok and err or nil
  w.text = table.concat(w.out, "\n")
  return w
end

print("a new computer")
local w = run(world({ above = { { name = PC } } }), "once")
check("placed, switched on, dug back up, into the chest below with its ID", #w.below == 1 and w.below[1].id == 40
  and w.front == nil and #w.above == 0 and w.text:find("ready: computer 1 (ID 40)", 1, true), w.text)
check("...and nothing left in the turtle", next(w.slots) == nil)

local stack = world({ above = { { name = PC }, { name = PC }, { name = PC } },
  onSleep = function(w, s) if s == 5 then error("idle", 0) end end })
run(stack)
check("left running: the whole chest on top, one at a time, then it waits", #stack.below == 3
  and stack.below[3].id == 42 and stack.err == "idle", stack.text)

print("what it does not do")
local dirt = run(world({ above = { { name = "minecraft:dirt" } } }), "once")
check("anything but an advanced computer goes back on top, and it says so", dirt.above[1].name == "minecraft:dirt"
  and #dirt.below == 0 and dirt.text:find("only advanced computers", 1, true), dirt.text)
local blocked = run(world({ above = { { name = PC } }, front = { block = "minecraft:stone" } }), "once")
check("a block in front: it says to clear it and keeps the computer", blocked.front.block == "minecraft:stone"
  and blocked.slots[1] and blocked.slots[1].name == PC and blocked.text:find("clear the block", 1, true), blocked.text)
local nopick = run(world({ above = { { name = PC } }, pick = false }), "once")
check("no pickaxe: says so before placing anything", nopick.front == nil and #nopick.above == 1
  and nopick.text:find("needs a pickaxe", 1, true), nopick.text)

print("halfway and awkward")
local left = run(world({ front = { computer = true } }), "once")
check("a computer left in front by a reboot is finished first", #left.below == 1 and left.below[1].id == 40
  and left.front == nil, left.text)
local had = run(world({ above = { { name = PC, id = 7 } } }), "once")
check("one that already has an ID keeps it", had.below[1] and had.below[1].id == 7, had.text)
local full = run(world({ above = { { name = PC } }, belowCap = 0,
  onSleep = function(w, s) if s == 10 then w.belowCap = 5 end end }), "once")
check("the chest below full: it waits, then drops it", #full.below == 1 and full.text:find("full - waiting", 1, true),
  full.text)
local noid = run(world({ above = { { name = PC } }, idDelay = 1e9 }), "once")
check("switched on but no ID: back on top to try again, never into the stock", #noid.below == 0
  and #noid.above == 1 and noid.above[1].id == nil and noid.text:find("got no ID", 1, true), noid.text)

print("")
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then error("navprep tests failed", 0) end
