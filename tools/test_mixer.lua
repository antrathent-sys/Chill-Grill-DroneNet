local DIR = ...
local pass, fail = 0, 0
local function check(n, c, d)
  if c then pass = pass + 1 print("  ok   " .. n)
  else fail = fail + 1 print("  FAIL " .. n .. (d and ("  " .. tostring(d)) or "")) end
end
local function near(a, b, tol) return math.abs(a - b) < (tol or 1e-6) end

-- the map two mixcal runs agreed on
local MAP = {
  vector_thruster_5 = "B1", vector_thruster_6 = "B2",
  vector_thruster_7 = "A2", vector_thruster_8 = "A1",
}
local written = {}
_G.peripheral = { wrap = function(name)
  written[name] = { pwr = 0, x = 0, y = 0 }
  return {
    setPowerNormalized = function(p) written[name].pwr = p end,
    setVector = function(x, y) written[name].x, written[name].y = x, y end,
    getThrust = function() return written[name].pwr * 100 end,
    getPower = function() return written[name].pwr end,
  }
end }

local mixer = dofile(DIR .. "/../lib/mixer.lua")
local ts = mixer.fromCorners(MAP)
check("fromCorners produced 4 thrusters", #ts == 4, #ts)
local byName = {}
for _, t in ipairs(ts) do byName[t.name] = t end
check("vt_5 is B1 -> pitch -1 roll +1", byName.vector_thruster_5.pitch == -1 and byName.vector_thruster_5.roll == 1)
check("vt_7 is A2 -> pitch +1 roll -1", byName.vector_thruster_7.pitch == 1 and byName.vector_thruster_7.roll == -1)

local n, missing = mixer.configure({ thrusters = ts })
check("configured 4, none missing", n == 4 and #missing == 0, n .. "/" .. #missing)

print("pure lift")
local a = mixer.allocate({ lift = 0.5 })
check("all four equal", near(a[1], 0.5) and near(a[2], 0.5) and near(a[3], 0.5) and near(a[4], 0.5),
      table.concat(a, ","))

print("pitch demand")
a = mixer.allocate({ lift = 0.5, pitch = 1 })
-- A corners (7,8) should rise, B corners (5,6) should fall
local m = {}
for i, t in ipairs(ts) do m[t.name] = a[i] end
check("A corners above B corners",
      m.vector_thruster_7 > m.vector_thruster_5 and m.vector_thruster_8 > m.vector_thruster_6)
check("pitch is symmetric about lift",
      near((m.vector_thruster_7 + m.vector_thruster_5) / 2, 0.5),
      (m.vector_thruster_7 + m.vector_thruster_5) / 2)
check("total lift preserved", near((a[1]+a[2]+a[3]+a[4])/4, 0.5), (a[1]+a[2]+a[3]+a[4])/4)

print("roll demand")
a = mixer.allocate({ lift = 0.5, roll = 1 })
m = {}
for i, t in ipairs(ts) do m[t.name] = a[i] end
check("1 corners above 2 corners",
      m.vector_thruster_5 > m.vector_thruster_6 and m.vector_thruster_8 > m.vector_thruster_7)

print("pitch and roll are independent")
a = mixer.allocate({ lift = 0.5, pitch = 1, roll = 1 })
m = {}
for i, t in ipairs(ts) do m[t.name] = a[i] end
-- A1 (vt_8) gets both, B2 (vt_6) gets neither
check("A1 highest and B2 lowest",
      m.vector_thruster_8 == math.max(m.vector_thruster_5, m.vector_thruster_6, m.vector_thruster_7, m.vector_thruster_8) and
      m.vector_thruster_6 == math.min(m.vector_thruster_5, m.vector_thruster_6, m.vector_thruster_7, m.vector_thruster_8))

print("saturation keeps attitude, sacrifices lift")
local sat
a, sat = mixer.allocate({ lift = 0.98, pitch = 1 })
check("flagged saturated", sat)
check("nothing above 1", math.max(a[1],a[2],a[3],a[4]) <= 1 + 1e-9, math.max(a[1],a[2],a[3],a[4]))
check("nothing below 0", math.min(a[1],a[2],a[3],a[4]) >= -1e-9, math.min(a[1],a[2],a[3],a[4]))
m = {}
for i, t in ipairs(ts) do m[t.name] = a[i] end
local diff = m.vector_thruster_7 - m.vector_thruster_5
check("pitch differential survived intact", near(diff, 2 * mixer.cfg.PITCH_AUTH, 1e-6), diff)

a, sat = mixer.allocate({ lift = 0.02, pitch = -1 })
check("also holds at the bottom", math.min(a[1],a[2],a[3],a[4]) >= -1e-9 and sat)

print("vectoring: translation is common to all four")
local v = mixer.vectors({ fwd = 0.5, lat = 0 })
local allSame = true
for i = 2, 4 do if not (near(v[i].x, v[1].x) and near(v[i].y, v[1].y)) then allSame = false end end
check("all nozzles point the same way", allSame,
      string.format("%.2f,%.2f vs %.2f,%.2f", v[1].x, v[1].y, v[4].x, v[4].y))
check("translation is non-zero", math.abs(v[1].y) > 0.1, v[1].y)

print("vectoring: yaw is tangential, so it cancels as net force")
v = mixer.vectors({ yawRate = 1 })
local sx, sy = 0, 0
for i = 1, 4 do sx = sx + v[i].x sy = sy + v[i].y end
check("net sideways force from pure yaw is zero", near(sx, 0) and near(sy, 0),
      string.format("%.4f, %.4f", sx, sy))
local anyNonZero = false
for i = 1, 4 do if math.abs(v[i].x) > 1e-6 or math.abs(v[i].y) > 1e-6 then anyNonZero = true end end
check("but individual nozzles did deflect", anyNonZero)

print("vector clamp")
v = mixer.vectors({ fwd = 99, lat = -99 })
check("clamped to VEC_MAX", math.abs(v[1].x) <= mixer.cfg.VEC_MAX and math.abs(v[1].y) <= mixer.cfg.VEC_MAX,
      v[1].x .. "," .. v[1].y)

print("write and stop reach the hardware")
mixer.write({ lift = 0.6, pitch = 0.2 })
local anyPwr = false
for _, w in pairs(written) do if w.pwr > 0 then anyPwr = true end end
check("thrusters received power", anyPwr)
mixer.stop()
local allZero = true
for _, w in pairs(written) do if w.pwr ~= 0 or w.x ~= 0 or w.y ~= 0 then allZero = false end end
check("stop zeroed everything", allZero)

print("health readback")
mixer.write({ lift = 0.4 })
local h = mixer.health()
check("reports all four", #h == 4, #h)
check("thrust readback present", h[1].thrust ~= nil)

print("")
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then error("mixer tests failed", 0) end
