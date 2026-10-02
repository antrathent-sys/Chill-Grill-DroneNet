--- kioskui: the CINDER NAV registration kiosk's screen (AVIONICS.md). A
-- player registers their own vehicle (Alex, 2026-10-02): they sit in the
-- kiosk's seat (which names them), put their unit's computer in the drive,
-- and a touch screen takes them through it - vehicle type, callsign, confirm.
-- CINDER's look and voice (lib/tui.lua): cold, capitals, one thing per screen.
--
--   M.render(T, c, view) -> hits      draw the screen for view.state
--   M.hit(hits, x, y) -> id           which button a touch at x, y was on
--   M.KEYS                            the on-screen keyboard's rows
--
-- view.state:
--   attract    nobody in the seat
--   hello      someone seated: put the computer in the drive; view.drive says
--              what is there (nil, "dev", "pass", "other", "theirs")
--   mine       the drive holds a unit registered to the seated player
--              (view.unit = { reg, call, kind })
--   type       vehicle type: AIR, LAND, SEA, SUB
--   callsign   view.call so far, typed on the on-screen keyboard
--   confirm    view.who, view.kind, view.call, view.reg
--   working    view.frac
--   done       view.reg, view.call
--   error      view.msg = { line, ... }
-- Built for a 3x2 advanced monitor (57x24 at text scale 0.5) and anything
-- bigger. Pure; tools/test_nav.lua, tools/preview_nav.py --kiosk.

local M = {}

local floor, max, min = math.floor, math.max, math.min

M.KINDS = {
  { id = "air",  word = "AIRCRAFT",     sees = "ALTIMETER" },
  { id = "land", word = "LAND VEHICLE", sees = "SPEEDOMETER" },
  { id = "sea",  word = "VESSEL",       sees = "COMPASS" },
  { id = "sub",  word = "SUBMARINE",    sees = "DEPTH GAUGE" },
}
M.KEYS = { "1234567890", "QWERTYUIOP", "ASDFGHJKL-", "ZXCVBNM" }
M.CALL_MAX = 16

