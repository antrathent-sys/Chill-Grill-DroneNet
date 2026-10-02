--- watch: the base's read-only feed, for the control room's screens on a
-- computer of their own, and later for outside watchers like an ATC tower.
--
-- The base is the only computer that holds the drones' keys, and it should
-- stay that way: whatever holds a drone's key can order that drone about. A
-- computer that only SHOWS the fleet gets a key of its own instead
-- (`seckey watch new <name>` on the base keeps it in .watchkeys; the watcher
-- keeps it as .watchkey and is labelled <name>). The base re-sends what it
-- hears, sealed again with that key. It opens the feed and nothing else: no
-- drone, depot or base accepts anything sealed with it.
--
-- What goes out, on W.CHANNEL, direction SEC.DIR.BASE_TO_WATCH, one envelope
-- per watcher with the watcher's name as its id:
--
--   every telemetry and route packet the base opens, as the drone sent it,
--   with its id moved to `unit` - opening a sealed packet stamps `id` with the
--   sealer's name, which on this channel is the watcher's own;
--
--   every W.EVERY seconds a summary of what only the base knows: the open
--   jobs (who, from, to, state, which unit), the queue, rides done since the
--   base started, and the places it knows, so a watcher needs no pads.lua.
--
-- Everything sealed is a flat table (lib/seclink.lua), so the lists travel as
-- strings: jobs "id|unit|state|who|from|to;..." and places "name:x:z:kind;...".
--
-- Pure: tables in, tables out. tools/test_watch.lua runs it on the desktop.

local W = {}

W.VERSION = 1
W.CHANNEL = 7213
W.EVERY = 2         -- s between summaries
W.STALE = 10        -- s without a summary before a watcher calls the base lost
W.JOBS_MAX = 8
W.PLACES_MAX = 40
W.DONE_SHOW = 60    -- s a finished job stays in the summary, so the screens show it land

