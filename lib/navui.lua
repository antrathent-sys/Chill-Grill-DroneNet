--- navui: the screens of a CINDER NAV unit (AVIONICS.md). A consumer
-- product in CINDER's house style (lib/tui.lua): what the driver needs at a
-- glance, big; everything else quiet.
--
--   M.render(T, c, view, page) -> hit    draw one page on a lib/display.lua canvas
--   M.pages(kind, w)                     the pages a screen of that width cycles through
--   M.onSos(hit, x, y)                   was a touch on the distress key?
--   M.boot(T, c, view)                   the boot screen startup.lua draws (view.frac, view.ver)
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
local tag          -- a page's place in the cycle, or TOUCH (defined with the notices below)

-- The boot screen, on the computer's own screen while startup pulls the
-- update behind it: the masthead, a filling line, the build in the corner.
function M.boot(T, c, view)
  local w, h = c.w, c.h
  c:clear()
  local after = T.masthead(c, math.max(1, math.floor(h / 2) - 3), "CINDER", T.C.text, "NAV")
  local bw = math.max(6, w - 10)
  local x = math.floor((w - bw) / 2) + 1
  local py = after * 3 + 2
  local px0, px1 = (x - 1) * 2 + 1, (x - 1 + bw) * 2
  c:line(px0, py, px1, py, T.C.rule)
  local fill = math.floor((px1 - px0 + 1) * math.max(0, math.min(1, view.frac or 0)))
  if fill > 0 then c:line(px0, py, px0 + fill - 1, py, T.C.accent) end
  if view.ver then c:text(2, h, "REV " .. tostring(view.ver):upper():sub(1, 7), T.C.rule) end
end

local floor, abs, max, min = math.floor, math.abs, math.max, math.min
local RANGE = 1000            -- the radar's ring, as far as a pong's traffic reaches

-- Each kind's own gauge in place of the plain figures (2026-10-02): an
-- aircraft's altimeter, a land vehicle's speedometer, a vessel's compass, a
-- submarine's depth gauge.
M.PAGES = {
  air  = { "speed", "altimeter", "heading", "radar", "status" },
  land = { "speedo", "heading", "height", "radar", "status" },
  sea  = { "speed", "compass", "radar", "status" },
  sub  = { "speed", "depth", "heading", "radar", "status" },
}

-- And every kind its pitch and roll (2026-10-03): the same horizon, called
-- what that kind calls it (M.ATT), after the page named here. Built, and
-- SWITCHED OFF for now (Alex, 2026-10-03: "a bit more to teach"); the unit
-- still learns its nose quietly, so turning it on is this one flag.
M.SHOW_ATTITUDE = false
M.ATT_AFTER = { air = "speed", land = "speedo", sea = "speed", sub = "depth" }

