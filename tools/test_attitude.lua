local DIR = ...
-- Lua 5.1 (CC) has math.atan2; the desktop runtime is newer and dropped it
math.atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
local pass, fail = 0, 0
local function check(n, c, d)
  if c then pass = pass + 1 print("  ok   " .. n)
  else fail = fail + 1 print("  FAIL " .. n .. (d and ("  " .. tostring(d)) or "")) end
end
local A = dofile(DIR .. "/../lib/attitude.lua")
local V = A.vec

-- quaternion helpers for building test cases
local function qmul(a, b)
  return { w = a.w*b.w - a.x*b.x - a.y*b.y - a.z*b.z,
           x = a.w*b.x + a.x*b.w + a.y*b.z - a.z*b.y,
           y = a.w*b.y - a.x*b.z + a.y*b.w + a.z*b.x,
           z = a.w*b.z + a.x*b.y - a.y*b.x + a.z*b.w }
end
local function qaxis(ax, deg)
  local h = math.rad(deg) / 2
  local s = math.sin(h)
  return { x = ax.x*s, y = ax.y*s, z = ax.z*s, w = math.cos(h) }
end
local function qangle(a, b)  -- angle between two rotations, degrees
  local d = math.abs(a.x*b.x + a.y*b.y + a.z*b.z + a.w*b.w)
  if d > 1 then d = 1 end
  return math.deg(2 * math.acos(d))
end

local NORTH_W = V.new(0, 0, -1)
local DOWN_W  = V.new(0, -1, 0)

-- Given a true body->world q, what would the gimbal and each table read?
local function simulate(q, mounts)
  local qc = A.conj(q)
  local gBody = A.rotate(qc, DOWN_W)
  local nBody = A.rotate(qc, NORTH_W)
  -- the gimbal angles this attitude implies, using the calibrated
  -- projected-tilt convention (see gravityFromGimbal)
  local pitch, roll = A.gimbalFromGravity(gBody)
  local tables = {}
  for _, m in ipairs(mounts) do
    local ang = A.expectedAngle(m, nBody)
    -- a real sensor never returns nil; a degenerate one returns junk
    tables[#tables + 1] = { mount = m, angle = ang or (math.random() * 360) }
  end
  return tables, { pitch = pitch, roll = roll }, nBody
end

local three = { A.mount.flat, A.mount.side, A.mount.front }

print("identity")
local q0 = { x = 0, y = 0, z = 0, w = 1 }
local t, g = simulate(q0, three)
local est, diag = A.estimate(t, g, NORTH_W)
check("recovers identity", est and qangle(est, q0) < 0.01, est and qangle(est, q0))
check("residual ~0", diag.residual and diag.residual < 0.01, diag.residual)
check("heading 0 = north", math.abs(A.heading(est)) < 0.01, A.heading(est))

print("pure yaw")
for _, deg in ipairs({ 30, 90, 180, 270, 359 }) do
  local q = qaxis(V.new(0, 1, 0), deg)          -- yaw about world up
  local tt, gg = simulate(q, three)
  local e = A.estimate(tt, gg, NORTH_W)
  check(string.format("yaw %3d recovered", deg), e and qangle(e, q) < 0.05, e and qangle(e, q))
end

print("random attitudes, all three tables")
math.randomseed(7)
local worst = 0
for i = 1, 200 do
  local ax = V.norm(V.new(math.random() - .5, math.random() - .5, math.random() - .5))
  local q = qaxis(ax, math.random() * 360)
  local tt, gg = simulate(q, three)
  local e = A.estimate(tt, gg, NORTH_W)
  if e then worst = math.max(worst, qangle(e, q)) else worst = 999 end
end
check("200 random rotations all recovered to <0.1 deg", worst < 0.1, string.format("worst %.4f deg", worst))

print("singularity: north straight along one table's normal")
-- flat table normal is body z; put body z along world north
local qSing = qaxis(V.new(1, 0, 0), -90)          -- body y (thrust) -> world -z (north)
local tt, gg, nB = simulate(qSing, three)
print(string.format("  north in body frame: %.3f %.3f %.3f  (flat table's normal is y)", nB.x, nB.y, nB.z))
check("test setup: north really is along the flat table's normal", math.abs(math.abs(nB.y) - 1) < 1e-6, nB.y)
local e, d = A.estimate(tt, gg, NORTH_W)
check("still solved with flat table degenerate", e and qangle(e, qSing) < 0.1, e and qangle(e, qSing))
check("residual still small (degenerate table ignored, not counted)", d.residual < 0.1, d.residual)

print("singularity, junk angle fed on the degenerate table")
tt[1].angle = 123.456                           -- the flat table lies
e, d = A.estimate(tt, gg, NORTH_W)
check("junk on the degenerate table does not corrupt the answer", e and qangle(e, qSing) < 0.1, e and qangle(e, qSing))

print("only two tables")
for i = 1, 50 do
  local ax = V.norm(V.new(math.random() - .5, math.random() - .5, math.random() - .5))
  local q = qaxis(ax, math.random() * 360)
  local tt2 = simulate(q, { A.mount.flat, A.mount.side })
  local gg2 = select(2, simulate(q, three))
  local e2 = A.estimate(tt2, gg2, NORTH_W)
  if not e2 or qangle(e2, q) > 0.1 then worst = 999 end
end
check("two tables suffice away from their singularities", worst ~= 999)

print("a bad reading is flagged, not hidden")
local tt3, gg3 = simulate(qaxis(V.new(0, 1, 0), 40), three)
tt3[2].angle = (tt3[2].angle + 25) % 360        -- side table off by 25 deg
local e3, d3 = A.estimate(tt3, gg3, NORTH_W)
check("residual reports the disagreement", d3.residual > 5, d3.residual)

print("leanError signs (the pitch sign once drove the lean the wrong way in flight)")
do
  local function le(p, r, tp, tr) return A.leanError(A.gravityFromGimbal(p, r), A.gravityFromGimbal(tp, tr)) end
  local ep, er = le(-10, 0, -5, 0)
  check("level nose-down too far: ep = -5", math.abs(ep + 5) < 0.2 and math.abs(er) < 0.2, ep)
  ep, er = le(0, 10, 0, 5)
  check("level port too far: er = +5", math.abs(er - 5) < 0.2 and math.abs(ep) < 0.2, er)
  ep, er = le(-77, -45.9, -26.1, -50.7)
  check("77 deg nose-down against 26: ep strongly negative", ep < -15, ep)
  ep, er = le(-44.1, -60.1, -49.2, -47.3)
  check("roll too far negative at 60 deg lean: er negative", er < -3, er)
  ep, er = le(30, 30, 30, 30)
  check("no error when equal", math.abs(ep) < 0.01 and math.abs(er) < 0.01, ep)
end

print("thrust axis in world")
local qLevel = q0
check("level: thrust points up (+y)", math.abs(A.thrustWorld(qLevel).y - 1) < 1e-9, A.thrustWorld(qLevel).y)
check("level: nose points north (-z)", math.abs(A.rotate(qLevel, A.NOSE).z + 1) < 1e-9)
local qOver = qaxis(V.new(1, 0, 0), 90)
local tw = A.thrustWorld(qOver)
check("pitched 90: thrust is horizontal", math.abs(tw.y) < 1e-9, tw.y)

print("")
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then error("attitude tests failed", 0) end
