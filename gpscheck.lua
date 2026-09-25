-- gpscheck: which GPS host is wrong?
--
--   gpscheck               ask every host where it is and how far away it is
--   gpscheck <x> <y> <z>   the same, standing on a block whose F3 you know:
--                          each host's measured distance is compared with the
--                          distance from where it SAYS it is to where you
--                          really are. A host with the wrong coordinates typed
--                          into `gps host` stands out by the difference.
--
-- A pocket finds itself only by GPS, and an open-ground pickup lands where
-- the fix says. On 2026-09-25 a fix at the rules pad, 3,600 blocks from the
-- hosts, was 13.5 blocks off and ~65 Y low. Ender modems report exact
-- distances, so an error that size is a host with the wrong coordinates, or
-- hosts too near one plane to solve the vertical - this says which.
-- Writes gpscheck.txt, and pushes it to data/ when this computer can upload.

local args = { ... }
local CH = (gps and gps.CHANNEL_GPS) or 65534
local WAIT = 2
local TOL = 2            -- blocks: a pocket sits at the player, not a block centre

local truth
if #args > 0 and #args < 3 then
  print("gpscheck <x> <y> <z> - three numbers, as F3 shows them")
  return
end
if #args >= 3 then
  truth = { x = tonumber(args[1]), y = tonumber(args[2]), z = tonumber(args[3]) }
  if not (truth.x and truth.y and truth.z) then
    print("gpscheck <x> <y> <z> - three numbers, as F3 shows them")
    return
  end
end

local modems = {}
for _, nm in ipairs(peripheral.getNames()) do
  if peripheral.getType(nm) == "modem" then
    local ok, wireless = pcall(peripheral.call, nm, "isWireless")
    if ok and wireless then modems[#modems + 1] = nm end
  end
end
if #modems == 0 then
  print("gpscheck: no wireless or ender modem here")
  return
end

local lines = {}
local function out(fmt, ...)
  local s = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
  lines[#lines + 1] = s
  print(s)
end

local wasOpen = {}
for _, m in ipairs(modems) do
  wasOpen[m] = peripheral.call(m, "isOpen", CH)
  peripheral.call(m, "open", CH)
  peripheral.call(m, "transmit", CH, CH, "PING")
end

-- every answer: where the host says it is, and how far it really is
local hosts = {}
local deadline = os.clock() + WAIT
local timer = os.startTimer(WAIT)
while os.clock() < deadline do
  local ev = { os.pullEvent() }
  if ev[1] == "timer" and ev[2] == timer then break end
  if ev[1] == "modem_message" and ev[3] == CH and type(ev[5]) == "table"
     and type(ev[5][1]) == "number" and type(ev[5][2]) == "number" and type(ev[5][3]) == "number"
     and type(ev[6]) == "number" then
    local p = ev[5]
    local dup = false
    for _, h in ipairs(hosts) do
      if h.x == p[1] and h.y == p[2] and h.z == p[3] then dup = true end
    end
    if not dup then hosts[#hosts + 1] = { x = p[1], y = p[2], z = p[3], d = ev[6] } end
  end
end
for _, m in ipairs(modems) do
  if not wasOpen[m] then pcall(peripheral.call, m, "close", CH) end
end

out("gpscheck: %d host%s answered", #hosts, #hosts == 1 and "" or "s")
if #hosts == 0 then
  out("no GPS at all here: nothing answered on channel %d", CH)
end

local bad = 0
for i, h in ipairs(hosts) do
  local line = string.format("%d  says %d %d %d   %.1f away", i, h.x, h.y, h.z, h.d)
  if truth then
    local should = math.sqrt((h.x - truth.x) ^ 2 + (h.y - truth.y) ^ 2 + (h.z - truth.z) ^ 2)
    local off = h.d - should
    local wrong = math.abs(off) > TOL
    if wrong then bad = bad + 1 end
    line = line .. string.format("   should be %.1f  %s", should, wrong and string.format("WRONG by %.1f", off) or "ok")
  end
  out(line)
end

-- geometry: four hosts at one height cannot solve the vertical
if #hosts >= 2 then
  local lo, hi = hosts[1].y, hosts[1].y
  for _, h in ipairs(hosts) do lo, hi = math.min(lo, h.y), math.max(hi, h.y) end
  out("hosts span %d in Y%s", hi - lo, (hi - lo) < 3 and " - too flat: the vertical is a guess, offset one host in Y" or "")
end
if #hosts >= 4 then
  -- volume of the first four: near zero means they lie in one plane
  local a, b, c, d = hosts[1], hosts[2], hosts[3], hosts[4]
  local ux, uy, uz = b.x - a.x, b.y - a.y, b.z - a.z
  local vx, vy, vz = c.x - a.x, c.y - a.y, c.z - a.z
  local wx, wy, wz = d.x - a.x, d.y - a.y, d.z - a.z
  local vol = math.abs(ux * (vy * wz - vz * wy) - uy * (vx * wz - vz * wx) + uz * (vx * wy - vy * wx)) / 6
  out("the first four enclose %.0f cubic blocks%s", vol, vol < 10 and " - in one plane: no reliable fix" or "")
elseif #hosts > 0 then
  out("fewer than 4 hosts: the fix can be the mirror image of the truth")
end

local x, y, z = gps.locate(WAIT)
if x then
  out("gps.locate says %.1f %.1f %.1f", x, y, z)
  if truth then
    out("which is %.1f blocks across and %.1f in Y from the truth",
      math.sqrt((x - truth.x) ^ 2 + (z - truth.z) ^ 2), y - truth.y)
  end
else
  out("gps.locate got no fix")
end
if truth then
  out(bad == 0 and "every host agrees with where you stand" or
    string.format("%d host%s with wrong coordinates: re-run `gps host` there with F3's numbers", bad, bad == 1 and "" or "s"))
else
  out("stand on a block you know and run: gpscheck <x> <y> <z>")
end

local f = fs.open("gpscheck.txt", "w")
if f then f.write(table.concat(lines, "\n") .. "\n") f.close() end
if fs.exists(".ghtoken") and fs.exists("upload.lua") then
  local label = (os.getComputerLabel and os.getComputerLabel()) or tostring(os.getComputerID())
  pcall(shell.run, "upload", "sync", "gpscheck.txt", "data/gpscheck-" .. label .. ".txt")
end
