--- loader: the loading station's sequence, and how much one load can carry.
--
-- The station stands at a dock. For a load it puts silos (Create item vaults,
-- 3x1) down in the bays either side, waits while they fill, assembles each into
-- its own physics object, and - once the drone is latched on the dock - lifts
-- them up to it. The drone sticks them on, the lifter goes down, the drone
-- lifts off:
--
--   place -> fill -> assemble -> dock -> lift -> stick -> retract -> liftoff
--
-- Every machine action is ONE Redstone Relay face (or a face of this
-- computer). The drone's two actions go to it sealed, from ops; the station
-- never talks to a drone itself. A silo is filled while it is still a block,
-- so nothing is ever loaded onto the drone in place.
--
-- The station's own layout - which relay face does what, the waits, the
-- drone's sticker names - is station.lua on the base computer (not in the
-- repo; station.example.lua shows every field).
--
-- Pure: every relay, clock, inventory and radio call comes in through `io`,
-- so tools/test_loader.lua runs whole loads on the desktop.

local L = {}

local floor, ceil, min, max = math.floor, math.ceil, math.min, math.max

-- Create's vaultCapacity (default 20 stacks per vault block, Create config
-- CLogistics). A 3x1 silo is three blocks: 60 stacks, 3,840 of a 64-stack
-- item. station.lua's capacity overrides it if the server config differs.
L.STACKS_PER_BLOCK = 20
L.SILO_BLOCKS = 3
L.BAYS = { "left", "right" }
L.PULSE = 0.5          -- seconds a face is held for one action (10 ticks)
L.POLL = 1             -- seconds between looks while waiting on something
-- seconds after each action before the next; fill and dock are how long to
-- wait at most before the load is called off
L.WAIT = { place = 2, fill = 120, assemble = 2, dock = 300, lift = 3, stick = 2, retract = 3 }
L.STEPS = { "place", "fill", "assemble", "dock", "lift", "stick", "retract", "liftoff" }
L.ACTIONS = { place = true, assemble = true, lift = true, retract = true }

