--- attitude: full orientation from nav tables plus the gimbal, by TRIAD.
--
-- Neither Sable nor this Avionics build gives a quaternion. This builds one.
--
--   Three navigation tables in orthogonal planes each report the angle of the
--   target's projection onto their own plane. From those the target's full
--   direction in the BODY frame is recovered, with a residual that says how
--   well the three agree. The gimbal gives gravity's direction in the body
--   frame. Two directions known in both body and world is the TRIAD problem,
--   whose answer is the rotation, here returned as a quaternion.
--
-- Body frame, Minecraft-native so that the IDENTITY quaternion means level with
-- the nose north: x = starboard (s), y = thrust (t, up in hover), z = aft, so
-- the nose (n) is -z. World frame: x east, y up, z south. Quaternions rotate
-- body->world. With y up in both frames, "level" needs no base rotation.
--
-- A table is DEGENERATE when the target lies along its normal: its angle is
-- then noise. The constraint it contributes is automatically satisfied in
-- that case (d.(n x p) = 0 whenever d is parallel to n), so a degenerate
-- table does not corrupt the solution, it merely stops helping. With three
-- orthogonal tables at most one can be degenerate at once, so the solution is
-- always determined and always checkable.

local A = {}

-- ---------- vectors ----------
local function v(x, y, z) return { x = x, y = y, z = z } end
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function cross(a, b)
  return v(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
end
local function len(a) return math.sqrt(dot(a, a)) end
local function norm(a)
  local l = len(a)
  if l < 1e-12 then return v(0, 0, 0) end
  return v(a.x / l, a.y / l, a.z / l)
end
local function scale(a, k) return v(a.x * k, a.y * k, a.z * k) end
local function add(a, b) return v(a.x + b.x, a.y + b.y, a.z + b.z) end
A.vec = { new = v, dot = dot, cross = cross, len = len, norm = norm }

-- ---------- table geometry ----------
-- A table is described by its plane NORMAL and its FORWARD direction, both
-- unit vectors in the body frame and perpendicular to each other. The angle it
-- reports is measured from forward toward right, where right = forward x normal
-- (the same convention as fly.lua's correctedHeading: x right, y forward).
--
-- Presets for the three orthogonal mountings. Which physical table matches
-- which preset, and with what sign, is a mounting fact established by
-- `calibrate`, not assumed.
A.NOSE   = v(0, 0, -1)
A.THRUST = v(0, 1, 0)
A.mount = {
  -- flat, plane horizontal, arrow along the nose
  flat      = { normal = v(0, 1, 0),  forward = v(0, 0, -1) },
  -- on a side wall, plane contains nose and thrust, arrow along the nose
  side      = { normal = v(1, 0, 0),  forward = v(0, 0, -1) },
  -- on the nose or tail face, plane contains starboard and thrust
  front     = { normal = v(0, 0, 1),  forward = v(1, 0, 0) },
}

--- What a table with this mounting would report for a target direction d (body).
-- Returns degrees 0..360, or nil if the projection is too small to be
-- meaningful (the degenerate case).
function A.expectedAngle(mount, d)
  local right = cross(mount.forward, mount.normal)
  local pf, pr = dot(d, mount.forward), dot(d, right)
  local mag = math.sqrt(pf * pf + pr * pr)
  if mag < 1e-6 then return nil, 0 end
  return math.deg(math.atan2(pr, pf)) % 360, mag
end

-- ---------- step 1: projections -> target direction in body frame ----------
--- tables: array of { mount = {normal, forward}, angle = degrees }
-- Returns the unit target direction in body frame, a residual in degrees
-- (how far the worst table's reading is from what the solution predicts),
-- and how many tables were usable.
function A.targetFromTables(tables)
  -- Each table constrains d to lie in the plane spanned by its normal and its
  -- projected direction p. Equivalently d is perpendicular to c = normal x p.
  local cs = {}
  for _, t in ipairs(tables) do
    if t.angle then
      local right = cross(t.mount.forward, t.mount.normal)
      local a = math.rad(t.angle)
      local p = add(scale(t.mount.forward, math.cos(a)), scale(right, math.sin(a)))
      cs[#cs + 1] = { c = norm(cross(t.mount.normal, p)), t = t }
    end
  end
  if #cs < 2 then return nil, nil, #cs end

  -- d is the common perpendicular. Take every pair's cross product, weighted
  -- by how well conditioned that pair is, with signs aligned to the first.
  local acc, ref = v(0, 0, 0), nil
  for i = 1, #cs do
    for j = i + 1, #cs do
      local x = cross(cs[i].c, cs[j].c)
      local w = len(x)                       -- 0 when the two constraints coincide
      if w > 1e-9 then
        x = scale(x, 1 / w)
        if not ref then ref = x end
        if dot(x, ref) < 0 then x = scale(x, -1) end
        acc = add(acc, scale(x, w))
      end
    end
  end
  local d = norm(acc)
  if len(d) < 0.5 then return nil, nil, #cs end

  -- Sign is ambiguous from cross products alone: d and -d satisfy the same
  -- perpendicularity. Pick the one that reproduces the readings.
  local function residual(cand)
    local worst = 0
    for _, e in ipairs(cs) do
      local exp, mag = A.expectedAngle(e.t.mount, cand)
      -- a table whose projection is tiny is near its singularity: its angle is
      -- legitimately noisy and must not be counted as disagreement
      if exp and mag > 0.15 then
        local err = math.abs((exp - e.t.angle + 180) % 360 - 180)
        if err > worst then worst = err end
      end
    end
    return worst
  end
  local rPos, rNeg = residual(d), residual(scale(d, -1))
  if rNeg < rPos then d, rPos = scale(d, -1), rNeg end
  return d, rPos, #cs
end

-- ---------- step 2: gravity in body frame from the gimbal ----------
--- Gimbal pitch and roll (degrees) to the unit "down" vector in the body
-- frame, treating pitch as the elevation of the nose axis and roll as the
-- elevation of the starboard axis, each independently.
--
-- VALIDITY. Fitted against a 43-sample tumble log on 2026-09-10, this was the
-- best of every standard Euler ordering and two non-Euler models, and it is
-- near-perfect below about 30 degrees of tilt (north.gravity within 0.005 to
-- 0.02 of zero). Beyond roughly 45 degrees it is NOT trustworthy: the log
-- contains readings such as (131.8, -127.1) whose sines square-sum above 1,
-- which no pair of orthogonal axis elevations can produce, so the real gimbal
-- uses a convention none of the candidates match at large angles. Hover,
-- docking and moderate manoeuvres are fine. A VTOL transition through 90
-- degrees is not, until the gimbal is calibrated at known stationary
-- attitudes. See BACKLOG.md.
function A.gravityFromGimbal(pitchDeg, rollDeg, signs)
  signs = signs or {}
  local p = math.rad(pitchDeg * (signs.pitch or 1))
  local r = math.rad(rollDeg * (signs.roll or 1))
  local sx, sz = -math.sin(r), math.sin(p)
  local y2 = math.max(0, 1 - sx * sx - sz * sz)
  -- past 90 on either axis means over the top: the vertical sense flips
  local sgn = (math.cos(p) >= 0 and math.cos(r) >= 0) and -1 or 1
  return v(sx, sgn * math.sqrt(y2), sz)
end

--- Whether a gimbal reading is inside the range this model is trusted for.
function A.gimbalTrusted(pitchDeg, rollDeg, limitDeg)
  local lim = limitDeg or 45
  return math.abs(pitchDeg) <= lim and math.abs(rollDeg) <= lim
end

-- ---------- presets ----------
-- The mounting fitted from data/probelog-run8-sixtables-tumble.csv by
-- tools/fit_mounts.py: all five tables agree to 0.00 degrees under it, and the
-- fitted heading swung 78.9 degrees between the two rest states against
-- nav4's own 79.0. Axis strings are the body frame above.
A.presets = {
  airframe1 = {
    gimbalSigns = { pitch = 1, roll = 1 },
    tables = {
      { name = "navigation_table_4", normal = "-y", forward = "+x" },
      { name = "navigation_table_5", normal = "-x", forward = "-z" },
      { name = "navigation_table_7", normal = "+z", forward = "-x" },
      { name = "navigation_table_8", normal = "+x", forward = "+z" },
      { name = "navigation_table_9", normal = "-z", forward = "+x" },
    },
  },
}
local AXIS = { ["+x"] = v(1,0,0), ["-x"] = v(-1,0,0), ["+y"] = v(0,1,0),
               ["-y"] = v(0,-1,0), ["+z"] = v(0,0,1), ["-z"] = v(0,0,-1) }
--- Turn a preset entry into a mount table.
function A.mountFrom(entry)
  return { normal = AXIS[entry.normal], forward = AXIS[entry.forward] }
end

-- ---------- step 3: TRIAD ----------
--- Two directions known in both frames -> rotation body->world as a quaternion.
-- Primary pair is trusted exactly; the secondary only fixes the roll about it.
-- Gravity is the primary here because the gimbal is the cleaner sensor.
function A.triad(b1, b2, w1, w2)
  local tb1 = norm(b1)
  local tb2 = norm(cross(b1, b2))
  local tb3 = cross(tb1, tb2)
  local tw1 = norm(w1)
  local tw2 = norm(cross(w1, w2))
  local tw3 = cross(tw1, tw2)
  if len(tb2) < 1e-9 or len(tw2) < 1e-9 then return nil, "reference directions are parallel" end

  -- R = Tw * Tb^T, columns of Tw, rows of Tb
  local R = {}
  local Tw, Tb = { tw1, tw2, tw3 }, { tb1, tb2, tb3 }
  for i = 1, 3 do
    R[i] = {}
    for j = 1, 3 do
      local s = 0
      for k = 1, 3 do
        local wk, bk = Tw[k], Tb[k]
        local wi = (i == 1) and wk.x or (i == 2) and wk.y or wk.z
        local bj = (j == 1) and bk.x or (j == 2) and bk.y or bk.z
        s = s + wi * bj
      end
      R[i][j] = s
    end
  end
  return A.matToQuat(R)
end

--- 3x3 rotation matrix -> unit quaternion {x,y,z,w}. Shepperd's method, so it
-- is stable for every rotation including 180 degrees.
function A.matToQuat(R)
  local tr = R[1][1] + R[2][2] + R[3][3]
  local q = {}
  if tr > 0 then
    local s = math.sqrt(tr + 1) * 2
    q.w = 0.25 * s
    q.x = (R[3][2] - R[2][3]) / s
    q.y = (R[1][3] - R[3][1]) / s
    q.z = (R[2][1] - R[1][2]) / s
  elseif R[1][1] > R[2][2] and R[1][1] > R[3][3] then
    local s = math.sqrt(1 + R[1][1] - R[2][2] - R[3][3]) * 2
    q.w = (R[3][2] - R[2][3]) / s
    q.x = 0.25 * s
    q.y = (R[1][2] + R[2][1]) / s
    q.z = (R[1][3] + R[3][1]) / s
  elseif R[2][2] > R[3][3] then
    local s = math.sqrt(1 + R[2][2] - R[1][1] - R[3][3]) * 2
    q.w = (R[1][3] - R[3][1]) / s
    q.x = (R[1][2] + R[2][1]) / s
    q.y = 0.25 * s
    q.z = (R[2][3] + R[3][2]) / s
  else
    local s = math.sqrt(1 + R[3][3] - R[1][1] - R[2][2]) * 2
    q.w = (R[2][1] - R[1][2]) / s
    q.x = (R[1][3] + R[3][1]) / s
    q.y = (R[2][3] + R[3][2]) / s
    q.z = 0.25 * s
  end
  return q
end

--- Rotate a body vector into world by q, or world into body with conj.
function A.rotate(q, vec)
  local qx, qy, qz, qw = q.x, q.y, q.z, q.w
  local tx = 2 * (qy * vec.z - qz * vec.y)
  local ty = 2 * (qz * vec.x - qx * vec.z)
  local tz = 2 * (qx * vec.y - qy * vec.x)
  return v(vec.x + qw * tx + (qy * tz - qz * ty),
           vec.y + qw * ty + (qz * tx - qx * tz),
           vec.z + qw * tz + (qx * ty - qy * tx))
end
function A.conj(q) return { x = -q.x, y = -q.y, z = -q.z, w = q.w } end

-- ---------- the whole thing ----------
--- tables: array of { mount, angle }.  gimbal: { pitch, roll, signs }.
-- targetWorld: unit direction to the target in world frame. For the north
-- magnet that is constant (0,0,-1). For a compass it is the direction from
-- the craft to world spawn, which the caller computes from position.
-- Returns quaternion body->world, and diagnostics.
function A.estimate(tables, gimbal, targetWorld)
  local dBody, resid, used = A.targetFromTables(tables)
  if not dBody then
    return nil, { reason = "fewer than two usable tables", used = used }
  end
  local gBody = A.gravityFromGimbal(gimbal.pitch, gimbal.roll, gimbal.signs)
  local gWorld = v(0, -1, 0)                  -- Minecraft: y up, so down is -y
  local q, err = A.triad(gBody, dBody, gWorld, targetWorld)
  if not q then return nil, { reason = err, used = used, residual = resid } end
  return q, { residual = resid, used = used, targetBody = dBody }
end

--- Heading (compass bearing, 0 north 90 east) from a body->world quaternion:
-- where the nose points, projected to the horizontal.
function A.heading(q)
  local nose = A.rotate(q, A.NOSE)
  return math.deg(math.atan2(nose.x, -nose.z)) % 360
end

--- The thrust axis in world coordinates: what the attitude loop actually
-- steers. Well behaved at every attitude, including through the transition.
function A.thrustWorld(q) return A.rotate(q, A.THRUST) end

return A
