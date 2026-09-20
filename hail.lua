-- hail: call a taxi to wherever you are standing.
--
--   hail            find yourself by GPS, ask where to, call a drone
--   hail 1200 340   skip straight to the destination
--
-- Meant for a wireless pocket computer. It finds the customer with gps.locate,
-- so the world needs a GPS constellation in range; if there is none it asks
-- them to type where they are.
--
-- This talks to ops by RADIO, which the rest of the fleet deliberately does not
-- do. The line it must not cross: a hail is a REQUEST, never an order. ops
-- decides whether to send anyone, and the flight command still reaches the
-- drone over the wired network (lib/fleet.lua, MISSIONCONTROL.md:52-59). The
-- worst a forged hail can do is ask for a taxi that ops may refuse, and ops
-- rate-limits and prints every one. Nothing here can re-route a drone already
-- in the air.

local F = dofile("lib/fleet.lua")

local args = { ... }

local radio
for _, nm in ipairs(peripheral.getNames()) do
  if peripheral.getType(nm) == "modem" then
    local ok, wireless = pcall(peripheral.call, nm, "isWireless")
    if ok and wireless then radio = radio or nm end
  end
end
if not radio then
  print("hail: this computer has no wireless modem, so it cannot call anyone.")
  return
end
rednet.open(radio)

local me = (os.getComputerLabel and os.getComputerLabel()) or ("hail-" .. tostring(os.getComputerID()))
local seq = 0
local function nonce()
  seq = seq + 1
  return F.nonce(me, tostring(os.epoch and os.epoch("utc") or os.clock()) .. "." .. seq)
end

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

-- ------------------------------------------------------------ where am I ----
term.clear()
term.setCursorPos(1, 1)
print("=== CHILL GRILL AIR TAXI ===")
print("finding you...")

local from
do
  local x, y, z = gps.locate(3)
  if x then
    from = { x = math.floor(x), y = math.floor(y), z = math.floor(z) }
    print(string.format("you are at %d, %d", from.x, from.z))
  else
    print("no GPS here. Where are you? (from F3, like  812 -344)")
    local px, py, pz = coords(ask("  > "))
    if not px then print("I need two numbers. Nothing called.") return end
    from = { x = px, y = py, z = pz }
  end
end

-- --------------------------------------------------------------- where to ---
local tx, ty, tz = coords(table.concat(args, " "))
if not tx then
  print("")
  print("Where to? (from F3, like  1200 340)")
  tx, ty, tz = coords(ask("  > "))
  if not tx then print("I need two numbers. Nothing called.") return end
end

local dist = math.sqrt((tx - from.x) ^ 2 + (tz - from.z) ^ 2)
print("")
print(string.format("  %d, %d  -  %d blocks", tx, tz, math.floor(dist)))
print("  ENTER to call your taxi, anything else to stop")
if ask("  > ") ~= "" then print("nothing called") return end

-- ------------------------------------------------------------- the ride -----
local req = F.request(from, { x = tx, z = tz, y = ty }, nonce(), me)
rednet.broadcast(req, F.PROTO)
print("calling...")

local job, t0 = nil, os.clock()
while os.clock() - t0 < 15 and not job do
  local _, msg = rednet.receive(F.PROTO, 15)
  if type(msg) == "table" and msg.nonce == req.nonce and msg.type == "job.assign" then
    job = msg.job
  elseif type(msg) == "table" and msg.type == "job.ack" and msg.ok == false then
    print("no taxi: " .. tostring(msg.why))
    return
  end
end
if not job then
  print("nobody answered. The base may be off, or out of radio range.")
  return
end

print("a taxi is coming to you. G when you are aboard, Q to give up.")
local boarded = false
while true do
  local ev = { os.pullEvent() }
  if ev[1] == "rednet_message" then
    local msg = ev[3]
    if type(msg) == "table" and msg.job == job and (F.check(msg)) and msg.type == "job.state" then
      if msg.state == "enroute" then
        print("  " .. tostring(msg.drone) .. " is on its way. Stand clear.")
      elseif msg.state == "waiting" then
        print("")
        print("  ***  YOUR TAXI HAS LANDED  ***")
        print("  Climb aboard, then press G.")
        boarded = true
      elseif msg.state == "riding" then
        print("  on our way.")
      elseif msg.state == "done" then
        print("  you have arrived. Thanks for flying.")
        return
      elseif msg.state == "failed" then
        print("  the flight ended early: " .. tostring(msg.detail))
        return
      end
    end
  elseif ev[1] == "char" then
    local ch = tostring(ev[2]):lower()
    if ch == "g" and boarded then
      rednet.broadcast(F.go(job, nonce()), F.PROTO)
      print("  off we go.")
    elseif ch == "q" then
      print("  gave up waiting")
      return
    end
  end
end
