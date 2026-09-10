-- probe: dump what CC: Sable reports on this drone, and check it against the
-- sensors fly.lua currently uses. Run it once on the pod, sitting still, then
-- again while moving. Read-only: it never touches the thruster.
--
--   probe            one snapshot
--   probe watch      refresh once a second until Ctrl+T
--   probe save       one snapshot, written to probe.txt and pushed to the repo
--                    (terminals cannot be copied out of, so this is how the
--                     output gets somewhere readable)

local WATCH = arg[1] == "watch"
local SAVE  = arg[1] == "save"

-- Tee every print into a buffer when saving, so the file matches the screen.
local buf = {}
local realPrint = print
if SAVE then
  print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    buf[#buf + 1] = table.concat(parts, " ")
    realPrint(...)
  end
end

local function has(api) return _G[api] ~= nil end

local function v3(t)
  if type(t) ~= "table" then return tostring(t) end
  return string.format("%10.4f %10.4f %10.4f", t.x or 0, t.y or 0, t.z or 0)
end

-- yaw about the vertical axis from a quaternion, degrees 0..360
local function yawOf(q)
  if type(q) ~= "table" then return nil end
  local x, y, z, w = q.x or 0, q.y or 0, q.z or 0, q.w or 1
  local siny = 2 * (w * y + z * x)
  local cosy = 1 - 2 * (x * x + y * y)
  return math.deg(math.atan2(siny, cosy)) % 360
end

local function pitchRollOf(q)
  if type(q) ~= "table" then return nil, nil end
  local x, y, z, w = q.x or 0, q.y or 0, q.z or 0, q.w or 1
  local sinp = 2 * (w * x - y * z)
  if sinp > 1 then sinp = 1 elseif sinp < -1 then sinp = -1 end
  local pitch = math.deg(math.asin(sinp))
  local sinr = 2 * (w * z + x * y)
  local cosr = 1 - 2 * (z * z + x * x)
  return pitch, math.deg(math.atan2(sinr, cosr))
end

-- time a call so you can see what it costs in ticks
local function timed(f, ...)
  local t0 = os.clock()
  local ok, a, b = pcall(f, ...)
  return os.clock() - t0, ok, a, b
end

-- rotate a body-frame vector into world by quaternion q (see FRAMES.md)
local function toWorld(q, v)
  local qx, qy, qz, qw = q.x or 0, q.y or 0, q.z or 0, q.w or 1
  local tx = 2 * (qy * v.z - qz * v.y)
  local ty = 2 * (qz * v.x - qx * v.z)
  local tz = 2 * (qx * v.y - qy * v.x)
  return { x = v.x + qw * tx + (qy * tz - qz * ty),
           y = v.y + qw * ty + (qz * tx - qx * tz),
           z = v.z + qw * tz + (qx * ty - qy * tx) }
end
local function conj(q) return { x = -(q.x or 0), y = -(q.y or 0), z = -(q.z or 0), w = q.w or 1 } end
local function sub(a, b) return { x = a.x - b.x, y = a.y - b.y, z = a.z - b.z } end
local function len(v) return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z) end

local gim = peripheral.find("gimbal_sensor")
local alt = peripheral.find("altitude_sensor")
local nav = peripheral.find("navigation_table")

