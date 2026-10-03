-- probe: dump what CC: Sable reports on this drone, and check it against the
-- sensors fly.lua currently uses. Run it once on the pod, sitting still, then
-- again while moving. Read-only: it never touches the thruster.
--
--   probe            one snapshot
--   probe watch      refresh once a second until Ctrl+T
--   probe save [lbl] one snapshot, written to probe.txt (or probe_<lbl>.txt)
--                    and pushed to the repo as data/probe.txt (data/probe-pose-<lbl>.txt)
--                    (terminals cannot be copied out of, so this is how the
--                     output gets somewhere readable)
--   probe here <x> <y> <z>
--                    compare pose and gps against YOUR F3 position. Use this
--                    rather than trusting either source against the other.
--   probe ticks [secs]  how fast the world really runs (default 5 s): server
--                    ticks per real second, and how often Sable's pose of this
--                    craft actually changes per tick. Run it while the craft
--                    MOVES - in a second tab (`bg probe ticks`) while fly
--                    hovers - since a latched craft never changes.
--   probe log [secs] sample everything for N seconds (default 30) into
--                    probelog.csv and push it. MOVE THE CRAFT during this:
--                    a stationary sample cannot tell us what frame the pose is
--                    in, nor whether the quaternion populates under motion.

-- CC: Advanced Math hands the orientation over as a quaternion OBJECT - the
-- scalar in .a, the vector in .v - so reading .x/.w off it gives nothing.
-- That is why every probe up to 2026-10-03 printed 0,0,0,0 ("dead"); it
-- never was. Flattened here so the rest of this file reads x, y, z, w.
if sublevel then
  local real = sublevel
  local function flat(fn)
    return function(...)
      local p = fn(...)
      local o = type(p) == "table" and p.orientation
      if type(o) == "table" and type(o.v) == "table" then
        p.orientation = { x = o.v.x, y = o.v.y, z = o.v.z, w = o.a }
      end
      return p
    end
  end
  sublevel = setmetatable({ getLogicalPose = flat(real.getLogicalPose), getLastPose = flat(real.getLastPose) },
    { __index = real })
end

local WATCH = arg[1] == "watch"
local SAVE  = arg[1] == "save"
local LABEL = SAVE and arg[2] and arg[2]:gsub("[^%w_%-]", "") or nil
local SAVE_LOCAL  = LABEL and ("probe_" .. LABEL .. ".txt") or "probe.txt"
local SAVE_REMOTE = LABEL and ("data/probe-pose-" .. LABEL .. ".txt") or "data/probe.txt"
local LOG   = arg[1] == "log"
local LOGSECS = tonumber(arg[2]) or 30
local HERE  = arg[1] == "here" and {
  x = tonumber(arg[2]), y = tonumber(arg[3]), z = tonumber(arg[4]) } or nil
if HERE and not (HERE.x and HERE.y and HERE.z) then
  error("usage: probe here <x> <y> <z>   (your F3 position)", 0)
end

