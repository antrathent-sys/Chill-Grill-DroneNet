--- display: the flight operations wall.
--
-- One screen for an advanced monitor wall (a 5x5 at text scale 0.5 is 100x66):
--
--   +-- header: title, clock, global status, restricted-area stripe ----------+
--   | TACTICAL MAP                              | FLIGHT DATA (selected drone) |
--   |  grid, range rings round home,            |  big speed readout, ALT HDG |
--   |  planned route as dotted lines, the       |  DST ETA OFF LEG PHASE,     |
--   |  active leg marching from the drone to    |  power and FE bars, dock    |
--   |  its target, scheduled trips in amber,    | FLEET: every drone, its     |
--   |  trails, drone arrows with id and speed   |  phase, speed, power, link  |
--   +-- MISSION CONTROL: leg chain, leg progress | SCHEDULED TRIPS: T-minus ---+
--   +-- alert ticker ----------------------------------------------------------+
--
-- Pure: it draws plain tables onto a canvas and flushes the canvas to any
-- term-like object (a monitor, or a fake one in tools/test_display.lua). It
-- never reads a peripheral or the network. console.lua does that.
--
-- The map is drawn in teletext: CC characters 128-159 are 2x3 blocks, so each
-- character cell carries six pixels in one ink colour. Text always wins over
-- pixels in the same cell.
--
--   local D = dofile("lib/display.lua")
--   D.applyPalette(mon)
--   local c = D.canvas(mon.getSize())
--   D.ingest(model, telemetryPacket, now)  D.ingestPlan(model, planPacket, now)
--   D.render(c, model, now)  c:flush(mon)

local D = {}

local floor, max, min, sqrt, abs = math.floor, math.max, math.min, math.sqrt, math.abs

-- colour roles -> blit hex digit. The palette below redefines those slots.
D.C = {
  bg = "f", grid = "7", dim = "8", green = "d", bright = "5", white = "0",
  amber = "1", amberDim = "c", red = "e", redDim = "a", cyan = "9", cyanDim = "3",
  warn = "4", panel = "b",
}

-- Themes: what the 16 colour slots look like, the words on the wall, and a few
-- drawing choices. The roles in D.C never change - a theme only restyles them.
--   silo      phosphor green, amber and red; hazard stripes
--   imperial  black and gunmetal, white and steel, imperial red and orange;
--             segmented rules, lettered sector grid, targeting brackets
D.THEMES = {
  silo = {
    palette = {
      f = 0x030604, ["7"] = 0x0c2a15, ["8"] = 0x22703a, d = 0x36e063, ["5"] = 0xb0ffc6,
      ["0"] = 0xe8fff0, ["1"] = 0xffae00, c = 0x6e4a00, e = 0xff2b2b, a = 0x4d0d0d,
      ["9"] = 0x3ad8ff, ["3"] = 0x114f63, ["4"] = 0xffe066, b = 0x07140c,
      ["2"] = 0x7a2cff, ["6"] = 0xff66cc,
    },
    titleFg = "f", titleBg = "d", boardFg = "f", boardBg = "1",
    stripe = "hazard", sectors = false, reticle = false,
    text = {
      title = "CHILL & GRILL // DRONENET", subtitle = "FLIGHT OPERATIONS",
      banner = " RESTRICTED AREA // AUTHORISED FLIGHT CREW ONLY ", status = "STATUS",
      map = " TACTICAL MAP ", side = " FLIGHT DATA", fleet = " FLEET",
      board = " MISSION CONTROL ", sched = " SCHEDULED TRIPS ",
      nominal = "ALL SYSTEMS NOMINAL // NO ALERTS", home = "HOME",
      noContact = "NO CONTACT", awaiting = "AWAITING TELEMETRY", noMission = "NO ACTIVE MISSION",
      noSched = "NONE SCHEDULED", progress = "LEG PROGRESS",
      lost = "LINK LOST", stale = "LINK STALE", lowPower = "LOW POWER",
      drones = "DRONES", trips = "TRIPS",
    },
  },
  imperial = {
    palette = {
      f = 0x040507, ["7"] = 0x151a21, ["8"] = 0x5d6775, d = 0xc7cfd9, ["5"] = 0xffffff,
      ["0"] = 0xedf1f5, ["1"] = 0xff7a1a, c = 0x5a2b08, e = 0xe3201b, a = 0x480b0a,
      ["9"] = 0x8fd8ff, ["3"] = 0x1c4a5f, ["4"] = 0xffc83a, b = 0x0b0e12,
      ["2"] = 0x7a2cff, ["6"] = 0xff66cc,
    },
    titleFg = "0", titleBg = "e", boardFg = "0", boardBg = "e",
    stripe = "segments", sectors = true, reticle = true,
    text = {
      title = "IMPERIAL FLIGHT COMMAND", subtitle = "DRONENET",
      banner = " CLASSIFIED // IMPERIAL CLEARANCE REQUIRED ", status = "CONDITION",
      map = " SECTOR SCAN ", side = " UNIT TELEMETRY", fleet = " SQUADRON",
      board = " OPERATION ", sched = " DEPLOYMENT ORDERS ",
      nominal = "ALL SYSTEMS OPERATIONAL", home = "BASE",
      noContact = "NO SIGNAL", awaiting = "AWAITING TRANSMISSION", noMission = "NO ACTIVE OPERATION",
      noSched = "NO ORDERS", progress = "VECTOR",
      lost = "SIGNAL LOST", stale = "SIGNAL WEAK", lowPower = "POWER CRITICAL",
      drones = "UNITS", trips = "ORDERS",
    },
  },
}
D.theme = D.THEMES.imperial
D.PALETTE = D.theme.palette

--- Pick a theme by name. Returns false for an unknown name (nothing changes).
function D.setTheme(name)
  local th = D.THEMES[name]
  if not th then return false end
  D.theme, D.PALETTE = th, th.palette
  return true
end

