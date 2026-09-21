-- Desktop tests for `ops load`: the loading station's commands on the base
-- computer, and a whole load synced with a pretend drone over the sealed
-- radio. ops runs inside a small CC event loop - timers, queued events,
-- parallel - so its own receive loop, sleeps and key watcher all run for real.
local DIR = ...
local pass, fail = 0, 0
local function check(n, c, d)
  if c then pass = pass + 1 print("  ok   " .. n)
  else fail = fail + 1 print("  FAIL " .. n .. (d and ("  " .. tostring(d)) or "")) end
end

dofile(DIR .. "/cc_shim.lua")
local S = dofile(DIR .. "/../lib/seclink.lua")
S.ROOT = DIR .. "/../"
local LINK = dofile(DIR .. "/../lib/link.lua")
local F = dofile(DIR .. "/../lib/fleet.lua")
local KEYHEX = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
local KEY = S.parseKey(KEYHEX)
local unpack = table.unpack or unpack
local function pack(...) return { n = select("#", ...), ... } end

local STATION = [[
return {
  dock = "home",
  place = { left = { relay = "redstone_relay_0", side = "top" }, right = { relay = "redstone_relay_1", side = "top" } },
  assemble = { left = { relay = "redstone_relay_2", side = "top" }, right = { relay = "redstone_relay_2", side = "bottom" } },
  lift = { relay = "redstone_relay_3", side = "top" },
  retract = { relay = "redstone_relay_3", side = "bottom" },
  stick = { left = "Create_Sticker_0", right = "Create_Sticker_1" },
  fill = %s,
  wait = { place = 1, assemble = 1, lift = 2, stick = 1, retract = 2, fill = 20, dock = 8 },
}
]]

