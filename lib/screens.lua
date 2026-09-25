--- screens: the base control room - three advanced monitors, each drawn from
-- the one state table lib/state.lua builds.
--
--   DRONE     3x4 blocks, portrait    the unit: fuel, state, position, task
--   TACTICAL  6x4 blocks, landscape   the world map and a data rail
--   ORDER     3x4 blocks, portrait    the job in hand: ETA, stage, today's counts
--
-- Text scale 1.0. Every layout reads its size from the canvas (by CC's monitor
-- formula a 3x4 is 28x26 characters and a 6x4 is 60x26) and nothing is ever
-- written past the right edge: a row that will not fit is dropped whole, or
-- loses whole trailing words, never cut mid-word. A panel with nothing real
-- behind it is left off, not drawn empty.
--
-- Pure drawing onto a lib/display.lua canvas - no peripherals, no network - so
-- tools/test_screens.lua renders every screen on the desktop.
--
--   local SC = dofile("lib/screens.lua")
--   SC.applyPalette(mon)
--   SC.render("tactical", canvas, state)  canvas:flush(mon)

local SC = {}

local floor, max, min = math.floor, math.max, math.min

-- colour roles -> blit digit; SC.PALETTE says what each digit looks like
SC.K = {
  bg = "f", white = "0", lgrey = "8", grey = "7", dark = "b",
  ice = "3", iceDim = "9", amber = "1", red = "e",
}
local K = SC.K

SC.PALETTE = {
  f = 0x05070a, ["0"] = 0xf2f5f7, ["8"] = 0xa9b1b9, ["7"] = 0x5f6770, b = 0x1c2229,
  ["3"] = 0x9fdcf2, ["9"] = 0x2b5566, ["1"] = 0xffb02e, e = 0xe8342a,
  ["2"] = 0x39414a, ["4"] = 0x6fb8d3, ["5"] = 0xffffff, ["6"] = 0x7d858e,
  a = 0x5a1812, c = 0x5a3d0a, d = 0xc9d1d8,
}

local HEX_COLOUR = {
  ["0"] = 1, ["1"] = 2, ["2"] = 4, ["3"] = 8, ["4"] = 16, ["5"] = 32, ["6"] = 64, ["7"] = 128,
  ["8"] = 256, ["9"] = 512, a = 1024, b = 2048, c = 4096, d = 8192, e = 16384, f = 32768,
}

--- Redefine the 16 colour slots on a monitor. Returns true if applied.
function SC.applyPalette(t)
  if not (t and t.setPaletteColour) then return false end
  for k, rgb in pairs(SC.PALETTE) do pcall(t.setPaletteColour, HEX_COLOUR[k], rgb) end
  return true
end

-- The fixed world the tactical map shows: 10,000 blocks square round 0,0 at
-- 128 blocks per teletext pixel, so the whole world is 78 pixels across and
-- every marker is always somewhere on the map.
SC.MAP = { half = 5000, bpp = 128, cols = 40, ox = 2, oy = 2, grid = 2000, rings = { 1000, 2500 } }

SC.STATE_COLOUR = {
  CRUISE = "ice", INBOUND = "ice", CRADLED = "lgrey", STANDBY = "lgrey", LANDED = "amber", HOLD = "amber", MAINT = "amber",
  OFFLINE = "red",
}
SC.STAGES = { "QUE", "PCK", "FLY", "DRP" }

local function stateColour(word) return K[SC.STATE_COLOUR[word] or "lgrey"] end

--- The unit a screen is about: today the only one, later whichever is selected.
function SC.focus(st)
  return st and st.units and st.units[st.focus or 1] or nil
end

-- ------------------------------------------------------------------ formats

function SC.signed4(v)
  if type(v) ~= "number" or v ~= v then return "-----" end
  return string.format("%+05d", floor(v + 0.5))
end

local function int3(v)
  if type(v) ~= "number" or v ~= v then return "---" end
  return string.format("%03d", floor(v + 0.5) % 360)
end

local function whole(v)
  if type(v) ~= "number" or v ~= v then return "---" end
  return tostring(floor(v + 0.5))
end

--- MM:SS, or HH:MM from an hour up.
function SC.countdown(secs)
  if type(secs) ~= "number" or secs ~= secs then return "--:--" end
  secs = max(0, floor(secs + 0.5))
  if secs >= 3600 then
    return string.format("%02d:%02d", min(99, floor(secs / 3600)), floor(secs / 60) % 60)
  end
  return string.format("%02d:%02d", floor(secs / 60), secs % 60)
