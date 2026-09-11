-- docktest: prove the docking connector is wired, reachable and actually
-- toggling, before any flight depends on it.
--
--   docktest                        report only - nothing is driven
--   docktest <side>                 drive a side of THIS computer
--   docktest relay <name> <side>    drive a CC:Tweaked Redstone Relay
--   docktest slave <proto> <side>   drive a computer running rsio.lua
--
-- e.g.  docktest back
--       docktest slave drone-rs back
--
-- It extends the connector, watches getConnectedName() for HOLD seconds,
-- then releases and watches again. Run it ON THE PAD: extending arms the
-- magnet, and releasing is what undocks, so doing this in the air is a way
-- to drop the craft.
--
-- The connector's whole API is getConnectedName() - there is no "am I
-- extended" to read - so the two things this can prove are that the redstone
-- output really changed, and that the pad answers when it does. If the name
-- stays empty with the signal high, the wiring is right and the alignment is
-- wrong, or the pad's own connector is not extended.

local HOLD = 6        -- seconds to stay extended
local STEP = 0.5      -- seconds between reports

local a1, a2, a3 = ...

-- ---------- what is attached ----------
local conn = peripheral.find("docking_connector")
print("=============== docktest ===============")
if not conn then
  print("NO docking_connector on this computer or its wired network.")
  print("  A wired modem on the connector's face puts it on the network;")
  print("  the modem is flat, so it costs no block space of its own.")
  return
end
local cname = peripheral.getName(conn)
print("connector : " .. cname)
local methods = peripheral.getMethods and peripheral.getMethods(cname) or {}
table.sort(methods)
print("  methods : " .. (#methods > 0 and table.concat(methods, " ") or "?"))

local function connected()
  local ok, name = pcall(conn.getConnectedName)
  if not ok then return nil, tostring(name) end
  if name == nil or name == "" then return nil end
  return name
end

-- Raw, because an empty string and a nil mean different things and a docked
-- pad with no label may well report one of them.
local function raw()
  local ok, name = pcall(conn.getConnectedName)
  if not ok then return "ERROR " .. tostring(name) end
  if name == nil then return "nil" end
  return string.format("%q", tostring(name))
end

-- Docking bridges the pad's wired network to the craft's, so the number of
-- peripherals visible jumps. That is a dock you can see even if the connector
-- will not say so.
local function npers()
  local ok, names = pcall(peripheral.getNames)
  return ok and type(names) == "table" and #names or -1
end
local baseN = npers()

local now, err = connected()
print("  docked  : " .. (now or (err and ("ERROR " .. err) or "no")))
print("  raw     : " .. raw())
print("  network : " .. baseN .. " peripherals visible (a dock bridges the pad's in)")

-- ---------- what we would drive ----------
local target
if a1 == "relay" then
  if not (a2 and a3) then print("usage: docktest relay <peripheral> <side>") return end
  target = { relay = a2, side = a3 }
elseif a1 == "slave" then
  if not (a2 and a3) then print("usage: docktest slave <protocol> <side>") return end
  target = { slave = a2, side = a3 }
elseif a1 then
  target = a1
end

if not target then
  print("")
  print("report only. give a redstone target to actually toggle it:")
  print("  docktest back                 a side of this computer")
  print("  docktest relay redstone_relay_0 back")
  print("  docktest slave drone-rs back")
  return
end

local okRS, RS = pcall(dofile, "lib/rs.lua")
if not okRS or type(RS) ~= "table" then print("lib/rs.lua missing or broken") return end
print("target    : " .. RS.describe(target))

-- Read the signal back where we can. A local side reads directly; a slave
-- reports its whole output state on a heartbeat, which rs.check compares
-- against what we asked for.
local function readback()
  if type(target) ~= "table" then return tostring(redstone.getOutput(target)) end
  if target.relay then
    local ok, v = pcall(peripheral.call, target.relay, "getOutput", target.side)
    return ok and tostring(v) or ("ERROR " .. tostring(v))
  end
  RS.poll()
  local bad = RS.check()
  return #bad == 0 and "confirmed by the slave" or table.concat(bad, "; ")
end

local function watch(label, secs)
  local t0 = os.clock()
  local last, lastN
  while os.clock() - t0 < secs do
    local name, n = connected(), npers()
    if name ~= last or n ~= lastN then
      print(string.format("  %5.1fs  %-8s name=%s  peripherals=%d%s  signal=%s",
        os.clock() - t0, label, raw(), n,
        n > baseN and " BRIDGED" or "", readback()))
      last, lastN = name, n
    end
    sleep(STEP)
  end
  print(string.format("  %5.1fs  %-8s name=%s  peripherals=%d%s  signal=%s",
    secs, label, raw(), npers(), npers() > baseN and " BRIDGED" or "", readback()))
end

print("")
print("EXTENDING - the magnet is armed while this is high")
local ok, errSet = RS.set(target, true)
if not ok then print("  FAILED to set: " .. tostring(errSet)) return end
watch("extended", HOLD)

print("")
print("RELEASING")
ok, errSet = RS.set(target, false)
if not ok then print("  FAILED to clear: " .. tostring(errSet)) end
watch("released", 3)

print("")
local final = connected()
if final then
  print("still reads docked to " .. final .. " - the pad may hold until it is pushed off")
else
  print("released cleanly")
end
print("reading this:")
print("  signal=false            the redstone never reached the connector")
print("  signal=true, name=\"\"    wiring fine; alignment or the pad's own connector is not")
print("  peripherals jumped      it IS docked, whatever the name says - the pad's")
print("                          network is bridged in, and that counts")
