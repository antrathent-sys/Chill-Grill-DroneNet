--- devices: the base's controllable and readable things, and their honest state.
--
-- The list lives in devices.lua on the base computer - not in the repo, it is
-- per base; devices.example.lua shows every kind. Each entry has a plain
-- `name` (letters, digits, - and _), an optional display `label`, and a `kind`:
--
--   output       a redstone signal: lights, alarms, simple doors. `out` is where
--                it is driven: { side = "back" } on this computer, or
--                { relay = "redstone_relay_0", side = "top" } on a Redstone
--                Relay (whose face can feed a Create Redstone Link). Optional
--                `status` is where its real state is read back the same way -
--                a Redstone Contact, a sensor, a returning link - with
--                invert = true when the signal means OFF. labels = { "OPEN",
--                "CLOSED" } renames ON and OFF.
--   gearshift    a Create Sequenced Gearshift moving a door or lift `travel`
--                blocks (unit = "angle" for degrees). Open runs forward, close
--                runs back (Create's speed modifier 1 / -1, or 2 / -2 with
--                fast = true). Optional `closed` is a contact reading true when
--                fully closed.
--   speed        a Create Rotation Speed Controller, clamped to `max` RPM
--                (default 256); optional `gauge` is a Speedometer on the driven
--                shaft that proves it turns.
--   stress       a Create Stressometer: SU used against capacity (warn at 80%).
--   speedometer  a Create Speedometer.
--   energy       anything with getEnergy/getEnergyCapacity (warn below 20%).
--   fluid        anything with tanks(); `capacity` in mB for a percentage.
--   items        anything with list/size: vaults, chests (warn at 90% of slots).
--   level        a 0-15 signal strength read back through `input`.
--
-- Every state has a short `text`, a `level` (ok, info, warn, fault), and for
-- readings a `value` and `max`. Nothing is invented: an output with no
-- read-back says "ON (SET)", a gearshift never driven says UNKNOWN, a
-- peripheral that is not there is MISSING, and a read-back that disagrees with
-- the command for longer than DV.SETTLE seconds is a FAULT.
--
-- Pure: peripheral, redstone and file access come in through
-- ctx = { P = peripheral, R = redstone, fs = fs }, so tools/test_devices.lua
-- runs all of it on the desktop.

local DV = {}

local floor, max, min, abs = math.floor, math.max, math.min, math.abs

DV.SETTLE = 3            -- seconds a read-back may lag its command
DV.TIMEOUT = 30          -- seconds a gearshift may run before it is JAMMED
DV.START_GRACE = 1       -- seconds a gearshift gets to start running after a command
DV.STATE_FILE = ".devstate"

DV.KINDS = {
  output = true, gearshift = true, speed = true, stress = true, speedometer = true,
  energy = true, fluid = true, items = true, level = true,
}
DV.ACTIONS = {
  output = { "on", "off", "toggle", "open", "close" },
  gearshift = { "open", "close" },
  speed = { "speed", "stop" },
}

-- ----------------------------------------------------------------- the list

local function isIO(t)
  return type(t) == "table" and type(t.side) == "string" and (t.relay == nil or type(t.relay) == "string")
end

local function num(v) return type(v) == "number" and v == v and v or nil end

