-- nav: CINDER NAV, the unit on a vehicle (AVIONICS.md). An advanced computer
-- with one screen and an ender modem, supplied and registered by CINDER.
--
-- It reads where the vehicle is from Sable (CC: Sable's sublevel API), shows
-- speed, height or depth, heading, a radar and its status on every screen
-- fitted to it, and pings the CINDER tower every few seconds, sealed with its
-- own key. The tower answers with the traffic near it, where the traffic
-- centres are, and anything the driver should know. A touch on SOS, then
-- another, tells CINDER it is in distress.
--
-- Screens: every advanced monitor attached (beside it, or on a wired modem)
-- shows one page, and a touch anywhere but SOS moves it to the next. Each
-- keeps its own page, saved in .navpages, so one screen can cycle through
-- everything or four can be speed, height, radar and status for good. A new
-- screen starts on the next page along from the ones before it. Monitors
-- placed side by side merge into one; separate screens need a gap.
--
-- It is a consumer device. startup.lua with role nav is its startup: every
-- boot it pulls only these files from the repo, quietly behind the CINDER NAV
-- boot screen, then runs this with no shell (Ctrl+T does nothing). No token,
-- nothing that pushes; a new key or registration comes from the tower's
-- drive (tower register). It takes no orders:
-- nothing in it touches a thruster, a redstone output or anything else on the
-- vehicle, and nothing the tower sends can.
--
--   .nav      who it is: unit id, registration number, callsign, type, owner
--   .navkey   its key (only ever speaks for this unit)
--   .navpages which page each screen shows

local N = dofile("lib/nav.lua")
local UI = dofile("lib/navui.lua")
local D = dofile("lib/display.lua")
local T = dofile("lib/tui.lua")
local SEC = dofile("lib/seclink.lua")
local unpack_ = table.unpack or unpack

local function readAll(p)
  if not fs.exists(p) then return nil end
  local h = fs.open(p, "r")
  if not h then return nil end
  local s = h.readAll()
  h.close()
  return s
end

local me = N.parseUnitFile(readAll(".nav"))
local key = me and SEC.readKeyFile(".navkey")
local view = { me = { reg = me and N.regNumber(me.n) or "", call = me and me.call or "", kind = me and me.kind or "air" },
               link = "search", traffic = {}, craft = false, unregistered = not (me and key) }

-- ------------------------------------------------------------------ devices --
-- every monitor, each with its own page, and the first wireless (ender)
-- modem; looked for again whenever one goes missing or another is fitted
local PAGES_FILE = ".navpages"
local TAUGHT_FILE = ".navtaught"      -- screens touched at least once: they stop saying TOUCH
local dev = { mons = {}, radio = nil }
local saved = {}
for name, page in (readAll(PAGES_FILE) or ""):gmatch("([^=\n]+)=([%w]+)") do saved[name] = page end
local taught = {}
for name in (readAll(TAUGHT_FILE) or ""):gmatch("[^\n]+") do taught[name] = true end
local function saveTaught()
  local lines = {}
  for name in pairs(taught) do lines[#lines + 1] = name end
  table.sort(lines)
  local h = fs.open(TAUGHT_FILE, "w")
  if h then h.write(table.concat(lines, "\n") .. "\n") h.close() end
end
local function savePages()
  local lines = {}
  for name, m in pairs(dev.mons) do lines[#lines + 1] = name .. "=" .. m.page end
  table.sort(lines)
  local h = fs.open(PAGES_FILE, "w")
  if h then h.write(table.concat(lines, "\n") .. "\n") h.close() end
end
local function monCount() local n = 0 for _ in pairs(dev.mons) do n = n + 1 end return n end
local function findDevices()
  for name in pairs(dev.mons) do
    if not peripheral.isPresent(name) then dev.mons[name] = nil end
  end
  if dev.radio and not peripheral.isPresent(dev.radio) then dev.radio = nil end
  for _, n in ipairs(peripheral.getNames()) do
    local ty = peripheral.getType(n)
    if ty == "monitor" and not dev.mons[n] then
      pcall(peripheral.call, n, "setTextScale", 0.5)
      T.apply({ setPaletteColour = function(...) return peripheral.call(n, "setPaletteColour", ...) end })
      local okS, w = pcall(peripheral.call, n, "getSize")
      w = okS and w or 15
      local list = UI.pages(view.me.kind, w)
      local page = saved[n]
      local known = false
      for _, p in ipairs(list) do if p == page then known = true end end
      if not known then page = list[monCount() % #list + 1] end
      local okC, colour = pcall(peripheral.call, n, "isColour")
      dev.mons[n] = { page = page, hit = {}, touch = okC and colour or false }
    elseif not dev.radio and ty == "modem" then
      local okW, wireless = pcall(peripheral.call, n, "isWireless")
      if okW and wireless then
        dev.radio = n
        pcall(peripheral.call, n, "open", N.CHANNEL)
      end
    end
  end
end

-- the computer's own screen: who it is and what is fitted, for whoever opens it
local function status()
  if not term or not term.clear then return end
  term.clear()
  local lines = {
    "CINDER NAV",
    me and string.format("%s  %s  %s", N.regNumber(me.n), me.call, N.TYPES[me.kind].word) or "UNREGISTERED - TAKE THIS UNIT TO CINDER",
    "",
    "screens: " .. (monCount() > 0 and (tostring(monCount()) .. (view.noTouch and
      " - none can be touched: SOS needs an ADVANCED monitor" or "")) or "NONE - put an advanced monitor against this computer"),
    "radio:  " .. (dev.radio or "NONE - put an ender modem on this computer"),
    "tower:  " .. (({ contact = "in contact", none = "no contact - CINDER may be down", search = "calling" })[view.link] or "?"),
    "craft:  " .. (view.craft and "on a vehicle" or "NOT on a vehicle - place this computer on your craft"),
    "",
    "Touch a screen for its next page. Two touches on SOS call CINDER.",
    "",
    "This unit reports its position to CINDER.",
  }
  for i, l in ipairs(lines) do
    if term.setCursorPos then term.setCursorPos(1, i) end
    if term.write then term.write(l) end
  end
end

local centres = {}          -- where the traffic centres are, from the last pong
local function redraw()
  view.centres = N.centresFrom(view.r, centres)
  -- what the setup page and the computer's own screen tell the owner to fix
  view.noRadio = dev.radio == nil
  local anyTouch = false
  for _, m in pairs(dev.mons) do if m.touch then anyTouch = true end end
  view.noTouch = monCount() > 0 and not anyTouch
  for name, m in pairs(dev.mons) do
    local okS, w, h = pcall(peripheral.call, name, "getSize")
    if okS and w then
      if not m.canvas or m.canvas.w ~= w or m.canvas.h ~= h then m.canvas = D.canvas(w, h) end
      local c = m.canvas
      c:clear()
      local okR, hit = pcall(UI.render, T, c, view, m.page, { hint = m.touch and not taught[name] })
      m.hit = okR and hit or {}
      c:flush({ setCursorPos = function(x, y) peripheral.call(name, "setCursorPos", x, y) end,
                blit = function(s, f, b) peripheral.call(name, "blit", s, f, b) end })
    end
  end
  status()
end

-- -------------------------------------------------------------- the vehicle --
local craft = nil            -- Sable's id, name and mass for the vehicle, read now and then
local craftAt = -1e9
local gpsPrev = nil
-- which way is forward on this craft, learned as it moves (lib/nav.lua)
local NOSE_FILE = ".navnose"
local nose = N.noseState(((readAll(NOSE_FILE) or ""):match("[%+%-][xz]")))

local function sense()
  local pose, vel
  if sublevel then
    parallel.waitForAll(
      function() local ok, r = pcall(sublevel.getLogicalPose) if ok then pose = r end end,
      function() local ok, r = pcall(sublevel.getLinearVelocity) if ok then vel = r end end)
  end
  if type(pose) == "table" and type(pose.position) == "table" then
    view.craft = true
    if os.clock() - craftAt > 60 then
      craftAt = os.clock()
      local c = {}
      parallel.waitForAll(
        function() local ok, r = pcall(sublevel.getUniqueId) if ok then c.id = r end end,
        function() local ok, r = pcall(sublevel.getName) if ok then c.name = r end end,
        function() local ok, r = pcall(sublevel.getMass) if ok then c.mass = r end end)
      craft = c
    end
    local r = N.reading(pose.position, type(vel) == "table" and vel or nil, view.r)
    -- pitch and roll: from Sable's orientation, once the nose is known
    local q = N.quat(pose.orientation)
    local was = nose.nose
    local nz = N.noseVote(nose, q, vel)
    if nz and nz ~= was then
      local h = fs.open(NOSE_FILE, "w")
      if h then h.write(nz .. "\n") h.close() end
    end
    if q and nz then r.pitch, r.roll = N.attitude(q, nz) end
    view.att = not q and "none" or nz and "ok" or "learning"
    return r
  end
  -- not on a vehicle: GPS, if the server has one, with its velocity differenced
  view.craft = false
  view.att = "none"
  if gps and gps.locate then
    local x, y, z = gps.locate(0.5)
    if x then
      local now = os.clock()
      local v = { x = 0, y = 0, z = 0 }
      if gpsPrev and now > gpsPrev.t then
        local dt = now - gpsPrev.t
        v = { x = (x - gpsPrev.x) / dt, y = (y - gpsPrev.y) / dt, z = (z - gpsPrev.z) / dt }
      end
      gpsPrev = { x = x, y = y, z = z, t = now }
      return N.reading({ x = x, y = y, z = z }, v, view.r)
    end
  end
  return nil
end

-- ----------------------------------------------------------------- the link --
local tx = (me and key) and SEC.sender(key, me.unit, SEC.DIR.NAV_TO_TOWER, ".navkey.ctr") or nil
local rx = SEC.receiver()
local unanswered = 0

local function ping()
  if not (tx and dev.radio and view.r) then return end
  local st = (view.sos == "sent" or view.sos == "heard" or view.sos == "cancel") and "sos"
             or (view.r.moving and "move" or "park")
  local env = tx.seal(N.ping(view.r, st, craft))
  if env then
    pcall(peripheral.call, dev.radio, "transmit", N.CHANNEL, N.CHANNEL, env)
    unanswered = unanswered + 1
    if unanswered >= N.LINK_LOST and view.link ~= "none" then
      view.link, view.traffic, view.adv = "none", {}, nil
      redraw()
    end
  end
end

local function hear(msg)
  if type(msg) ~= "table" or not msg.sl then return end
  local body = rx.open(msg, function(id) return me and id == me.unit and key or nil end,
                       SEC.DIR.TOWER_TO_NAV, N.MAX_AGE_MS)
  local p = body and N.parsePong(body)
  if not p then return end
  unanswered = 0
  view.link, view.traffic, view.adv, view.msg = "contact", p.traffic, p.adv, p.msg
  if #p.centres > 0 then centres = p.centres end
  if p.sos and view.sos == "sent" then view.sos = "heard" end
  redraw()
end

-- ----------------------------------------------------------------- distress --
-- one touch arms the key for a few seconds, a second sends. Once sent, the
-- same: one touch asks, a second takes it back.
local SOS_ARM = 5
local armedAt = nil
local function touched(name, x, y)
  local m = dev.mons[name]
  if not m then return end
  if not taught[name] then taught[name] = true saveTaught() end
  if not UI.onSos(m.hit, x, y) then
    -- anywhere else on the screen: its next page, kept
    local okS, w = pcall(peripheral.call, name, "getSize")
    m.page = UI.nextPage(view.me.kind, okS and w or 15, m.page)
    savePages()
    redraw()
    return
  end
  local now = os.clock()
  local s = view.sos
  if s == nil then view.sos, armedAt = "armed", now
  elseif s == "armed" then view.sos, armedAt = "sent", nil os.queueEvent("nav_ping")
  elseif s == "sent" or s == "heard" then view.sos, armedAt = "cancel", now
  elseif s == "cancel" then view.sos, armedAt = nil, nil os.queueEvent("nav_ping") end
  redraw()
end
local function disarm()
  if armedAt and os.clock() - armedAt > SOS_ARM then
    if view.sos == "armed" then view.sos = nil elseif view.sos == "cancel" then view.sos = "sent" end
    armedAt = nil
    redraw()
  end
end

-- -------------------------------------------------------------------- loops --
findDevices()
redraw()

if view.unregistered then
  -- nothing to do but say so, for as long as it is switched on
  while true do
    sleep(30)
    findDevices()
    redraw()
  end
end

local function senseLoop()
  local n = 0
  while true do
    local r = sense()
    if r then view.r = r end
    disarm()
    n = n + 1
    if n % 10 == 0 then findDevices() end
    redraw()
    sleep(0.5)
  end
end

local function pingLoop()
  while true do
    ping()
    local wait = (view.r and not view.r.moving and not view.sos) and N.PING_PARKED or N.PING_MOVING
    local timer = os.startTimer(wait)
    while true do
      local e, p = os.pullEvent()
      if (e == "timer" and p == timer) or e == "nav_ping" then break end
    end
  end
end

local function radioLoop()
  while true do
    local _, _, ch, _, msg = os.pullEvent("modem_message")
    if ch == N.CHANNEL then hear(msg) end
  end
end

local function touchLoop()
  while true do
    local _, side, x, y = os.pullEvent("monitor_touch")
    touched(side, x, y)
  end
end

parallel.waitForAny(senseLoop, pingLoop, radioLoop, touchLoop)
