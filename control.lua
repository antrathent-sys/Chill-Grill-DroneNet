-- control: the base control room - three advanced monitors at text scale 1.
--
--   control            live, from sealed drone telemetry
--   control demo       the mock unit flying its loop (no radio needed)
--   control identify   show each monitor's number and name on it, to set them up
--   control insecure   also accept PLAINTEXT packets (bench testing only)
--
-- On the base it listens to the drones with .fleetkeys. On a computer of its
-- own it runs from the base's read-only feed instead (lib/watch.lua) - and
-- then it also shows what only the base knows: the real job, who it is for,
-- from and to, the queue and rides done. For that:
--   on the base:     seckey watch new screens       (then restart ops)
--   on this one:     seckey watch set disk   and   label set screens
-- It never needs a drone's key: the feed key opens the feed and nothing else.
--
--   DRONE     3x4 blocks, portrait     the unit: fuel, state, position, task
--   TACTICAL  6x4 blocks, landscape    the world map and a data rail
--   ORDER     3x4 blocks, portrait     the job in hand, its stage, today's counts
--
-- Which monitor is which, on this computer:
--   set dronenet.screen.drone monitor_1
--   set dronenet.screen.tactical monitor_2
--   set dronenet.screen.order monitor_3
-- Unset, they are guessed: the most landscape monitor is TACTICAL, and the
-- rest in name order are DRONE then ORDER. `control identify` shows the names.
--
-- Like console, it only LISTENS: packets are opened with .fleetkeys and a
-- packet that fails its tag, replays, or is plaintext is dropped and counted.
-- Base pads come from pads.lua on this computer (fly pad add writes it on the
-- drone; copy it or record it here). World spawn, if you want it on the map:
--   set dronenet.spawn 0,0
-- Make it start on boot with:  startup autorun control

local WATCH = dofile("lib/watch.lua")
local D = dofile("lib/display.lua")
local S = dofile("lib/state.lua")
local SC = dofile("lib/screens.lua")
local link = dofile("lib/link.lua")
local args = { ... }
local demo, insecure, identify = args[1] == "demo", args[1] == "insecure", args[1] == "identify"

local ROLES = { "drone", "tactical", "order" }

local function setting(name)
  return settings and settings.get(name) or nil
end

