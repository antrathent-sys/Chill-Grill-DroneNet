--- mission: turn "deliver to X" into a validated leg queue.
--
-- This is the L3 layer from ARCHITECTURE.md. It never touches the thruster; it
-- produces legs for the phase machine and answers one question continuously:
-- can we still get home?
--
-- Everything here depends on PERF, which is measured, not guessed. Until a
-- real flight has been logged, `mission.perf.calibrated` is false and
-- validation says so rather than pretending.
--
--   local mission = dofile("lib/mission.lua")
--   mission.setPerf({ cruise = 8.2, drain = 3.1, climb = 9 })
--   local plan = mission.plan({ from = home, to = pad, payloadMass = 400 })
--   local ok, why = mission.validate(plan, { energy = 82 })

local mission = {}

--- Measured performance. Fill from flight logs, not from CFG.
-- cruise: blocks/sec actually achieved in the dash phase
-- drain : accumulator %/min at cruise
-- climb : blocks/sec achieved climbing
-- hover : accumulator %/min while station keeping
mission.perf = {
  cruise = 8, drain = 4, climb = 9, hover = 2,
  calibrated = false,
}

function mission.setPerf(p)
  for k, v in pairs(p) do mission.perf[k] = v end
  mission.perf.calibrated = true
  return mission.perf
end

--- Reserve policy. RESERVE_PCT is never spent; MARGIN scales the estimate up
-- to cover the fact that estimates are optimistic.
mission.policy = {
  RESERVE_PCT = 20,     -- refuse to plan into this
  MARGIN = 1.35,        -- multiply every energy estimate by this
  MIN_CLEARANCE = 12,   -- blocks of cruise altitude above the highest known ground
  ARRIVE = 8,
}

local function dist(a, b)
  local dx, dz = (b.x or 0) - (a.x or 0), (b.z or 0) - (a.z or 0)
  return math.sqrt(dx * dx + dz * dz)
end

--- Energy in accumulator percent to fly `blocks` horizontally.
function mission.cruiseCost(blocks)
  local p = mission.perf
  local secs = blocks / math.max(p.cruise, 0.1)
  return (secs / 60) * p.drain * mission.policy.MARGIN
end

--- Energy to climb from `fromY` to `toY`, and to hold for `holdSecs`.
function mission.climbCost(fromY, toY)
  local p = mission.perf
  local up = math.max(0, (toY or 0) - (fromY or 0))
  local secs = up / math.max(p.climb, 0.1)
  -- climbing costs more than hovering; charge it at the cruise rate
  return (secs / 60) * p.drain * mission.policy.MARGIN
end

function mission.holdCost(secs)
  return (secs / 60) * mission.perf.hover * mission.policy.MARGIN
end

