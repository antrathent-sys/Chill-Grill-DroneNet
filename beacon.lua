-- beacon: the drone's idle telemetry, so the base's screens see it whenever its
-- computer is on. fly only transmits while it flies.
--
--   beacon                   send a sealed status packet every 2 s
--   startup autorun beacon   run it from every boot
--
-- While it runs: F asks for a fly command and runs it - the beacon goes quiet
-- for the flight and carries on afterwards - and Q stops it.
--
-- It also listens on the WIRED network (rednet, protocol dronenet, lib/fleet.lua)
-- for the base: an ops.fly command from the admin panel, or a taxi job from a
-- pad by way of ops. Wired only, and the wired-only part is the whole security
-- model, the same one fly's own command loop uses (fly.lua:3540-3575): a radio
-- packet can be copied by anyone in earshot, and this runs flights. Orders are
-- addressed - a message for another drone on the same cable is ignored - and
-- each one is acted on once, by its nonce.
--
-- So: it never flies on its own judgement, but a person at the base or at a pad
-- can now start a flight without standing at this keyboard. fly itself still
-- cannot autorun (startup.lua:45-47); beacon is already running and calls it.
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
local F = dofile("lib/fleet.lua")
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

-- ---------------------------------------------------------------- orders ----
-- Only wired modems are opened, so a wireless order cannot even arrive.
local wired = F.wired(peripheral)
for _, nm in ipairs(wired) do pcall(rednet.open, nm) end

local job          -- { id, pad, tx, tz, ty, step } while carrying someone
local pending      -- the fly command line the main loop should run next
local seenNonce = {}
local orderSeq = 0

local function myNonce()
  orderSeq = orderSeq + 1
  return F.nonce(id, tostring(os.epoch and os.epoch("utc") or os.clock()) .. "." .. orderSeq)
end

local function say(msg) pcall(rednet.broadcast, msg, F.PROTO) end
local function announce(state, detail)
  if job then say(F.state(job.id, id, state, detail, myNonce())) end
end

-- Waits for something to fly and returns; the main loop runs it and then calls
-- jobStep to work out what happens next.
local function netLoop()
  while true do
    local _, msg = rednet.receive(F.PROTO)
    local ok = type(msg) == "table" and (F.check(msg))
    if ok and (msg.to == nil or msg.to == id) and F.fresh(seenNonce, msg.nonce, os.clock()) then
      if msg.type == "ops.fly" then
        if job then
          say(F.ack(job.id, id, false, "carrying someone", myNonce()))
        else
          pending = F.flyArgs(msg.args)
          say(F.ack("ops", id, true, nil, myNonce()))
          print("")
          print("ops says: fly " .. tostring(pending))
          return
        end
      elseif msg.type == "job.assign" then
        if job then
          say(F.ack(msg.job, id, false, "already on " .. job.id, myNonce()))
        else
          job = { id = msg.job, pad = msg.pad, tx = msg.tx, tz = msg.tz, ty = msg.ty, step = "pickup" }
          say(F.ack(msg.job, id, true, nil, myNonce()))
          pending = F.legCommand("pickup", msg)
          print("")
          print("taxi job " .. job.id .. ": collecting from " .. tostring(job.pad))
          announce("enroute", "on the way to " .. tostring(job.pad))
          return
        end
      elseif msg.type == "job.go" and job and job.step == "waiting" and msg.job == job.id then
        job.step = "ride"
        pending = F.legCommand("ride", job)
        print("passenger aboard - flying to " .. tostring(job.tx) .. ", " .. tostring(job.tz))
        announce("riding")
        return
      end
    end
  end
end

-- What to do after a flight the orders started has finished. flew is what
-- shell.run said: false means fly stopped early (a tumble, a refusal, a
-- keyboard stop), and then the job ends where it stands rather than carrying
-- on to the next leg with a passenger who may not be aboard.
local function jobStep(flew)
  if not job then return end
  if job.step == "pickup" then
    if flew then
      job.step = "waiting"
      announce("waiting", "docked at " .. tostring(job.pad))
      print("waiting at " .. tostring(job.pad) .. " for the passenger to press G")
    else
      announce("failed", "could not reach " .. tostring(job.pad))
      job = nil
    end
  elseif job.step == "ride" then
    if flew then announce("done", "landed") else announce("failed", "the ride stopped early") end
    job.step = "home"
    pending = F.legCommand("home", job)
  elseif job.step == "home" then
    job = nil
  end
end

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
print(string.format("F = fly, Q = stop%s", #wired > 0
  and ("  -  taking orders on " .. table.concat(wired, ", ")) or "  -  no wired modem, no orders"))
while true do
  local choice
  pending = nil
  parallel.waitForAny(sendLoop, function()
    while true do
      local _, ch = os.pullEvent("char")
      ch = tostring(ch):lower()
      if ch == "f" or ch == "q" then
        choice = ch
        return
      end
    end
  end, netLoop)
  print("")
  if choice == "q" then
    if job then announce("failed", "the drone was stopped at its keyboard") end
    print("beacon stopped")
    return
  end
  local line = pending
  if not line then
    write("fly ")
    line = read()
  end
  if not (line and line:match("%S")) then print("nothing flown") end
  -- a job is more than one flight: the pickup, then the ride, then the way
  -- home. jobStep queues the next one, so keep going while it does.
  while line and line:match("%S") do
    local ordered = (pending ~= nil)
    pending = nil
    local flew = shell.run("fly " .. line)
    if ordered then jobStep(flew and true or false) end
    line = pending
  end
  print("beacon resumes - F = fly, Q = stop")
end
