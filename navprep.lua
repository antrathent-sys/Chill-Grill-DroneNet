--- navprep: a mining turtle that gets the kiosk's computers ready
-- (AVIONICS.md). A computer goes onto a disk drive only once it has been
-- switched on once - that is when it gets its ID - so a new one from the
-- crafting table cannot be written as a kit. This does that, one at a time:
--
--   raw advanced computers go in the chest ON TOP of the turtle
--   it places one in front, switches it on, digs it back up (the ID stays
--   with the item) and drops it into the chest BELOW - the kiosk's computers
--
-- Needs a pickaxe (a mining turtle) and the block in front of it clear. Runs
-- on boot (startup role prep). `navprep once` does one computer and stops.

local COMPUTER = "computercraft:computer_advanced"
local args = { ... }

local function frontIsComputer()
  for _ = 1, 20 do
    if peripheral.getType("front") == "computer" then return true end
    sleep(0.05)
  end
  return false
end

local function freeSlot()
  for s = 1, 16 do if turtle.getItemCount(s) == 0 then return s end end
end

-- One computer into the chest below: true and its ID, or nil and why
-- ("empty" when there is nothing to do).
local function one()
  turtle.select(1)
  -- a computer already in front was left there halfway (a reboot, a chunk
  -- unloading): finish it rather than place another
  if peripheral.getType("front") ~= "computer" then
    if turtle.getItemCount(1) == 0 and not turtle.suckUp(1) then return nil, "empty" end
    local it = turtle.getItemDetail(1)
    if not it or it.name ~= COMPUTER then
      turtle.dropUp()
      return nil, "only advanced computers go in the chest on top - found " .. tostring(it and it.name)
    end
    if turtle.detect() then return nil, "clear the block in front of the turtle" end
    if not turtle.place() then return nil, "could not place the computer in front" end
    if not frontIsComputer() then
      turtle.dig()
      return nil, "placed it, but it does not show as a computer"
    end
  end
  pcall(peripheral.call, "front", "turnOn")
  local id
  for _ = 1, 40 do
    local ok, v = pcall(peripheral.call, "front", "getID")
    if ok and type(v) == "number" and v >= 0 then id = v break end
    sleep(0.05)
  end
  local slot = freeSlot()
  if not slot then return nil, "the turtle is full - empty it" end
  turtle.select(slot)
  local dug, why = turtle.dig()
  if not dug then return nil, "could not dig it back up (" .. tostring(why) .. ")" end
  -- no ID: back on top, to go round again
  if not id then
    turtle.dropUp()
    return nil, "it was switched on but got no ID - put back on top to try again"
  end
  while not turtle.dropDown() do
    print("the chest below is full - waiting")
    sleep(10)
  end
  return true, id
end

if not turtle then printError("navprep runs on a turtle") return end
local function isPick(e) return type(e) == "table" and tostring(e.name):find("pickaxe", 1, true) ~= nil end
if turtle.getEquippedLeft and not (isPick(turtle.getEquippedLeft()) or isPick(turtle.getEquippedRight())) then
  printError("navprep needs a pickaxe: craft the turtle with a diamond pickaxe (a mining turtle)")
  return
end

local once = args[1] == "once"
print("navprep: raw advanced computers in the chest on top;")
print("ready ones go in the chest below. Keep the front clear.")
local done = 0
while true do
  local ok, r = one()
  if ok then
    done = done + 1
    print(string.format("ready: computer %d (ID %d)", done, r))
    if once then return end
  elseif r == "empty" then
    if once then print("nothing in the chest on top") return end
    sleep(5)
  else
    print(r)
    if once then return end
    sleep(30)
  end
end
