-- admin: the admin pocket - the fleet live, and trips of several legs, Go and
-- Cancel, asked of the base (Alex, 2026-09-29).
--
--   admin      on a pocket computer with an ender (or wireless) modem
--
-- Setup, once:
--   on the base:  seckey admin new <name>        (floppy in the drive), restart ops
--   here:         seckey admin set disk   and   label set <name>
--
-- It never talks to a drone. Requests go to the base sealed with this
-- pocket's own key (lib/seclink.lua, direction ADMIN_TO_BASE); the base vets
-- each and gives the drone its order, so no drone key is ever on a pocket.
-- The fleet, the places, the trips and the base's answers come back on the
-- feed (lib/watch.lua), sealed to this pocket's name.
--
-- Keys:
--   fleet   up/down pick a unit, Enter opens it, Q quits
--   unit    N new trip, G go on from a stop, C cancel its trip, H home,
--           Backspace back. In the air C stops it: it hovers and waits for a
--           new trip (N or H turn it round from there; C again sends it
--           home). N or H while it is flying turn it round too.
--   trip    S add a stop, W add a waypoint, Backspace drops the last leg,
--           Enter sends it, Q back without sending
--   place   up/down, Enter picks, Backspace back
-- A stop lands (a pad) or docks (a dock) and waits for Go; a waypoint is
-- flown over. The base runs the trip and answers at every stop.

local SEC = dofile("lib/seclink.lua")
local F = dofile("lib/fleet.lua")
local link = dofile("lib/link.lua")
local W = dofile("lib/watch.lua")
local ST = dofile("lib/state.lua")

local me = os.getComputerLabel and os.getComputerLabel()
local key = SEC.readKeyFile(".adminkey")
if not key then
  print("admin: no key. On the base: seckey admin new <name>; here: seckey admin set disk")
  return
end
if not me then print("admin: no label - label set <the name the key was made for>") return end
local radio = link.findRadio(peripheral)
if not radio then print("admin: no wireless or ender modem on this pocket") return end
peripheral.call(radio, "open", W.CHANNEL)
local tx = SEC.sender(key, me, SEC.DIR.ADMIN_TO_BASE, ".adminkey.ctr")
local rx = SEC.receiver()

local S = { view = "fleet", sel = 1, psel = 1, units = {}, order = {}, said = {}, legs = {} }
local seq = 0
local FRESH, NEAR = 15, 16

-- the lines at the foot: what was asked, replaced by the base's answer
local SAID_LINES = 6
local function say(text, ok, drone)
  table.insert(S.said, 1, { text = tostring(text), ok = ok, drone = drone, pending = drone ~= nil })
  while #S.said > SAID_LINES do table.remove(S.said) end
end
local function nonce()
  seq = seq + 1
  return F.nonce(me, tostring(os.epoch and os.epoch("utc") or os.clock()) .. "." .. seq)
end
local function send(msg, what)
  local ok, env = pcall(tx.seal, msg)
  if not (ok and env) then say("not sent: " .. tostring(env), false) return end
  pcall(peripheral.call, radio, "transmit", link.CHANNEL, link.CHANNEL, env)
  say(what .. " - sent", nil, msg.drone)
end