local function str(v) return type(v) == "string" and v ~= "" end
local function num(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end
local function clean(s) return (tostring(s or ""):gsub("[|;:\30\31]", " ")) end

-- PUBLIC watchers: a computer that shows CINDER's units to other people -
-- the traffic tower (AVIONICS.md). Named "tower" or "tower-<anything>" in
-- .watchkeys. It is told only where each unit is and how it moves - no jobs,
-- no customers, no places, no routes - and nothing at all while the base is
-- in stealth (Alex, 2026-10-02: "a stealth toggle to hide the whole cinder
-- network"). Every W.EVERY s it is told whether stealth is on.
function W.isPublic(name)
  return type(name) == "string" and (name == "tower" or name:match("^tower%-") ~= nil)
end

--- One telemetry packet (as W.wrap left it) for a public watcher, or nil.
function W.publicUnit(t)
  if type(t) ~= "table" or t.type ~= "tlm" or not str(t.unit) or not (num(t.x) and num(t.z)) then return nil end
  return { type = "cinder.unit", unit = t.unit, x = t.x, y = num(t.y) and t.y or 0, z = t.z,
           vx = num(t.vx) and t.vx or nil, vz = num(t.vz) and t.vz or nil, vv = num(t.vv) and t.vv or nil,
           spd = num(t.spd) and t.spd or 0, hdg = num(t.hdg) and t.hdg or nil,
           phase = str(t.phase) and t.phase or nil }
end

function W.publicStatus(stealth) return { type = "cinder.status", stealth = stealth and true or false } end

--- A packet the base opened, ready to seal again for a watcher: its flat
-- fields, with the drone's id kept in `unit`.
function W.wrap(body)
  local t = {}
  for k, v in pairs(body or {}) do
    local tv = type(v)
    if type(k) == "string" and (tv == "number" or tv == "string" or tv == "boolean") then t[k] = v end
  end
  t.unit = body and body.id
  return t
end

--- ...and on the watcher's side, the drone's id put back.
function W.unwrap(body)
  if type(body) == "table" and str(body.unit) then body.id, body.unit = body.unit, nil end
  return body
end

-- a job's state -> the ORDER screen's stage: QUE, PCK, FLY, DRP
W.STAGE = { assigned = 1, enroute = 2, waiting = 2, relocate = 2, riding = 3, done = 4 }

--- A job's short code: "J-" and the last four digits of its number.
function W.code(id)
  local n = tostring(id or ""):match("^j%-(%d+)")
  return n and ("J-" .. n:sub(-4)) or clean(id):upper():sub(1, 8)
end

--- The summary. jobs: ops's jobs by id; queued: how many are waiting for a
-- unit; done: rides finished since the base started; places: pads.lua's list;
-- now: os.clock() on the base.
function W.summary(jobs, queued, done, places, now, trips)
  now = now or 0
  local show = {}
  for _, j in pairs(jobs or {}) do
    if type(j) == "table" and str(j.id) then
      local recent = j.state == "done" and num(j.updated) and now - j.updated <= W.DONE_SHOW
      if (j.state ~= "done" and j.state ~= "failed") or recent then show[#show + 1] = j end
    end
  end
  table.sort(show, function(a, b) return (a.at or 0) > (b.at or 0) end)
  local parts = {}
  for i = 1, math.min(#show, W.JOBS_MAX) do
    local j = show[i]
    parts[#parts + 1] = table.concat({ clean(j.id), clean(j.drone), clean(j.state), clean(j.who),
                                       clean(j.pad), clean(j.toName) }, "|")
  end
  local ps = {}
  for _, p in ipairs(places or {}) do
    if #ps >= W.PLACES_MAX then break end
    if type(p) == "table" and str(p.name) and num(p.x) and num(p.z) then
      ps[#ps + 1] = string.format("%s:%d:%d:%s", clean(p.name), math.floor(p.x), math.floor(p.z), clean(p.kind or "dock"))
    end
  end
  -- admin trips: lib/trip.lua's T.line for each ("id|drone|state|seg/n|stop|who")
  local ts = {}
  for _, line in ipairs(trips or {}) do
    if #ts >= W.JOBS_MAX then break end
    ts[#ts + 1] = (tostring(line):gsub("[;:\30\31]", " "))
  end
  return { v = W.VERSION, type = "ops", t = now, jobs = table.concat(parts, ";"),
           queue = math.floor(tonumber(queued) or 0), done = math.floor(tonumber(done) or 0),
           places = table.concat(ps, ";"), trips = table.concat(ts, ";") }
end

--- A summary as the watcher uses it: { jobs = { {id, code, drone, state,
-- stage, who, from, to}, ... }, queue, done, places = { {name, x, z, kind} } },
-- or nil if it is not one.
function W.parse(body)
  if type(body) ~= "table" or body.type ~= "ops" or body.v ~= W.VERSION then return nil end
  local out = { jobs = {}, places = {}, trips = {}, queue = tonumber(body.queue) or 0, done = tonumber(body.done) or 0 }
  for item in tostring(body.trips or ""):gmatch("[^;]+") do
    local f = {}
    for v in (item .. "|"):gmatch("([^|]*)|") do f[#f + 1] = v end
    if str(f[1]) then
      out.trips[#out.trips + 1] = { id = f[1], drone = f[2], state = f[3], leg = f[4], stop = f[5], who = f[6] }
    end
  end
  for item in tostring(body.jobs or ""):gmatch("[^;]+") do
    local f = {}
    for v in (item .. "|"):gmatch("([^|]*)|") do f[#f + 1] = v end
    if str(f[1]) then
      local function opt(v) return str(v) and v or nil end
      out.jobs[#out.jobs + 1] = { id = f[1], code = W.code(f[1]), drone = opt(f[2]), state = opt(f[3]),
                                  stage = W.STAGE[f[3]] or 1, who = opt(f[4]), from = opt(f[5]), to = opt(f[6]) }
    end
  end
  for item in tostring(body.places or ""):gmatch("[^;]+") do
    local name, x, z, kind = item:match("^([^:]+):(%-?%d+):(%-?%d+):([^:]*)$")
    if name then out.places[#out.places + 1] = { name = name, x = tonumber(x), z = tonumber(z), kind = kind } end
  end
  return out
end

--- The job a unit is on, by its id in any case, or nil.
function W.jobFor(ops, unit)
  if not (ops and unit) then return nil end
  unit = tostring(unit):lower()
  for _, j in ipairs(ops.jobs or {}) do
    if tostring(j.drone or ""):lower() == unit then return j end
  end
  return nil
end

return W