local function center(c, y, s, ink, bg)
  s = tostring(s):sub(1, c.w)
  c:text(max(1, floor((c.w - #s) / 2) + 1), y, s, ink, bg)
end

-- a button: a filled block with its label in the middle, recorded for touches
local function button(T, c, hits, id, x, y, w, h, label, primary, sub)
  local bg = primary and T.C.accent or T.C.panel
  c:fill(x, y, w, h, bg)
  for yy = y, y + h - 1 do c:text(x, yy, string.rep(" ", w), T.C.text, bg) end
  local ly = y + floor((h - (sub and 2 or 1)) / 2)
  label = tostring(label):sub(1, w - 2)
  c:text(x + floor((w - #label) / 2), ly, label, T.C.text, bg)
  if sub then
    sub = tostring(sub):sub(1, w - 2)
    c:text(x + floor((w - #sub) / 2), ly + 1, sub, primary and T.C.text or T.C.faint, bg)
  end
  hits[#hits + 1] = { id = id, x1 = x, y1 = y, x2 = x + w - 1, y2 = y + h - 1 }
end

-- a row of buttons along the bottom, right-aligned, the primary last
local function footButtons(T, c, hits, list)
  local h = 3
  local y = c.h - h
  local x = c.w - 1
  for i = #list, 1, -1 do
    local b = list[i]
    local w = max(10, #b[2] + 4)
    x = x - w + 1
    button(T, c, hits, b[1], x, y, w, h, b[2], b[3])
    x = x - 2
  end
end

local function header(T, c, step)
  T.band(c, 1, "CINDER NAV  REGISTRATION", step, T.C.text, T.C.faint)
end

local function kindWord(id)
  for _, k in ipairs(M.KINDS) do if k.id == id then return k.word end end
  return ""
end

-- ------------------------------------------------------------------ screens --
local S = {}

function S.attract(T, c, view, hits)
  local y = max(2, floor(c.h / 2) - 6)
  local after = T.masthead(c, y, "CINDER", T.C.text, "NAV")
  center(c, after + 2, "REGISTER YOUR VEHICLE", T.C.text)
  center(c, after + 3, "AIRCRAFT  LAND VEHICLES  VESSELS  SUBMARINES", T.C.faint)
  center(c, after + 5, "TAKE A SEAT TO BEGIN", T.C.text, T.C.accent)
  center(c, c.h - 1, "REGISTRATION IS FREE", T.C.faint)
end

local DRIVE = {
  dev = { "THAT IS ONE OF CINDER'S MACHINES", "REMOVE IT" },
  pass = { "THAT IS A TRANSIT PASS", "IT CANNOT BE A NAV UNIT" },
  other = { "THAT COMPUTER HAS FILES ON IT", "USE THE ONE FROM YOUR CINDER NAV KIT" },
  theirs = { "THAT UNIT IS REGISTERED TO ANOTHER PLAYER", "ONLY ITS OWNER CAN CHANGE IT" },
}

function S.hello(T, c, view, hits)
  header(T, c, "1/4")
  center(c, 4, "WELCOME", T.C.faint)
  center(c, 5, tostring(view.who or ""):upper(), T.C.text)
  center(c, 8, "PLACE YOUR UNIT'S COMPUTER IN THE DRIVE", T.C.text)
  center(c, 9, "THE ADVANCED COMPUTER FROM YOUR CINDER NAV KIT", T.C.faint)
  local d = DRIVE[view.drive or ""]
  if d then
    center(c, 12, d[1], T.C.warn)
    center(c, 13, d[2], T.C.faint)
  else
    center(c, 12, "WAITING FOR A COMPUTER " .. T.spin(view.n), T.C.faint)
  end
  footButtons(T, c, hits, { { "cancel", "CANCEL" } })
end

function S.mine(T, c, view, hits)
  header(T, c, "1/4")
  local u = view.unit or {}
  center(c, 4, "THIS UNIT IS YOURS", T.C.faint)
  center(c, 6, tostring(u.reg or ""), T.C.text)
  center(c, 7, tostring(u.call or ""), T.C.text)
  center(c, 8, kindWord(u.kind), T.C.faint)
  center(c, 11, "UPDATE ITS SOFTWARE, OR CHANGE ITS TYPE AND CALLSIGN", T.C.faint)
  footButtons(T, c, hits, { { "cancel", "CANCEL" }, { "change", "CHANGE" }, { "update", "UPDATE", true } })
end

function S.type(T, c, view, hits)
  header(T, c, "2/4")
  center(c, 3, "WHAT IS IT FITTED TO?", T.C.text)
  local gap = 2
  local bw = floor((c.w - 2 - gap) / 2)
  local bh = max(3, min(5, floor((c.h - 9) / 2)))
  for i, k in ipairs(M.KINDS) do
    local col, row = (i - 1) % 2, floor((i - 1) / 2)
    button(T, c, hits, "kind:" .. k.id, 2 + col * (bw + gap), 5 + row * (bh + 1), bw, bh, k.word,
      view.kind == k.id, k.sees)
  end
  footButtons(T, c, hits, { { "back", "BACK" } })
end

function S.callsign(T, c, view, hits)
  header(T, c, "3/4")
  center(c, 3, "CALLSIGN: WHAT TRAFFIC CALLS IT", T.C.text)
  local call = tostring(view.call or "")
  local fw = M.CALL_MAX + 4
  local fx = floor((c.w - fw) / 2) + 1
  c:text(fx, 5, string.rep(" ", fw), T.C.text, T.C.panel)
  c:text(fx + 2, 5, call .. (#call < M.CALL_MAX and "_" or ""), T.C.text, T.C.panel)
  -- the keyboard, centred: keys 3x1 on a 3x2 monitor, 5x3 on anything 4x3 or bigger
  local big = c.w >= 70 and c.h >= 34
  local kw, kh, kgap = big and 5 or 3, big and 3 or 1, 1
  local step = kh + 1
  local ky = 7
  for r, row in ipairs(M.KEYS) do
    local rowW = #row * (kw + kgap) - kgap
    local x = floor((c.w - rowW) / 2) + 1
    for i = 1, #row do
      local ch = row:sub(i, i)
      button(T, c, hits, "key:" .. ch, x + (i - 1) * (kw + kgap), ky + (r - 1) * step, kw, kh, ch)
    end
  end
  -- space and delete under the last row
  local sy = ky + #M.KEYS * step
  local rowW = 10 * (kw + kgap) - kgap
  local x0 = floor((c.w - rowW) / 2) + 1
  local spaceW = floor(rowW * 0.6)
  button(T, c, hits, "key: ", x0, sy, spaceW, kh, "SPACE")
  button(T, c, hits, "del", x0 + spaceW + 1, sy, rowW - spaceW - 1, kh, "DELETE")
  footButtons(T, c, hits, { { "back", "BACK" }, { "next", "NEXT", #call >= 2 } })
end

function S.confirm(T, c, view, hits)
  header(T, c, "4/4")
  center(c, 3, "CHECK, THEN REGISTER", T.C.text)
  local rows = { { "OWNER", tostring(view.who or ""):upper() }, { "TYPE", kindWord(view.kind) },
                 { "CALLSIGN", tostring(view.call or "") }, { "REGISTRATION", tostring(view.reg or "") } }
  local lw = 14
  local x = max(2, floor((c.w - 34) / 2))
  for i, r in ipairs(rows) do
    c:text(x, 4 + i * 2, r[1], T.C.faint)
    c:text(x + lw, 4 + i * 2, r[2], T.C.text)
  end
  center(c, 15, "YOUR UNIT REPORTS ITS POSITION TO CINDER", T.C.faint)
  footButtons(T, c, hits, { { "back", "BACK" }, { "register", "REGISTER", true } })
end

function S.working(T, c, view, hits)
  header(T, c, "")
  center(c, floor(c.h / 2) - 1, "WRITING YOUR UNIT", T.C.text)
  local bw = min(40, c.w - 10)
  T.bar(c, floor((c.w - bw) / 2) + 1, floor(c.h / 2) + 1, bw, view.frac or 0, T.C.accent)
  center(c, floor(c.h / 2) + 3, "DO NOT REMOVE IT", T.C.faint)
end

function S.done(T, c, view, hits)
  header(T, c, "")
  center(c, 4, "REGISTERED", T.C.ok)
  local reg = tostring(view.reg or "")
  local cells = math.ceil(T.headlinePx(reg, 2) / 2)
  T.headline(c, max(1, floor((c.w - cells) / 2) + 1), 6, reg, T.C.text, 2)
  center(c, 11, tostring(view.call or ""), T.C.text)
  center(c, 13, "TAKE YOUR UNIT FROM THE DRIVE", T.C.text)
  center(c, 14, "FIT IT WITH AN ADVANCED MONITOR AND AN ENDER MODEM", T.C.faint)
  center(c, 15, "IT STARTS BY ITSELF", T.C.faint)
  footButtons(T, c, hits, { { "done", "DONE", true } })
end

function S.error(T, c, view, hits)
  header(T, c, "")
  local lines = view.msg or { "SOMETHING WENT WRONG" }
  local y = max(4, floor(c.h / 2) - #lines)
  for i, l in ipairs(lines) do center(c, y + i - 1, tostring(l):upper(), i == 1 and T.C.warn or T.C.faint) end
  footButtons(T, c, hits, { { "done", "OK", true } })
end

-- -------------------------------------------------------------------- draw --
function M.render(T, c, view)
  c:fill(1, 1, c.w, c.h, T.C.ground)
  local hits = {}
  local draw = S[view.state or "attract"] or S.attract
  draw(T, c, view, hits)
  return hits
end

function M.hit(hits, x, y)
  for _, h in ipairs(hits or {}) do
    if x >= h.x1 and x <= h.x2 and y >= h.y1 and y <= h.y2 then return h.id end
  end
  return nil
end

return M
