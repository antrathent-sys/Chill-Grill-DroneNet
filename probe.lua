-- probe: dump what CC: Sable reports on this drone, and check it against the
-- sensors fly.lua currently uses. Run it once on the pod, sitting still, then
-- again while moving. Read-only: it never touches the thruster.
--
--   probe            one snapshot
--   probe watch      refresh once a second until Ctrl+T
--   probe save       one snapshot, written to probe.txt and pushed to the repo
--                    (terminals cannot be copied out of, so this is how the
--                     output gets somewhere readable)
--   probe here <x> <y> <z>
--                    compare pose and gps against YOUR F3 position. Use this
--                    rather than trusting either source against the other.
--   probe log [secs] sample everything for N seconds (default 30) into
--                    probelog.csv and push it. MOVE THE CRAFT during this:
--                    a stationary sample cannot tell us what frame the pose is
--                    in, nor whether the quaternion populates under motion.

local WATCH = arg[1] == "watch"
local SAVE  = arg[1] == "save"
local LOG   = arg[1] == "log"
local LOGSECS = tonumber(arg[2]) or 30
local HERE  = arg[1] == "here" and {
  x = tonumber(arg[2]), y = tonumber(arg[3]), z = tonumber(arg[4]) } or nil
if HERE and not (HERE.x and HERE.y and HERE.z) then
  error("usage: probe here <x> <y> <z>   (your F3 position)", 0)
