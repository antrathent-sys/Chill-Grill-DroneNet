--- state: the one table the control room screens draw from (lib/screens.lua).
--
--   { units = { unit, ... }, focus = 1, unit = units[1],
--     order = {...} or nil, dest = {...} or nil, base = {...} or nil, spawn = {...} or nil,
--     log = { { t = "hhmm", msg = "..." }, ... }, system = { { name, value, level }, ... },
--     counters = { out = n, returned = n }, today = { rides = n, queue = n } or nil,
--     clock = "hhmm" }
--
-- ctx.ops is the base's own knowledge, when the screens run from its feed
-- (lib/watch.lua): the real job a unit is on - who for, from, to - wins over
-- the one followed from telemetry, and TODAY counts rides and the queue.
--
-- Built from what the drones actually send (lib/display.lua's model of the
-- sealed telemetry) plus what the base remembers between frames - the event
-- log, the job in hand and today's counts - kept in a `track`. Nothing is
-- invented: a field the drone does not send stays nil and its panel is left off.
--
-- A job opens when a cradled unit leaves its pad and closes when it cradles
-- again; its stages are QUE (opened), PCK (off the pad), FLY (under way) and
-- DRP (at the destination: a drop hover, or cradled on another pad).
--
-- `units` is a list and the screens read the focused one through
-- screens.focus, so a fleet needs no drawing changes.
--
--   local track = S.newTrack()
--   local st = S.build(model, now, { D = D, track = track, pads = pads,
--                                    clock = S.clock(os.time()), day = os.day() })
--
--   local sim = S.mock(D)   sim.tick(0.25)   local st = sim.state()

local S = {}
-- what a unit is called on screen (lib/names.lua): drone-1 -> LAMBDA-001
local NAMES = (function()
  local ok, n = pcall(dofile, "lib/names.lua")
  return ok and type(n) == "table" and n or nil
end)()
local function unitName(id) return NAMES and NAMES.unit(id) or tostring(id or ""):upper() end


local floor, max, sqrt = math.floor, math.max, math.sqrt
local atan2 = math.atan2 or math.atan

S.BASE_NAME = "M1"
S.NEAR = 16          -- blocks: this close to a pad counts as on it
S.LOG_KEEP = 30

--- In-game hours (os.time()) -> "hhmm".
function S.clock(hours)
  hours = (tonumber(hours) or 0) % 24
  local hh = floor(hours)
  return string.format("%02d%02d", hh, floor((hours - hh) * 60))
end

--- The one word for what a unit is doing, from its last packet and link state.
function S.stateWord(p, link)
  if not p or link == "LOST" or link == "NONE" then return "OFFLINE" end
  local ph = tostring(p.phase or "")
  if p.mode == "linger" then return "ON CALL" end      -- beacon: waiting on a pad after a ride, free
  if p.dock == 1 or ph == "docked" then return "CRADLED" end
  if ph == "align" or ph == "descend" or ph == "capture" or p.legKind == "dock" or p.mode == "dock" then
    return "INBOUND"
  end
  if ph == "climb" or ph == "cruise" or ph == "brake" then return "CRUISE" end
  if ph == "landed" then return "LANDED" end           -- beacon: on the ground, not latched
  if ph == "idle" then return "STANDBY" end            -- beacon: on, not flying, not docked
  return "HOLD"
end

local function near(ax, az, bx, bz)
  return ax and az and bx and bz and (ax - bx) ^ 2 + (az - bz) ^ 2 <= S.NEAR * S.NEAR
end

--- The name of the pad at (x, z): the base, a pad from pads.lua, or the
-- coordinates themselves.
function S.placeName(pads, base, x, z)
  if base and near(x, z, base.x, base.z) then return base.name end
  for _, p in ipairs(pads or {}) do
    if p.name ~= "home" and near(x, z, p.x + 0.5, p.z + 0.5) then return p.name:upper() end
  end
  return string.format("%d %d", floor(x + 0.5), floor(z + 0.5))
end

function S.newTrack()
  return { seq = 0, prev = {}, log = {}, counters = { out = 0, returned = 0 }, order = nil, day = nil }
end