-- ------------------------------------------------------------------ the feed
local function onMessage(ch, msg)
  if ch ~= W.CHANNEL or type(msg) ~= "table" or not msg.sl or msg.id ~= me then return end
  local ok, body = pcall(rx.open, msg, function(id) return id == me and key or nil end,
                         SEC.DIR.BASE_TO_WATCH, 120000)
  if not (ok and body) then return end
  W.unwrap(body)
  if body.type == "ops" then
    S.ops, S.opsAt = W.parse(body), os.clock()
  elseif body.type == "admin.ack" then
    -- answers come in the order asked: the oldest waiting line for that unit
    for i = #S.said, 1, -1 do
      local s = S.said[i]
      if s.pending and s.drone == body.drone then s.text, s.ok, s.pending = tostring(body.text), body.ok, false return end
    end
    say(body.text, body.ok)
  elseif body.type == "tlm" and type(body.id) == "string" then
    if not S.units[body.id] then
      S.order[#S.order + 1] = body.id
      table.sort(S.order)
    end
    S.units[body.id] = { pkt = body, got = os.clock() }
  end
end

-- ------------------------------------------------------------ what to show
-- the same words as the control room's screens
local function stateWord(u)
  return ST.stateWord(u and u.pkt, (not u or os.clock() - u.got > FRESH) and "LOST" or "OK")
end
local function places() return S.ops and S.ops.places or {} end
local function where(u)
  if not (u and type(u.pkt.x) == "number") then return "" end
  local best, bd
  for _, p in ipairs(places()) do
    local d = math.sqrt((u.pkt.x - p.x - 0.5) ^ 2 + (u.pkt.z - p.z - 0.5) ^ 2)
    if d <= NEAR and (not bd or d < bd) then best, bd = p, d end
  end
  if best then return best.name:upper() end
  return string.format("%d %d", math.floor(u.pkt.x), math.floor(u.pkt.z))
end
local function tripOf(id)
  for _, t in ipairs(S.ops and S.ops.trips or {}) do if t.drone == id then return t end end
  return nil
end

local colour = term.isColour and term.isColour()
local function ink(c) if colour and c then term.setTextColour(c) end end
local function at(y, text, c)
  local w = term.getSize()
  term.setCursorPos(1, y)
  ink(c or colours.white)
  term.write(tostring(text):sub(1, w))
end
local function rule(y) local w = term.getSize() at(y, string.rep("-", w), colours.grey) end

-- the base's answers are longer than a pocket is wide: wrapped at spaces
local function wrap(text, w)
  local out = {}
  while #text > w do
    local cut = text:sub(1, w + 1):match("^.*() ")
    if not cut or cut < 2 then cut = w + 1 end
    out[#out + 1] = text:sub(1, cut - 1)
    text = (text:sub(cut):gsub("^ +", ""))
  end
  out[#out + 1] = text
  return out
end
local function footLines()
  local w = term.getSize()
  local lines = {}
  for _, s in ipairs(S.said) do
    local c = s.ok == false and colours.red or (s.ok and colours.lime or colours.lightGrey)
    local ls = wrap(s.text, w)
    if #lines + #ls > SAID_LINES then break end
    for _, l in ipairs(ls) do lines[#lines + 1] = { l, c } end
  end
  return lines
end
-- the row of the rule above them
local function footTop() local _, h = term.getSize() return h - #footLines() - 1 end
local function footer(keysLine)
  local _, h = term.getSize()
  local y = footTop()
  rule(y)
  for i, l in ipairs(footLines()) do at(y + i, l[1], l[2]) end
  at(h, keysLine, colours.lightGrey)
end

local function drawFleet()
  local w = term.getSize()
  at(1, "CINDER ADMIN", colours.orange)
  term.setCursorPos(math.max(1, w - #me + 1), 1)
  ink(colours.lightGrey)
  term.write(me)
  rule(2)
  if #S.order == 0 then
    at(3, S.opsAt and "no units heard yet" or "waiting for the base...", colours.lightGrey)
  end
  for i, id in ipairs(S.order) do
    local u = S.units[id]
    local line = string.format("%s%-8s %-8s %s", i == S.sel and ">" or " ", id:upper():sub(1, 8), stateWord(u), where(u))
    at(2 + i, line, i == S.sel and colours.yellow or colours.white)
    local t = tripOf(id)
    if t and i == S.sel then at(3 + #S.order, string.format(" %s %s %s %s", t.id, t.state, t.leg, t.stop), colours.cyan) end
  end
  footer("^v pick  ENT open  Q quit")
end

local function drawUnit()
  local id = S.unit
  local u = S.units[id]
  at(1, id:upper(), colours.orange)
  local sw = stateWord(u)
  local w = term.getSize()
  term.setCursorPos(math.max(1, w - #sw + 1), 1)
  ink(colours.white)
  term.write(sw)
  rule(2)
  if u then
    at(3, "at " .. where(u), colours.white)
    at(4, string.format("batt %s  alt %s  spd %s",
      u.pkt.energy and string.format("%d%%", u.pkt.energy) or "--",
      u.pkt.y and string.format("%d", u.pkt.y) or "--", u.pkt.spd and string.format("%d", u.pkt.spd) or "--"), colours.lightGrey)
  end
  local t = tripOf(id)
  if t then
    at(6, string.format("%s  %s", t.id, t.state:upper()), colours.cyan)
    at(7, string.format("leg %s  to %s", t.leg, t.stop:upper()), colours.cyan)
  else
    at(6, "no trip", colours.lightGrey)
  end
  at(9, "N new trip   G go on", colours.white)
  at(10, "C stop/cancel H home", colours.white)
  footer("BKSP back")
end

local function drawTrip()
  at(1, "TRIP FOR " .. S.unit:upper(), colours.orange)
  rule(2)
  if #S.legs == 0 then at(3, "no legs yet", colours.lightGrey) end
  for i, l in ipairs(S.legs) do
    at(2 + i, string.format("%d %-4s %s", i, l.kind, l.name:upper()), l.kind == "via" and colours.cyan or colours.white)
  end
  local y = 3 + math.max(1, #S.legs) + 1
  at(y, "S stop   W waypoint", colours.white)
  at(y + 1, "BKSP undo   ENT send", colours.white)
  footer("Q back without sending")
end

local function drawPlace()
  local list = places()
  at(1, S.pick == "via" and "WAYPOINT OVER..." or "STOP AT...", colours.orange)
  rule(2)
  local rows = math.max(1, footTop() - 3)
  local top = math.max(1, math.min(S.psel - math.floor(rows / 2), #list - rows + 1))
  if #list == 0 then at(3, "no places yet", colours.lightGrey) end
  for i = top, math.min(#list, top + rows - 1) do
    local p = list[i]
    at(3 + i - top, string.format("%s%-12s %s", i == S.psel and ">" or " ", p.name:sub(1, 12), p.kind or "dock"),
       i == S.psel and colours.yellow or colours.white)
  end
  footer("^v  ENT pick  BKSP back")
end

local function draw()
  term.setBackgroundColour(colours.black)
  term.clear()
  if S.view == "fleet" then drawFleet()
  elseif S.view == "unit" then drawUnit()
  elseif S.view == "trip" then drawTrip()
  else drawPlace() end
end

-- -------------------------------------------------------------------- keys
local function onKey(k)
  if S.view == "fleet" then
    if k == keys.up then S.sel = math.max(1, S.sel - 1)
    elseif k == keys.down then S.sel = math.min(math.max(1, #S.order), S.sel + 1)
    elseif k == keys.enter and S.order[S.sel] then S.unit, S.view = S.order[S.sel], "unit" end
  elseif S.view == "unit" then
    if k == keys.backspace then S.view = "fleet" end
  elseif S.view == "trip" then
    if k == keys.backspace or k == keys.delete then table.remove(S.legs)
    elseif k == keys.enter then
      if #S.legs == 0 then say("add a stop first", false)
      elseif S.legs[#S.legs].kind ~= "stop" then say("end the trip on a stop", false)
      else
        local parts = {}
        for _, l in ipairs(S.legs) do parts[#parts + 1] = l.kind .. ":" .. l.name end
        send(F.adminTrip(S.unit, table.concat(parts, ";"), nonce()), "trip for " .. S.unit)
        S.view = "unit"
      end
    end
  elseif S.view == "place" then
    local n = #places()
    if k == keys.up then S.psel = math.max(1, S.psel - 1)
    elseif k == keys.down then S.psel = math.min(math.max(1, n), S.psel + 1)
    elseif k == keys.enter and places()[S.psel] then
      S.legs[#S.legs + 1] = { kind = S.pick, name = places()[S.psel].name }
      S.view = "trip"
    elseif k == keys.backspace then S.view = "trip" end
  end
end

-- true to quit
local function onChar(c)
  c = tostring(c):lower()
  if S.view == "fleet" then return c == "q" end
  if S.view == "unit" then
    if c == "n" then S.legs, S.view = {}, "trip"
    elseif c == "g" then send(F.adminCmd("go", S.unit, nonce()), S.unit .. " go on")
    elseif c == "c" then send(F.adminCmd("cancel", S.unit, nonce()), S.unit .. " cancel")
    elseif c == "h" then send(F.adminTrip(S.unit, "stop:home", nonce()), S.unit .. " home") end
  elseif S.view == "trip" then
    if c == "s" or c == "w" then
      if #places() == 0 then say("no places from the base yet", false)
      else S.pick, S.psel, S.view = (c == "s") and "stop" or "via", 1, "place" end
    elseif c == "q" then S.view = "unit" end
  end
  return false
end

draw()
local tick = os.startTimer(0.5)
while true do
  local ev, a, b, c, d = os.pullEvent()
  if ev == "modem_message" then
    onMessage(b, d)
  elseif ev == "key" then
    onKey(a)
    draw()
  elseif ev == "char" then
    if onChar(a) then break end
    draw()
  elseif ev == "timer" and a == tick then
    tick = os.startTimer(0.5)
    draw()
  end
end
term.setBackgroundColour(colours.black)
term.clear()
term.setCursorPos(1, 1)
