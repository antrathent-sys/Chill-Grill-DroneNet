-- beacon: the drone's idle telemetry, so the base's screens see it whenever its
-- computer is on. fly only transmits while it flies.
--
--   beacon                   send a sealed status packet every 2 s
--   startup autorun beacon   run it from every boot
--
-- While it runs: F asks for a fly command and runs it - the beacon goes quiet
-- for the flight and carries on afterwards - and Q stops it.
--
-- It also takes orders from the base over the radio: an ops.fly command from
-- the admin panel, a taxi job from a customer by way of ops, or - docked at the
-- loading station - stick the silos the station has lifted up to it. An order is
-- SEALED with this drone's own key (lib/seclink.lua, direction BASE_TO_DRONE)
-- on the same channel the telemetry goes out on. That seal is the whole
-- security model now that the fleet flies without cables: only the base, which
-- holds the key in .fleetkeys, can make an order; the counter rises so a
-- copied packet is refused as a replay; anything this drone cannot open with
-- its own key is dropped without being read. Orders are also acted on once, by
-- their nonce, and this drone answers sealed so the base knows it was really
-- us.
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
-- Docked and LANDED are different things (Alex, 2026-09-25): docked is
-- latched on a dock - charging, and a loading station can reach it; landed is
-- sitting on the ground somewhere, on nothing. Both read exactly zero
-- velocity, so being still is not enough. Docked is: the connector names its
-- pad, or the accumulators are charging, or - still, with the connector held
-- out (fly leaves DOCK_SIDE high after docking and never raises it to land)
-- - within a few blocks of a known dock. Still and none of that: landed.

local link = dofile("lib/link.lua")
local SEC = dofile("lib/seclink.lua")
local F = dofile("lib/fleet.lua")
local PERIOD = 2         -- seconds between packets
-- How high the altimeter reads above the block a resting craft stands on:
-- fly.lua's DOCK_GAP, measured (70.5 over a pad at 63). A pickup that comes to
-- rest much higher than the customer's own ground has landed ON something - a
-- roof, a tree - and is no place to board, so the job is called off.
local REST_GAP = 7.5
local OBSTRUCTED = 4     -- blocks above the expected rest that count as on top of something
local DISTRESS_EVERY = 15   -- packets between repeats of the distress call (30 s)
-- An obstructed pickup climbs this far above where it came to rest and holds
-- there while the customer finds somewhere clear. No new spot in
-- RELOCATE_WAIT seconds, or a third obstructed landing, drops the job - and
-- the base charges the fare.
local SAFE_CLIMB = 12
local RELOCATE_WAIT = 120
local MAX_TRIES = 3
local HOLD = "hold-for-a-new-spot"   -- not a fly command: the main loop's marker
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

