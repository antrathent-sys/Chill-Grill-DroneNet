-- Desktop tests for hail.lua on a customer's pass and for kiosk.lua around it:
-- a whole ride driven through the real program - places list, confirm, the
-- shuttle coming, G, the ride, and round to the list again - against a base
-- that answers like ops does. It exists because a refactor once deleted the
-- helper that draws the list, and nothing noticed until a pocket would have
-- crashed in a customer's hand.
local DIR = ...
local ROOT = DIR .. "/.."
local pass, fail = 0, 0
local function check(n, c, d)
  if c then pass = pass + 1 print("  ok   " .. n)
  else fail = fail + 1 print("  FAIL " .. n .. (d and ("  " .. tostring(d)) or "")) end
end

dofile(DIR .. "/cc_shim.lua")
local S = dofile(ROOT .. "/lib/seclink.lua")
S.ROOT = ROOT .. "/"
local F = dofile(ROOT .. "/lib/fleet.lua")

local KEYS = { enter = 28, up = 200, down = 208, pageUp = 201, pageDown = 209,
               q = 16, t = 20, c = 46, g = 34, l = 38, p = 25, h = 35, s = 31, d = 32, one = 2, two = 3, three = 4 }
local COLOURS = { white = 1, orange = 2, brown = 4096, black = 32768, red = 16384,
                  grey = 128, lightGrey = 256 }

