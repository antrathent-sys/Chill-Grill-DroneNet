--- dockseq: a loading dock with two sides, A and B, each with four machines.
--
--   place     puts a silo down in the bay. It places on the FALLING edge
--             (Alex, 2026-09-24), so it is pulsed, and then given time to land
--   assemble  deploys a Physics Assembler and fires it: the silo becomes its
--             own physics object
--   belt      a funnel on a belt that runs one way or the other: into the
--             cargo, or out of it into this side's storage. It never STOPS,
--             so neither level is "off": the belt is held at the loading
--             level from the fill until the silo has gone with the drone
--             (anything else would pull the load straight back out while it
--             waits), and at the unloading level otherwise - harmless with
--             an empty bay, and what an unload wants. Every job sets it at
--             the START to suit the bay, whatever the last one left: a run
--             stopped with Ctrl+T once left a belt loading for an hour, and
--             the next load's items went into the bay before its fill began.
--             A job that fails leaves it loading only if a FILLED silo is
--             waiting, and at unloading otherwise.
--   pusher    lifts the silo up against the drone, and takes it back down
--
-- Two jobs, in Alex's order (2026-09-24):
--
--   LOAD    is there an empty silo on this side? if not: place, assemble.
--           fill it. once the drone is latched: pusher up, the drone
--           sticks, pusher down. The silo has gone with the drone.
--   UNLOAD  pusher up. the drone lets go. pusher down. empty the silo into
--           storage. An empty silo is now waiting on this side.
--
-- Whether a silo is in a bay is SEEN when the dock has a detector for that
-- side - a Create Avionics laser_sensor, whose power goes high when it sees
-- a silo and low when it does not - and remembered otherwise (io.silo),
-- because an assembled silo is not an inventory any more. With a detector
-- every step that should put a silo in the bay or take one out is checked:
-- placed and assembled means one is there, stuck and pushed back down means
-- it has gone with the drone, let go of means one has arrived. Memory is still
-- kept for what a detector cannot tell: whether the silo in the bay is empty
-- or full.
--
-- Filling and emptying are judged by the side's storage, which IS readable:
-- a fill is done when the load has left it (or it has stopped moving), an
-- empty is done when items have stopped arriving.
--
-- The layout is dock.lua in this machine's folder (machines/<label>/). Pure:
-- relays, clock, inventories and the drone come in through `io`, so
-- tools/test_dockseq.lua runs both jobs on the desktop.

local D = {}

D.SIDES = { "A", "B" }
D.DEVICES = { "place", "assemble", "belt", "pusher" }
-- seconds; every one of them can be set in dock.lua
D.WAIT = {
  pulse = 1,       -- how long a one-shot machine (the placer) is pulsed
  assemble_hold = 1,  -- how long the assembler is held on: it deploys an
                      -- assembler and then fires it, which takes time
  place = 3,       -- after the placer's pulse: time for the silo to land
  assemble = 4,    -- assembled: time for the physics object to settle
  push = 3,        -- pusher up: time to reach the drone
  retract = 3,     -- pusher down
  step = 1,        -- a breath between steps
}
D.FILL = { settle = 5, start = 20, max = 180 }    -- s: still for this long = done;
D.EMPTY = { settle = 5, start = 20, max = 240 }   -- nothing at all by `start` = stuck
D.POLL = 1

local function str(v) return type(v) == "string" and v ~= "" end
local function num(v) return type(v) == "number" and v == v and v >= 0 end

