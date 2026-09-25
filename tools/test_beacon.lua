-- Desktop tests for beacon.lua: sealed idle telemetry the base can open, docked
-- versus idle, home for the map, and a counter that only rises across a flight
-- launched from the beacon.
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
local KEYHEX = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
local KEY = S.parseKey(KEYHEX)

-- a drone: opts.name (what the connector reports), energy rising or not,
-- velocity, keys pressed, and how many packets each beacon session sends
local function drone(opts)
  local w = { files = opts.files or {}, printed = {}, sent = {}, runs = {}, keys = opts.keys or {},
              lines = opts.lines or {}, cycles = opts.cycles or 2, stored = opts.stored or 500000 }
  if not opts.nokey then w.files[".dronekey"] = w.files[".dronekey"] or KEYHEX end
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
    open = function(p, mode)
      if mode == "r" then
        local s = w.files[p]
        return s and { readAll = function() return s end, readLine = function() return s end, close = function() end } or nil
      end
      local buf = {}
      return { write = function(s) buf[#buf + 1] = s end, close = function() w.files[p] = table.concat(buf) end }
    end,
    delete = function(p) w.files[p] = nil end,
  }
  local acc = {
    getEnergy = function()
      if opts.charging then w.stored = w.stored + 5000 end
      return w.stored
    end,
    getCapacity = function() return 1000000 end,
  }
  local thr = { getEnergy = function() return 800 end, getEnergyCapacity = function() return 1000 end }
  local periph = {
    modem_ender = { type = "modem", m = {
      isWireless = function() return true end,
      transmit = function(ch, _, msg) w.sent[#w.sent + 1] = { ch = ch, msg = msg } end } },
    altitude_sensor_0 = { type = "altitude_sensor", m = { getHeight = function()
      if type(opts.height) == "function" then return opts.height(w) end
      return opts.height or 98.5
    end } },
    modular_accumulator_0 = { type = "modular_accumulator", m = acc },
    vector_thruster_5 = { type = "vector_thruster", m = thr },
    docking_connector_0 = { type = "docking_connector", m = { getConnectedName = function() return opts.name or "" end } },
  }
  periph.modem_0 = { type = "modem", m = { isWireless = function() return false end } }
  -- opts.stickers: names of Create Stickers on the craft, all retracted
  w.stuckOut = {}
  for _, n in ipairs(opts.stickers or {}) do
    w.stuckOut[n] = false
    periph[n] = { type = "Create_Sticker", m = {
      extend = function() local was = w.stuckOut[n] w.stuckOut[n] = true return not was end,
      retract = function() local was = w.stuckOut[n] w.stuckOut[n] = false return was end,
      isExtended = function() return w.stuckOut[n] end,
      isAttachedToBlock = function() return false end } }
  end
  if opts.nowire then periph.modem_0 = nil end
  if opts.noradio then periph.modem_ender = nil end
  env.peripheral = {
    getNames = function() local t = {} for n in pairs(periph) do t[#t + 1] = n end table.sort(t) return t end,
    getType = function(n) return periph[n] and periph[n].type end,
    call = function(n, m, ...) return periph[n].m[m](...) end,
    find = function(ty)
      local found = {}
      for _, n in ipairs(env.peripheral.getNames()) do
        if periph[n].type == ty then found[#found + 1] = periph[n].m end
      end
      return unpack(found)
    end,
  }
  w.inbox = opts.inbox or {}
  w.said = {}
  w.opens = {}
  -- orders arrive sealed, on the telemetry channel, as the base sends them
  w.baseSealer = S.sender(KEY, opts.label or "drone-1", S.DIR.BASE_TO_DRONE, nil)
  env.rednet = {
    open = function(nm) w.opens[#w.opens + 1] = nm end,
    broadcast = function(msg, proto) w.said[#w.said + 1] = { msg = msg, proto = proto } end,
  }
  local v = opts.velocity or { x = 3, y = 0, z = -1 }
  env.sublevel = {
    getLogicalPose = function() return { position = { x = 1892.5, y = 98.5 - 7.5, z = 365.5 } } end,
    getLinearVelocity = function() return v end,
  }
  env.term = { getSize = function() return 39, 13 end, getCursorPos = function() return 1, 5 end,
               setCursorPos = function() end, clearLine = function() end, write = function() end }
  -- a pause inside the order listener runs outside any coroutine here
  -- opts.latch: the face fly holds high to keep the connector out
  env.redstone = { getOutput = function(side) return opts.latch == side end }
  env.sleep = function() if coroutine.running() then coroutine.yield() end end
  -- the send loop runs `cycles` packets, then the key watcher gets the next key
  -- send a few packets, then whichever of the other two has something to do:
  -- an order if one is queued (net), else the keyboard
  w.depth, w.clock, w.queued = 0, 0, {}
  w.holdEvents = opts.holdEvents or {}
  local function sideBySide(...)
    local cos, filters = {}, {}
    for i, f in ipairs({ ... }) do cos[i] = coroutine.create(f) end
    w.depth = w.depth + 1
    local ev, first, n = {}, true, 0
    while true do
      for i, co in ipairs(cos) do
        if first or filters[i] == nil or filters[i] == ev[1] or ev[1] == "terminate" then
          local ok, want = coroutine.resume(co, (table.unpack or unpack)(ev))
          if not ok then w.depth = w.depth - 1 error(want, 0) end
          if coroutine.status(co) == "dead" then w.depth = w.depth - 1 return i end
          filters[i] = want
        end
      end
      first = false
      n = n + 1
      if n > 5000 then error("hold never ended", 0) end
      -- what CC would deliver next: something queued, a scripted order when
      -- its time comes, else a second passing
      if #w.queued > 0 then
        ev = table.remove(w.queued, 1)
      elseif w.holdEvents[1] and w.clock >= (w.holdEvents[1].at or 0) then
        local h = table.remove(w.holdEvents, 1)
        ev = { "modem_message", "modem_ender", LINK.CHANNEL, LINK.CHANNEL, w.baseSealer.seal(h.order) }
      else
        w.clock = w.clock + 1
        ev = { "timer", 1 }
      end
    end
  end
  env.parallel = { waitForAny = function(...)
    if select("#", ...) == 2 then return sideBySide(...) end
    return w.mainLoop(...)
  end }
  w.mainLoop = function(a, b, net)
    local co = coroutine.create(a)
    for _ = 1, w.cycles do
      local ok, e = coroutine.resume(co)
      if not ok then error(e, 0) end
    end
    if net and #w.inbox > 0 then
      local ok, e = pcall(net)
      if ok then return end
      if not tostring(e):find("no more orders", 1, true) then error(e, 0) end
    end
    b()
  end
  env.os = setmetatable({
    clock = function() return w.clock end,
    startTimer = function() return 1 end, cancelTimer = function() end,
    queueEvent = function(...) w.queued[#w.queued + 1] = { ... } end,
    pullEvent = function(want)
      if w.depth > 0 then return coroutine.yield(want) end
      if want == "modem_message" or (want == nil and #w.inbox > 0) then
        local m = table.remove(w.inbox, 1)
        if not m then error("no more orders", 0) end   -- the harness stops here
        local env2 = m.raw and m.msg or w.baseSealer.seal(m)
        return "modem_message", "modem_ender", LINK.CHANNEL, LINK.CHANNEL, env2
      end
      return "char", table.remove(w.keys, 1) or "q"
    end,
    getComputerLabel = function() return opts.label or "drone-1" end,
    getComputerID = function() return 7 end,
  }, { __index = os })
  -- opts.fails: the numbers of the flights that fail (a crash, a refusal)
  env.shell = { run = function(cmd)
    w.runs[#w.runs + 1] = cmd
    -- opts.dropsOnRun: what fly writes to .drops during this flight
    if opts.dropsOnRun then w.files[".drops"] = opts.dropsOnRun end
    if cmd:match("^fly %d+$") and w.depth > 0 then
      -- a hold: fly keeps the height until its own word, "l", lands it
      while true do
        local ev, ch = env.os.pullEvent()
        if ev == "char" and ch == "l" then break end
      end
    end
    return not (opts.fails and opts.fails[#w.runs])
  end }
  env.dofile = function(p)
    if p == "lib/seclink.lua" then return S end
    return dofile(DIR .. "/../" .. p)
  end
  w.env = env
  return w
end

local function run(w)
  local f = assert(loadfile(DIR .. "/../beacon.lua"))
  setfenv(f, w.env)
  _G.fs = w.env.fs            -- seclink reads the key and counter through the global fs
  local ok, err = pcall(f)
  w.err = (not ok) and tostring(err) or nil
  w.text = table.concat(w.printed, "\n")
  -- open everything as the base would: one receiver, so a counter that fails to rise is refused
  local rx = S.receiver()
  w.opened, w.refused = {}, 0
  for _, s in ipairs(w.sent) do
    local body = rx.open(s.msg, function(id) return id == "drone-1" and KEY or nil end, S.DIR.DRONE_TO_BASE)
    if body then w.opened[#w.opened + 1] = body else w.refused = w.refused + 1 end
  end
  return w
end

local function tlm(w) local t = {} for _, b in ipairs(w.opened) do if b.type == "tlm" then t[#t + 1] = b end end return t end
local function plans(w) local t = {} for _, b in ipairs(w.opened) do if b.type == "plan" then t[#t + 1] = b end end return t end

print("sending")
local w = run(drone({ name = "base_pad", files = { ["fly.lua"] = "  HOME_X = 1892, HOME_Y = 91, HOME_Z = 365,   -- the base dock" } }))
local t = tlm(w)
check("runs", w.err == nil, w.err)
check("every packet opens with this drone's key, none refused", #w.opened == #w.sent and w.refused == 0 and #w.sent >= 3,
  #w.sent .. " sent, " .. w.refused .. " refused")
check("on the telemetry channel", w.sent[1].ch == LINK.CHANNEL)
check("sealed: only the envelope on the air", w.sent[1].msg.sl and w.sent[1].msg.c and w.sent[1].msg.x == nil)
check("the base's shape check accepts it", LINK.check(t[1]))
check("docked when the connector names its pad", t[1].phase == "docked" and t[1].dock == 1)
check("battery, FE, height and position", t[1].energy == 50 and t[1].fe == 80 and t[1].y == 98.5
  and t[1].x == 1892.5 and t[1].z == 365.5, t[1].energy .. " " .. tostring(t[1].fe))
check("idle mode, no target", t[1].mode == "idle" and t[1].tx == nil and t[1].leg == 0)
local p = plans(w)
check("a route packet naming home from fly.lua", #p == 1 and p[1].hx == 1892.5 and p[1].hz == 365.5 and p[1].route == "",
  p[1] and tostring(p[1].hx))
check("Q stops it", w.text:find("beacon stopped", 1, true) ~= nil and #w.runs == 0)

print("docked or idle")
w = run(drone({ velocity = { x = 2, y = 0, z = 0 } }))
check("moving, no pad name, not charging: idle", tlm(w)[2].phase == "idle" and tlm(w)[2].dock == 0)
-- docked is latched on a dock; landed is still on the ground, on nothing
local STILL = { x = 0, y = 0, z = 0 }
local AT_HOME = '  HOME_X = 1892, HOME_Y = 91, HOME_Z = 365,\n  DOCK_SIDE = "back",'
local FAR_HOME = '  HOME_X = 100, HOME_Y = 64, HOME_Z = 100,\n  DOCK_SIDE = "back",'
w = run(drone({ velocity = STILL, cycles = 3 }))
t = tlm(w)
check("still, nothing latched: LANDED from the second reading, not docked", t[1].phase == "idle"
  and t[2].phase == "landed" and t[3].dock == 0, t[2].phase)
w = run(drone({ velocity = STILL, cycles = 3, latch = "back", files = { ["fly.lua"] = AT_HOME } }))
t = tlm(w)
check("still, connector held out, on the home dock: docked", t[2].phase == "docked" and t[3].dock == 1, t[2].phase)
w = run(drone({ velocity = STILL, cycles = 3, files = { ["fly.lua"] = AT_HOME } }))
check("on the home dock with the connector NOT held - fly land put it there: landed", tlm(w)[2].phase == "landed")
w = run(drone({ velocity = STILL, cycles = 3, latch = "back", files = { ["fly.lua"] = FAR_HOME } }))
check("connector held but nowhere near a dock: landed", tlm(w)[2].phase == "landed" and tlm(w)[3].dock == 0)
w = run(drone({ velocity = STILL, cycles = 3, latch = "back", files = { ["fly.lua"] = FAR_HOME,
  ["pads.lua"] = 'return { { name = "pier", kind = "dock", x = 1892, y = 70, z = 365 } }' } }))
check("a dock from pads.lua counts as a dock", tlm(w)[2].phase == "docked")
w = run(drone({ velocity = STILL, cycles = 3, latch = "back", files = { ["fly.lua"] = FAR_HOME,
  ["pads.lua"] = 'return { { name = "field", kind = "pad", x = 1892, y = 70, z = 365 } }' } }))
check("a landing pad is not a dock: still on one is landed", tlm(w)[2].phase == "landed")
w = run(drone({ velocity = STILL, cycles = 3, latch = "back", files = { ["fly.lua"] = AT_HOME,
  ["tune.lua"] = 'return { DOCK_SIDE = "top" }' } }))
check("tune.lua moving the connector's face is followed", tlm(w)[2].phase == "landed")
w = run(drone({ charging = true }))
check("charging is docked", tlm(w)[2].phase == "docked")
w = run(drone({ files = { ["pads.lua"] = 'return { { name = "home", x = 100, y = 64, z = -40 } }',
                          ["fly.lua"] = "HOME_X = 1892, HOME_Y = 91, HOME_Z = 365," } }))
check("a home pad in pads.lua wins over fly.lua", plans(w)[1].hx == 100.5 and plans(w)[1].hz == -39.5)
w = run(drone({}))
check("no home anywhere: says so, sends no home", w.text:find("home unknown", 1, true) ~= nil and plans(w)[1].hx == nil)

print("flying from the beacon")
w = run(drone({ keys = { "f", "q" }, lines = { "deliver 2000 100 1000" }, name = "pad" }))
check("F runs the typed fly command", w.runs[1] == "fly deliver 2000 100 1000", w.runs[1])
check("it carries on afterwards and every counter still rises", #tlm(w) >= 4 and w.refused == 0, w.refused)
check("the counter file moved on", tonumber(w.files[".dronekey.ctr"]) and tonumber(w.files[".dronekey.ctr"]) > 0)
w = run(drone({ keys = { "f", "q" }, lines = { "  " } }))
check("an empty fly line flies nothing", #w.runs == 0 and w.text:find("nothing flown", 1, true) ~= nil)

print("orders over the cable")
local F = dofile(DIR .. "/../lib/fleet.lua")
local function order(t) t.to = t.to or "drone-1" return t end
-- what the drone said back, opened with its key as the base would
local function saidOfType(w, ty)
  local out = {}
  for _, b in ipairs(w.opened) do if b.type == ty then out[#out + 1] = b end end
  return out
end

w = run(drone({ name = "pad", inbox = { order(F.flyCommand("ferry pier", "ops-1")) } }))
check("an ops command is flown", w.runs[1] == "fly ferry pier", w.runs[1] or "nothing")
check("the order channel is open", w.text:find("taking sealed orders", 1, true) ~= nil)
check("and acked", #saidOfType(w, "job.ack") == 1 and saidOfType(w, "job.ack")[1].ok == true)
check("its answer is sealed, and the base can open it", w.refused == 0 and #saidOfType(w, "job.ack") == 1)

w = run(drone({ name = "pad", inbox = { order({ v = 1, type = "ops.fly", nonce = "ops-2",
  args = "land 1 2; shutdown" }) } }))
check("a command with shell characters is not flown", #w.runs == 0)

-- an order nobody sealed, or sealed with the wrong key, never arrives at all
local OTHER = S.parseKey("ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100")
w = run(drone({ name = "pad", inbox = { { raw = true, msg = order(F.flyCommand("ferry pier", "ops-5")) } } }))
check("an unsealed order is ignored", #w.runs == 0)
local stranger = S.sender(OTHER, "drone-1", S.DIR.BASE_TO_DRONE, nil)
w = run(drone({ name = "pad", inbox = { { raw = true, msg = stranger.seal(order(F.flyCommand("ferry pier", "ops-6"))) } } }))
check("an order sealed with the wrong key is ignored", #w.runs == 0)
local wrongWay = S.sender(KEY, "drone-1", S.DIR.DRONE_TO_BASE, nil)
w = run(drone({ name = "pad", inbox = { { raw = true, msg = wrongWay.seal(order(F.flyCommand("ferry pier", "ops-7"))) } } }))
check("an order sealed the wrong way round is ignored", #w.runs == 0)

w = run(drone({ name = "pad", inbox = { { to = "drone-9", v = 1, type = "ops.fly", nonce = "ops-3",
  args = "ferry pier" } } }))
check("an order for another drone is ignored", #w.runs == 0)

local dup = order(F.flyCommand("ferry pier", "ops-4"))
w = run(drone({ name = "pad", cycles = 1, inbox = { dup, dup } }))
check("the same order twice flies once", #w.runs == 1, #w.runs)

print("a taxi job, end to end")
local req = F.request({ name = "pier", x = 100, y = 70, z = -50 }, { x = 1200, z = 340 }, "pier-1")
w = run(drone({ name = "pad", cycles = 1, inbox = { order(F.assign("j-1", req)), order(F.go("j-1", "pier-2")) } }))
check("first it ferries to the pad", w.runs[1] == "fly ferry pier", w.runs[1] or "nothing")
check("then it lands at the destination", w.runs[2] == "fly land 1200 340", w.runs[2] or "nothing")
check("then it takes itself home", w.runs[3] == "fly ferry home", w.runs[3] or "nothing")
local states = {}
for _, s in ipairs(saidOfType(w, "job.state")) do states[#states + 1] = s.state end
check("and it says where it is at each step: " .. table.concat(states, " "),
  table.concat(states, " ") == "enroute waiting riding done", table.concat(states, " "))
check("every state names the job", saidOfType(w, "job.state")[1].job == "j-1")

-- (a second request, so a second nonce: the same nonce twice is dropped as a
-- replay before the job is even looked at, which the test above covers)
local req2 = F.request({ name = "pier", x = 100, y = 70, z = -50 }, { x = 5, z = 6 }, "pier-9")
w = run(drone({ name = "pad", cycles = 1, inbox = { order(F.assign("j-1", req)),
                                                    order(F.assign("j-2", req2)) } }))
local acks = saidOfType(w, "job.ack")
check("a second job while carrying someone is refused", #acks == 2 and acks[1].ok == true and acks[2].ok == false
  and acks[2].why:find("already on j-1", 1, true) ~= nil, acks[2] and acks[2].why)
check("and it is not flown", #w.runs == 1, #w.runs)

print("a counter that keeps rising across the flights of a job")
-- fly seals with the same key and counter file while it flies, so beacon has
-- to start a fresh sealer afterwards or the base refuses everything it says
local flightCtr = 0
local function flyMovesTheCounter(w)
  return function(cmd)
    w.runs[#w.runs + 1] = cmd
    flightCtr = tonumber(w.files[".dronekey.ctr"] or "0") + 500
    w.files[".dronekey.ctr"] = tostring(flightCtr)   -- as fly leaves it
    return true
  end
end
local wc = drone({ name = "pad", cycles = 1,
                   inbox = { order(F.assign("j-9", req)), order(F.go("j-9", "pier-3")) } })
wc.env.shell = { run = flyMovesTheCounter(wc) }
run(wc)
check("nothing it says after a flight is refused", wc.refused == 0, wc.refused .. " refused")
local st9 = {}
for _, b in ipairs(wc.opened) do if b.type == "job.state" then st9[#st9 + 1] = b.state end end
check("so the customer hears every step: " .. table.concat(st9, " "),
  table.concat(st9, " ") == "enroute waiting riding done", table.concat(st9, " "))

print("collected from where the customer stands, not just a pad")
local hail = F.request({ x = 812, y = 71, z = -344 }, { x = 1200, z = 340 }, "pocket-1", "alex")
-- resting where it should: the customer's ground (70) plus the rest gap
w = run(drone({ name = "pad", cycles = 1, height = 77.5,
                inbox = { order(F.assign("j-7", hail)), order(F.go("j-7", "pocket-2")) } }))
check("it lands beside the customer", w.runs[1] == "fly land 812 71 -344", w.runs[1] or "nothing")
check("then flies them to the destination", w.runs[2] == "fly land 1200 340", w.runs[2] or "nothing")
check("then home", w.runs[3] == "fly ferry home", w.runs[3] or "nothing")



print("a pickup that lands on something")
local hailO = F.request({ x = 812, y = 71, z = -344 }, { x = 1200, z = 340 }, "pocket-o", "alex")
-- first landing: on something (90, where 77.5 is the ground); the second, at
-- the customer's new spot, rests where it should
local function heights(w) return (#w.runs <= 2) and 90 or 77.5 end
w = run(drone({ name = "pad", cycles = 1, height = heights,
                inbox = { order(F.assign("j-o", hailO)), order(F.go("j-o", "pocket-o2")) },
                holdEvents = { { at = 20, order = order(F.relocate("j-o", 850, 71, -300, "pocket-o3")) } } }))
local stO = {}
for _, s in ipairs(saidOfType(w, "job.state")) do stO[#stO + 1] = s.state end
check("obstructed: it says so and holds above instead of giving up",
  table.concat(stO, " "):find("enroute relocate enroute waiting", 1, true) ~= nil, table.concat(stO, " "))
check("the hold is 12 above where it came to rest", w.runs[2] == "fly 102", w.runs[2])
check("given a new spot it sets down, then flies there", w.runs[3] == "fly land 850 71 -300", w.runs[3])
check("and the ride carries on from there", w.runs[4] == "fly land 1200 340" and w.runs[5] == "fly ferry home",
  tostring(w.runs[4]) .. " / " .. tostring(w.runs[5]))
check("none of that is a distress", #saidOfType(w, "unit.distress") == 0)

local hailT = F.request({ x = 812, y = 71, z = -344 }, { x = 1200, z = 340 }, "pocket-t", "alex")
w = run(drone({ name = "pad", cycles = 1, height = 90, inbox = { order(F.assign("j-t", hailT)) } }))
local stT = saidOfType(w, "job.state")
check("no new spot in two minutes: the job is dropped and charged",
  stT[#stT] and stT[#stT].state == "failed" and tostring(stT[#stT].detail):find("job dropped, fare charged", 1, true) ~= nil,
  stT[#stT] and stT[#stT].detail)
check("it sets down and goes home", w.runs[2] == "fly 102" and w.runs[3] == "fly ferry home", tostring(w.runs[3]))
check("after waiting the full two minutes", w.clock >= 120, w.clock)

print("a flight that fails")
local hailD = F.request({ x = 812, y = 71, z = -344 }, { x = 1200, z = 340 }, "pocket-d", "alex")
local hailD2 = F.request({ x = 900, y = 71, z = -344 }, { x = 1200, z = 340 }, "pocket-d2", "sam")
w = run(drone({ name = "pad", cycles = 1, fails = { [1] = true }, velocity = { x = 1, y = 0, z = 0 },
                inbox = { order(F.assign("j-d", hailD)), order(F.assign("j-e", hailD2)) } }))
local sos = saidOfType(w, "unit.distress")
check("it signals distress, with where it is", #sos >= 1 and sos[1].why == "pickup flight failed"
  and sos[1].x == 1892 and sos[1].z == 365, sos[1] and (sos[1].why .. " " .. tostring(sos[1].x)))
local stD = saidOfType(w, "job.state")
check("the customer hears the unit is down, and where", stD[#stD] and stD[#stD].state == "failed"
  and tostring(stD[#stD].detail):find("unit down at 1892", 1, true) ~= nil, stD[#stD] and stD[#stD].detail)
check("it does not try to fly home by itself", #w.runs == 1, #w.runs)
local tD = tlm(w)
check("every packet after reads sos", tD[#tD] and tD[#tD].phase == "sos", tD[#tD] and tD[#tD].phase)
local acksD = saidOfType(w, "job.ack")
check("and it takes no new customer until the base sends it somewhere",
  acksD[#acksD] and acksD[#acksD].ok == false and tostring(acksD[#acksD].why):find("unit down", 1, true) ~= nil,
  acksD[#acksD] and acksD[#acksD].why)

print("a unit already where the customer is")
local near = F.request({ x = 1890, y = 92, z = 366 }, { x = 1200, z = 340 }, "pocket-b", "alex")
near.board = true
w = run(drone({ name = "base_pad", cycles = 1,
                inbox = { order(F.assign("j-b", near)), order(F.go("j-b", "pocket-b2")) } }))
local stB = {}
for _, s in ipairs(saidOfType(w, "job.state")) do stB[#stB + 1] = s.state end
check("no pickup flight: on station at once, then the ride, then home",
  w.runs[1] == "fly land 1200 340" and table.concat(stB, " "):sub(1, 7) == "waiting", (w.runs[1] or "nothing") .. " / " .. table.concat(stB, " "))

print("the loading station's silos")
w = run(drone({ name = "base_pad", cycles = 1, stickers = { "Create_Sticker_0", "Create_Sticker_1" },
                inbox = { order(F.stick("load-1", { "Create_Sticker_0" }, true, "ops-s1")) } }))
local stk = saidOfType(w, "unit.stuck")
check("docked: the named sticker goes out, and only that one", w.stuckOut.Create_Sticker_0 == true
  and w.stuckOut.Create_Sticker_1 == false)
check("it answers sealed: stuck, for that load", #stk == 1 and stk[1].ok == true and stk[1].job == "load-1"
  and w.refused == 0, stk[1] and tostring(stk[1].why))
check("...saying what the sticker reports", stk[1] and tostring(stk[1].detail):find("Create_Sticker_0 out", 1, true) ~= nil,
  stk[1] and stk[1].detail)
check("nothing flies", #w.runs == 0)
w = run(drone({ velocity = { x = 2, y = 0, z = 0 }, cycles = 1, stickers = { "Create_Sticker_0" },
                inbox = { order(F.stick("load-2", { "Create_Sticker_0" }, true, "ops-s2")) } }))
stk = saidOfType(w, "unit.stuck")
check("not docked: refused, the sticker stays in", w.stuckOut.Create_Sticker_0 == false and stk[1]
  and stk[1].ok == false and stk[1].why == "not docked", stk[1] and stk[1].why)
w = run(drone({ name = "base_pad", cycles = 1, stickers = { "Create_Sticker_0" },
                inbox = { order(F.stick("load-3", { "modem_0" }, true, "ops-s3")) } }))
stk = saidOfType(w, "unit.stuck")
check("a name that is not a sticker is refused", stk[1] and stk[1].ok == false
  and tostring(stk[1].why):find("not a sticker", 1, true) ~= nil, stk[1] and stk[1].why)
w = run(drone({ name = "base_pad", cycles = 1, stickers = { "Create_Sticker_0" },
                inbox = { order(F.stick("load-4", { "Create_Sticker_0" }, true, "ops-s4")),
                          order(F.stick("load-4", { "Create_Sticker_0" }, false, "ops-s5")) } }))
stk = saidOfType(w, "unit.stuck")
check("unstick retracts it again", #stk == 2 and stk[2].ok == true and w.stuckOut.Create_Sticker_0 == false)
w = run(drone({ name = "base_pad", cycles = 1, stickers = { "Create_Sticker_0" },
                inbox = { { raw = true, msg = order(F.stick("load-5", { "Create_Sticker_0" }, true, "ops-s6")) } } }))
check("an unsealed stick order is not obeyed", w.stuckOut.Create_Sticker_0 == false and #saidOfType(w, "unit.stuck") == 0)

print("reporting what a delivery let go of")
w = run(drone({ name = "base_pad", cycles = 1, inbox = { order(F.flyCommand("deliver pier and market", "ops-d1")) },
                dropsOnRun = "Create_Sticker_0 100 80 50 1\nCreate_Sticker_1 20 80 30 0\n" }))
local dr = saidOfType(w, "unit.dropped")
check("after the flight each silo let go of goes to the base, sealed", #dr == 2 and dr[1].sticker == "Create_Sticker_0"
  and dr[1].ok == true and dr[1].x == 100 and dr[1].y == 80 and dr[1].z == 50 and w.refused == 0, #dr .. " sent")
check("a sticker still out afterwards is reported as still holding", dr[2] and dr[2].ok == false)
check("the file is cleared, and a copy kept on the drone", w.files[".drops"] == nil
  and tostring(w.files[".drops.log"]):find("Create_Sticker_1 20 80 30 0", 1, true) ~= nil)
w = run(drone({ name = "base_pad", files = { [".drops"] = "Create_Sticker_0 5 70 6 1\n" } }))
dr = saidOfType(w, "unit.dropped")
check("drops from a flight flown at the shell are reported when the beacon starts", #dr == 1 and dr[1].x == 5)
w = run(drone({ name = "base_pad", files = { [".drops"] = "garbage line\n" } }))
check("a line that is not a drop is not reported", #saidOfType(w, "unit.dropped") == 0)

print("refusals")
w = run(drone({ nokey = true }))
check("no key: nothing sent, says how", #w.sent == 0 and w.text:find("seckey set disk", 1, true) ~= nil)
w = run(drone({ noradio = true }))
check("no modem: says so", #w.sent == 0 and w.text:find("no wireless or ender modem", 1, true) ~= nil)

print("")
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then error("beacon tests failed", 0) end
