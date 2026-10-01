--- navui: the screens of a CINDER NAV unit (AVIONICS.md). A consumer
-- product in CINDER's house style (lib/tui.lua): what the driver needs at a
-- glance, big; everything else quiet.
--
--   M.render(T, c, view, page) -> hit    draw one page on a lib/display.lua canvas
--   M.pages(kind, w)                     the pages a screen of that width cycles through
--   M.onSos(hit, x, y)                   was a touch on the distress key?
--
-- Every screen fitted to a unit shows one page, and a touch anywhere but the
-- SOS key moves it to the next; each screen keeps its own (Alex, 2026-10-01:
-- one screen that cycles, or several - speed, radar, altitude - each set
-- once). A one-block screen (15x10 at text scale 0.5) shows one thing big:
--
--   speed     ground speed, heading under it
--   height    height (Y) - DEPTH below sea level on a submarine; not on a boat
--   heading   heading and the compass point
--   radar     a ring, you in the middle, a dot for each vehicle within 1 km
--             and each traffic centre; your heading at the top. Very simple.
--   status    callsign, type, tower link, traffic, the nearest centre
--
-- A screen 30 or more wide starts on the overview: speed and height (or
-- heading) side by side, and on a panel the traffic list. Every page keeps
-- the tower link and the SOS key on its bottom row, and an advisory across
-- the row above, whatever page it is on.
--
-- view: { me = { reg, call, kind }, r = reading (lib/nav.lua N.reading),
--         link = "contact" | "none" | "search", traffic = { ... }, adv,
--         sos = nil | "armed" | "sent" | "heard" | "cancel", craft = true|false,
--         centres = { { name, dist, brg }, ... } nearest first,
--         unregistered = true, msg }
-- hit: { sos = { x1, x2, y } }. Pure; tools/test_nav.lua.

local M = {}

local floor, abs, max, min = math.floor, math.abs, math.max, math.min
local RANGE = 1000            -- the radar's ring, as far as a pong's traffic reaches

M.PAGES = {
  air  = { "speed", "height", "heading", "radar", "status" },
  land = { "speed", "heading", "height", "radar", "status" },
  sea  = { "speed", "heading", "radar", "status" },
  sub  = { "speed", "height", "heading", "radar", "status" },
}