--- Check dock.lua. Returns a clean layout, or nil and what is wrong.
function D.check(c)
  if type(c) ~= "table" then return nil, "dock.lua must return a table" end
  if type(c.sides) ~= "table" then return nil, "dock.lua needs sides = { A = { ... }, B = { ... } }" end
  local out = { sides = {}, storage = {}, wait = {}, fill = {}, empty = {} }
  for _, side in ipairs(D.SIDES) do
    local s = c.sides[side]
    if s ~= nil then
      if type(s) ~= "table" then return nil, "side " .. side .. " must be a table" end
      local o = {}
      for _, dev in ipairs(D.DEVICES) do
        if s[dev] ~= nil then
          if not str(s[dev]) then return nil, side .. "." .. dev .. " must be a relay name" end
          o[dev] = s[dev]
        end
      end
      -- what ON does to this side's belt, when it differs from the dock's
      if s.belt_on ~= nil and s.belt_on ~= "fills" and s.belt_on ~= "empties" then
        return nil, side .. ".belt_on is \"fills\" or \"empties\""
      end
      o.belt_on = s.belt_on
      -- this side's own storage, when it has one (a name or a list); else the
      -- dock's, counted together
      if s.storage ~= nil then
        local list = type(s.storage) == "table" and s.storage or { s.storage }
        o.storage = {}
        for _, inv in ipairs(list) do
          if not str(inv) then return nil, side .. ".storage must be an inventory's name" end
          o.storage[#o.storage + 1] = inv
        end
      end
      if not o.pusher then return nil, "side " .. side .. " needs a pusher" end
      out.sides[side] = o
    end
  end
  if not next(out.sides) then return nil, "dock.lua names no side" end
  for _, inv in ipairs(type(c.storage) == "table" and c.storage or {}) do
    if str(inv) then out.storage[#out.storage + 1] = inv end
  end
  -- what ON does to a belt: it fills the cargo, or empties it into storage
  if c.belt_on ~= nil and c.belt_on ~= "fills" and c.belt_on ~= "empties" then
    return nil, "belt_on is \"fills\" or \"empties\""
  end
  out.belt_on = c.belt_on
  for _, o in pairs(out.sides) do o.belt_on = o.belt_on or c.belt_on end
  -- a detector per side: a laser_sensor's name. silo_when says which power
  -- means a silo is there: "high" (Alex's dock, 2026-09-24: the sensor goes
  -- low when there is no silo) or "low". "hit" and "blocked" still work, as
  -- the same two
  out.detect = {}
  if c.detect ~= nil then
    if type(c.detect) ~= "table" then return nil, "detect = { A = \"laser_sensor_0\", B = ... }" end
    for _, side in ipairs(D.SIDES) do
      if c.detect[side] ~= nil then
        if not str(c.detect[side]) then return nil, "detect." .. side .. " must be a sensor's name" end
        out.detect[side] = c.detect[side]
      end
    end
  end
  local when = ({ high = "high", low = "low", hit = "high", blocked = "low" })[c.silo_when or "high"]
  if not when then return nil, "silo_when is \"high\" or \"low\"" end
  out.silo_when = when
  -- watch: read and log the sensors, but go by memory and never stop a job
  -- on them - for while what a state reads is still being found out. true
  -- watches every check; a list of steps ({ "assemble", "retract" })
  -- watches only those and lets the sensor decide the rest.
  if type(c.watch) == "table" then
    out.watch = {}
    for _, step in ipairs(c.watch) do if str(step) then out.watch[step] = true end end
  else
    out.watch = c.watch and true or false
  end
  for k, v in pairs(D.WAIT) do out.wait[k] = (type(c.wait) == "table" and num(c.wait[k])) and c.wait[k] or v end
  for k, v in pairs(D.FILL) do out.fill[k] = (type(c.fill) == "table" and num(c.fill[k])) and c.fill[k] or v end
  for k, v in pairs(D.EMPTY) do out.empty[k] = (type(c.empty) == "table" and num(c.empty[k])) and c.empty[k] or v end
  return out
end

--- Every relay dock.lua names, once each: put at rest before and after a
-- job. Not the belts - a belt has no rest, only a direction - unless asked.
function D.relays(cfg, withBelts)
  local out, seen = {}, {}
  for _, side in ipairs(D.SIDES) do
    local s = cfg.sides[side]
    if s then
      for _, dev in ipairs(D.DEVICES) do
        if s[dev] and not seen[s[dev]] and (withBelts or dev ~= "belt") then
          seen[s[dev]] = true
          out[#out + 1] = s[dev]
        end
      end
    end
  end
  return out
end

--- A side's belt level for "fill" or "empty": ON, OFF, or nil when that belt
-- is not mapped or its direction is not known (then it is left as it is).
function D.beltFor(cfg, want, side)
  local s = side and cfg.sides[side]
  local on = s and s.belt_on or cfg.belt_on
  if not on or (s and not s.belt) then return nil end
  return on == (want == "fill" and "fills" or "empties")
end

-- ------------------------------------------------------------------ running

-- io:
--   set(relay, on) -> ok, why       drive a relay (every face)
--   sleep(s), now()
--   count(side) -> number|nil       items in that side's storage (or the
--                                   dock's, when the side has none of its own)
--   drone(step) -> ok, why          the drone's part: "dock" (latched here),
--                                   "stick", "release". Test mode asks a
--                                   person; a depot asks the base.
--   silo(side[, state]) -> state    "empty" (an assembled silo waiting),
--                                   "full", or "none"; with state, remembers it
--   present(side) -> true|false|nil what the side's detector sees: a silo in
--                                   the bay, none, or nil (no detector, or it
--                                   could not be read)
--   say(step, text), stopped() -> bool
local function runner(cfg, side, io)
  local s = cfg.sides[side]
  if not s then error({ why = "this dock has no side " .. tostring(side) }, 0) end
  local r = { step = "start", up = false }
  function r.say(text) if io.say then io.say(r.step, text) end end
  function r.set(relay, on)
    if not relay then return end
    local ok, why = io.set(relay, on)
    if ok == false then error({ why = relay .. ": " .. tostring(why) }, 0) end
  end
  function r.pause(secs)
    local untilT = io.now() + (secs or 0)
    while io.now() < untilT do
      if io.stopped and io.stopped() then error({ why = "stopped by the operator" }, 0) end
      io.sleep(math.min(D.POLL, untilT - io.now()))
    end
  end
  function r.pulse(relay, hold)
    r.set(relay, true)
    r.pause(hold or cfg.wait.pulse)
    r.set(relay, false)
  end
  function r.pusher(up)
    r.set(s.pusher, up)
    r.up = up
    r.pause(up and cfg.wait.push or cfg.wait.retract)
  end
  function r.drone(what)
    local ok, why = io.drone(what)
    if not ok then error({ why = "the drone: " .. tostring(why or (what .. " did not happen")) }, 0) end
  end
  -- watch the storage until it settles; want = items expected to move (or nil)
  function r.watch(t, want, dir)
    local startN = io.count and io.count(side)
    if not startN then
      r.say("no storage to watch - waiting " .. t.max .. " s")
      r.pause(t.max)
      return nil
    end
    local last, lastT, moved = startN, io.now(), false
    local t0 = io.now()
    while true do
      r.pause(D.POLL)
      local n = io.count(side)
      if n and n ~= last then last, lastT, moved = n, io.now(), true end
      local done = (dir < 0 and startN - (n or last) or (n or last) - startN)
      if want and done >= want then return done end
      if moved and io.now() - lastT >= t.settle then return done end
      if not moved and io.now() - t0 >= t.start then
        error({ why = string.format("nothing moved in %d s - is there anything to move?", t.start) }, 0)
      end
      if io.now() - t0 >= t.max then return done end
    end
  end
  -- what the detector says, or nil when this side has none. A side that HAS
  -- one which cannot be read stops the job: falling back to memory is how a
  -- load once filled toward an empty bay (2026-09-24) - the sensor's name did
  -- not match, memory said a silo was waiting, and nothing said otherwise.
  -- is this step's sensor check only watched?
  function r.watching()
    return cfg.watch == true or (type(cfg.watch) == "table" and cfg.watch[r.step] == true)
  end
  function r.read()
    if not io.present then return nil end
    return io.present(side)
  end
  function r.seen()
    local name = cfg.detect and cfg.detect[side]
    local got, said = r.read()
    -- said once, and again only when it changes: a check looks five times
    local line = (got ~= nil and said) and string.format("sensor: %s - %s", said, got and "a silo" or "no silo") or nil
    if line and line ~= r.lastSensor then r.say(line) end
    r.lastSensor = line or r.lastSensor
    if r.watching() then return nil end      -- watching only: memory decides
    if name and got == nil then
      error({ why = string.format("the silo sensor for side %s (%s) cannot be read - check its name with depot probe",
        side, name) }, 0)
    end
    return got
  end
  -- insist on it, where a detector can tell: wanted = true (a silo must be in
  -- the bay) or false (it must have gone); a few looks, as a silo settles
  function r.expect(wanted, why)
    if r.watching() then
      -- watching only: say what was expected and what the sensor made of it
      local got, said = r.read()
      if got ~= nil then
        r.say(string.format("watch: expected %s, sensor %s - %s", wanted and "a silo" or "no silo", tostring(said),
          got == wanted and "agrees" or "DISAGREES"))
      end
      return
    end
    if r.seen() == nil then return end
    for _ = 1, 5 do
      if r.seen() == wanted then return end
      r.pause(D.POLL)
    end
    error({ why = why }, 0)
  end
  function r.rest()
    for _, relay in ipairs(D.relays(cfg)) do pcall(io.set, relay, false) end
  end
  return r, s
end

-- a job, with the dock left safe whatever happens: pusher down, all at rest
-- the belt for a side given what is in its bay: loading only keeps a filled
-- silo filled; anything else rests at unloading
local function beltFor(cfg, side, keepFull)
  return D.beltFor(cfg, keepFull and "fill" or "empty", side)
end

local function job(cfg, side, io, body, kind)
  if not cfg.sides[side] then
    local why = "this dock has no side " .. tostring(side)
    if io.say then io.say("start", "called off: " .. why) end
    return false, why, "start"
  end
  local r = runner(cfg, side, io)
  r.rest()
  local ok, err = pcall(body, r)
  if ok then return true, nil, "done", err end
  local why = type(err) == "table" and err.why or tostring(err)
  local at = r.step
  if r.up then pcall(io.set, cfg.sides[side].pusher, false) end
  r.rest()
  local s = cfg.sides[side]
  local lvl = s.belt and beltFor(cfg, side, kind == "load" and io.silo(side) == "full")
  if lvl ~= nil and s.belt then pcall(io.set, s.belt, lvl) end
  if io.say then io.say(at, "called off: " .. why) end
  return false, why, at
end

--- LOAD one side. items: how many are going (for the fill to know when it
-- is done), or nil to fill until the storage stops moving. Returns ok, why,
-- the step it ended on, and how many items left the storage.
function D.load(cfg, side, io, items)
  return job(cfg, side, io, function(r)
    local s = cfg.sides[side]
    r.step = "silo"
    local have = io.silo(side)
    local seen = r.seen()
    if seen == true and have == "none" then have = "empty" end     -- one is there, whatever memory said
    if seen == false and have ~= "none" then have = "none" end     -- nothing there, whatever memory said
    -- the belt to suit the bay before anything else moves
    local startLevel = beltFor(cfg, side, have == "full")
    if startLevel ~= nil then r.set(s.belt, startLevel) end
    if have == "full" then
      r.say("a filled silo is already waiting on side " .. side)
    elseif have == "empty" then
      r.say("an empty silo is waiting on side " .. side)
    else
      if not (s.place and s.assemble) then error({ why = "no silo here, and no placer or assembler to make one" }, 0) end
      r.step = "place"
      r.say("placing a silo on side " .. side)
      r.pulse(s.place)                 -- it places as the signal FALLS
      r.pause(cfg.wait.place)          -- then time for the silo to land
      r.expect(true, "a silo was placed but the detector does not see one in the bay")
      r.step = "assemble"
      r.say("assembling it")
      r.pulse(s.assemble, cfg.wait.assemble_hold)   -- held long enough to deploy and fire
      r.pause(cfg.wait.assemble)
      r.expect(true, "after assembling, the detector no longer sees the silo")
      io.silo(side, "empty")
    end

    -- the belt goes to loading and stays there until the silo has gone: at
    -- the other level it would pull the load back out while it waits
    r.expect(true, "no silo in the bay to fill - nothing will be loaded toward an empty bay")
    local fillLevel = D.beltFor(cfg, "fill", side)
    if fillLevel ~= nil then r.set(s.belt, fillLevel) end
    local moved
    if have ~= "full" then
    r.step = "fill"
    r.say(items and string.format("filling %d items", items) or "filling until the storage stops moving")
    moved = r.watch(cfg.fill, items, -1)
    r.say(moved and string.format("%d items in", moved) or "filled")
    io.silo(side, "full")
    r.pause(cfg.wait.step)
    end

    r.step = "dock"
    r.say("waiting for the drone to latch")
    r.drone("dock")

    r.step = "push"
    r.say("pusher up")
    r.pusher(true)
    r.step = "stick"
    r.say("the drone sticks the silo")
    r.drone("stick")
    r.step = "retract"
    r.say("pusher down")
    r.pusher(false)
    r.expect(false, "the silo is still in the bay - the drone did not take it")
    io.silo(side, "none")        -- it went with the drone
    -- an empty bay: the belt back to unloading, its harmless level
    local idle = D.beltFor(cfg, "empty", side)
    if idle ~= nil then r.set(s.belt, idle) end
    r.step = "done"
    r.say("loaded - side " .. side .. " has no silo now")
    return moved
  end, "load")
end

--- UNLOAD one side: take a silo off the drone and empty it into storage.
-- expect: items it should hold (from the cargo ledger), or nil.
function D.unload(cfg, side, io, expect)
  return job(cfg, side, io, function(r)
    local s = cfg.sides[side]
    local seen = r.seen()
    if seen == true or (seen == nil and io.silo(side) ~= "none") then
      error({ why = "side " .. side .. " already has a silo in the bay - load it, or clear it first" }, 0)
    end
    local startLevel = beltFor(cfg, side, false)
    if startLevel ~= nil then r.set(s.belt, startLevel) end
    r.step = "push"
    r.say("pusher up, under the drone's silo")
    r.pusher(true)
    r.step = "release"
    r.say("the drone lets go")
    r.drone("release")
    r.step = "retract"
    r.say("pusher down")
    r.pusher(false)
    r.expect(true, "the drone let go but no silo arrived in the bay")
    io.silo(side, "full")

    r.step = "empty"
    local emptyLevel = D.beltFor(cfg, "empty", side)
    if emptyLevel ~= nil then r.set(s.belt, emptyLevel) end
    r.say(expect and string.format("emptying %d items into storage", expect) or "emptying into storage")
    local moved = r.watch(cfg.empty, expect, 1)
    io.silo(side, "empty")
    r.step = "done"
    r.say(string.format("%s - an empty silo is waiting on side %s", moved and (moved .. " items out") or "emptied", side))
    return moved
  end, "unload")
end

return D
