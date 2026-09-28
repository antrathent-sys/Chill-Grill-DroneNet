--- trip: an admin's multi-leg trip for one drone, run by the base.
--
-- From the admin pocket (Alex, 2026-09-29): a trip of several legs, each a
-- known place and a kind -
--   stop  land (a pad) or dock (a dock) there, then wait for Go from the
--         pocket - STOP_WAIT at most, after which the trip ends there and the
--         drone is free where it stands
--   via   fly over it on the way to the next stop. That needs fly's route
--         mode; until it exists a trip with a via is refused (T.VIAS)
-- The last leg is always a stop. The base runs a trip one proven flight at a
-- time: the vias before a stop plus the stop make one fly command, sent as an
-- ops.fly order, and the drone's own telemetry says when it has left and
-- when it is down at the stop.
--
-- Cancel: at a stop, or before the first flight, the trip ends at once. In
-- the air, a drone whose telemetry says it takes orders there (ord, fly.lua
-- ORDERS_IN_FLIGHT) is told to stop: it brakes, hovers and waits - the trip
-- is "holding" - for a new trip from the pocket, which it flies from the
-- hover; Cancel again, or nothing within its wait, sends it home. A drone
-- that cannot stop in the air ends the trip at this leg's stop instead.
--
-- A new trip for a drone in the air that takes orders replaces the one it is
-- on: it stops, and goes from the hover. Its first flight is sent to the
-- flight itself (unit.goto) rather than to the beacon (ops.fly).
--
-- Over the radio a trip's legs are one string: "stop:rules;via:market;stop:home".
--
-- Pure: places and units come in as tables. tools/test_trip.lua.

local T = {}

T.MAX_LEGS = 8
T.STOP_WAIT = 600     -- s at a stop waiting for Go before the trip ends there
T.LEG_MAX = 900       -- s from take-off to down at the stop before it is failed
T.LEAVE_MAX = 60      -- s from the order to seeing it in the air
T.AWAY_MAX = 30       -- s down somewhere that is not the stop before it is failed
T.FRESH = 15          -- s: telemetry older than this is no news
T.NEAR_PAD = 8        -- blocks from a pad's centre that count as down there
T.NEAR_DOCK = 6       -- ... from a dock's (a missed capture sets down beside it)
T.VIAS = false        -- true once fly has a route mode
T.STOP_MAX = 90       -- s from a stop order to seeing it hover before it is failed