--- Cruise altitude for a route. Takes the highest ground height either end
-- knows about, plus clearance. Ground heights come from the place registry,
-- so an unsurveyed destination is flagged rather than assumed flat.
function mission.cruiseAltitude(from, to)
  local known, unknown = {}, {}
  for _, p in ipairs({ from, to }) do
    if p.groundY then known[#known + 1] = p.groundY else unknown[#unknown + 1] = p.name or "?" end
  end
  local highest = -64
  for _, y in ipairs(known) do if y > highest then highest = y end end
  if #known == 0 then return nil, unknown end
  return highest + mission.policy.MIN_CLEARANCE, unknown
end

--- Build the leg queue for an out-and-back delivery.
-- opts: from, to (places), dropAlt (blocks above to.groundY), payloadMass
function mission.plan(opts)
  local from, to = opts.from, opts.to
  if not from or not to then error("mission.plan needs from and to", 2) end

  local cruiseY, unsurveyed = mission.cruiseAltitude(from, to)
  local d = dist(from, to)
  local dropAlt = to.groundY and (to.groundY + (opts.dropAlt or 6)) or nil

  local legs = {
    { leg = "climb",  y = cruiseY },
    { leg = "cruise", x = to.x, z = to.z, y = cruiseY },
  }
  if dropAlt then
    legs[#legs + 1] = { leg = "hover", x = to.x, z = to.z, y = dropAlt }
    legs[#legs + 1] = { leg = "action", what = "release" }
  end
  legs[#legs + 1] = { leg = "climb",  y = cruiseY }
  legs[#legs + 1] = { leg = "cruise", x = from.x, z = from.z, y = cruiseY }
  legs[#legs + 1] = { leg = "dock",   x = from.x, z = from.z, padY = from.padY or from.groundY }

  -- energy estimate, leg by leg, so validate() can say where it goes
  local startY = from.groundY or 64
  local budget = {
    out    = mission.cruiseCost(d),
    back   = mission.cruiseCost(d),
    climb  = mission.climbCost(startY, cruiseY or startY) * 2,
    manoeuvre = mission.holdCost(60),   -- align, descend, capture, slack
  }
  budget.total = budget.out + budget.back + budget.climb + budget.manoeuvre

  return {
    from = from, to = to, legs = legs, distance = d,
    cruiseY = cruiseY, dropAlt = dropAlt,
    payloadMass = opts.payloadMass,
    budget = budget,
    unsurveyed = unsurveyed,
  }
end

--- Can this plan be flown from the current state? Returns ok, reasons.
-- state: energy (percent), and optionally position
function mission.validate(plan, state)
  local reasons = {}
  local pol = mission.policy

  if not mission.perf.calibrated then
    reasons[#reasons + 1] = "performance not calibrated - fly a measured leg first, numbers are defaults"
  end
  if not plan.cruiseY then
    reasons[#reasons + 1] = "no ground height known for either end - survey before planning"
  end
  if plan.unsurveyed and #plan.unsurveyed > 0 then
    reasons[#reasons + 1] = "unsurveyed: " .. table.concat(plan.unsurveyed, ", ")
  end
  if not plan.dropAlt then
    reasons[#reasons + 1] = "destination has no ground height, cannot set a drop altitude"
  end

  local e = state.energy or -1
  if e < 0 then
    reasons[#reasons + 1] = "no accumulator reading"
  else
    local usable = e - pol.RESERVE_PCT
    if plan.budget.total > usable then
      reasons[#reasons + 1] = string.format(
        "needs %.0f%% but only %.0f%% is spendable (%.0f%% held as reserve)",
        plan.budget.total, usable, pol.RESERVE_PCT)
    end
  end

  return #reasons == 0, reasons
end

--- The point of no return, evaluated continuously in flight.
-- Returns "go" | "turn back" | "land now", plus the numbers behind it.
function mission.checkReturn(state)
  local home = state.home
  local here = { x = state.x, z = state.z }
  if not home then return "go", { reason = "no home set" } end

  local d = dist(here, home)
  local need = mission.cruiseCost(d) + mission.holdCost(30)
  local have = (state.energy or 0) - mission.policy.RESERVE_PCT

  local verdict
  if have <= 0 then
    verdict = "land now"
  elseif need > have then
    verdict = "land now"
  elseif need > have * 0.7 then
    verdict = "turn back"
  else
    verdict = "go"
  end
  return verdict, { distanceHome = d, needed = need, spendable = have }
end

--- Learn cruise speed and drain rate from a flightlog this drone just wrote.
-- Streams the file; safe on a CC computer. Returns a perf table or nil.
function mission.calibrateFromLog(path)
  if not fs or not fs.exists(path) then return nil, "no " .. tostring(path) end
  local h = fs.open(path, "r")
  local header = h.readLine()
  if not header then h.close() return nil, "empty log" end

  -- find the columns we need by name, so column order can change safely
  local col = {}
  local i = 0
  for name in header:gmatch("[^,]+") do i = i + 1 col[name] = i end
  if not (col.t and col.phase and col.fwdH and col.energy and col.height) then
    h.close() return nil, "log is missing required columns"
  end

  local dashN, dashSum = 0, 0
  local climbN, climbSum = 0, 0
  local e0, e1, t0, t1 = nil, nil, nil, nil
  local lastH, lastT = nil, nil
  while true do
    local line = h.readLine()
    if not line then break end
    local f, n = {}, 0
    for v in line:gmatch("[^,]*") do n = n + 1 f[n] = v end
    local t = tonumber(f[col.t])
    local phase = f[col.phase]
    local energy = tonumber(f[col.energy])
    local height = tonumber(f[col.height])
    if t then
      t0 = t0 or t
      t1 = t
      if energy and energy >= 0 then e0 = e0 or energy e1 = energy end
      if phase == "dash" then
        local fwd = tonumber(f[col.fwdH])
        if fwd then dashN = dashN + 1 dashSum = dashSum + math.abs(fwd) end
      elseif phase == "climb" and lastH and lastT and t > lastT then
        climbN = climbN + 1
        climbSum = climbSum + (height - lastH) / (t - lastT)
      end
      lastH, lastT = height, t
    end
  end
  h.close()

  local out = {}
  if dashN > 0 then out.cruise = dashSum / dashN end
  if climbN > 0 then out.climb = climbSum / climbN end
  if e0 and e1 and t1 and t0 and t1 > t0 then
    out.drain = (e0 - e1) / ((t1 - t0) / 60)
  end
  if not (out.cruise or out.drain) then return nil, "log had no usable dash or energy data" end
  return out
end

--- Places: destinations with the ground height that makes them plannable.
-- Backed by lib/db.lua so they survive a reboot.
function mission.places(store)
  local P = {}
  function P.put(name, place)
    place.name = name
    store:put("place:" .. name, place)
    return place
  end
  function P.get(name) return store:get("place:" .. name) end
  function P.list()
    local out = {}
    for k, v in store:iter() do
      if k:sub(1, 6) == "place:" then out[#out + 1] = v end
    end
    return out
  end
  function P.remove(name) return store:delete("place:" .. name) end
  return P
end

return mission
