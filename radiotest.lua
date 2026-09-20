-- radiotest: can these two computers hear each other, at all?
--
--   radiotest listen        print every packet that arrives, on any channel
--   radiotest ping [n]      send n packets (default 5) and print any answer
--   radiotest echo          answer every ping, so one computer can be left here
--
-- No keys, no protocols, no rednet: raw modem transmit and modem_message on
-- one channel. It exists to split "the order was refused" from "nothing
-- arrived", which look identical from the outside and have nothing in common.
--
-- The case it was written for: a drone's ender modem sending telemetry the
-- base receives perfectly, while nothing the base sends ever arrives. A modem
-- riding on a Create contraption is a good suspect - it transmits as a
-- peripheral but may never be handed an incoming packet - and this tells you
-- that in ten seconds instead of an evening.

local CH = 7213          -- next door to the fleet's channel, so it cannot confuse ops

local args = { ... }
local what = (args[1] or "listen"):lower()

local me = (os.getComputerLabel and os.getComputerLabel()) or ("computer-" .. tostring(os.getComputerID()))

local modems = {}
for _, nm in ipairs(peripheral.getNames()) do
  if peripheral.getType(nm) == "modem" then
    local ok, wireless = pcall(peripheral.call, nm, "isWireless")
    modems[#modems + 1] = { name = nm, wireless = ok and wireless or false }
  end
end
if #modems == 0 then
  print("radiotest: no modem on this computer at all")
  return
end

print("radiotest on " .. me .. ", channel " .. CH)
for _, m in ipairs(modems) do
  local opened = pcall(peripheral.call, m.name, "open", CH)
  local isOpen = select(2, pcall(peripheral.call, m.name, "isOpen", CH))
  print(string.format("  %-14s %s  open=%s", m.name, m.wireless and "wireless" or "wired  ",
    tostring(opened and isOpen)))
end

local function send(body)
  for _, m in ipairs(modems) do
    pcall(peripheral.call, m.name, "transmit", CH, CH, body)
  end
end

if what == "ping" then
  local n = tonumber(args[2]) or 5
  print("sending " .. n .. " pings, 1 s apart. Anything heard is printed.")
  local heard = 0
  parallel.waitForAny(function()
    for i = 1, n do
      send({ radiotest = "ping", from = me, i = i })
      print("  sent #" .. i)
      sleep(1)
    end
    sleep(3)
  end, function()
    while true do
      local _, side, ch, _, msg = os.pullEvent("modem_message")
      heard = heard + 1
      print(string.format("  HEARD on %s ch %d: %s", tostring(side), ch,
        type(msg) == "table" and (tostring(msg.radiotest) .. " from " .. tostring(msg.from)) or tostring(msg)))
    end
  end)
  print(heard == 0 and "nothing came back - this computer heard nothing at all"
                    or (heard .. " packet(s) heard"))
  return
end

if what == "echo" then
  print("echoing every ping. Q stops.")
  parallel.waitForAny(function()
    while true do
      local _, side, ch, _, msg = os.pullEvent("modem_message")
      if ch == CH and type(msg) == "table" and msg.radiotest == "ping" then
        print("  ping from " .. tostring(msg.from) .. " #" .. tostring(msg.i) .. " - answering")
        send({ radiotest = "pong", from = me, i = msg.i })
      end
    end
  end, function()
    while true do
      local _, k = os.pullEvent("char")
      if tostring(k):lower() == "q" then return end
    end
  end)
  return
end

print("listening. Every packet on channel " .. CH .. " is printed. Q stops.")
local n = 0
parallel.waitForAny(function()
  while true do
    local _, side, ch, reply, msg = os.pullEvent("modem_message")
    n = n + 1
    print(string.format("%3d  %s ch %d: %s", n, tostring(side), ch,
      type(msg) == "table" and textutils.serialise(msg):gsub("%s+", " ") or tostring(msg)))
  end
end, function()
  while true do
    local _, k = os.pullEvent("char")
    if tostring(k):lower() == "q" then return end
  end
end)
print(n .. " packet(s) heard")
