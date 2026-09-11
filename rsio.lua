-- rsio: the redstone slave.
--
-- Runs on the small computer wedged into the airframe next to the docking
-- connector. The flight computer cannot reach that face - the 3x3's outer
-- ring is accumulators and cable, and the centre column above the connector
-- is the CC&A power connector - so it asks this computer to hold the signal
-- instead, over rednet on the craft's own wired network.
--
-- Set it as this computer's startup: it must come back on its own after a
-- chunk reload, or the drone silently loses the ability to dock.
--
--   rsio            listen forever, print what changes
--   rsio test       cycle every side once, for wiring checks. FIRES OUTPUTS.

local PROTOCOL = "drone-rs"
local BEAT     = 1.0     -- seconds between state broadcasts

local function openModem()
  local best
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      local okw, wireless = pcall(peripheral.call, name, "isWireless")
      if okw and wireless == false then best = name break end
      best = best or name
    end
  end
  if not best then error("no modem - this computer cannot hear the flight computer", 0) end
  rednet.open(best)
  return best
end

local function stateNow()
  local s = {}
  for _, side in ipairs(redstone.getSides()) do s[side] = redstone.getOutput(side) end
  return s
end

if ... == "test" then
  print("cycling every side, 1s each - outputs WILL fire")
  for _, side in ipairs(redstone.getSides()) do
    print("  " .. side .. " high") redstone.setOutput(side, true) sleep(1)
    redstone.setOutput(side, false)
  end
  print("done, all sides low")
  return
end

local modem = openModem()
print("rsio: redstone slave, id " .. os.getComputerID() .. " via " .. modem)
print("holding: (nothing yet)")

local function listen()
  while true do
    local _, msg = rednet.receive(PROTOCOL)
    if type(msg) == "table" then
      if msg.cmd == "set" and type(msg.side) == "string" then
        redstone.setOutput(msg.side, msg.on and true or false)
        print(string.format("%s -> %s", msg.side, tostring(msg.on and true or false)))
      elseif msg.cmd == "clear" then
        for _, side in ipairs(redstone.getSides()) do
          if side ~= msg.except then redstone.setOutput(side, false) end
        end
        print("cleared all except " .. tostring(msg.except))
      end
    end
  end
end

-- Broadcast the whole output state on a heartbeat. The flight computer warns
-- if this stops arriving, so a dead slave shows up before a docking attempt
-- rather than during one.
local function beat()
  while true do
    rednet.broadcast({ state = stateNow(), id = os.getComputerID() }, PROTOCOL)
    sleep(BEAT)
  end
end

parallel.waitForAny(listen, beat)
