--- towerui: the traffic tower's screens (AVIONICS.md), drawn the same on the
-- master and on every display-only centre.
--
--   M.radar(T, c, view, sel) -> hits
--                          the scope: for a monitor 3x3 or bigger (Alex,
--                          2026-10-01) - 57x38 at text scale 0.5. sel: the
--                          key of a craft touched on it, which gets a ring
--                          and a card of everything known about it
--   M.pick(hits, x, y)     the craft a touch at x, y was on, or nil
--   M.cardLines(ct, now)   that card's lines
--   M.board(T, c, view)    the list: every vehicle heard, distress first
--   M.wantsRadar(w, h)     is this screen big enough for the scope?
--
-- view: { name = "CHI", x, z (where this centre is), range (blocks to the
--         outer ring), now (os.clock), contacts = { { n, call, kind, x, y, z,
--         spd, hdg, st, t, tr (turn, deg/s, right +), wt (L/M/H) } },
--         centres = { { name, x, z } }, regs (count),
--         lastEvent, refused, feed = nil | "ok" | "none" (a centre's link to
--         its master) }
-- North up, this centre in the middle, a ring at the range and one at half.
-- Each vehicle is a dot with a short line where it is heading (where it will
-- be in 30 s) and its callsign beside it; distress in red; other centres a
-- green cross with their name. Pure; tools/test_nav.lua.

local M = {}

local floor, min, max, sqrt = math.floor, math.min, math.max, math.sqrt

M.RADAR_MIN_W, M.RADAR_MIN_H = 50, 30
M.LEAD_SECS = 30           -- the heading line shows where a vehicle will be in this long
M.STALE = 60               -- seconds unheard: away, off the scope

function M.wantsRadar(w, h) return (w or 0) >= M.RADAR_MIN_W and (h or 0) >= M.RADAR_MIN_H end

-- Each kind of craft its own colour (Alex, 2026-10-03: "blue for ships,
-- brown for land, deep blue for subs"). Air keeps the plain white - the most
-- of them, the easiest read. Red is only ever distress and green only ever a
-- traffic centre. Three slots of the palette lib/tui.lua leaves free; the
-- deep blue is lifted enough to read on the near-black ground.
M.PALETTE = { ["3"] = 0x4f9fd6,      -- vessel: sea blue
              ["1"] = 0xa8784a,      -- land: brown
              ["b"] = 0x4866d8 }     -- submarine: deep blue
M.KIND_INK = { air = "0", land = "1", sea = "3", sub = "b" }
--- Put the kinds' colours on a monitor or terminal (after tui's apply).
function M.apply(t)
  if not (t and t.setPaletteColour) then return false end
  for slot, rgb in pairs(M.PALETTE) do pcall(t.setPaletteColour, 2 ^ tonumber(slot, 16), rgb) end
  return true
end
local function inkOf(T, ct)
  if ct.st == "sos" then return T.C.accent end
  return M.KIND_INK[ct.kind or ""] or T.C.text
end
M.inkOf = inkOf

-- Each kind of craft its own colour (Alex, 2026-10-03: "blue for ships,
-- brown for land, deep blue for subs"). Air keeps the plain white - the most
-- of them, the easiest read. Red is only ever distress and green only ever a
-- traffic centre. Three slots of the palette lib/tui.lua leaves free; the
-- deep blue is lifted enough to read on the near-black ground.
M.PALETTE = { ["3"] = 0x4f9fd6,      -- vessel: sea blue
              ["1"] = 0xa8784a,      -- land: brown
              ["b"] = 0x4866d8 }     -- submarine: deep blue
M.KIND_INK = { air = "0", land = "1", sea = "3", sub = "b" }
--- Put the kinds' colours on a monitor or terminal (after tui's apply).
function M.apply(t)
  if not (t and t.setPaletteColour) then return false end
  for slot, rgb in pairs(M.PALETTE) do pcall(t.setPaletteColour, 2 ^ tonumber(slot, 16), rgb) end
  return true
end
local function inkOf(T, ct)
  if ct.st == "sos" then return T.C.accent end
  return M.KIND_INK[ct.kind or ""] or T.C.text
end
M.inkOf = inkOf

local function rangeWord(d)
  if d >= 1000 then return (d % 1000 == 0 and tostring(floor(d / 1000)) or string.format("%.1f", d / 1000)) .. "K" end
  return tostring(floor(d))
end
M.rangeWord = rangeWord