end

--- 850, or 1.2k from a thousand blocks up.
function SC.range(b)
  if type(b) ~= "number" or b ~= b then return "--" end
  if b >= 1000 then return string.format("%.1fk", b / 1000) end
  return tostring(floor(b + 0.5))
end

--- s cut to at most n characters by dropping whole trailing words; nil if
-- not even the first word fits.
function SC.words(s, n)
  s = tostring(s or "")
  if #s <= n then return s end
  local out
  for wd in s:gmatch("%S+") do
    local t = out and (out .. " " .. wd) or wd
    if #t > n then break end
    out = t
  end
  return out
end

-- ------------------------------------------------------------------ drawing

-- all of s at (x, y), or nothing
local function put(c, x, y, s, fg, bg)
  s = tostring(s)
  if y < 1 or y > c.h or x < 1 or x + #s - 1 > c.w then return false end
  c:text(x, y, s, fg, bg)
  return true
end
SC.put = put

-- left text and right text on one row between columns x0 and x1, or neither
local function lr(c, y, x0, x1, left, lc, right, rc)
  left, right = tostring(left or ""), tostring(right or "")
  local need = #left + #right + ((#left > 0 and #right > 0) and 1 or 0)
  if y < 1 or y > c.h or x0 < 1 or x1 > c.w or need > x1 - x0 + 1 then return false end
  if #left > 0 then c:text(x0, y, left, lc) end
  if #right > 0 then c:text(x1 - #right + 1, y, right, rc) end
  return true
end