local function num(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end
local function str(v) return type(v) == "string" and v ~= "" end

local function isIO(t)
  return type(t) == "table" and str(t.side) and (t.relay == nil or str(t.relay))
end

--- An action's faces for the bays in use: a per-bay table gives one face per
-- bay, a single face is shared and fires once.
function L.facesFor(spec, sides)
  if spec == nil then return {} end
  if isIO(spec) then return { spec } end
  local out = {}
  for _, s in ipairs(sides) do if spec[s] then out[#out + 1] = spec[s] end end
  return out
end

--- Check station.lua. Returns a clean config, or nil and what is wrong.
function L.check(c)
  if type(c) ~= "table" then return nil, "station.lua must return a table" end
  local out = { dock = c.dock, liftoff = c.liftoff, single = c.single,
                pulse = num(c.pulse) and c.pulse or L.PULSE, wait = {}, stick = c.stick, fill = c.fill }
  if out.dock ~= nil and not str(out.dock) then return nil, "dock must be a place name" end
  if out.liftoff ~= nil and not str(out.liftoff) then return nil, "liftoff must be a fly command" end
  for k, v in pairs(L.WAIT) do
    local w = type(c.wait) == "table" and c.wait[k]
    out.wait[k] = num(w) and w >= 0 and w or v
  end
  if c.capacity ~= nil and not (num(c.capacity) and c.capacity >= 1) then
    return nil, "capacity is stacks per silo (60 for a 3x1 vault)"
  end
  out.capacity = c.capacity and floor(c.capacity) or L.STACKS_PER_BLOCK * L.SILO_BLOCKS

  for act in pairs(L.ACTIONS) do
    local spec = c[act]
    if spec ~= nil then
      if isIO(spec) then
        out[act] = spec
      elseif type(spec) == "table" then
        local per = {}
        for _, s in ipairs(L.BAYS) do
          if spec[s] ~= nil then
            if not isIO(spec[s]) then return nil, act .. "." .. s .. " needs { relay = ..., side = ... }" end
            per[s] = spec[s]
          end
        end
        if not next(per) then return nil, act .. " needs { relay = ..., side = ... } or left/right" end
        out[act] = per
      else
        return nil, act .. " needs { relay = ..., side = ... }"
      end
    end
  end
  if not out.place then return nil, "place needs a relay face (left and right, or one for both)" end
  if not out.lift then return nil, "lift needs a relay face" end

  -- the bays are the sides place can put a silo in
  out.bays = {}
  if isIO(out.place) then
    out.bays[1] = "left"
  else
    for _, s in ipairs(L.BAYS) do if out.place[s] then out.bays[#out.bays + 1] = s end end
  end
  if out.single ~= nil then
    local okS = false
    for _, s in ipairs(out.bays) do if s == out.single then okS = true end end
    if not okS then return nil, "single must be one of the bays place fills" end
  end

  -- the drone's stickers, by the names its computer sees them under
  local st = c.stick
  if str(st) then
    out.stick = { left = st }
  elseif type(st) == "table" then
    out.stick = {}
    for _, s in ipairs(L.BAYS) do if str(st[s]) then out.stick[s] = st[s] end end
  else
    return nil, "stick needs the drone's sticker names: { left = \"Create_Sticker_0\", ... }"
  end
  for _, s in ipairs(out.bays) do
    if not out.stick[s] then return nil, "stick has no sticker for the " .. s .. " bay" end
    if not out.stick[s]:match("^[%w_:%.%-]+$") then return nil, "bad sticker name " .. out.stick[s] end
  end

  -- where what went in is counted, for cargo.csv: each silo while it is still
  -- a block (a wired modem beside each bay), or else the intake it came from
  if c.silo ~= nil then
    if str(c.silo) then
      out.silo = { left = c.silo }
    elseif type(c.silo) == "table" then
      out.silo = {}
      for _, s in ipairs(L.BAYS) do if str(c.silo[s]) then out.silo[s] = c.silo[s] end end
    else
      return nil, "silo names the vault in each bay: { left = \"create:item_vault_0\", ... }"
    end
  end
  out.intake = (str(c.intake) and c.intake) or (type(c.fill) == "table" and str(c.fill.intake) and c.fill.intake) or nil

  -- how a fill is known to be done: a fixed time, the silos' own count, the
  -- intake emptying, or a signal (a threshold switch or comparator)
  local f = c.fill
  if type(f) ~= "table" then
    return nil, "fill needs a table: { secs = 30 } or { intake = \"minecraft:chest_0\" } ..."
  elseif num(f.secs) then
    out.fill = { secs = f.secs }
  elseif str(f.intake) or str(f.inv) or type(f.inv) == "table" then
    local inv = f.inv
    if str(inv) then inv = { inv } end
    out.fill = { intake = f.intake, inv = inv, settle = num(f.settle) and f.settle or 2 }
  elseif isIO(f.input) then
    out.fill = { input = f.input, level = num(f.level) and f.level or 1, settle = num(f.settle) and f.settle or 2 }
  else
    return nil, "fill needs secs, intake, inv or input"
  end
  return out
end

--- Stacks a load takes, from what an inventory holds: a list of
-- { count, max } per slot or per item, max being that item's stack size.
function L.stacksOf(list)
  local items, stacks = 0, 0
  for _, it in ipairs(list or {}) do
    local c, m = it.count or it[1], it.max or it[2] or 64
    if num(c) and c > 0 then
      items = items + c
      stacks = stacks + ceil(c / max(1, m))
    end
  end
  return items, stacks
end

--- The most this station can take of an item that stacks to `stack`.
function L.maxItems(cfg, stack)
  return cfg.capacity * (stack or 64) * #cfg.bays
end

--- How a load is carried: how many silos, which bays, about how much in
-- each. stacks may be given (from an inventory); otherwise it is items
-- divided by the stack size. nil and why when it does not fit.
function L.plan(cfg, items, stack, stacks)
  if not (num(items) and items >= 1) then return nil, "nothing to load" end
  items = floor(items)
  stack = (num(stack) and stack >= 1) and floor(stack) or 64
  stacks = (num(stacks) and stacks >= 1) and ceil(stacks) or ceil(items / stack)
  local silos = ceil(stacks / cfg.capacity)
  if silos > #cfg.bays then
    return nil, string.format("%d items is %d stacks: %d silos, and the station has %d (%d stacks, %d of a %d-stack item)",
      items, stacks, silos, #cfg.bays, cfg.capacity * #cfg.bays, L.maxItems(cfg, stack), stack)
  end
  local sides
  if silos == 1 then
    sides = { cfg.single or cfg.bays[1] }
  else
    sides = {}
    for i = 1, silos do sides[i] = cfg.bays[i] end
  end
  -- split evenly, so two silos weigh about the same either side of the drone
  local share = {}
  for i, s in ipairs(sides) do
    share[s] = floor(items / silos) + ((i <= items % silos) and 1 or 0)
  end
  local stickers = {}
  for _, s in ipairs(sides) do stickers[#stickers + 1] = cfg.stick[s] end
  return { items = items, stack = stack, stacks = stacks, silos = silos, sides = sides,
           share = share, stickers = stickers, capacity = cfg.capacity,
           full = floor(100 * stacks / (cfg.capacity * silos) + 0.5) }
end

local function describeIO(io)
  if not io then return "-" end
  local s = io.relay and (io.relay .. ":" .. io.side) or ("computer:" .. io.side)
  if io.hold then s = s .. " held" end
  if io.invert then s = s .. " inverted" end
  return s
end
L.describeIO = describeIO

--- The sequence as lines of text, with the waits: `ops load plan` and the dry
-- run print it.
function L.describe(cfg, plan)
  local lines = {}
  local function add(fmt, ...) lines[#lines + 1] = string.format(fmt, ...) end
  local function faces(act)
    local t = {}
    for _, io in ipairs(L.facesFor(cfg[act], plan.sides)) do t[#t + 1] = describeIO(io) end
    return #t > 0 and table.concat(t, ", ") or "(no relay)"
  end
  local f = cfg.fill
  local fill = f.secs and string.format("wait %gs", f.secs)
    or f.intake and string.format("until %d have left %s, max %gs", plan.items, f.intake, cfg.wait.fill)
    or f.inv and string.format("until %s hold %d, max %gs", table.concat(f.inv, "+"), plan.items, cfg.wait.fill)
    or string.format("until %s reads %d+, max %gs", describeIO(f.input), f.level, cfg.wait.fill)
  add("1 place     %s  %s, then %gs", table.concat(plan.sides, " + "), faces("place"), cfg.wait.place)
  add("2 fill      %s", fill)
  add("3 assemble  %s, then %gs", faces("assemble"), cfg.wait.assemble)
  add("4 dock      the drone latched%s, max %gs", cfg.dock and (" at " .. cfg.dock) or "", cfg.wait.dock)
  add("5 lift      %s, then %gs", faces("lift"), cfg.wait.lift)
  add("6 stick     drone extends %s, then %gs", table.concat(plan.stickers, " + "), cfg.wait.stick)
  add("7 retract   %s, then %gs", faces("retract"), cfg.wait.retract)
  add("8 liftoff   %s", cfg.liftoff and ("fly " .. cfg.liftoff) or "(none set - the drone stays, loaded)")
  return lines
end

-- ------------------------------------------------------------------ running

--- Every face station.lua names, once each, in a steady order.
function L.allFaces(cfg)
  local out, seen = {}, {}
  for _, act in ipairs({ "place", "assemble", "lift", "retract" }) do
    local spec = cfg[act]
    local list = isIO(spec) and { spec } or {}
    if not isIO(spec) and type(spec) == "table" then
      for _, s in ipairs(L.BAYS) do if spec[s] then list[#list + 1] = spec[s] end end
    end
    for _, io in ipairs(list) do
      local k = describeIO(io)
      if not seen[k] then seen[k] = true out[#out + 1] = io end
    end
  end
  return out
end

--- Run one load. io:
--   set(face, on) -> ok, why      drive a relay face (or this computer's side)
--   sleep(s)                      wait
--   now() -> seconds
--   count(inv) -> number|nil      items in an inventory
--   input(face) -> 0..15|nil      analog signal on a face
--   docked() -> bool, why         is the drone latched on the station's dock
--   stick(names) -> ok, why       the drone extends these stickers; returns
--                                 once it has answered
--   liftoff(args) -> ok, why      the drone flies this
--   say(step, text)               progress, for the screen
--   stopped() -> bool             optional: the operator called it off
--   beforeFill(plan)              optional: just before the fill (the intake
--                                 is counted here)
--   manifest(plan) -> m, how      optional: what is in the silos now, as
--                                 { [side] = { item = count } }, and how it
--                                 was counted. Kept as plan.manifest; silos
--                                 that count empty call the load off.
-- Returns ok, why, the step it ended on. Whatever happens, the relay faces
-- end at rest, and a lift that went up comes down again.
function L.run(cfg, plan, io)
  local held = {}          -- faces set and left on (hold = true) until the lift comes down
  local lifted = false
  local step = "start"
  local function say(text) if io.say then io.say(step, text) end end
  local function stopped() return io.stopped and io.stopped() end

  local function level(face, active)
    if face.invert then return not active end
    return active and true or false
  end
  local function drive(face, active)
    local ok, why = io.set(face, level(face, active))
    if ok == false then error({ why = "relay " .. describeIO(face) .. ": " .. tostring(why) }, 0) end
  end
  -- one action: each face on, held for the pulse, then off - or, for a held
  -- face, on until the lift comes down
  local function act(name)
    local faces = L.facesFor(cfg[name], plan.sides)
    for _, face in ipairs(faces) do
      drive(face, true)
      if face.hold then held[#held + 1] = face end
    end
    local pulse = 0
    for _, face in ipairs(faces) do
      if not face.hold then pulse = max(pulse, num(face.pulse) and face.pulse or cfg.pulse) end
    end
    if pulse > 0 then
      io.sleep(pulse)
      for _, face in ipairs(faces) do if not face.hold then drive(face, false) end end
    end
    return #faces
  end
  local function release()
    for i = #held, 1, -1 do pcall(drive, held[i], false) held[i] = nil end
  end
  local function pause(secs)
    local untilT = io.now() + secs
    while io.now() < untilT do
      if stopped() then error({ why = "stopped by the operator" }, 0) end
      io.sleep(min(L.POLL, untilT - io.now()))
    end
  end
  -- poll until done() says so, or give up after secs
  local function waitFor(secs, done, what)
    local untilT = io.now() + secs
    while true do
      local ok, note = done()
      if ok then return note end
      if stopped() then error({ why = "stopped by the operator" }, 0) end
      if io.now() >= untilT then error({ why = what .. " after " .. secs .. "s" .. (note and (" - " .. note) or "") }, 0) end
      io.sleep(L.POLL)
    end
  end
  local function countAll(list)
    local total = 0
    for _, inv in ipairs(list) do
      local n = io.count(inv)
      if not num(n) then return nil, inv .. " cannot be read" end
      total = total + n
    end
    return total
  end

  local function sequence()
    -- every face at rest first: an inverted face rests ON
    for _, face in ipairs(L.allFaces(cfg)) do drive(face, false) end

    step = "place"
    say(string.format("placing %d silo%s: %s", plan.silos, plan.silos == 1 and "" or "s", table.concat(plan.sides, " + ")))
    act("place")
    pause(cfg.wait.place)

    step = "fill"
    if io.beforeFill then io.beforeFill(plan) end
    local f = cfg.fill
    if f.secs then
      say(string.format("filling - %gs", f.secs))
      pause(f.secs)
    elseif f.intake or f.inv then
      local start
      if f.intake then
        start = io.count(f.intake)
        if not num(start) then error({ why = "the intake " .. f.intake .. " cannot be read" }, 0) end
      end
      say(string.format("filling %d items", plan.items))
      waitFor(cfg.wait.fill, function()
        if f.inv then
          local n, why = countAll(f.inv)
          if not n then return false, why end
          return n >= plan.items, string.format("%d of %d in", n, plan.items)
        end
        local n = io.count(f.intake)
        if not num(n) then return false, "intake unreadable" end
        return start - n >= plan.items, string.format("%d of %d moved", start - n, plan.items)
      end, "the silos did not fill")
      pause(f.settle)
    else
      say("filling - waiting for the full signal")
      waitFor(cfg.wait.fill, function()
        local v = io.input(f.input)
        return num(v) and v >= f.level, "signal " .. tostring(v)
      end, "no full signal")
      pause(f.settle)
    end

    -- count what went in while the silos are still blocks: after assembly
    -- they are physics objects and nothing can read them
    if io.manifest then
      local m, how = io.manifest(plan)
      if m then
        local total = 0
        for _, items in pairs(m) do for _, c in pairs(items) do total = total + c end end
        if total == 0 then error({ why = "the silos are empty (" .. tostring(how) .. ")" }, 0) end
        plan.manifest, plan.counted = m, how
        say(string.format("%d items in (%s)", total, tostring(how)))
      end
    end

    step = "assemble"
    say("assembling")
    act("assemble")
    pause(cfg.wait.assemble)

    step = "dock"
    say("waiting for the drone on the dock")
    waitFor(cfg.wait.dock, function() return io.docked() end, "no drone on the dock")

    step = "lift"
    say("lifting to the drone")
    lifted = true
    act("lift")
    pause(cfg.wait.lift)

    step = "stick"
    say("drone sticking " .. table.concat(plan.stickers, " + "))
    local okS, whyS = io.stick(plan.stickers)
    if not okS then error({ why = "the drone did not stick: " .. tostring(whyS) }, 0) end
    pause(cfg.wait.stick)

    step = "retract"
    say("lowering the lifter")
    act("retract")
    release()
    lifted = false
    pause(cfg.wait.retract)

    step = "liftoff"
    if cfg.liftoff then
      say("lift off: fly " .. cfg.liftoff)
      local okL, whyL = io.liftoff(cfg.liftoff)
      if not okL then error({ why = "the drone did not take the lift-off: " .. tostring(whyL) }, 0) end
    else
      say("loaded - no liftoff set, the drone stays")
    end
    step = "done"
  end

  local ok, err = pcall(sequence)
  if ok then return true, nil, "done" end
  local why = type(err) == "table" and err.why or tostring(err)
  local at = step
  -- leave it safe: the lift comes down (a silo that did not stick rides down
  -- with it), and nothing stays driven
  if lifted then
    pcall(act, "retract")
  end
  release()
  for _, face in ipairs(L.allFaces(cfg)) do pcall(drive, face, false) end
  if io.say then io.say(at, "called off: " .. why) end
  return false, why, at
end

return L