--- The pages a screen cycles through: a wide one starts on the overview.
function M.pages(kind, w)
  local list = {}
  if (w or 0) >= 30 then list[1] = "overview" end
  for _, p in ipairs(M.PAGES[kind] or M.PAGES.air) do list[#list + 1] = p end
  return list
end

--- The page after this one on that screen (the first if it is not on it).
function M.nextPage(kind, w, page)
  local list = M.pages(kind, w)
  for i, p in ipairs(list) do
    if p == page then return list[i % #list + 1] end
  end
  return list[1]
end

-- the two big numbers and the small line of the overview, per vehicle type
M.BIG = {
  air  = { { "spd", "SPD B/S" }, { "alt", "ALT" } },
  land = { { "spd", "SPD B/S" }, { "hdg", "HDG" } },
  sea  = { { "spd", "SPD B/S" }, { "hdg", "HDG" } },
  sub  = { { "spd", "SPD B/S" }, { "depth", "DEPTH" } },
}
M.SMALL = {
  air  = { "hdg", "vs" },
  land = { "alt" },
  sea  = { "pos" },
  sub  = { "hdg", "vs" },
}

local function fmtSpd(v)
  if not v then return "--" end
  if v < 10 then return string.format("%.1f", v) end
  return tostring(floor(v + 0.5))
end

--- A value as text, for the big font (digits, '.', '-') or the small line.
function M.value(r, key)
  if not r then return "--" end
  if key == "spd" then return fmtSpd(r.spd) end
  if key == "alt" then return r.y and tostring(floor(r.y + 0.5)) or "--" end
  if key == "depth" then return r.depth and tostring(max(0, floor(r.depth + 0.5))) or "--" end
  if key == "hdg" then return r.hdg and string.format("%03d", floor(r.hdg + 0.5) % 360) or "---" end
  if key == "vs" then
    if not r.vs then return "--" end
    local v = floor(r.vs * 10 + 0.5) / 10
    return (v > 0 and "+" or "") .. string.format("%.1f", v)
  end
  if key == "pos" then
    return r.x and string.format("%d %d", floor(r.x + 0.5), floor(r.z + 0.5)) or "--"
  end
  return "--"
end

local function distWord(d)
  if not d then return "--" end
  if d >= 1000 then return string.format("%.1fK", d / 1000) end
  return tostring(floor(d / 10 + 0.5) * 10)
end

local CARDINALS = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }
local CARD_WORD = { N = "NORTH", NE = "NORTHEAST", E = "EAST", SE = "SOUTHEAST",
                    S = "SOUTH", SW = "SOUTHWEST", W = "WEST", NW = "NORTHWEST" }
local function cardinal(b) return b and CARDINALS[floor(((b % 360) + 22.5) / 45) % 8 + 1] or nil end

local LABEL = { hdg = "HDG", vs = "V/S", alt = "ALT", pos = "POS", depth = "DEPTH", spd = "SPD" }

local function center(c, y, s, ink, bg)
  c:text(max(1, floor((c.w - #s) / 2) + 1), y, s, ink, bg)
end

-- the bottom band: tower link at the left, the distress key at the right
local function footer(T, c, view)
  local y = c.h
  local link = ({ contact = { "TOWER CONTACT", T.C.ok }, none = { "NO TOWER CONTACT", T.C.warn },
                  search = { "CALLING TOWER", T.C.faint } })[view.link or "search"]
  if c.w < 30 then link = ({ contact = { "TOWER", T.C.ok }, none = { "NO TOWER", T.C.warn },
                             search = { "CALLING", T.C.faint } })[view.link or "search"] end
  c:text(1, y, string.rep(" ", c.w), T.C.faint, T.C.panel)
  c:text(2, y, link[1], link[2], T.C.panel)
  local key = ({ armed = "TOUCH AGAIN", sent = "SOS SENT", heard = "SOS HEARD",
                cancel = "CANCEL SOS?" })[view.sos or ""] or "SOS"
  local label = " " .. key .. " "
  local x1 = c.w - #label
  if x1 < #link[1] + 2 then           -- no room beside the link: the key wins
    c:text(1, y, string.rep(" ", c.w), T.C.faint, T.C.panel)
    x1 = c.w - #label
  end
  c:text(x1, y, label, T.C.text, view.sos and T.C.accent or T.C.rule)
  return { x1 = x1, x2 = c.w, y = y }
end

-- an advisory that fits: "TRAFFIC 2 O'CLOCK 300 SAME LEVEL" is "TFC 2H 300"
-- on a one-block screen
local function fitAdv(adv, w)
  if #adv <= w then return adv end
  local clock, dist = adv:match("^TRAFFIC (%d+) O'CLOCK (%S+)")
  if clock then return ("TFC " .. clock .. "H " .. dist):sub(1, w) end
  local who = adv:match("^DISTRESS (%S+)")
  if who then return ("SOS " .. who):sub(1, w) end
  return adv:sub(1, w)
end

local function advBand(T, c, view)
  if not view.adv then return false end
  local y = c.h - 1
  c:text(1, y, string.rep(" ", c.w), T.C.text, T.C.accent)
  center(c, y, fitAdv(view.adv, c.w), T.C.text, T.C.accent)
  return true
end

local function unregistered(T, c)
  T.band(c, 1, c.w >= 30 and "CINDER NAV" or "CINDER")
  center(c, floor(c.h / 2) - 1, "UNREGISTERED", T.C.warn)
  center(c, floor(c.h / 2) + 1, c.w >= 30 and "TAKE THIS UNIT TO CINDER" or "SEE CINDER", T.C.faint)
  return {}
end

-- ---------------------------------------------------------------- overview --
local function bigNumber(T, c, x, y, w, text, label, scale)
  local cells = math.ceil(T.headlinePx(text, scale) / 2)
  local bx = x + max(0, floor((w - cells) / 2))
  T.headline(c, bx, y, text, T.C.text, scale)
  local ly = y + (scale == 2 and 4 or 2)
  c:text(x + max(0, floor((w - #label) / 2)), ly, label, T.C.faint)
end

local function smallLine(T, c, y, view)
  local parts = {}
  for _, k in ipairs(M.SMALL[view.me.kind] or M.SMALL.air) do
    parts[#parts + 1] = LABEL[k] .. " " .. M.value(view.r, k)
  end
  if not view.craft then parts[#parts + 1] = "NO CRAFT" end
  center(c, y, table.concat(parts, "   "), T.C.text)
end

local function noticeLine(T, c, y, view, listed)
  if advBand(T, c, view) then return end
  if view.msg then center(c, y, view.msg:sub(1, c.w), T.C.text) return end
  if listed then return end
  local tr = view.traffic or {}
  if view.link ~= "contact" then
    center(c, y, ("NO TRAFFIC PICTURE"):sub(1, c.w), T.C.faint)
  elseif #tr == 0 then
    center(c, y, ("NO TRAFFIC NEAR"):sub(1, c.w), T.C.faint)
  else
    local t = tr[1]
    local s = string.format("TRAFFIC %d  NEAREST %s %s", #tr, t.call, distWord(t.dist))
    if #s > c.w then s = string.format("TFC %d %s", #tr, distWord(t.dist)) end
    center(c, y, s:sub(1, c.w), T.C.text)
  end
end

--- The traffic list on a panel: callsign, clock bearing, distance, height.
local function trafficList(T, c, y0, rows, view)
  T.band(c, y0, "TRAFFIC", tostring(#(view.traffic or {})))
  local tr = view.traffic or {}
  if #tr == 0 then
    center(c, y0 + 2, view.link == "contact" and "NOTHING WITHIN 1K" or "NO TRAFFIC PICTURE", T.C.faint)
    return
  end
  local hdg = view.r and view.r.hdg or 0
  for i = 1, min(rows, #tr) do
    local t = tr[i]
    local rel = floor(((t.brg - hdg) % 360 + 360) % 360 / 30 + 0.5) % 12
    local dy = t.dy >= 0 and ("+" .. floor(t.dy + 0.5)) or tostring(floor(t.dy + 0.5))
    local left = string.format("%-10s %2d O'CLK", t.call:sub(1, 10), rel == 0 and 12 or rel)
    local right = string.format("%5s %5s", distWord(t.dist), dy)
    c:text(2, y0 + i, left, t.warn and T.C.warn or T.C.text)
    c:text(c.w - #right, y0 + i, right, t.warn and T.C.warn or T.C.faint)
  end
end

local function overview(T, c, view)
  local big = M.BIG[view.me.kind] or M.BIG.air
  T.band(c, 1, "CINDER NAV", view.me.reg or "", T.C.text, T.C.faint)
  local half = floor(c.w / 2)
  bigNumber(T, c, 1, 3, half, M.value(view.r, big[1][1]), big[1][2], 2)
  bigNumber(T, c, half + 1, 3, c.w - half, M.value(view.r, big[2][1]), big[2][2], 2)
  smallLine(T, c, 8, view)
  if c.h < 20 then
    noticeLine(T, c, c.h - 1, view)
  else
    trafficList(T, c, 10, c.h - 13, view)
    noticeLine(T, c, c.h - 1, view, true)
  end
end

-- ------------------------------------------------------------ one big thing --
local TITLE = { speed = "SPEED", heading = "HEADING", radar = "RADAR", status = "STATUS" }
local function titleOf(page, kind)
  if page == "height" then return kind == "sub" and "DEPTH" or "ALTITUDE" end
  return TITLE[page] or page:upper()
end

-- the page's number, its label under it, and the small line under that
local function bigOf(page, view)
  local r, kind = view.r, view.me.kind
  if page == "speed" then
    return M.value(r, "spd"), "B/S", "HDG " .. M.value(r, "hdg")
  elseif page == "height" then
    if kind == "sub" then return M.value(r, "depth"), "BELOW SEA", "V/S " .. M.value(r, "vs") end
    return M.value(r, "alt"), "Y LEVEL", "V/S " .. M.value(r, "vs")
  elseif page == "heading" then
    local cp = r and cardinal(r.hdg)
    return M.value(r, "hdg"), cp and CARD_WORD[cp] or "NOT MOVING", "SPD " .. M.value(r, "spd")
  end
  return "--", "", nil
end

local function numberPage(T, c, view, page, idx, n)
  T.band(c, 1, titleOf(page, view.me.kind), idx .. "/" .. n, T.C.text, T.C.faint)
  local text, label, small = bigOf(page, view)
  if not view.craft and page ~= "heading" then small = "NO CRAFT" end
  local top, bottom = 3, c.h - 2
  local scale, cells, rows
  for _, s in ipairs({ 3, 2, 1 }) do
    cells = math.ceil(T.headlinePx(text, s) / 2)
    rows = math.ceil(5 * s / 3)
    if cells <= c.w - 2 and rows + 2 <= bottom - top + 1 then scale = s break end
  end
  scale = scale or 1
  cells, rows = math.ceil(T.headlinePx(text, scale) / 2), math.ceil(5 * scale / 3)
  local block = rows + 1 + (small and 1 or 0)
  local y0 = top + max(0, floor((bottom - top + 1 - block) / 2))
  T.headline(c, max(1, floor((c.w - cells) / 2) + 1), y0, text, T.C.text, scale)
  center(c, y0 + rows, label:sub(1, c.w), T.C.faint)
  if small then center(c, y0 + rows + 1, small:sub(1, c.w), T.C.text) end
  advBand(T, c, view)
end

-- the radar: a ring, you in the middle, a dot for each vehicle and centre.
-- Heading up when there is a heading, north up when there is not.
local function radarPage(T, c, view, idx, n)
  T.band(c, 1, "RADAR", (c.w >= 20 and (idx .. "/" .. n .. "  ") or "") .. "1K", T.C.text, T.C.faint)
  local hasAdv = view.adv ~= nil
  local topRow, botRow = 2, c.h - (hasAdv and 2 or 1)
  local py0, py1 = (topRow - 1) * 3 + 1, botRow * 3
  local cx, cy = c.w + 0.5, (py0 + py1) / 2
  local R = min(c.w - 1.5, (py1 - py0) / 2 - 1)
  c:circle(cx, cy, R, T.C.rule)
  -- you: a small cross
  for d = -1, 1 do c:pix(cx + d, cy, T.C.text) c:pix(cx, cy + d, T.C.text) end
  local up = view.r and view.r.hdg or 0
  local function dot(brg, dist, col, big)
    local a = math.rad(brg - up)
    local d = min(dist / RANGE, 1) * R
    local x, y = cx + math.sin(a) * d, cy - math.cos(a) * d
    c:pix(x, y, col) c:pix(x + 1, y, col)
    if big then c:pix(x, y + 1, col) c:pix(x + 1, y + 1, col) end
  end
  for _, ct in ipairs(view.centres or {}) do
    if ct.dist <= RANGE then dot(ct.brg, ct.dist, T.C.ok, true) end
  end
  for _, t in ipairs(view.traffic or {}) do
    dot(t.brg, t.dist, t.warn and T.C.warn or T.C.text, true)
  end
  if not (view.r and view.r.hdg) then c:text(2, 2, "N", T.C.faint) end
  if view.link ~= "contact" then center(c, floor((topRow + botRow) / 2), "NO TOWER", T.C.warn) end
  advBand(T, c, view)
end

local function statusPage(T, c, view, idx, n)
  local wide = c.w >= 30
  T.band(c, 1, wide and "CINDER NAV" or "CINDER", wide and (view.me.reg or "") or (idx .. "/" .. n),
    T.C.text, T.C.faint)
  local word = ({ air = "AIRCRAFT", land = "LAND VEHICLE", sea = "VESSEL", sub = "SUBMARINE" })[view.me.kind] or ""
  local link = ({ contact = { "TOWER CONTACT", T.C.ok }, none = { "NO TOWER CONTACT", T.C.warn },
                  search = { "CALLING TOWER", T.C.faint } })[view.link or "search"]
  local tr = view.traffic or {}
  local ctr = view.centres and view.centres[1]
  local lines = {
    { view.me.call or "", T.C.text },
    { word, T.C.faint },
    { link[1], link[2] },
    { view.link == "contact" and (#tr == 0 and "NO TRAFFIC NEAR" or ("TRAFFIC " .. #tr)) or "NO TRAFFIC PICTURE",
      #tr > 0 and T.C.text or T.C.faint },
    { ctr and string.format("%s %s %s", ctr.name, distWord(ctr.dist), cardinal(ctr.brg)) or "NO CENTRE KNOWN",
      ctr and T.C.text or T.C.faint },
  }
  if not wide then lines[#lines + 1] = { view.me.reg or "", T.C.faint } end
  if wide and not view.craft then lines[#lines + 1] = { "NOT ON A VEHICLE", T.C.warn } end
  for i, l in ipairs(lines) do
    if 2 + i <= c.h - 2 then center(c, 2 + i, tostring(l[1]):sub(1, c.w), l[2]) end
  end
  advBand(T, c, view)
end

-- -------------------------------------------------------------------- draw --
function M.render(T, c, view, page)
  c:fill(1, 1, c.w, c.h, T.C.ground)
  if view.unregistered then return unregistered(T, c) end
  local list = M.pages(view.me.kind, c.w)
  local idx = 1
  for i, p in ipairs(list) do if p == page then idx = i end end
  page = list[idx]
  if page == "overview" then overview(T, c, view)
  elseif page == "radar" then radarPage(T, c, view, idx, #list)
  elseif page == "status" then statusPage(T, c, view, idx, #list)
  else numberPage(T, c, view, page, idx, #list) end
  return { sos = footer(T, c, view), page = page }
end

--- Was a touch at x, y on the distress key?
function M.onSos(hit, x, y)
  local k = hit and hit.sos
  return k ~= nil and y == k.y and x >= k.x1 and x <= k.x2
end

return M