local function monitorNames()
  local list = {}
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n) == "monitor" then list[#list + 1] = n end
  end
  table.sort(list)
  return list
end

local function sizeAtOne(name)
  local m = peripheral.wrap(name)
  pcall(m.setTextScale, 1)
  return m.getSize()
end

-- role -> monitor name: settings first, the rest guessed by shape and name
local function assign(names)
  local out, used = {}, {}
  for _, role in ipairs(ROLES) do
    local n = setting("dronenet.screen." .. role)
    if n and peripheral.isPresent(n) then out[role], used[n] = n, true end
  end
  local free = {}
  for _, n in ipairs(names) do
    if not used[n] then free[#free + 1] = n end
  end
  if not out.tactical and #free > 0 then
    local best, shape = 1, -1
    for i, n in ipairs(free) do
      local w, h = sizeAtOne(n)
      if w / h > shape then best, shape = i, w / h end
    end
    out.tactical = table.remove(free, best)
  end
  if not out.drone and #free > 0 then out.drone = table.remove(free, 1) end
  if not out.order and #free > 0 then out.order = table.remove(free, 1) end
  return out
end

local names = monitorNames()
if #names == 0 then error("control: no monitors attached (wired modems switched on?)", 0) end
local roles = assign(names)

if identify then
  local roleOf = {}
  for role, n in pairs(roles) do roleOf[n] = role end
  for _, n in ipairs(names) do
    local m = peripheral.wrap(n)
    m.setTextScale(1)
    SC.applyPalette(m)
    local c = D.canvas(m.getSize())
    local num = n:match("(%d+)$")
    if num then c:bigText(5, 5, num, SC.K.white, 3) end
    SC.put(c, 2, c.h - 3, n, SC.K.ice)
    SC.put(c, 2, c.h - 1, "IS " .. (roleOf[n] and roleOf[n]:upper() or "UNUSED"), SC.K.lgrey)
    c:flush(m)
    print(string.format("%-12s %dx%d  %s", n, c.w, c.h, roleOf[n] and roleOf[n]:upper() or "unused"))
  end
  print("to change one:  set dronenet.screen.<drone|tactical|order> <name>")
  return
end

local screens = {}
for _, role in ipairs(ROLES) do
  local n = roles[role]
  if n then
    local m = peripheral.wrap(n)
    m.setTextScale(1)
    if m.isColour and not m.isColour() then print("control: " .. n .. " is not an advanced monitor - it will be grey") end
    SC.applyPalette(m)
    m.setBackgroundColour(colours.black)
    m.clear()
    local w, h = m.getSize()
    screens[#screens + 1] = { role = role, name = n, mon = m, canvas = D.canvas(w, h) }
    print(string.format("control: %-8s on %s (%dx%d)", role:upper(), n, w, h))
  else
    print("control: no monitor for " .. role:upper())
  end
end

-- base-side knowledge: pads and spawn
local pads = {}
do
  local okP, P = pcall(dofile, "lib/pads.lua")
  if okP and type(P) == "table" then
    local bad
    pads, bad = P.load("pads.lua", fs)
    for _, why in ipairs(bad) do print("pads: " .. why) end
  end
end
local spawn
do
  local sx, sz = tostring(setting("dronenet.spawn") or ""):match("^%s*(%-?[%d%.]+)%s*,%s*(%-?[%d%.]+)%s*$")
  if sx then spawn = { x = tonumber(sx), z = tonumber(sz) } end
end

-- the telemetry side, as in console.lua
local okS, SEC = pcall(dofile, "lib/seclink.lua")
if not okS or type(SEC) ~= "table" then SEC = nil end
local fleet, nKeys = {}, 0
if SEC then fleet, nKeys = SEC.readFleetKeys(".fleetkeys") end
-- no drone keys here, but a watcher key: run from the base's feed
local me = os.getComputerLabel and os.getComputerLabel()
local watchKey = (SEC and nKeys == 0 and not demo and not insecure) and SEC.readKeyFile(".watchkey") or nil
local watching = watchKey ~= nil and me ~= nil
local model = D.newModel()
model.link = insecure and "INSECURE" or (watching and "SEALED FEED")
  or ((SEC and nKeys > 0) and ("SEALED " .. nKeys .. " KEY" .. (nKeys == 1 and "" or "S")) or "NO KEYS")
model.rejected = 0
local track = S.newTrack()
local t0 = os.clock()
local sim = demo and S.mock(D, { ops = true }) or nil
if watchKey and not me then
  print("control: a watcher key but no label - label set <the name it was made for>")
elseif not demo and not insecure and nKeys == 0 and not watching then
  print("control: no keys - every packet will be refused. Screens on their own computer: seckey watch set disk")
end

local function receive()
  if demo then while true do sleep(3600) end end
  local radio = link.findRadio(peripheral)
  if not radio then
    print("control: no wireless modem - every unit will show OFFLINE")
    while true do sleep(3600) end
  end
  local chan = watching and WATCH.CHANNEL or link.CHANNEL
  peripheral.call(radio, "open", chan)
  local rx = SEC and SEC.receiver()
  print("control: listening on " .. radio .. " channel " .. chan .. " - " .. model.link
    .. (watching and (" as " .. me) or ""))
  while true do
    local _, _, ch, _, msg = os.pullEvent("modem_message")
    if ch == chan and type(msg) == "table" then
      local now = os.clock() - t0
      local body
      if watching then
        -- the feed: sealed to this computer's name; another watcher's is not ours to count
        if msg.sl and msg.id == me then
          local ok, b = pcall(rx.open, msg, function(id) return id == me and watchKey or nil end,
                              SEC.DIR.BASE_TO_WATCH, 120000)
          if ok and b then
            body = WATCH.unwrap(b)
            if body.type == "ops" then
              model.ops, model.opsAt = WATCH.parse(body), now
              body = nil
            end
          else
            model.rejected = model.rejected + 1
          end
        end
      elseif msg.sl then
        if rx then
          local ok, b = pcall(rx.open, msg, function(id) return fleet[id] end, SEC.DIR.DRONE_TO_BASE, 120000)
          if ok and b then body = b else model.rejected = model.rejected + 1 end
        else
          model.rejected = model.rejected + 1
        end
      elseif insecure then
        body = msg
      else
        model.rejected = model.rejected + 1
      end
      if body then
        if body.type == "plan" and type(body.id) == "string" then
          D.ingestPlan(model, body, now)
        elseif link.check(body) then
          D.ingest(model, body, now)
        end
      end
    end
  end
end

local FRAME = tonumber(setting("dronenet.frame")) or 0.25
if FRAME < 0.05 then FRAME = 0.05 end

local function draw()
  while true do
    local st
    if sim then
      sim.tick(FRAME)
      st = sim.state()
    else
      local now = os.clock() - t0
      local ops, feedState
      if watching then
        local fresh = model.opsAt and now - model.opsAt <= WATCH.STALE
        ops, feedState = fresh and model.ops or nil, fresh and "OK" or "LOST"
      end
      -- the base's places, from the feed, when this computer has no pads.lua
      local where = (#pads == 0 and model.ops and model.ops.places) or pads
      st = S.build(model, now, { D = D, track = track, pads = where, spawn = spawn, ops = ops, feed = feedState,
                                 clock = S.clock(os.time()), day = os.day() })
    end
    for _, s in ipairs(screens) do
      SC.render(s.role, s.canvas, st)
      s.canvas:flush(s.mon)
    end
    sleep(FRAME)
  end
end

local function watchMonitors()
  while true do
    local ev, side = os.pullEvent("monitor_resize")
    for _, s in ipairs(screens) do
      if s.name == side then
        s.canvas = D.canvas(s.mon.getSize())
        s.mon.clear()
      end
    end
  end
end

parallel.waitForAny(receive, draw, watchMonitors)