-- opts: args, lines (answers to read()), station (fill rule, or false for no
-- station.lua), drone = { x, z, docked, stickFails, silent }, intake (items),
-- keysAt = { { t, key } }, norelay (a relay name that is missing)
local function base(opts)
  local w = { files = {}, printed = {}, clock = 0, queue = {}, timers = {}, nTimer = 0, later = {},
              sets = {}, level = {}, orders = {}, lines = opts.lines or { "y" }, nextTlm = 0.5, seq = 0 }
  w.files[".fleetkeys"] = "drone-1=" .. KEYHEX .. "\n"
  w.files["pads.lua"] = 'return { { name = "home", x = 1892, y = 91, z = 365, kind = "dock" } }'
  if opts.station ~= false then w.files["station.lua"] = STATION:format(opts.station or "{ secs = 5 }") end
  local drone = opts.drone or {}
  local env = setmetatable({}, { __index = _G })
  local function out(s) w.printed[#w.printed + 1] = tostring(s) end
  env.print = function(...)
    local t = {}
    for i = 1, select("#", ...) do t[#t + 1] = tostring((select(i, ...))) end
    out(table.concat(t, " "))
  end
  env.write = out
  env.read = function() return table.remove(w.lines, 1) end
  env.fs = {
    exists = function(p) return w.files[p] ~= nil end,
    attributes = function(p) return w.files[p] and { modified = 0, size = #w.files[p] } or nil end,
    delete = function(p) w.files[p] = nil end,
    isDir = function() return false end,
    open = function(p, mode)
      if mode == "r" then
        local s = w.files[p]
        if not s then return nil end
        local pos = 1
        return { readAll = function() return s end,
                 readLine = function()
                   if pos > #s then return nil end
                   local e = s:find("\n", pos, true) or (#s + 1)
                   local line = s:sub(pos, e - 1)
                   pos = e + 1
                   return line
                 end, close = function() end }
      end
      local buf = { mode == "a" and (w.files[p] or "") or "" }
      local h = {}
      h.write = function(x) buf[#buf + 1] = tostring(x) end
      h.writeLine = function(x) buf[#buf + 1] = tostring(x) .. "\n" end
      h.flush = function() end
      h.close = function() w.files[p] = table.concat(buf) end
      return h
    end,
  }
  -- CC's pcall can be yielded through (a sleep inside it works); desktop
  -- Lua 5.1's cannot, so pcall here runs the function as a coroutine and
  -- passes its yields up
  env.pcall = function(fn, ...)
    local co = coroutine.create(fn)
    local res = pack(coroutine.resume(co, ...))
    while coroutine.status(co) ~= "dead" do
      local back = pack(coroutine.yield(unpack(res, 2, res.n)))
      res = pack(coroutine.resume(co, unpack(back, 1, back.n)))
    end
    return unpack(res, 1, res.n)
  end
  -- libraries run in this computer's environment, as they would in CC
  env.dofile = function(p)
    if p == "lib/seclink.lua" then return S end
    local f
    if w.files[p] then
      f = assert(loadstring(w.files[p], p))
    else
      f = loadfile(DIR .. "/../" .. p)
      if not f then error("cannot open " .. p, 0) end
    end
    setfenv(f, env)
    return f()
  end

  -- the drone: it hears sealed orders and answers sealed, and its telemetry
  -- comes in every 2 s
  local droneRx = S.receiver()
  local droneTx = S.sender(KEY, "drone-1", S.DIR.DRONE_TO_BASE, nil)
  -- sealed when it is sent, not when it is scheduled: the counter has to rise
  -- in the order the packets go out, as it does on a real drone
  local function fromDrone(body, delay)
    w.later[#w.later + 1] = { at = w.clock + (delay or 0.3), body = body }
  end
  local function transmit(ch, _, env2)
    if ch ~= LINK.CHANNEL or type(env2) ~= "table" or not env2.sl then return end
    local body = droneRx.open(env2, function(id) return id == "drone-1" and KEY or nil end, S.DIR.BASE_TO_DRONE, 120000)
    if not body then return end
    w.orders[#w.orders + 1] = body
    if drone.silent then return end
    if body.type == "unit.stick" then
      local ok = not drone.stickFails
      fromDrone(F.stuck(body.job, "drone-1", ok, (not ok) and "Create_Sticker_1 is not a sticker on this drone" or nil,
        (body.on and "Create_Sticker_0 out" or "Create_Sticker_0 in"), "d-" .. #w.orders))
    elseif body.type == "ops.fly" then
      fromDrone(F.ack("ops", "drone-1", true, nil, "d-" .. #w.orders), 0.05)
    end
  end
  local function tlm()
    w.seq = w.seq + 1
    local docked = drone.docked ~= false and (not drone.dockAt or w.clock >= drone.dockAt)
    local s = { t = w.clock, phase = docked and "docked" or "idle", h = 98.5, e = 0,
                x = drone.x or 1892.5, z = drone.z or 365.5, vx = 0, vz = 0, vv = 0 }
    return { "modem_message", "modem_ender", LINK.CHANNEL, LINK.CHANNEL,
             droneTx.seal(LINK.packet("drone-1", w.seq, s, { energy = 50 }, { pct = 80 }, { connected = docked }, 0, 0, nil, "idle")) }
  end

  local relay = function(name)
    return { type = "redstone_relay", m = {
      setOutput = function(side, on)
        w.sets[#w.sets + 1] = { t = w.clock, k = name .. ":" .. side, on = on }
        w.level[name .. ":" .. side] = on
      end,
      getAnalogInput = function() return 0 end } }
  end
  local periph = {
    modem_ender = { type = "modem", m = { isWireless = function() return true end, open = function() end,
                                           transmit = transmit } },
  }
  for i = 0, 3 do
    local n = "redstone_relay_" .. i
    if n ~= opts.norelay then periph[n] = relay(n) end
  end
  if opts.intake then
    periph["minecraft:chest_0"] = { type = "minecraft:chest", m = {
      list = function()
        local left = opts.intakeLeft and opts.intakeLeft(w) or opts.intake
        if left <= 0 then return {} end
        return { [1] = { name = "minecraft:cobblestone", count = left } }
      end,
      getItemDetail = function() return { name = "minecraft:cobblestone", maxCount = 64 } end } }
  end
  env.peripheral = {
    getNames = function() local t = {} for n in pairs(periph) do t[#t + 1] = n end table.sort(t) return t end,
    getType = function(n) return periph[n] and periph[n].type end,
    isPresent = function(n) return periph[n] ~= nil end,
    call = function(n, m, ...)
      if not periph[n] then error("no peripheral " .. tostring(n), 2) end
      return periph[n].m[m](...)
    end,
  }
  env.rednet = { open = function() end, broadcast = function() end, send = function() end, isOpen = function() return true end }
  env.redstone = { setOutput = function() end, getAnalogInput = function() return 0 end,
                   getSides = function() return { "top", "bottom", "left", "right", "front", "back" } end }
  env.keys = setmetatable({ x = 45, q = 16, enter = 28, y = 21 }, { __index = function() return 0 end })
  env.term = { getSize = function() return 51, 19 end }
  env.textutils = { formatTime = function() return "12:00" end }

  -- the event loop
  env.os = setmetatable({
    clock = function() return w.clock end,
    epoch = function() return 1700000000000 + math.floor(w.clock * 1000) end,
    time = function() return 12 end,
    getComputerLabel = function() return "base" end,
    getComputerID = function() return 1 end,
    startTimer = function(n) w.nTimer = w.nTimer + 1 w.timers[w.nTimer] = w.clock + (n or 0) return w.nTimer end,
    cancelTimer = function(id) w.timers[id] = nil end,
    queueEvent = function(...) w.queue[#w.queue + 1] = pack(...) end,
    pullEventRaw = function(f) return coroutine.yield(f) end,
    pullEvent = function(f)
      local ev = pack(coroutine.yield(f))
      if ev[1] == "terminate" then error("Terminated", 0) end
      return unpack(ev, 1, ev.n)
    end,
  }, { __index = os })
  env.sleep = function(n)
    local id = env.os.startTimer(n)
    repeat local _, p = env.os.pullEvent("timer") until p == id
  end
  env.parallel = { waitForAny = function(...)
    local cos, filters = {}, {}
    for i, f in ipairs({ ... }) do cos[i] = coroutine.create(f) end
    local ev = { n = 0 }
    while true do
      for i, co in ipairs(cos) do
        if filters[i] == nil or filters[i] == ev[1] or ev[1] == "terminate" then
          local ok, want = coroutine.resume(co, unpack(ev, 1, ev.n))
          if not ok then error(want, 0) end
          if coroutine.status(co) == "dead" then return i end
          filters[i] = want
        end
      end
      ev = pack(coroutine.yield())
    end
  end }
  for _, k in ipairs(opts.keysAt or {}) do w.later[#w.later + 1] = { at = k[1], ev = { "key", env.keys[k[2]] } } end

  -- what CC would deliver next: something queued, else the next thing due
  local function nextEvent()
    if #w.queue > 0 then return table.remove(w.queue, 1) end
    local best, kind, idx = nil, nil, nil
    for id, at in pairs(w.timers) do if not best or at < best then best, kind, idx = at, "timer", id end end
    for i, l in ipairs(w.later) do if not best or l.at < best then best, kind, idx = l.at, "later", i end end
    if not drone.silentTlm and (not best or w.nextTlm < best) then best, kind = w.nextTlm, "tlm" end
    if not best then return nil end
    w.clock = math.max(w.clock, best)
    if kind == "timer" then w.timers[idx] = nil return { "timer", idx, n = 2 } end
    if kind == "later" then
      local l = table.remove(w.later, idx)
      local ev = l.ev or { "modem_message", "modem_ender", LINK.CHANNEL, LINK.CHANNEL, droneTx.seal(l.body) }
      ev.n = #ev
      return ev
    end
    w.nextTlm = w.nextTlm + 2
    local ev = tlm()
    ev.n = #ev
    return ev
  end
  w.run = function()
    local f = assert(loadfile(DIR .. "/../ops.lua"))
    setfenv(f, env)
    _G.fs = env.fs
    local co = coroutine.create(function() return f(unpack(opts.args)) end)
    local filter, ev, steps = nil, { n = 0 }, 0
    while true do
      if filter == nil or filter == ev[1] or ev[1] == "terminate" then
        local ok, want = coroutine.resume(co, unpack(ev, 1, ev.n))
        if not ok then w.err = tostring(want) break end
        if coroutine.status(co) == "dead" then break end
        filter = want
      end
      steps = steps + 1
      if steps > 100000 or w.clock > 2000 then w.err = "never finished" break end
      ev = nextEvent()
      if not ev then w.err = "stuck waiting for " .. tostring(filter) break end
    end
    w.text = table.concat(w.printed, "\n")
    return w
  end
  return w
end

local function has(w, s) return w.text:find(s, 1, true) ~= nil end
local function firstOn(w, k) for _, s in ipairs(w.sets) do if s.k == k and s.on then return s end end end
local function onCount(w, k)
  local n = 0
  for _, s in ipairs(w.sets) do if s.k == k and s.on then n = n + 1 end end
  return n
end
local function ordersOf(w, ty)
  local t = {}
  for _, o in ipairs(w.orders) do if o.type == ty then t[#t + 1] = o end end
  return t
end

print("the station")
local w = base({ args = { "load" }, station = false }):run()
check("no station.lua: says how to make one", w.err == nil and has(w, "copy station.example.lua"), w.err)
w = base({ args = { "load" } }):run()
check("ops load lists it", w.err == nil and has(w, "2 bays (left + right), dock home"), w.err or w.text)
check("...with what a silo holds", has(w, "a silo holds 60 stacks: 3840 of a 64-stack item; the station takes 7680"))
check("...and every command", has(w, "ops load run <drone|any>"))
w = base({ args = { "load" }, norelay = "redstone_relay_2" }):run()
check("a relay that is not on the network is called out", has(w, "MISSING: redstone_relay_2"), w.text)

print("planning")
w = base({ args = { "load", "plan", "5000" } }):run()
check("5000 items: two silos, both bays", w.err == nil and has(w, "5000 items, 79 stacks: 2 silos (left + right)"), w.err or w.text)
check("...and the eight steps", has(w, "1 place") and has(w, "8 liftoff"))
w = base({ args = { "load", "plan", "8000" } }):run()
check("8000 does not fit", has(w, "does not fit"), w.text)
w = base({ args = { "load", "plan" }, station = '{ intake = "minecraft:chest_0" }', intake = 640 }):run()
check("no number: the intake is counted", w.err == nil and has(w, "640 items, 10 stacks: 1 silo (left)"), w.err or w.text)

print("one relay at a time")
w = base({ args = { "load", "test", "lift" } }):run()
local up = firstOn(w, "redstone_relay_3:top")
check("test lift: asks, fires the lift face, lets go", w.err == nil and up and w.level["redstone_relay_3:top"] == false, w.err)
w = base({ args = { "load", "test", "place", "right" } }):run()
check("test place right: only the right bay", onCount(w, "redstone_relay_1:top") == 1 and onCount(w, "redstone_relay_0:top") == 0)
w = base({ args = { "load", "test", "lift" }, lines = { "n" } }):run()
check("answer no: nothing fires", #w.sets == 0 and has(w, "nothing fired"))

print("the drone's stickers alone")
w = base({ args = { "load", "stick", "drone-1", "left" } }):run()
local st = ordersOf(w, "unit.stick")
check("stick: a sealed order for the left sticker", w.err == nil and #st == 1 and st[1].stickers == "Create_Sticker_0"
  and st[1].on == true, w.err or w.text)
check("...and its answer shown", has(w, "drone-1: done"), w.text)
w = base({ args = { "load", "unstick", "drone-1" } }):run()
st = ordersOf(w, "unit.stick")
check("unstick: both stickers, retract", #st == 1 and st[1].stickers == "Create_Sticker_0,Create_Sticker_1" and st[1].on == false)
w = base({ args = { "load", "stick", "drone-1" }, drone = { silent = true } }):run()
check("a drone that never answers: says so", has(w, "no answer in 10 s"), w.text)

print("a whole load")
w = base({ args = { "load", "run", "drone-1", "1000" } }):run()
st = ordersOf(w, "unit.stick")
local lift = firstOn(w, "redstone_relay_3:top")
local lower = firstOn(w, "redstone_relay_3:bottom")
check("it runs to the end", w.err == nil and has(w, "loaded in"), w.err or w.text)
check("one silo: left placed, assembled, lifted", onCount(w, "redstone_relay_0:top") == 1
  and onCount(w, "redstone_relay_1:top") == 0 and onCount(w, "redstone_relay_2:top") == 1 and lift ~= nil)
check("the drone is told to stick once the lift is up", #st == 1 and st[1].stickers == "Create_Sticker_0")
check("the lift comes down after the drone answered", lower and lift and lower.t > lift.t + 2)
check("no liftoff set: nothing flown, and it says how", #ordersOf(w, "ops.fly") == 0 and has(w, "ops fly drone-1"))
check("the steps are printed as they go", has(w, "LIFT") and has(w, "STICK") and has(w, "RETRACT"))

w = base({ args = { "load", "run", "drone-1", "1000" }, drone = { stickFails = true } }):run()
check("the drone cannot stick: called off at stick, lift lowered", has(w, "called off at stick")
  and onCount(w, "redstone_relay_3:bottom") == 1, w.text)
w = base({ args = { "load", "run", "drone-1", "1000" }, drone = { x = 1950.5 } }):run()
check("docked somewhere else: waits, then called off at dock, nothing lifted", has(w, "called off at dock")
  and has(w, "58 blocks from home") and onCount(w, "redstone_relay_3:top") == 0, w.text)
w = base({ args = { "load", "run", "drone-1", "1000" }, drone = { dockAt = 5 } }):run()
check("it arrives during the fill: the load waits for it and carries on", has(w, "loaded in"), w.text)
w = base({ args = { "load", "run", "drone-1", "1000" }, keysAt = { { 10.2, "x" } } }):run()
check("X during the lift: called off, and the lift comes back down", has(w, "calling it off") and
  has(w, "called off") and onCount(w, "redstone_relay_3:bottom") == 1, w.text)
w = base({ args = { "load", "run", "drone-1" }, station = '{ intake = "minecraft:chest_0", settle = 1 }', intake = 640,
           intakeLeft = function(ww)
             local placed = firstOn(ww, "redstone_relay_0:top")
             return (placed and ww.clock >= placed.t + 2) and 0 or 640
           end }):run()
check("from the intake: counts 640, waits for it to empty, loads", w.err == nil and has(w, "640 items, 10 stacks")
  and has(w, "loaded in"), w.err or w.text)
local liftoffStation = STATION:gsub("fill = %%s,", "fill = %%s, liftoff = \"ferry pier\",")
STATION, liftoffStation = liftoffStation, STATION
w = base({ args = { "load", "run", "drone-1", "1000" } }):run()
local fl = ordersOf(w, "ops.fly")
check("with a liftoff: the drone is flown last", w.err == nil and #fl == 1 and fl[1].args == "ferry pier"
  and has(w, "loaded in"), w.err or w.text)
STATION = liftoffStation

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then error("ops load tests failed", 0) end