--- Check one entry. Returns a clean device, or nil and why not.
function DV.check(e)
  if type(e) ~= "table" then return nil, "not a table" end
  local name = type(e.name) == "string" and (e.name:lower():gsub("%s+", "")) or ""
  if name == "" or not name:match("^[%w_%-]+$") then
    return nil, "a device needs a plain name (letters, digits, - and _)"
  end
  local kind = e.kind
  if not DV.KINDS[kind] then return nil, name .. ": unknown kind " .. tostring(kind) end
  local d = { name = name, kind = kind, label = (type(e.label) == "string" and e.label or e.name):upper() }

  if kind == "output" then
    if not isIO(e.out) then return nil, name .. ": needs out = { side = ... } (relay optional)" end
    if e.status ~= nil and not isIO(e.status) then return nil, name .. ": status needs { side = ... }" end
    d.out, d.status = e.out, e.status
    d.onText, d.offText = "ON", "OFF"
    if type(e.labels) == "table" and type(e.labels[1]) == "string" and type(e.labels[2]) == "string" then
      d.onText, d.offText = e.labels[1]:upper(), e.labels[2]:upper()
    end
  elseif kind == "level" then
    if not isIO(e.input) then return nil, name .. ": needs input = { side = ... } (relay optional)" end
    d.input = e.input
  else
    if type(e.periph) ~= "string" then return nil, name .. ": needs periph = \"<peripheral name>\"" end
    d.periph = e.periph
    d.warn = num(e.warn)
    if kind == "gearshift" then
      if not num(e.travel) or e.travel <= 0 then return nil, name .. ": needs travel > 0" end
      if e.closed ~= nil and not isIO(e.closed) then return nil, name .. ": closed needs { side = ... }" end
      d.travel, d.closed = floor(e.travel + 0.5), e.closed
      d.unit = e.unit == "angle" and "angle" or "distance"
      d.fast = e.fast == true
      d.timeout = num(e.timeout) or DV.TIMEOUT
    elseif kind == "speed" then
      if e.gauge ~= nil and type(e.gauge) ~= "string" then return nil, name .. ": gauge must be a peripheral name" end
      d.gauge, d.max = e.gauge, num(e.max) or 256
    elseif kind == "fluid" then
      d.capacity = num(e.capacity)
    end
  end
  return d
end

