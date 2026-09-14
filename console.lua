-- console: the DroneNet flight operations wall, on the base computer.
--
--   console          listen for sealed drone telemetry and draw it
--   console demo     draw the built-in demo fleet (no radio needed)
--   console insecure also accept PLAINTEXT packets (bench testing only)
--
-- Needs an advanced monitor (the biggest one attached is used; a 5x5 at text
-- scale 0.5 is 100x66) and, for live data, a wireless or ender modem. The
-- console only LISTENS on the telemetry channel. It sends nothing and obeys
-- nothing. Packets are opened with the drone's key from .fleetkeys (seckey new
-- <id>); a packet that fails its tag, replays an old one, or is plaintext is
-- dropped and counted as REJ on the wall.
--
-- The look is a theme: imperial (default) or silo. Switch it on this computer
-- with  set dronenet.theme silo  (or imperial) and restart the console.
--
-- Touch a drone in the FLEET list to select it. Scheduled trips come from an
-- optional schedule.lua returning a list of
--   { id = "M-0043", drone = "drone-2", kind = "courier", at = <console seconds>,
--     pts = { { x = -1500, z = 2200 } } }
-- until ops.lua schedules them for real.

local link = dofile("lib/link.lua")
local D = dofile("lib/display.lua")
local args = { ... }
local demo, insecure = args[1] == "demo", args[1] == "insecure"
local okS, SEC = pcall(dofile, "lib/seclink.lua")
if not okS or type(SEC) ~= "table" then
  print("console: lib/seclink.lua would not load: " .. tostring(SEC))
  SEC = nil
end
local fleet, nKeys = {}, 0
if SEC then fleet, nKeys = SEC.readFleetKeys(".fleetkeys") end

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
local themeName = (settings and settings.get("dronenet.theme")) or "imperial"
if not D.setTheme(themeName) then
  print("console: unknown theme " .. tostring(themeName) .. " - using imperial")
  themeName = "imperial"
  D.setTheme(themeName)
end
D.applyPalette(mon)
mon.setBackgroundColour(colours.black)
mon.clear()

local canvas = D.canvas(mon.getSize())
local model = D.newModel()
model.link = insecure and "INSECURE" or ((SEC and nKeys > 0) and ("SEALED " .. nKeys .. " KEY" .. (nKeys == 1 and "" or "S")) or "NO KEYS")
local t0 = os.clock()
if not demo and not insecure and nKeys == 0 then
  print("console: no .fleetkeys - every packet will be refused. On this computer: seckey new <drone id>")
end

if fs.exists("schedule.lua") then
  local ok, s = pcall(dofile, "schedule.lua")
  if ok and type(s) == "table" then model.scheduled = s else print("schedule.lua ignored: " .. tostring(s)) end
end

print(string.format("console: %s %dx%d, %s theme%s", monName, canvas.w, canvas.h, themeName, demo and " (demo)" or ""))

local rejected = 0
local function receive()
  if demo then while true do sleep(3600) end end
  local radio = link.findRadio(peripheral)
  if not radio then
    print("console: no wireless modem - the wall will show NO CONTACT")
    while true do sleep(3600) end
  end
  peripheral.call(radio, "open", link.CHANNEL)
  local rx = SEC and SEC.receiver()
  print("console: listening on " .. radio .. " channel " .. link.CHANNEL .. " - " .. model.link)
  while true do
    local _, _, ch, _, msg = os.pullEvent("modem_message")
    if ch == link.CHANNEL and type(msg) == "table" then
      local now = os.clock() - t0
      local body
      if msg.sl then
        -- sealed: only a drone holding its key can have made this, and only
        -- once; anything else is dropped before a single field is read
        if rx then
          local ok, b = pcall(rx.open, msg, function(id) return fleet[id] end, SEC.DIR.DRONE_TO_BASE, 120000)
          if ok and b then body = b else rejected = rejected + 1 end
        else
          rejected = rejected + 1
        end
      elseif insecure then
        body = msg
      else
        rejected = rejected + 1
      end
      if body then
        if body.type == "plan" and type(body.id) == "string" then
          D.ingestPlan(model, body, now)
        elseif link.check(body) then
          D.ingest(model, body, now)
        end
      end
      model.rejected = rejected
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