-- home: a pad called home in pads.lua, else HOME_X/Y/Z in fly.lua. And every
-- dock this drone knows, and the face its connector is held by - for telling
-- docked from landed.
local home
local docks = {}          -- { x, z } of every dock, home included
local latchSide           -- fly's DOCK_SIDE, when it is a face of this computer
do
  local okP, P = pcall(dofile, "lib/pads.lua")
  if okP and type(P) == "table" then
    local list = P.load("pads.lua", fs) or {}
    local h = P.get(list, "home")
    if h then home = { x = h.x + 0.5, z = h.z + 0.5 } end
    for _, p in ipairs(list) do
      if p.kind ~= "pad" then docks[#docks + 1] = { x = p.x + 0.5, z = p.z + 0.5 } end
    end
  end
  local function read(path)
    if not fs.exists(path) then return "" end
    local f = fs.open(path, "r")
    local src = f and f.readAll() or ""
    if f then f.close() end
    return src
  end
  local src = read("fly.lua")
  if not home then
    local hx, hz = src:match("HOME_X = (%-?%d+), HOME_Y = %-?%d+, HOME_Z = (%-?%d+),")
    if hx then home = { x = tonumber(hx) + 0.5, z = tonumber(hz) + 0.5 } end
  end
  if home then docks[#docks + 1] = home end
  -- tune.lua may move it; a relay or a slave (a table) cannot be read from here
  latchSide = read("tune.lua"):match('DOCK_SIDE%s*=%s*"(%a+)"') or src:match('DOCK_SIDE%s*=%s*"(%a+)"')
end
local DOCK_NEAR = 4       -- blocks from a dock that count as on it

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
  local still = run.frozen >= 2
  local held = false
  if latchSide and redstone and redstone.getOutput then
    local okR, on = pcall(redstone.getOutput, latchSide)
    held = okR and on == true
  end
  local onDock = false
  if x then
    for _, d in ipairs(docks) do
      if (d.x - x) ^ 2 + (d.z - z) ^ 2 <= DOCK_NEAR * DOCK_NEAR then onDock = true break end
    end
  end
  local docked = (type(name) == "string" and name ~= "") or charging or (still and held and onDock)
  local landed = still and not docked
  run.landed = landed
  -- in distress the phase says so on every packet, so the base's board shows
  -- it and a base that restarts still finds out
  local phase = run.sos and "sos" or (docked and "docked" or (landed and "landed" or "idle"))
  local s = { t = os.clock(), phase = phase, h = h or py, e = 0,
              x = x, z = z, vx = vx, vz = vz, vv = vy }
  return s, { energy = energy }, { pct = fe }, { connected = docked }
end

local function pct(v) return type(v) == "number" and string.format("%d%%", math.floor(v + 0.5)) or "--" end

-- ---------------------------------------------------------------- orders ----
-- The same modem and channel the telemetry leaves on; sealed both ways.
pcall(peripheral.call, radio, "open", link.CHANNEL)
local orderRx = SEC.receiver()
local orderSealer          -- made on first use, shares .dronekey.ctr with the
                           -- telemetry sealer so the counter only ever rises

local job          -- { id, pad, tx, tz, ty, step } while carrying someone
local pending      -- the fly command line the main loop should run next
local seenNonce = {}
local orderSeq = 0

local function myNonce()
  orderSeq = orderSeq + 1
  return F.nonce(id, tostring(os.epoch and os.epoch("utc") or os.clock()) .. "." .. orderSeq)
end

-- ONE sealer at a time for everything this drone sends. Two live sealers over
-- the same key both reserve counters out of .dronekey.ctr and then interleave,
-- and the base refuses any counter that does not rise - which silently ate half
-- the job states the first time orders and telemetry had a sealer each.
--
-- ...and a FRESH one after every flight: fly seals its own telemetry with the
-- same key and file and leaves the counter far ahead, so the sealer beacon was
-- using before the flight is now behind and everything it sends is refused as
-- a replay. That is what swallowed "your taxi has landed" on the first real
-- ride: the drone arrived, said so, and the base threw the packet away
-- (2026-09-20).
local function sealer()
  if not orderSealer then orderSealer = SEC.sender(key, id, SEC.DIR.DRONE_TO_BASE, ".dronekey.ctr") end
  return orderSealer
end
local function sealerAfterFlight() orderSealer = nil end

-- Answer the base, sealed as this drone. The reply rides the same channel.
local function say(msg)
  local ok, env = pcall(sealer().seal, msg)
  if ok and env then pcall(peripheral.call, radio, "transmit", link.CHANNEL, link.CHANNEL, env) end
end
-- A delivery leaves .drops behind: one line per silo it let go of, written
-- by fly at the drop ("sticker x y z 1|0"). Each goes to the base, sealed,
-- for its cargo ledger, and a copy stays here in .drops.log.
local function reportDrops()
  if not fs.exists(".drops") then return end
  local h = fs.open(".drops", "r")
  local text = h and h.readAll() or ""
  if h then h.close() end
  for line in text:gmatch("[^\n]+") do
    local n, x, y, z, ok = line:match("^(%S+) (%-?%d+) (%-?%d+) (%-?%d+) ([01])$")
    if n then
      say(F.dropped(id, n, ok == "1", tonumber(x), tonumber(y), tonumber(z), myNonce()))
      print(string.format("reported %s %s at %s %s %s", n, ok == "1" and "dropped" or "STILL HELD", x, y, z))
    end
  end
  local keep = fs.open(".drops.log", "a")
  if keep then keep.write(text) keep.close() end
  fs.delete(".drops")
end

local function announce(state, detail)
  if job then say(F.state(job.id, id, state, detail, myNonce())) end
end

-- Where the craft is now, as a person going to fetch it would want it.
local function position()
  local x, y, z = pose()
  local h = call(alt, "getHeight")
  return x, h or y, z
end
local function here()
  local x, y, z = position()
  if not x then return "position unknown" end
  return string.format("%d %d %d", math.floor(x), math.floor(y), math.floor(z))
end

-- A flight that was ordered has failed: a crash, a tumble, a launch that
-- never got off the pad. Say so now, with where it is, and keep saying it
-- (sendLoop repeats it, and every telemetry packet reads "sos") until the
-- base sends it somewhere again. It does NOT try to fly home on its own:
-- after a crash, the operator decides.
local function distress(why)
  run.sos = why
  local x, y, z = position()
  say(F.distress(id, why, x, y, z, myNonce()))
  print("DISTRESS: " .. why .. " at " .. here())
end

-- The loading station has lifted silos up against these stickers: extend them
-- (retract, for on = false). Only latched on a dock or at rest - in the air
-- there is nothing to hold - and never while carrying someone. The answer
-- says what each sticker reports; "touching" is Create's own check and may
-- not see a block on another physics object, so it is information, not the
-- verdict. The verdict is whether every sticker ended where it was asked.
local function stickFor(msg)
  if job then return false, "carrying someone" end
  local name = call(dockP, "getConnectedName")
  if not ((type(name) == "string" and name ~= "") or run.frozen >= 2) then return false, "not docked" end
  local names = F.stickers(msg)
  if #names == 0 then return false, "no stickers named" end
  for _, n in ipairs(names) do
    local isOne = false
    for _, t in ipairs({ peripheral.getType(n) }) do if t == "Create_Sticker" then isOne = true end end
    if not isOne then return false, n .. " is not a sticker on this drone" end
  end
  local want = msg.on ~= false
  for _, n in ipairs(names) do pcall(peripheral.call, n, want and "extend" or "retract") end
  sleep(0.25)
  local parts, ok = {}, true
  for _, n in ipairs(names) do
    local okE, ext = pcall(peripheral.call, n, "isExtended")
    local okA, att = pcall(peripheral.call, n, "isAttachedToBlock")
    if not (okE and ext == want) then ok = false end
    parts[#parts + 1] = n .. ((okE and ext) and " out" or " in") .. ((okA and att) and " touching" or "")
  end
  return ok, (not ok) and "a sticker did not move" or nil, table.concat(parts, ", ")
end

-- Waits for something to fly and returns; the main loop runs it and then calls
-- jobStep to work out what happens next.
-- Open one packet from the telemetry channel as an order for this drone, or
-- return nil and say why not. Shared by netLoop and the hold above an
-- obstructed landing, so both believe exactly the same things.
local function openOrder(ch, env)
    local msg
    if ch == link.CHANNEL then run.heard = (run.heard or 0) + 1 end
    if ch == link.CHANNEL and type(env) == "table" and env.sl and env.d == SEC.DIR.BASE_TO_DRONE then
      -- our key, our direction, and a counter that has not been used before
      local okO, body = pcall(orderRx.open, env, function(who) return who == id and key or nil end,
                              SEC.DIR.BASE_TO_DRONE, 120000)
      if okO and body then
        msg = body
      else
        -- silence here looks exactly like the base never sending anything, so
        -- say what came and why it was turned away
        print(string.format("order for %s refused: %s", tostring(env.id), tostring(body)))
      end
    end
    -- ...and if it opened but the order is not one we will act on, say that
    -- too: a sealed order that is silently dropped is the hardest fault there
    -- is to find from either end (2026-09-20, the first taxi that never came).
    if msg then
      local okC, whyC = F.check(msg)
      if not okC then
        print(string.format("order %s ignored: %s", tostring(msg.type), tostring(whyC)))
        msg = nil
      elseif msg.to ~= nil and msg.to ~= id then
        print(string.format("order was for %s, not me", tostring(msg.to)))
        msg = nil
      elseif not F.fresh(seenNonce, msg.nonce, os.clock()) then
        print("order repeated - already done")
        msg = nil
      end
    end
    return msg
end

local function netLoop()
  while true do
    local _, _, ch, _, env = os.pullEvent("modem_message")
    local msg = openOrder(ch, env)
    if msg then
      if msg.type == "ops.fly" then
        if job then
          say(F.ack(job.id, id, false, "carrying someone", myNonce()))
        else
          pending = F.flyArgs(msg.args)
          if run.sos then print("distress cleared by the base's order") end
          run.sos = nil
          say(F.ack("ops", id, true, nil, myNonce()))
          print("")
          print("ops says: fly " .. tostring(pending))
          return
        end
      elseif msg.type == "job.assign" then
        if job then
          say(F.ack(msg.job, id, false, "already on " .. job.id, myNonce()))
        elseif run.sos then
          say(F.ack(msg.job, id, false, "unit down: " .. run.sos, myNonce()))
        elseif msg.board then
          -- already on station where the customer is: they walk to it
          job = { id = msg.job, pad = msg.pad, tx = msg.tx, tz = msg.tz, ty = msg.ty,
                  px = msg.px, py = msg.py, pz = msg.pz, step = "waiting", board = true }
          say(F.ack(msg.job, id, true, nil, myNonce()))
          print("")
          print("taxi job " .. job.id .. ": boarding here")
          announce("waiting", "on station - board here")
        else
          job = { id = msg.job, pad = msg.pad, tx = msg.tx, tz = msg.tz, ty = msg.ty,
                  px = msg.px, py = msg.py, pz = msg.pz, step = "pickup" }
          say(F.ack(msg.job, id, true, nil, myNonce()))
          pending = F.legCommand("pickup", msg)
          print("")
          print("taxi job " .. job.id .. ": collecting from " .. tostring(job.pad))
          announce("enroute", "on the way to " .. tostring(job.pad))
          return
        end
      elseif msg.type == "unit.stick" then
        local okS, whyS, detail = stickFor(msg)
        print("")
        print(string.format("stickers %s: %s", msg.on ~= false and "out" or "in", okS and "done" or tostring(whyS)))
        if detail then print("  " .. detail) end
        say(F.stuck(msg.job, id, okS, whyS, detail, myNonce()))
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
      -- landed somewhere, but where? A pickup at open ground that came to rest
      -- well above the customer's own ground is on top of something
      local h = call(alt, "getHeight")
      local expect = job.py and (job.py - 1 + REST_GAP)
      if not job.pad and expect and h and h - expect > OBSTRUCTED then
        job.tries = (job.tries or 0) + 1
        local above = math.floor(h - expect + 0.5)
        if job.tries >= MAX_TRIES then
          announce("failed", "landing zone obstructed again - job dropped, fare charged")
          print("pickup obstructed " .. job.tries .. " times - job dropped")
          job.step = "home"
          pending = F.legCommand("home", job)
          return
        end
        -- climb clear and hold, while the customer finds somewhere clear
        job.holdY = math.floor(h + SAFE_CLIMB)
        job.step = "relocate"
        announce("relocate", string.format("landing zone obstructed - %d above you, holding", above))
        print("pickup obstructed - holding at Y " .. job.holdY .. " for a new spot")
        pending = HOLD
        return
      end
      job.step = "waiting"
      announce("waiting", "docked at " .. tostring(job.pad))
      print("waiting at " .. tostring(job.pad) .. " for the passenger to press G")
    else
      distress("pickup flight failed")
      announce("failed", "unit down at " .. here())
      job = nil
    end
  elseif job.step == "ride" then
    if flew then
      announce("done", "landed")
      job.step = "home"
      pending = F.legCommand("home", job)
    else
      distress("transit flight failed")
      announce("failed", "unit down at " .. here())
      job = nil
    end
  elseif job.step == "home" then
    if not flew then distress("return flight failed") end
    job = nil
  end
end

local function sendLoop()
  -- the one sealer, shared with the order replies; it reserves counters above
  -- whatever fly used
  local function send(pkt)
    local ok, env = pcall(sealer().seal, pkt)
    if ok and env then pcall(peripheral.call, radio, "transmit", link.CHANNEL, link.CHANNEL, env) end
  end
  while true do
    local s, mon, fuel, dock = status()
    run.seq = run.seq + 1
    send(link.packet(id, run.seq, s, mon, fuel, dock, 0, 0, nil, "idle"))
    if run.seq == 1 or run.seq % PLAN_EVERY == 0 then
      send(link.planPacket(id, run.seq, nil, 0, home, "idle", s))
    end
    if run.sos and run.seq % DISTRESS_EVERY == 0 then
      send(F.distress(id, run.sos, s.x, s.h, s.z, myNonce()))
    end
    local w = term.getSize()
    local _, y = term.getCursorPos()
    term.setCursorPos(1, y)
    term.clearLine()
    -- "hrd" is how many packets have arrived on the order channel: 0 while the
    -- base is poking means nothing is reaching this drone at all, which is a
    -- different problem from an order it cannot open
    term.write(string.format("#%d %s  batt %s  FE %s  hrd %d", run.seq, s.phase:upper(),
      pct(mon.energy), pct(fuel.pct), run.heard or 0):sub(1, w))
    sleep(PERIOD)
  end
end

-- Hold above an obstructed landing until the customer sends a new spot, or
-- RELOCATE_WAIT runs out. fly holds the height; this listens beside it. The
-- hold is ended with fly's own word - "l", land here - never by stopping fly,
-- which would leave the thrusters at their last command. Then the next leg
-- goes to the new spot, or home if the time ran out.
local function holdForSpot()
  local target, timedOut
  local deadline = os.clock() + RELOCATE_WAIT
  local flew = true
  local function hover() flew = shell.run("fly " .. tostring(job.holdY)) end
  local function listen()
    local asked = false
    while true do
      local timer = os.startTimer(1)
      local ev = { os.pullEvent() }
      if ev[1] ~= "timer" then pcall(os.cancelTimer, timer) end
      if not asked then
        if ev[1] == "modem_message" then
          local msg = openOrder(ev[3], ev[5])
          if msg and msg.type == "job.relocate" and msg.job == job.id then
            target, asked = msg, true
            print("new spot " .. tostring(msg.px) .. " " .. tostring(msg.pz) .. " - setting down first")
            os.queueEvent("char", "l")
          end
        elseif os.clock() > deadline then
          timedOut, asked = true, true
          print("no new spot in " .. RELOCATE_WAIT .. " s - setting down")
          os.queueEvent("char", "l")
        end
      end
    end
  end
  parallel.waitForAny(hover, listen)
  sealerAfterFlight()          -- fly moved the counter on
  if not flew or not (target or timedOut) then
    distress("hold above an obstructed landing failed")
    announce("failed", "unit down at " .. here())
    job = nil
    return
  end
  if target then
    job.px, job.py, job.pz, job.pad = target.px, target.py, target.pz, target.pad
    job.step = "pickup"
    announce("enroute", "to the new spot")
    pending = F.legCommand("pickup", job)
  else
    announce("failed", "no new spot in 2 min - job dropped, fare charged")
    job.step = "home"
    pending = F.legCommand("home", job)
  end
end

print(string.format("beacon: %s on %s channel %d, sealed%s", id, radio, link.CHANNEL,
  home and "" or " - home unknown (fly pad add home, or HOME_X/Z in fly.lua)"))
print(string.format("F = fly, Q = stop  -  taking sealed orders on %s ch %d", radio, link.CHANNEL))
reportDrops()                 -- from a delivery flown from the shell, before this started
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
    local forJob = (job ~= nil)
    pending = nil
    if line == HOLD and job then
      holdForSpot()           -- queues the next leg itself
    else
      local flew = shell.run("fly " .. line)
      sealerAfterFlight()     -- fly moved the counter on; start above it
      reportDrops()           -- a delivery says what it let go of, and where
      if ordered then jobStep(flew and true or false) end
      if ordered and not forJob and not flew then distress("ordered flight failed: fly " .. line) end
    end
    line = pending
  end
  print("beacon resumes - F = fly, Q = stop")
end
