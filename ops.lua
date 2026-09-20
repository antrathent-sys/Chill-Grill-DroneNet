-- ops: the admin panel. It watches the whole fleet and gives orders.
--
--   ops                  the live board, and it dispatches taxi pads
--   ops list             one snapshot of the fleet, then quit
--   ops fly <who> <...>  fly a command on a drone: ops fly any ferry pier
--   ops send <who> <pad> shorthand for: ops fly <who> ferry <pad>
--   ops land|hold|undock <who>     the in-flight words fly already takes
--   ops stats            what the taxi pads have reported
--   ops closed           run the board but turn radio hails away
--
-- <who> is a drone id, or "any" for the nearest one that is docked, has called
-- in within the last 15 s and is not already on a job.
--
-- Two networks, on purpose:
--   * the ENDER modem, listening only. Sealed telemetry from every drone in
--     .fleetkeys (lib/seclink.lua). This is where the board comes from, and
--     nothing is ever sent back this way.
--   * the WIRED modems, rednet, protocol dronenet. Every order goes out here
--     and only here, because anyone in earshot can copy a radio packet, and a
--     drone that strangers can re-route is not a fleet (MISSIONCONTROL.md:52-59).
--     In practice that means orders reach a drone while it is docked and its
--     connector bridges the pad cable. A drone in the air is read-only, except
--     for the three words fly's own command loop takes (land, hold, undock),
--     which ops sends on fly's protocol.
--
-- Hails by radio: a customer with a pocket computer (hail.lua) is nowhere near
-- a cable, so ops also listens on the WIRELESS modem - but only for a request,
-- never for an order. A hail is a question ops may refuse; the flight command
-- it decides on still leaves over the wire. So the rule that matters holds: no
-- drone ever takes a flight command from the air. Hails are rate-limited per
-- caller, printed as they arrive, and `ops closed` turns them away entirely.
--
-- ops holds no drone keys and cannot forge telemetry: .fleetkeys only ever
-- opens packets, and the sealed direction here is drone-to-base.

local F = dofile("lib/fleet.lua")
local SEC = dofile("lib/seclink.lua")
local link = dofile("lib/link.lua")

local args = { ... }
local cmd = (args[1] or "watch"):lower()

local fleetKeys, nKeys = SEC.readFleetKeys(".fleetkeys")
local me = (os.getComputerLabel and os.getComputerLabel()) or ("ops-" .. tostring(os.getComputerID()))

-- ---------------------------------------------------------------- the wire --
local wired = F.wired(peripheral)
for _, nm in ipairs(wired) do pcall(rednet.open, nm) end
-- and the radio, for hails only (see the note above)
local HAIL_EVERY = 20        -- seconds a caller must wait between hails
local openToHails = (cmd ~= "closed")
local lastHail = {}
if openToHails then
  for _, nm in ipairs(peripheral.getNames()) do
    if peripheral.getType(nm) == "modem" then
      local okW, wireless = pcall(peripheral.call, nm, "isWireless")
      if okW and wireless then pcall(rednet.open, nm) end
    end
  end
end
if cmd == "closed" then cmd = "watch" end
if #wired == 0 then
  print("ops: no WIRED modem - the board will fill in but no order can leave.")
  print("     Put a modem on this computer and cable it to the pads.")
end

local seq = 0
local function nonce()
  seq = seq + 1
  return F.nonce(me, tostring(os.epoch and os.epoch("utc") or os.time()) .. "." .. seq)
end

local function shout(msg) rednet.broadcast(msg, F.PROTO) end

-- ------------------------------------------------------------- the fleet ----
-- Built from telemetry alone: a drone exists the moment a packet of its opens.
local fleet, pads, jobs, padStats = {}, {}, {}, {}
-- nonces live in their OWN table. They were sharing `jobs`, whose values are
-- job records, and fleet.fresh does arithmetic on every value it finds while
-- ageing them out: the first hail after a job existed crashed ops with
-- "attempt to perform arithmetic on a table value" (2026-09-20).
local seenNonce = {}

