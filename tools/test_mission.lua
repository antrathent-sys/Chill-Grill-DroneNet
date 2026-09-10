-- Test lib/mission.lua. Run via python tools/run_mission_test.py
local DIR = ...

local pass, fail = 0, 0
local function check(n, c, d)
  if c then pass = pass + 1 print("  ok   " .. n)
  else fail = fail + 1 print("  FAIL " .. n .. (d and ("  " .. tostring(d)) or "")) end
end

-- minimal fs for calibrateFromLog
local vfiles = {}
_G.fs = {
  exists = function(p) return vfiles[p] ~= nil end,
  open = function(p)
    local c, pos = vfiles[p], 1
    if not c then return nil end
    return {
      readLine = function()
        if pos > #c then return nil end
        local nl = c:find("\n", pos, true)
        local l
        if nl then l = c:sub(pos, nl - 1) pos = nl + 1 else l = c:sub(pos) pos = #c + 1 end
        return l
      end,
      close = function() end,
    }
  end,
}

local m = dofile(DIR .. "/../lib/mission.lua")

local home = { name = "home", x = 0, z = 0, groundY = 64, padY = 70 }
local far  = { name = "far",  x = 600, z = 0, groundY = 80 }
local near = { name = "near", x = 60,  z = 0, groundY = 66 }
local blind = { name = "blind", x = 100, z = 0 }   -- no groundY

print("cruise altitude")
local y, unk = m.cruiseAltitude(home, far)
check("clears the higher end", y == 80 + m.policy.MIN_CLEARANCE, y)
check("nothing unsurveyed", #unk == 0)
local y2, unk2 = m.cruiseAltitude(home, blind)
check("flags an unsurveyed end", #unk2 == 1 and unk2[1] == "blind", unk2[1])
check("still plans from the known end", y2 == 64 + m.policy.MIN_CLEARANCE, y2)

print("plan shape")
local p = m.plan({ from = home, to = near, dropAlt = 6 })
local names = {}
for _, l in ipairs(p.legs) do names[#names + 1] = l.leg end
check("legs are the expected sequence",
  table.concat(names, ",") == "climb,cruise,hover,action,climb,cruise,dock",
  table.concat(names, ","))
check("drop altitude above destination ground", p.dropAlt == 66 + 6, p.dropAlt)
check("distance measured", math.abs(p.distance - 60) < 0.01, p.distance)
check("dock leg carries the pad height", p.legs[#p.legs].padY == 70, p.legs[#p.legs].padY)

local pb = m.plan({ from = home, to = blind })
local bnames = {}
for _, l in ipairs(pb.legs) do bnames[#bnames + 1] = l.leg end
check("no hover/release without a ground height",
  table.concat(bnames, ",") == "climb,cruise,climb,cruise,dock", table.concat(bnames, ","))

print("energy budget")
check("round trip costs more than one way",
  p.budget.out > 0 and math.abs(p.budget.out - p.budget.back) < 1e-9)
local pf = m.plan({ from = home, to = far })
check("further costs more", pf.budget.total > p.budget.total,
  string.format("%.1f vs %.1f", pf.budget.total, p.budget.total))

print("validation")
local ok, why = m.validate(p, { energy = 90 })
check("uncalibrated perf is flagged even when energy is fine",
  not ok and table.concat(why, "|"):match("calibrated") ~= nil, table.concat(why, "|"))

m.setPerf({ cruise = 8, drain = 4, climb = 9, hover = 2 })
ok, why = m.validate(p, { energy = 90 })
check("short trip on a full battery passes", ok, table.concat(why, "|"))

ok, why = m.validate(p, { energy = 22 })
check("refuses when only reserve is left",
  not ok and table.concat(why, "|"):match("spendable") ~= nil, table.concat(why, "|"))

ok, why = m.validate(m.plan({ from = home, to = blind }), { energy = 90 })
check("refuses an unsurveyed destination",
  not ok and table.concat(why, "|"):match("drop altitude") ~= nil, table.concat(why, "|"))

print("point of no return")
local v = m.checkReturn({ x = 20, z = 0, energy = 90, home = home })
check("close and charged -> go", v == "go", v)
v = m.checkReturn({ x = 2000, z = 0, energy = 40, home = home })
check("far and middling -> not go", v ~= "go", v)
v = m.checkReturn({ x = 4000, z = 0, energy = 22, home = home })
check("far and nearly flat -> land now", v == "land now", v)
local v2, num = m.checkReturn({ x = 300, z = 400, energy = 80, home = home })
check("reports the distance home", math.abs(num.distanceHome - 500) < 0.01, num.distanceHome)

print("calibration from a log")
local rows = { "t,phase,height,err,pwr,gps,x,z,ex,ez,vxw,vzw,hdg,rawhdg,mothdg,tp,tr,p,r,vx,vy,sched,fwdRaw,latRaw,vrtRaw,fwdH,latH,energy,fuel" }
local h, e = 64, 90
for i = 1, 120 do
  local t = i * 0.5
  local phase = i <= 20 and "climb" or "dash"
  if phase == "climb" then h = h + 5 end          -- 10 b/s climb
  e = e - 0.05                                     -- 6 %/min at 0.5s steps
  local fwd = phase == "dash" and 7.5 or 0
  rows[#rows + 1] = string.format(
    "%.2f,%s,%.2f,0,0.5,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,%.2f,0,%.0f,80",
    t, phase, h, fwd, e)
end
vfiles["flightlog"] = table.concat(rows, "\n") .. "\n"

local perf, err2 = m.calibrateFromLog("flightlog")
check("reads the log", perf ~= nil, err2)
if perf then
  check("cruise speed from the dash phase", math.abs(perf.cruise - 7.5) < 0.1, perf.cruise)
  check("climb rate from the climb phase", math.abs(perf.climb - 10) < 0.5, perf.climb)
  check("drain rate in %/min", math.abs(perf.drain - 6) < 0.5, perf.drain)
end
check("missing file is reported", select(2, m.calibrateFromLog("nope")) ~= nil)

print("")
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then error("mission tests failed", 0) end