local floor, sqrt = math.floor, math.sqrt
local function str(v) return type(v) == "string" and v ~= "" end
local function num(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

--- A place by name, any case: pads.lua records { name, x, y, z, kind }.
function T.place(places, name)
  if not str(name) then return nil end
  local want = name:lower()
  for _, p in ipairs(places or {}) do
    if type(p) == "table" and str(p.name) and p.name:lower() == want then return p end
  end
  return nil
end

--- "stop:rules;via:market;stop:home" -> { { kind, place }, ... }, or nil and why.
function T.parse(text, places)
  if not str(text) or #text > 300 then return nil, "no legs" end
  local legs = {}
  for item in text:gmatch("[^;]+") do
    local kind, name = item:match("^%s*(%a+)%s*:%s*([%w_%-]+)%s*$")
    if not kind then return nil, "a leg is kind:place, not '" .. item .. "'" end
    kind = kind:lower()
    if kind ~= "stop" and kind ~= "via" then return nil, "a leg is a stop or a via, not " .. kind end
    local p = T.place(places, name)
    if not p then return nil, "no place called " .. name end
    if not (num(p.x) and num(p.z)) then return nil, name .. " has no position" end
    legs[#legs + 1] = { kind = kind, place = p }
  end
  if #legs == 0 then return nil, "no legs" end
  if #legs > T.MAX_LEGS then return nil, string.format("%d legs - %d at most", #legs, T.MAX_LEGS) end
  if legs[#legs].kind ~= "stop" then return nil, "the last leg must be a stop" end
  return legs
end

--- The legs back as the wire string.
function T.encode(legs)
  local out = {}
  for _, l in ipairs(legs or {}) do out[#out + 1] = l.kind .. ":" .. l.place.name end
  return table.concat(out, ";")
end

--- The flights a trip is made of: each run of vias with the stop after it.
function T.segments(legs)
  local segs, vias = {}, {}
  for _, l in ipairs(legs or {}) do
    if l.kind == "via" then
      vias[#vias + 1] = l.place
    else
      segs[#segs + 1] = { vias = vias, stop = l.place }
      vias = {}
    end
  end
  return segs
end

--- The fly command for one segment, or nil and why. A dock is ferried to and
-- latched on; anything else - a landing pad - is landed on, from the base's
-- own record of where it is.
function T.command(seg)
  if not (seg and seg.stop) then return nil, "no stop" end
  if #seg.vias > 0 and not T.VIAS then
    return nil, "waypoints need fly's route mode - not built yet"
  end
  local p = seg.stop
  local stop
  if p.kind == "pad" then
    if num(p.y) then
      stop = string.format("land %d %d %d", floor(p.x), floor(p.y), floor(p.z))
    else
      stop = string.format("land %d %d", floor(p.x), floor(p.z))
    end
  else
    stop = "ferry " .. p.name
  end
  if #seg.vias == 0 then return stop end
  local parts = { "route" }
  for _, v in ipairs(seg.vias) do parts[#parts + 1] = "via " .. v.name end
  parts[#parts + 1] = stop
  return table.concat(parts, " ")
end

--- A new trip for drone, not started yet.
-- air: the drone is in the air, so the first flight goes to the flight itself.
function T.new(id, drone, legs, who, now, air)
  return { id = id, drone = drone, who = who, legs = legs, segs = T.segments(legs), seg = 1,
           state = "send", at = now or 0, air = air or nil }
end

local function fresh(u, now) return type(u) == "table" and num(u.seen) and now - u.seen <= T.FRESH end
local function down(u) return u.docked or u.landed end
local function waiting(u) return type(u) == "table" and u.legKind == "wait" end

--- In the air, heard from lately, and able to take a stop there.
function T.canStop(u, now)
  return fresh(u, now) and u.ord and not down(u) and u.phase ~= "sos" and true or false
end

--- Is the unit down at place p?
function T.at(u, p)
  if not (type(u) == "table" and num(u.x) and num(u.z) and p) then return false end
  local d = sqrt((u.x - (p.x + 0.5)) ^ 2 + (u.z - (p.z + 0.5)) ^ 2)
  return (down(u) and true or false) and d <= (p.kind == "pad" and T.NEAR_PAD or T.NEAR_DOCK)
end

local function finish(trip, outcome, why)
  trip.state, trip.why = outcome, why
  return "end", why
end

--- The order for this segment has gone: now wait to see it leave.
function T.sent(trip, now) trip.state, trip.at, trip.away = "sent", now, nil end

--- One look at a trip. Returns what to do and a line to tell the admin:
--   "send"   order the drone to fly T.command(trip.segs[trip.seg]), then T.sent
--   "end"    the trip is over - trip.state says how: done, cancelled, ended
--            (no Go in time) or failed - and the drone is free again
--   nil      nothing to do; the text, if any, is news (arrived at a stop)
function T.step(trip, u, now)
  local s = trip.state
  if s == "send" then return "send" end
  if s ~= "sent" and s ~= "flying" and s ~= "stopped" and s ~= "stopping" and s ~= "holding" then return nil end
  if type(u) == "table" and u.sos then return finish(trip, "failed", "the drone is in distress") end
  if s == "stopping" then
    if fresh(u, now) and waiting(u) then
      trip.state, trip.at = "holding", now
      return nil, string.format("hovering at %d %d - a new trip, or Cancel for home", floor(u.x or 0), floor(u.z or 0))
    end
    if fresh(u, now) and down(u) then return finish(trip, "cancelled", "cancelled - it was already down") end
    if now - trip.at > T.STOP_MAX then return finish(trip, "failed", "it did not stop") end
    return nil
  end
  if s == "holding" then
    -- its own wait ran out and it is on its way home
    if fresh(u, now) and not waiting(u) then return finish(trip, "ended", "no new trip in time - it went home") end
    return nil
  end
  if s == "sent" then
    if fresh(u, now) and not down(u) then trip.state, trip.at = "flying", now return nil end
    if now - trip.at > T.LEAVE_MAX then return finish(trip, "failed", "it never took off") end
    return nil
  end
  local stop = trip.segs[trip.seg].stop
  if s == "flying" then
    if fresh(u, now) and down(u) then
      if T.at(u, stop) then
        if trip.seg >= #trip.segs then return finish(trip, "done", "down at " .. stop.name .. " - trip done") end
        if trip.cancel then return finish(trip, "cancelled", "cancelled - down at " .. stop.name) end
        trip.state, trip.at = "stopped", now
        return nil, "down at " .. stop.name .. " - Go for the next leg"
      end
      trip.away = trip.away or now
      if now - trip.away > T.AWAY_MAX then
        return finish(trip, "failed", "it came down away from " .. stop.name)
      end
    else
      trip.away = nil
    end
    if now - trip.at > T.LEG_MAX then return finish(trip, "failed", "the leg to " .. stop.name .. " took too long") end
    return nil
  end
  -- stopped, waiting for Go
  if trip.cancel then return finish(trip, "cancelled", "cancelled at " .. stop.name) end
  if trip.go then
    trip.go = nil
    trip.seg = trip.seg + 1
    trip.state = "send"
    return "send"
  end
  if now - trip.at > T.STOP_WAIT then
    return finish(trip, "ended", "no Go at " .. stop.name .. " in " .. floor(T.STOP_WAIT / 60) .. " min - ended there")
  end
  return nil
end

--- Go from the pocket: fly the next leg. Only at a stop.
function T.go(trip)
  if trip.state ~= "stopped" then return false, "not waiting at a stop" end
  trip.go = true
  return true, "going on to " .. trip.segs[trip.seg + 1].stop.name
end

--- Cancel from the pocket. Returns ok, what to tell the admin, whether the
-- trip is over now, and what to order the drone, if anything:
--   "stop"  stop in the air and hover (u can: T.canStop) - the trip holds
--   "home"  it was holding: home now, and the trip is over
-- Before the first flight it is over at once; at a stop the next step ends it;
-- in the air, a drone that cannot stop ends the trip at this leg's stop.
function T.cancel(trip, u, now)
  if trip.state == "send" then
    trip.state, trip.why = "cancelled", "cancelled before it flew"
    return true, trip.why, true
  end
  if trip.state == "holding" then
    trip.state, trip.why = "cancelled", "cancelled - home from the hover"
    return true, trip.why, true, "home"
  end
  if trip.state == "stopping" then return true, "already stopping", false end
  if trip.state == "flying" and T.canStop(u, now or 0) then
    trip.state, trip.at = "stopping", now or 0
    return true, "stopping - it will hover and wait for a new trip", false, "stop"
  end
  trip.cancel = true
  if trip.state == "stopped" then return true, "cancelled", false end
  return true, "will end at " .. trip.segs[trip.seg].stop.name .. " (this drone cannot stop in the air)", false
end

--- One line for the base's feed: "id|drone|state|seg/n|stop|who".
function T.line(trip)
  local seg = trip.segs[trip.seg]
  return table.concat({ trip.id, trip.drone, trip.state, trip.seg .. "/" .. #trip.segs,
                        seg and seg.stop.name or "", trip.who or "" }, "|")
end

return T
