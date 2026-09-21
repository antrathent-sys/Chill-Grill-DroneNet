-- hail: the customer's terminal, in their pocket. It calls a shuttle to
-- wherever they are standing and flies them where they ask.
--
--   hail               serve customers: pick a place, a drone comes
--   hail 1200 340      one ride, straight to those coordinates
--   hail stats         what this terminal has been used for
--   hail test          ask the base if it can hear this terminal
--
-- While a shuttle is coming it shows a boxed terminal dashboard: the unit, the
-- status, the range with a bar and an ETA, and the job printing itself into a
-- log panel. Positions come from ops once a second (it can see the sealed
-- telemetry; a customer cannot), so the range steps rather than glides.
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
-- decides whether to send anyone and the flight command it sends the drone is
-- sealed with that drone's key. Nothing here can re-route a drone in the air.
--
-- A terminal issued to a customer carries its own key in .custkey (made with
-- `seckey cust new <name>` at the base). Requests from it are SEALED with that
-- key, so the base knows which customer is calling, can bill them, and can
-- turn one terminal off without touching the others. Without a key a terminal
-- still works if the base is set to take open hails, and then it is simply
-- anonymous. The key only ever proves who is ASKING - it cannot command a
-- drone, which is what keeps handing these out safe.
--
-- Each terminal counts its own use - rides, asks, failures, blocks flown - in
-- .hailstats, and reports it to ops after every ride.
--
-- Money: the base keeps the account, not this terminal. It shows the balance
-- the base last told it, and T tops up - the customer says how much, walks to
-- a depositor and pays it, and the base credits them when the coins go in. A
-- balance may go negative, and a ride to the base is always free, so nobody
-- can be stranded by an empty account.

local F = dofile("lib/fleet.lua")
local SEC = dofile("lib/seclink.lua")
local D, T, UI              -- canvas, the shared terminal look, the screens
do
  local okD, mod = pcall(dofile, "lib/display.lua")
  if okD and type(mod) == "table" and mod.canvas then D = mod end
  local okT, t = pcall(dofile, "lib/tui.lua")
  if okT and type(t) == "table" and t.box then T = t end
  local okM, m = pcall(dofile, "lib/hailui.lua")
  if okM and type(m) == "table" and m.ride then UI = m end
end
if T then T.apply(term) end

local args = { ... }
local sub = (args[1] or ""):lower()
-- `hail kiosk` is how a customer's pass runs it (kiosk.lua writes nothing
-- else): straight to the places list and round again after every ride, with
-- no way back to the shell and none of the operator's words.
local KIOSK = (sub == "kiosk")
if KIOSK then args, sub = {}, "" end
local STATS, PLACES = ".hailstats", "places.lua"

local me = (os.getComputerLabel and os.getComputerLabel()) or ("hail-" .. tostring(os.getComputerID()))
local stats = F.loadStats(STATS, fs, me)

-- this terminal's own key, if it was issued one
local custKey = SEC.readKeyFile(".custkey")
local sealer = custKey and SEC.sender(custKey, me, SEC.DIR.DRONE_TO_BASE, ".custkey.ctr")

if sub == "stats" then
  print(F.statsText(stats))
  return
end


local seq = 0
local function nonce()
  seq = seq + 1
  return F.nonce(me, tostring(os.epoch and os.epoch("utc") or os.clock()) .. "." .. seq)
end

-- Everything this terminal says goes out through here: sealed when it has a
-- key, plain when it does not, so the rest of the program never has to care.
local function say(msg)
  if sealer then
    local ok, env = pcall(sealer.seal, msg)
    if ok and env then return pcall(rednet.broadcast, env, F.PROTO) end
  end
  return pcall(rednet.broadcast, msg, F.PROTO)
end

local function save()
  pcall(F.saveStats, STATS, stats, fs)
  say(F.statsMessage(stats, nonce()))
end

-- ------------------------------------------------------------------ paint ---
-- The text screens use the same kit as the drawn ones: lib/tui.lua recolours
-- these slots, so AMBER is the light grey body text, DIM the quieter grey,
-- INK the dark red that marks the thing to act on. A pocket screen is 26x20,
-- so every line is cut to fit and nothing wraps.
local W, H = term.getSize()
local AMBER = colours and colours.white or 1
local DIM = colours and colours.brown or 4096
local PAPER = colours and colours.black or 32768
local INK = colours and colours.red or 16384

-- One canvas for the list and the till, one for the ride, made on first use
-- and dropped whenever a text screen has drawn over them (a canvas only
-- writes the rows it thinks have changed). nil when the kit is missing, and
-- then every caller falls back to text.
local canvas, rideCanvas
local function screen()
  if not (D and T and UI) then return nil end
  if not canvas then canvas = D.canvas(W, H) end
  return canvas
end

local function drawRide(view)
  if not (D and T and UI) then return false end
  if not rideCanvas then rideCanvas = D.canvas(W, H) end
  UI.ride(T, rideCanvas, view)
  rideCanvas:flush(term)
  return true
end

