-- beacon: the drone's idle telemetry, so the base's screens see it whenever its
-- computer is on. fly only transmits while it flies.
--
--   beacon                   send a sealed status packet every 2 s
--   startup autorun beacon   run it from every boot
--
-- While it runs: F asks for a fly command and runs it - the beacon goes quiet
-- for the flight and carries on afterwards - and Q stops it. It never flies by
-- itself: a person types every flight.
--
-- The packets are the ones fly sends (lib/link.lua, sealed with lib/seclink.lua
-- and this drone's .dronekey and counter), with phase "docked" or "idle" and no
-- target, plus a route packet naming home so the base can put M1 on the map.
-- Only one of beacon and fly sends at a time: the base refuses a counter that
-- does not rise, and two senders sharing a key would interleave.
--
-- Docked is judged without flying: the connector names its pad, or the
-- accumulators are charging, or the pose has been frozen for two readings (a
-- latched craft reads exactly zero velocity).

local link = dofile("lib/link.lua")
local SEC = dofile("lib/seclink.lua")
local PERIOD = 2         -- seconds between packets
local PLAN_EVERY = 10    -- a route packet on the first and every this many
local CHARGE_FE = 200    -- FE gained between packets that counts as charging

local id = (os.getComputerLabel and os.getComputerLabel()) or ("drone-" .. tostring(os.getComputerID()))
local key = SEC.readKeyFile(".dronekey")
if not key then
  print("beacon: no key - on this drone run seckey set disk (or seckey set <hex>)")
  return
end
local radio = link.findRadio(peripheral)
if not radio then
  print("beacon: no wireless or ender modem - nothing to send with")
  return
end

local alt = peripheral.find("altitude_sensor")
local accs = { peripheral.find("modular_accumulator") }
local thrs = { peripheral.find("vector_thruster") }
local dockP = peripheral.find("docking_connector")

-- home: a pad called home in pads.lua, else HOME_X/Y/Z in fly.lua
local home
do
  local okP, P = pcall(dofile, "lib/pads.lua")
  if okP and type(P) == "table" then
    local h = P.get((P.load("pads.lua", fs)), "home")
    if h then home = { x = h.x + 0.5, z = h.z + 0.5 } end
  end
  if not home and fs.exists("fly.lua") then
    local f = fs.open("fly.lua", "r")
    local src = f.readAll() or ""
    f.close()
    local hx, hz = src:match("HOME_X = (%-?%d+), HOME_Y = %-?%d+, HOME_Z = (%-?%d+),")
    if hx then home = { x = tonumber(hx) + 0.5, z = tonumber(hz) + 0.5 } end
  end
end

local function call(p, method)
  if not (p and p[method]) then return nil end
  local ok, v = pcall(p[method])
  if ok then return v end
  return nil
end

-- percent full over a list of peripherals, and the raw amount
local function level(list, getAmount, getCapacity)
  local amount, capacity = 0, 0
  for _, p in ipairs(list) do
    local a, c = call(p, getAmount), call(p, getCapacity)
    if type(a) == "number" and type(c) == "number" then amount, capacity = amount + a, capacity + c end
  end
  if capacity <= 0 then return nil, amount end
  return 100 * amount / capacity, amount
end

local function pose()
  if type(sublevel) ~= "table" then return nil end
  local okP, p = pcall(sublevel.getLogicalPose)
  if not (okP and type(p) == "table" and type(p.position) == "table") then return nil end
  local okV, v = pcall(sublevel.getLinearVelocity)
  v = (okV and type(v) == "table") and v or {}
  return p.position.x, p.position.y, p.position.z, v.x or 0, v.y or 0, v.z or 0
end

local run = { seq = 0, lastFE = nil, frozen = 0 }

-- one reading of everything, shaped as fly's shared tables
local function status()
  local x, py, z, vx, vy, vz = pose()
  local h = call(alt, "getHeight")
  local energy, stored = level(accs, "getEnergy", "getCapacity")
  local fe = level(thrs, "getEnergy", "getEnergyCapacity")
  local name = call(dockP, "getConnectedName")
  local charging = run.lastFE ~= nil and stored > run.lastFE + CHARGE_FE
  run.lastFE = stored
  if x and vx == 0 and vy == 0 and vz == 0 then run.frozen = run.frozen + 1 else run.frozen = 0 end
  local docked = (type(name) == "string" and name ~= "") or charging or run.frozen >= 2
  local s = { t = os.clock(), phase = docked and "docked" or "idle", h = h or py, e = 0,
              x = x, z = z, vx = vx, vz = vz, vv = vy }
  return s, { energy = energy }, { pct = fe }, { connected = docked }
end

local function pct(v) return type(v) == "number" and string.format("%d%%", math.floor(v + 0.5)) or "--" end

local function sendLoop()
  -- a fresh sealer each time: it reserves counters above whatever fly used
  local sealer = SEC.sender(key, id, SEC.DIR.DRONE_TO_BASE, ".dronekey.ctr")
  local function send(pkt)
    local ok, env = pcall(sealer.seal, pkt)
    if ok and env then pcall(peripheral.call, radio, "transmit", link.CHANNEL, link.CHANNEL, env) end
  end
  while true do
    local s, mon, fuel, dock = status()
    run.seq = run.seq + 1
    send(link.packet(id, run.seq, s, mon, fuel, dock, 0, 0, nil, "idle"))
    if run.seq == 1 or run.seq % PLAN_EVERY == 0 then
      send(link.planPacket(id, run.seq, nil, 0, home, "idle", s))
    end
    local w = term.getSize()
    local _, y = term.getCursorPos()
    term.setCursorPos(1, y)
    term.clearLine()
    term.write(string.format("#%d %s  batt %s  FE %s", run.seq, s.phase:upper(), pct(mon.energy), pct(fuel.pct)):sub(1, w))
    sleep(PERIOD)
  end
end

print(string.format("beacon: %s on %s channel %d, sealed%s", id, radio, link.CHANNEL,
  home and "" or " - home unknown (fly pad add home, or HOME_X/Z in fly.lua)"))
print("F = fly, Q = stop")
while true do
  local choice
  parallel.waitForAny(sendLoop, function()
    while true do
      local _, ch = os.pullEvent("char")
      ch = tostring(ch):lower()
      if ch == "f" or ch == "q" then
        choice = ch
        return
      end
    end
  end)
  print("")
  if choice == "q" then
    print("beacon stopped")
    return
  end
  write("fly ")
  local line = read()
  if line and line:match("%S") then
    shell.run("fly " .. line)
  else
    print("nothing flown")
  end
  print("beacon resumes - F = fly, Q = stop")
end
