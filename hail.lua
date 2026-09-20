-- hail: the customer's terminal, in their pocket. It calls a taxi to wherever
-- they are standing and flies them where they ask.
--
--   hail               serve customers: find them, ask where to, call a drone
--   hail 1200 340      one ride, straight to that destination
--   hail stats         what this terminal has been used for
--
-- Meant for a wireless pocket computer, so the customer can be anywhere. It
-- finds them with gps.locate; with no GPS in range it asks them to type where
-- they are, once per ride.
--
-- This talks to ops by RADIO, which the rest of the fleet deliberately does
-- not do. The line it does not cross: a hail is a REQUEST, never an order. ops
-- decides whether to send anyone, and the flight command still reaches the
-- drone over the wired network (lib/fleet.lua, MISSIONCONTROL.md:52-59). The
-- worst a forged hail can do is ask for a taxi ops may refuse, and ops
-- rate-limits every caller and prints each one. Nothing here can re-route a
-- drone that is already in the air, and this terminal holds no keys.
--
-- Each terminal counts its own use - rides, asks, failures, blocks flown - in
-- .hailstats, and reports it to ops after every ride.

local F = dofile("lib/fleet.lua")

local args = { ... }
local sub = (args[1] or ""):lower()
local STATS = ".hailstats"

local me = (os.getComputerLabel and os.getComputerLabel()) or ("hail-" .. tostring(os.getComputerID()))
local stats = F.loadStats(STATS, fs, me)

if sub == "stats" then
  print(F.statsText(stats))
  return
end

-- ------------------------------------------------------------------ radio ---
-- Waits rather than exits: under `startup autorun hail` an exit is a restart
-- loop, and a pocket computer can lose its modem to a player at any moment.
local function findRadio()
  for _, nm in ipairs(peripheral.getNames()) do
    if peripheral.getType(nm) == "modem" then
      local ok, wireless = pcall(peripheral.call, nm, "isWireless")
      if ok and wireless then return nm end
    end
  end
  return nil
end

local radio = findRadio()
while not radio do
  print("hail: this computer has no wireless modem, so it cannot call anyone.")
  print("      Checking again every 5 s.")
  sleep(5)
  radio = findRadio()
end
rednet.open(radio)

local seq = 0
local function nonce()
  seq = seq + 1
  return F.nonce(me, tostring(os.epoch and os.epoch("utc") or os.clock()) .. "." .. seq)
end

local function save()
  pcall(F.saveStats, STATS, stats, fs)
  pcall(rednet.broadcast, F.statsMessage(stats, nonce()), F.PROTO)
end

-- ------------------------------------------------------------------ input ---
local function coords(s)
  local n = {}
  for w in tostring(s or ""):gmatch("%-?%d+%.?%d*") do n[#n + 1] = tonumber(w) end
  if #n == 2 then return n[1], nil, n[2] end
  if #n >= 3 then return n[1], n[2], n[3] end
  return nil
end

local function ask(prompt)
  term.write(prompt)
  return read()
end

local function banner()
  term.clear()
  term.setCursorPos(1, 1)
  print("== CHILL GRILL AIR TAXI ==")
  print(string.format("%d rides", stats.rides or 0))
  print("")
end

-- where the customer is: GPS if the world has it, otherwise they type it
local function whereAmI()
  local x, y, z = gps.locate(3)
  if x then return { x = math.floor(x), y = math.floor(y), z = math.floor(z) } end
  print("no GPS here. Where are you? (from F3)")
  local px, py, pz = coords(ask("  > "))
  if not px then return nil end
  return { x = px, y = py, z = pz }
end

-- Follow one job to its end. Returns "done", "failed" or "gave up".
local function follow(job)
  local aboard = false
  local t0 = os.clock()
  while true do
    if os.clock() - t0 > (aboard and 600 or 300) then return "gave up" end
    local ev = { os.pullEvent() }
    if ev[1] == "rednet_message" then
      local msg = ev[3]
      if type(msg) == "table" and msg.job == job and (F.check(msg)) and msg.type == "job.state" then
        if msg.state == "enroute" then
          print("  " .. tostring(msg.drone) .. " is on its way. Stand clear.")
        elseif msg.state == "waiting" then
          print("")
          print("  *** YOUR TAXI HAS LANDED ***")
          print("  Climb aboard, then press G.")
          aboard = true
        elseif msg.state == "riding" then
          print("  on our way.")
        elseif msg.state == "done" then
          return "done"
        elseif msg.state == "failed" then
          print("  ended early: " .. tostring(msg.detail))
          return "failed"
        end
      end
    elseif ev[1] == "char" then
      local ch = tostring(ev[2]):lower()
      if ch == "g" and aboard then
        rednet.broadcast(F.go(job, nonce()), F.PROTO)
        print("  off we go.")
      elseif ch == "q" then
        return "gave up"
      end
    end
  end
end

-- one ride, start to finish
local function oneRide(tx, ty, tz)
  local from = whereAmI()
  if not from then print("  I need two numbers.") sleep(2) return end
  print(string.format("you are at %d, %d", from.x, from.z))
  if not tx then
    print("")
    print("Where to? (from F3, like  1200 340)")
    tx, ty, tz = coords(ask("  > "))
    if not tx then print("  I need two numbers.") sleep(2) return end
  end
  local dist = math.sqrt((tx - from.x) ^ 2 + (tz - from.z) ^ 2)
  print("")
  print(string.format("  %d, %d - %d blocks", tx, tz, math.floor(dist)))
  print("  ENTER to call, anything else to change it")
  if ask("  > ") ~= "" then return end

  stats.requests = (stats.requests or 0) + 1
  local req = F.request(from, { x = tx, z = tz, y = ty }, nonce(), me)
  rednet.broadcast(req, F.PROTO)
  print("calling...")

  local job, t0, refused = nil, os.clock(), nil
  while os.clock() - t0 < 15 and not job and not refused do
    local _, msg = rednet.receive(F.PROTO, 15)
    if type(msg) == "table" and msg.nonce == req.nonce and msg.type == "job.assign" then
      job = msg.job
    elseif type(msg) == "table" and msg.type == "job.ack" and msg.ok == false then
      refused = tostring(msg.why)
    end
  end
  if not job then
    F.record(stats, "failure")
    save()
    print("")
    print("  no taxi: " .. (refused or "nobody answered - the base may be off, or out of range"))
    sleep(5)
    return
  end

  local how = follow(job)
  if how == "done" then
    F.record(stats, "ride", { at = os.epoch and math.floor(os.epoch("utc") / 1000) or os.time(), blocks = dist })
    print("  you have arrived. Thanks for flying.")
  else
    F.record(stats, "failure")
    print("  that ride did not finish (" .. how .. ").")
  end
  save()
  sleep(4)
end

-- ------------------------------------------------------------------ serve ---
local tx, ty, tz = coords(table.concat(args, " "))
if tx then
  banner()
  oneRide(tx, ty, tz)
  return
end

save()
while true do
  banner()
  print("Press ENTER to call a taxi, or Q to stop.")
  local said = ask("  > ")
  if tostring(said):lower() == "q" then print("bye") return end
  banner()
  oneRide(nil, nil, nil)
end