end

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

  -- logicalPose and lastPose can differ; print both while we work out which
  -- one Sable actually keeps up to date.
  local okl, last = pcall(sublevel.getLastPose)
  if okl and type(last) == "table" and last.position then
    print("getLastPose  : pos " .. v3(last.position))
    if last.orientation then
      local l = last.orientation
      local ln = (l.x or 0)^2 + (l.y or 0)^2 + (l.z or 0)^2 + (l.w or 0)^2
      print("               ori " .. v3(l) .. string.format(" w=%8.4f  norm %.4f%s",
        l.w or 0, ln, (math.abs(ln - 1) < 0.01) and " (valid)" or " <<< NOT A ROTATION"))
    end
  end

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

  -- Which source is telling the truth? Comparing them against EACH OTHER only
  -- says they disagree. Ground truth from F3 says which one is wrong.
  local gx, gy, gz = gps.locate(1)
  if gx then
    print(string.format("gps.locate   : %10.4f %10.4f %10.4f", gx, gy, gz))
  else
    print("gps.locate   : no fix")
  end
  if HERE then
    print(string.format("your F3      : %10.4f %10.4f %10.4f", HERE.x, HERE.y, HERE.z))
    local function err(label, p)
      if not p then return end
      local dx, dy, dz = p.x - HERE.x, p.y - HERE.y, p.z - HERE.z
      local d = math.sqrt(dx * dx + dy * dy + dz * dz)
      print(string.format("  %-12s off by %7.2f %7.2f %7.2f   (%.1f blocks)%s",
        label, dx, dy, dz, d, d < 4 and "  <- matches reality" or ""))
    end
    err("pose", pose.position)
    if gx then err("gps", { x = gx, y = gy, z = gz }) end
  elseif gx and pose.position then
    local p = pose.position
    print(string.format("pose - gps   : %10.4f %10.4f %10.4f", p.x - gx, p.y - gy, p.z - gz))
    print("  (they disagree - run `probe here <x> <y> <z>` with your F3 position")
    print("   to find out which one is wrong)")
  end

  -- A rotation quaternion must have unit norm. A null one silently behaves
  -- like identity in the rotate maths, so check before believing any of it.
  local q = pose.orientation
  if type(q) == "table" then
    local qn = (q.x or 0)^2 + (q.y or 0)^2 + (q.z or 0)^2 + (q.w or 0)^2
    print(string.format("quat norm    : %.4f %s", qn,
      (math.abs(qn - 1) < 0.01) and "(valid)" or "<<< NOT A ROTATION"))
    if math.abs(qn - 1) > 0.01 then
      print("  orientation is degenerate - every axis reading below is meaningless.")
      print("  try getLastPose(), and try again while the contraption is MOVING.")
    end
  end
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
  -- Every nav table, by name. Two in orthogonal planes are what the TRIAD
  -- attitude solution needs, so each reading has to be attributable.
  local navs = { peripheral.find("navigation_table") }
  if #navs > 0 then
    print("navigation_table x" .. #navs .. ":")
    local navList = {}
    for _, p in ipairs(navs) do
      navList[#navList + 1] = { p = p, name = peripheral.getName and peripheral.getName(p) or "?" }
    end
    table.sort(navList, function(a, b) return a.name < b.name end)
    local shownMethods = false
    for _, t in ipairs(navList) do
      if not shownMethods then
        local ms = peripheral.getMethods(t.name) or {}
        table.sort(ms)
        print("  methods: " .. table.concat(ms, " "))
        shownMethods = true
      end
      local okr, ra = pcall(t.p.getRelativeAngle)
      print(string.format("  %-22s relAngle %8.2f deg", t.name, okr and ra or -1))
      if okr then
        -- fly.lua computes heading = (HDG_SIGN * relAngle + HDG_OFFSET) % 360.
        -- If the nose is pointing NORTH right now, this is the HDG_OFFSET that
        -- makes that read 0. Point north (F3 shows facing), run probe, copy it.
        print(string.format("  %-22s   if nose is north now: HDG_OFFSET = %.1f", "", (-ra) % 360))
      end
    end
    if #navs >= 2 then
      print("  two tables: tilt the craft and re-run to see which plane each is in")
    end
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

--- Sample the moving values into a CSV. One row per sample, so the frame
-- question is answerable: if pose.position tracks gps as the craft moves, it
-- is world with an offset; if it does not move at all, it is something else.
local function logRun(secs)
  local rows = {}
  rows[1] = "t,px,py,pz,qx,qy,qz,qw,qnorm,gx,gy,gz,lvx,lvy,lvz,avx,avy,avz,lpx,lpy,lpz,lqw"
  local t0 = os.clock()
  local n = 0
  print(string.format("logging for %ds - MOVE THE CRAFT NOW", secs))
  while os.clock() - t0 < secs do
    local t = os.clock() - t0
    local okp, pose = pcall(sublevel.getLogicalPose)
    local okl, last = pcall(sublevel.getLastPose)
    local okv, lv = pcall(sublevel.getLinearVelocity)
    local oka, av = pcall(sublevel.getAngularVelocity)
    local gx, gy, gz = gps.locate(0.5)

    local p = (okp and type(pose) == "table" and pose.position) or {}
    local q = (okp and type(pose) == "table" and pose.orientation) or {}
    local lp = (okl and type(last) == "table" and last.position) or {}
    local lq = (okl and type(last) == "table" and last.orientation) or {}
    lv = (okv and type(lv) == "table") and lv or {}
    av = (oka and type(av) == "table") and av or {}
    local qn = (q.x or 0)^2 + (q.y or 0)^2 + (q.z or 0)^2 + (q.w or 0)^2

    n = n + 1
    rows[n + 1] = string.format(
      "%.2f,%.4f,%.4f,%.4f,%.5f,%.5f,%.5f,%.5f,%.5f,%s,%s,%s,%.4f,%.4f,%.4f,%.5f,%.5f,%.5f,%.4f,%.4f,%.4f,%.5f",
      t, p.x or 0, p.y or 0, p.z or 0,
      q.x or 0, q.y or 0, q.z or 0, q.w or 0, qn,
      gx and string.format("%.4f", gx) or "", gy and string.format("%.4f", gy) or "",
      gz and string.format("%.4f", gz) or "",
      lv.x or 0, lv.y or 0, lv.z or 0, av.x or 0, av.y or 0, av.z or 0,
      lp.x or 0, lp.y or 0, lp.z or 0, lq.w or 0)

    if n % 10 == 0 then
      print(string.format("  %4.1fs  pos %.1f %.1f %.1f  qnorm %.3f  n=%d",
        t, p.x or 0, p.y or 0, p.z or 0, qn, n))
    end
    sleep(0.5)
  end

  local f = fs.open("probelog.csv", "w")
  f.write(table.concat(rows, "\n") .. "\n")
  f.close()
  print(string.format("wrote probelog.csv, %d samples", n))
  if fs.exists("upload.lua") and http then
    print("pushing...")
    local ok, err = pcall(function()
      if shell then return shell.run("upload", "sync", "probelog.csv", "data/probelog.csv") end
      return os.run({}, "upload.lua", "sync", "probelog.csv", "data/probelog.csv")
    end)
    if not ok then print("push failed: " .. tostring(err)) end
  else
    print("no upload.lua or no http - copy probelog.csv off manually")
  end
end

if HERE then
  snapshot()
elseif LOG then
  if not has("sublevel") then error("sublevel API missing", 0) end
  snapshot()
  print("")
  logRun(LOGSECS)
elseif WATCH then
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
