--- nav: CINDER NAV, the registered unit any vehicle on the server can carry -
-- aircraft, land vehicles, boats and submarines (AVIONICS.md, Alex
-- 2026-10-01). An advanced computer, one screen and an ender modem; CINDER
-- supplies the kit, registers it, and its tower answers every ping.
--
-- The pure part, shared by both ends:
--   what a unit reads and shows       N.reading
--   the ping it sends, the pong back  N.ping / N.checkPing, N.pong / N.parsePong
--   traffic and advisories            N.track, N.traffic, N.advisory
--   the registry and its log          N.loadRegistry / N.serialise, N.event
--   putting the software on a unit    N.inspect / N.install
-- nav.lua runs the unit, tower.lua the tower, lib/navui.lua draws the unit's
-- screen. No peripherals here, and fs only as passed in: tools/test_nav.lua.

local N = {}

N.VERSION = 1
N.CHANNEL = 7215          -- pings and pongs: a channel of their own, never the fleet's 7212/7213
N.PING_MOVING = 2         -- seconds between pings while the vehicle moves
N.PING_PARKED = 10        -- ... and while it stands
N.LINK_LOST = 3           -- pings in a row with no pong before the screen says so
N.MAX_AGE_MS = 120000     -- a ping or pong older than this is refused (a replay)
N.SEA_LEVEL = 63
N.MOVING = 0.5            -- b/s: anything faster is moving
N.RANGE = 1000            -- blocks: the traffic a pong lists
N.TRAFFIC_MAX = 6
N.WARN_SECS = 30          -- an advisory when two would pass within WARN_DIST
N.WARN_DIST = 40          --   inside WARN_SECS, and within WARN_DY of each
N.WARN_DY = 30            --   other's height
N.STALE = 60              -- seconds unheard: the tower shows it last seen, and it leaves traffic
N.PIC_PERIOD = 2          -- seconds between the master's pictures to each display-only centre
N.PIC_MAX = 100           -- contacts in one picture (a sealed body stays under seclink's 8 KB)
N.PIC_AWAY = 3600         -- seconds: how long an away contact stays on a centre's board
N.CENTRES_MAX = 8         -- centres a pong tells a unit about

-- What a unit can be fitted to. The screen shows what suits each.
N.TYPES = {
  air  = { word = "AIRCRAFT",     short = "AIR" },
  land = { word = "LAND VEHICLE", short = "LAND" },
  sea  = { word = "VESSEL",       short = "SEA" },
  sub  = { word = "SUBMARINE",    short = "SUB" },
}
N.TYPE_ORDER = { "air", "land", "sea", "sub" }
N.STATES = { move = true, park = true, sos = true }

-- The registration number. A PLACEHOLDER: the format is still to be agreed
-- (Alex, 2026-10-01: "would need to discuss with people"). Records keep only
-- the sequence number, so changing this one line renames every unit at once.
N.REG_FORMAT = "CR-%04d"
function N.regNumber(n) return string.format(N.REG_FORMAT, tonumber(n) or 0) end
-- The unit's own id: its label, the name its key is filed under, what every
-- sealed packet carries. Fixed for life, whatever the registration looks like.
function N.unitId(n) return string.format("nav-%04d", tonumber(n) or 0) end

local floor, sqrt, abs = math.floor, math.sqrt, math.abs
local function num(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end
local function round(v, d) local m = 10 ^ (d or 0) return floor(v * m + 0.5) / m end

-- ---------------------------------------------------------------- reading --

--- Compass heading of a world-frame horizontal vector: 0 north (-z), 90 east.
function N.headingOf(vx, vz) return (math.deg(math.atan2(vx, -vz)) + 360) % 360 end

--- What the screen shows, from a position and a velocity (world frame, b/s):
-- ground speed, climb, heading over the ground (kept from before while it is
-- too slow to have one), height, depth below sea level, and whether it moves.
function N.reading(pos, vel, prev)
  local vx = vel and num(vel.x) and vel.x or 0
  local vy = vel and num(vel.y) and vel.y or 0
  local vz = vel and num(vel.z) and vel.z or 0
  local r = { x = pos.x, y = pos.y, z = pos.z }
  r.spd = sqrt(vx * vx + vz * vz)
  r.vs = vy
  r.vx, r.vz = vx, vz
  if r.spd >= N.MOVING then r.hdg = N.headingOf(vx, vz) else r.hdg = prev and prev.hdg or nil end
  r.depth = N.SEA_LEVEL - pos.y
  r.moving = r.spd >= N.MOVING or abs(vy) >= N.MOVING
  return r
end

-- --------------------------------------------------------- ping and pong --

--- The unit's report. st: "move", "park" or "sos". craft: Sable's id, name
-- and mass for the vehicle it is on, when it is on one.
function N.ping(r, st, craft)
  local p = { type = "nav.ping", v = N.VERSION, st = st or (r.moving and "move" or "park"),
              x = round(r.x, 1), y = round(r.y, 1), z = round(r.z, 1),
              spd = round(r.spd or 0, 1), vs = round(r.vs or 0, 1) }
  if r.hdg then p.hdg = floor(r.hdg + 0.5) % 360 end
  if craft then
    if type(craft.id) == "string" then p.sid = craft.id:sub(1, 40) end
    if type(craft.name) == "string" then p.sname = craft.name:sub(1, 32) end
    if num(craft.mass) then p.mass = floor(craft.mass + 0.5) end
  end
  return p
end

--- A ping as the tower receives it: every field checked, nil and why if not.
function N.checkPing(m)
  if type(m) ~= "table" or m.type ~= "nav.ping" then return nil, "not a ping" end
  for _, k in ipairs({ "x", "y", "z", "spd", "vs" }) do
    if not num(m[k]) then return nil, k .. " is not a number" end
  end
  if abs(m.x) > 3e7 or abs(m.z) > 3e7 or m.y < -2048 or m.y > 100000 then return nil, "position off the world" end
  if m.spd < 0 or m.spd > 2000 or abs(m.vs) > 2000 then return nil, "speed past belief" end
  if m.hdg ~= nil and not (num(m.hdg) and m.hdg >= 0 and m.hdg < 360) then return nil, "bad heading" end
  if not N.STATES[m.st] then return nil, "bad state" end
  if m.sid ~= nil and (type(m.sid) ~= "string" or #m.sid > 40) then return nil, "bad craft id" end
  if m.sname ~= nil and (type(m.sname) ~= "string" or #m.sname > 32) then return nil, "bad craft name" end
  return m
end

-- Callsigns are letters, digits, spaces and dashes, so a list of contacts
-- packs into one string: seclink carries flat tables only.
local function clean(s) return (tostring(s or ""):gsub("[^%w%- ]", ""):upper()) end

--- What a contact is shown as: its registration, or CINDER for one of
-- CINDER's own units (number 0, from the base's feed - N.cinderContact).
function N.regOf(c) return (c.cinder or c.n == 0) and "CINDER" or N.regNumber(c.n) end

-- CINDER's own units, from the base's read-only feed (lib/watch.lua, the
-- tower as a public watcher). Must match lib/watch.lua W.CHANNEL.
N.CINDER_FEED = 7213

--- Fold one of the base's "cinder.unit" reports into the contacts, as number
-- 0 with its name as the callsign. Never logged: it is no registration.
function N.cinderContact(contacts, b, call, now)
  if type(b) ~= "table" or type(b.unit) ~= "string" or not (num(b.x) and num(b.z)) then return nil end
  local key = "cinder:" .. b.unit
  local c = contacts[key] or { unit = key, n = 0, kind = "air", cinder = true }
  contacts[key] = c
  c.call = (tostring(call or b.unit):upper():gsub("[^%w%- ]", "")):sub(1, 16)
  c.x, c.y, c.z = b.x, num(b.y) and b.y or 0, b.z
  c.spd, c.hdg, c.vs = num(b.spd) and b.spd or 0, num(b.hdg) and b.hdg % 360 or nil, b.vv
  c.st = b.phase == "sos" and "sos" or (c.spd > 1 and "move" or "park")
  if num(b.vx) and num(b.vz) then
    c.vx, c.vz = b.vx, b.vz
  else
    local h = math.rad(c.hdg or 0)
    c.vx, c.vz = c.hdg and c.spd * math.sin(h) or 0, c.hdg and -c.spd * math.cos(h) or 0
  end
  c.t = now
  return c
end

--- Take CINDER's units off the picture: all of them (stealth), or with
-- `now`, only those not heard for N.STALE (the base gone quiet).
function N.dropCinder(contacts, now)
  for k, c in pairs(contacts) do
    if c.cinder and (not now or now - (c.t or -1e9) > N.STALE) then contacts[k] = nil end
  end
end

--- The tower's answer to one unit: what is near it, the most urgent
-- advisory, and whether its distress has been heard.
function N.pong(traffic, adv, opts)
  local parts = {}
  for i = 1, math.min(#(traffic or {}), N.TRAFFIC_MAX) do
    local t = traffic[i]
    parts[#parts + 1] = table.concat({ clean(t.call), clean(t.reg), t.kind or "air", floor(t.brg + 0.5) % 360,
      floor(t.dist + 0.5), floor(t.dy + 0.5), t.warn and 1 or 0 }, ",")
  end
  local p = { type = "nav.pong", v = N.VERSION, tr = table.concat(parts, ";"), n = #parts }
  if adv then p.adv = tostring(adv):sub(1, 60) end
  if opts and opts.sos then p.sos = 1 end
  if opts and opts.msg then p.msg = tostring(opts.msg):sub(1, 60) end
  if opts and opts.centres and #opts.centres > 0 then p.ctr = N.centresString(opts.centres) end
  return p
end

--- A pong back into a table the screen can use; nil if it is not one.
function N.parsePong(m)
  if type(m) ~= "table" or m.type ~= "nav.pong" then return nil end
  local out = { traffic = {}, adv = type(m.adv) == "string" and m.adv or nil, sos = m.sos == 1,
                msg = type(m.msg) == "string" and m.msg or nil, centres = N.parseCentres(m.ctr) }
  for item in tostring(m.tr or ""):gmatch("[^;]+") do
    local call, reg, kind, brg, dist, dy, warn = item:match("^([^,]*),([^,]*),(%a+),(%-?%d+),(%d+),(%-?%d+),([01])$")
    if call then
      out.traffic[#out.traffic + 1] = { call = call, reg = reg, kind = kind, brg = tonumber(brg),
        dist = tonumber(dist), dy = tonumber(dy), warn = warn == "1" }
    end
  end
  return out
end

-- ---------------------------------------------------------------- centres --
-- Traffic centres: the master tower that hears every ping, and any number of
-- display-only centres it feeds (Alex, 2026-10-01). Every unit is told where
-- they all are, so its screen can show the nearest.

--- A centre's name: 2 to 12 letters, digits or dashes, in capitals.
function N.validCentre(s)
  if type(s) ~= "string" then return nil end
  s = s:gsub("^%s+", ""):gsub("%s+$", ""):upper()
  if #s < 2 or #s > 12 or not s:match("^[%w%-]+$") then return nil end
  return s
end
--- The id a centre's key is filed under and its packets carry.
function N.centreId(name) return "ctr-" .. tostring(name):lower() end

-- Registration kiosks (navdesk.lua): computers of their own wherever players
-- are, which ask the master tower to register a unit and hand the kit over.
-- A kiosk is named like a centre and filed under kiosk-<name>.
N.KIOSK_MAX = 5           -- units a player can register at a kiosk; more at the tower
function N.kioskId(name) return "kiosk-" .. tostring(name):lower() end
function N.kioskFile(k) return "name=" .. k.name .. "\nmaster=" .. tostring(k.master or "") .. "\n" end
function N.parseKioskFile(text)
  if type(text) ~= "string" then return nil end
  local t = {}
  for k, v in text:gmatch("(%w+)=([^\n]*)") do t[k] = v:gsub("%s+$", "") end
  local name = N.validCentre(t.name)
  if not name then return nil end
  return { name = name, master = t.master ~= "" and t.master or nil }
end

--- Centres as one string for a pong: "CHI,2497,70,-3297;NORTH,1200,80,-400".
function N.centresString(list)
  local parts = {}
  for i = 1, math.min(#(list or {}), N.CENTRES_MAX) do
    local c = list[i]
    if N.validCentre(c.name) and num(c.x) and num(c.z) then
      parts[#parts + 1] = string.format("%s,%d,%d,%d", N.validCentre(c.name), floor(c.x + 0.5),
        floor((c.y or 0) + 0.5), floor(c.z + 0.5))
    end
  end
  return table.concat(parts, ";")
end
function N.parseCentres(s)
  local out = {}
  for item in tostring(s or ""):gmatch("[^;]+") do
    local name, x, y, z = item:match("^([%w%-]+),(%-?%d+),(%-?%d+),(%-?%d+)$")
    if name and #out < N.CENTRES_MAX then
      out[#out + 1] = { name = name, x = tonumber(x), y = tonumber(y), z = tonumber(z) }
    end
  end
  return out
end

--- Every centre with its bearing and distance from a reading, nearest first.
function N.centresFrom(r, centres)
  local out = {}
  if not (r and r.x) then return out end
  for _, c in ipairs(centres or {}) do
    local dx, dz = c.x - r.x, c.z - r.z
    out[#out + 1] = { name = c.name, x = c.x, y = c.y, z = c.z, dist = sqrt(dx * dx + dz * dz),
                      brg = N.headingOf(dx, dz) }
  end
  table.sort(out, function(a, b) return a.dist < b.dist end)
  return out
end

N.CARDINALS = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }
N.CARDINAL_WORD = { N = "NORTH", NE = "NORTHEAST", E = "EAST", SE = "SOUTHEAST",
                    S = "SOUTH", SW = "SOUTHWEST", W = "WEST", NW = "NORTHWEST" }
--- A compass heading as one of eight points.
function N.cardinal(brg)
  if not brg then return "-" end
  return N.CARDINALS[floor(((brg % 360) + 22.5) / 45) % 8 + 1]
end

--- A centre's own file: who it is, where, and which master feeds it.
function N.centreFile(c)
  return table.concat({ "name=" .. c.name, "x=" .. floor(c.x + 0.5), "y=" .. floor((c.y or 0) + 0.5),
    "z=" .. floor(c.z + 0.5), "master=" .. tostring(c.master or "") }, "\n") .. "\n"
end
function N.parseCentreFile(text)
  if type(text) ~= "string" then return nil end
  local t = {}
  for k, v in text:gmatch("(%w+)=([^\n]*)") do t[k] = v:gsub("%s+$", "") end
  local name = N.validCentre(t.name)
  local x, y, z = tonumber(t.x), tonumber(t.y), tonumber(t.z)
  if not (name and x and z) then return nil end
  return { name = name, x = x, y = y or 0, z = z, master = t.master ~= "" and t.master or nil }
end

--- The master's picture for one display-only centre: every contact live or
-- recently away, and every centre. One sealed packet every PIC_PERIOD.
function N.picture(contacts, centres, now)
  local list = {}
  for _, c in pairs(contacts or {}) do
    if c.x and now - (c.t or -1e9) <= N.PIC_AWAY then list[#list + 1] = c end
  end
  table.sort(list, function(a, b) return (now - a.t) < (now - b.t) end)
  local parts = {}
  for i = 1, math.min(#list, N.PIC_MAX) do
    local c = list[i]
    parts[#parts + 1] = table.concat({ c.n, clean(c.call), c.kind or "air", floor(c.x + 0.5), floor(c.y + 0.5),
      floor(c.z + 0.5), floor((c.spd or 0) + 0.5), c.hdg and floor(c.hdg + 0.5) % 360 or "",
      c.st or "park", floor(now - c.t) }, ",")
  end
  return { type = "nav.pic", v = N.VERSION, ct = table.concat(parts, ";"), n = #parts,
           cn = N.centresString(centres) }
end
function N.parsePicture(m, now)
  if type(m) ~= "table" or m.type ~= "nav.pic" then return nil end
  local out = { contacts = {}, centres = N.parseCentres(m.cn) }
  for item in tostring(m.ct or ""):gmatch("[^;]+") do
    local n, call, kind, x, y, z, spd, hdg, st, age =
      item:match("^(%d+),([^,]*),(%a+),(%-?%d+),(%-?%d+),(%-?%d+),(%d+),(%d*),(%a+),(%d+)$")
    if n and N.TYPES[kind] and N.STATES[st] then
      out.contacts[#out.contacts + 1] = { n = tonumber(n), call = call, kind = kind, x = tonumber(x),
        y = tonumber(y), z = tonumber(z), spd = tonumber(spd), hdg = tonumber(hdg), st = st,
        t = (now or 0) - tonumber(age) }
    end
  end
  return out
end

-- ---------------------------------------------------------------- traffic --

--- Fold one ping into the tower's picture. contacts: unit -> contact. rec:
-- the unit's registry record. Returns the events worth writing down:
-- "first" (heard for the first time since the tower started), "depart",
-- "arrive", "sos", "sos-clear". The vehicle's Sable id is kept as the last
-- one heard and nothing more: players pack craft into containers and put them
-- out again, which makes a new one each time (Alex, 2026-10-01), so a unit
-- going quiet or turning up on a "different" vehicle is ordinary.
function N.track(contacts, rec, m, now)
  local c = contacts[rec.unit]
  local events = {}
  if not c then
    c = { unit = rec.unit, n = rec.n, call = rec.call, kind = rec.kind }
    contacts[rec.unit] = c
    events[#events + 1] = "first"
  elseif now - (c.t or now) <= N.STALE then
    if c.st == "park" and m.st == "move" then events[#events + 1] = "depart" end
    if c.st == "move" and m.st == "park" then events[#events + 1] = "arrive" end
  end
  if m.st == "sos" and c.st ~= "sos" then events[#events + 1] = "sos" end
  if c.st == "sos" and m.st ~= "sos" then events[#events + 1] = "sos-clear" end
  c.call, c.kind, c.n = rec.call, rec.kind, rec.n
  c.x, c.y, c.z, c.spd, c.vs, c.hdg, c.st = m.x, m.y, m.z, m.spd, m.vs, m.hdg, m.st
  local h = math.rad(m.hdg or 0)
  c.vx, c.vz = m.hdg and m.spd * math.sin(h) or 0, m.hdg and -m.spd * math.cos(h) or 0
  c.sid, c.sname, c.mass = m.sid or c.sid, m.sname or c.sname, m.mass or c.mass
  c.t = now
  return c, events
end

--- Everything near one contact, nearest first: bearing, distance, height
-- difference, and whether they are on course to pass too close.
function N.traffic(contacts, me, now)
  local out = {}
  for unit, o in pairs(contacts) do
    if unit ~= me.unit and o.x and now - (o.t or -1e9) <= N.STALE then
      local dx, dz, dy = o.x - me.x, o.z - me.z, o.y - me.y
      local dist = sqrt(dx * dx + dz * dz)
      if dist <= N.RANGE then
        -- closest approach, flat, from both velocities
        local wx, wz = (o.vx or 0) - (me.vx or 0), (o.vz or 0) - (me.vz or 0)
        local w2 = wx * wx + wz * wz
        local tca = w2 > 1e-6 and math.max(0, -(dx * wx + dz * wz) / w2) or 0
        local cx, cz = dx + wx * tca, dz + wz * tca
        local cpa = sqrt(cx * cx + cz * cz)
        local warn = (dist <= N.WARN_DIST or (tca > 0 and tca <= N.WARN_SECS and cpa <= N.WARN_DIST))
                     and abs(dy) <= N.WARN_DY
        out[#out + 1] = { unit = unit, call = o.call, reg = N.regOf(o), kind = o.kind,
          brg = N.headingOf(dx, dz), dist = dist, dy = dy, tca = tca, cpa = cpa, warn = warn,
          sos = o.st == "sos" }
      end
    end
  end
  table.sort(out, function(a, b) return a.dist < b.dist end)
  return out
end

--- Bearing relative to the nose as a clock position, 12 dead ahead.
function N.clock(brg, hdg)
  local rel = ((brg - (hdg or 0)) % 360 + 360) % 360
  local h = floor(rel / 30 + 0.5) % 12
  return h == 0 and 12 or h
end

local function distWord(d)
  if d >= 1000 then return string.format("%.1fK", d / 1000) end
  return tostring(floor(d / 10 + 0.5) * 10)
end
N.distWord = distWord

--- The one line a pilot most needs, or nil: the nearest contact on course to
-- pass too close, then anyone in distress nearby.
function N.advisory(me, traffic)
  for _, t in ipairs(traffic) do
    if t.warn then
      local level = abs(t.dy) < 8 and "SAME LEVEL" or (t.dy > 0 and "ABOVE" or "BELOW")
      return string.format("TRAFFIC %d O'CLOCK %s %s", N.clock(t.brg, me.hdg), distWord(t.dist), level)
    end
  end
  for _, t in ipairs(traffic) do
    if t.sos then return string.format("DISTRESS %s %s %d O'CLOCK", t.call, distWord(t.dist), N.clock(t.brg, me.hdg)) end
  end
  return nil
end

-- --------------------------------------------------------------- registry --

--- A Minecraft username: whose vehicle it is, as given at registration.
function N.validOwner(s) return type(s) == "string" and #s >= 3 and #s <= 16 and s:match("^[%w_]+$") ~= nil end

-- The owner, read off the seat beside the tower (Alex, 2026-10-02): a Create
-- Seat, a Display Link on it with the "Entity Name" source, aimed at a CC:C
-- Bridge target block on the tower's computer - the only thing in this pack
-- that names a real player to a computer. A line of the target, colour codes
-- stripped: the name, or nil and why. A mob sitting there reads as a plain
-- word too ("Pig"), which is why the registrar still confirms it.
N.SEAT_WAIT = 60            -- seconds `tower register` waits for someone to sit
function N.seatName(line)
  if type(line) ~= "string" then return nil, "no reading" end
  local name = line:gsub("\194\167%x", ""):match("^%s*(.-)%s*$")
  if name == "" then return nil, "seat empty" end
  if not N.validOwner(name) then return nil, "not a player name" end
  return name
end
--- A callsign: what traffic calls the vehicle. 2 to 16 of letters, digits,
-- spaces and dashes, kept in capitals.
function N.validCall(s)
  if type(s) ~= "string" then return nil end
  s = s:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " "):upper()
  if #s < 2 or #s > 16 or not s:match("^[%w%- ]+$") then return nil end
  return s
end

-- One callsign per vehicle, and CINDER's own names are CINDER's: nobody can
-- pose as LAMBDA-001 or the tower (Alex, 2026-10-02: "are there checks to
-- see if callsign is already used?"). The callsign, cleaned, or nil and why.
N.RESERVED_CALLS = { "^CINDER", "^LAMBDA", "^ZETA", "^TOWER", "^ATC" }
function N.callFree(recs, call, exceptUnit)
  local c = N.validCall(call)
  if not c then return nil, "2 TO 16 LETTERS, DIGITS, SPACES OR DASHES" end
  for _, p in ipairs(N.RESERVED_CALLS) do
    if c:match(p) then return nil, "RESERVED FOR CINDER" end
  end
  for _, r in ipairs(recs or {}) do
    if not r.revoked and r.unit ~= exceptUnit and N.validCall(r.call) == c then
      return nil, "TAKEN BY " .. N.regNumber(r.n)
    end
  end
  return c
end

-- What the kiosk hands a player with their unit: an advanced computer (one
-- that has been placed and turned on once - only then can a disk drive read
-- it), two advanced monitors and an ender modem.
N.KIT = {
  computer = "computercraft:computer_advanced",
  { name = "computercraft:monitor_advanced", count = 2 },
  { name = "computercraft:wireless_modem_advanced", count = 1 },
}

--- Each part of a kit against what one kit needs, for a person to read:
-- "computers 0/1, monitors 4/2, ender modems 1/1" - the short ones first.
N.KIT_WORDS = { ["computercraft:computer_advanced"] = "advanced computers",
                ["computercraft:monitor_advanced"] = "advanced monitors",
                ["computercraft:wireless_modem_advanced"] = "ender modems" }
function N.kitParts(list)
  local have = {}
  for _, it in pairs(list or {}) do
    if type(it) == "table" and type(it.name) == "string" then have[it.name] = (have[it.name] or 0) + (it.count or 1) end
  end
  local parts = { { N.KIT.computer, 1 } }
  for _, need in ipairs(N.KIT) do parts[#parts + 1] = { need.name, need.count } end
  local short, fine = {}, {}
  for _, p in ipairs(parts) do
    local line = string.format("%s %d/%d", N.KIT_WORDS[p[1]] or p[1], have[p[1]] or 0, p[2])
    if (have[p[1]] or 0) < p[2] then short[#short + 1] = line else fine[#fine + 1] = line end
  end
  for _, l in ipairs(fine) do short[#short + 1] = l end
  return table.concat(short, ", ")
end

--- How many kits an inventory's list() holds (computers counted as they
-- are; whether each can be read is found out when one is tried).
function N.kitsIn(list)
  local have = {}
  for _, it in pairs(list or {}) do
    if type(it) == "table" and type(it.name) == "string" then have[it.name] = (have[it.name] or 0) + (it.count or 1) end
  end
  local n = have[N.KIT.computer] or 0
  for _, need in ipairs(N.KIT) do n = math.min(n, floor((have[need.name] or 0) / need.count)) end
  return n
end

-- Applications to host a traffic centre, from the kiosk: one CSV line each,
-- "n,when,who,name,x,z,status" with status pending, approved or refused.
N.APPS_HEADER = "n,when,who,name,x,z,status"
function N.parseApps(text)
  local out = {}
  for line in tostring(text or ""):gmatch("[^\r\n]+") do
    local n, when, who, name, x, z, st = line:match("^(%d+),(%d*),([%w_]+),([%w%-]+),(%-?%d+),(%-?%d+),(%a+)$")
    if n then
      out[#out + 1] = { n = tonumber(n), when = tonumber(when), who = who, name = name, x = tonumber(x),
                        z = tonumber(z), status = st }
    end
  end
  return out
end
function N.appsText(list)
  local lines = { N.APPS_HEADER }
  for _, a in ipairs(list) do
    lines[#lines + 1] = string.format("%d,%d,%s,%s,%d,%d,%s", a.n, a.when or 0, a.who, a.name, a.x, a.z, a.status)
  end
  return table.concat(lines, "\n") .. "\n"
end

-- idby: how the owner was known - "seat" (sat in the tower's seat) or "typed"
local FIELDS = { "n", "unit", "owner", "idby", "call", "kind", "issued", "by", "sid", "sname", "mass", "first", "last",
                 "x", "y", "z", "revoked" }

--- A registry record, cleaned, or nil and why.
function N.checkRecord(r)
  if type(r) ~= "table" then return nil, "not a table" end
  if not (num(r.n) and r.n >= 1 and r.n == floor(r.n)) then return nil, "no sequence number" end
  if r.unit ~= N.unitId(r.n) then return nil, "unit id does not match its number" end
  if not N.validOwner(r.owner) then return nil, "owner is not a player name" end
  if not N.validCall(r.call) then return nil, "bad callsign" end
  if not N.TYPES[r.kind] then return nil, "bad vehicle type" end
  local out = {}
  for _, k in ipairs(FIELDS) do out[k] = r[k] end
  out.call = N.validCall(r.call)
  return out
end

--- The registry file: a Lua table of records, read with no environment, so
-- it can only ever be data.
function N.loadRegistry(text)
  if type(text) ~= "string" or text == "" then return {}, {} end
  local chunk
  if setfenv then
    chunk = (loadstring or load)(text, "registry")
    if chunk then setfenv(chunk, {}) end
  else
    chunk = load(text, "registry", "t", {})
  end
  if not chunk then return {}, { "the registry does not parse" } end
  local ok, t = pcall(chunk)
  if not ok or type(t) ~= "table" then return {}, { "the registry does not load" } end
  local out, bad = {}, {}
  for i, r in ipairs(t) do
    local c, why = N.checkRecord(r)
    if c then out[#out + 1] = c else bad[#bad + 1] = "record " .. i .. ": " .. tostring(why) end
  end
  table.sort(out, function(a, b) return a.n < b.n end)
  return out, bad
end

function N.serialise(records)
  local lines = { "-- CINDER NAV registry, written by tower.lua. One record per registered unit;",
                  "-- the registration shown everywhere is N.regNumber(n) (lib/nav.lua).", "return {" }
  for _, r in ipairs(records) do
    local parts = {}
    for _, k in ipairs(FIELDS) do
      local v = r[k]
      if v ~= nil then
        parts[#parts + 1] = type(v) == "string" and string.format("%s = %q", k, v)
          or string.format("%s = %s", k, tostring(v))
      end
    end
    lines[#lines + 1] = "  { " .. table.concat(parts, ", ") .. " },"
  end
  lines[#lines + 1] = "}"
  return table.concat(lines, "\n") .. "\n"
end

function N.nextNumber(records)
  local n = 0
  for _, r in ipairs(records) do if r.n > n then n = r.n end end
  return n + 1
end

--- A record by registration ("CR-0001"), unit id ("nav-0001") or number.
function N.find(records, key)
  local s = tostring(key or ""):upper()
  for _, r in ipairs(records) do
    if N.regNumber(r.n) == s or r.unit:upper() == s or tostring(r.n) == s then return r end
  end
  return nil
end

--- One line of the tower's log: when (UTC seconds), registration, unit,
-- callsign, event, position, anything else. Comma-separated, nothing quoted.
N.LOG_HEADER = "when,reg,unit,call,event,x,y,z,detail"
function N.event(when, rec, ev, c, detail)
  local function f(v) return v and tostring(floor(v + 0.5)) or "" end
  local call = (rec.call or ""):gsub(",", " ")
  local more = tostring(detail or ""):gsub("[,\n]", " ")
  return table.concat({ tostring(floor(when or 0)), N.regNumber(rec.n), rec.unit, call,
    ev, f(c and c.x), f(c and c.y), f(c and c.z), more }, ",")
end

-- ------------------------------------------------------------ the install --

-- Everything a unit runs: nav and the libraries it loads, the sealed link and
-- the crypto under it - the manifest's nav role, less startup.lua. The
-- tower's own startup.lua becomes the unit's, with role nav: every boot it
-- pulls just these from the repo, quietly behind the CINDER NAV boot screen,
-- and runs nav with no shell. No token and nothing that pushes (Alex,
-- 2026-10-01). The copies written here mean it runs before its first pull.
N.FILES = {
  "nav.lua", "lib/nav.lua", "lib/navui.lua", "lib/display.lua", "lib/tui.lua", "lib/seclink.lua",
  "ccryptolib/aead.lua", "ccryptolib/chacha20.lua", "ccryptolib/poly1305.lua",
  "ccryptolib/random.lua", "ccryptolib/blake3.lua", "ccryptolib/config.lua",
  "ccryptolib/internal/util.lua", "ccryptolib/internal/packing.lua",
  "ccryptolib/internal/hw.lua",
}
N.STARTUP = "startup.lua"
N.ROLE = "nav"
-- Found on CINDER's own machines and never on a unit: refused untouched. So
-- is any role but nav.
N.DEV_MARKERS = { ".ghtoken", ".fleetkeys", ".dronekey", ".custkeys", ".navkeys", ".adminkey", ".watchkey",
                  ".centrekey", ".centrekeys", ".navdeskkey", ".kioskkeys" }
N.KEEP = { [".navkey"] = true, [".navkey.ctr"] = true, [".nav"] = true, [".navpages"] = true, [".navtaught"] = true }

local function join(a, b) return (a == "" or a == nil) and b or (a .. "/" .. b) end
local function readAll(fsys, path)
  if not fsys.exists(path) then return nil end
  local h = fsys.open(path, "r")
  if not h then return nil end
  local s = h.readAll()
  h.close()
  return s
end
local function writeText(fsys, path, text)
  local h = fsys.open(path, "w")
  if not h then return false end
  h.write(text)
  h.close()
  return true
end

--- The unit's own record of itself (.nav): "key=value" lines.
function N.unitFile(rec)
  return table.concat({ "unit=" .. rec.unit, "n=" .. rec.n, "call=" .. rec.call, "kind=" .. rec.kind,
    "owner=" .. rec.owner }, "\n") .. "\n"
end
function N.parseUnitFile(text)
  if type(text) ~= "string" then return nil end
  local t = {}
  for k, v in text:gmatch("(%w+)=([^\n]*)") do t[k] = v:gsub("%s+$", "") end
  t.n = tonumber(t.n)
  if not (t.n and t.unit == N.unitId(t.n) and N.TYPES[t.kind] and N.validCall(t.call)) then return nil end
  t.call = N.validCall(t.call)
  return t
end

--- What is on a computer in the tower's drive:
--   { kind = "dev" }    one of CINDER's own machines - never touched
--   { kind = "pass" }   a customer's pass - not a nav unit
--   { kind = "unit", me = { unit, n, ... } }   a unit we registered
--   { kind = "blank" }  nothing on it
--   { kind = "other", files = { ... } }        somebody's files
function N.inspect(fsys, mount)
  local files = fsys.list(mount) or {}
  table.sort(files)
  for _, m in ipairs(N.DEV_MARKERS) do
    if fsys.exists(join(mount, m)) then return { kind = "dev", marker = m, files = files } end
  end
  local role = readAll(fsys, join(mount, ".role"))
  if role and role:gsub("%s+", "") ~= N.ROLE then
    return { kind = "dev", marker = ".role " .. role:gsub("%s+", ""), files = files }
  end
  if fsys.exists(join(mount, ".nav")) then
    return { kind = "unit", me = N.parseUnitFile(readAll(fsys, join(mount, ".nav"))), files = files }
  end
  if fsys.exists(join(mount, ".pass")) then return { kind = "pass", files = files } end
  local real = {}
  for _, f in ipairs(files) do if f ~= ".settings" then real[#real + 1] = f end end
  if #real == 0 then return { kind = "blank", files = files } end
  return { kind = "other", files = real }
end

--- Put the software on a unit, or refresh it.
--   opts.rec      its registry record
--   opts.keyHex   a NEW key, or nil to keep the one already on it
--   opts.src      where this computer keeps the files; opts.version the commit
-- Every source is checked before anything is deleted, so a missing file
-- never leaves a half-built unit. Returns true, files copied; or nil and why.
function N.install(fsys, mount, opts)
  local rec, src = opts.rec and N.checkRecord(opts.rec), opts.src or ""
  if not rec then return nil, "no good record to install" end
  if not opts.keyHex and not fsys.exists(join(mount, ".navkey")) then return nil, "no key on the unit and none given" end
  for _, f in ipairs(N.FILES) do
    if not fsys.exists(join(src, f)) then return nil, "this computer is missing " .. f end
  end
  if not fsys.exists(join(src, N.STARTUP)) then return nil, "this computer is missing " .. N.STARTUP end
  for _, f in ipairs(fsys.list(mount) or {}) do
    if not (not opts.keyHex and N.KEEP[f]) then fsys.delete(join(mount, f)) end
  end
  for _, f in ipairs(N.FILES) do
    local dst = join(mount, f)
    local dir = fsys.getDir(dst)
    if dir ~= "" and not fsys.exists(dir) then fsys.makeDir(dir) end
    if fsys.exists(dst) then fsys.delete(dst) end
    fsys.copy(join(src, f), dst)
  end
  fsys.copy(join(src, N.STARTUP), join(mount, "startup.lua"))
  writeText(fsys, join(mount, ".role"), N.ROLE .. "\n")
  writeText(fsys, join(mount, ".autorun"), "nav\n")
  writeText(fsys, join(mount, ".nav"), N.unitFile(rec))
  if opts.version then writeText(fsys, join(mount, ".commit"), opts.version:gsub("%s+$", "") .. "\n") end
  if opts.keyHex then
    writeText(fsys, join(mount, ".navkey"), opts.keyHex .. "\n")
    if fsys.exists(join(mount, ".navkey.ctr")) then fsys.delete(join(mount, ".navkey.ctr")) end
  end
  return true, #N.FILES + 1
end

return N
