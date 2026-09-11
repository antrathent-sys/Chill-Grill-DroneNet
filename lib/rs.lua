--- rs: a redstone output that is not necessarily on this computer's faces.
--
-- The 3x3 airframe has no free face next to the docking connector - the outer
-- ring is accumulators and network cable, and the centre column above the
-- connector is the CC&A power connector. The signal therefore has to come
-- from somewhere else on the wired network. Three backends:
--
--   "bottom"                                   a side of THIS computer (free)
--   { relay = "redstone_relay_0", side = "b" }  a CC:Tweaked Redstone Relay
--                                               (needs CC >= 1.109; check with
--                                               print(_HOST) on the pod)
--   { slave = "drone-rs", side = "bottom" }     a small computer running
--                                               rsio.lua, reached over rednet
--                                               on the wired network
--
-- A slave set is FIRE AND FORGET: waiting for an acknowledgement would stall
-- whichever coroutine called it, and dockExtend() is called from the control
-- loop. The slave instead broadcasts its whole output state about once a
-- second; call rs.poll() from the SLOW loop to pick that up, and rs.check()
-- to find out whether what we asked for is actually being held.

local rs = {}

rs.PROTOCOL = "drone-rs"
rs.STALE = 5          -- seconds without a slave broadcast before it counts as lost

local wanted = {}     -- side -> boolean we last commanded on the slave
local heard  = nil    -- os.clock() of the last slave broadcast
local state  = {}     -- side -> boolean the slave says it is holding
local opened = false

local function sideOf(t) return type(t) == "table" and t.side or t end

--- Human-readable, for print() and error messages.
function rs.describe(t)
  if not t then return "nil" end
  if type(t) ~= "table" then return "local " .. tostring(t) end
  if t.relay then return t.relay .. ":" .. tostring(t.side) end
  if t.slave then return "slave " .. t.slave .. ":" .. tostring(t.side) end
  return "?" .. tostring(t.side)
end

-- Open rednet on the first modem we can find. Wired is preferred: the slave
-- is on the craft's own cable, and a wireless modem would happily talk to
-- another drone's slave.
local function ensureRednet()
  if opened then return true end
  if not rednet or not peripheral then return false end
  local best
  for _, name in ipairs(peripheral.getNames and peripheral.getNames() or {}) do
    if peripheral.getType(name) == "modem" then
      local okw, wireless = pcall(peripheral.call, name, "isWireless")
      if okw and wireless == false then best = name break end
      best = best or name
    end
  end
  if not best then return false end
  local ok = pcall(rednet.open, best)
  opened = ok and true or false
  return opened
end

--- Drive a target high or low. Returns ok, err.
function rs.set(t, on)
  if not t then return true end
  on = on and true or false
  if type(t) ~= "table" then
    redstone.setOutput(t, on)
    return true
  end
  if t.relay then
    local ok, err = pcall(peripheral.call, t.relay, "setOutput", t.side, on)
    if not ok then return false, "relay " .. t.relay .. ": " .. tostring(err) end
    return true
  end
  if t.slave then
    if not ensureRednet() then return false, "no modem for the redstone slave" end
    wanted[t.side] = on
    local ok, err = pcall(rednet.broadcast, { cmd = "set", side = t.side, on = on }, t.slave)
    if not ok then return false, "rednet: " .. tostring(err) end
    return true
  end
  return false, "unrecognised redstone target"
end

--- Drop every output except one. Used by the panic stop, which must never
-- release the docking connector.
function rs.clear(keep)
  local keepSide = sideOf(keep)
  local keepLocal = (type(keep) ~= "table") and keep or nil
  for _, side in ipairs(redstone.getSides()) do
    if side ~= keepLocal then redstone.setOutput(side, false) end
  end
  if type(keep) == "table" and keep.slave then
    if ensureRednet() then
      pcall(rednet.broadcast, { cmd = "clear", except = keepSide }, keep.slave)
      wanted = { [keepSide] = wanted[keepSide] }
    end
  end
end

--- Pick up slave broadcasts. Costs at most one tick, so call it from the
-- monitoring loop, never from the control loop.
function rs.poll()
  if not opened then return end
  local ok, _, msg = pcall(rednet.receive, rs.PROTOCOL, 0)
  while ok and type(msg) == "table" and msg.state do
    heard, state = os.clock(), msg.state
    ok, _, msg = pcall(rednet.receive, rs.PROTOCOL, 0)
  end
end

--- What is wrong with the remote outputs right now, as a list of strings.
-- Empty when everything we asked for is being held (or nothing is remote).
function rs.check()
  local bad = {}
  if not next(wanted) then return bad end
  if not heard then
    bad[#bad + 1] = "redstone slave has never reported"
  elseif os.clock() - heard > rs.STALE then
    bad[#bad + 1] = string.format("redstone slave silent for %.0fs", os.clock() - heard)
  else
    for side, on in pairs(wanted) do
      if (state[side] and true or false) ~= on then
        bad[#bad + 1] = string.format("slave %s is %s, wanted %s", side,
          tostring(state[side] and true or false), tostring(on))
      end
    end
  end
  return bad
end

return rs
