-- taxipad: the customer end. A computer standing at a pad that calls a drone
-- to come and take someone somewhere.
--
--   taxipad                 serve customers at this pad
--   taxipad here <name>     say which pad this is (once, then it remembers)
--   taxipad stats           what this pad has done
--
-- The customer types where they want to go and presses ENTER. The pad asks the
-- base (ops) for a drone, the drone flies here and docks, the customer gets on
-- and presses G, and it flies them there and lands.
--
-- Everything goes out over the WIRED network on protocol dronenet, the same
-- rule the rest of the fleet follows: no radio, so nobody out of sight can
-- order a drone or pretend to be one. The pad holds no keys - it cannot read
-- telemetry and it cannot forge any - so a public terminal is only ever a
-- customer, never an operator.
--
-- Every press is stamped with a nonce that never repeats, so leaning on the
-- button orders one taxi, not five.
--
-- Usage is counted here and reported to ops: rides, asks, failures and blocks
-- flown, kept in .padstats across reboots.

local F = dofile("lib/fleet.lua")

local args = { ... }
local sub = (args[1] or "serve"):lower()
local PADFILE, STATS = ".pad", ".padstats"

-- ---------------------------------------------------------------- this pad --
local function readPad()
  if not fs.exists(PADFILE) then return nil end
  local h = fs.open(PADFILE, "r")
  local name = (h.readLine() or ""):lower()
  h.close()
  return name ~= "" and name or nil
end

local padName = readPad()

if sub == "here" then
  local name = tostring(args[2] or ""):lower()
  if not name:match("^[%w_%-]+$") then
    print("taxipad here <name>   (letters, numbers, - and _)")
    return
  end
  local h = fs.open(PADFILE, "w")
  h.write(name)
  h.close()
  print("this pad is now called " .. name)
  print("it must also exist in pads.lua so a drone can ferry to it:")
  print("  on the drone, stand it here docked and run: fly pad add " .. name)
  return
end

if not padName then
  print("taxipad: which pad is this? Run:  taxipad here <name>")
  return
end

-- Where the pad is. pads.lua if this computer has one, else the position the
-- customer's drone will be told - so ask once and keep it.
local pad = { name = padName }
do
  local okP, P = pcall(dofile, "lib/pads.lua")
  if okP and type(P) == "table" then
    local got = P.get(P.load("pads.lua", fs) or {}, padName)
    if got then pad.x, pad.y, pad.z = got.x, got.y, got.z end
  end
end

local stats = F.loadStats(STATS, fs, padName)

if sub == "stats" then
  print(F.statsText(stats))
  if stats.lastRide then print("last ride at " .. tostring(stats.lastRide)) end
  return
end

if sub ~= "serve" then
  print("taxipad | taxipad here <name> | taxipad stats")
  return
end

-- ------------------------------------------------------------------ wiring --
local wired = F.wired(peripheral)
for _, nm in ipairs(wired) do pcall(rednet.open, nm) end
if #wired == 0 then
  print("taxipad: no wired modem. Cable this computer to the base and try again.")
  return
end

local seq = 0
local function nonce()
  seq = seq + 1
  return F.nonce(padName, tostring(os.epoch and os.epoch("utc") or os.time()) .. "." .. seq)
end

local function save()
  local ok, why = F.saveStats(STATS, stats, fs)
  if not ok then print("(usage not saved: " .. tostring(why) .. ")") end
  rednet.broadcast(F.statsMessage(stats, nonce()), F.PROTO)
end

-- ------------------------------------------------------------------- input --
local function ask(prompt)
  term.write(prompt)
  return read()
end

local function number(s)
  local n = tonumber((tostring(s or ""):gsub("[^%-%d%.]", "")))
  return n
end

local function banner()
  term.clear()
  term.setCursorPos(1, 1)
  print("=== CHILL GRILL AIR TAXI ===")
  print("pad: " .. padName .. (pad.x and string.format("  (%d, %d)", pad.x, pad.z) or "  (position unknown)"))
  print(string.format("%d rides so far", stats.rides or 0))
  print("")