local colour = term.isColour and term.isColour()
local function fg(c) if colour then term.setTextColour(c) end end
local function bg(c) if colour then term.setBackgroundColour(c) end end

local function at(x, y, s, c)
  if y < 1 or y > H then return end
  term.setCursorPos(x, y)
  fg(c or AMBER)
  term.write(tostring(s):upper():sub(1, W - x + 1))   -- capitals, like the drawn screens
end

-- a labelled line: the label quiet, the value in the body colour
local function field(y, label, value, ink)
  at(1, y, string.rep(" ", W))
  at(1, y, label, DIM)
  at(11, y, value, ink or AMBER)
end

local function rule(y, c)
  if y < 1 or y > H then return end
  term.setCursorPos(1, y)
  fg(c or DIM)
  term.write(string.rep("-", W))
end

-- A text screen: the masthead in the block font, a title, a quieter note
-- under it, and the key bar along the bottom - the same pieces, in the same
-- places, as the drawn screens. Content goes on from row 6.
local function frame(title, note, keyBar)
  bg(PAPER)
  term.clear()
  canvas, rideCanvas = nil, nil       -- this clear just made both of them wrong
  if D and T and UI then
    local c = D.canvas(W, H)
    UI.header(T, c)
    if title then T.band(c, 3, title, nil, T.C.text) end
    if note and note ~= "" then c:text(2, 4, tostring(note):upper():sub(1, W - 2), T.C.faint) end
    if keyBar then T.keys(c, H, keyBar) end
    c:flush(term)
  else
    at(1, 1, "CINDER TRANSIT", AMBER)
    rule(2)
    if title then at(1, 3, title, AMBER) end
    if note then at(1, 4, note, DIM) end
  end
  fg(AMBER)
end

-- the scrolling slash, one character, turned by hand
local SPIN = { "|", "/", "-", "\\" }
local function spinner(y, text, n)
  at(1, y, SPIN[(n % 4) + 1], INK)
  at(3, y, text, DIM)
end

-- Drop whatever input is already queued. A command key arrives as a key
-- event and then as its character, and without this, pressing C to type
-- coordinates put a "c" at the start of the prompt.
local function flushInput()
  os.queueEvent("hail_flush")
  while true do
    local ev = os.pullEvent()
    if ev == "hail_flush" then return end
  end
end

local function ask(prompt)
  flushInput()
  fg(DIM)
  term.write(prompt)
  fg(AMBER)
  local said = read()
  return said
end

-- One fresh key press, ignoring a key still held from the screen before. On
-- a customer's pass terminate arrives as an ordinary event (kiosk.lua), even
-- to a filtered pull, so it is skipped like anything else that is not a key.
local function keyPress()
  while true do
    local ev, key, held = os.pullEvent("key")
    if ev == "key" and not held then return key end
  end
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
  if KIOSK then
    frame("NO SIGNAL", "this pass needs its modem")
  else
    print("hail: this computer has no wireless modem, so it cannot call anyone.")
    print("      Checking again every 5 s.")
  end
  sleep(5)
  radio = findRadio()
end
rednet.open(radio)