-- The board clears the screen every two seconds, so anything printed from the
-- serve loop vanished before it could be read - including the error that took
-- the loop down. Events go in here instead and the board draws them.
local events = {}
local function log(fmt, ...)
  local line = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
  events[#events + 1] = string.format("%s  %s", textutils.formatTime(os.time(), true), line)
  while #events > 8 do table.remove(events, 1) end
  return line
end
local rejected = 0

do
  local okP, P = pcall(dofile, "lib/pads.lua")
  if okP and type(P) == "table" then pads = P.load("pads.lua", fs) or {} end
end
local function padByName(name)
  for _, p in ipairs(pads) do if p.name == tostring(name):lower() then return p end end
  return nil
end

local function note(d)
  local id = d.id
  fleet[id] = fleet[id] or {}
  local f = fleet[id]
  f.seen = os.clock()
  f.x, f.z, f.y = d.x, d.z, d.y
  f.phase, f.mode = d.phase, d.mode
  f.docked = (d.dock == 1) or d.phase == "docked"
  f.energy, f.spd = d.energy, d.spd
  if f.docked and f.job and jobs[f.job] and jobs[f.job].state == "done" then f.job = nil end
end

local function receive()
  local radio = link.findRadio(peripheral)
  if not radio then
    print("ops: no ender modem - no telemetry, orders still work")
    while true do os.pullEvent("terminate_never") end
  end
  peripheral.call(radio, "open", link.CHANNEL)
  local rx = SEC.receiver()
  while true do
    local _, _, ch, _, msg = os.pullEvent("modem_message")
    if ch == link.CHANNEL and type(msg) == "table" and msg.sl then
      local ok, body = pcall(rx.open, msg, function(id) return fleetKeys[id] end,
                             SEC.DIR.DRONE_TO_BASE, 120000)
      if ok and body and body.type == "tlm" and link.check(body) then note(body)
      else rejected = rejected + 1 end
    end
  end
end

-- ------------------------------------------------------------ dispatching ---
local function pickWho(who, near)
  who = (who or "any"):lower()
  if who ~= "any" then
    local ok, why = F.available(fleet[who], os.clock())
    if not ok then return who, "warning: " .. who .. " is " .. why end
    return who
  end
  local id, why = F.pick(fleet, near or { x = 0, z = 0 }, os.clock())
  if not id then return nil, why end
  return id
end

-- An order is addressed: the drone checks the name against its own label, so a
-- second drone on the same cable ignores it.
local function order(id, msg)
  msg.to = id
  shout(msg)
end

local function orderFly(who, line, near)
  local argsOk, why = F.flyArgs(line)
  if not argsOk then return false, "that command is no good: " .. why end
  local id, note2 = pickWho(who, near)
  if not id then return false, note2 end
  order(id, F.flyCommand(argsOk, nonce()))
  return id, note2
end

-- Who asked, so the answer and every state update go back to them. A pad on
-- the cable and a pocket in the air are answered the same way.
local function reply(to, msg)
  if to then pcall(rednet.send, to, msg, F.PROTO) end
  shout(msg)
end

local function dispatch(req, from)
  -- the pickup is a pad if it names one, otherwise wherever the caller is
  local pad = (req.pad and padByName(req.pad)) or { name = req.pad, x = req.px, y = req.py, z = req.pz }
  local id, why = F.pick(fleet, pad, os.clock())
  if not id then
    reply(from, F.ack("j-none", "ops", false, why, nonce()))
    return nil, why
  end
  local job = "j-" .. tostring(os.epoch and math.floor(os.epoch("utc") / 1000) or os.time()) .. "-" .. id
  jobs[job] = { id = job, drone = id, pad = pad.name, tx = req.tx, tz = req.tz, state = "assigned",
                at = os.clock(), who = req.who, client = from }
  fleet[id] = fleet[id] or {}
  fleet[id].job = job
  local assign = F.assign(job, req)
  order(id, assign)                  -- to the drone, addressed, over the wire
  if from then pcall(rednet.send, from, assign, F.PROTO) end   -- and to whoever asked
  return id, job
end

-- ------------------------------------------------------------------ board ---
local function line(id, f, now)
  local age = f.seen and (now - f.seen) or 999
  local state = age > 30 and "LOST" or (age > 5 and "STALE" or (f.docked and "DOCKED" or (f.phase or "FLYING"):upper()))
  local job = f.job and jobs[f.job]
  return string.format("%-10s %-7s %6s %5s %s",
    id, state,
    (type(f.energy) == "number") and (string.format("%d%%", math.floor(f.energy + 0.5))) or "--",
    (type(f.spd) == "number") and string.format("%3.0f", f.spd) or "--",
    job and (job.state .. " " .. job.id:sub(1, 14)) or "")
end

local function board()
  local now = os.clock()
  local ids = {}
  for id in pairs(fleet) do ids[#ids + 1] = id end
  table.sort(ids)
  print(string.format("%-10s %-7s %6s %5s %s", "DRONE", "STATE", "BATT", "SPD", "JOB"))
  if #ids == 0 then print("  (nothing has called in yet)") end
  for _, id in ipairs(ids) do print(line(id, fleet[id], now)) end
  return #ids
end

-- ------------------------------------------------------------ one-shot use --
if cmd == "list" then
  print(string.format("ops: %d key%s, %d pad%s", nKeys, nKeys == 1 and "" or "s", #pads, #pads == 1 and "" or "s"))
  print("listening 3 s for telemetry...")
  parallel.waitForAny(receive, function() sleep(3) end)
  board()
  if rejected > 0 then print(rejected .. " packet(s) refused - a drone whose key is not in .fleetkeys") end
  return
end

if cmd == "fly" or cmd == "send" or cmd == "land" or cmd == "hold" or cmd == "undock" then
  local who, line2
  if cmd == "fly" then
    who = args[2]
    line2 = table.concat({ table.unpack and table.unpack(args, 3) or unpack(args, 3) }, " ")
  elseif cmd == "send" then
    who, line2 = args[2], "ferry " .. tostring(args[3] or "")
    if not args[3] then print("ops send <drone|any> <pad>") return end
  end
  if not who then print("ops " .. cmd .. " <drone|any> ...") return end
  print("listening 3 s so the board is current...")
  parallel.waitForAny(receive, function() sleep(3) end)

  if cmd == "land" or cmd == "hold" or cmd == "undock" then
    -- fly's own in-flight words, on fly's protocol, wired only
    local id = (who:lower() == "any") and nil or who
    if not id then print("name the drone for " .. cmd) return end
    rednet.broadcast({ cmd = cmd }, "drone-cmd")
    print(cmd .. " sent to anything flying on this cable (fly takes it by word, not by name)")
    return
  end

  local near = padByName(args[3]) or nil
  local id, why = orderFly(who, line2, near)
  if not id then print("ops: " .. tostring(why)) return end
  if why then print(why) end
  print(string.format("%s -> %s: fly %s", me, id, line2))
  print("waiting for an ack...")
  local t0 = os.clock()
  while os.clock() - t0 < 5 do
    local _, msg, proto = rednet.receive(F.PROTO, 5 - (os.clock() - t0))
    if type(msg) == "table" and msg.type == "job.ack" and msg.drone == id then
      print(msg.ok and ("  " .. id .. " took it") or ("  " .. id .. " refused: " .. tostring(msg.why)))
      return
    end
  end
  print("  no ack - is it docked with its connector on the cable, and is beacon running?")
  return
end

if cmd == "stats" then
  print("listening 10 s for pad reports (each pad sends on the minute and after a ride)...")
  local heard = 0
  parallel.waitForAny(function()
    while true do
      local _, msg = rednet.receive(F.PROTO)
      if type(msg) == "table" and msg.type == "pad.stats" and F.check(msg) then
        heard = heard + 1
        print(string.format("  %-10s %4d rides  %4d asked  %3d failed  %8d blocks",
          msg.pad, msg.rides, msg.requests or 0, msg.failures or 0, msg.blocks or 0))
      end
    end
  end, function() sleep(10) end)
  if heard == 0 then print("  nothing reported - are the pads cabled to this computer?") end
  return
end

if cmd ~= "watch" then
  print("ops: watch | list | fly <who> <...> | send <who> <pad> | land|hold|undock <who> | stats")
  return
end

-- ---------------------------------------------------------------- watching --
print(string.format("ops %s: %d key%s, %d pad%s, %d wired modem%s", me,
  nKeys, nKeys == 1 and "" or "s", #pads, #pads == 1 and "" or "s",
  #wired, #wired == 1 and "" or "s"))
print(openToHails and "dispatching pads and radio hails. Q quits."
                   or "dispatching pads only - radio hails turned away. Q quits.")

-- One message. Kept separate so serve can run it under pcall: a single
-- malformed packet must never be able to stop ops answering customers.
local function handle(from, msg)
  do
    if type(msg) == "table" and (F.check(msg)) then
      if msg.type == "taxi.request" then
        local caller = tostring(msg.who or from)
        if not F.fresh(seenNonce, msg.nonce, os.clock()) then
          -- a repeat of one already in hand: a customer leaning on the button
        else
          -- the rate slot is only spent on a hail we are really going to act on
          local slowEnough, whyRate = F.rateOk(lastHail, caller, os.clock(), HAIL_EVERY)
          if not slowEnough then
            pcall(rednet.send, from, F.ack("j-none", "ops", false, whyRate, nonce()), F.PROTO)
            log("another hail from %s, %s", caller, whyRate)
          else
            local id, why = dispatch(msg, from)
            log("%s from %s: %s",
              msg.pad and ("pad " .. msg.pad) or string.format("hail at %d,%d", msg.px or 0, msg.pz or 0),
              caller,
              id and (id .. " " .. tostring(why)) or ("nobody: " .. tostring(why)))
          end
        end
      elseif msg.type == "ops.ping" then
        -- "can you hear me?" - and how many drones are free right now
        local free = 0
        for _, d in pairs(fleet) do if (F.available(d, os.clock())) then free = free + 1 end end
        pcall(rednet.send, from, F.ack("ping", "ops", true, free .. " free", nonce()), F.PROTO)
        log("ping from %s - answered, %d free", tostring(from), free)
      elseif msg.type == "job.go" then
        -- the customer is aboard. They may be on the radio; the drone only
        -- ever hears this over the wire, from here.
        local j = jobs[msg.job]
        if j then order(j.drone, F.go(j.id, nonce())) end
      elseif msg.type == "job.state" then
        local j = jobs[msg.job]
        if j then
          j.state = msg.state
          if j.client then pcall(rednet.send, j.client, msg, F.PROTO) end
          if msg.state == "done" or msg.state == "failed" then
            if fleet[msg.drone] then fleet[msg.drone].job = nil end
          end
        end
        log("%s %s%s", msg.drone, msg.state, msg.detail and (" - " .. msg.detail) or "")
      elseif msg.type == "pad.stats" then
        padStats[msg.pad] = msg
      end
    elseif type(msg) == "table" and msg.v ~= nil then
      local _, whyBad = F.check(msg)
      log("ignored a %s: %s", tostring(msg.type), tostring(whyBad))
    end
  end
end

local function serve()
  while true do
    local from, msg = rednet.receive(F.PROTO)
    local ok, err = pcall(handle, from, msg)
    if not ok then log("ERROR handling %s: %s", type(msg) == "table" and tostring(msg.type) or "?", tostring(err)) end
  end
end

local function draw()
  while true do
    term.clear()
    term.setCursorPos(1, 1)
    print(string.format("OPS  %s   %d refused", textutils.formatTime(os.time(), true), rejected))
    board()
    local n = 0
    for _ in pairs(padStats) do n = n + 1 end
    if n > 0 then
      print("")
      for pad, s in pairs(padStats) do
        print(string.format("%-10s %d rides today, %d asked", pad, s.rides, s.requests or 0))
      end
    end
    if #events > 0 then
      print("")
      for _, line in ipairs(events) do print(line) end
    end
    sleep(2)
  end
end

local function keys()
  while true do
    local _, ch = os.pullEvent("char")
    if tostring(ch):lower() == "q" then return end
  end
end

parallel.waitForAny(receive, serve, draw, keys)
print("ops stopped")