-- How often the world moves. Every sublevel call waits for a server tick, so
-- reading the pose back to back takes one read per tick: reads per real
-- second is the server's tick rate (20 when healthy), and the share of reads
-- whose pose differs from the one before is how often Sable's physics updates
-- what a computer can see (Sable steps inside each tick, 2 substeps of 25 ms
-- by default). Asked 2026-10-01: "the sample rate got cut in half for the
-- physics calc" - this says whether it is the server's ticks or the physics.
if arg[1] == "ticks" then
  if not sublevel then error("probe ticks: no sublevel API - is this computer on a craft?", 0) end
  local secs = tonumber(arg[2]) or 5
  print(string.format("probe ticks: reading the pose every tick for %g s - keep the craft moving", secs))
  local function key(p)
    if type(p) ~= "table" or type(p.position) ~= "table" then return nil end
    local q = p.orientation or {}
    return string.format("%.6f %.6f %.6f %.6f %.6f %.6f %.6f", p.position.x or 0, p.position.y or 0, p.position.z or 0,
      q.x or 0, q.y or 0, q.z or 0, q.w or 0)
  end
  local t0, c0 = os.epoch("utc"), os.clock()
  local reads, changes, last, run, gaps = 0, 0, nil, 0, {}
  while os.epoch("utc") - t0 < secs * 1000 do
    local ok, pose = pcall(sublevel.getLogicalPose)
    local k = ok and key(pose) or nil
    reads = reads + 1
    run = run + 1
    if k and last and k ~= last then
      changes = changes + 1
      gaps[run] = (gaps[run] or 0) + 1
      run = 0
    end
    if not last then run = 0 end         -- count gaps from the first pose read
    last = k or last
  end
  local real, game = (os.epoch("utc") - t0) / 1000, os.clock() - c0
  print(string.format("%d reads in %.2f s real, %.2f s of game time", reads, real, game))
  print(string.format("  server: %.1f ticks a second (20 is healthy)", reads / real))
  if changes == 0 then
    print("  the pose never changed - the craft is still (latched?). Run it while it moves.")
  else
    print(string.format("  pose changed on %d of %d reads (%.0f%%)", changes, reads - 1, 100 * changes / math.max(1, reads - 1)))
    local keys = {}
    for n in pairs(gaps) do keys[#keys + 1] = n end
    table.sort(keys)
    for _, n in ipairs(keys) do print(string.format("    every %d tick%s: %d times", n, n == 1 and "" or "s", gaps[n])) end
    print("  every 1 tick = the physics updates each tick; every 2 = it moves every other tick")
  end
  return
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

    -- Live attitude from the tables + gimbal, using the fitted preset. This is
    -- the thing the whole exercise was for: a real quaternion, on the pod.
    if fs.exists("lib/attitude.lua") and gim then
      local okA, ATT = pcall(dofile, "lib/attitude.lua")
      if okA and ATT and ATT.presets then
        local pre = ATT.presets.airframe1
        local byName = {}
        for _, t in ipairs(navList) do byName[t.name] = t.p end
        local tables = {}
        for _, e in ipairs(pre.tables) do
          local p = byName[e.name]
          if p then
            local okr, ang = pcall(p.getRelativeAngle)
            if okr then tables[#tables + 1] = { mount = ATT.mountFrom(e), angle = ang } end
          end
        end
        local ga = gim.getAngles()
        if #tables >= 2 then
          local q, diag = ATT.estimate(tables, { pitch = ga[1], roll = ga[2], signs = pre.gimbalSigns },
            ATT.vec.new(0, 0, -1))
          print("attitude (TRIAD, " .. #tables .. " tables + gimbal):")
          if q then
            local g = ATT.gravityFromGimbal(ga[1], ga[2], pre.gimbalSigns)
            local nb = diag.targetBody
            local perp = math.abs(nb.x * g.x + nb.y * g.y + nb.z * g.z)
            local tw = ATT.thrustWorld(q)
            print(string.format("  heading %6.1f deg   tables agree to %.2f deg   north.gravity %.3f %s",
              ATT.heading(q), diag.residual or 0, perp,
              perp < 0.05 and "(good)" or "(gimbal model off here)"))
            print(string.format("  thrust axis in world: %+.2f %+.2f %+.2f   quat %.3f %.3f %.3f %.3f",
              tw.x, tw.y, tw.z, q.x, q.y, q.z, q.w))
          else
            print("  no solution: " .. tostring(diag.reason))
          end
        end
      end
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
  -- Every nav table, sorted by name so the columns are stable run to run.
  -- With one table on each plane, the ones that track north and the ones
  -- that go degenerate separate themselves as the craft moves.
  local navs = {}
  for _, p in ipairs({ peripheral.find("navigation_table") }) do
    navs[#navs + 1] = { p = p, name = peripheral.getName and peripheral.getName(p) or ("nav" .. #navs) }
  end
  table.sort(navs, function(a, b) return a.name < b.name end)
  local navCols = {}
  for _, t in ipairs(navs) do navCols[#navCols + 1] = t.name:gsub("navigation_table_", "nav") end
  local gimP = peripheral.find("gimbal_sensor")

  local rows = {}
  rows[1] = "t,px,py,pz,gp,gr,qx,qy,qz,qw,qnorm,gx,gy,gz,lvx,lvy,lvz,avx,avy,avz,lpx,lpy,lpz,lqw"
    .. (#navCols > 0 and ("," .. table.concat(navCols, ",")) or "")
  local t0 = os.clock()
  local n = 0
  print(string.format("logging for %ds with %d nav tables - MOVE THE CRAFT NOW", secs, #navs))
  while os.clock() - t0 < secs do
    local t = os.clock() - t0
    local gp, gr = 0, 0
    if gimP then local okg, a = pcall(gimP.getAngles) if okg and a then gp, gr = a[1] or 0, a[2] or 0 end end
    local navVals = {}
    for i, tb in ipairs(navs) do
      local okn, v = pcall(tb.p.getRelativeAngle)
      navVals[i] = string.format("%.2f", okn and v or -1)
    end
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
      "%.2f,%.4f,%.4f,%.4f,%.2f,%.2f,%.5f,%.5f,%.5f,%.5f,%.5f,%s,%s,%s,%.4f,%.4f,%.4f,%.5f,%.5f,%.5f,%.4f,%.4f,%.4f,%.5f",
      t, p.x or 0, p.y or 0, p.z or 0, gp, gr,
      q.x or 0, q.y or 0, q.z or 0, q.w or 0, qn,
      gx and string.format("%.4f", gx) or "", gy and string.format("%.4f", gy) or "",
      gz and string.format("%.4f", gz) or "",
      lv.x or 0, lv.y or 0, lv.z or 0, av.x or 0, av.y or 0, av.z or 0,
      lp.x or 0, lp.y or 0, lp.z or 0, lq.w or 0)
      .. (#navVals > 0 and ("," .. table.concat(navVals, ",")) or "")

    if n % 6 == 0 then
      print(string.format("  %4.1fs  g %+5.1f/%+5.1f  nav %s",
        t, gp, gr, table.concat(navVals, " ")))
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
  local f = fs.open(SAVE_LOCAL, "w")
  f.write(table.concat(buf, "\n") .. "\n")
  f.close()
  print("")
  print("written to " .. SAVE_LOCAL .. " (" .. #buf .. " lines)")
  if fs.exists("upload.lua") and http then
    print("pushing to the repo as " .. SAVE_REMOTE .. " ...")
    local ok, err = pcall(function()
      if shell then return shell.run("upload", "sync", SAVE_LOCAL, SAVE_REMOTE) end
      return os.run({}, "upload.lua", "sync", SAVE_LOCAL, SAVE_REMOTE)
    end)
    if not ok then print("push failed: " .. tostring(err)) end
  else
    print("no upload.lua or no http - copy " .. SAVE_LOCAL .. " off manually")
  end
else
  snapshot()
end
