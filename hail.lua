-- hail: the customer's terminal, in their pocket. It calls a taxi to wherever
-- they are standing and flies them where they ask.
--
--   hail               serve customers: pick a place, a drone comes
--   hail 1200 340      one ride, straight to those coordinates
--   hail stats         what this terminal has been used for
--   hail test          ask the base if it can hear this terminal
--
-- Meant for a wireless pocket computer, so the customer can be anywhere. It
-- finds them with gps.locate; with no GPS in range it asks them to type where
-- they are, once per ride.
--
-- The places on the menu are the pads the base knows (it asks ops for them at
-- the start and after every ride), plus anything in places.lua on this
-- computer - one per line as "name x z", or a pads-style table. Typing
-- coordinates still works and always will: the menu is a shortcut, not a cage.
--
-- This talks to ops by RADIO, which is a request and never an order: ops
-- decides whether to send anyone, rate-limits every caller, and the flight
-- command it sends the drone is sealed with that drone's key. Nothing here can
-- re-route a drone in the air, and this terminal holds no keys.
--
-- Each terminal counts its own use - rides, asks, failures, blocks flown - in
-- .hailstats, and reports it to ops after every ride.

local F = dofile("lib/fleet.lua")

local args = { ... }
local sub = (args[1] or ""):lower()
local STATS, PLACES = ".hailstats", "places.lua"

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

-- ------------------------------------------------------------------ paint ---
-- Imperial: amber on black, hard rules, no rounded anything. A pocket screen
-- is 26x20, so every line is cut to fit and nothing wraps.
local W, H = term.getSize()
local AMBER = colours and colours.orange or 2
local DIM = colours and colours.brown or 4096
local PAPER = colours and colours.black or 32768
local INK = colours and colours.white or 1

local colour = term.isColour and term.isColour()
local function fg(c) if colour then term.setTextColour(c) end end
local function bg(c) if colour then term.setBackgroundColour(c) end end

local function at(x, y, s, c)
  if y < 1 or y > H then return end
  term.setCursorPos(x, y)
  fg(c or AMBER)
  term.write(tostring(s):sub(1, W - x + 1))
end

local function rule(y, c)
  if y < 1 or y > H then return end
  term.setCursorPos(1, y)
  fg(c or DIM)
  term.write(string.rep("-", W))
end

local function frame(title, note)
  bg(PAPER)
  term.clear()
  at(1, 1, "CHILL GRILL AIR TAXI", AMBER)
  rule(2)
  if title then at(1, 3, title, INK) end
  if note then at(1, 4, note, DIM) end
  fg(AMBER)
end

-- the scrolling slash, one character, turned by hand
local SPIN = { "|", "/", "-", "\\" }
local function spinner(y, text, n)
  at(1, y, SPIN[(n % 4) + 1] .. " " .. text, AMBER)
end

local function ask(prompt)
  fg(AMBER)
  term.write(prompt)
  fg(INK)
  local said = read()
  fg(AMBER)
  return said
end

