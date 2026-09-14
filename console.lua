-- console: the DroneNet flight operations wall, on the base computer.
--
--   console          listen for drone telemetry and draw it
--   console demo     draw the built-in demo fleet (no radio needed)
--
-- Needs an advanced monitor (the biggest one attached is used; a 5x5 at text
-- scale 0.5 is 100x66) and, for live data, a wireless or ender modem. The
-- console only LISTENS on the telemetry channel. It sends nothing and obeys
-- nothing, so there is nothing here to hijack - but until the link is signed
-- anyone could transmit a fake drone onto the wall (MISSIONCONTROL.md).
--
-- Touch a drone in the FLEET list to select it. Scheduled trips come from an
-- optional schedule.lua returning a list of
--   { id = "M-0043", drone = "drone-2", kind = "courier", at = <console seconds>,
--     pts = { { x = -1500, z = 2200 } } }
-- until ops.lua schedules them for real.

local link = dofile("lib/link.lua")
local D = dofile("lib/display.lua")
local demo = (... == "demo")

local function biggestMonitor()
  local best, area
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n) == "monitor" then
      local m = peripheral.wrap(n)
      pcall(m.setTextScale, 0.5)
      local w, h = m.getSize()
      if not area or w * h > area then best, area = n, w * h end
    end
  end
  return best
end

local monName = biggestMonitor()
if not monName then error("console: no monitor attached", 0) end
local mon = peripheral.wrap(monName)
mon.setTextScale(0.5)
if mon.isColour and not mon.isColour() then error("console: " .. monName .. " is not an advanced monitor", 0) end
D.applyPalette(mon)
mon.setBackgroundColour(colours.black)
mon.clear()

local canvas = D.canvas(mon.getSize())
local model = D.newModel()
local t0 = os.clock()

if fs.exists("schedule.lua") then
  local ok, s = pcall(dofile, "schedule.lua")
  if ok and type(s) == "table" then model.scheduled = s else print("schedule.lua ignored: " .. tostring(s)) end
end

print(string.format("console: %s %dx%d%s", monName, canvas.w, canvas.h, demo and " (demo)" or ""))

local function receive()
  if demo then while true do sleep(3600) end end
  local radio = link.findRadio(peripheral)
  if not radio then
    print("console: no wireless modem - the wall will show NO CONTACT")
    while true do sleep(3600) end
  end
  peripheral.call(radio, "open", link.CHANNEL)
  print("console: listening on " .. radio .. " channel " .. link.CHANNEL)
  while true do
    local _, _, ch, _, msg = os.pullEvent("modem_message")
    if ch == link.CHANNEL and type(msg) == "table" then
      local now = os.clock() - t0
      if msg.type == "plan" and type(msg.id) == "string" then
        D.ingestPlan(model, msg, now)
      elseif link.check(msg) then
        D.ingest(model, msg, now)
      end
    end
  end
end

local shown = model
local function draw()
  while true do
    local now = os.clock() - t0
    shown = demo and D.demoModel(now, model) or model
    D.render(canvas, shown, now)
    canvas:flush(mon)
    sleep(0.5)
  end
end

local function input()
  while true do
    local ev, side, x, y = os.pullEvent()
    if ev == "monitor_touch" and side == monName then
      local id = D.touch(canvas, shown, x, y)
      if id then model.selected = id end
    elseif ev == "monitor_resize" and side == monName then
      canvas = D.canvas(mon.getSize())
      mon.clear()
    end
  end
end

parallel.waitForAny(receive, draw, input)