-- label in grey then value in white, as one unit
local function kv(c, x, y, k, v)
  local s = tostring(v)
  if x + #k + #s > c.w then return false end
  put(c, x, y, k, K.grey)
  put(c, x + #k + 1, y, s, K.white)
  return true
end

-- a hairline through the middle of a text row, cells x0..x1
local function hair(c, y, x0, x1, col)
  if y < 1 or y > c.h then return end
  local py = (y - 1) * 3 + 2
  for px = (x0 - 1) * 2 + 1, x1 * 2 do c:pix(px, py, col) end
end

-- a section label: grey caps, then a dark hairline out to x1
local function sub(c, y, x0, x1, label)
  if not put(c, x0, y, label, K.grey) then return false end
  if x0 + #label + 1 <= x1 then hair(c, y, x0 + #label + 1, x1, K.dark) end
  return true
end

-- a pixel box on the outer sub-pixels of cells x0..x1, rows y0..y1
local function frame(c, x0, y0, x1, y1, col)
  local px0, px1, py0, py1 = (x0 - 1) * 2 + 1, x1 * 2, (y0 - 1) * 3 + 1, min(y1, c.h) * 3
  c:line(px0, py0, px1, py0, col)
  c:line(px0, py1, px1, py1, col)
  c:line(px0, py0, px0, py1, col)
  c:line(px1, py0, px1, py1, col)
end

-- an n-cell bar at (x, y) with frac of it lit in col and the rest dark
local function bar(c, x, y, n, frac, col)
  if n < 1 or y < 1 or y > c.h or x < 1 or x + n - 1 > c.w then return end
  local lit = type(frac) == "number" and floor(max(0, min(1, frac)) * n + 0.5) or 0
  for i = 0, n - 1 do c:text(x + i, y, " ", nil, i < lit and col or K.dark) end
end

-- the biggest scale, from `scale` down, at which s drawn from pixel px ends by rightPx
local function fitScale(px, s, scale, rightPx)
  while scale > 1 and px + #s * 4 * scale - scale - 1 > rightPx do scale = scale - 1 end
  return scale
end

local function footer(c, left, right)
  hair(c, c.h - 1, 1, c.w, K.dark)
  lr(c, c.h, 1, c.w, left, K.grey, right, K.grey)
end

local function baseName(st) return st.base and st.base.name or "M1" end

-- ------------------------------------------------------------ screen A: drone

function SC.drawDrone(c, st)
  local w = c.w
  local u = SC.focus(st)
  local n = #(st.units or {})
  lr(c, 1, 1, w, u and u.id or "NO UNIT", K.white, st.clock, K.grey)
  if not u then
    put(c, 1, 3, "AWAITING SIGNAL", K.grey)
    footer(c, baseName(st), "NO UNITS")
    return
  end

  -- fuel: big figure, "%", and a bar, all amber below 35
  local fuel = type(u.fuel) == "number" and max(0, min(100, u.fuel)) or nil
  local low = fuel ~= nil and fuel < 35
  local col = low and K.amber or K.white
  put(c, 1, 3, "FUEL", K.ice)
  frame(c, 1, 4, w, 10, K.grey)
  local digits = fuel and tostring(floor(fuel + 0.5)) or "--"
  local scale = fitScale(5, digits, 3, 30)
  c:bigText(5, scale == 3 and 13 or 15, digits, col, scale)
  put(c, 16, 7, "%", col)
  local blen = min(13, w - 17)
  if blen >= 4 then bar(c, 16, 8, blen, fuel and fuel / 100, low and K.amber or K.ice) end

  -- state strip
  if c.h >= 11 then
    c:fill(1, 11, w, 1, K.iceDim)
    put(c, 2, 11, u.state, K.white, K.iceDim)
  end

  sub(c, 13, 1, w, "POSITION")
  put(c, 1, 14, "X", K.grey)
  put(c, 3, 14, SC.signed4(u.x), K.white)
  put(c, 17, 14, "Z", K.grey)
  put(c, 19, 14, SC.signed4(u.z), K.white)
  kv(c, 1, 15, "ALT", whole(u.alt))
  kv(c, 17, 15, "HDG", int3(u.hdg))
  kv(c, 1, 16, "SPD", whole(u.spd) .. " B/S")

  sub(c, 18, 1, w, "TASK")
  local o = st.order
  if o and o.unit == u.id then
    local line = SC.words(o.kind .. " " .. o.code, w)
    if line then put(c, 1, 19, line, K.white) end
    local to = st.dest and st.dest.name or o.to
    local toLine = to and SC.words("TO " .. to, w)
    if toLine then put(c, 1, 20, toLine, K.grey) end
  else
    put(c, 1, 19, "STANDING BY", K.grey)
  end

  footer(c, baseName(st), n == 1 and "ONE UNIT" or (n .. " UNITS"))
end

-- ------------------------------------------------------- screen B: tactical

--- A map label beside a marker at pixel (px, py): to its right, or flipped to
-- its left if it would run past column maxCol. Never written past maxCol.
-- Returns the column used, or nil if it could not be placed.
function SC.label(c, px, py, s, col, maxCol)
  local cx, cy = floor((px - 1) / 2) + 1, floor((py - 1) / 3) + 1
  local x = cx + 2
  if x + #s - 1 > maxCol then x = cx - 1 - #s end
  if x < 1 or x + #s - 1 > maxCol or cy < 1 or cy > c.h then return nil end
  c:text(x, cy, s, col)
  return x
end

local function square(c, x0, y0, x1, y1, col)
  for x = x0, x1 do c:pix(x, y0, col) c:pix(x, y1, col) end
  for y = y0, y1 do c:pix(x0, y, col) c:pix(x1, y, col) end
end

local function block2(c, x, y, col)
  c:pix(x, y, col) c:pix(x + 1, y, col) c:pix(x, y + 1, col) c:pix(x + 1, y + 1, col)
end

function SC.drawMap(c, st, cols)
  local M = SC.MAP
  local pw, ph = cols * 2, c.h * 3
  local span = floor(2 * M.half / M.bpp + 0.5)
  local function P(x, z)
    return M.ox + floor((x + M.half) / M.bpp + 0.5), M.oy + floor((z + M.half) / M.bpp + 0.5)
  end
  c.clip = { 1, 1, pw, ph }

  -- border, very dark axes, a grey dot every grid step
  square(c, M.ox - 1, M.oy - 1, min(pw, M.ox + span + 1), min(ph, M.oy + span + 1), K.grey)
  local ax, az = P(0, 0)
  c:line(ax, M.oy, ax, M.oy + span, K.dark)
  c:line(M.ox, az, M.ox + span, az, K.dark)
  local g0 = -floor(M.half / M.grid) * M.grid
  for gx = g0, -g0, M.grid do
    for gz = g0, -g0, M.grid do
      local gpx, gpy = P(gx, gz)
      c:pix(gpx, gpy, K.grey)
    end
  end

  local base, dest, u = st.base, st.dest, SC.focus(st)
  local labels = {}
  local bx, by
  if base then
    bx, by = P(base.x, base.z)
    for _, r in ipairs(M.rings) do c:circle(bx, by, r / M.bpp, K.dark, 1, 3) end
  end
  if dest and base then
    local dx, dy = P(dest.x, dest.z)
    c:line(bx, by, dx, dy, K.iceDim, 2, 3)
  end
  if st.spawn then
    local sx, sy = P(st.spawn.x, st.spawn.z)
    square(c, sx - 1, sy - 1, sx + 1, sy + 1, K.grey)
  end
  if dest then
    local dx, dy = P(dest.x, dest.z)
    square(c, dx - 2, dy - 2, dx + 3, dy + 3, K.iceDim)
    block2(c, dx, dy, K.ice)
    labels[#labels + 1] = { dx + 3, dy, "DEST", K.ice }
  end
  if base then
    square(c, bx - 2, by - 2, bx + 2, by + 2, K.white)
    c:pix(bx, by, K.white)
    labels[#labels + 1] = { bx + 2, by, base.name, K.white }
  end
  if u and type(u.x) == "number" and type(u.z) == "number" then
    local ux, uy = P(u.x, u.z)
    local col = (u.state == "HOLD" and K.amber) or (u.state == "OFFLINE" and K.red) or K.ice
    if type(u.hdg) == "number" then
      local a = math.rad(u.hdg)
      for i = 2, 5 do c:pix(ux + 0.5 - math.sin(a) * i, uy + 0.5 + math.cos(a) * i, col) end
    end
    block2(c, ux, uy, col)
    -- on the base or the destination: its id goes a row lower so the labels do not collide
    local ly = uy
    for _, l in ipairs(labels) do
      if math.abs(ux - l[1]) < 8 and math.abs(uy - l[2]) < 5 then ly = uy + 3 end
    end
    labels[#labels + 1] = { ux + 1, ly, u.id, col }
  end
  c.clip = nil

  for _, l in ipairs(labels) do SC.label(c, l[1], l[2], l[3], l[4], cols) end
  local caption = "1 PX = " .. M.bpp .. " BLOCKS"
  if #caption + 1 <= cols then put(c, 2, c.h, caption, K.grey) end
end

function SC.drawRail(c, st, x0, x1)
  local rw = x1 - x0 + 1
  lr(c, 1, x0, x1, "TACTICAL", K.white, st.clock, K.grey)

  local u = SC.focus(st)
  if u then
    lr(c, 3, x0, x1, u.id, K.white, u.state, stateColour(u.state))
    lr(c, 4, x0, x1, SC.signed4(u.x), K.white, SC.signed4(u.z), K.white)
    lr(c, 5, x0, x1, "HDG " .. int3(u.hdg), K.grey, "ALT " .. whole(u.alt), K.grey)
    local fuel = type(u.fuel) == "number" and max(0, min(100, u.fuel)) or nil
    local low = fuel ~= nil and fuel < 35
    local pct = fuel and (floor(fuel + 0.5) .. "%") or "--"
    local blen = rw - 10
    if blen >= 3 and put(c, x0, 6, "FUEL", K.grey) then
      bar(c, x0 + 5, 6, blen, fuel and fuel / 100, low and K.amber or K.ice)
      put(c, x1 - #pct + 1, 6, pct, low and K.amber or K.white)
    end
  else
    put(c, x0, 3, "NO SIGNAL", K.grey)
  end

  local y = 8
  local d = st.dest
  if d then
    sub(c, 8, x0, x1, "DESTINATION")
    local name = SC.words(d.name, rw)
    if name then put(c, x0, 9, name, K.white) end
    lr(c, 10, x0, x1, "BRG " .. int3(d.brg), K.grey, SC.range(d.range), K.white)
    lr(c, 11, x0, x1, "ETA", K.grey, SC.countdown(d.eta), K.ice)
    y = 13
  end

  local sys = st.system or {}
  local sysY = #sys > 0 and (c.h - 1 - #sys) or c.h
  local log = st.log or {}
  if #log > 0 and sysY - 2 - y >= 1 then
    sub(c, y, x0, x1, "LOG")
    local rows = min(6, sysY - 2 - y)
    local ry = y + 1
    for i = max(1, #log - rows + 1), #log do
      local e = log[i]
      local msg = SC.words(e.msg, rw - 5)
      if msg then
        put(c, x0, ry, e.t, K.grey)
        put(c, x0 + 5, ry, msg, K.lgrey)
      end
      ry = ry + 1
    end
  end
  if #sys > 0 and sysY > y then
    sub(c, sysY, x0, x1, "SYSTEM")
    for i, s in ipairs(sys) do
      local col = (s.level == "fault" and K.red) or (s.level == "ok" and K.ice) or K.lgrey
      lr(c, sysY + i, x0, x1, s.name, K.grey, s.value, col)
    end
  end
  local foot = SC.words(baseName(st) .. " TACTICAL", rw)
  if foot then put(c, x0, c.h, foot, K.grey) end
end

function SC.drawTactical(c, st)
  local cols = min(SC.MAP.cols, c.w)
  SC.drawMap(c, st, cols)
  if c.w - (cols + 1) >= 14 then SC.drawRail(c, st, cols + 2, c.w) end
end

-- ---------------------------------------------------------- screen C: order

--- Four nodes on a hairline, filled ice for the stages reached, labels below.
function SC.stageRail(c, y, x0, x1, stage, dim)
  local n = #SC.STAGES
  if y + 1 > c.h then return end
  local py = (y - 1) * 3 + 2
  local cx = {}
  for i = 1, n do cx[i] = x0 + 1 + floor((x1 - x0 - 2) * (2 * i - 1) / (2 * n) + 0.5) end
  for px = (cx[1] - 1) * 2 + 1, (cx[n] - 1) * 2 + 1 do c:pix(px, py, K.grey) end
  for i = 1, n do
    local px = (cx[i] - 1) * 2 + 1
    local reached = (not dim) and i <= stage
    for dx = -1, 1 do
      for dy = -1, 1 do
        if reached or dx ~= 0 or dy ~= 0 then c:pix(px + dx, py + dy, reached and K.ice or K.grey) end
      end
    end
    local col = K.grey
    if not dim then col = (i == stage and K.white) or (i < stage and K.lgrey) or K.grey end
    put(c, cx[i] - 1, y + 1, SC.STAGES[i], col)
  end
end

-- a big two-scale counter with its label beside it (the short label if the long one will not fit)
local function counter(c, x, y, x1, value, label, short, ncol, lcol)
  local s = tostring(value or 0)
  c:bigText((x - 1) * 2 + 3, (y - 1) * 3 + 2, s, ncol, 2)
  local lx = x + 1 + #s * 4 + 1
  if lx + #label - 1 <= x1 then put(c, lx, y + 1, label, lcol)
  elseif lx + #short - 1 <= x1 then put(c, lx, y + 1, short, lcol) end
end

function SC.drawOrder(c, st)
  local w = c.w
  local o = st.order
  local dim = not o
  lr(c, 1, 1, w, "ORDER", K.white, o and o.code or "NO ORDER", o and K.ice or K.grey)

  put(c, 1, 3, "ETA", dim and K.grey or K.ice)
  frame(c, 1, 4, w, 10, dim and K.dark or K.grey)
  local s = o and SC.countdown(o.eta) or "--:--"
  local scale = fitScale(5, s, 3, w * 2 - 3)
  c:bigText(5, scale == 3 and 13 or 15, s, dim and K.grey or K.white, scale)

  if o then
    lr(c, 11, 1, w, "TYPE", K.grey, o.kind, K.white)
    local to = o.to and SC.words(o.to, w - 3)
    if to then lr(c, 12, 1, w, "TO", K.grey, to, K.white) end
  end

  sub(c, 14, 1, w, "STATUS")
  SC.stageRail(c, 15, 1, w, o and o.stage or 0, dim)

  local k = st.counters
  if k and c.h >= 22 then
    sub(c, 18, 1, w, "TODAY")
    local half = floor(w / 2)
    counter(c, 1, 19, half, k.out, "OUT", "OUT", K.ice, K.ice)
    counter(c, half + 1, 19, w, k.returned, "RETURNED", "RTN", K.lgrey, K.grey)
  end
end

-- ------------------------------------------------------------------- render

SC.SCREENS = { drone = SC.drawDrone, tactical = SC.drawTactical, order = SC.drawOrder }

--- Clear the canvas and draw one screen of the state onto it.
function SC.render(name, c, st)
  local f = SC.SCREENS[name]
  if not f then error("no screen called " .. tostring(name), 0) end
  c:clear()
  if c.w < 20 or c.h < 12 then
    put(c, 1, 1, "TOO SMALL", K.red)
    return
  end
  f(c, st or {})
end

return SC