-- ----------------------------------------------------------------- places ---
local function coords(s)
  local n = {}
  for w in tostring(s or ""):gmatch("%-?%d+%.?%d*") do n[#n + 1] = tonumber(w) end
  if #n == 2 then return n[1], nil, n[2] end
  if #n >= 3 then return n[1], n[2], n[3] end
  return nil
end

-- places.lua on this computer: either a pads-style table, or plain lines of
-- "name x z" for anyone who does not want to write Lua
local function localPlaces()
  if not fs.exists(PLACES) then return {} end
  local h = fs.open(PLACES, "r")
  local text = h.readAll() or ""
  h.close()
  local out = {}
  if text:match("return%s*{") then
    local chunk = (loadstring or load)(text, "places")
    if chunk and setfenv then setfenv(chunk, {}) end
    local ok, t = false, nil
    if chunk then ok, t = pcall(chunk) end
    if ok and type(t) == "table" then
      for _, p in ipairs(t) do
        if type(p) == "table" and p.name and tonumber(p.x) and tonumber(p.z) then
          out[#out + 1] = { name = tostring(p.name), x = tonumber(p.x), z = tonumber(p.z), y = tonumber(p.y) }
        end
      end
    end
    return out
  end
  for line in text:gmatch("[^\r\n]+") do
    local name, x, z = line:match("^%s*([%w_%- ]-)%s+(-?%d+)%s+(-?%d+)%s*$")
    if name and name ~= "" then out[#out + 1] = { name = name, x = tonumber(x), z = tonumber(z) } end
  end
  return out
end

local places = localPlaces()

-- Ask ops for its pads and fold them in. Whatever has arrived by the deadline
-- is what the menu shows: a customer never waits on the base.
local function refreshPlaces(secs)
  pcall(rednet.broadcast, F.placesAsk(nonce()), F.PROTO)
  local t0 = os.clock()
  while os.clock() - t0 < (secs or 1.5) do
    local _, msg = rednet.receive(F.PROTO, (secs or 1.5) - (os.clock() - t0))
    if type(msg) == "table" and msg.type == "places.list" and (F.check(msg)) then
      local known = {}
      for _, p in ipairs(places) do known[p.name:lower()] = true end
      for _, p in ipairs(F.unpackPlaces(msg.places)) do
        if not known[p.name:lower()] then places[#places + 1] = p end
      end
      return true
    end
  end
  return false
end

-- ------------------------------------------------------------------ where ---
local function whereAmI()
  local x, y, z = gps.locate(3)
  if x then return { x = math.floor(x), y = math.floor(y), z = math.floor(z) } end
  frame("WHERE ARE YOU?", "no GPS - read it off F3")
  term.setCursorPos(1, 6)
  local px, py, pz = coords(ask("> "))
  if not px then return nil end
  return { x = px, y = py, z = pz }
end

local function dist(a, bx, bz) return math.sqrt((bx - a.x) ^ 2 + (bz - a.z) ^ 2) end

-- The menu. Returns x, y, z, name - or nil if they backed out.
local function chooseDestination(from)
  local page = 0
  while true do
    frame("WHERE TO?", string.format("you are at %d, %d", from.x, from.z))
    local rows = H - 8
    local first = page * rows + 1
    local shown = 0
    for i = first, math.min(#places, first + rows - 1) do
      local p = places[i]
      shown = shown + 1
      at(1, 4 + shown, string.format("%2d %-11s %5d", i, p.name:sub(1, 11), math.floor(dist(from, p.x, p.z))))
    end
    if #places == 0 then at(1, 5, "(no places known)", DIM) end
    local more = #places > first + rows - 1
    rule(H - 3)
    at(1, H - 2, more and "number / C coords / M more" or "number / C coords", DIM)
    at(1, H - 1, "Q back", DIM)
    term.setCursorPos(1, H)
    local said = ask("> ")
    local pick = tonumber(said)
    local letter = tostring(said):lower():sub(1, 1)
    if pick and places[pick] then
      local p = places[pick]
      return p.x, p.y, p.z, p.name
    elseif letter == "m" and more then
      page = page + 1
    elseif letter == "q" then
      return nil
    elseif letter == "c" then
      frame("WHERE TO?", "coordinates, like 1200 340")
      term.setCursorPos(1, 6)
      local tx, ty, tz = coords(ask("> "))
      if tx then return tx, ty, tz, string.format("%d, %d", tx, tz) end
    elseif said and said:match("%d") then
      local tx, ty, tz = coords(said)
      if tx then return tx, ty, tz, string.format("%d, %d", tx, tz) end
    else
      page = 0
    end
  end
end

-- ------------------------------------------------------------------- ride ---
-- Follow one job to its end, drawing where the taxi is. Returns "done",
-- "failed" or "gave up".
local function follow(job, from, name)
  local aboard, state, drone, away = false, "calling", nil, nil
  local n, t0 = 0, os.clock()
  while true do
    if os.clock() - t0 > (aboard and 600 or 300) then return "gave up" end
    frame("TAXI: " .. tostring(name):upper(), drone and ("unit " .. drone) or "finding a unit")
    at(1, 6, state == "enroute" and "on its way to you"
          or state == "waiting" and "HERE - get aboard"
          or state == "riding" and "flying you there"
          or "calling a taxi", INK)
    if away then at(1, 7, string.format("%d blocks away", math.floor(away))) end
    if state == "waiting" then
      rule(9)
      at(1, 10, "PRESS  G  TO GO", INK)
      rule(11)
    end
    at(1, H - 1, "Q gives up", DIM)
    spinner(H, state:upper(), n)
    n = n + 1

    local timer = os.startTimer(0.25)
    local ev = { os.pullEvent() }
    if ev[1] == "rednet_message" then
      local msg = ev[3]
      if type(msg) == "table" and msg.job == job and (F.check(msg)) then
        if msg.type == "job.track" then
          drone, away = msg.drone or drone, dist(from, msg.x, msg.z)
        elseif msg.type == "job.state" then
          state, drone = msg.state, msg.drone or drone
          if msg.state == "waiting" then aboard = true end
          if msg.state == "done" then return "done" end
          if msg.state == "failed" then
            frame("RIDE ENDED", "")
            at(1, 6, "ended early", INK)
            at(1, 7, tostring(msg.detail), DIM)
            sleep(4)
            return "failed"
          end
        end
      end
    elseif ev[1] == "char" then
      local ch = tostring(ev[2]):lower()
      if ch == "g" and aboard then
        pcall(rednet.broadcast, F.go(job, nonce()), F.PROTO)
        state = "riding"
      elseif ch == "q" then
        return "gave up"
      end
    end
    if ev[1] ~= "timer" then pcall(os.cancelTimer, timer) end
  end
end

-- one ride, start to finish
local function oneRide(tx, ty, tz, name)
  local from = whereAmI()
  if not from then return end
  if not tx then
    tx, ty, tz, name = chooseDestination(from)
    if not tx then return end
  end
  name = name or string.format("%d, %d", tx, tz)
  local away = dist(from, tx, tz)

  frame("CONFIRM", name)
  at(1, 6, string.format("%d blocks", math.floor(away)), INK)
  at(1, 8, "ENTER to call")
  at(1, 9, "anything else goes back", DIM)
  term.setCursorPos(1, 11)
  if ask("> ") ~= "" then return end

  stats.requests = (stats.requests or 0) + 1
  local req = F.request(from, { x = tx, z = tz, y = ty }, nonce(), me)
  pcall(rednet.broadcast, req, F.PROTO)

  frame("CALLING", name)
  local job, t0, refused, heard, n = nil, os.clock(), nil, false, 0
  while os.clock() - t0 < 15 and not job and not refused do
    spinner(H, "asking the base", n)
    n = n + 1
    local timer = os.startTimer(0.25)
    local ev = { os.pullEvent() }
    if ev[1] == "rednet_message" then
      local msg = ev[3]
      if type(msg) == "table" then heard = true end
      if type(msg) == "table" and msg.nonce == req.nonce and msg.type == "job.assign" then
        job = msg.job
      elseif type(msg) == "table" and msg.type == "job.ack" and msg.ok == false then
        refused = tostring(msg.why)
      end
    end
    if ev[1] ~= "timer" then pcall(os.cancelTimer, timer) end
  end

  if not job then
    F.record(stats, "failure")
    save()
    frame("NO TAXI", "")
    at(1, 6, refused or (heard and "the base sent nobody" or "nothing came back"), INK)
    if not (refused or heard) then
      at(1, 8, "is ops running, and are", DIM)
      at(1, 9, "you in radio range?", DIM)
      at(1, 10, "try: hail test", DIM)
    end
    sleep(6)
    return
  end

  local how = follow(job, from, name)
  if how == "done" then
    F.record(stats, "ride", { at = os.epoch and math.floor(os.epoch("utc") / 1000) or os.time(), blocks = away })
    frame("ARRIVED", name)
    at(1, 6, "thanks for flying", INK)
  else
    F.record(stats, "failure")
    frame("RIDE ENDED", how)
  end
  save()
  sleep(3)
  refreshPlaces(0.8)
end

-- ------------------------------------------------------------------- test ---
if sub == "test" then
  pcall(rednet.broadcast, F.ping(nonce()), F.PROTO)
  frame("LINK TEST", "asking the base to answer")
  local t0, n = os.clock(), 0
  while os.clock() - t0 < 6 do
    spinner(H, "listening", n)
    n = n + 1
    local timer = os.startTimer(0.25)
    local ev = { os.pullEvent() }
    if ev[1] == "rednet_message" and type(ev[3]) == "table"
       and ev[3].type == "job.ack" and ev[3].job == "ping" then
      at(1, 6, "the base can hear you", INK)
      at(1, 7, tostring(ev[3].why), AMBER)
      term.setCursorPos(1, H)
      print("")
      return
    end
    if ev[1] ~= "timer" then pcall(os.cancelTimer, timer) end
  end
  at(1, 6, "no answer in 6 s", INK)
  at(1, 8, "ops not running, or you", DIM)
  at(1, 9, "are out of radio range", DIM)
  term.setCursorPos(1, H)
  print("")
  return
end

-- ------------------------------------------------------------------ serve ---
local tx0, ty0, tz0 = coords(table.concat(args, " "))
if tx0 then
  oneRide(tx0, ty0, tz0, nil)
  return
end

frame("STARTING", "asking the base for places")
refreshPlaces(2)
save()

while true do
  frame("AIR TAXI", string.format("%d rides from this unit", stats.rides or 0))
  at(1, 6, "ENTER  call a taxi", INK)
  at(1, 7, "R      refresh places", DIM)
  at(1, 8, "Q      stop", DIM)
  at(1, 10, string.format("%d places known", #places), DIM)
  term.setCursorPos(1, 12)
  local said = tostring(ask("> ")):lower()
  if said == "q" then
    frame("STOPPED", "")
    term.setCursorPos(1, 6)
    print("")
    return
  elseif said == "r" then
    frame("PLACES", "asking the base")
    refreshPlaces(2)
  else
    oneRide(nil, nil, nil, nil)
  end
end
