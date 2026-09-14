local DIR = ...
local pass, fail = 0, 0
local function check(n, c, d)
  if c then pass = pass + 1 print("  ok   " .. n)
  else fail = fail + 1 print("  FAIL " .. n .. (d and ("  " .. tostring(d)) or "")) end
end

local link = dofile(DIR .. "/../lib/link.lua")

print("findRadio")
local function periph(modems)            -- name -> isWireless (nil = not a modem)
  return {
    getNames = function()
      local t = {} for k in pairs(modems) do t[#t + 1] = k end return t
    end,
    getType = function(n) return modems[n] == nil and "altitude_sensor" or "modem" end,
    call = function(n, m)
      if m == "isWireless" then return modems[n] end
      error("no method", 0)
    end,
  }
end
check("picks the wireless modem, not the wired one",
  link.findRadio(periph({ modem_wired = false, modem_ender = true })) == "modem_ender")
check("nil when only wired modems",
  link.findRadio(periph({ modem_a = false, modem_b = false })) == nil)
check("nil with no peripheral table", link.findRadio(nil) == nil)
check("stable choice: first by name",
  link.findRadio(periph({ zz_radio = true, aa_radio = true })) == "aa_radio")
local throwing = periph({ modem_x = true })
throwing.call = function() error("detached", 0) end
check("a modem that throws is skipped, not fatal", link.findRadio(throwing) == nil)

print("offLine")
check("on the line is 0", math.abs(link.offLine(50, 0, 0, 0, 100, 0)) < 1e-9)
-- travelling +x (east), world z grows south; right of travel is +z (south)
check("south of an eastbound line is positive", link.offLine(50, 10, 0, 0, 100, 0) > 0,
  link.offLine(50, 10, 0, 0, 100, 0))
check("north of an eastbound line is negative", link.offLine(50, -10, 0, 0, 100, 0) < 0)
check("magnitude", math.abs(math.abs(link.offLine(50, 10, 0, 0, 100, 0)) - 10) < 1e-9)
check("nil without a start", link.offLine(1, 1, nil, 0, 5, 5) == nil)
check("nil for a zero-length line", link.offLine(1, 1, 3, 3, 3.2, 3.2) == nil)

print("packet")
local s = { t = 12.345, phase = "cruise", h = 250.26, e = -3.14, x = 100.04, z = 49.96,
            vx = 150, vz = 80, vv = -1.23, hdg = 57.6, p = -60, r = 20,
            tx = 2000.5, tz = 5000.5, sx = 0.5, sz = 0.5, sat = false }
local p = link.packet("drone-7", 3, s, { energy = 81.25, rate = -2.345 }, { pct = 64.44 },
                      { connected = false }, 4, 2, "cruise", "deliver")
check("version, id, seq", p.v == link.VERSION and p.id == "drone-7" and p.seq == 3)
check("rounded position", p.x == 100 and p.z == 50 and p.y == 250.3, string.format("%s %s %s", p.x, p.z, p.y))
check("speed from world velocity", p.spd == 170, p.spd)
-- (2000.5-100.04, 5000.5-49.96) -> 5302.8 blocks; at 170 b/s 31.2 s
check("distance and eta", p.dist == 5303 and p.eta == 31, string.format("%s %s", p.dist, p.eta))
check("tilt", p.tilt == 63, p.tilt)
check("leg bookkeeping", p.leg == 2 and p.legs == 4 and p.legKind == "cruise" and p.mode == "deliver")
check("energy, drain, fe", p.energy == 81.3 and p.drain == -2.35 and p.fe == 64.4,
  string.format("%s %s %s", p.energy, p.drain, p.fe))
check("dock and sat as 0/1", p.dock == 0 and p.sat == 0)
check("off-line present", type(p.off) == "number")
local flat = true
for k, v in pairs(p) do if type(v) == "table" or type(v) == "function" then flat = false end end
check("flat: no nested tables", flat)
local q = link.packet("d", 1, { t = 0, phase = "climb", x = 0, z = 0, h = 70, vx = 0, vz = 0 }, nil, nil, nil)
check("no target: no dist, eta or off", q.dist == nil and q.eta == nil and q.off == nil)
check("NaN rounds to nil", link.round(0 / 0, 1) == nil)
check("slow craft gets no eta", link.packet("d", 1, { t = 0, phase = "hold", x = 0, z = 0, h = 1,
  vx = 1, vz = 0, tx = 10, tz = 0 }).eta == nil)

print("check")
check("a real packet passes", link.check(p) == true)
local ok, why = link.check({ v = 99, id = "x", seq = 1, phase = "a", t = 0, x = 0, y = 0, z = 0 })
check("wrong version rejected", ok == false and why:find("version"), why)
ok, why = link.check({ v = link.VERSION, id = "", seq = 1, phase = "a", t = 0, x = 0, y = 0, z = 0 })
check("empty id rejected", ok == false, why)
ok, why = link.check({ v = link.VERSION, id = "x", seq = 1, phase = "a", t = 0, x = 0, z = 0 })
check("missing y rejected", ok == false and why == "no y", why)
check("non-table rejected", link.check("land") == false)

print("")
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then error("link tests failed", 0) end
