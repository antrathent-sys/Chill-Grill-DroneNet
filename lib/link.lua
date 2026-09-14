--- link: the telemetry packet between a drone and the base.
--
-- L4 in ARCHITECTURE.md, first slice: the drone SENDS a small status table
-- about once a second; the base reads it. Nothing here receives commands.
--
-- Send-only is deliberate. The drone transmits with raw modem.transmit on its
-- ender modem and never calls rednet.open or modem.open on it: opening that
-- modem for rednet would let `drone-cmd` words arrive over radio again, and a
-- rednet_message event does not say which modem it came in on, so the
-- wired-only rule in fly.lua (CMD_RADIO_STRICT) could not hold. Commands over
-- radio wait for the signed link (MISSIONCONTROL.md, step 5).
--
-- Everything here is pure: tables in, tables out, no peripheral calls except
-- through the table passed to findRadio, so it tests on the desktop.
--
--   local link = dofile("lib/link.lua")
--   local radio = link.findRadio(peripheral)
--   peripheral.call(radio, "transmit", link.CHANNEL, link.CHANNEL,
--                   link.packet(id, seq, status, mon, fuel, dock, #legs, legIdx, legKind, mode))

local link = {}

link.VERSION = 1
link.CHANNEL = 7212

local function round(x, n)
  if type(x) ~= "number" or x ~= x or x == math.huge or x == -math.huge then return nil end
  local m = 10 ^ (n or 0)
  return math.floor(x * m + 0.5) / m
end
link.round = round

--- Name of the first wireless modem (an ender modem counts), or nil.
-- Names are sorted so the choice is stable across reboots.
function link.findRadio(periph)
  if not periph or not periph.getNames then return nil end
  local names = {}
  for _, n in ipairs(periph.getNames()) do names[#names + 1] = n end
  table.sort(names)
  for _, n in ipairs(names) do
    if periph.getType(n) == "modem" then
      local ok, wireless = pcall(periph.call, n, "isWireless")
      if ok and wireless == true then return n end
    end
  end
  return nil
end

--- Signed distance of (x, z) from the line (sx, sz) -> (tx, tz), in blocks.
-- Positive to the RIGHT of the direction of travel (world X east, Z south:
-- south of an eastbound leg), the same perpendicular CRUISE_TRACK uses.
-- nil when there is no line.
function link.offLine(x, z, sx, sz, tx, tz)
  if not (x and z and sx and sz and tx and tz) then return nil end
  local lx, lz = tx - sx, tz - sz
  local ln = math.sqrt(lx * lx + lz * lz)
  if ln < 1 then return nil end
  return (x - sx) * (-lz / ln) + (z - sz) * (lx / ln)
end

--- Build one telemetry packet. s is the status table the leg machine fills
-- (t, phase, h, e, x, z, vx, vz, vv, hdg, p, r, tx, tz, sx, sz, sat); mon, fuel
-- and dock are fly.lua's shared tables. Flat on purpose: every value is a
-- number, string or nil, so it copies cheaply over a modem and parses anywhere.
function link.packet(id, seq, s, mon, fuel, dock, nLegs, legIdx, legKind, mode)
  s, mon, fuel, dock = s or {}, mon or {}, fuel or {}, dock or {}
  local vx, vz = s.vx or 0, s.vz or 0
  local spd = math.sqrt(vx * vx + vz * vz)
  local dist
  if s.x and s.z and s.tx and s.tz then
    dist = math.sqrt((s.tx - s.x) ^ 2 + (s.tz - s.z) ^ 2)
  end
  local tilt
  if s.p and s.r then tilt = math.sqrt(s.p * s.p + s.r * s.r) end
  return {
    v = link.VERSION, id = id, seq = seq, t = round(s.t, 1),
    mode = mode, phase = s.phase,
    leg = legIdx or 0, legs = nLegs or 0, legKind = legKind,
    x = round(s.x, 1), y = round(s.h, 1), z = round(s.z, 1),
    vx = round(vx, 1), vz = round(vz, 1), vv = round(s.vv, 1),
    spd = round(spd, 1), hdg = round(s.hdg, 0), tilt = round(tilt, 0),
    alte = round(s.e, 1),
    tx = round(s.tx, 1), tz = round(s.tz, 1), dist = round(dist, 0),
    eta = (dist and spd > 5) and round(dist / spd, 0) or nil,
    off = round(link.offLine(s.x, s.z, s.sx, s.sz, s.tx, s.tz), 0),
    energy = round(mon.energy, 1), drain = round(mon.rate, 2), fe = round(fuel.pct, 1),
    dock = dock.connected and 1 or 0, sat = s.sat and 1 or 0,
  }
end

--- Is this a telemetry packet the base should believe the shape of?
-- Returns true, or false and a reason. It does NOT prove who sent it: that
-- is the signed link's job.
function link.check(p)
  if type(p) ~= "table" then return false, "not a table" end
  if p.v ~= link.VERSION then return false, "version " .. tostring(p.v) end
  if type(p.id) ~= "string" or p.id == "" then return false, "no id" end
  if type(p.seq) ~= "number" then return false, "no seq" end
  if type(p.phase) ~= "string" then return false, "no phase" end
  for _, k in ipairs({ "t", "x", "y", "z" }) do
    if type(p[k]) ~= "number" then return false, "no " .. k end
  end
  return true
end

return link