--- The pages a screen cycles through: a wide one starts on the overview.
function M.pages(kind, w)
  local list = {}
  if (w or 0) >= 30 then list[1] = "overview" end
  for _, p in ipairs(M.PAGES[kind] or M.PAGES.air) do
    list[#list + 1] = p
    if M.SHOW_ATTITUDE and p == (M.ATT_AFTER[kind] or "speed") then list[#list + 1] = "attitude" end
  end
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

-- The page's place in the cycle, "2/5" - or TOUCH until this screen has been
-- touched once, which is how an owner learns the screens change (Alex,
-- 2026-10-02: "they should teach how to use themselves")
local HINT = false
tag = function(idx, n, c) return HINT and ((c and c.w < 20) and "TAP" or "TOUCH") or (idx .. "/" .. n) end

-- What stops the unit working, each with what to do about it, most basic
-- first: { { title, fix }, ... }. Empty when it is fitted right.
function M.problems(view)
  local out = {}
  if view.noRadio then out[#out + 1] = { "NO ENDER MODEM", "PUT ONE ON THE COMPUTER" } end
  if view.craft == false then out[#out + 1] = { "NOT ON A VEHICLE", "PLACE THE COMPUTER ON YOUR CRAFT" } end
  if view.noTouch then out[#out + 1] = { "NO TOUCH SCREEN", "SOS NEEDS AN ADVANCED MONITOR" } end
  return out
end

-- words to lines no wider than w
local function wrap(s, w)
  local lines, line = {}, ""
  for word in tostring(s):gmatch("%S+") do
    if line == "" then line = word
    elseif #line + 1 + #word <= w then line = line .. " " .. word
    else lines[#lines + 1] = line line = word end
  end
  if line ~= "" then lines[#lines + 1] = line end
  return lines
end

-- the setup page: every problem and its fix, until there are none
local function setupPage(T, c, view, probs)
  local more = #probs > 1 and (c.w >= 30 and (#probs .. " TO DO") or ("+" .. (#probs - 1))) or nil
  T.band(c, 1, c.w >= 30 and "CINDER NAV  SET UP" or "SET UP", more, T.C.text, T.C.warn)
  local y = 3
  for _, p in ipairs(probs) do
    for _, l in ipairs(wrap(p[1], c.w - 2)) do
      if y <= c.h - 1 then center(c, y, l, T.C.warn) end
      y = y + 1
    end
    for _, l in ipairs(wrap(p[2], c.w - 2)) do
      if y <= c.h - 1 then center(c, y, l, T.C.faint) end
      y = y + 1
    end
    y = y + 1
  end
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
  T.band(c, 1, titleOf(page, view.me.kind), tag(idx, n, c), T.C.text, T.C.faint)
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
  T.band(c, 1, "RADAR", (c.w >= 20 and (tag(idx, n, c) .. "  ") or "") .. "1K", T.C.text, T.C.faint)
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

-- ------------------------------------------------------------------ gauges --
-- A round gauge in pixels: a ring of ticks, needles from the middle, the
-- reading in figures low in the dial. One for each kind of vehicle (Alex,
-- 2026-10-02: "a proper altimeter if it's a plane"): an aircraft's altimeter,
-- a land vehicle's speedometer, a vessel's compass, a submarine's depth gauge.
local function dialGeom(c)
  local topRow, botRow = 2, c.h - 2
  local py0, py1 = (topRow - 1) * 3 + 1, botRow * 3
  local cx, cy = c.w + 0.5, (py0 + py1) / 2
  return cx, cy, min(c.w - 1.5, (py1 - py0) / 2 - 0.5)
end
local function polar(cx, cy, r, deg)
  local a = math.rad(deg)
  return cx + math.sin(a) * r, cy - math.cos(a) * r
end
local function tick(c, cx, cy, R, deg, len, col)
  local x0, y0 = polar(cx, cy, R - len, deg)
  local x1, y1 = polar(cx, cy, R, deg)
  c:line(x0, y0, x1, y1, col)
end
local function needle(c, cx, cy, len, deg, col)
  local x, y = polar(cx, cy, len, deg)
  c:line(cx, cy, x, y, col)
end
-- the figures, in a window in the lower half of the dial
local function window(c, cy, R, s, ink)
  local row = floor((cy + R * 0.55 - 1) / 3) + 1
  center(c, row, s, ink)
end
-- the line under the dial, when there is no advisory to show there
local function underDial(T, c, view, s)
  if not view.adv and s then center(c, c.h - 1, s:sub(1, c.w), T.C.faint) end
end

-- Altimeter: as in an aircraft, the long needle goes round once per 100
-- blocks and the short one once per 1,000, with Y in figures.
local function altimeterPage(T, c, view, idx, n)
  T.band(c, 1, "ALTIMETER", tag(idx, n, c), T.C.text, T.C.faint)
  local cx, cy, R = dialGeom(c)
  c:circle(cx, cy, R, T.C.rule)
  for i = 0, 9 do tick(c, cx, cy, R, i * 36, i == 0 and 3 or 2, i == 0 and T.C.text or T.C.faint) end
  if R >= 14 then for i = 0, 49 do if i % 5 ~= 0 then tick(c, cx, cy, R, i * 7.2, 1, T.C.rule) end end end
  local y = view.r and view.r.y
  if y then
    needle(c, cx, cy, R * 0.5, (y % 1000) / 1000 * 360, T.C.accent)
    needle(c, cx, cy, R - 2, (y % 100) / 100 * 360, T.C.text)
  end
  window(c, cy, R, M.value(view.r, "alt"), T.C.text)
  underDial(T, c, view, view.craft and ("V/S " .. M.value(view.r, "vs")) or "NO CRAFT")
  advBand(T, c, view)
end

-- Depth gauge: once round per 100 blocks below sea level, depth in figures.
local function depthPage(T, c, view, idx, n)
  T.band(c, 1, "DEPTH", tag(idx, n, c), T.C.text, T.C.faint)
  local cx, cy, R = dialGeom(c)
  c:circle(cx, cy, R, T.C.rule)
  for i = 0, 9 do tick(c, cx, cy, R, i * 36, i == 0 and 3 or 2, i == 0 and T.C.text or T.C.faint) end
  local d = view.r and view.r.depth
  if d then needle(c, cx, cy, R - 2, (max(0, d) % 100) / 100 * 360, d > 0 and T.C.text or T.C.faint) end
  window(c, cy, R, (d and d <= 0) and "SURF" or M.value(view.r, "depth"), T.C.text)
  underDial(T, c, view, view.craft and ("V/S " .. M.value(view.r, "vs")) or "NO CRAFT")
  advBand(T, c, view)
end

-- Speedometer: a 270-degree sweep to a full scale that grows with the
-- speed, 20 / 40 / 80 / 160 / 320 blocks a second.
local function speedoPage(T, c, view, idx, n)
  local spd = view.r and view.r.spd or 0
  local full = 20
  while full < spd and full < 320 do full = full * 2 end
  T.band(c, 1, "SPEED", (c.w >= 20 and (tag(idx, n, c) .. "  ") or "") .. "/" .. full, T.C.text, T.C.faint)
  local cx, cy, R = dialGeom(c)
  for i = 0, 8 do
    local deg = -135 + i * 270 / 8
    tick(c, cx, cy, R, deg, (i % 4 == 0) and 3 or 2, (i % 4 == 0) and T.C.text or T.C.faint)
  end
  for i = 0, 54 do local x, y = polar(cx, cy, R, -135 + i * 5) c:pix(x, y, T.C.rule) end
  needle(c, cx, cy, R - 2, -135 + min(spd, full) / full * 270, T.C.accent)
  window(c, cy, R, M.value(view.r, "spd"), T.C.text)
  underDial(T, c, view, view.craft and ("HDG " .. M.value(view.r, "hdg")) or "NO CRAFT")
  advBand(T, c, view)
end

-- Compass: north up, the needle on the heading, N E S W round the ring.
local function compassPage(T, c, view, idx, n)
  T.band(c, 1, "COMPASS", tag(idx, n, c), T.C.text, T.C.faint)
  local cx, cy, R = dialGeom(c)
  c:circle(cx, cy, R, T.C.rule)
  for i = 0, 7 do tick(c, cx, cy, R, i * 45, (i % 2 == 0) and 2 or 1, T.C.faint) end
  for i, l in ipairs({ "N", "E", "S", "W" }) do
    local x, y = polar(cx, cy, R - 3.5, (i - 1) * 90)
    c:text(floor((x - 1) / 2) + 1, floor((y - 1) / 3) + 1, l, l == "N" and T.C.text or T.C.faint)
  end
  local h = view.r and view.r.hdg
  if h then needle(c, cx, cy, R - 2, h, T.C.accent) end
  window(c, cy, R, M.value(view.r, "hdg"), T.C.text)
  local cp = h and cardinal(h)
  underDial(T, c, view, cp and CARD_WORD[cp] or "NOT MOVING")
  advBand(T, c, view)
end

-- Attitude: an artificial horizon. The craft is the fixed mark in the
-- middle; the sky (grey) and the ground (black) tilt with the roll and slide
-- with the pitch, a line every 10 degrees, the bank scale round the top with
-- a pointer that leans with the horizon, and the figures under it. Past the
-- kind's limits the figures turn rust and say why.
M.ATT = {
  air  = { title = "ATTITUDE", roll = 60, pitch = 30, warn = "BANK ANGLE" },
  land = { title = "INCLINE",  roll = 30, pitch = 30, warn = "TIP RISK" },
  sea  = { title = "HEEL TRIM", roll = 15, pitch = 15, warn = "LIST" },
  sub  = { title = "ANGLE",    roll = 20, pitch = 30, warn = "STEEP" },
}
M.ATT_SPAN = 25            -- degrees of pitch from the middle to the top edge

local function signed(v) return (v >= 0 and "+" or "-") .. tostring(floor(abs(v) + 0.5)) end
local function rollWord(v)
  local d = floor(abs(v) + 0.5)
  return d == 0 and "0" or (tostring(d) .. (v > 0 and "R" or "L"))
end

--- The figures under the horizon, and whether they are past the limits.
function M.attWords(kind, pitch, roll, w)
  local a = M.ATT[kind] or M.ATT.air
  local over = abs(roll) >= a.roll or abs(pitch) >= a.pitch
  local s = w >= 30 and string.format("PITCH %s  ROLL %s", signed(pitch), rollWord(roll))
    or string.format("P%s R%s", signed(pitch), rollWord(roll))
  if over and #s + #a.warn + 2 <= w - 2 then s = a.warn .. "  " .. s end
  return s, over
end

local function attitudePage(T, c, view, idx, n)
  local kind = view.me.kind
  local a = M.ATT[kind] or M.ATT.air
  T.band(c, 1, a.title, tag(idx, n, c), T.C.text, T.C.faint)
  local top, bot = 2, c.h - 2
  local r = view.r or {}
  local pitch, roll = r.pitch, r.roll
  if view.att ~= "ok" or not (pitch and roll) then
    local mid = floor((top + bot) / 2)
    if view.att == "learning" then
      center(c, mid - 1, c.w >= 30 and "LEARNING WHICH WAY IS FORWARD" or "LEARNING", T.C.text)
      center(c, mid + 1, c.w >= 30 and "MOVE AHEAD FOR A FEW SECONDS" or "MOVE AHEAD", T.C.faint)
    else
      center(c, mid, view.craft and "NO ATTITUDE" or "NO CRAFT", T.C.faint)
    end
    advBand(T, c, view)
    return
  end
  local py0, py1 = (top - 1) * 3 + 1, bot * 3
  local cx, cy = c.w + 0.5, (py0 + py1) / 2
  local K = (py1 - py0) / 2 / M.ATT_SPAN
  local sr, cr = math.sin(math.rad(roll)), math.cos(math.rad(roll))
  local off = K * pitch
  -- ground where a pixel lies beyond the horizon: a whole cell takes its
  -- colour as background, a cell the horizon crosses gets ground pixels
  local skyCell = {}
  for y = top, bot do
    for x = 1, c.w do
      local g, k = 0, {}
      for sy = 0, 2 do
        for sx = 1, 2 do
          local px, py = (x - 1) * 2 + sx, (y - 1) * 3 + sy + 1
          local ground = (px - cx) * sr + (py - cy) * cr - off > 0
          k[#k + 1] = ground and { px, py } or false
          if ground then g = g + 1 end
        end
      end
      if g == 6 then c:fill(x, y, 1, 1, T.C.ground)
      else
        c:fill(x, y, 1, 1, T.C.panel)
        for _, p in ipairs(k) do if p then c:pix(p[1], p[2], T.C.ground) end end
      end
      skyCell[y * 1000 + x] = g < 3
    end
  end
  c.clip = { 1, py0, c.w * 2, py1 }
  -- the pitch ladder, every 10 degrees
  -- (a single block has room for the 10s only, and no bank scale)
  local halfH = (py1 - py0) / 2
  for _, deg in ipairs(halfH >= 20 and { -20, -10, 10, 20 } or { -10, 10 }) do
    local d = K * (pitch - deg)
    local L = c.w * (abs(deg) == 10 and 0.3 or 0.45)
    local mx, my = cx + d * sr, cy + d * cr
    c:line(mx - L * cr, my + L * sr, mx + L * cr, my - L * sr, T.C.faint)
  end
  -- the bank scale, fixed, and the pointer that leans with the horizon
  local Rb = min(c.w - 2, (py1 - py0) / 2 - 1)
  if Rb >= 14 then
    for _, deg in ipairs({ -60, -45, -30, -20, -10, 0, 10, 20, 30, 45, 60 }) do
      local s, co = math.sin(math.rad(deg)), math.cos(math.rad(deg))
      c:pix(cx + Rb * s, cy - Rb * co, deg == 0 and T.C.text or T.C.rule)
    end
    local s, co = math.sin(math.rad(-roll)), math.cos(math.rad(-roll))
    for d = 2, 3 do c:pix(cx + (Rb - d) * s, cy - (Rb - d) * co, T.C.text) end
  end
  c.clip = nil
  -- the craft: fixed, wings level, a mark in the middle
  local midY = floor((cy - 1) / 3) + 1
  local midX = floor(c.w / 2) + 1
  local wing, gap = max(2, floor(c.w / 7)), max(1, floor(c.w / 12))
  local function mark(x, ch)
    if x >= 1 and x <= c.w then
      c:text(x, midY, ch, T.C.text, skyCell[midY * 1000 + x] and T.C.panel or T.C.ground)
    end
  end
  for i = 1, wing do mark(midX - gap - i, "-") mark(midX + gap + i, "-") end
  mark(midX, "+")
  local words, over = M.attWords(kind, pitch, roll, c.w)
  if not view.adv then center(c, c.h - 1, words:sub(1, c.w), over and T.C.warn or T.C.text) end
  advBand(T, c, view)
end

local function statusPage(T, c, view, idx, n)
  local wide = c.w >= 30
  T.band(c, 1, wide and "CINDER NAV" or "CINDER", wide and (view.me.reg or "") or (tag(idx, n, c)),
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
-- opts.hint: this screen has not been touched yet (TOUCH in the header)
function M.render(T, c, view, page, opts)
  c:fill(1, 1, c.w, c.h, T.C.ground)
  if view.unregistered then return unregistered(T, c) end
  local probs = M.problems(view)
  if #probs > 0 then
    setupPage(T, c, view, probs)
    return { sos = footer(T, c, view), page = page }
  end
  HINT = opts and opts.hint or false
  local list = M.pages(view.me.kind, c.w)
  local idx = 1
  for i, p in ipairs(list) do if p == page then idx = i end end
  page = list[idx]
  if page == "overview" then overview(T, c, view)
  elseif page == "radar" then radarPage(T, c, view, idx, #list)
  elseif page == "status" then statusPage(T, c, view, idx, #list)
  elseif page == "altimeter" then altimeterPage(T, c, view, idx, #list)
  elseif page == "depth" then depthPage(T, c, view, idx, #list)
  elseif page == "speedo" then speedoPage(T, c, view, idx, #list)
  elseif page == "compass" then compassPage(T, c, view, idx, #list)
  elseif page == "attitude" then attitudePage(T, c, view, idx, #list)
  else numberPage(T, c, view, page, idx, #list) end
  return { sos = footer(T, c, view), page = page }
end

--- Was a touch at x, y on the distress key?
function M.onSos(hit, x, y)
  local k = hit and hit.sos
  return k ~= nil and y == k.y and x >= k.x1 and x <= k.x2
end

return M
