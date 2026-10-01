--- navui: the one screen of a CINDER NAV unit (AVIONICS.md). A consumer
-- product in CINDER's house style (lib/tui.lua): what the driver needs at a
-- glance, big; everything else quiet.
--
--   M.render(T, c, view) -> hit       draw on a lib/display.lua canvas
--
-- view: { me = { reg, call, kind }, r = reading (lib/nav.lua N.reading),
--         link = "contact" | "none" | "search", traffic = { ... }, adv,
--         sos = nil | "armed" | "sent" | "heard", craft = true|false,
--         unregistered = true, msg }
-- hit: { sos = { x1, x2, y } } - where a touch means the distress key.
--
-- Fits whatever monitor it is given, at text scale 0.5: one block (15x10),
-- a strip (36x10, 57x10) or a panel (36x24 and up). What is big depends on
-- the vehicle: speed always; height for aircraft, depth for submarines,
-- heading for land vehicles and boats. Pure; tools/test_nav.lua.

local M = {}

local floor, abs = math.floor, math.abs

-- the two big numbers and the small line, per vehicle type
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
  if key == "depth" then return r.depth and tostring(math.max(0, floor(r.depth + 0.5))) or "--" end
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

local LABEL = { hdg = "HDG", vs = "V/S", alt = "ALT", pos = "POS", depth = "DEPTH", spd = "SPD" }

local function center(c, y, s, ink, bg)
  c:text(math.max(1, floor((c.w - #s) / 2) + 1), y, s, ink, bg)
end

-- the bottom band: tower link at the left, the distress key at the right
local function footer(T, c, y, view)
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
  if x1 <= #link[1] + 2 then          -- no room beside the link: the key wins
    c:text(1, y, string.rep(" ", c.w), T.C.faint, T.C.panel)
    x1 = c.w - #label
  end
  local ink, paper = T.C.text, view.sos and T.C.accent or T.C.rule
  c:text(x1, y, label, ink, paper)
  return { x1 = x1, x2 = c.w, y = y }
end

local function bigNumber(T, c, x, y, w, text, label, scale)
  local cells = math.ceil(T.headlinePx(text, scale) / 2)
  local bx = x + math.max(0, floor((w - cells) / 2))
  T.headline(c, bx, y, text, T.C.text, scale)
  local ly = y + (scale == 2 and 4 or 2)
  c:text(x + math.max(0, floor((w - #label) / 2)), ly, label, T.C.faint)
end

local function smallLine(T, c, y, view)
  local parts = {}
  for _, k in ipairs(M.SMALL[view.me.kind] or M.SMALL.air) do
    parts[#parts + 1] = LABEL[k] .. " " .. M.value(view.r, k)
  end
  if not view.craft then parts[#parts + 1] = "NO CRAFT" end
  center(c, y, table.concat(parts, "   "), T.C.text)
end

-- what the line above the footer says: an advisory beats everything. With
-- the traffic listed above it (a panel), only an advisory or a message.
local function noticeLine(T, c, y, view, listed)
  if view.adv then
    c:text(1, y, string.rep(" ", c.w), T.C.text, T.C.accent)
    center(c, y, view.adv:sub(1, c.w), T.C.text, T.C.accent)
    return
  end
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

local function header(T, c, view)
  -- one block has room for the name or the registration, and the name wins
  local right = c.w >= 30 and (view.me.reg or "") or nil
  local left = c.w >= 30 and "CINDER NAV" or "CINDER"
  T.band(c, 1, left, right, T.C.text, T.C.faint)
end

local function unregistered(T, c)
  T.band(c, 1, "CINDER NAV")
  center(c, floor(c.h / 2) - 1, "UNREGISTERED", T.C.warn)
  center(c, floor(c.h / 2) + 1, c.w >= 30 and "TAKE THIS UNIT TO CINDER" or "SEE CINDER", T.C.faint)
  return {}
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
  for i = 1, math.min(rows, #tr) do
    local t = tr[i]
    local rel = floor(((t.brg - hdg) % 360 + 360) % 360 / 30 + 0.5) % 12
    local dy = t.dy >= 0 and ("+" .. floor(t.dy + 0.5)) or tostring(floor(t.dy + 0.5))
    local left = string.format("%-10s %2d O'CLK", t.call:sub(1, 10), rel == 0 and 12 or rel)
    local right = string.format("%5s %5s", distWord(t.dist), dy)
    local ink = t.warn and T.C.warn or T.C.text
    c:text(2, y0 + i, left, ink)
    c:text(c.w - #right, y0 + i, right, t.warn and T.C.warn or T.C.faint)
  end
end

function M.render(T, c, view)
  c:fill(1, 1, c.w, c.h, T.C.ground)
  if view.unregistered then return unregistered(T, c) end
  local big = M.BIG[view.me.kind] or M.BIG.air
  local hit = {}
  if c.w < 30 then
    -- one block: text only, the four things that matter
    header(T, c, view)
    local rows = { { big[1][2]:match("^%S+"), M.value(view.r, big[1][1]) },
                   { big[2][2], M.value(view.r, big[2][1]) } }
    for _, k in ipairs(M.SMALL[view.me.kind] or {}) do rows[#rows + 1] = { LABEL[k], M.value(view.r, k) } end
    for i = 1, math.min(#rows, c.h - 4) do
      c:text(2, 2 + i, rows[i][1], T.C.faint)
      c:text(c.w - #rows[i][2], 2 + i, rows[i][2], T.C.text)
    end
    noticeLine(T, c, c.h - 1, view)
    hit.sos = footer(T, c, c.h, view)
    return hit
  end
  header(T, c, view)
  local half = floor(c.w / 2)
  local scale = 2
  bigNumber(T, c, 1, 3, half, M.value(view.r, big[1][1]), big[1][2], scale)
  bigNumber(T, c, half + 1, 3, c.w - half, M.value(view.r, big[2][1]), big[2][2], scale)
  if c.h < 20 then
    smallLine(T, c, 8, view)
    noticeLine(T, c, c.h - 1, view)
    hit.sos = footer(T, c, c.h, view)
    return hit
  end
  -- a panel: the same at the top, then the traffic
  smallLine(T, c, 8, view)
  local listTop = 10
  local rows = c.h - listTop - 3
  trafficList(T, c, listTop, rows, view)
  noticeLine(T, c, c.h - 1, view, true)
  hit.sos = footer(T, c, c.h, view)
  return hit
end

--- Was a touch at x, y on the distress key?
function M.onSos(hit, x, y)
  local k = hit and hit.sos
  return k ~= nil and y == k.y and x >= k.x1 and x <= k.x2
end

return M
