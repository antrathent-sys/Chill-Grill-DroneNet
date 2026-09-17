-- Desktop tests for lib/devices.lua: the device list, every kind's honest
-- state, commands, faults when a read-back disagrees, and memory across a reboot.
local DIR = ...
local pass, fail = 0, 0
local function check(n, c, d)
  if c then pass = pass + 1 print("  ok   " .. n)
  else fail = fail + 1 print("  FAIL " .. n .. (d and ("  " .. tostring(d)) or "")) end
end

local DV = dofile(DIR .. "/../lib/devices.lua")

-- a base computer: peripherals by name, its own redstone faces, a disk
local function base(files)
  local w = { periph = {}, calls = {}, rsOut = {}, rsIn = {}, files = files or {} }
  w.P = {
    isPresent = function(n) return w.periph[n] ~= nil end,
    call = function(n, m, ...)
      w.calls[#w.calls + 1] = n .. "." .. m
      local p = w.periph[n]
      if not p then error("no peripheral " .. n, 0) end
      if not p[m] then error("no such method " .. m, 0) end
      return p[m](...)
    end,
  }
  w.R = {
    setOutput = function(s, on) w.rsOut[s] = on end,
    getInput = function(s) return w.rsIn[s] == true end,
    getAnalogInput = function() return 0 end,
  }
  w.fs = {
    exists = function(p) return w.files[p] ~= nil end,
    open = function(p, mode)
      if mode == "r" then
        local s = w.files[p]
        return s and { readAll = function() return s end, close = function() end } or nil
      end
      local buf = {}
      return { write = function(s) buf[#buf + 1] = s end, close = function() w.files[p] = table.concat(buf) end }
    end,
    delete = function(p) w.files[p] = nil end,
  }
  w.ctx = { P = w.P, R = w.R, fs = w.fs }
  function w.relay(name)
    local r = { out = {}, inp = {}, analog = {} }
    w.periph[name] = {
      setOutput = function(side, on) r.out[side] = on end,
      getInput = function(side) return r.inp[side] == true end,
      getAnalogInput = function(side) return r.analog[side] or 0 end,
    }
    return r
  end
  function w.gearshift(name)
    local g = { running = false, moves = {} }
    w.periph[name] = {
      isRunning = function() return g.running end,
      move = function(dist, mod) g.moves[#g.moves + 1] = { "move", dist, mod } g.running = true end,
      rotate = function(deg, mod) g.moves[#g.moves + 1] = { "rotate", deg, mod } g.running = true end,
    }
    return g
  end
  return w
end

local function has(list, s)
  for _, v in ipairs(list) do if v:find(s, 1, true) then return true end end
  return false
end

print("the list")
local list, bad = DV.parse({
  { name = "Hangar Lights", kind = "output", out = { relay = "redstone_relay_0", side = "top" } },
  { name = "door", kind = "gearshift", periph = "gs", travel = 6 },
  { name = "door", kind = "output", out = { side = "back" } },
  { name = "odd!", kind = "output", out = { side = "back" } },
  { name = "toaster", kind = "fridge", periph = "x" },
  { name = "nogo", kind = "gearshift", periph = "gs" },
  { name = "noout", kind = "output" },
})
check("good devices kept, names cleaned", #list == 2 and list[1].name == "hangarlights" and list[1].label == "HANGAR LIGHTS")
check("every problem reported", #bad == 5 and has(bad, "twice") and has(bad, "plain name") and has(bad, "unknown kind fridge")
  and has(bad, "travel > 0") and has(bad, "needs out"), table.concat(bad, "; "))
local exampleFs = { exists = function() return true end, open = function(p)
  local f = io.open(DIR .. "/../devices.example.lua", "r")
  local s = f:read("*a") f:close()
  return { readAll = function() return s end, close = function() end }
end }
local ex, exBad = DV.load("devices.example.lua", exampleFs)
check("devices.example.lua loads with no complaints", #ex == 10 and #exBad == 0, table.concat(exBad, "; "))
check("a devices file cannot reach the computer", (function()
  local l, b = DV.load("devices.lua", { exists = function() return true end, open = function()
    return { readAll = function() return "fs.delete('startup.lua') return {}" end, close = function() end }
  end })
  return #l == 0 and #b == 1
end)())

print("outputs")
local w = base()
local r0 = w.relay("redstone_relay_0")
local b = DV.bank(DV.parse({
  { name = "lights", kind = "output", out = { relay = "redstone_relay_0", side = "top" } },
  { name = "alarm", kind = "output", out = { side = "back" } },
  { name = "side-door", kind = "output", labels = { "open", "closed" },
    out = { relay = "redstone_relay_0", side = "north" },
    status = { relay = "redstone_relay_0", side = "south", invert = true } },
}))
DV.poll(b, w.ctx, 0)
check("never told: NOT SET", b.state.lights.text == "NOT SET")
local ok, msg = DV.command(b, w.ctx, "lights", "on", nil, 1)
check("on drives the relay face", ok and r0.out.top == true and msg == "LIGHTS ON", msg)
DV.poll(b, w.ctx, 1)
check("no read-back: says it was only SET", b.state.lights.text == "ON (SET)" and b.state.lights.level == "info")
DV.command(b, w.ctx, "alarm", "toggle", nil, 1)
check("toggle on this computer's own face", w.rsOut.back == true)
DV.command(b, w.ctx, "alarm", "toggle", nil, 2)
check("toggle again turns it off", w.rsOut.back == false)

r0.inp.south = true -- contact powered: the door is closed
DV.poll(b, w.ctx, 2)
check("read-back with renamed labels: CLOSED", b.state["side-door"].text == "CLOSED" and b.state["side-door"].level == "ok")
DV.command(b, w.ctx, "side-door", "open", nil, 10)
DV.poll(b, w.ctx, 11)
check("just told to open and still reads closed: SWITCHING", b.state["side-door"].text == "SWITCHING")
DV.poll(b, w.ctx, 14)
check("still closed past the settle time: FAULT", b.state["side-door"].text == "FAULT"
  and b.state["side-door"].detail == "set OPEN, reads CLOSED", b.state["side-door"].detail)
r0.inp.south = false
DV.poll(b, w.ctx, 15)
check("the contact opens: OPEN and ok", b.state["side-door"].text == "OPEN" and b.state["side-door"].level == "ok")
w.periph.redstone_relay_0 = nil
DV.poll(b, w.ctx, 16)
check("relay gone: MISSING fault", b.state.lights.text == "MISSING" and b.state.lights.level == "fault")
local okm, mm = DV.command(b, w.ctx, "lights", "off", nil, 16)
check("a command to a missing relay fails and says why", not okm and mm:find("missing", 1, true), mm)

print("commands")
check("unknown device", select(2, DV.command(b, w.ctx, "fridge", "on", nil, 1)) == "no device called fridge")
check("unknown action lists the right ones", select(2, DV.command(b, w.ctx, "alarm", "speed", nil, 1))
  == "ALARM takes: on, off, toggle, open, close")

print("gearshift doors")
local w2 = base()
local gs = w2.gearshift("gs")
local r1 = w2.relay("relay1")
local b2 = DV.bank(DV.parse({
  { name = "hangar", kind = "gearshift", periph = "gs", travel = 6 },
  { name = "gate", kind = "gearshift", periph = "gs", travel = 90, unit = "angle", fast = true,
    closed = { relay = "relay1", side = "top" } },
}))
DV.poll(b2, w2.ctx, 0)
check("never driven: UNKNOWN, warns how to fix", b2.state.hangar.text == "UNKNOWN" and b2.state.hangar.level == "warn")
local okg, mg = DV.command(b2, w2.ctx, "hangar", "open", nil, 1)
check("open: move 6 forward", okg and gs.moves[1][1] == "move" and gs.moves[1][2] == 6 and gs.moves[1][3] == 1, mg)
DV.poll(b2, w2.ctx, 2)
check("running: OPENING", b2.state.hangar.text == "OPENING")
check("a second command while moving is refused", not DV.command(b2, w2.ctx, "hangar", "close", nil, 3))
gs.running = false
DV.poll(b2, w2.ctx, 5)
check("stopped: OPEN", b2.state.hangar.text == "OPEN")
check("open again is refused, no move sent", not DV.command(b2, w2.ctx, "hangar", "open", nil, 6) and #gs.moves == 1)
DV.command(b2, w2.ctx, "hangar", "close", nil, 7)
check("close: the same distance back", gs.moves[2][2] == 6 and gs.moves[2][3] == -1)
DV.poll(b2, w2.ctx, 7.5)
check("the start grace covers a gearshift that has not begun yet", b2.state.hangar.text == "CLOSING")
DV.poll(b2, w2.ctx, 40)
check("running past the timeout: JAMMED", b2.state.hangar.text == "JAMMED" and b2.state.hangar.level == "fault")
gs.running = false
DV.poll(b2, w2.ctx, 41)
check("then it stops: CLOSED", b2.state.hangar.text == "CLOSED")
check("the position is remembered on disk", (w2.files[".devstate"] or ""):find("hangar pos closed", 1, true),
  w2.files[".devstate"])

-- the gate has a contact
r1.inp.top = true
DV.poll(b2, w2.ctx, 50)
check("contact says closed: CLOSED, ok", b2.state.gate.text == "CLOSED" and b2.state.gate.level == "ok")
check("close while the contact says closed is refused", not DV.command(b2, w2.ctx, "gate", "close", nil, 51))
DV.command(b2, w2.ctx, "gate", "open", nil, 52)
check("angle unit rotates, fast doubles the modifier", gs.moves[3][1] == "rotate" and gs.moves[3][2] == 90
  and gs.moves[3][3] == 2)
gs.running = false
DV.poll(b2, w2.ctx, 54)
check("finished opening but the contact still reads closed: FAULT", b2.state.gate.text == "FAULT"
  and b2.state.gate.detail == "should be open, contact closed", b2.state.gate.detail)
w2.periph.gs = nil
DV.poll(b2, w2.ctx, 60)
check("gearshift gone: MISSING", b2.state.hangar.text == "MISSING")

print("speed")
local w3 = base()
local ctl = { target = 0 }
local gauge = { speed = 0 }
w3.periph.ctl = { setTargetSpeed = function(v) ctl.target = v end, getTargetSpeed = function() return ctl.target end }
w3.periph.gauge = { getSpeed = function() return gauge.speed end }
local b3 = DV.bank(DV.parse({ { name = "line", kind = "speed", periph = "ctl", gauge = "gauge", max = 128 } }))
local oks, ms = DV.command(b3, w3.ctx, "line", "speed", "500", 1)
check("speed is clamped to max", oks and ctl.target == 128, ms)
DV.poll(b3, w3.ctx, 2)
check("shaft not turning yet: still settling", b3.state.line.detail == "spinning up")
DV.poll(b3, w3.ctx, 6)
check("shaft never turns: STALLED", b3.state.line.text == "STALLED" and b3.state.line.level == "fault")
gauge.speed = -128
DV.poll(b3, w3.ctx, 7)
check("turning: the real RPM", b3.state.line.text == "128 RPM" and b3.state.line.level == "ok")
DV.command(b3, w3.ctx, "line", "stop", nil, 8)
check("stop sets 0", ctl.target == 0)
check("speed without a number is refused", not DV.command(b3, w3.ctx, "line", "speed", "fast", 9))

print("readings")
local w4 = base()
local stress = { used = 400, cap = 2048 }
w4.periph.su = { getStress = function() return stress.used end, getStressCapacity = function() return stress.cap end }
w4.periph.bat = { getEnergy = function() return 150000 end, getEnergyCapacity = function() return 1000000 end }
w4.periph.tank = { tanks = function() return { { name = "minecraft:lava", amount = 12600 } } end }
w4.periph.vault = { size = function() return 54 end,
  list = function() local t = {} for i = 1, 50 do t[i] = { name = "minecraft:cobblestone", count = 64 } end return t end }
w4.periph.meter = { getSpeed = function() return 32 end }
local r4 = w4.relay("relay4")
r4.analog.west = 11
local b4 = DV.bank(DV.parse({
  { name = "su", kind = "stress", periph = "su" },
  { name = "power", kind = "energy", periph = "bat" },
  { name = "lava", kind = "fluid", periph = "tank", capacity = 64000 },
  { name = "vault", kind = "items", periph = "vault" },
  { name = "shaft", kind = "speedometer", periph = "meter" },
  { name = "heat", kind = "level", input = { relay = "relay4", side = "west" } },
  { name = "gone", kind = "energy", periph = "nothere" },
}))
local st = DV.poll(b4, w4.ctx, 0)
check("stress: used/capacity", st.su.text == "400/2.0k SU" and st.su.level == "ok" and st.su.value == 400 and st.su.max == 2048,
  st.su.text)
stress.used = 1800
DV.poll(b4, w4.ctx, 1)
check("stress above 80%: warn", st.su.level == "warn")
stress.used = 2100
DV.poll(b4, w4.ctx, 2)
check("stress over capacity: OVERSTRESSED fault", st.su.text == "OVERSTRESSED" and st.su.level == "fault")
check("energy: percent and FE, warn below 20", st.power.text == "15% 150kFE" and st.power.level == "warn", st.power.text)
check("fluid: percent of capacity", st.lava.text == "20% 12.6k mB", st.lava.text)
check("items: count and slots, warn at 90%", st.vault.text == "3.2k ITEMS 50/54" and st.vault.level == "warn", st.vault.text)
check("speedometer", st.shaft.text == "32 RPM")
check("level from a relay", st.heat.text == "11/15" and st.heat.value == 11)
check("a reading whose peripheral is gone is MISSING", st.gone.text == "MISSING" and st.gone.level == "fault")
check("readings take no commands", select(2, DV.command(b4, w4.ctx, "su", "on", nil, 1)):find("takes no commands", 1, true))

print("a reboot")
local w5 = base({ [".devstate"] = "lights set true\nhangar pos open\nalarm set false\n" })
local r5 = w5.relay("redstone_relay_0")
w5.gearshift("gs")
local b5 = DV.bank(DV.parse({
  { name = "lights", kind = "output", out = { relay = "redstone_relay_0", side = "top" } },
  { name = "alarm", kind = "output", out = { side = "back" } },
  { name = "hangar", kind = "gearshift", periph = "gs", travel = 6 },
}))
DV.restore(b5, w5.ctx, 0)
check("outputs are driven back to what they were told", r5.out.top == true and w5.rsOut.back == false)
DV.poll(b5, w5.ctx, 0)
check("a door remembers where it is", b5.state.hangar.text == "OPEN" and b5.state.lights.text == "ON (SET)")

print("")
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then error("devices tests failed", 0) end