local HEX_COLOUR = {
  ["0"] = 1, ["1"] = 2, ["2"] = 4, ["3"] = 8, ["4"] = 16, ["5"] = 32, ["6"] = 64, ["7"] = 128,
  ["8"] = 256, ["9"] = 512, a = 1024, b = 2048, c = 4096, d = 8192, e = 16384, f = 32768,
}

--- Redefine the 16 colour slots on a term that supports it. Returns true if applied.
function D.applyPalette(t)
  if not (t and t.setPaletteColour) then return false end
  for k, rgb in pairs(D.PALETTE) do pcall(t.setPaletteColour, HEX_COLOUR[k], rgb) end
  return true
end

-- ---------------------------------------------------------------- formatting

local function pad(s, n)
  s = tostring(s)
  if n <= 0 then return "" end
  if #s >= n then return s:sub(1, n) end
  return s .. string.rep(" ", n - #s)
end
D.pad = pad

local function int(v)
  if type(v) ~= "number" or v ~= v then return nil end
  return floor(v + 0.5)
end

function D.fmtInt(n)
  n = int(n)
  if not n then return "--" end
  local s = tostring(abs(n)):reverse():gsub("(%d%d%d)", "%1,")
  s = s:reverse()
  if s:sub(1, 1) == "," then s = s:sub(2) end
  return (n < 0 and "-" or "") .. s
end

function D.fmtClock(sec)
  sec = max(0, floor(sec or 0))
  return string.format("%02d:%02d:%02d", floor(sec / 3600), floor(sec / 60) % 60, sec % 60)
end

function D.fmtEta(sec)
  sec = int(sec)
  if not sec then return "--:--" end
  return string.format("%d:%02d", floor(sec / 60), sec % 60)
end

local function signed(v)
  v = int(v)
  if not v then return "--" end
  return (v > 0 and "+" or "") .. v
end

local function blink(now, rate)
  return floor((now or 0) * (rate or 2)) % 2 == 0
end

-- ------------------------------------------------------------------- canvas

local Canvas = {}
Canvas.__index = Canvas

-- teletext bit weights: top-left, top-right, mid-left, mid-right, bottom-left, bottom-right
local WEIGHT = { 1, 2, 4, 8, 16, 32 }

function D.canvas(w, h)
  local c = setmetatable({ w = w, h = h, prev = {} }, Canvas)
  c:clear()
  return c
end

function Canvas:clear()
  self.cells = {}
  for y = 1, self.h do
    local r = { ch = {}, fg = {}, bg = {}, txt = {} }
    for x = 1, self.w do
      r.ch[x], r.fg[x], r.bg[x], r.txt[x] = " ", D.C.white, D.C.bg, false
    end
    self.cells[y] = r
  end
  self.px = {}
  self.pw = self.w * 2
  self.clip = nil
  self.hits = {}
end

--- Text at a cell. fg/bg nil keep what the cell has.
function Canvas:text(x, y, s, fg, bg)
  if y < 1 or y > self.h then return end
  s = tostring(s)
  local r = self.cells[y]
  for i = 1, #s do
    local cx = x + i - 1
    if cx >= 1 and cx <= self.w then
      r.ch[cx] = s:sub(i, i)
      if fg then r.fg[cx] = fg end
      if bg then r.bg[cx] = bg end
      r.txt[cx] = true
    end
  end
end

--- Background colour for a block of cells (does not hide pixels).
function Canvas:fill(x, y, w, h, bg)
  for yy = max(1, y), min(self.h, y + h - 1) do
    local r = self.cells[yy]
    for xx = max(1, x), min(self.w, x + w - 1) do r.bg[xx] = bg end
  end
end

--- One teletext pixel. Pixel coordinates run 1..w*2, 1..h*3.
function Canvas:pix(x, y, col)
  x, y = floor(x + 0.5), floor(y + 0.5)
  local k = self.clip
  if k then
    if x < k[1] or y < k[2] or x > k[3] or y > k[4] then return end
  elseif x < 1 or y < 1 or x > self.pw or y > self.h * 3 then
    return
  end
  self.px[(y - 1) * self.pw + x] = col
end

--- A line of pixels. With on/period it is dashed: pixel i is lit when
-- (i + phase) % period < on. Returns the length in pixels.
function Canvas:line(x0, y0, x1, y1, col, on, period, phase)
  local dx, dy = x1 - x0, y1 - y0
  local n = floor(max(abs(dx), abs(dy)) + 0.5)
  if n == 0 then self:pix(x0, y0, col) return 0 end
  if n > 4000 then return n end
  phase = phase or 0
  for i = 0, n do
    if not on or ((i + phase) % period) < on then
      self:pix(x0 + dx * i / n, y0 + dy * i / n, col)
    end
  end
  return n
end

function Canvas:circle(cx, cy, r, col, on, period)
  local n = max(12, floor(2 * math.pi * r))
  if n > 4000 then return end
  for i = 0, n - 1 do
    if not on or (i % period) < on then
      local a = 2 * math.pi * i / n
      self:pix(cx + r * math.cos(a), cy + r * math.sin(a), col)
    end
  end
end

local FONT = {
  ["0"] = { "111", "101", "101", "101", "111" }, ["1"] = { "010", "110", "010", "010", "111" },
  ["2"] = { "111", "001", "111", "100", "111" }, ["3"] = { "111", "001", "111", "001", "111" },
  ["4"] = { "101", "101", "111", "001", "001" }, ["5"] = { "111", "100", "111", "001", "111" },
  ["6"] = { "111", "100", "111", "101", "111" }, ["7"] = { "111", "001", "010", "010", "010" },
  ["8"] = { "111", "101", "111", "101", "111" }, ["9"] = { "111", "101", "111", "001", "111" },
  ["-"] = { "000", "000", "111", "000", "000" }, ["."] = { "000", "000", "000", "000", "010" },
  [":"] = { "000", "010", "000", "010", "000" }, [" "] = { "000", "000", "000", "000", "000" },
}

--- Big digits from a 3x5 pixel font, each font pixel scale x scale teletext
-- pixels. Returns the width in pixels.
function Canvas:bigText(px, py, s, col, scale)
  scale = scale or 2
  s = tostring(s)
  local adv = 4 * scale
  for i = 1, #s do
    local g = FONT[s:sub(i, i)] or FONT[" "]
    for gy = 1, 5 do
      for gx = 1, 3 do
        if g[gy]:sub(gx, gx) == "1" then
          for sy = 0, scale - 1 do
            for sx = 0, scale - 1 do
              self:pix(px + (i - 1) * adv + (gx - 1) * scale + sx, py + (gy - 1) * scale + sy, col)
            end
          end
        end
      end
    end
  end
  return #s * adv
end

--- One row as the three blit strings. Text cells as written; other cells
-- composed from their six pixels (majority colour as ink).
function Canvas:row(y)
  local r = self.cells[y]
  local pw, px = self.pw, self.px
  local base = (y - 1) * 3
  local s, f, b = {}, {}, {}
  for x = 1, self.w do
    if r.txt[x] then
      s[x], f[x], b[x] = r.ch[x], r.fg[x], r.bg[x]
    else
      local bits, cnt, ink, best, k = 0, nil, nil, 0, 0
      for sy = 0, 2 do
        local rowi = (base + sy) * pw + (x - 1) * 2
        for sx = 1, 2 do
          k = k + 1
          local col = px[rowi + sx]
          if col then
            bits = bits + WEIGHT[k]
            cnt = cnt or {}
            local n = (cnt[col] or 0) + 1
            cnt[col] = n
            if n > best then best, ink = n, col end
          end
        end
      end
      if bits == 0 then
        s[x], f[x], b[x] = " ", r.fg[x], r.bg[x]
      elseif bits >= 32 then
        -- bottom-right has no bit of its own: draw the inverse pattern
        s[x], f[x], b[x] = string.char(128 + 63 - bits), r.bg[x], ink
      else
        s[x], f[x], b[x] = string.char(128 + bits), ink, r.bg[x]
      end
    end
  end
  return table.concat(s), table.concat(f), table.concat(b)
end

--- Write changed rows to a term. Returns how many rows were written.
function Canvas:flush(t)
  local n = 0
  for y = 1, self.h do
    local s, f, b = self:row(y)
    local key = s .. "\0" .. f .. b
    if self.prev[y] ~= key then
      t.setCursorPos(1, y)
      t.blit(s, f, b)
      self.prev[y] = key
      n = n + 1
    end
  end
  return n
end

-- -------------------------------------------------------------------- model

function D.newModel()
  return { drones = {}, order = {}, scheduled = {}, home = nil, selected = nil, now = 0 }
end

local function droneFor(m, id)
  local d = m.drones[id]
  if not d then
    d = { id = id, trail = {} }
    m.drones[id] = d
    m.order[#m.order + 1] = id
    table.sort(m.order)
  end
  m.selected = m.selected or id
  return d
end

--- A telemetry packet (lib/link.lua packet) received at console time `now`.
function D.ingest(m, p, now)
  local d = droneFor(m, p.id)
  d.pkt, d.got = p, now
  if type(p.x) == "number" and type(p.z) == "number" then
    local tr = d.trail
    local last = tr[#tr]
    if not last or (p.x - last.x) ^ 2 + (p.z - last.z) ^ 2 >= 16 then
      tr[#tr + 1] = { x = p.x, z = p.z }
      if #tr > 400 then table.remove(tr, 1) end
    end
  end
  return d
end

--- "cruise:2000.5:5000.5|hover:2000.5:5000.5|drop|dock:0.5:0.5" -> list
function D.parseRoute(route)
  local out = {}
  if type(route) ~= "string" or route == "" then return out end
  for item in (route .. "|"):gmatch("([^|]*)|") do
    local kind, x, z = item:match("^([^:]+):([%-%d%.]+):([%-%d%.]+)$")
    if kind then
      out[#out + 1] = { kind = kind, x = tonumber(x), z = tonumber(z) }
    elseif item ~= "" then
      out[#out + 1] = { kind = item }
    end
  end
  return out
end

--- A plan packet (lib/link.lua planPacket): the drone's whole route.
function D.ingestPlan(m, p, now)
  local d = droneFor(m, p.id)
  d.plan = { leg = p.leg, n = p.n, mode = p.mode, pts = D.parseRoute(p.route),
             hx = p.hx, hz = p.hz, sx = p.sx, sz = p.sz, got = now }
  if p.hx and p.hz and not m.home then m.home = { x = p.hx, z = p.hz } end
  return d
end

--- LIVE under 5 s since the last packet, STALE under 30 s, then LOST.
function D.droneState(d, now)
  if not d or not d.got then return "NONE", D.C.dim end
  local age = now - d.got
  if age > 30 then return "LOST", D.C.red end
  if age > 5 then return "STALE", D.C.warn end
  return "LIVE", D.C.green
end

function D.alerts(m, now)
  local out = {}
  for _, id in ipairs(m.order) do
    local d = m.drones[id]
    local st = D.droneState(d, now)
    local p = d.pkt or {}
    local T = D.theme.text
    if st == "LOST" then out[#out + 1] = T.lost .. " " .. id:upper()
    elseif st == "STALE" then out[#out + 1] = T.stale .. " " .. id:upper() end
    if type(p.energy) == "number" and p.energy >= 0 and p.energy < 25 then
      out[#out + 1] = T.lowPower .. " " .. id:upper()
    end
  end
  return out
end

function D.status(m, now)
  if #m.order == 0 then return "NO CONTACT", D.C.dim end
  local worst = "NOMINAL"
  for _, id in ipairs(m.order) do
    local d = m.drones[id]
    local st = D.droneState(d, now)
    local e = d.pkt and d.pkt.energy
    if st == "LOST" then return "ALERT", D.C.red end
    if st == "STALE" or (type(e) == "number" and e >= 0 and e < 25) then worst = "CAUTION" end
  end
  return worst, worst == "NOMINAL" and D.C.green or D.C.warn
end

-- ------------------------------------------------------------------- layout

function D.layout(w, h)
  if w < 60 or h < 30 then return { tiny = true } end
  local right = max(32, floor(w * 0.34))
  local boardH = max(10, floor(h * 0.22))
  local midH = h - 3 - boardH
  return {
    map = { x = 1, y = 4, w = w - right, h = midH },
    side = { x = w - right + 1, y = 4, w = right, h = midH },
    board = { x = 1, y = h - boardH + 1, w = w, h = boardH },
  }
end

local function niceStep(raw)
  if raw <= 0 then return 100 end
  local p = 10 ^ floor(math.log(raw) / math.log(10))
  local f = raw / p
  local n = (f < 1.5 and 1) or (f < 3.5 and 2) or (f < 7.5 and 5) or 10
  return n * p
end
D.niceStep = niceStep

local ARROW = { string.char(30), string.char(16), string.char(31), string.char(17) }   -- N E S W

local function arrowFor(vx, vz)
  if type(vx) ~= "number" or type(vz) ~= "number" or vx * vx + vz * vz < 4 then return "o" end
  local a = math.deg(math.atan2(vx, -vz)) % 360
  return ARROW[floor((a + 45) / 90) % 4 + 1]
end
D.arrowFor = arrowFor

--- Centre and span (blocks) of everything worth showing.
function D.mapBounds(m)
  local x0, z0, x1, z1 = math.huge, math.huge, -math.huge, -math.huge
  local function add(x, z)
    if type(x) == "number" and type(z) == "number" then
      x0, x1, z0, z1 = min(x0, x), max(x1, x), min(z0, z), max(z1, z)
    end
  end
  if m.home then add(m.home.x, m.home.z) end
  for _, id in ipairs(m.order) do
    local d = m.drones[id]
    local p = d.pkt or {}
    add(p.x, p.z) add(p.tx, p.tz)
    if d.plan then
      add(d.plan.hx, d.plan.hz) add(d.plan.sx, d.plan.sz)
      for _, pt in ipairs(d.plan.pts) do add(pt.x, pt.z) end
    end
  end
  for _, s in ipairs(m.scheduled or {}) do
    for _, pt in ipairs(s.pts or {}) do add(pt.x, pt.z) end
  end
  if x0 == math.huge then return 0, 0, 1000 end
  return (x0 + x1) / 2, (z0 + z1) / 2, max(x1 - x0, z1 - z0, 400) * 1.25
end

-- ------------------------------------------------------------------ screens

-- A band of pixels across one text row: the silo's diagonal hazard stripe, or
-- the imperial segmented rule with red end caps.
local function band(c, x0, x1, row)
  local C = D.C
  local p0, p1 = (x0 - 1) * 2 + 1, x1 * 2
  local top = (row - 1) * 3
  if D.theme.stripe == "segments" then
    for px = p0, p1 do
      if (px - p0) % 14 < 11 then c:pix(px, top + 2, C.dim) end
    end
    for px = p0, min(p1, p0 + 5) do c:pix(px, top + 1, C.red) c:pix(px, top + 3, C.red) end
    for px = max(p0, p1 - 5), p1 do c:pix(px, top + 1, C.red) c:pix(px, top + 3, C.red) end
  else
    for px = p0, p1 do
      for py = top + 1, top + 3 do
        if ((px + py) % 6) < 3 then c:pix(px, py, C.amberDim) end
      end
    end
  end
end

local EMBLEM = { { 1, 0 }, { 2, 0 }, { 3, 0 }, { 0, 1 }, { 4, 1 }, { 0, 2 }, { 2, 2 }, { 4, 2 },
                 { 0, 3 }, { 4, 3 }, { 1, 4 }, { 2, 4 }, { 3, 4 } }

local function drawHeader(c, m, now)
  local C, w, T = D.C, c.w, D.theme.text
  c:fill(1, 1, w, 2, C.panel)
  local tx = 2
  if D.theme.reticle then
    for _, pt in ipairs(EMBLEM) do c:pix(3 + pt[1], 2 + pt[2], C.red) end
    tx = 5
  end
  c:text(tx, 1, T.title, C.bright, C.panel)
  local clock = "T+" .. D.fmtClock(now)
  local subX = tx + #T.title + 3
  if subX + #T.subtitle < w - #clock - 2 then c:text(subX, 1, T.subtitle, C.dim, C.panel) end
  c:text(w - #clock, 1, clock, C.white, C.panel)
  local status, sc = D.status(m, now)
  local word = (status == "NO CONTACT") and T.noContact or status
  local flash = status ~= "NOMINAL" and status ~= "NO CONTACT" and not blink(now)
  local badge = " " .. T.status .. ": " .. word .. " "
  c:text(tx, 2, badge, C.bg, flash and C.panel or sc)
  local live = 0
  for _, id in ipairs(m.order) do
    if D.droneState(m.drones[id], now) == "LIVE" then live = live + 1 end
  end
  local ix = max(21, tx + #badge + 2)
  local info = string.format("%s %d/%d LIVE   %s %d   CH 7212", T.drones, live, #m.order, T.trips, #(m.scheduled or {}))
  local room = w - #clock - 2 - ix
  c:text(ix, 2, pad(info, room), C.dim, C.panel)
  if m.link and #info + 2 < room then
    local tag = m.link .. ((m.rejected or 0) > 0 and ("  REJ " .. m.rejected) or "")
    c:text(ix + #info + 2, 2, pad(tag, room - #info - 2), m.link:find("^SEALED") and C.green or C.warn, C.panel)
  end
  band(c, 1, w, 3)
  local msg = T.banner
  if w > #msg + 4 then
    c:text(floor((w - #msg) / 2) + 1, 3, msg, D.theme.stripe == "segments" and C.red or C.amber, C.bg)
  end
end

local function drawMap(c, m, R, now)
  local C = D.C
  local ix0, iy0 = R.x * 2 + 1, R.y * 3 + 1
  local ix1, iy1 = (R.x + R.w - 2) * 2, (R.y + R.h - 2) * 3
  -- frame just outside the inner area
  c:line(ix0 - 1, iy0 - 1, ix1 + 1, iy0 - 1, C.dim)
  c:line(ix0 - 1, iy1 + 1, ix1 + 1, iy1 + 1, C.dim)
  c:line(ix0 - 1, iy0 - 1, ix0 - 1, iy1 + 1, C.dim)
  c:line(ix1 + 1, iy0 - 1, ix1 + 1, iy1 + 1, C.dim)
  c:text(R.x + 2, R.y, D.theme.text.map, D.theme.titleFg, D.theme.titleBg)

  local cx, cz, span = D.mapBounds(m)
  local pw, ph = ix1 - ix0, iy1 - iy0
  local scale = min(pw, ph) / span
  local mx, my = (ix0 + ix1) / 2, (iy0 + iy1) / 2
  local function P(x, z) return mx + (x - cx) * scale, my + (z - cz) * scale end
  local cxMin, cxMax, cyMin, cyMax = R.x + 1, R.x + R.w - 2, R.y + 1, R.y + R.h - 2
  local function cellOf(px, py) return floor((px - 1) / 2) + 1, floor((py - 1) / 3) + 1 end
  local function mtext(x, y, s, fg, bg)
    if y < cyMin or y > cyMax then return end
    if x < cxMin then s = s:sub(cxMin - x + 1) x = cxMin end
    if x + #s - 1 > cxMax then s = s:sub(1, max(0, cxMax - x + 1)) end
    if #s > 0 then c:text(x, y, s, fg, bg) end
  end

  c.clip = { ix0, iy0, ix1, iy1 }
  -- grid
  local cols, rows = {}, {}
  local step = niceStep(span / 6)
  local wx0, wx1 = cx - (pw / 2) / scale, cx + (pw / 2) / scale
  local wz0, wz1 = cz - (ph / 2) / scale, cz + (ph / 2) / scale
  local gx = math.ceil(wx0 / step) * step
  for _ = 1, 60 do
    if gx > wx1 then break end
    local px = P(gx, cz)
    c:line(px, iy0, px, iy1, gx == 0 and C.dim or C.grid, 1, 3)
    cols[#cols + 1] = px
    gx = gx + step
  end
  local gz = math.ceil(wz0 / step) * step
  for _ = 1, 60 do
    if gz > wz1 then break end
    local _, py = P(cx, gz)
    c:line(ix0, py, ix1, py, gz == 0 and C.dim or C.grid, 1, 3)
    rows[#rows + 1] = py
    gz = gz + step
  end
  -- range rings round home
  if m.home then
    local hx, hy = P(m.home.x, m.home.z)
    local ring = niceStep(span / 4)
    for k = 1, 3 do c:circle(hx, hy, k * ring * scale, C.dim, 1, 4) end
  end
  -- scheduled trips: amber dotted routes out from home
  for _, s in ipairs(m.scheduled or {}) do
    local ax, az = m.home and m.home.x or 0, m.home and m.home.z or 0
    for _, pt in ipairs(s.pts or {}) do
      local x0, y0 = P(ax, az)
      local x1, y1 = P(pt.x, pt.z)
      c:line(x0, y0, x1, y1, C.amberDim, 1, 3)
      ax, az = pt.x, pt.z
    end
  end

  local labels = {}
  local phase = -floor(now * 8)
  for _, id in ipairs(m.order) do
    local d = m.drones[id]
    local p = d.pkt or {}
    local st = D.droneState(d, now)
    -- trail
    for _, t in ipairs(d.trail) do
      local tx, ty = P(t.x, t.z)
      c:pix(tx, ty, st == "LOST" and C.redDim or C.cyanDim)
    end
    -- route: done solid dim, active leg marching from the drone, future dotted
    local pts = d.plan and d.plan.pts or {}
    if #pts == 0 and p.tx then pts = { { kind = p.legKind or p.mode or "go", x = p.tx, z = p.tz } } end
    local sx = d.plan and (d.plan.hx or d.plan.sx)
    local sz = d.plan and (d.plan.hz or d.plan.sz)
    if not sx and d.trail[1] then sx, sz = d.trail[1].x, d.trail[1].z end
    local cur = p.leg or 0
    if #pts > 0 and (not d.plan) then cur = 1 end
    local ax, az = sx, sz
    for i, pt in ipairs(pts) do
      if pt.x then
        if ax then
          local x0, y0 = P(ax, az)
          local x1, y1 = P(pt.x, pt.z)
          if i < cur then
            c:line(x0, y0, x1, y1, C.dim)
          elseif i == cur and type(p.x) == "number" and st ~= "LOST" then
            local dx, dy = P(p.x, p.z)
            c:line(x0, y0, dx, dy, C.dim)
            c:line(dx, dy, x1, y1, C.bright, 2, 4, phase)
          else
            c:line(x0, y0, x1, y1, st == "LOST" and C.redDim or C.green, 1, 3)
          end
        end
        labels[#labels + 1] = { x = pt.x, z = pt.z, s = "+", fg = (i == cur) and C.amber or C.dim }
        ax, az = pt.x, pt.z
      elseif ax then
        labels[#labels + 1] = { x = ax, z = az, s = "X", fg = (i < cur) and C.dim or C.red }
      end
    end
  end
  c.clip = nil

  -- sector letters along the top, numbers down the side
  if D.theme.sectors then
    for i, px in ipairs(cols) do
      local kx = cellOf(px, iy0)
      mtext(kx + 1, cyMin, string.char(64 + (i - 1) % 26 + 1), C.dim)
    end
    for i, py in ipairs(rows) do
      local _, ky = cellOf(ix0, py)
      mtext(cxMin, ky - 1, tostring(i), C.dim)
    end
  end

  -- markers on top: scheduled destinations, route points, home, then drones
  for _, s in ipairs(m.scheduled or {}) do
    local last = s.pts and s.pts[#s.pts]
    if last then
      local kx, ky = cellOf(P(last.x, last.z))
      mtext(kx, ky, "+", C.amber)
      local tag = tostring(s.id):upper()
      if kx + #tag + 2 > cxMax then mtext(kx - #tag - 1, ky, tag, C.amberDim) else mtext(kx + 2, ky, tag, C.amberDim) end
    end
  end
  for _, l in ipairs(labels) do
    local kx, ky = cellOf(P(l.x, l.z))
    mtext(kx, ky, l.s, l.fg)
  end
  if m.home then
    local kx, ky = cellOf(P(m.home.x, m.home.z))
    mtext(kx, ky, "H", C.bg, C.green)
    mtext(kx - floor(#D.theme.text.home / 2), ky + 1, D.theme.text.home, C.dim)
  end
  local selected = m.selected
  for pass = 1, 2 do
    for _, id in ipairs(m.order) do
      if (pass == 2) == (id == selected) then
        local d = m.drones[id]
        local p = d.pkt or {}
        if type(p.x) == "number" and type(p.z) == "number" then
          local st = D.droneState(d, now)
          local kx, ky = cellOf(P(p.x, p.z))
          local fg = C.cyan
          if st == "LOST" then fg = C.red
          elseif st == "STALE" then fg = C.warn
          elseif id == selected and not blink(now, 4) then fg = C.white end
          local icon = st == "LOST" and "?" or arrowFor(p.vx, p.vz)
          local gap = 2
          if D.theme.reticle and id == selected then
            -- targeting brackets on the selected unit
            mtext(kx - 1, ky, "[", C.red)
            mtext(kx + 1, ky, "]", C.red)
            gap = 3
          end
          mtext(kx, ky, icon, fg)
          local tag = id:upper() .. (st == "LOST" and " LOST" or (" " .. (int(p.spd) or 0) .. "B/S"))
          if kx + #tag + gap > cxMax then mtext(kx - #tag - gap + 1, ky, tag, fg) else mtext(kx + gap, ky, tag, fg) end
        end
      end
    end
  end

  -- north, scale bar, grid size
  mtext(cxMax - 2, cyMin, string.char(30) .. "N", C.dim)
  local barPx = step * scale
  if barPx >= 6 and barPx < pw - 8 then
    local by = iy1 - 4
    c:line(ix0 + 3, by, ix0 + 3 + barPx, by, C.dim)
    c:line(ix0 + 3, by - 1, ix0 + 3, by + 1, C.dim)
    c:line(ix0 + 3 + barPx, by - 1, ix0 + 3 + barPx, by + 1, C.dim)
    local kx, ky = cellOf(ix0 + 3 + barPx + 3, by)
    mtext(kx, ky, D.fmtInt(step) .. " B", C.dim)
  end
end

local function drawSide(c, m, R, now)
  local C = D.C
  c:fill(R.x, R.y, R.w, R.h, C.panel)
  local x, w = R.x + 1, R.w - 2
  local yEnd = R.y + R.h - 1
  local y = R.y + 1
  local function line(s, fg)
    if y <= yEnd then c:text(x, y, pad(s, w), fg, C.panel) end
    y = y + 1
  end
  local function bar(label, v)
    if y > yEnd then y = y + 1 return end
    local bw = w - 9
    c:text(x, y, pad(label, 4), C.dim, C.panel)
    local ok = type(v) == "number" and v >= 0
    local fill = ok and floor(min(1, v / 100) * bw + 0.5) or 0
    local col = (ok and v < 25) and C.red or ((ok and v < 50) and C.warn or C.green)
    for i = 0, bw - 1 do c:text(x + 4 + i, y, " ", C.white, i < fill and col or C.grid) end
    c:text(x + 4 + bw, y, ok and string.format("%4d%%", floor(v + 0.5)) or "   --", C.white, C.panel)
    y = y + 1
  end
  c:text(R.x, R.y, pad(D.theme.text.side, R.w), D.theme.titleFg, D.theme.titleBg)

  local d = m.selected and m.drones[m.selected]
  if not d or not d.pkt then
    line("")
    line(blink(now) and ("  " .. D.theme.text.noContact) or "", C.warn)
    line("  " .. D.theme.text.awaiting, C.dim)
    line("  ON CHANNEL 7212", C.dim)
    y = y + 1
  else
    local p = d.pkt
    local st, stc = D.droneState(d, now)
    line(p.id:upper(), C.white)
    c:text(x + w - #st, y - 1, st, (st == "LOST" and not blink(now)) and C.panel or stc, C.panel)
    -- big speed readout
    local spd = tostring(int(p.spd) or 0)
    c:bigText(x * 2 + 1, (y - 1) * 3 + 2, spd, st == "LIVE" and C.bright or C.dim, 2)
    if y + 2 <= yEnd then c:text(x + #spd * 4 + 1, y + 2, "B/S", C.dim, C.panel) end
    y = y + 4
    line(string.format("ALT %7s   VV  %6s", D.fmtInt(p.y), type(p.vv) == "number" and string.format("%+.1f", p.vv) or "--"), C.green)
    line(string.format("HDG %7s   TLT %6s", int(p.hdg) and string.format("%03d", int(p.hdg)) or "--", int(p.tilt) or "--"), C.green)
    line(string.format("DST %7s   ETA %6s", D.fmtInt(p.dist), D.fmtEta(p.eta)), C.green)
    line(string.format("OFF %7s   LEG %6s", signed(p.off), (int(p.leg) or 0) .. "/" .. (int(p.legs) or 0)), C.green)
    line("PHASE " .. tostring(p.phase or "?"):upper() .. "  " .. tostring(p.mode or ""):upper(), C.bright)
    y = y + 1
    bar("PWR", p.energy)
    bar("FE", p.fe)
    line(string.format("DRAIN %s %%/MIN", type(p.drain) == "number" and string.format("%+.2f", p.drain) or "--"), C.dim)
    line(p.dock == 1 and "DOCK  LATCHED" or "DOCK  ------", p.dock == 1 and C.cyan or C.dim)
  end

  y = y + 1
  if y <= yEnd then c:text(R.x, y, pad(D.theme.text.fleet, R.w), D.theme.titleFg, D.theme.titleBg) end
  y = y + 1
  for _, id in ipairs(m.order) do
    if y > yEnd then break end
    local dd = m.drones[id]
    local pp = dd.pkt or {}
    local st, stc = D.droneState(dd, now)
    local sel = id == m.selected
    -- 1 + 8 + 1 + 7 + 1 + 3 + 1 + 4 = 26 = w - 6, then the 5-wide link state
    local row = string.format("%s%-8s %-7s %3s %4s", sel and string.char(16) or " ", id:upper():sub(1, 8),
      tostring(pp.phase or "-"):upper():sub(1, 7), int(pp.spd) or "--", int(pp.energy) and (int(pp.energy) .. "%") or "--")
    c:text(x, y, pad(row, w - 6), sel and C.white or C.green, C.panel)
    c:text(x + w - 5, y, pad(st, 5), stc, C.panel)
    c.hits[y] = { x0 = R.x, x1 = R.x + R.w - 1, id = id }
    y = y + 1
  end
end

local function drawBoard(c, m, R, now)
  local C = D.C
  local yTop, yAlert = R.y, R.y + R.h - 1
  local T = D.theme.text
  band(c, R.x, R.x + R.w - 1, yTop)
  c:text(R.x + 2, yTop, T.board, D.theme.boardFg, D.theme.boardBg)
  local split = floor(R.w * 0.56)
  c:text(R.x + split + 1, yTop, T.sched, D.theme.boardFg, D.theme.boardBg)
  local sepCol = D.theme.stripe == "segments" and C.dim or C.amberDim
  for py = yTop * 3 + 1, (yAlert - 1) * 3 do
    if py % 3 ~= 0 then c:pix((R.x + split - 1) * 2, py, sepCol) end
  end
  local function put(x, y, s, fg, bg)
    if y > yTop and y < yAlert then c:text(x, y, s, fg, bg) end
  end

  -- left: the selected drone's mission as a chain of legs
  local left = split - 2
  local d = m.selected and m.drones[m.selected]
  local y = yTop + 2
  if not d or not d.pkt then
    put(R.x + 2, y, T.noMission, C.dim)
  else
    local p, pl = d.pkt, d.plan
    put(R.x + 2, y, pad(string.format("%s  %s  LEG %d/%d  %s", p.id:upper(), tostring(p.mode or "?"):upper(),
      int(p.leg) or 0, int(p.legs) or 0, tostring(p.phase or ""):upper()), left), C.white)
    y = y + 2
    local pts = pl and pl.pts or {}
    if #pts == 0 and p.tx then pts = { { kind = p.legKind or p.mode or "go", x = p.tx, z = p.tz } } end
    local cur = (pl and int(p.leg)) or 1
    local xx = R.x + 2
    for i, it in ipairs(pts) do
      local label = "[" .. tostring(it.kind):upper() .. "]"
      if xx + #label + 3 > R.x + left then y = y + 1 xx = R.x + 2 end
      local fg, bg = C.green, nil
      if i < cur then fg = C.dim
      elseif i == cur then fg, bg = C.bg, blink(now) and C.bright or C.green
      elseif not it.x then fg = C.amber end
      put(xx, y, label, fg, bg)
      xx = xx + #label
      if i < #pts then put(xx, y, " > ", C.dim) xx = xx + 3 end
    end
    y = y + 2
    -- progress along the current leg
    local sx, sz = pl and (pl.hx or pl.sx), pl and (pl.hz or pl.sz)
    for i = 1, min(cur - 1, #pts) do
      if pts[i].x then sx, sz = pts[i].x, pts[i].z end
    end
    local frac
    if sx and type(p.tx) == "number" and type(p.dist) == "number" then
      local len = sqrt((p.tx - sx) ^ 2 + (p.tz - sz) ^ 2)
      if len > 1 then frac = max(0, min(1, 1 - p.dist / len)) end
    end
    local bw = max(4, left - 22)
    put(R.x + 2, y, T.progress, C.dim)
    local fill = frac and floor(frac * bw + 0.5) or 0
    for i = 0, bw - 1 do put(R.x + 15 + i, y, " ", C.white, i < fill and C.green or C.grid) end
    put(R.x + 16 + bw, y, frac and string.format("%3d%%", floor(frac * 100 + 0.5)) or " --", C.white)
    y = y + 1
    put(R.x + 2, y, pad(string.format("DIST %s   ETA %s   OFF LINE %s", D.fmtInt(p.dist), D.fmtEta(p.eta), signed(p.off)), left), C.green)
  end

  -- right: scheduled trips, soonest first
  local sx0 = R.x + split + 1
  local list = {}
  for _, s in ipairs(m.scheduled or {}) do list[#list + 1] = s end
  table.sort(list, function(a, b) return (a.at or 1e18) < (b.at or 1e18) end)
  local yy = yTop + 2
  if #list == 0 then put(sx0, yy, T.noSched, C.amberDim) end
  for i, s in ipairs(list) do
    if yy >= yAlert then break end
    local dt = s.at and (s.at - now)
    local tm = (not dt and "HOLD") or (dt <= 0 and "DUE") or ("T-" .. D.fmtClock(dt))
    local row = string.format("%-7s %-8s %-8s %s", tostring(s.id):upper(), tostring(s.drone or "-"):upper(),
      tostring(s.kind or ""):upper(), tm)
    put(sx0, yy, pad(row, R.w - split - 1), i == 1 and C.amber or C.amberDim)
    local dst = s.pts and s.pts[#s.pts]
    if dst and yy + 1 < yAlert then
      put(sx0 + 2, yy + 1, pad("TO " .. D.fmtInt(dst.x) .. ", " .. D.fmtInt(dst.z), R.w - split - 3), C.amberDim)
    end
    yy = yy + 2
  end

  -- alert ticker
  local alerts = D.alerts(m, now)
  if #alerts > 0 then
    c:text(R.x + 1, yAlert, pad("! " .. table.concat(alerts, "   ! "), R.w - 2), blink(now) and C.red or C.redDim, C.bg)
  else
    c:text(R.x + 1, yAlert, pad(T.nominal, R.w - 2), C.dim, C.bg)
  end
end

--- Draw the whole wall. Returns the layout used.
function D.render(c, m, now)
  now = now or m.now or 0
  c:clear()
  local L = D.layout(c.w, c.h)
  if L.tiny then
    c:text(1, 1, "DRONENET", D.C.green)
    c:text(1, 2, "MONITOR TOO SMALL", D.C.warn)
    c:text(1, 3, c.w .. "X" .. c.h .. " < 60X30", D.C.dim)
    return L
  end
  drawHeader(c, m, now)
  drawMap(c, m, L.map, now)
  drawSide(c, m, L.side, now)
  drawBoard(c, m, L.board, now)
  return L
end

--- A touch on the fleet list selects that drone. Returns its id or nil.
function D.touch(c, m, x, y)
  local h = c.hits and c.hits[y]
  if h and x >= h.x0 and x <= h.x1 then
    m.selected = h.id
    return h.id
  end
  return nil
end

-- --------------------------------------------------------------------- demo

--- A made-up fleet for `console demo`, the tests and the HTML preview:
-- drone-1 flying an 80 s out-and-back delivery, drone-2 docked, drone-3 lost,
-- two scheduled trips. Deterministic in `now`.
function D.demoModel(now, keep)
  local m = D.newModel()
  m.now = now
  local home = { x = 0.5, z = 0.5 }
  m.home = home
  m.link = "SEALED 3 KEYS"
  local tgt = { x = 2000.5, z = 5000.5 }
  local s = (now % 80) / 80
  local out = s < 0.5
  local f = out and s * 2 or (s - 0.5) * 2
  local ax, az, bx, bz = home.x, home.z, tgt.x, tgt.z
  if not out then ax, az, bx, bz = tgt.x, tgt.z, home.x, home.z end
  local len = sqrt((bx - ax) ^ 2 + (bz - az) ^ 2)
  local ux, uz = (bx - ax) / len, (bz - az) / len
  local spd = 196
  local dist = len * (1 - f)
  D.ingest(m, {
    v = 1, type = "tlm", id = "drone-1", seq = floor(now), t = now, mode = "deliver", phase = "cruise",
    leg = out and 1 or 4, legs = 4, legKind = out and "cruise" or "dock",
    x = ax + (bx - ax) * f, y = 250, z = az + (bz - az) * f,
    vx = ux * spd, vz = uz * spd, vv = -0.4, spd = spd,
    hdg = floor(math.deg(math.atan2(ux, -uz)) % 360), tilt = 76, alte = -3,
    tx = bx, tz = bz, dist = dist, eta = dist / spd, off = floor(math.sin(now / 7) * 40),
    energy = 92 - s * 30, drain = -2.3, fe = 71, dock = 0, sat = 0,
  }, now - 0.4)
  local d1 = m.drones["drone-1"]
  d1.plan = { leg = out and 1 or 4, n = 4, mode = "deliver", hx = home.x, hz = home.z,
              pts = D.parseRoute("cruise:2000.5:5000.5|hover:2000.5:5000.5|drop|dock:0.5:0.5") }
  d1.trail = {}
  for k = 12, 1, -1 do
    local ff = f - k * 0.02
    if ff > 0 then d1.trail[#d1.trail + 1] = { x = ax + (bx - ax) * ff, z = az + (bz - az) * ff } end
  end
  D.ingest(m, { v = 1, type = "tlm", id = "drone-2", seq = 1, t = now, mode = "dock", phase = "docked",
    leg = 0, legs = 0, x = 3.5, y = 66, z = 2.5, vx = 0, vz = 0, vv = 0, spd = 0, hdg = 0, tilt = 0,
    energy = 100, drain = 0.8, fe = 100, dock = 1, sat = 0 }, now - 0.2)
  D.ingest(m, { v = 1, type = "tlm", id = "drone-3", seq = 99, t = now - 45, mode = "go", phase = "cruise",
    leg = 1, legs = 1, x = -2600, y = 240, z = 3100, vx = -120, vz = 90, vv = 0, spd = 150, hdg = 233,
    tilt = 70, tx = -4000, tz = 4200, dist = 1780, eta = 12, energy = 41, drain = -3.1, fe = 38,
    dock = 0, sat = 0 }, now - 45)
  local d3 = m.drones["drone-3"]
  d3.plan = { leg = 1, n = 1, mode = "go", sx = -1000, sz = 1800, pts = D.parseRoute("go:-4000:4200") }
  d3.trail = { { x = -1000, z = 1800 }, { x = -1400, z = 2100 }, { x = -1800, z = 2400 }, { x = -2200, z = 2750 } }
  m.scheduled = {
    { id = "M-0043", drone = "drone-2", kind = "courier", at = 1200, pts = { { x = -1500.5, z = 2200.5 } } },
    { id = "M-0044", drone = "drone-1", kind = "ferry", at = 4800,
      pts = { { x = 3200.5, z = -1800.5 }, { x = 4100.5, z = -600.5 } } },
  }
  if keep and keep.selected and m.drones[keep.selected] then m.selected = keep.selected end
  return m
end

return D