local function snapshot()
  print("================ CC: Sable probe ================")
  if not has("sublevel") then
    print("sublevel API MISSING - is CC: Sable installed on the server?")
    return
  end

  local dt, ok, inGrid = timed(sublevel.isInPlotGrid)
  print(string.format("isInPlotGrid : %s   (%.3fs)", tostring(inGrid), dt))
  if not ok then print("  error: " .. tostring(inGrid)) return end

  local okn, name = pcall(sublevel.getName)
  local oku, uuid = pcall(sublevel.getUniqueId)
  print("name / uuid  : " .. tostring(okn and name or "-") .. " / " .. tostring(oku and uuid or "-"))

  local dtp, okp, pose = timed(sublevel.getLogicalPose)
  if not okp or type(pose) ~= "table" then
    print("getLogicalPose FAILED: " .. tostring(pose))
    print("(this computer may not be on a sub-level)")
    return
  end
  print(string.format("getLogicalPose call cost: %.3fs", dtp))
  print("  position   : " .. v3(pose.position))
  print("  orientation: " .. v3(pose.orientation) .. string.format(" w=%10.4f", (pose.orientation or {}).w or 0))
  if pose.rotationPoint then print("  rotPoint   : " .. v3(pose.rotationPoint)) end
  if pose.scale then print("  scale      : " .. v3(pose.scale)) end

  -- THE key question: is pose.position in world coordinates?
  local gx, gy, gz = gps.locate(1)
  if gx and pose.position then
    local p = pose.position
    local dx, dy, dz = p.x - gx, p.y - gy, p.z - gz
    print(string.format("gps.locate   : %10.4f %10.4f %10.4f", gx, gy, gz))
    print(string.format("pose - gps   : %10.4f %10.4f %10.4f", dx, dy, dz))
    local off = math.sqrt(dx * dx + dz * dz)
    if off < 4 then
      print("  -> WORLD FRAME. pose.position can replace gps entirely.")
    else
      print("  -> NOT world frame (or a big offset). Do not drop gps yet.")
    end
  else
    print("gps.locate   : no fix (expected if hosts are down)")
  end

  -- orientation cross-check against the gimbal sensor
  local q = pose.orientation
  local yaw = yawOf(q)
  local qp, qr = pitchRollOf(q)
  if yaw then
    print(string.format("quat yaw     : %7.2f deg   <- this is the yaw the gimbal cannot give", yaw))
    print(string.format("quat p / r   : %7.2f / %7.2f deg", qp, qr))
  end
  if gim then
    local a = gim.getAngles()
    print(string.format("gimbal p / r : %7.2f / %7.2f deg", a[1], a[2]))
    print("  (if quat p/r and gimbal p/r disagree, the quaternion axis order differs")
    print("   from what this script assumes - note the numbers and we can fix the mapping)")
  end
  if nav then
    local okr, ra = pcall(nav.getRelativeAngle)
    if okr then print(string.format("nav rel angle: %7.2f deg", ra)) end
  end

  local dv, okv, lv = timed(sublevel.getLinearVelocity)
  if okv then print(string.format("linear vel   : %s   (%.3fs)", v3(lv), dv)) end
  local okav, av = pcall(sublevel.getAngularVelocity)
  if okav then print("angular vel  : " .. v3(av)) end
  local okgv, gv = pcall(sublevel.getVelocity)
  if okgv then print("global vel   : " .. v3(gv)) end

  -- ---- body axis mapping and quaternion direction ----
  -- Assemble body velocity from the three sensors using their own getAxis()
  -- labels, rotate it both ways, and see which matches the physics engine's
  -- world velocity. That pins down the quaternion direction AND the axis map.
  local vs = { peripheral.find("velocity_sensor") }
  if #vs > 0 then
    print("velocity sensors (Aeronautics body-axis labels):")
    local body = { x = 0, y = 0, z = 0 }
    for _, s in ipairs(vs) do
      local nm = peripheral.getName(s)
      local oka, ax = pcall(s.getAxis)
      local okv2, vel = pcall(s.getVelocity)
      ax = oka and ax or "?"
      vel = okv2 and vel or 0
      print(string.format("  %-20s axis=%s  vel=%8.3f", nm, tostring(ax), vel))
      if ax == "x" or ax == "y" or ax == "z" then body[ax] = vel end
    end
    print("  assembled body velocity: " .. v3(body))
    if okv and type(lv) == "table" and q then
      local asWorld = toWorld(q, body)
      local asBody  = toWorld(conj(q), body)
      local eW, eB = len(sub(asWorld, lv)), len(sub(asBody, lv))
      print("  body->world via q     : " .. v3(asWorld) .. string.format("  err %.3f", eW))
      print("  body->world via q*    : " .. v3(asBody) .. string.format("  err %.3f", eB))
      print("  sublevel linear vel   : " .. v3(lv))
      if len(lv) < 0.3 then
        print("  -> too slow to tell. Re-run this while MOVING at speed.")
      elseif eW < eB * 0.5 then
        print("  -> q rotates BODY -> WORLD, and the axis labels line up. Use toWorld(q,v).")
      elseif eB < eW * 0.5 then
        print("  -> q rotates WORLD -> BODY. Use the conjugate. Note this in FRAMES.md.")
      else
        print("  -> inconclusive: neither matches. Axis labels probably do not map")
        print("     straight onto the pose frame. Record both vectors and we will")
        print("     work out the permutation.")
      end
    end
  end

  -- where does each body axis point in the world right now?
  if q then
    print("body axes in world coords (hover: the thrust axis should read ~0,1,0):")
    print("  body +x -> " .. v3(toWorld(q, { x = 1, y = 0, z = 0 })))
    print("  body +y -> " .. v3(toWorld(q, { x = 0, y = 1, z = 0 })))
    print("  body +z -> " .. v3(toWorld(q, { x = 0, y = 0, z = 1 })))
  end

  local okm, mass = pcall(sublevel.getMass)
  local okc, com = pcall(sublevel.getCenterOfMass)
  if okm then print(string.format("mass         : %.2f", mass)) end
  if okc and com then print("centre of mass: " .. v3(com)) end

  if alt then
    local okh, h = pcall(alt.getHeight)
    if okh and pose.position then
      print(string.format("alt sensor   : %.4f   (pose.y - alt = %.4f)", h, pose.position.y - h))
    end
  end
end

if WATCH then
  while true do
    term.clear() term.setCursorPos(1, 1)
    snapshot()
    print("Ctrl+T stops")
    sleep(1)
  end
elseif SAVE then
  snapshot()
  print = realPrint
  local f = fs.open("probe.txt", "w")
  f.write(table.concat(buf, "\n") .. "\n")
  f.close()
  print("")
  print("written to probe.txt (" .. #buf .. " lines)")
  if fs.exists("upload.lua") and http then
    print("pushing to the repo...")
    local ok, err = pcall(function()
      if shell then return shell.run("upload", "sync", "probe.txt", "data/probe.txt") end
      return os.run({}, "upload.lua", "sync", "probe.txt", "data/probe.txt")
    end)
    if not ok then print("push failed: " .. tostring(err)) end
  else
    print("no upload.lua or no http - copy probe.txt off manually")
  end
else
  snapshot()
end
