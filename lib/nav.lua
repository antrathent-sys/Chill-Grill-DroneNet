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
  return p
end

--- A pong back into a table the screen can use; nil if it is not one.
function N.parsePong(m)
  if type(m) ~= "table" or m.type ~= "nav.pong" then return nil end
  local out = { traffic = {}, adv = type(m.adv) == "string" and m.adv or nil, sos = m.sos == 1,
                msg = type(m.msg) == "string" and m.msg or nil }
  for item in tostring(m.tr or ""):gmatch("[^;]+") do
    local call, reg, kind, brg, dist, dy, warn = item:match("^([^,]*),([^,]*),(%a+),(%-?%d+),(%d+),(%-?%d+),([01])$")
    if call then
      out.traffic[#out.traffic + 1] = { call = call, reg = reg, kind = kind, brg = tonumber(brg),
        dist = tonumber(dist), dy = tonumber(dy), warn = warn == "1" }
    end
  end
  return out
end

-- ---------------------------------------------------------------- traffic --

--- Fold one ping into the tower's picture. contacts: unit -> contact. rec:
-- the unit's registry record. Returns the events worth writing down:
-- "first" (heard for the first time since the tower started), "depart",
-- "arrive", "sos", "sos-clear", "craft" (now on a different vehicle).
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
  if m.sid and rec.sid and m.sid ~= rec.sid then events[#events + 1] = "craft" end
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
        out[#out + 1] = { unit = unit, call = o.call, reg = N.regNumber(o.n), kind = o.kind,
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
--- A callsign: what traffic calls the vehicle. 2 to 16 of letters, digits,
-- spaces and dashes, kept in capitals.
function N.validCall(s)
  if type(s) ~= "string" then return nil end
  s = s:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " "):upper()
  if #s < 2 or #s > 16 or not s:match("^[%w%- ]+$") then return nil end
  return s
end

local FIELDS = { "n", "unit", "owner", "call", "kind", "issued", "by", "sid", "sname", "mass", "first", "last",
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
-- the crypto under it. kiosk.lua becomes its startup, as on a customer's pass:
-- no shell, no updater, no token. Updated by coming back to the tower.
N.FILES = {
  "nav.lua", "lib/nav.lua", "lib/navui.lua", "lib/display.lua", "lib/tui.lua", "lib/seclink.lua",
  "ccryptolib/aead.lua", "ccryptolib/chacha20.lua", "ccryptolib/poly1305.lua",
  "ccryptolib/random.lua", "ccryptolib/blake3.lua", "ccryptolib/config.lua",
  "ccryptolib/internal/util.lua", "ccryptolib/internal/packing.lua",
  "ccryptolib/internal/hw.lua",
}
N.STARTUP = "kiosk.lua"
-- Found on CINDER's own machines and never on a unit: refused untouched.
N.DEV_MARKERS = { ".ghtoken", ".fleetkeys", ".dronekey", ".custkeys", ".navkeys", ".role", ".installed", ".autorun" }
N.KEEP = { [".navkey"] = true, [".navkey.ctr"] = true, [".nav"] = true }

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
  writeText(fsys, join(mount, ".kiosk"), "nav\n")
  writeText(fsys, join(mount, ".pass"), rec.unit .. "\n")     -- kiosk keeps the label on it
  writeText(fsys, join(mount, ".nav"), N.unitFile(rec))
  if opts.version then writeText(fsys, join(mount, ".version"), opts.version .. "\n") end
  if opts.keyHex then
    writeText(fsys, join(mount, ".navkey"), opts.keyHex .. "\n")
    if fsys.exists(join(mount, ".navkey.ctr")) then fsys.delete(join(mount, ".navkey.ctr")) end
  end
  return true, #N.FILES + 1
end

return N