function S.addLog(track, clock, msg, unit)
  local L = track.log
  L[#L + 1] = { t = clock, msg = msg, unit = unit }
  while #L > S.LOG_KEEP do table.remove(L, 1) end
end

--- Compare a unit with how it was last frame, and log, open, advance and close
-- jobs from what changed.
function S.observe(track, u, base, pads, clock)
  local pv = track.prev[u.id]
  track.prev[u.id] = { state = u.state, dock = u.dock, link = u.link }
  if not pv then
    S.addLog(track, clock, u.state == "OFFLINE" and "NO SIGNAL" or ("ACQUIRED " .. u.state), u.name)
    return
  end
  if u.link == "LOST" and pv.link ~= "LOST" then S.addLog(track, clock, "SIGNAL LOST", u.name) end
  if u.link ~= "LOST" and pv.link == "LOST" then S.addLog(track, clock, "SIGNAL OK", u.name) end

  -- a job opens when a cradled unit leaves its pad
  if pv.dock == 1 and u.dock == 0 then
    track.seq = track.seq + 1
    track.order = { code = string.format("TRK-%04d", track.seq), kind = tostring(u.mode or "flight"):upper(),
                    unit = u.id, stage = 2 }
    S.addLog(track, clock, track.order.code .. " OPEN", u.name)
  end

  local cradled = u.state == "CRADLED" and pv.state ~= "CRADLED"
  if u.state ~= pv.state and u.state ~= "OFFLINE" then
    local msg = u.state
    if cradled and u.x then msg = msg .. " " .. S.placeName(pads, base, u.x, u.z) end
    S.addLog(track, clock, msg, u.name)
  end

  local o = track.order
  if not (o and o.unit == u.id) then return end
  if (u.state == "CRUISE" or u.state == "INBOUND") and o.stage < 3 then o.stage = 3 end
  local home = cradled and base and near(u.x, u.z, base.x, base.z)
  if o.stage < 4 and (u.legKind == "hover" or (cradled and not home)) then
    o.stage = 4
    track.counters.out = track.counters.out + 1
    S.addLog(track, clock, o.code .. " DROP", u.name)
  end
  if cradled then
    if home then track.counters.returned = track.counters.returned + 1 end
    S.addLog(track, clock, o.code .. " DONE", u.name)
    track.order = nil
  end
end

--- The state table for this frame. ctx: D (lib/display.lua), track, and
-- optionally pads, spawn {x, z}, clock "hhmm", day (os.day()).
function S.build(model, now, ctx)
  local D, track = ctx.D, ctx.track
  local clock = ctx.clock or "0000"
  if ctx.day and track.day ~= ctx.day then
    if track.day then track.counters.out, track.counters.returned = 0, 0 end
    track.day = ctx.day
  end

  local base
  if model.home then
    base = { name = S.BASE_NAME, x = model.home.x, z = model.home.z }
  else
    for _, p in ipairs(ctx.pads or {}) do
      if p.name == "home" then base = { name = S.BASE_NAME, x = p.x + 0.5, z = p.z + 0.5 } end
    end
  end

  local units = {}
  for _, id in ipairs(model.order or {}) do
    local d = model.drones[id]
    local p = d.pkt
    local link = D.droneState(d, now)
    local u = { id = id:upper(), name = unitName(id), link = link, state = S.stateWord(p, link) }
    if p then
      u.x, u.z, u.alt, u.hdg, u.spd = p.x, p.z, p.y, p.hdg, p.spd
      u.fuel, u.fe, u.dock = p.energy, p.fe, p.dock
      u.mode, u.leg, u.legs, u.legKind = p.mode, p.leg, p.legs, p.legKind
      u.tx, u.tz, u.eta = p.tx, p.tz, p.eta
      u.wait = p.wait                                  -- seconds left on call, before it goes home
    end
    units[#units + 1] = u
    S.observe(track, u, base, ctx.pads, clock)
  end

  local u = units[1]
  local dest
  if u and type(u.tx) == "number" and type(u.tz) == "number" and u.state ~= "CRADLED" and u.state ~= "OFFLINE" then
    local dx, dz = u.tx - (u.x or u.tx), u.tz - (u.z or u.tz)
    dest = { name = S.placeName(ctx.pads, base, u.tx, u.tz), x = u.tx, z = u.tz,
             range = sqrt(dx * dx + dz * dz), brg = floor(math.deg(atan2(dx, -dz)) % 360 + 0.5) % 360,
             eta = u.eta }
  end

  local order
  local o = track.order
  local job
  if ctx.ops and u then
    for _, j in ipairs(ctx.ops.jobs or {}) do
      if tostring(j.drone or ""):upper() == u.id then job = j break end
    end
  end
  if job then
    order = { code = job.code, kind = "TAXI", unit = u.id, stage = job.stage or 1,
              who = job.who and job.who:upper(), from = job.from and job.from:upper(),
              to = (job.to and job.to:upper()) or (dest and dest.name), eta = dest and dest.eta }
  elseif o then
    if dest then o.to = dest.name end
    order = { code = o.code, kind = o.kind, unit = o.unit, stage = o.stage, to = o.to, eta = dest and dest.eta }
  end

  local system = {}
  if base then
    local taken = false
    for _, uu in ipairs(units) do
      if uu.state == "CRADLED" and near(uu.x, uu.z, base.x, base.z) then taken = true end
    end
    system[#system + 1] = { name = "PAD " .. base.name, value = taken and "OCCUPIED" or "CLEAR",
                            level = taken and "info" or "ok" }
  end
  if model.link then
    local rej = model.rejected or 0
    local value, level = "OK", "ok"
    if not model.link:find("^SEALED") then value, level = (model.link == "NO KEYS") and "NO KEYS" or "OPEN", "fault"
    elseif rej > 0 then value, level = "REJ " .. rej, "fault" end
    system[#system + 1] = { name = "LINK", value = value, level = level }
  end
  if ctx.feed then
    system[#system + 1] = { name = "BASE", value = ctx.feed == "OK" and "FEED OK" or "FEED LOST",
                            level = ctx.feed == "OK" and "ok" or "fault" }
  end
  local today
  if ctx.ops then
    today = { rides = ctx.ops.done or 0, queue = ctx.ops.queue or 0 }
    if today.queue > 0 then system[#system + 1] = { name = "QUEUE", value = tostring(today.queue), level = "info" } end
  end

  return { units = units, focus = 1, unit = u, order = order, dest = dest, base = base, spawn = ctx.spawn,
           log = track.log, system = system, counters = track.counters, today = today, clock = clock }
end

-- --------------------------------------------------------------------- mock

S.MOCK_CYCLE = 130
local HOME, DEPOT = { x = 0.5, z = 0.5 }, { x = -1500.5, z = 2200.5 }

--- The mock unit's packet at second s of its 130 s loop: cradled at home,
-- out to the depot, a drop hover, back, and cradled again.
function S.mockPacket(s)
  local p = { v = 1, type = "tlm", id = "drone-1", seq = floor(s), t = s, mode = "deliver", legs = 4,
              y = 250, vv = 0, tilt = 0, fe = 88, drain = -2.1, energy = 100 - s * 0.45, dock = 0 }
  local function go(a, b, f, spd, phase, legKind, leg)
    local dx, dz = b.x - a.x, b.z - a.z
    local len = sqrt(dx * dx + dz * dz)
    p.x, p.z = a.x + dx * f, a.z + dz * f
    p.vx, p.vz, p.spd = dx / len * spd, dz / len * spd, spd
    p.hdg = floor(math.deg(atan2(dx, -dz)) % 360)
    p.tx, p.tz, p.dist = b.x, b.z, len * (1 - f)
    p.eta = spd > 5 and p.dist / spd or nil
    p.phase, p.legKind, p.leg = phase, legKind, leg
  end
  if s < 8 or s >= 122 then
    p.x, p.z, p.y, p.spd, p.vx, p.vz = HOME.x, HOME.z, 70, 0, 0, 0
    p.phase, p.dock, p.mode, p.leg, p.legs, p.hdg = "docked", 1, "dock", 0, 0, 0
    if s < 8 then p.energy = 100 end
  elseif s < 14 then go(HOME, DEPOT, 0, 0, "climb", "cruise", 1) p.y = 70 + (s - 8) * 30
  elseif s < 52 then go(HOME, DEPOT, (s - 14) / 40, 70, "cruise", "cruise", 1)
  elseif s < 58 then go(HOME, DEPOT, 0.95 + (s - 52) / 120, 20, "brake", "cruise", 1)
  elseif s < 66 then go(HOME, DEPOT, 1, 0, "hold", "hover", 2) p.y = 80
  elseif s < 72 then go(DEPOT, HOME, 0, 0, "climb", "dock", 4) p.y = 80 + (s - 66) * 28
  elseif s < 112 then go(DEPOT, HOME, (s - 72) / 42, 68, "cruise", "dock", 4)
  else go(DEPOT, HOME, 1, 0, s < 116 and "align" or "descend", "dock", 4) p.y = 250 - (s - 112) * 18 end
  return p
end

--- The base's side of the mock, for the feed: a taxi job for the mock unit
-- through the loop - queued while it is cradled, riding out, at the
-- destination during the hover - and nothing on the way home.
function S.mockOps(s)
  local stage, state
  if s < 8 then stage, state = 1, "assigned"
  elseif s < 58 then stage, state = 3, "riding"
  elseif s < 66 then stage, state = 4, "done" end
  local jobs = {}
  if stage then
    jobs[1] = { id = "j-1727000042-drone-1", code = "J-0042", drone = "drone-1", state = state, stage = stage,
                who = "alex", from = "home", to = "depot" }
  end
  return { jobs = jobs, queue = s < 40 and 1 or 0, done = 12 + (s >= 58 and 1 or 0), places = {} }
end

--- A self-running stand-in for live telemetry: sim.tick(dt) advances it,
-- sim.state() is the table the screens draw. Deterministic in sim.t. With
-- opts.ops it also plays the base's feed (S.mockOps).
function S.mock(D, opts)
  local sim = { t = 0, track = S.newTrack(), model = D.newModel() }
  sim.model.home = { x = HOME.x, z = HOME.z }
  sim.model.link, sim.model.rejected = "SEALED 1 KEY", 0
  sim.pads = { { name = "home", x = 0, y = 63, z = 0 }, { name = "depot", x = -1501, y = 72, z = 2200 } }
  function sim.tick(dt)
    sim.t = sim.t + (dt or 1)
    local p = S.mockPacket(sim.t % S.MOCK_CYCLE)
    D.ingest(sim.model, p, sim.t)
  end
  function sim.state()
    local withOps = opts and opts.ops
    return S.build(sim.model, sim.t, { D = D, track = sim.track, pads = sim.pads,
                                       ops = withOps and S.mockOps(sim.t % S.MOCK_CYCLE) or nil,
                                       feed = withOps and "OK" or nil,
                                       clock = S.clock(13 + sim.t / 60), day = 1 })
  end
  sim.tick(0)
  return sim
end

return S
