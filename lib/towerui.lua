--- towerui: the traffic tower's screens (AVIONICS.md), drawn the same on the
-- master and on every display-only centre.
--
--   M.radar(T, c, view)    the scope: for a monitor 3x3 or bigger (Alex,
--                          2026-10-01) - 57x38 at text scale 0.5
--   M.board(T, c, view)    the list: every vehicle heard, distress first
--   M.wantsRadar(w, h)     is this screen big enough for the scope?
--
-- view: { name = "CHI", x, z (where this centre is), range (blocks to the
--         outer ring), now (os.clock), contacts = { { n, call, kind, x, y, z,
--         spd, hdg, st, t } }, centres = { { name, x, z } }, regs (count),
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

function M.radar(T, c, view)
  c:fill(1, 1, c.w, c.h, T.C.ground)
  local range = view.range or 2000
  local count = 0
  for _, ct in ipairs(view.contacts or {}) do if live(view, ct) then count = count + 1 end end
  T.band(c, 1, "CINDER TRAFFIC  " .. (view.name or ""), string.format("RANGE %s  %d LIVE", rangeWord(range), count),
    T.C.text, T.C.faint)
  local footRight = view.feed == "none" and "NO FEED FROM MASTER" or view.feed == "ok" and "FEED"
    or ((view.refused or 0) > 0 and (view.refused .. " REFUSED") or nil)
  T.band(c, c.h, view.lastEvent or "LISTENING", footRight, T.C.faint, view.feed == "none" and T.C.warn or T.C.faint)
  if not (view.x and view.z) then
    center(c, floor(c.h / 2), "THIS CENTRE'S POSITION IS NOT SET", T.C.warn)
    center(c, floor(c.h / 2) + 2, "tower here <name> <x> <y> <z>", T.C.faint)
    return
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
  table.sort(list, function(a, b) return (a.st == "sos" and 1 or 0) < (b.st == "sos" and 1 or 0) end)
  for _, ct in ipairs(list) do
    local px, py = toPx(ct.x, ct.z)
    if sqrt((px - cx) ^ 2 + (py - cy) ^ 2) <= R then
      local col = ct.st == "sos" and T.C.accent or T.C.text
      if ct.hdg and (ct.spd or 0) > 0.5 then
        local len = max(3, min(R / 3, (ct.spd * M.LEAD_SECS) / range * R))
        local h = math.rad(ct.hdg)
        c:line(px, py, px + math.sin(h) * len, py - math.cos(h) * len, T.C.faint)
      end
      c:pix(px, py, col) c:pix(px + 1, py, col) c:pix(px, py + 1, col) c:pix(px + 1, py + 1, col)
      label(cellX(px) + 2, cellY(py), (ct.st == "sos" and "SOS " or "") .. tostring(ct.call or ""):sub(1, 10),
        ct.st == "sos" and T.C.accent or T.C.text)
    end
  end
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

function M.board(T, c, view)
  c:fill(1, 1, c.w, c.h, T.C.ground)
  local now = view.now or 0
  local count = 0
  for _, ct in ipairs(view.contacts or {}) do if live(view, ct) then count = count + 1 end end
  T.band(c, 1, "CINDER TRAFFIC  " .. (view.name or ""),
    view.regs and string.format("%d HEARD  %d REG", count, view.regs) or string.format("%d HEARD", count),
    T.C.text, T.C.faint)
  local wide = c.w >= 50
  c:text(2, 3, wide and string.format("%-8s %-12s %-4s %-5s %4s %5s %5s", "REG", "CALLSIGN", "TYPE", "STATE", "SPD",
    "ALT", "HEARD") or string.format("%-12s %-5s %4s %5s", "CALLSIGN", "STATE", "SPD", "ALT"), T.C.faint)
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
    if y >= c.h then break end
    local away = not live(view, ct)
    local state = away and "AWAY" or tostring(ct.st):upper()
    local row = wide and string.format("%-8s %-12s %-4s %-5s %4d %5d %5s", ct.reg or "", tostring(ct.call):sub(1, 12),
      SHORT[ct.kind] or "", state, floor((ct.spd or 0) + 0.5), floor((ct.y or 0) + 0.5), ago(now - ct.t))
      or string.format("%-12s %-5s %4d %5d", tostring(ct.call):sub(1, 12), state, floor((ct.spd or 0) + 0.5),
        floor((ct.y or 0) + 0.5))
    if ct.st == "sos" and not away then
      c:text(1, y, string.rep(" ", c.w), T.C.text, T.C.accent)
      c:text(2, y, row:sub(1, c.w - 2), T.C.text, T.C.accent)
    else
      c:text(2, y, row:sub(1, c.w - 2), away and T.C.faint or T.C.text)
    end
  end
  if #list == 0 then c:text(2, 5, "NOTHING HEARD YET", T.C.faint) end
  local footRight = view.feed == "none" and "NO FEED" or ((view.refused or 0) > 0 and (view.refused .. " REFUSED") or nil)
  T.band(c, c.h, view.lastEvent or "LISTENING", footRight)
end

return M
