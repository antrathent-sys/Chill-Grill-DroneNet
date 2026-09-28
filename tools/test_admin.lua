-- Desktop tests for admin.lua, the admin pocket: the fleet from the base's
-- feed, a trip built leg by leg and sent, Go, Cancel and Home - all driven
-- through the real program, with a base that opens what the pocket sends the
-- way ops does and answers on the feed.
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
local W = dofile(ROOT .. "/lib/watch.lua")
local LINK = dofile(ROOT .. "/lib/link.lua")

local KEYHEX = "3f3e3d3c3b3a393837363534333231302f2e2d2c2b2a29282726252423222120"
local KEY = S.parseKey(KEYHEX)
local OTHER = S.parseKey("0f0e0d0c0b0a09080706050403020100f0e0d0c0b0a090807060504030201000")
local KEYS = { enter = 28, up = 200, down = 208, backspace = 14, delete = 211 }
local COLOURS = setmetatable({}, { __index = function() return 1 end })

local PLACES = { { name = "home", x = 1892, y = 91, z = 365, kind = "dock" },
                 { name = "rules", x = -40, y = 70, z = 812, kind = "pad" },
                 { name = "pier", x = 300, y = 64, z = -90, kind = "dock" } }

local function tlm(id, t)
  t.v, t.type, t.id, t.seq = 1, "tlm", id, 1
  return W.wrap(t)
end

