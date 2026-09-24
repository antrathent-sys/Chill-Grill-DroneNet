-- cc_world: TEST-ONLY. One CC computer on the desktop, with a real event loop,
-- so a program's own parallel loops, sleeps, timers and radio run as they do
-- in game. Never deployed.
--
--   local W = dofile(DIR .. "/cc_world.lua")
--   local w = W.new(DIR, { label = "depot-pier", S = seclinkModule })
--   w.files["station.lua"] = "..."          -- the computer's disk
--   w.periph.modem_ender = { type = "modem", m = { transmit = function(ch, r, msg) ... end } }
--   w.at(5, function() return { "modem_message", ... } end)   -- an event at T=5
--   w:run("depot.lua", { "run" }, 60)        -- until it ends, fails, or T=60
--   w.text, w.err, w.clock
--
-- What CC does and desktop Lua 5.1 does not, stood in for here: pcall that a
-- sleep can yield through, dofile in the computer's environment, os.pullEvent
-- on a queue of events and timers, parallel.waitForAny as CC writes it.

local W = {}
local unpack = table.unpack or unpack
local function pack(...) return { n = select("#", ...), ... } end

function W.new(DIR, opts)
  opts = opts or {}
  local w = { files = {}, printed = {}, clock = 0, queue = {}, timers = {}, nTimer = 0, later = {},
              lines = opts.lines or {}, periph = {}, redstone = {} }
  local env = setmetatable({}, { __index = _G })
  w.env = env
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
    move = function(a, b)
      if w.files[a] == nil then error("no such file " .. a, 2) end
      w.files[b], w.files[a] = w.files[a], nil
    end,
    open = function(p, mode)
      if mode == "r" then
        local s = w.files[p]
        if not s then return nil end
        local pos = 1
        return { readAll = function() local r = s:sub(pos) pos = #s + 1 return r end,
                 readLine = function()
                   if pos > #s then return nil end
                   local e = s:find("\n", pos, true) or (#s + 1)
                   local line = s:sub(pos, e - 1)
                   pos = e + 1
                   return line
                 end, close = function() end }
      end
      local buf = { mode == "a" and (w.files[p] or "") or "" }
      return { write = function(x) buf[#buf + 1] = tostring(x) end,
               writeLine = function(x) buf[#buf + 1] = tostring(x) .. "\n" end,
               flush = function() end,
               close = function() w.files[p] = table.concat(buf) end }
    end,
  }
  env.pcall = function(fn, ...)
    -- a C function cannot be a coroutine in 5.1, and never yields
    local okCo, co = pcall(coroutine.create, fn)
    if not okCo then return pcall(fn, ...) end
    local res = pack(coroutine.resume(co, ...))
    while coroutine.status(co) ~= "dead" do
      local back = pack(coroutine.yield(unpack(res, 2, res.n)))
      res = pack(coroutine.resume(co, unpack(back, 1, back.n)))
    end
    return unpack(res, 1, res.n)
  end
  env.dofile = function(p)
    if p == "lib/seclink.lua" and opts.S then return opts.S end
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
  env.peripheral = {
    getNames = function() local t = {} for n in pairs(w.periph) do t[#t + 1] = n end table.sort(t) return t end,
    getType = function(n) return w.periph[n] and w.periph[n].type end,
    isPresent = function(n) return w.periph[n] ~= nil end,
    getMethods = function(n)
      local p = w.periph[n]
      if not p then return nil end
      local out = {}
      for k in pairs(p.m) do out[#out + 1] = k end
      table.sort(out)
      return out
    end,
    call = function(n, m, ...)
      local p = w.periph[n]
      if not p then error("no peripheral " .. tostring(n), 2) end
      if not p.m[m] then error("no method " .. tostring(m), 2) end
      return p.m[m](...)
    end,
    find = function(ty)
      local found = {}
      for _, n in ipairs(env.peripheral.getNames()) do
        if w.periph[n].type == ty then found[#found + 1] = w.periph[n].m end
      end
      return unpack(found)
    end,
  }
  env.redstone = {
    setOutput = function(side, on) w.redstone[side] = on end,
    getAnalogInput = function() return 0 end,
    getSides = function() return { "top", "bottom", "left", "right", "front", "back" } end,
  }
  env.rednet = { open = function() end, broadcast = function() end, send = function() end,
                 isOpen = function() return true end,
                 receive = function(proto)
                   while true do
                     local _, from, msg, p = env.os.pullEvent("rednet_message")
                     if proto == nil or p == proto then return from, msg, p end
                   end
                 end }
  env.keys = setmetatable({ x = 45, q = 16, enter = 28, y = 21 }, { __index = function() return 0 end })
  local nothing = function() end
  env.term = setmetatable({ getSize = function() return 51, 19 end, isColour = function() return true end,
                            getCursorPos = function() return 1, 1 end },
    { __index = function() return nothing end })
  env.colours = setmetatable({}, { __index = function() return 1 end })
  env.colors = env.colours
  env.textutils = { formatTime = function() return "12:00" end }
  env.os = setmetatable({
    clock = function() return w.clock end,
    epoch = function() return 1700000000000 + math.floor(w.clock * 1000) end,
    time = function() return 12 end,
    getComputerLabel = function() return opts.label end,
    getComputerID = function() return opts.id or 5 end,
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

  --- An event at time t: a table, or a function returning one when it is
  -- delivered (so a sealed packet gets its counter in the order it is sent).
  function w.at(t, ev) w.later[#w.later + 1] = { at = t, ev = ev } end

  local function nextEvent()
    if #w.queue > 0 then return table.remove(w.queue, 1) end
    local best, kind, idx = nil, nil, nil
    for id, at in pairs(w.timers) do if not best or at < best then best, kind, idx = at, "timer", id end end
    for i, l in ipairs(w.later) do if not best or l.at < best then best, kind, idx = l.at, "later", i end end
    if not best then return nil end
    w.clock = math.max(w.clock, best)
    if kind == "timer" then w.timers[idx] = nil return { "timer", idx, n = 2 } end
    local l = table.remove(w.later, idx)
    local ev = type(l.ev) == "function" and l.ev(w) or l.ev
    if not ev then return nextEvent() end
    ev.n = ev.n or #ev
    return ev
  end

  --- Run a program until it ends, errors, or the clock passes untilT (then
  -- it is simply left there, as a computer still running).
  function w:run(path, args, untilT)
    local f = assert(loadfile(DIR .. "/../" .. path))
    setfenv(f, env)
    _G.fs = env.fs              -- seclink reads keys and counters through the global fs
    local co = coroutine.create(function() return f(unpack(args or {})) end)
    local filter, ev, steps = nil, { n = 0 }, 0
    while true do
      if filter == nil or filter == ev[1] or ev[1] == "terminate" then
        local ok, want = coroutine.resume(co, unpack(ev, 1, ev.n))
        if not ok then w.err = tostring(want) break end
        if coroutine.status(co) == "dead" then w.ended = true break end
        filter = want
      end
      steps = steps + 1
      if steps > 200000 then w.err = "never settled" break end
      ev = nextEvent()
      if not ev then w.err = "stuck waiting for " .. tostring(filter) break end
      if untilT and w.clock > untilT then break end
    end
    w.text = table.concat(w.printed, "\n")
    return w
  end
  return w
end

return W