-- ----------------------------------------------------------------- places ---
local function coords(s)
  local n = {}
  for w in tostring(s or ""):gmatch("%-?%d+%.?%d*") do n[#n + 1] = tonumber(w) end
  if #n == 2 then return n[1], nil, n[2] end
  if #n >= 3 then return n[1], n[2], n[3] end
  return nil
end

-- Coordinates typed by the customer, all three, in F3's order. Height is
-- where the descent starts braking, so a guess at it is not good enough.
-- Blank goes back.
local function askXYZ(title)
  local note = "x y z, as F3 shows them"
  while true do
    frame(title, note)
    at(2, 8, "e.g. 1200 70 340", DIM)
    term.setCursorPos(2, 6)
    local s = ask("> ")
    if s == "" then return nil end
    local x, y, z = coords(s)
    if x and y and z then return math.floor(x), math.floor(y), math.floor(z) end
    note = "need all three: x y z"
  end
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
          out[#out + 1] = { name = tostring(p.name), x = tonumber(p.x), z = tonumber(p.z), y = tonumber(p.y),
                            own = true }
        end
      end
    end
    return out
  end
  for line in text:gmatch("[^\r\n]+") do
    local name, x, z = line:match("^%s*([%w_%- ]-)%s+(-?%d+)%s+(-?%d+)%s*$")
    if name and name ~= "" then out[#out + 1] = { name = name, x = tonumber(x), z = tonumber(z), own = true } end
  end
  return out
end

local places = localPlaces()
local balance                    -- what the base last said, or nil if unknown
local lastFare, lastUnit         -- what the last ride cost, and which unit flew it

-- What the base thinks this customer is worth. Cheap, so it is asked for
-- whenever the main screen is about to be drawn.
local function askBalance(secs)
  say(F.accountAsk(nonce()))
  local t0 = os.clock()
  while os.clock() - t0 < (secs or 1) do
    local _, msg = rednet.receive(F.PROTO, (secs or 1) - (os.clock() - t0))
    if type(msg) == "table" and msg.type == "account.info" and (F.check(msg)) then
      balance = msg.balance
      if msg.fare then lastFare = msg.fare end
      return balance
    end
  end
  return balance
end

-- Ask the base about a ride before anything is promised: what it will cost
-- (its own tariff, the same sum it charges at the end) and whether a free
-- unit is already on station near the customer. Returns the answer, or nil
-- when nothing comes back in time.
local function askQuote(from, tx, tz, name)
  local ask = F.fareAsk(from, { x = tx, z = tz, name = name }, nonce())
  say(ask)
  local t0 = os.clock()
  while os.clock() - t0 < 1.5 do
    local _, msg = rednet.receive(F.PROTO, 1.5 - (os.clock() - t0))
    if type(msg) == "table" and msg.type == "fare.quote" and msg.re == ask.nonce and (F.check(msg)) then
      return msg
    end
  end
  return nil
end

local function money(spurs)
  if spurs == 0 then return "no charge" end
  return UI and UI.money(spurs) or (tostring(spurs) .. " spur")
end

-- Ask ops for its pads and fold them in. Whatever has arrived by the deadline
-- is what the menu shows: a customer never waits on the base.
local function refreshPlaces(secs)
  say(F.placesAsk(nonce()))
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
  local px, py, pz = askXYZ("POSITION UNKNOWN")
  if not px then return nil end
  return { x = px, y = py, z = pz }
end

local function dist(a, bx, bz) return math.sqrt((bx - a.x) ^ 2 + (bz - a.z) ^ 2) end

-- Coordinates as F3 shows them. Every screen of an order shows them.
local function xyz(x, y, z)
  if not (x and z) then return "unknown" end
  return y and string.format("%d %d %d", math.floor(x), math.floor(y), math.floor(z))
            or string.format("%d %d", math.floor(x), math.floor(z))
end

-- Putting money on the account: pick an amount, then pay a depositor. The
-- base arms itself for THIS customer when we say so, because a depositor
-- cannot tell it who paid - it only reports that someone did.
local AMOUNTS = { [keys.one] = 64, [keys.two] = 512, [keys.three] = 4096 }
local function topUp()
  local c = screen()
  if not c then return end
  local view = { who = me, balance = balance, state = "choose", spin = 0 }

  -- While an amount is chosen, say where we are standing, a few seconds
  -- apart. That is how the pay pad knows whose account to credit - it never
  -- has to learn which PLAYER paid, only which terminal is on the spot.
  -- It runs beside the screen, not inside it: gps.locate throws away every
  -- event it is not waiting for, and in the screen's own loop that included
  -- the Q meant to leave the page.
  local function reportHere()
    while true do
      if view.state == "waiting" or view.state == "ready" then
        local x, y, z = gps.locate(2)
        if x then say(F.here(x, y, z, nonce(), view.amount)) end
        sleep(3)
      else
        sleep(0.5)
      end
    end
  end

  local function screenLoop()
    while true do
      UI.topup(T, c, view)
      c:flush(term)
      local timer = os.startTimer(1)
      local ev = { os.pullEvent() }
      if ev[1] ~= "timer" then pcall(os.cancelTimer, timer) end
      view.spin = (view.spin or 0) + 1
      if ev[1] == "key" then
        local key = ev[2]
        if key == keys.q then return end
        if view.state == "choose" and AMOUNTS[key] then
          view.amount, view.state = AMOUNTS[key], "waiting"
          say(F.creditArm(view.amount, nonce()))
          view.since = os.clock()
        end
      elseif ev[1] == "rednet_message" then
        local msg = ev[3]
        if type(msg) == "table" and (F.check(msg)) then
          if msg.type == "till.open" then
            view.state, view.amount = "ready", msg.amount
          elseif msg.type == "credit.ok" then
            balance, view.balance = msg.balance, msg.balance
            view.got, view.state = msg.amount, "done"
          elseif msg.type == "account.info" then
            balance, view.balance = msg.balance, msg.balance
          end
        end
      end
    end
  end

  parallel.waitForAny(screenLoop, reportHere)
end

-- The menu: the places list, driven by the arrow keys. Returns x, y, z, name,
-- or nil if they backed out. Falling back to a typed prompt when the screen
-- kit is missing means a pocket with no lib/display.lua still works.
-- ------------------------------------------------------- your places ---
-- A customer's own destinations, saved on the pass in places.lua. They sit
-- above the base's on the list, only this pass has them, and provisioning
-- keeps the file through every update.
local NAME_MAX = 12

local function saveOwnPlaces()
  local out = { "-- places saved on this pass: the customer's own, not the base's", "return {" }
  for _, p in ipairs(places) do
    if p.own then
      out[#out + 1] = string.format("  { name = %q, x = %d, y = %d, z = %d },",
        p.name, math.floor(p.x), math.floor(p.y or 64), math.floor(p.z))
    end
  end
  out[#out + 1] = "}"
  local h = fs.open(PLACES, "w")
  if not h then return false end
  h.write(table.concat(out, "\n") .. "\n")
  h.close()
  return true
end

local function placeNamed(name)
  for _, p in ipairs(places) do
    if tostring(p.name):lower() == tostring(name):lower() then return p end
  end
  return nil
end

-- Save a position as one of the customer's own places. Asks for a short name;
-- blank goes back. Returns the saved place, or nil.
local function savePlace(pos, title)
  local note = "name it, " .. NAME_MAX .. " letters max"
  while true do
    frame(title or "SAVE PLACE", note)
    field(6, "position", xyz(pos.x, pos.y, pos.z))
    at(2, 8, "e.g. house, farm, mine", DIM)
    term.setCursorPos(2, 10)
    local name = ask("> ")
    name = name and name:gsub("^%s+", ""):gsub("%s+$", ""):lower() or ""
    if name == "" then return nil end
    if #name > NAME_MAX or not name:match("^[%w _%-]+$") then
      note = "letters, digits, space, - or _"
    elseif placeNamed(name) then
      note = "that name is taken"
    else
      local p = { name = name, x = math.floor(pos.x), y = pos.y and math.floor(pos.y) or nil,
                  z = math.floor(pos.z), own = true }
      places[#places + 1] = p
      saveOwnPlaces()
      frame("PLACE SAVED", name)
      field(6, "position", xyz(p.x, p.y, p.z))
      at(2, 8, "it is on your list now", DIM)
      sleep(1.5)
      return p
    end
  end
end

-- Forget one of the customer's own places, after a yes.
local function deletePlace(p)
  frame("DELETE PLACE", p.name, { { "ENT", "DELETE", true }, { "ANY", "KEEP" } })
  field(6, "position", xyz(p.x, p.y, p.z))
  if keyPress() ~= keys.enter then return false end
  for k, q in ipairs(places) do
    if q == p or (q.own and q.name == p.name) then table.remove(places, k) break end
  end
  saveOwnPlaces()
  return true
end

-- The menu: the places list, driven by the arrow keys. Returns x, y, z, name,
-- or nil if they backed out. Falling back to a typed prompt when the screen
-- kit is missing means a pocket with no lib/display.lua still works.
local function chooseDestination(from)
  local c = screen()
  if not c then
    local tx, ty, tz = askXYZ("ENTER COORDINATES")
    if not tx then return nil end
    return tx, ty, tz, string.format("%d %d %d", tx, ty, tz)
  end

  -- the customer's own places first, then the base's, each nearest first
  local function build()
    local own, base = {}, {}
    for _, p in ipairs(places) do
      local e = { name = p.name, x = p.x, y = p.y, z = p.z, own = p.own, src = p, dist = dist(from, p.x, p.z) }
      if p.own then own[#own + 1] = e else base[#base + 1] = e end
    end
    local function near(a, b) return a.dist < b.dist end
    table.sort(own, near)
    table.sort(base, near)
    for _, e in ipairs(base) do own[#own + 1] = e end
    return own
  end
  local list = build()

  local sel, top, rows = 1, 1, 1
  while true do
    c = screen()
    rows, top = UI.places(T, c, { places = list, sel = sel, top = top, from = from, balance = balance })
    c:flush(term)
    local ev, key = os.pullEvent()
    if ev == "key" then
      if key == keys.down then sel = math.min(#list, sel + 1)
      elseif key == keys.up then sel = math.max(1, sel - 1)
      elseif key == keys.pageDown then sel = math.min(#list, sel + rows)
      elseif key == keys.pageUp then sel = math.max(1, sel - rows)
      elseif key == keys.enter and list[sel] then
        local p = list[sel]
        return p.x, p.y, p.z, p.name
      elseif key == keys.q and not KIOSK then
        return nil
      elseif key == keys.t then
        topUp()
        canvas = nil
      elseif key == keys.c then
        local tx, ty, tz = askXYZ("ENTER COORDINATES")
        canvas = nil                      -- the text prompt scribbled over it
        if tx then return tx, ty, tz, string.format("%d %d %d", tx, ty, tz) end
      elseif key == keys.s then
        -- where they stand now, not where they stood when the list opened
        local x, y, z = gps.locate(2)
        local pos = x and { x = x, y = y, z = z } or from
        local saved = savePlace(pos)
        canvas = nil
        list = build()
        if saved then
          for k, e in ipairs(list) do if e.src == saved then sel = k end end
        end
      elseif key == keys.d and list[sel] and list[sel].own then
        deletePlace(list[sel].src)
        canvas = nil
        list = build()
        sel = math.max(1, math.min(sel, #list))
      end
    end
  end
end

-- ------------------------------------------------------------------- ride ---
-- Follow one job to its end, drawing where the shuttle is. Returns "done",
-- "failed" or "gave up".
-- ----------------------------------------------------------- safety ---

local LZ_R = 4            -- blocks round the spot a unit needs clear: 9x9
local AT_PLATFORM = 6     -- this close to a known platform counts as on it
local WALKABLE = 250      -- a platform further than this is not worth offering

-- The nearest known landing platform (the base's places), and how far.
local function nearestPlatform(pos)
  local best, bd
  for _, p in ipairs(places) do
    local d = dist(pos, p.x, p.z)
    if not bd or d < bd then best, bd = p, d end
  end
  return best, bd
end

-- Walk to a platform, with the distance counting down. GPS runs beside the
-- screen, not in it, so no key press is lost while it listens. Returns true
-- once they are there and press ENT, false if they go back.
local function walkTo(pad)
  local d
  local function draw()
    frame("PROCEED TO PLATFORM", pad.name, { { "ENT", "ARRIVED", true }, { "ANY", "BACK" } })
    field(6, "platform", xyz(pad.x, pad.y, pad.z))
    field(7, "distance", d and string.format("%d blocks", math.floor(d)) or "locating", d and AMBER or DIM)
    if d and d <= AT_PLATFORM then
      at(2, 9, "on the platform", AMBER)
    else
      at(2, 9, "walk to it, then press ent", DIM)
    end
  end
  local result
  local function screen()
    draw()
    while true do
      local ev, key = os.pullEvent()
      if ev == "hail_where" then draw()
      elseif ev == "key" then
        if key == keys.enter then
          if d and d <= AT_PLATFORM then result = true return end
        else
          result = false return
        end
      end
    end
  end
  local function track()
    while true do
      local x, _, z = gps.locate(2)
      if x then d = dist({ x = x, z = z }, pad.x, pad.z) end
      os.queueEvent("hail_where")
      sleep(1)
    end
  end
  flushInput()
  parallel.waitForAny(screen, track)
  return result
end

-- Before a unit is called to open ground: where it will come down, what the
-- spot needs, and a platform instead if there is one. Returns the pickup -
-- where they stand, or a platform - or nil to go back.
local function landingZone(from)
  local pad, pd = nearestPlatform(from)
  if pad and pd <= AT_PLATFORM then
    -- already on a known platform: known good, nothing to check
    return { x = pad.x, y = pad.y or from.y, z = pad.z, name = pad.name }
  end
  if pad and pd > WALKABLE then pad = nil end
  local keysBar = { { "ENT", "CLEAR", true } }
  if pad then keysBar[#keysBar + 1] = { "P", "PLATFORM" } end
  keysBar[#keysBar + 1] = { "ANY", "BACK" }
  frame("LANDING ZONE", xyz(from.x, from.y, from.z), keysBar)
  at(2, 6, "the unit lands where you", AMBER)
  at(2, 7, "stand. before you call:", AMBER)
  at(2, 9, "- clear sky above", DIM)
  at(2, 10, "- level ground, 9x9", DIM)
  at(2, 11, "- no water, trees, roofs", DIM)
  at(2, 12, "- then step 5 blocks back", DIM)
  if pad then
    at(2, 14, "nearest platform", DIM)
    at(2, 15, string.format("%s  %d blocks", pad.name, math.floor(pd)), AMBER)
  end
  local key = keyPress()
  if key == keys.enter then return from end
  if key == keys.p and pad then
    if walkTo(pad) then return { x = pad.x, y = pad.y or from.y, z = pad.z, name = pad.name } end
  end
  return nil
end

-- What went wrong, in the Directorate's words, and what to do about it.
local function aborted(detail)
  frame("TRANSIT ABORTED", "")
  local d = tostring(detail or "")
  if d:find("job dropped", 1, true) then
    at(2, 6, "job dropped", INK)
    at(2, 8, "no clear spot in time,", AMBER)
    at(2, 9, "so the fare is charged", AMBER)
  elseif d:find("obstructed", 1, true) then
    at(2, 6, "landing zone obstructed", INK)
    at(2, 8, "move to open ground or a", AMBER)
    at(2, 9, "platform, then call again", AMBER)
  elseif d:find("unit down", 1, true) then
    at(2, 6, "unit down", INK)
    at(2, 8, "the operator has its", AMBER)
    at(2, 9, "position and is alerted", AMBER)
    local where = d:match("at%s+(%-?%d+%s+%-?%d+%s+%-?%d+)")
    if where then field(11, "position", where) end
  else
    at(2, 6, "the unit stopped early", INK)
    at(2, 8, d, DIM)
  end
end

-- The unit could not land where they stood and is holding above. They go
-- somewhere clear - or to a platform - and press ENT standing on it; the base
-- sends the unit there. The unit keeps the time: two minutes, then it sets
-- down, drops the job and the fare is charged. The clock here is a guide.
local RELOCATE_WAIT = 120
local function newSpot(jobId)
  local deadline = os.clock() + RELOCATE_WAIT
  local x, y, z = gps.locate(2)
  local pad, pd
  if x then pad, pd = nearestPlatform({ x = x, z = z }) end
  if pad and pd > WALKABLE then pad = nil end
  local function clockLine()
    local left = math.max(0, deadline - os.clock())
    at(2, 15, "time left", DIM)
    at(12, 15, string.format("%d:%02d", math.floor(left / 60), math.floor(left % 60)), left < 30 and INK or AMBER)
  end
  local function draw()
    local keysBar = { { "ENT", "HERE", true } }
    if pad then keysBar[#keysBar + 1] = { "P", "PLATFORM" } end
    frame("LANDING ZONE OBSTRUCTED", "unit holding above", keysBar)
    at(2, 6, "move somewhere clear:", AMBER)
    at(2, 7, "clear sky, level 9x9,", DIM)
    at(2, 8, "no water, trees, roofs.", DIM)
    at(2, 10, "stand on it, press ent", AMBER)
    if pad then
      at(2, 12, "nearest platform", DIM)
      at(2, 13, string.format("%s  %d blocks", pad.name, math.floor(pd)), AMBER)
    end
    clockLine()
    at(2, 16, "then the job is dropped", DIM)
    at(2, 17, "and the fare charged", DIM)
  end
  flushInput()
  draw()
  local timer = os.startTimer(1)
  while true do
    local ev, a, b = os.pullEvent()
    if ev == "timer" and a == timer then
      if os.clock() >= deadline then return nil end
      clockLine()
      timer = os.startTimer(1)
    elseif ev == "key" then
      if a == keys.enter then
        at(2, 10, "locating...           ", DIM)
        local gx, gy, gz = gps.locate(2)
        if gx then return { x = math.floor(gx), y = math.floor(gy), z = math.floor(gz) } end
        local tx, ty, tz = askXYZ("NEW SPOT")
        if tx then return { x = tx, y = ty, z = tz } end
        draw()
        timer = os.startTimer(1)
      elseif a == keys.p and pad then
        if walkTo(pad) then return { x = pad.x, y = pad.y, z = pad.z, name = pad.name } end
        draw()
        timer = os.startTimer(1)
      end
    elseif ev == "rednet_message" and type(b) == "table" and b.job == jobId
           and b.type == "job.state" and b.state == "failed" and (F.check(b)) then
      return nil, b
    end
  end
end

local function follow(job, from, name, route)
  route = route or {}
  local pickup = route.pickup or from
  local dest = route.to
  local aboard, state, drone, away = route.board and true or false, "calling", nil, nil
  local n, t0 = 0, os.clock()
  local here, showLog = nil, false
  local startAway, eta, lastAway, lastAt = nil, nil, nil, nil
  local zone                           -- how far the customer is from the pickup spot
  local log = {}
  local function note(line)
    log[#log + 1] = string.format("%s %s", textutils.formatTime(os.time(), true), line)
    while #log > 6 do table.remove(log, 1) end
  end
  note(route.board and "unit on station nearby" or "unit requested")
  rideCanvas = nil                    -- a fresh canvas per ride
  local result

  local function loop()
  while true do
    if os.clock() - t0 > (aboard and 600 or 300) then result = "gave up" return end
    if not drawRide({ away = away, state = state, unit = drone, spin = n,
                      start = startAway, eta = eta, log = log, showLog = showLog,
                      from = pickup, to = dest, zone = (state ~= "riding") and zone or nil,
                      board = route.board, zoneR = LZ_R }) then
      frame("TRANSIT: " .. tostring(name):upper(),
            drone and ("unit " .. (UI and UI.unitName(drone) or drone)) or "assigning a unit")
      at(1, 6, state == "enroute" and "unit inbound"
            or state == "waiting" and "on station - board now"
            or state == "riding" and "in transit"
            or "requesting unit", INK)
      at(1, 7, "from " .. xyz(pickup.x, pickup.y, pickup.z), DIM)
      if dest then at(1, 8, "to   " .. xyz(dest.x, dest.y, dest.z), DIM) end
      if state == "waiting" then at(1, 10, "PRESS  G  TO DEPART", INK) end
      at(1, H - 1, "Q aborts", DIM)
      spinner(H, state:upper(), n)
    end
    n = n + 1

    local timer = os.startTimer(0.25)
    local ev = { os.pullEvent() }
    if ev[1] == "rednet_message" then
      local msg = ev[3]
      if type(msg) == "table" and msg.job == job and (F.check(msg)) then
        if msg.type == "job.track" then
          -- range to wherever the unit is going now: the pickup, then the
          -- destination
          local target = (state == "riding" and dest) or pickup
          drone, away = msg.drone or drone, dist(target, msg.x, msg.z)
          here = { x = msg.x, z = msg.z }
          -- how fast the gap is closing, so the screen can say how long is
          -- left. Smoothed, because one slow tick should not swing the number.
          startAway = startAway or away
          if lastAway and lastAt and os.clock() > lastAt then
            local closing = (lastAway - away) / (os.clock() - lastAt)
            if closing > 1 then
              local guess = away / closing
              eta = eta and (eta * 0.6 + guess * 0.4) or guess
            end
          end
          lastAway, lastAt = away, os.clock()
        elseif msg.type == "job.state" then
          state, drone = msg.state, msg.drone or drone
          lastUnit = drone
          note((UI and UI.WORDS[msg.state] or msg.state) ..
               (msg.detail and (" - " .. tostring(msg.detail)) or ""))
          if msg.state == "riding" or msg.state == "enroute" then
            startAway, eta, lastAway, lastAt = nil, nil, nil, nil   -- new leg, new gauge
          end
          if msg.state == "waiting" then aboard = true end
          if msg.state == "relocate" then
            local spot, failure = newSpot(job)
            rideCanvas = nil
            if spot then
              say(F.relocate(job, spot.x, spot.y, spot.z, nonce(), spot.name))
              pickup, zone = spot, nil
              note("new spot " .. xyz(spot.x, spot.y, spot.z))
            elseif failure then
              aborted(failure.detail)
              sleep(5)
              result = "failed"
              return
            end
            -- no spot and no word: the unit keeps the time and will say
          end
          if msg.state == "done" then result = "done" return end
          if msg.state == "failed" then
            aborted(msg.detail)
            sleep(5)
            result = "failed"
            return
          end
        end
      end
    elseif ev[1] == "char" then
      local ch = tostring(ev[2]):lower()
      if ch == "l" then
        showLog = not showLog
      elseif ch == "g" and aboard then
        say(F.go(job, nonce()))
        state = "riding"
      elseif ch == "q" then
        result = "gave up"
        return
      end
    end
    if ev[1] ~= "timer" then pcall(os.cancelTimer, timer) end
  end
  end

  -- Where the customer is against the pickup spot, every couple of seconds,
  -- beside the screen (gps.locate would eat key presses inside it). The ride
  -- screen warns them while they are inside the landing zone.
  local function watchZone()
    while true do
      if state ~= "riding" and state ~= "done" then
        local x, _, z = gps.locate(1)
        if x then zone = dist({ x = x, z = z }, pickup.x, pickup.z) end
      end
      sleep(2)
    end
  end

  parallel.waitForAny(loop, watchZone)
  return result
end

-- one ride, start to finish
local function oneRide(tx, ty, tz, name)
  local from = whereAmI()
  if not from then return end
  if not tx then
    tx, ty, tz, name = chooseDestination(from)
    if not tx then return end
  end
  name = name or xyz(tx, ty, tz)
  local to = { x = tx, y = ty, z = tz }

  -- First ask the base: the fare, and whether a unit is already on station
  -- nearby. If one is, there is no landing to arrange - they walk to it.
  frame("CHECKING", name)
  at(2, 6, "consulting the directorate", DIM)
  local quote = askQuote(from, tx, tz, name)
  local near = quote and quote.near
  local pickup = from
  if not near then
    pickup = landingZone(from)
    if not pickup then return end
    if pickup.name then quote = askQuote(pickup, tx, tz, name) or quote end
  end

  -- The price before the promise, and where from and to, in coordinates.
  lastFare, lastUnit = nil, nil
  frame("CONFIRM", name, { { "ENT", "REQUEST", true }, { "ANY", "BACK" } })
  if near then
    local unitAt = quote.nplace and quote.nplace:upper() or xyz(quote.nx, quote.ny, quote.nz)
    field(6, "from", "unit at " .. unitAt)
    field(7, "to", xyz(tx, ty, tz))
    field(8, "distance", string.format("%d blocks", math.floor(dist({ x = quote.nx, z = quote.nz }, tx, tz))))
  else
    field(6, "from", pickup.name and (pickup.name:upper()) or xyz(pickup.x, pickup.y, pickup.z))
    if pickup.name then at(11, 7, xyz(pickup.x, pickup.y, pickup.z), DIM) end
    field(pickup.name and 8 or 7, "to", xyz(tx, ty, tz))
    field(pickup.name and 9 or 8, "distance", string.format("%d blocks", math.floor(dist(pickup, tx, tz))))
  end
  local row = near and 9 or (pickup.name and 10 or 9)
  field(row, "fare", quote and money(quote.fare) or "unavailable", quote and AMBER or DIM)
  if balance then field(row + 1, "balance", money(balance), balance < 0 and INK or AMBER) end
  if near then
    at(2, row + 3, "unit on station nearby", AMBER)
    at(2, row + 4, "walk over, board, press g", DIM)
  end
  if keyPress() ~= keys.enter then return end

  stats.requests = (stats.requests or 0) + 1
  -- the name goes too: the base checks it against its own places, which is
  -- how a ride home is known to be free
  local req = F.request(pickup, { x = tx, z = tz, y = ty, name = name }, nonce(), me)
  say(req)

  frame("REQUESTING UNIT", name)
  field(6, "from", xyz(pickup.x, pickup.y, pickup.z))
  field(7, "to", xyz(tx, ty, tz))
  local job, t0, refused, heard, n = nil, os.clock(), nil, false, 0
  local place, wait, assigned
  while os.clock() - t0 < 15 and not job and not refused do
    spinner(H, "awaiting dispatch", n)
    n = n + 1
    local timer = os.startTimer(0.25)
    local ev = { os.pullEvent() }
    if ev[1] == "rednet_message" then
      local msg = ev[3]
      if type(msg) == "table" then heard = true end
      if type(msg) == "table" and msg.nonce == req.nonce and msg.type == "job.assign" then
        job, assigned = msg.job, msg
      elseif type(msg) == "table" and msg.type == "job.queued" then
        -- nobody free: we are in the line, and the wait screen takes over
        place, wait = msg.place, msg.wait
        break
      elseif type(msg) == "table" and msg.type == "job.ack" and msg.ok == false then
        refused = tostring(msg.why)
      end
    end
    if ev[1] ~= "timer" then pcall(os.cancelTimer, timer) end
  end

  -- waiting in the line: the same screen, saying where we stand, until a
  -- shuttle is assigned or the customer gives up
  while place and not job do
    if not drawRide({ state = "queued", place = place, eta = wait, spin = n, log = log,
                      showLog = false, away = nil, start = 1, from = pickup, to = to }) then
      frame("HOLDING", string.format("position %d, about %d:%02d", place, math.floor((wait or 0) / 60),
        math.floor((wait or 0) % 60)))
    end
    n = n + 1
    local timer = os.startTimer(0.25)
    local ev = { os.pullEvent() }
    if ev[1] ~= "timer" then pcall(os.cancelTimer, timer) end
    if ev[1] == "rednet_message" then
      local msg = ev[3]
      if type(msg) == "table" and (F.check(msg)) then
        if msg.type == "job.queued" then place, wait = msg.place, msg.wait
        elseif msg.type == "job.assign" and msg.nonce == req.nonce then job, assigned = msg.job, msg
        elseif msg.type == "job.ack" and msg.ok == false then
          refused, place = tostring(msg.why), nil
        end
      end
    elseif ev[1] == "char" and tostring(ev[2]):lower() == "q" then
      say(F.cancel(nonce()))
      place = nil
    end
  end

  if not job then
    F.record(stats, "failure")
    save()
    frame("NO UNIT", "")
    at(1, 6, refused or (heard and "no unit was dispatched" or "no response"), INK)
    if not (refused or heard) then
      if KIOSK then
        -- a customer has never heard of ops, and cannot type a command
        at(1, 8, "service suspended, or you", DIM)
        at(1, 9, "are out of range", DIM)
      else
        at(1, 8, "is ops running, and are", DIM)
        at(1, 9, "you in radio range?", DIM)
        at(1, 10, "try: hail test", DIM)
      end
    end
    sleep(6)
    return
  end

  -- the base has the last word on where the pickup is: a platform's own
  -- record, or the unit that is already standing nearby
  local board = assigned and assigned.board
  if assigned and assigned.px and assigned.pz then
    pickup = { x = assigned.px, y = assigned.py or pickup.y, z = assigned.pz, name = pickup.name }
  end
  local how = follow(job, from, name, { pickup = pickup, to = to, board = board })
  askBalance(1.5)                 -- the fare lands as the ride ends
  if how == "done" then
    F.record(stats, "ride", { at = os.epoch and math.floor(os.epoch("utc") / 1000) or os.time(),
      blocks = dist(pickup, tx, tz) })
    -- the end of the ride is the part people remember, so it says exactly
    -- what happened: which unit, from and to where, what it cost, what is left
    frame("TRANSIT COMPLETE", name)
    local fare = lastFare or (quote and quote.fare)
    if lastUnit then field(6, "unit", UI and UI.unitName(lastUnit) or lastUnit) end
    field(7, "from", xyz(pickup.x, pickup.y, pickup.z))
    field(8, "to", xyz(tx, ty, tz))
    if fare then field(9, "fare", money(fare)) end
    if balance then field(10, "balance", money(balance), balance < 0 and INK or AMBER) end
    at(1, 12, "compliance appreciated", DIM)
    -- a destination typed as coordinates can be kept for next time
    if not placeNamed(name) then
      at(2, 14, "S  save this place", AMBER)
      flushInput()
      local timer = os.startTimer(8)
      while true do
        local ev, a = os.pullEvent()
        if ev == "timer" and a == timer then break end
        if ev == "key" then
          if a == keys.s then savePlace({ x = tx, y = ty, z = tz }, "SAVE DESTINATION") end
          break
        end
      end
    end
  elseif how ~= "failed" then
    F.record(stats, "failure")
    frame("TRANSIT ABORTED", how)
  else
    F.record(stats, "failure")
  end
  save()
  sleep(3)
  refreshPlaces(0.8)
end

-- ------------------------------------------------------------------- test ---
if sub == "test" then
  say(F.ping(nonce()))
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

if KIOSK then
  -- A customer's pass: the places list is the home screen, and after every
  -- ride it comes back round. The boot screen stays up until the list is
  -- drawn, so there is no STARTING screen to read.
  refreshPlaces(2)
  askBalance(1)
  save()
  while true do
    oneRide(nil, nil, nil, nil)
    refreshPlaces(1)
    askBalance(1)
  end
end

frame("STARTING", "asking the base for places")
refreshPlaces(2)
askBalance(1)
save()

while true do
  frame("TRANSIT", string.format("%d transits from this unit", stats.rides or 0))
  at(1, 6, "ENTER  request a unit", INK)
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