-- The pocket and the base. script: what happens, in order - {feed = body}
-- (sealed to the pocket by the base), {raw = envelope}, {key = k} or
-- {char = c}. The base opens every request and answers it on the feed.
local function world(opts)
  local w = { files = opts.files or {}, frame = {}, all = {}, asked = {}, sent = {}, clock = 0,
              script = opts.script or {}, label = opts.label == nil and "alex" or opts.label or nil }
  if opts.key ~= false then w.files[".adminkey"] = KEYHEX end
  local baseTx = S.sender(KEY, "alex", S.DIR.BASE_TO_WATCH, nil)
  local baseRx = S.receiver()
  local inbox = {}
  local function feed(body) inbox[#inbox + 1] = baseTx.seal(body) end
  w.feed = feed

  local env = setmetatable({}, { __index = _G })
  local function show(s)
    s = tostring(s)
    w.frame[#w.frame + 1] = s
    w.all[#w.all + 1] = s
  end
  env.print = function(...) local t = {} for i = 1, select("#", ...) do t[#t + 1] = tostring((select(i, ...))) end show(table.concat(t, " ")) end
  env.keys, env.colours, env.colors = KEYS, COLOURS, COLOURS
  env.term = {
    getSize = function() return 26, 20 end, setCursorPos = function() end, write = show,
    clear = function() w.frame = {} end, setTextColour = function() end, setBackgroundColour = function() end,
    isColour = function() return true end,
  }
  env.peripheral = {
    getNames = function() return opts.noradio and {} or { "back" } end,
    getType = function() return "modem" end,
    call = function(_, m, ch, _, msg)
      if m == "isWireless" then return true end
      if m == "open" then w.opened = ch end
      if m == "transmit" then
        w.sent[#w.sent + 1] = { ch = ch, env = msg }
        local body = baseRx.open(msg, function(id) return id == "alex" and KEY or nil end, S.DIR.ADMIN_TO_BASE)
        if body then
          w.asked[#w.asked + 1] = body
          local answer = opts.answer and opts.answer(body)
          if answer then feed(F.adminAck(answer[1], answer[2], body.nonce, body.drone)) end
        end
      end
    end,
  }
  env.os = setmetatable({
    clock = function() w.clock = w.clock + 0.001 return w.clock end,
    epoch = function() return 1789867493000 + math.floor(w.clock * 1000) end,
    startTimer = function() return 1 end,
    getComputerLabel = function() return w.label end,
    pullEvent = function()
      if #inbox > 0 then return "modem_message", "back", W.CHANNEL, W.CHANNEL, table.remove(inbox, 1), 5 end
      local s = table.remove(w.script, 1)
      if not s then error("script over", 0) end
      if s.feed then feed(s.feed) return "timer", 0 end
      if s.raw then return "modem_message", "back", s.ch or W.CHANNEL, W.CHANNEL, s.raw, 5 end
      if s.key then return "key", s.key, false end
      if s.char then return "char", s.char end
      w.clock = w.clock + (s.wait or 0.5)
      return "timer", 1
    end,
  }, { __index = os })
  env.fs = {
    exists = function(p) return w.files[p] ~= nil end,
    open = function(p, mode)
      if mode == "r" then
        local s = w.files[p]
        if not s then return nil end
        return { readAll = function() return s end, close = function() end }
      end
      local buf = {}
      return { write = function(x) buf[#buf + 1] = x end, close = function() w.files[p] = table.concat(buf) end }
    end,
  }
  env.dofile = function(p) return dofile(ROOT .. "/" .. p) end
  w.env = env
  return w
end

local function run(w)
  local fn = assert(loadfile(ROOT .. "/admin.lua"))
  setfenv(fn, w.env)
  _G.fs = w.env.fs
  local ok, err = pcall(fn)
  w.err = (not ok) and tostring(err) or nil
  w.text = table.concat(w.frame, "\n")
  w.everything = table.concat(w.all, "\n")
  return w
end
local function has(s, what) return s:upper():find(what:upper(), 1, true) ~= nil end

local function fleetFeed()
  return {
    { feed = tlm("drone-2", { phase = "cruise", x = 500, y = 350, z = 100, energy = 71, spd = 220 }) },
    { feed = tlm("drone-1", { phase = "docked", dock = 1, x = 1892.5, y = 91, z = 365.5, energy = 88, spd = 0 }) },
    { feed = W.summary({}, 0, 0, PLACES, 1, { "T-1|drone-2|flying|1/2|rules|alex" }) },
  }
end
local function plus(a, b) for _, v in ipairs(b) do a[#a + 1] = v end return a end

print("setting up")
local w = run(world({ key = false }))
check("no key: it says how to get one, and stops", w.err == nil and has(w.everything, "seckey admin set disk"), w.err)
w = run(world({ label = false }))
check("no label: it asks for the key's name", w.err == nil and has(w.everything, "label set"), w.err)
w = run(world({ noradio = true }))
check("no modem: it says so", w.err == nil and has(w.everything, "no wireless or ender modem"), w.err)
w = run(world({ script = { { char = "q" } } }))
check("with a key it listens on the feed, and Q quits cleanly", w.err == nil and w.opened == W.CHANNEL, w.err)

print("the fleet, from the feed")
w = run(world({ script = plus(fleetFeed(), { { wait = 1 } }) }))
check("both units, in name order, with the screens' words", has(w.text, "DRONE-1") and has(w.text, "CRADLED")
  and has(w.text, "DRONE-2") and has(w.text, "CRUISE") and w.text:find("DRONE%-1.-DRONE%-2") ~= nil, w.text)
check("a unit on a place is at it by name", has(w.text, "HOME"), w.text)
w = run(world({ script = plus(fleetFeed(), { { key = KEYS.down }, { wait = 1 } }) }))
check("the picked unit shows its trip", has(w.text, "T-1 flying 1/2 rules"), w.text)
w = run(world({ script = plus(fleetFeed(), { { wait = 20 }, { wait = 1 } }) }))
check("a unit not heard from for a while is OFFLINE", has(w.text, "OFFLINE"), w.text)

print("what is not for this pocket")
local strangerTx = S.sender(OTHER, "alex", S.DIR.BASE_TO_WATCH, nil)
local screensTx = S.sender(KEY, "screens", S.DIR.BASE_TO_WATCH, nil)
w = run(world({ script = {
  { raw = strangerTx.seal(tlm("drone-9", { phase = "cruise", x = 1, z = 1 })) },
  { raw = screensTx.seal(tlm("drone-8", { phase = "cruise", x = 1, z = 1 })) },
  { raw = { type = "tlm", id = "drone-7", phase = "cruise" } },
  { wait = 1 } } }))
check("sealed with another key, sealed to another name, or plain: none of it shows", w.err == "script over"
  and not has(w.text, "DRONE-9") and not has(w.text, "DRONE-8") and not has(w.text, "DRONE-7"), w.err or w.text)

print("a trip, leg by leg")
local asked
w = run(world({
  answer = function(b) if b.type == "admin.trip" then return { true, "T-2: 2 stops, off now" } end end,
  script = plus(fleetFeed(), {
    { key = KEYS.enter },                        -- drone-1
    { char = "n" },
    { key = KEYS.enter },                        -- nothing to send yet
    { char = "s" }, { key = KEYS.down }, { key = KEYS.enter },               -- stop at rules
    { char = "w" }, { key = KEYS.down }, { key = KEYS.down }, { key = KEYS.enter },  -- over the pier
    { key = KEYS.enter },                        -- ends on a waypoint: refused here
    { char = "s" }, { key = KEYS.enter },        -- stop at home
    { char = "s" }, { key = KEYS.enter }, { key = KEYS.backspace },   -- one too many, taken back
    { key = KEYS.enter },                        -- send
    { wait = 1 } }) }))
asked = w.asked[1]
check("nothing goes before there is a stop, or while it ends on a waypoint",
  has(w.everything, "add a stop first") and has(w.everything, "end the trip on a stop") and #w.asked == 1, #w.asked)
check("Enter sends the legs as built", asked and asked.type == "admin.trip" and asked.drone == "drone-1"
  and asked.legs == "stop:rules;via:pier;stop:home", asked and asked.legs)
check("sealed with the pocket's own key, as an admin, on the base's channel", w.sent[1] and w.sent[1].ch == LINK.CHANNEL
  and w.sent[1].env.id == "alex" and w.sent[1].env.d == S.DIR.ADMIN_TO_BASE and asked and asked.nonce)
check("its counter is kept, so a restart is not a replay", w.files[".adminkey.ctr"] ~= nil)
check("the base's answer shows", has(w.text, "T-2: 2 stops, off now"), w.text)
check("and it is back on the unit", has(w.text, "N new trip"), w.text)

print("Go, Cancel, Home")
w = run(world({
  answer = function(b) return { b.type ~= "admin.cancel", b.type .. " heard" } end,
  script = plus(fleetFeed(), { { key = KEYS.down }, { key = KEYS.enter }, { char = "g" }, { char = "c" }, { char = "h" },
                               { wait = 1 } }) }))
local kinds = {}
for _, b in ipairs(w.asked) do kinds[#kinds + 1] = b.type .. ":" .. tostring(b.drone) .. ":" .. tostring(b.legs) end
check("G, C and H ask the base for drone-2", table.concat(kinds, " ")
  == "admin.go:drone-2:nil admin.cancel:drone-2:nil admin.trip:drone-2:stop:home", table.concat(kinds, " "))
check("every request has its own nonce", w.asked[1] and w.asked[2] and w.asked[1].nonce ~= w.asked[2].nonce
  and w.asked[2].nonce ~= w.asked[3].nonce)
check("answers show, newest first", w.text:find("admin.trip heard.-admin.cancel heard.-admin.go heard") ~= nil, w.text)

print("a long answer")
w = run(world({
  answer = function() return { false, "drone-1 is on T-3 - cancel it first" } end,
  script = plus(fleetFeed(), { { key = KEYS.enter }, { char = "h" }, { wait = 1 } }) }))
check("wraps at a space instead of losing its end", w.text:find("drone-1 is on T-3 - cancel\nit first", 1, true) ~= nil, w.text)

print("backing out")
w = run(world({ script = plus(fleetFeed(), { { key = KEYS.enter }, { char = "n" }, { char = "s" }, { key = KEYS.enter },
                                             { char = "q" }, { key = KEYS.backspace }, { char = "q" } }) }))
check("Q in the trip goes back without sending; Backspace to the fleet; Q quits", w.err == nil and #w.asked == 0, w.err)
w = run(world({ script = { { key = KEYS.enter }, { char = "n" }, { char = "s" }, { wait = 1 } } }))
check("no places from the base yet: Enter on an empty fleet does nothing", not has(w.text, "TRIP FOR"), w.text)

print("")
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then error("admin tests failed", 0) end
