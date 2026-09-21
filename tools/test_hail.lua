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
               q = 16, t = 20, c = 46, g = 34, l = 38, one = 2, two = 3, three = 4 }
local COLOURS = { white = 1, orange = 2, brown = 4096, black = 32768, red = 16384,
                  grey = 128, lightGrey = 256 }

-- A pocket computer and a base. inputs are the player's keys, each waiting for
-- its moment (`when`); the base answers what the pocket says.
local function world(opts)
  local w = { files = opts.files or {}, shown = {}, said = {}, inbox = {}, clock = 0,
              inputs = opts.inputs or {}, events = 0, state = "idle", rebooted = false,
              label = opts.label }
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
  env.read = function() return "" end
  env.sleep = function(t) w.clock = w.clock + (t or 0) end
  env.gps = { locate = function() return 100, 64, 200 end }
  env.peripheral = {
    getNames = function() return opts.noradio and {} or { "back" } end,
    getType = function() return "modem" end,
    call = function(_, m) if m == "isWireless" then return true end end,
  }

  -- the base: answers exactly the questions ops answers, the way ops does
  local places = { { name = "home", x = 1892, z = 365 }, { name = "market", x = 865, z = 248 } }
  local function reply(msg) w.inbox[#w.inbox + 1] = msg end
  env.rednet = {
    open = function() end,
    broadcast = function(msg)
      w.said[#w.said + 1] = msg
      if type(msg) ~= "table" then return end
      if msg.type == "places.ask" then reply(F.placesList(places, "p-" .. #w.said))
      elseif msg.type == "account.ask" then reply(F.accountInfo("alex", 500, 3, "a-" .. #w.said))
      elseif msg.type == "taxi.request" then
        w.request = msg
        reply(F.assign("j-1", msg))
        reply(F.state("j-1", "drone-1", "enroute", nil, "s-1"))
        reply(F.state("j-1", "drone-1", "waiting", nil, "s-2"))
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
    if w.events > 2000 then error("runaway: 2000 events", 0) end
    if filter ~= "key" and filter ~= "char" and #w.inbox > 0 then
      local m = table.remove(w.inbox, 1)
      if m.type == "job.state" then w.state = m.state end
      return "rednet_message", 7, m, F.PROTO
    end
    local nxt = w.inputs[1]
    if nxt and (not nxt.when or nxt.when(w)) then
      table.remove(w.inputs, 1)
      if nxt.terminate then return "terminate" end
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
  env.os = setmetatable({
    clock = function() w.clock = w.clock + 0.001 return w.clock end,
    epoch = function() return 1789867493000 + math.floor(w.clock * 1000) end,
    time = function() return 12 end,
    startTimer = function() return 1 end, cancelTimer = function() end,
    pullEvent = function(f)
      local ev = { nextEvent(f) }
      if ev[1] == "terminate" and w.rawEvents ~= true then error("Terminated", 0) end
      return (table.unpack or unpack)(ev)
    end,
    pullEventRaw = function(f) return nextEvent(f) end,
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
    { key = KEYS.enter },
    { key = KEYS.enter },
    { char = "g", when = function(w) return w.state == "waiting" end },
  }
end

print("a ride on a customer's pass")
local w = run(world({ inputs = ride() }), "hail.lua", "kiosk")
check("it ran until the player stopped pressing keys", w.err == "script over", w.err)
check("the places list drew (the canvas helper exists)", has(w, "WHERE TO?"))
check("Q did not leave the list", w.request ~= nil)
-- the list is nearest first: market (766 blocks), then home (1799)
check("it asked for the second place on the list", w.request and w.request.toName == "home", w.request and w.request.toName)
check("from where the player stood", w.request and w.request.px == 100 and w.request.pz == 200)
check("the confirm screen asked with one key", has(w, "CONFIRM"))
check("the ride screen drew while it came", has(w, "ON STATION"))
check("G sent the shuttle off", w.went == true)
check("it arrived", has(w, "ARRIVED"))
check("and came round to the list again", select(2, w.text:upper():gsub("WHERE TO%?", "")) >= 2)
check("no operator words on a customer's screen",
  not has(w, "hail test") and not has(w, "ops ") and not has(w, "autorun"))
local stats = w.files[".hailstats"] or ""
check("the ride was counted on the pass", stats:find("rides", 1, true) ~= nil)

print("no shuttle answering")
local quiet = world({ inputs = { { key = KEYS.enter }, { key = KEYS.enter } } })
local answer = quiet.env.rednet.broadcast
quiet.env.rednet.broadcast = function(msg)      -- places and balance, but no shuttle
  if type(msg) == "table" and msg.type == "taxi.request" then quiet.said[#quiet.said + 1] = msg return end
  return answer(msg)
end
run(quiet, "hail.lua", "kiosk")
check("it says so in customer's words", has(quiet, "service may be closed"))
check("and does not tell them to type a command", not has(quiet, "hail test"))

print("the kiosk around it")
local k = world({ inputs = ride(), files = { [".pass"] = "alex\n", [".kiosk"] = "hail\n" }, label = "someone" })
k.rawEvents = true
run(k, "kiosk.lua")
check("the label comes back from .pass", k.label == "alex", k.label)
check("the boot screen shows the name and no debug",
  k.shown[1] and not has(k, "pulling") and not has(k, "role"))
check("the ride still works under it", k.went == true)
check("when it stops, it goes out of service", has(k, "OUT OF SERVICE"))
check("writes what happened for the base", (k.files[".crash"] or ""):find("script over", 1, true) ~= nil)
check("and starts again", k.rebooted == true)

local t = world({ inputs = { { terminate = true }, { key = KEYS.down }, { key = KEYS.enter }, { key = KEYS.enter },
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