-- A pocket computer and a base. inputs are the player's keys, each waiting for
-- its moment (`when`); the base answers what the pocket says.
local function world(opts)
  local w = { files = opts.files or {}, shown = {}, said = {}, inbox = {}, clock = 0,
              inputs = opts.inputs or {}, events = 0, state = "idle", rebooted = false,
              label = opts.label, queued = {}, reads = {}, depth = 0,
              gpsPos = opts.gpsPos, later = {} }
  local env = setmetatable({}, { __index = _G })
  local function show(s) if s and s ~= "" then w.shown[#w.shown + 1] = s end end

  env.print = function(...) local t = {} for i = 1, select("#", ...) do t[#t + 1] = tostring((select(i, ...))) end show(table.concat(t, " ")) end
  env.write = show
  env.keys, env.colours, env.colors = KEYS, COLOURS, COLOURS
  env.textutils = { formatTime = function() return "12:00" end }
  env.term = {
    getSize = function() return 26, 20 end, setCursorPos = function() end, getCursorPos = function() return 1, 1 end,
    write = show, blit = function(s) show(s) end, clear = function() show("<clear>") end, clearLine = function() end,
    setTextColour = function() end, setBackgroundColour = function() end, setTextColor = function() end,
    setBackgroundColor = function() end, isColour = function() return true end, isColor = function() return true end,
    setPaletteColour = function() end, setCursorBlink = function() end, scroll = function() end,
  }
  -- read() the way CC's does: characters until Enter
  env.read = function()
    local s = ""
    while true do
      local ev, a = env.os.pullEvent()
      if ev == "char" then s = s .. a
      elseif ev == "key" and a == KEYS.enter then w.reads[#w.reads + 1] = s return s end
    end
  end
  env.sleep = function(t)
    if w.depth > 0 then
      local left = t or 0
      repeat coroutine.yield("timer") left = left - 0.25 until left <= 0
    else
      w.clock = w.clock + (t or 0)
    end
  end
  -- gps.locate as CC's behaves: it pulls events until it has a fix or times
  -- out, and throws away everything else it sees - key presses included.
  -- While it is busy, only inputs marked whileGps are delivered, so a script
  -- can press a key exactly then.
  env.gps = { locate = function(timeout)
    w.gpsBusy = true
    local deadline = w.clock + (timeout or 2)
    while w.clock < deadline do env.os.pullEvent() end
    w.gpsBusy = false
    local p = w.gpsPos or { 100, 64, 200 }
    if type(p) == "function" then p = p(w) end
    return p[1], p[2], p[3]
  end }
  -- parallel.waitForAny as CC runs it: every event goes to every coroutine
  -- that is waiting for it, and the first to finish ends the lot
  env.parallel = { waitForAny = function(...)
    local cos, filters = {}, {}
    for i, f in ipairs({ ... }) do cos[i] = coroutine.create(f) end
    w.depth = w.depth + 1
    local ev, first = {}, true
    while true do
      for i, co in ipairs(cos) do
        if first or filters[i] == nil or filters[i] == ev[1] or ev[1] == "terminate" then
          local ok, want = coroutine.resume(co, (table.unpack or unpack)(ev))
          if not ok then w.depth = w.depth - 1 w.gpsBusy = false error(want, 0) end
          if coroutine.status(co) == "dead" then
            w.depth = w.depth - 1
            w.gpsBusy = false          -- whatever the others were doing is abandoned
            return i
          end
          filters[i] = want
        end
      end
      first = false
      ev = { w.nextEvent(nil) }
    end
  end }
  env.peripheral = {
    getNames = function() return opts.noradio and {} or { "back" } end,
    getType = function() return "modem" end,
    call = function(_, m) if m == "isWireless" then return true end end,
  }

  -- the base: answers exactly the questions ops answers, the way ops does
  local places = { { name = "home", x = 1892, z = 365 }, { name = "market", x = 865, z = 248 } }
  local function reply(msg, after)
    if after then w.later[#w.later + 1] = { at = w.events + after, msg = msg }
    else w.inbox[#w.inbox + 1] = msg end
  end
  env.rednet = {
    open = function() end,
    broadcast = function(msg)
      w.said[#w.said + 1] = msg
      if type(msg) ~= "table" then return end
      if msg.type == "places.ask" then reply(F.placesList(places, "p-" .. #w.said, opts.free))
      elseif msg.type == "account.ask" then reply(F.accountInfo("alex", 500, 3, "a-" .. #w.said))
      elseif msg.type == "fare.ask" then
        w.fareAsked = msg
        reply(F.fareQuote(opts.fare or 13, "flat fare", "q-" .. #w.said, msg.nonce, opts.near, opts.free))
      elseif msg.type == "taxi.request" then
        w.request = msg
        if opts.near then
          msg.board, msg.px, msg.pz, msg.py = true, opts.near.x, opts.near.z, opts.near.y
        end
        reply(F.assign("j-1", msg))
        if opts.relocate or opts.relocateTimeout then
          -- it came down on something and is holding above
          reply(F.state("j-1", "drone-1", "enroute", nil, "s-1"))
          reply(F.state("j-1", "drone-1", "relocate", "landing zone obstructed - 9 above you, holding", "s-r"), 30)
          if opts.relocateTimeout then
            reply(F.state("j-1", "drone-1", "failed", "no new spot in 2 min - job dropped, fare charged", "s-x"), 400)
          end
        elseif opts.fail then
          reply(F.state("j-1", "drone-1", "enroute", nil, "s-1"))
          reply(F.state("j-1", "drone-1", "failed", opts.fail, "s-f"))
        elseif opts.near then
          reply(F.state("j-1", "drone-1", "waiting", "on station - board here", "s-2"))
        else
          reply(F.state("j-1", "drone-1", "enroute", nil, "s-1"))
          reply(F.state("j-1", "drone-1", "waiting", nil, "s-2"), 60)   -- the flight takes a while
        end
      elseif msg.type == "job.relocate" then
        w.relocated = msg
        reply(F.state("j-1", "drone-1", "enroute", "to the new spot", "s-n"))
        reply(F.state("j-1", "drone-1", "waiting", nil, "s-w"), 40)
      elseif msg.type == "job.go" then
        w.went = true
        reply(F.state("j-1", "drone-1", "riding", nil, "s-3"))
        reply(F.state("j-1", "drone-1", "done", nil, "s-4"))
      end
    end,
    receive = function(_, timeout)
      local m = table.remove(w.inbox, 1)
      if m then
        if m.type == "job.state" then w.state = m.state end
        return 7, m, F.PROTO
      end
      w.clock = w.clock + (timeout or 1)
      return nil
    end,
  }

  local function nextEvent(filter)
    w.events = w.events + 1
    if w.events > 8000 then error("runaway: 8000 events", 0) end
    for k = #w.later, 1, -1 do                -- replies whose time has come
      if w.events >= w.later[k].at then table.insert(w.inbox, table.remove(w.later, k).msg) end
    end
    local pending = w.inputs[1]
    if w.gpsBusy and not (pending and pending.whileGps) and #w.queued == 0 then
      w.clock = w.clock + 0.25
      return "timer", 1
    end
    -- what is already in CC's queue comes first: a character that followed its
    -- key press, or an event the program queued itself
    if #w.queued > 0 then return (table.unpack or unpack)(table.remove(w.queued, 1)) end
    local typed = w.inputs[1]
    if typed and typed.line and (not typed.when or typed.when(w)) then
      table.remove(w.inputs, 1)
      local keysIn = {}
      for ch in typed.line:gmatch(".") do keysIn[#keysIn + 1] = { char = ch } end
      keysIn[#keysIn + 1] = { key = KEYS.enter }
      for i = #keysIn, 1, -1 do table.insert(w.inputs, 1, keysIn[i]) end
    end
    if filter ~= "key" and filter ~= "char" and #w.inbox > 0 then
      local m = table.remove(w.inbox, 1)
      if m.type == "job.state" then w.state = m.state end
      return "rednet_message", 7, m, F.PROTO
    end
    local nxt = w.inputs[1]
    if nxt and (not nxt.when or nxt.when(w)) then
      table.remove(w.inputs, 1)
      if nxt.terminate then return "terminate" end
      if nxt.key and nxt.char then            -- a key that types: CC queues its char next
        table.insert(w.queued, 1, { "char", nxt.char })
        return "key", nxt.key, false
      end
      if nxt.char then return "char", nxt.char end
      return "key", nxt.key, false
    end
    -- nothing left for the player to press: let time pass for a while (a
    -- shuttle that never answers takes 15 s to give up), then stop the run
    if not nxt then
      w.idle = (w.idle or 0) + 1
      if w.idle > 300 then error("script over", 0) end
    end
    w.clock = w.clock + 0.25
    return "timer", 1
  end
  w.nextEvent = nextEvent
  -- inside parallel, a pull yields to the scheduler, as CC's does
  local function pullRaw(f)
    if w.depth > 0 then return coroutine.yield(f) end
    return nextEvent(f)
  end
  env.os = setmetatable({
    clock = function() w.clock = w.clock + 0.001 return w.clock end,
    epoch = function() return 1789867493000 + math.floor(w.clock * 1000) end,
    time = function() return 12 end,
    startTimer = function() return 1 end, cancelTimer = function() end,
    queueEvent = function(...) w.queued[#w.queued + 1] = { ... } end,
    pullEvent = function(f)
      local ev = { pullRaw(f) }
      if ev[1] == "terminate" and w.rawEvents ~= true then error("Terminated", 0) end
      return (table.unpack or unpack)(ev)
    end,
    pullEventRaw = function(f) return pullRaw(f) end,
    getComputerLabel = function() return w.label end,
    setComputerLabel = function(l) w.label = l end,
    getComputerID = function() return 12 end,
    reboot = function() w.rebooted = true error("rebooted", 0) end,
  }, { __index = os })

  env.fs = {
    exists = function(p) return w.files[p] ~= nil end,
    getSize = function(p) return #(w.files[p] or "") end,
    delete = function(p) w.files[p] = nil end,
    open = function(p, mode)
      if mode == "r" then
        local s = w.files[p]
        if not s then return nil end
        local pos = 1
        return { readAll = function() return s end,
                 readLine = function()
                   if pos > #s then return nil end
                   local e = s:find("\n", pos, true)
                   local line = s:sub(pos, (e or #s + 1) - 1)
                   pos = (e or #s) + 1
                   return line
                 end,
                 close = function() end }
      end
      local buf = { mode == "a" and (w.files[p] or "") or "" }
      return { write = function(x) buf[#buf + 1] = x end, writeLine = function(x) buf[#buf + 1] = x .. "\n" end,
               close = function() w.files[p] = table.concat(buf) end }
    end,
  }
  env.dofile = function(p) return dofile(ROOT .. "/" .. p) end
  env.loadfile = function(p, _, e)
    local fn, err = loadfile(ROOT .. "/" .. p)
    if fn and e then setfenv(fn, e) end
    return fn, err
  end
  env.shell = {}
  env._G = env              -- kiosk.lua builds hail's environment on top of _G
  w.env = env
  return w
end

-- screens are set in capitals, so text is compared without regard to case
local function has(w, s) return w.text:upper():find(s:upper(), 1, true) ~= nil end

local function run(w, file, ...)
  local fn = assert(loadfile(ROOT .. "/" .. file))
  setfenv(fn, w.env)
  _G.fs = w.env.fs
  local ok, err = pcall(fn, ...)
  w.err = (not ok) and tostring(err) or nil
  w.text = table.concat(w.shown, "\n")
  return w
end

-- the player: Q (which must do nothing), down to the second place, ENTER,
-- ENTER again to confirm, then G once the shuttle is on station
local function ride()
  return {
    { key = KEYS.q },
    { key = KEYS.down },
    { key = KEYS.enter },                    -- the place
    { key = KEYS.enter },                    -- landing zone: clear
    { key = KEYS.enter },                    -- confirm
    { char = "g", when = function(w) return w.state == "waiting" end },
  }
end

print("a ride on a customer's pass")
local w = run(world({ inputs = ride() }), "hail.lua", "kiosk")
check("it ran until the player stopped pressing keys", w.err == "script over", w.err)
check("the places list drew (the canvas helper exists)", has(w, "DESTINATIONS"))
check("Q did not leave the list", w.request ~= nil)
-- the list is nearest first: market (766 blocks), then home (1799)
check("it asked for the second place on the list", w.request and w.request.toName == "home", w.request and w.request.toName)
check("from where the player stood", w.request and w.request.px == 100 and w.request.pz == 200)
check("the confirm screen asked with one key", has(w, "CONFIRM"))
check("it asked the base for the price first", w.fareAsked and w.fareAsked.toName == "home")
check("and showed it before anything was requested", has(w, "FARE") and has(w, "13 SPUR"))
check("the ride screen drew while it came", has(w, "ON STATION"))
check("G sent the shuttle off", w.went == true)
check("it arrived", has(w, "TRANSIT COMPLETE"))
check("with a receipt naming the unit by its class", has(w, "LAMBDA-1"))
check("and came round to the list again", select(2, w.text:upper():gsub("DESTINATIONS", "")) >= 2)
check("no operator words on a customer's screen",
  not has(w, "hail test") and not has(w, "ops ") and not has(w, "autorun"))
local stats = w.files[".hailstats"] or ""
check("the ride was counted on the pass", stats:find("rides", 1, true) ~= nil)

print("the landing zone")
check("before calling to open ground it shows the landing zone", has(w, "LANDING ZONE"))
check("with the checklist", has(w, "CLEAR SKY ABOVE") and has(w, "LEVEL GROUND, 9X9"))
check("and where the unit will come down", has(w, "100 64 200"))
check("the route is on the ride screen in coordinates", has(w, "FROM") and has(w, "1892 365"))
check("the receipt says from and to", has(w, "COMPLIANCE APPRECIATED") and has(w, "100 64 200"))

print("stand clear")
local close = run(world({ inputs = ride(), gpsPos = { 101, 64, 201 } }), "hail.lua", "kiosk")
check("inside the landing zone while it comes in: stand clear", has(close, "STAND CLEAR OF THE ZONE"))
local back = run(world({ inputs = ride(), gpsPos = function(w)
  return w.request and { 108, 64, 200 } or { 100, 64, 200 }
end }), "hail.lua", "kiosk")
check("standing back: zone clear", has(back, "ZONE CLEAR"))

print("a unit already on station nearby")
local nb = run(world({ near = { unit = "drone-1", x = 1890, y = 98, z = 366, place = "home" },
                       gpsPos = { 1880, 92, 360 }, inputs = {
  { key = KEYS.enter },                    -- home, the nearest place
  { key = KEYS.enter },                    -- confirm: no landing zone to check
  { char = "g", when = function(w) return w.state == "waiting" end },
} }), "hail.lua", "kiosk")
check("no landing zone to check", not has(nb, "LANDING ZONE"))
check("the places list calls the home dock CINDER HQ, not HOME", has(nb, "CINDER HQ"))
check("it says so at confirm, and the home dock is called CINDER HQ",
  has(nb, "UNIT ON STATION NEARBY") and has(nb, "UNIT AT") and has(nb, "CINDER HQ"))
check("the ride screen says walk to it", has(nb, "WALK TO UNIT"))
check("and G takes it from there", nb.went == true)

print("a pickup that could not land")
local ob = run(world({ inputs = { { key = KEYS.enter }, { key = KEYS.enter }, { key = KEYS.enter } },
                       fail = "landing zone obstructed - landed 9 blocks above you" }), "hail.lua", "kiosk")
check("it says the zone was obstructed", has(ob, "LANDING ZONE OBSTRUCTED"))
check("and what to do", has(ob, "MOVE TO OPEN GROUND OR A"))
local down = run(world({ inputs = { { key = KEYS.enter }, { key = KEYS.enter }, { key = KEYS.enter } },
                         fail = "unit down at 1500 80 300" }), "hail.lua", "kiosk")
check("a unit down says so, and that the operator knows", has(down, "UNIT DOWN") and has(down, "IS ALERTED"))

print("a unit that could not land")
local rl = run(world({ relocate = true,
  gpsPos = function(w) return w.moved and { 130, 64, 215 } or { 100, 64, 200 } end,
  inputs = {
    { key = KEYS.enter }, { key = KEYS.enter }, { key = KEYS.enter },   -- place, landing zone, confirm
    { key = KEYS.enter, when = function(w) if w.state == "relocate" then w.moved = true return true end end },
    { char = "g", when = function(w) return w.state == "waiting" end },
} }), "hail.lua", "kiosk")
check("it says the zone was obstructed and the unit is holding", has(rl, "LANDING ZONE OBSTRUCTED")
  and has(rl, "UNIT HOLDING ABOVE"))
check("with the two minutes and what happens after", has(rl, "TIME LEFT") and has(rl, "THEN THE JOB IS DROPPED"))
check("ENT sends where they stand now", rl.relocated and rl.relocated.px == 130 and rl.relocated.pz == 215,
  rl.relocated and (rl.relocated.px .. " " .. rl.relocated.pz))
check("and the ride carries on from the new spot", rl.went == true and has(rl, "130 64 215"))
local rt = run(world({ relocateTimeout = true, inputs = {
    { key = KEYS.enter }, { key = KEYS.enter }, { key = KEYS.enter },
} }), "hail.lua", "kiosk")
check("no new spot in time: dropped, and it says the fare is charged",
  has(rt, "JOB DROPPED") and has(rt, "SO THE FARE IS CHARGED"))

print("a platform in walking distance comes first")
local walk = run(world({ gpsPos = function(w) return w.walking and { 865, 70, 250 } or { 700, 64, 200 } end,
  inputs = {
  { key = KEYS.down },                     -- home is second nearest from here
  { key = KEYS.enter },
  { key = KEYS.enter },                    -- the platform it offers: market, 165 blocks
  { key = KEYS.enter, when = function(w) w.walking = true return w.events > 40 end },
  { key = KEYS.enter, when = function(w) return w.events > 80 end },   -- arrived
  { key = KEYS.enter },                    -- confirm
  { char = "g", when = function(w) return w.state == "waiting" end },
} }), "hail.lua", "kiosk")
check("it offers the platform before anything else, as a known safe landing",
  has(walk, "PLATFORM NEARBY") and has(walk, "A KNOWN SAFE LANDING") and has(walk, "MARKET"))
check("ENT takes it: it guides them to the platform", has(walk, "PROCEED TO PLATFORM"))
check("and the pickup is the platform", walk.request and walk.request.pad == "market"
  and walk.request.px == 865, walk.request and tostring(walk.request.pad))

local here = run(world({ gpsPos = { 700, 64, 200 }, inputs = {
  { key = KEYS.down }, { key = KEYS.enter },
  { key = KEYS.h, char = "h" },            -- no: where I stand
  { key = KEYS.enter },                    -- the landing zone checklist: clear
  { key = KEYS.enter },                    -- confirm
  { char = "g", when = function(w) return w.state == "waiting" end },
} }), "hail.lua", "kiosk")
check("H calls it to where they stand instead, through the checklist",
  has(here, "LANDING ZONE") and has(here, "CLEAR SKY ABOVE")
  and here.request and here.request.px == 700 and here.request.pad == nil,
  here.request and (tostring(here.request.px) .. " " .. tostring(here.request.pad)))

local own = run(world({ gpsPos = { 100, 64, 200 },
  files = { ["places.lua"] = 'return {\n  { name = "shed", x = 110, y = 64, z = 205 },\n}\n' },
  inputs = {
    { key = KEYS.down }, { key = KEYS.enter },   -- a base place, below their own
    { key = KEYS.enter },                        -- landing zone: clear
    { key = KEYS.enter },                        -- confirm
    { char = "g", when = function(w) return w.state == "waiting" end },
} }), "hail.lua", "kiosk")
check("their own saved place nearby is not offered as a platform - nobody checked it",
  not has(own, "PLATFORM NEARBY") and not has(own, "NEAREST PLATFORM") and has(own, "LANDING ZONE"))

print("how many units are free")
local fr = run(world({ inputs = ride(), free = 2 }), "hail.lua", "kiosk")
check("the list says how many units are available", has(fr, "2 UNITS AVAILABLE"))
local up = fr.text:upper()
local ci = up:find("CONFIRM", 1, true) or 1
local confirmText = up:sub(ci, up:find("REQUESTING UNIT", ci, true) or #up)
check("and so does the confirm screen", confirmText:find("2 UNITS AVAILABLE", 1, true) ~= nil and fr.request ~= nil)
local one = run(world({ inputs = ride(), free = 1 }), "hail.lua", "kiosk")
check("one is one UNIT", has(one, "1 UNIT AVAILABLE"))
local none = run(world({ inputs = ride(), free = 0 }), "hail.lua", "kiosk")
check("none free: the list says all units are committed", has(none, "ALL UNITS COMMITTED"))
check("and confirm says they will hold in line", has(none, "YOU WILL HOLD IN LINE"))
check("a base that does not say shows nothing, not a guess", not has(w, "UNITS AVAILABLE")
  and not has(w, "ALL UNITS COMMITTED"))

print("typing coordinates")
local typed = run(world({ inputs = {
  { key = KEYS.c, char = "c" },            -- C on the list: a key, then its character
  { line = "1200 340" },                   -- only two numbers
  { line = "1200 70 340" },
  { key = KEYS.enter },                    -- landing zone: clear
  { key = KEYS.enter },                    -- confirm
  { char = "g", when = function(w) return w.state == "waiting" end },
  { key = KEYS.s, char = "s", when = function(w) return w.state == "done" end },   -- the receipt's offer
  { line = "spot" },
} }), "hail.lua", "kiosk")
check("the C that opened the prompt is not typed into it", typed.reads[1] == "1200 340", typed.reads[1])
check("two numbers are not enough - it asks for all three", has(typed, "NEED ALL THREE"))
check("the ride goes to x y z as typed", typed.request and typed.request.tx == 1200
  and typed.request.ty == 70 and typed.request.tz == 340)
check("and the height goes with the fare question too", typed.fareAsked ~= nil)

print("leaving the credit page")
local credit = run(world({ inputs = {
  { key = KEYS.t, char = "t" },                      -- the credit page
  { key = KEYS.one, char = "1" },                    -- 64 spur: now it reports its position
  { key = KEYS.q, char = "q", whileGps = true },     -- Q, pressed while GPS is listening
  { key = KEYS.enter }, { key = KEYS.enter }, { key = KEYS.enter },   -- back on the list: a ride
  { char = "g", when = function(w) return w.state == "waiting" end },
} }), "hail.lua", "kiosk")
check("Q leaves the credit page even while GPS is busy", credit.request ~= nil, credit.err)

check("the receipt offers to keep a typed destination", has(typed, "SAVE THIS PLACE"))
check("and keeps it, height and all", (typed.files["places.lua"] or ""):find('name = "spot", x = 1200, y = 70, z = 340', 1, true) ~= nil,
  typed.files["places.lua"])

print("your own places")
local sv = run(world({ gpsPos = { 321, 70, -45 }, inputs = {
  { key = KEYS.s, char = "s" },            -- save where I stand
  { line = "home" },                       -- taken: the base has a home
  { line = "house" },
} }), "hail.lua", "kiosk")
check("a name the base already uses is refused", has(sv, "THAT NAME IS TAKEN"))
check("S saves where they stand, with its height", (sv.files["places.lua"] or ""):find('name = "house", x = 321, y = 70, z = -45', 1, true) ~= nil,
  sv.files["places.lua"])
check("and the C that opened it was not typed into the name", not (sv.files["places.lua"] or ""):find('"shouse"', 1, true))
check("it is listed first, under its own band", has(sv, "YOUR PLACES") and has(sv, "HOUSE"))
local del = run(world({ files = { ["places.lua"] = 'return {\n  { name = "farm", x = 150, y = 66, z = 210 },\n}\n' },
  inputs = {
    { key = KEYS.d, char = "d" },          -- farm is first and selected
    { key = KEYS.enter },                  -- yes, delete
} }), "hail.lua", "kiosk")
check("D on your own place deletes it, after a yes", has(del, "DELETE PLACE")
  and not (del.files["places.lua"] or ""):find("farm", 1, true), del.files["places.lua"])

print("nothing is called before it exists")
-- a helper deleted in a refactor (screen) and one defined below its first
-- caller (xyz) both passed a syntax check and would have crashed in a
-- customer's hand; this finds either kind before a test even runs it
local function readSrc(p) local h = io.open(ROOT .. "/" .. p, "r") local s = h:read("*a") h:close() return s end
for _, file in ipairs({ "hail.lua", "kiosk.lua" }) do
  local lines = {}
  for l in (readSrc(file) .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = l end
  local defined = {}
  for i, l in ipairs(lines) do
    local name = l:match("^local function ([%w_]+)")
    if name and not defined[name] then defined[name] = i end
  end
  local early = {}
  for name, at in pairs(defined) do
    for i = 1, at - 1 do
      local code = lines[i]:gsub("%-%-.*$", "")
      if code:find("[^%w_%.:]" .. name .. "%s*%(") or code:find("^" .. name .. "%s*%(") then
        early[#early + 1] = name .. " (line " .. i .. ", defined at " .. at .. ")"
        break
      end
    end
  end
  check(file .. ": every local function is defined above its first use", #early == 0, table.concat(early, "; "))
end

print("a terminal with no pass")
local nopass = world({ inputs = { { key = KEYS.enter }, { key = KEYS.enter }, { key = KEYS.enter } } })
local base = nopass.env.rednet.broadcast
nopass.env.rednet.broadcast = function(msg)
  if type(msg) == "table" and msg.type == "taxi.request" then
    nopass.inbox[#nopass.inbox + 1] = F.ack("j-none", "ops", false, "no pass on this terminal", "r-1")
    return
  end
  return base(msg)
end
run(nopass, "hail.lua", "kiosk")
check("it is told why, not left waiting", has(nopass, "NO PASS ON THIS TERMINAL"))

print("no shuttle answering")
local quiet = world({ inputs = { { key = KEYS.enter }, { key = KEYS.enter }, { key = KEYS.enter } } })
local answer = quiet.env.rednet.broadcast
quiet.env.rednet.broadcast = function(msg)      -- places and balance, but no shuttle
  if type(msg) == "table" and msg.type == "taxi.request" then quiet.said[#quiet.said + 1] = msg return end
  return answer(msg)
end
run(quiet, "hail.lua", "kiosk")
check("it says so in customer's words", has(quiet, "out of range"))
check("and does not tell them to type a command", not has(quiet, "hail test"))

print("the kiosk around it")
local k = world({ inputs = ride(), files = { [".pass"] = "alex\n", [".kiosk"] = "hail\n" }, label = "someone" })
k.rawEvents = true
run(k, "kiosk.lua")
check("the label comes back from .pass", k.label == "alex", k.label)
check("the boot screen shows the name and no debug",
  k.shown[1] and not has(k, "pulling") and not has(k, "role"))
check("the ride still works under it", k.went == true)
check("when it stops, the service is suspended", has(k, "SERVICE SUSPENDED"))
check("writes what happened for the base", (k.files[".crash"] or ""):find("script over", 1, true) ~= nil)
check("and starts again", k.rebooted == true)

local t = world({ inputs = { { terminate = true }, { key = KEYS.down }, { key = KEYS.enter }, { key = KEYS.enter }, { key = KEYS.enter },
                             { char = "g", when = function(w) return w.state == "waiting" end } },
                  files = { [".pass"] = "alex\n" } })
t.rawEvents = true
run(t, "kiosk.lua")
check("Ctrl+T on the list does nothing - the ride carries on", t.went == true)

local bad = world({ inputs = {}, files = { [".pass"] = "alex\n", [".kiosk"] = "shell\n" } })
bad.rawEvents = true
bad.env.loadfile = function(p, _, e)
  bad.loaded = p
  return function() error("stop here", 0) end
end
run(bad, "kiosk.lua")
check("a .kiosk naming anything else still runs hail", bad.loaded == "hail.lua", bad.loaded)

print("")
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then error("hail tests failed", 0) end