local function center(c, y, s, ink, bg)
  c:text(max(1, floor((c.w - #s) / 2) + 1), y, s, ink, bg)
end

-- pixel to cell
local function cellX(px) return floor((px - 1) / 2) + 1 end
local function cellY(py) return floor((py - 1) / 3) + 1 end

local function live(view, ct) return (view.now or 0) - (ct.t or -1e9) <= M.STALE end

--- One craft's key on the screens: its unit on the master, its number and
-- callsign on a centre (whose picture has no unit names).
function M.keyOf(ct) return ct.unit or (tostring(ct.n) .. ":" .. tostring(ct.call)) end

local KIND_WORD = { air = "AIRCRAFT", land = "LAND VEHICLE", sea = "VESSEL", sub = "SUBMARINE" }
local function three(h) return string.format("%03d", floor(h + 0.5) % 360) end

--- What the card says about one craft: the registration first, then
-- everything that is being heard for it - lines that would be empty are left
-- out (a centre's picture carries less than the master hears).
function M.cardLines(ct, now)
  local out = {}
  local function add(label, value) if value then out[#out + 1] = { label, tostring(value) } end end
  out[1] = { tostring(ct.reg or ""), tostring(ct.call or "") }
  add("TYPE", (KIND_WORD[ct.kind] or "") .. (ct.wt and ("  WT " .. ct.wt) or ""))
  add("STATE", ((now or 0) - (ct.t or -1e9) > M.STALE) and "AWAY" or tostring(ct.st or ""):upper())
  add("SPEED", string.format("%d B/S", floor((ct.spd or 0) + 0.5)))
  add("ALT", ct.y and (tostring(floor(ct.y + 0.5)) .. (ct.vs and string.format("  V/S %+.1f", ct.vs) or "")))
  add("TRACK", ct.hdg and (ct.spd or 0) > 0.5 and three(ct.hdg) or nil)
  add("NOSE", ct.nh and three(ct.nh) or nil)
  add("TURN", ct.tr and math.abs(ct.tr) >= 0.5 and string.format("%.0f/S %s", math.abs(ct.tr), ct.tr > 0 and "RIGHT" or "LEFT") or nil)
  add("POS", ct.x and string.format("%d %d", floor(ct.x + 0.5), floor(ct.z + 0.5)))
  add("HEARD", ct.t and (M.ago((now or 0) - ct.t) .. " AGO"))
  return out
end

--- The craft whose dot a touch at cell x, y was nearest, within a few cells.
function M.pick(hits, x, y)
  local best, bestD
  for _, h in ipairs(hits or {}) do
    local dx, dy = (h.x - x) * 2, (h.y - y) * 3          -- cells to pixels, near enough
    local d = dx * dx + dy * dy
    if d <= 64 and (not bestD or d < bestD) then best, bestD = h.key, d end
  end
  return best
end

-- the card: a panel low on the side away from the craft
local function card(T, c, ct, now, dotX)
  local lines = M.cardLines(ct, now)
  local w = 0
  for i, l in ipairs(lines) do w = max(w, i == 1 and (#l[1] + 2 + #l[2]) or (7 + #l[2])) end
  w = min(w + 2, c.w - 2)
  local h = #lines
  local x0 = dotX < c.w / 2 and (c.w - w) or 2
  local y0 = max(2, c.h - 1 - h)
  for i, l in ipairs(lines) do
    local y = y0 + i - 1
    c:text(x0, y, string.rep(" ", w), T.C.text, i == 1 and (ct.st == "sos" and T.C.accent or T.C.rule) or T.C.panel)
    if i == 1 then
      c:text(x0 + 1, y, (l[1] .. "  " .. l[2]):sub(1, w - 2), T.C.text, ct.st == "sos" and T.C.accent or T.C.rule)
    else
      c:text(x0 + 1, y, l[1], T.C.faint, T.C.panel)
      c:text(x0 + 8, y, l[2]:sub(1, w - 9), T.C.text, T.C.panel)
    end
  end
end

function M.radar(T, c, view, sel)
  c:fill(1, 1, c.w, c.h, T.C.ground)
  local range = view.range or 2000
  local count = 0
  for _, ct in ipairs(view.contacts or {}) do if live(view, ct) then count = count + 1 end end
  T.band(c, 1, "CINDER TRAFFIC  " .. (view.name or ""), string.format("RANGE %s  %d LIVE", rangeWord(range), count),
    T.C.text, T.C.faint)
  -- a centre says nothing about where its picture comes from (Alex,
  -- 2026-10-03): only NO SIGNAL when it has stopped coming
  local footRight = view.feed == "none" and "NO SIGNAL"
    or (view.cinder == "stealth" and "CINDER HIDDEN") or (view.cinder == "none" and "NO CINDER FEED")
    or ((view.refused or 0) > 0 and (view.refused .. " REFUSED") or nil)
  T.band(c, c.h, view.lastEvent or "LISTENING", footRight, T.C.faint, view.feed == "none" and T.C.warn or T.C.faint)
  local hits = {}
  if not (view.x and view.z) then
    center(c, floor(c.h / 2), "THIS CENTRE'S POSITION IS NOT SET", T.C.warn)
    center(c, floor(c.h / 2) + 2, "tower here <name> <x> <y> <z>", T.C.faint)
    return hits
  end
  local py0, py1 = 4, (c.h - 1) * 3
  local cx, cy = c.w + 0.5, (py0 + py1) / 2
  local R = min(c.w - 2, (py1 - py0) / 2 - 1)
  c:circle(cx, cy, R, T.C.rule)
  c:circle(cx, cy, R / 2, T.C.rule, 2, 5)
  local used = {}
  local function label(x, y, s, ink)
    if y <= 1 or y >= c.h then return end
    for i = 0, #s - 1 do if used[y * 1000 + x + i] then y = y + 1 break end end
    if y <= 1 or y >= c.h then return end
    x = max(1, min(x, c.w - #s + 1))
    c:text(x, y, s, ink)
    for i = 0, #s - 1 do used[y * 1000 + x + i] = true end
  end
  label(cellX(cx), cellY(cy - R) + 1, "N", T.C.faint)        -- just inside the ring, under the header
  label(cellX(cx + R * 0.71) + 1, cellY(cy - R * 0.71), rangeWord(range), T.C.faint)
  label(cellX(cx + R * 0.36) + 1, cellY(cy - R * 0.36), rangeWord(range / 2), T.C.faint)
  -- the colours' key, top left
  if c.w >= 30 then
    local kx = 2
    for _, k in ipairs({ { "air", "AIR" }, { "land", "LAND" }, { "sea", "SEA" }, { "sub", "SUB" } }) do
      c:text(kx, 2, k[2], M.KIND_INK[k[1]])
      kx = kx + #k[2] + 1
    end
  end
  -- the colours' key, top left
  if c.w >= 30 then
    local kx = 2
    for _, k in ipairs({ { "air", "AIR" }, { "land", "LAND" }, { "sea", "SEA" }, { "sub", "SUB" } }) do
      c:text(kx, 2, k[2], M.KIND_INK[k[1]])
      kx = kx + #k[2] + 1
    end
  end
  local function toPx(x, z) return cx + (x - view.x) / range * R, cy + (z - view.z) / range * R end
  local function cross(px, py, col)
    for d = -1, 1 do c:pix(px + d, py, col) c:pix(px, py + d, col) end
  end
  cross(cx, cy, T.C.ok)
  for _, ct in ipairs(view.centres or {}) do
    if ct.name ~= view.name and ct.x and ct.z then
      local px, py = toPx(ct.x, ct.z)
      local d = sqrt((px - cx) ^ 2 + (py - cy) ^ 2)
      if d <= R then
        cross(px, py, T.C.ok)
        label(cellX(px) + 1, cellY(py), ct.name, T.C.ok)
      end
    end
  end
  -- distress last, so it is drawn over anything else
  local list = {}
  for _, ct in ipairs(view.contacts or {}) do if live(view, ct) and ct.x then list[#list + 1] = ct end end
  -- the trails first, under everything: a dot where each craft was every
  -- N.TRAIL_SECS, fading with age - far apart is fast, bunched is slow
  local FADE = { T.C.faint, T.C.faint, T.C.rule, T.C.rule, T.C.panel, T.C.panel }
  for _, ct in ipairs(list) do
    local tr = ct.trail or {}
    local nx, ny = toPx(ct.x, ct.z)
    for i = #tr, 1, -1 do
      local p = tr[i]
      local px, py = toPx(p.x, p.z)
      if (px - nx) ^ 2 + (py - ny) ^ 2 >= 4 and sqrt((px - cx) ^ 2 + (py - cy) ^ 2) <= R then
        c:pix(px, py, FADE[#tr - i + 1] or T.C.panel)
      end
    end
  end
  table.sort(list, function(a, b) return (a.st == "sos" and 1 or 0) < (b.st == "sos" and 1 or 0) end)
  local picked
  for _, ct in ipairs(list) do
    local px, py = toPx(ct.x, ct.z)
    if sqrt((px - cx) ^ 2 + (py - cy) ^ 2) <= R then
      local key = M.keyOf(ct)
      hits[#hits + 1] = { key = key, x = cellX(px), y = cellY(py) }
      if sel and key == sel then picked = { ct = ct, px = px, py = py } end
      local col = inkOf(T, ct)
      if ct.hdg and (ct.spd or 0) > 0.5 then
        -- where it will be: straight on, or round its turn (Alex, 2026-10-03)
        local len = max(3, min(R / 3, (ct.spd * M.LEAD_SECS) / range * R))
        local secs = len / (ct.spd / range * R)
        -- at most a quarter turn drawn: a slow craft turning hard would curl
        local bend = max(-90, min(90, (ct.tr or 0) * secs))
        local h, step = math.rad(ct.hdg), len / 8
        local x0, y0 = px, py
        for _ = 1, 8 do
          local x1, y1 = x0 + math.sin(h) * step, y0 - math.cos(h) * step
          c:line(x0, y0, x1, y1, T.C.faint)
          x0, y0 = x1, y1
          h = h + math.rad(bend / 8)
        end
      end
      c:pix(px, py, col) c:pix(px + 1, py, col) c:pix(px, py + 1, col) c:pix(px + 1, py + 1, col)
      label(cellX(px) + 2, cellY(py), (ct.st == "sos" and "SOS " or "") .. tostring(ct.call or ""):sub(1, 10), col)
    end
  end
  -- the one touched: a ring round it, and its card
  if picked then
    c:circle(picked.px + 0.5, picked.py + 0.5, 4, T.C.text)
    card(T, c, picked.ct, view.now, cellX(picked.px))
  end
  return hits
end

local function ago(s)
  s = max(0, floor(s))
  if s < 60 then return s .. "S" end
  if s < 3600 then return floor(s / 60) .. "M" end
  if s < 86400 then return floor(s / 3600) .. "H" end
  return floor(s / 86400) .. "D"
end
M.ago = ago

local SHORT = { air = "AIR", land = "LAND", sea = "SEA", sub = "SUB" }

-- The other traffic centres inside this one's range ring, nearest first:
-- { name, dist, word } - the same ones its radar draws (Alex, 2026-10-03:
-- "i want other towers to show on the screens if in range")
local POINTS = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }
function M.centresInRange(view)
  local out = {}
  if not (view.x and view.z) then return out end
  for _, ct in ipairs(view.centres or {}) do
    if ct.name ~= view.name and ct.x and ct.z then
      local dx, dz = ct.x - view.x, ct.z - view.z
      local d = sqrt(dx * dx + dz * dz)
      if d <= (view.range or 2000) then
        local brg = (math.deg(math.atan2 and math.atan2(dx, -dz) or math.atan(dx, -dz)) + 360) % 360
        out[#out + 1] = { name = ct.name, dist = d, word = POINTS[floor((brg + 22.5) / 45) % 8 + 1] }
      end
    end
  end
  table.sort(out, function(a, b) return a.dist < b.dist end)
  return out
end
local function distWord(d)
  if d >= 1000 then return string.format("%.1fK", d / 1000) end
  return tostring(floor(d / 10 + 0.5) * 10)
end

function M.board(T, c, view)
  c:fill(1, 1, c.w, c.h, T.C.ground)
  local now = view.now or 0
  local count = 0
  for _, ct in ipairs(view.contacts or {}) do if live(view, ct) then count = count + 1 end end
  T.band(c, 1, "CINDER TRAFFIC  " .. (view.name or ""),
    view.regs and string.format("%d HEARD  %d REG", count, view.regs) or string.format("%d HEARD", count),
    T.C.text, T.C.faint)
  -- where each one is, X and Z, at every width (Alex, 2026-10-03: "add
  -- coordinates to the tui of controllers too"); a narrower board gives up
  -- type and heard (51 wide, the tower's own screen), then reg, weight and
  -- speed. WT: the weight class from Sable's mass, L M H (measured)
  local size = c.w >= 67 and "wide" or c.w >= 50 and "mid" or "narrow"
  local HEAD = {
    wide = { "%-8s %-12s %-4s %-2s %-5s%4s %5s %6s %6s %5s", "REG", "CALLSIGN", "TYPE", "WT", "STATE", "SPD", "ALT",
             "X", "Z", "HEARD" },
    mid = { "%-7s %-9s %-2s %-5s%4s %4s %6s %6s", "REG", "CALLSIGN", "WT", "STATE", "SPD", "ALT", "X", "Z" },
    narrow = { "%-10s %-5s%4s %6s %6s", "CALLSIGN", "STATE", "ALT", "X", "Z" } }
  local h = HEAD[size]
  c:text(2, 3, string.format(h[1], (unpack or table.unpack)(h, 2)):sub(1, c.w - 2), T.C.faint)
  -- distress first, then everything heard lately, then those away (packed,
  -- parked out of range, switched off), the most recently heard first
  local list = {}
  for _, ct in ipairs(view.contacts or {}) do list[#list + 1] = ct end
  local function rank(ct) if not live(view, ct) then return 2 end return ct.st == "sos" and 0 or 1 end
  table.sort(list, function(a, b)
    local ra, rb = rank(a), rank(b)
    if ra ~= rb then return ra < rb end
    if ra == 2 then return a.t > b.t end
    return (a.n or 0) < (b.n or 0)
  end)
  for i, ct in ipairs(list) do
    local y = 3 + i
    if y >= c.h - 1 then break end
    local away = not live(view, ct)
    local state = (away and "AWAY" or tostring(ct.st):upper()):sub(1, 4)
    local spd, alt = floor((ct.spd or 0) + 0.5), floor((ct.y or 0) + 0.5)
    local x, z = floor((ct.x or 0) + 0.5), floor((ct.z or 0) + 0.5)
    local call = tostring(ct.call)
    local row
    if size == "wide" then
      row = string.format("%-8s %-12s %-4s %-2s %-4s %4d %5d %6d %6d %5s", ct.reg or "", call:sub(1, 12),
        SHORT[ct.kind] or "", ct.wt or "", state, spd, alt, x, z, ago(now - ct.t))
    elseif size == "mid" then
      row = string.format("%-7s %-9s %-2s %-4s %4d %4d %6d %6d", tostring(ct.reg or ""):sub(1, 7), call:sub(1, 9),
        ct.wt or "", state, spd, alt, x, z)
    else
      row = string.format("%-10s %-4s %4d %6d %6d", call:sub(1, 10), state, alt, x, z)
    end
    if ct.st == "sos" and not away then
      c:text(1, y, string.rep(" ", c.w), T.C.text, T.C.accent)
      c:text(2, y, row:sub(1, c.w - 2), T.C.text, T.C.accent)
    else
      c:text(2, y, row:sub(1, c.w - 2), away and T.C.faint or T.C.text)
      if not away then
        -- the callsign, and the type where it is shown, in the kind's colour
        local ink = inkOf(T, ct)
        local cx0, cw0 = ({ wide = { 11, 12 }, mid = { 10, 9 }, narrow = { 2, 10 } })[size][1],
                         ({ wide = { 11, 12 }, mid = { 10, 9 }, narrow = { 2, 10 } })[size][2]
        if cx0 + cw0 - 1 <= c.w - 1 then c:text(cx0, y, row:sub(cx0 - 1, cx0 + cw0 - 2), ink) end
        if size == "wide" then c:text(24, y, row:sub(23, 26), ink) end
      end
    end
  end
  if #list == 0 then c:text(2, 5, "NOTHING HEARD YET", T.C.faint) end
  -- the other centres in range, on the row above the foot
  local near = M.centresInRange(view)
  local parts = {}
  for _, ct in ipairs(near) do parts[#parts + 1] = string.format("%s %s %s", ct.name, distWord(ct.dist), ct.word) end
  c:text(2, c.h - 1, ("CENTRES  " .. (#parts > 0 and table.concat(parts, "  ") or "NONE IN RANGE")):sub(1, c.w - 2),
    #parts > 0 and T.C.ok or T.C.faint)
  local footRight = view.feed == "none" and "NO SIGNAL"
    or (view.cinder == "stealth" and "CINDER HIDDEN") or (view.cinder == "none" and "NO CINDER FEED")
    or ((view.refused or 0) > 0 and (view.refused .. " REFUSED") or nil)
  T.band(c, c.h, view.lastEvent or "LISTENING", footRight)
end

return M