--- A list of entries -> good devices in order, plus complaints about the rest.
function DV.parse(t)
  local list, bad, seen = {}, {}, {}
  if type(t) ~= "table" then return list, { "the devices file did not return a table" } end
  for i, e in ipairs(t) do
    local d, why = DV.check(e)
    if not d then
      bad[#bad + 1] = string.format("entry %d: %s", i, why)
    elseif seen[d.name] then
      bad[#bad + 1] = d.name .. " is listed twice - keeping the first"
    else
      seen[d.name] = true
      list[#list + 1] = d
    end
  end
  return list, bad
end

--- Read devices.lua. It runs with no environment, so it can only describe
-- devices. No file is an empty list, not an error.
function DV.load(path, fsys)
  if not (fsys and fsys.exists(path)) then return {}, {} end
  local f = fsys.open(path, "r")
  if not f then return {}, { "could not open " .. path } end
  local text = f.readAll() or ""
  f.close()
  local chunk, err
  if setfenv then
    chunk, err = (loadstring or load)(text, "devices")
    if chunk then setfenv(chunk, {}) end
  else
    chunk, err = load(text, "devices", "t", {})
  end
  if not chunk then return {}, { path .. ": " .. tostring(err) } end
  local ok, t = pcall(chunk)
  if not ok then return {}, { path .. ": " .. tostring(t) } end
  return DV.parse(t)
end

--- A bank: the devices plus what each was last told and how each is now.
function DV.bank(list)
  local b = { list = list, by = {}, run = {}, state = {} }
  for _, d in ipairs(list) do
    b.by[d.name] = d
    b.run[d.name] = {}
  end
  return b
end

-- ---------------------------------------------------------------------- io

local function present(ctx, name) return ctx.P.isPresent(name) end

-- call a peripheral method: value, or nil and why
local function pcallP(ctx, name, method, ...)
  if not present(ctx, name) then return nil, name .. " missing" end
  local ok, v = pcall(ctx.P.call, name, method, ...)
  if not ok then return nil, tostring(v) end
  return v
end

local function ioWrite(ctx, io, on)
  if io.relay then
    if not present(ctx, io.relay) then return false, io.relay .. " missing" end
    return pcall(ctx.P.call, io.relay, "setOutput", io.side, on)
  end
  return pcall(ctx.R.setOutput, io.side, on)
end

local function ioRead(ctx, io, analog)
  local method = analog and "getAnalogInput" or "getInput"
  if io.relay then return pcallP(ctx, io.relay, method, io.side) end
  local ok, v = pcall(ctx.R[method], io.side)
  if not ok then return nil, tostring(v) end
  return v
end

-- --------------------------------------------------------------- formatting

function DV.short(n)
  n = tonumber(n) or 0
  local a = abs(n)
  if a >= 1e9 then return string.format("%.1fB", n / 1e9) end
  if a >= 1e6 then return string.format("%.1fM", n / 1e6) end
  if a >= 1e5 then return string.format("%.0fk", n / 1e3) end
  if a >= 1e3 then return string.format("%.1fk", n / 1e3) end
  return tostring(floor(n + 0.5))
end

local function S(text, level, value, maxv, detail)
  return { text = text, level = level, value = value, max = maxv, detail = detail }
end

-- --------------------------------------------------------------- the kinds

local POLL = {}

function POLL.output(d, r, ctx, now)
  if d.out.relay and not present(ctx, d.out.relay) then return S("MISSING", "fault", nil, nil, d.out.relay .. " missing") end
  if not d.status then
    if r.set == nil then return S("NOT SET", "info") end
    return S((r.set and d.onText or d.offText) .. " (SET)", "info")
  end
  local v, err = ioRead(ctx, d.status)
  if v == nil then return S("MISSING", "fault", nil, nil, err) end
  local on = (v == true) ~= (d.status.invert == true)
  local txt = on and d.onText or d.offText
  if r.set ~= nil and on ~= r.set then
    if now - (r.setAt or -1e9) < DV.SETTLE then return S("SWITCHING", "info") end
    return S("FAULT", "fault", nil, nil, "set " .. (r.set and d.onText or d.offText) .. ", reads " .. txt)
  end
  return S(txt, "ok")
end

function POLL.gearshift(d, r, ctx, now)
  local running, err = pcallP(ctx, d.periph, "isRunning")
  if running == nil then return S("MISSING", "fault", nil, nil, err) end
  local starting = r.moveAt and now - r.moveAt < DV.START_GRACE
  if running or starting then
    if r.moveAt and now - r.moveAt > d.timeout then
      return S("JAMMED", "fault", nil, nil, "still running after " .. d.timeout .. " s")
    end
    return S(r.target == "open" and "OPENING" or (r.target == "closed" and "CLOSING" or "MOVING"), "info")
  end
  if r.moveAt then
    r.pos, r.target, r.moveAt = r.target, nil, nil
    ctx.dirty = true
  end
  if d.closed then
    local v, e2 = ioRead(ctx, d.closed)
    if v == nil then return S("MISSING", "fault", nil, nil, e2) end
    local isClosed = (v == true) ~= (d.closed.invert == true)
    if r.pos == "closed" and not isClosed then return S("FAULT", "fault", nil, nil, "should be closed, contact open") end
    if r.pos == "open" and isClosed then return S("FAULT", "fault", nil, nil, "should be open, contact closed") end
    return S(isClosed and "CLOSED" or "OPEN", "ok")
  end
  if r.pos == nil then return S("UNKNOWN", "warn", nil, nil, "never driven here - close it once to set it") end
  return S(r.pos == "open" and "OPEN" or "CLOSED", "info")
end

function POLL.speed(d, r, ctx, now)
  local target, err = pcallP(ctx, d.periph, "getTargetSpeed")
  if target == nil then return S("MISSING", "fault", nil, nil, err) end
  local txt = string.format("%d RPM", floor(target + 0.5))
  if not d.gauge then return S(txt, target == 0 and "info" or "ok", abs(target), d.max) end
  local actual, e2 = pcallP(ctx, d.gauge, "getSpeed")
  if actual == nil then return S("MISSING", "fault", abs(target), d.max, e2) end
  if target ~= 0 and abs(actual) < 0.5 then
    if now - (r.setAt or -1e9) < DV.SETTLE then return S(txt, "info", abs(target), d.max, "spinning up") end
    return S("STALLED", "fault", abs(target), d.max, "set " .. txt .. ", shaft reads 0")
  end
  return S(string.format("%d RPM", floor(abs(actual) + 0.5)), target == 0 and "info" or "ok", abs(actual), d.max)
end

function POLL.stress(d, r, ctx)
  local used, err = pcallP(ctx, d.periph, "getStress")
  if used == nil then return S("MISSING", "fault", nil, nil, err) end
  local cap = pcallP(ctx, d.periph, "getStressCapacity") or 0
  local txt = DV.short(used) .. "/" .. DV.short(cap) .. " SU"
  if cap > 0 and used > cap then return S("OVERSTRESSED", "fault", used, cap, txt) end
  local pct = cap > 0 and used / cap * 100 or 0
  return S(txt, pct >= (d.warn or 80) and "warn" or "ok", used, cap)
end

function POLL.speedometer(d, r, ctx)
  local v, err = pcallP(ctx, d.periph, "getSpeed")
  if v == nil then return S("MISSING", "fault", nil, nil, err) end
  return S(string.format("%d RPM", floor(abs(v) + 0.5)), abs(v) < 0.5 and "info" or "ok", abs(v))
end

function POLL.energy(d, r, ctx)
  local e, err = pcallP(ctx, d.periph, "getEnergy")
  if e == nil then return S("MISSING", "fault", nil, nil, err) end
  local cap = pcallP(ctx, d.periph, "getEnergyCapacity") or 0
  local pct = cap > 0 and e / cap * 100 or 0
  return S(string.format("%d%% %sFE", floor(pct + 0.5), DV.short(e)), pct < (d.warn or 20) and "warn" or "ok", e, cap)
end

function POLL.fluid(d, r, ctx)
  local tanks, err = pcallP(ctx, d.periph, "tanks")
  if tanks == nil then return S("MISSING", "fault", nil, nil, err) end
  local amount = 0
  for _, t in pairs(tanks) do amount = amount + (tonumber(t.amount) or 0) end
  if not d.capacity then return S(DV.short(amount) .. " mB", "ok", amount) end
  local pct = amount / d.capacity * 100
  return S(string.format("%d%% %s mB", floor(pct + 0.5), DV.short(amount)), pct < (d.warn or 0) and "warn" or "ok",
    amount, d.capacity)
end

function POLL.items(d, r, ctx)
  local list, err = pcallP(ctx, d.periph, "list")
  if list == nil then return S("MISSING", "fault", nil, nil, err) end
  local size = pcallP(ctx, d.periph, "size") or 0
  local used, count = 0, 0
  for _, it in pairs(list) do
    used = used + 1
    count = count + (tonumber(it.count) or 0)
  end
  local pct = size > 0 and used / size * 100 or 0
  return S(string.format("%s ITEMS %d/%d", DV.short(count), used, size), pct >= (d.warn or 90) and "warn" or "ok",
    used, size)
end

function POLL.level(d, r, ctx)
  local v, err = ioRead(ctx, d.input, true)
  if v == nil then return S("MISSING", "fault", nil, nil, err) end
  return S(tostring(v) .. "/15", "ok", v, 15)
end

--- Read every device once. Returns bank.state (name -> state).
function DV.poll(bank, ctx, now)
  for _, d in ipairs(bank.list) do
    local ok, st = pcall(POLL[d.kind], d, bank.run[d.name], ctx, now)
    bank.state[d.name] = ok and st or S("ERROR", "fault", nil, nil, tostring(st))
  end
  if ctx.dirty then DV.saveState(bank, ctx) end
  return bank.state
end

-- ----------------------------------------------------------------- commands

local function allowed(kind, action)
  for _, a in ipairs(DV.ACTIONS[kind] or {}) do
    if a == action then return true end
  end
  return false
end

--- Tell a device to do something. Returns ok and a message for a person.
function DV.command(bank, ctx, name, action, arg, now)
  local d = bank.by[type(name) == "string" and name:lower() or ""]
  if not d then return false, "no device called " .. tostring(name) end
  if not DV.ACTIONS[d.kind] then return false, d.label .. " is a reading - it takes no commands" end
  action = tostring(action or ""):lower()
  if not allowed(d.kind, action) then
    return false, d.label .. " takes: " .. table.concat(DV.ACTIONS[d.kind], ", ")
  end
  local r = bank.run[d.name]

  if d.kind == "output" then
    local want
    if action == "toggle" then want = not r.set else want = (action == "on" or action == "open") end
    local ok, err = ioWrite(ctx, d.out, want)
    if not ok then return false, d.label .. ": " .. tostring(err) end
    r.set, r.setAt = want, now
    DV.saveState(bank, ctx)
    return true, d.label .. " " .. (want and d.onText or d.offText)

  elseif d.kind == "gearshift" then
    local target = action == "open" and "open" or "closed"
    local running, err = pcallP(ctx, d.periph, "isRunning")
    if running == nil then return false, d.label .. ": " .. tostring(err) end
    if running or (r.moveAt and now - r.moveAt < DV.START_GRACE) then
      return false, d.label .. " is still moving - wait for it"
    end
    local where = r.pos
    if d.closed then
      local v = ioRead(ctx, d.closed)
      if v ~= nil then where = ((v == true) ~= (d.closed.invert == true)) and "closed" or "open" end
    end
    if where == target then return false, d.label .. " is already " .. target:upper() end
    local modifier = (target == "open" and 1 or -1) * (d.fast and 2 or 1)
    local okc, cerr = pcall(ctx.P.call, d.periph, d.unit == "angle" and "rotate" or "move", d.travel, modifier)
    if not okc then return false, d.label .. ": " .. tostring(cerr) end
    r.target, r.moveAt = target, now
    DV.saveState(bank, ctx)
    return true, d.label .. (target == "open" and " OPENING" or " CLOSING")

  else -- speed
    local rpm = action == "stop" and 0 or tonumber(arg)
    if not rpm then return false, d.label .. ": speed needs a number of RPM" end
    rpm = floor(max(-d.max, min(d.max, rpm)) + 0.5)
    local okc, cerr = pcall(ctx.P.call, d.periph, "setTargetSpeed", rpm)
    if not okc then return false, d.label .. ": " .. tostring(cerr) end
    r.set, r.setAt = rpm, now
    DV.saveState(bank, ctx)
    return true, string.format("%s set to %d RPM", d.label, rpm)
  end
end

-- ------------------------------------------------------------------ memory

--- What each device was last told, so a reboot neither forgets a door's
-- position nor leaves the lights off.
function DV.saveState(bank, ctx)
  ctx.dirty = nil
  if not ctx.fs then return end
  local lines = {}
  for _, d in ipairs(bank.list) do
    local r = bank.run[d.name]
    if d.kind == "output" and r.set ~= nil then
      lines[#lines + 1] = d.name .. " set " .. tostring(r.set)
    elseif d.kind == "gearshift" and (r.target or r.pos) then
      lines[#lines + 1] = d.name .. " pos " .. (r.target or r.pos)
    end
  end
  if ctx.fs.exists(DV.STATE_FILE) then ctx.fs.delete(DV.STATE_FILE) end
  local f = ctx.fs.open(DV.STATE_FILE, "w")
  if f then
    f.write(table.concat(lines, "\n") .. "\n")
    f.close()
  end
end

--- Read it back at startup, and drive every output to what it was last told
-- (a computer's own redstone resets when it reboots).
function DV.restore(bank, ctx, now)
  if not (ctx.fs and ctx.fs.exists(DV.STATE_FILE)) then return end
  local f = ctx.fs.open(DV.STATE_FILE, "r")
  if not f then return end
  local text = f.readAll() or ""
  f.close()
  for name, key, value in text:gmatch("([%w_%-]+) (%a+) (%a+)") do
    local d, r = bank.by[name], bank.run[name]
    if d and d.kind == "output" and key == "set" then
      r.set, r.setAt = value == "true", now
      ioWrite(ctx, d.out, r.set)
    elseif d and d.kind == "gearshift" and key == "pos" and (value == "open" or value == "closed") then
      r.pos = value
    end
  end
end

return DV