end

-- Follow one job until it ends. Returns "done", "failed" or "gave up".
local function ride(job, dest)
  local boarded = false
  local t0 = os.clock()
  while true do
    local timeout = boarded and 300 or 180
    if os.clock() - t0 > timeout then return "gave up" end
    local ev = { os.pullEvent() }
    if ev[1] == "rednet_message" then
      local msg, proto = ev[3], ev[4]
      if proto == F.PROTO and type(msg) == "table" and (F.check(msg)) and msg.job == job then
        if msg.type == "job.state" then
          if msg.state == "enroute" then
            print("your taxi is on its way (" .. msg.drone .. ")")
          elseif msg.state == "waiting" then
            print("")
            print("*** your taxi is here - get on board, then press G ***")
            boarded = true
          elseif msg.state == "riding" then
            print("on the way. Sit tight.")
          elseif msg.state == "done" then
            return "done"
          elseif msg.state == "failed" then
            print("the flight ended early: " .. tostring(msg.detail))
            return "failed"
          end
        elseif msg.type == "job.ack" and msg.ok == false then
          print("refused: " .. tostring(msg.why))
          return "failed"
        end
      end
    elseif ev[1] == "char" and tostring(ev[2]):lower() == "g" and boarded then
      rednet.broadcast(F.go(job, nonce()), F.PROTO)
      print("off we go.")
    elseif ev[1] == "char" and tostring(ev[2]):lower() == "q" then
      return "gave up"
    end
  end
end

-- ------------------------------------------------------------------- serve --
print("taxipad " .. padName .. " on " .. table.concat(wired, ", "))
save()

while true do
  banner()
  print("Where to? Coordinates from F3, or Q to quit.")
  local sx = ask("  X: ")
  if tostring(sx):lower() == "q" then print("bye") return end
  local sz = ask("  Z: ")
  local x, z = number(sx), number(sz)
  if not (x and z) then
    print("I need two numbers. Try again.")
    sleep(2)
  else
    local sy = ask("  Y (blank = ground): ")
    local y = number(sy)
    if not pad.x then
      print("this pad does not know where it is - add it to pads.lua first")
      sleep(3)
    else
      local dist = math.sqrt((x - pad.x) ^ 2 + (z - pad.z) ^ 2)
      print("")
      print(string.format("%d, %d is %d blocks away.", x, z, math.floor(dist)))
      local yes = ask("Order the taxi? (y/N) ")
      if tostring(yes):lower():sub(1, 1) == "y" then
        stats.requests = (stats.requests or 0) + 1
        local req = F.request(pad, { x = x, z = z, y = y }, nonce(), "pad " .. padName)
        rednet.broadcast(req, F.PROTO)
        print("asking the base for a drone...")
        -- ops answers with an assignment carrying the same nonce
        local job, t0 = nil, os.clock()
        while os.clock() - t0 < 10 and not job do
          local _, msg, proto = rednet.receive(F.PROTO, 10)
          if proto == F.PROTO and type(msg) == "table" and msg.nonce == req.nonce
             and msg.type == "job.assign" then
            job = msg.job
          elseif type(msg) == "table" and msg.type == "job.ack" and msg.ok == false then
            print("no taxi available: " .. tostring(msg.why))
            break
          end
        end
        if not job then
          F.record(stats, "failure")
          print("nothing came back. Try again in a minute.")
          save()
          sleep(4)
        else
          local how = ride(job, { x = x, z = z })
          if how == "done" then
            F.record(stats, "ride", { at = os.epoch and math.floor(os.epoch("utc") / 1000) or os.time(), blocks = dist })
            print("you have arrived. Thanks for flying.")
          else
            F.record(stats, "failure")
            print("that ride did not finish (" .. how .. ").")
          end
          save()
          print("")
          ask("press ENTER for the next customer ")
        end
      end
    end
  end
end
