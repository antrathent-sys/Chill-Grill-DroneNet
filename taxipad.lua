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

local function nameIt(name)
  name = tostring(name or ""):lower()
  if not name:match("^[%w_%-]+$") then return nil end
  local h = fs.open(PADFILE, "w")
  h.write(name)
  h.close()
  print("this pad is now called " .. name)
  print("it must also exist in pads.lua so a drone can ferry to it:")
  print("  on the drone, stand it here docked and run: fly pad add " .. name)
  return name
end

if sub == "here" then
  if not nameIt(args[2]) then print("taxipad here <name>   (letters, numbers, - and _)") end
  return
end

-- An unnamed pad ASKS. It used to print how to name it and quit, which under
-- `startup autorun taxipad` is a restart loop: the program ends, autorun starts
-- it again, it ends again, for ever (seen on the first pad built, 2026-09-20).
-- Anything that runs from autorun has to settle into a wait, never exit.
while not padName do
  print("")
  print("Which pad is this? (letters, numbers, - and _)")
  term.write("  name: ")
  local typed = read()
  padName = nameIt(typed)
  if not padName then
    print("that name will not do.")
    sleep(1)      -- never spin: this may be running with nobody watching
  end
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
-- Same rule as the name above: under autorun this must wait, not exit, or the
-- program ends and is restarted for ever. Someone may well be cabling the pad
-- up while it sits here.
local wired = F.wired(peripheral)
while #wired == 0 do
  print("taxipad: no wired modem yet - put one on this computer and cable it")
  print("         to the base. Checking again every 5 s.")
  sleep(5)
  wired = F.wired(peripheral)
end
for _, nm in ipairs(wired) do pcall(rednet.open, nm) end

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
            print("  " .. msg.drone .. " is on its way. Stand clear of the pad.")
          elseif msg.state == "waiting" then
            print("")
            print("  ***  YOUR TAXI IS HERE  ***")
            print("  Climb aboard, then press G to go.")
            print("")
            boarded = true
          elseif msg.state == "riding" then
            print("  On our way. Sit tight.")
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
-- The whole customer flow is two presses: type where you are going, then ENTER.
-- Everything else the pad does for them. Coordinates go in on ONE line, in the
-- order F3 shows them, so a passenger can read them straight off the screen:
--   1200 340        x and z
--   1200 72 340     x, y and z, as F3 prints it
-- A stray comma or "x=" is thrown away rather than refused.
print("taxipad " .. padName .. " on " .. table.concat(wired, ", "))
save()

-- pull the numbers out of whatever they typed
local function coords(s)
  local n = {}
  for w in tostring(s or ""):gmatch("%-?%d+%.?%d*") do n[#n + 1] = tonumber(w) end
  if #n == 2 then return n[1], nil, n[2] end
  if #n >= 3 then return n[1], n[2], n[3] end
  return nil
end

local function bigMessage(...)
  local lines = { ... }
  print("")
  for _, l in ipairs(lines) do print("  " .. l) end
  print("")
end

while true do
  banner()
  print("Where to? Type the coordinates and press ENTER.")
  print("(from F3, like  1200 340  - or Q to quit)")
  print("")
  local said = ask("  > ")
  if tostring(said):lower() == "q" then print("bye") return end
  local x, y, z = coords(said)
  if not x then
    bigMessage("I did not catch that.", "Two numbers, like  1200 340")
    sleep(2)
  elseif not pad.x then
    bigMessage("This pad does not know where it is.",
               "Ask an operator to run: fly pad add " .. padName)
    sleep(4)
  else
    local dist = math.sqrt((x - pad.x) ^ 2 + (z - pad.z) ^ 2)
    bigMessage(string.format("%d, %d  -  %d blocks away", x, z, math.floor(dist)),
               "ENTER to call your taxi, or anything else to change it")
    local go = ask("  > ")
    if go == "" then
      stats.requests = (stats.requests or 0) + 1
      local req = F.request(pad, { x = x, z = z, y = y }, nonce(), "pad " .. padName)
      rednet.broadcast(req, F.PROTO)
      print("Calling a taxi...")
      local job, t0, refused = nil, os.clock(), nil
      while os.clock() - t0 < 10 and not job and not refused do
        local _, msg, proto = rednet.receive(F.PROTO, 10)
        if proto == F.PROTO and type(msg) == "table" and msg.nonce == req.nonce
           and msg.type == "job.assign" then
          job = msg.job
        elseif type(msg) == "table" and msg.type == "job.ack" and msg.ok == false then
          refused = tostring(msg.why)
        end
      end
      if not job then
        F.record(stats, "failure")
        save()
        bigMessage("No taxi free just now.", refused or "Nothing answered.", "Try again in a minute.")
        sleep(5)
      else
        local how = ride(job, { x = x, z = z })
        if how == "done" then
          F.record(stats, "ride", { at = os.epoch and math.floor(os.epoch("utc") / 1000) or os.time(), blocks = dist })
          bigMessage("You have arrived. Thanks for flying.")
        else
          F.record(stats, "failure")
          bigMessage("That ride did not finish (" .. how .. ").")
        end
        save()
        sleep(4)
      end
    end
  end
end
