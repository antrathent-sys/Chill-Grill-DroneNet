--- kioskui: the CINDER NAV registration kiosk's screen (AVIONICS.md). A
-- player registers their own vehicle and is handed the kit for it (Alex,
-- 2026-10-02): they sit in the kiosk's seat, which names them, choose the
-- vehicle type and a callsign on the touch screen, and the kiosk writes a
-- unit from its stock and puts it, with its monitors and ender modem, in the
-- chest beside them. The same screen takes applications to host a traffic
-- centre. CINDER's look and voice (lib/tui.lua): cold, capitals.
--
--   M.render(T, c, view) -> hits      draw the screen for view.state
--   M.hit(hits, x, y) -> id           which button a touch at x, y was on
--
-- view.state:
--   attract      nobody in the seat
--   hello        someone seated: REGISTER A VEHICLE, APPLY FOR A CENTRE; their
--                own unit in the drive is offered for update. view.drive says
--                what else is in the drive (nil, "dev", "pass", "other",
--                "theirs"); view.stock = kits in stock
--   mine         the drive holds one of their units (view.unit)
--   type         vehicle type
--   callsign     view.call, view.note (why the last one was refused)
--   confirm      view.who, view.kind, view.call, view.reg
--   working      view.frac, view.say
--   done         view.reg, view.call, view.kit (handed a kit) or view.updated
--   appname      a centre's name: view.text, view.note
--   appwhere     its place: view.text "X Z", view.note
--   appconfirm   view.appName, view.x, view.z
--   appdone
--   error        view.msg = { line, ... }
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

local function header(T, c, title, step)
  T.band(c, 1, title or "CINDER NAV  REGISTRATION", step, T.C.text, T.C.faint)
end

local function kindWord(id)
  for _, k in ipairs(M.KINDS) do if k.id == id then return k.word end end
  return ""
end

-- a text field and the on-screen keyboard: keys 3x1 on a 3x2 monitor, 5x3
-- on anything 4x3 or bigger. opts: prompt, text, max, okWord, okLive, note,
-- keys (a filter: only these characters get a key)
local function keyboard(T, c, hits, opts)
  center(c, 3, opts.prompt, T.C.text)
  local text = tostring(opts.text or "")
  local fw = (opts.max or 16) + 4
  local fx = floor((c.w - fw) / 2) + 1
  c:text(fx, 5, string.rep(" ", fw), T.C.text, T.C.panel)
  c:text(fx + 2, 5, text .. (#text < (opts.max or 16) and "_" or ""), T.C.text, T.C.panel)
  if opts.note then center(c, 6, opts.note, T.C.warn) end
  local big = c.w >= 70 and c.h >= 34
  local kw, kh, kgap = big and 5 or 3, big and 3 or 1, 1
  local step = kh + 1
  local ky = big and 8 or 7
  local rowsDrawn = 0
  for _, row in ipairs(M.KEYS) do
    local keys = {}
    for i = 1, #row do
      local ch = row:sub(i, i)
      if not opts.keys or opts.keys:find(ch, 1, true) then keys[#keys + 1] = ch end
    end
    if #keys > 0 then
      local rowW = #keys * (kw + kgap) - kgap
      local x = floor((c.w - rowW) / 2) + 1
      for i, ch in ipairs(keys) do
        button(T, c, hits, "key:" .. ch, x + (i - 1) * (kw + kgap), ky + rowsDrawn * step, kw, kh, ch)
      end
      rowsDrawn = rowsDrawn + 1
    end
  end
  local sy = ky + rowsDrawn * step
  local rowW = 10 * (kw + kgap) - kgap
  local x0 = floor((c.w - rowW) / 2) + 1
  local spaceW = floor(rowW * 0.6)
  button(T, c, hits, "key: ", x0, sy, spaceW, kh, "SPACE")
  button(T, c, hits, "del", x0 + spaceW + 1, sy, rowW - spaceW - 1, kh, "DELETE")
  footButtons(T, c, hits, { { "back", "BACK" }, { "next", opts.okWord or "NEXT", opts.okLive } })
end

-- ------------------------------------------------------------------ screens --
local S = {}

function S.attract(T, c, view, hits)
  local y = max(2, floor(c.h / 2) - 6)
  local after = T.masthead(c, y, "CINDER", T.C.text, "NAV")
  center(c, after + 2, "REGISTER YOUR VEHICLE", T.C.text)
  center(c, after + 3, "AIRCRAFT  LAND VEHICLES  VESSELS  SUBMARINES", T.C.faint)
  center(c, after + 5, "TAKE A SEAT TO BEGIN", T.C.text, T.C.accent)
  center(c, c.h - 1, "REGISTRATION AND KIT ARE FREE", T.C.faint)
end

local DRIVE = {
  dev = "THAT IS ONE OF CINDER'S MACHINES - REMOVE IT",
  pass = "THAT IS A TRANSIT PASS - REMOVE IT",
  other = "TAKE YOUR COMPUTER OUT OF THE DRIVE",
  theirs = "THAT UNIT IS REGISTERED TO ANOTHER PLAYER",
}

function S.hello(T, c, view, hits)
  header(T, c, nil, "")
  center(c, 3, "WELCOME", T.C.faint)
  center(c, 4, tostring(view.who or ""):upper(), T.C.text)
  local bw = min(40, c.w - 6)
  local bx = floor((c.w - bw) / 2) + 1
  local out = view.stock ~= nil and view.stock < 1
  button(T, c, hits, "register", bx, 7, bw, 3, "REGISTER A VEHICLE", not out,
    out and "KITS OUT OF STOCK" or "YOUR KIT IS INCLUDED")
  button(T, c, hits, "apply", bx, 11, bw, 3, "HOST A TRAFFIC CENTRE", false, "APPLY TO CINDER")
  local d = DRIVE[view.drive or ""]
  if d then center(c, 16, d, T.C.warn)
  else center(c, 16, "TO UPDATE A UNIT YOU HAVE, PUT IT IN THE DRIVE", T.C.faint) end
  center(c, c.h - 1, "STAND UP TO LEAVE", T.C.faint)
end

function S.mine(T, c, view, hits)
  header(T, c, nil, "")
  local u = view.unit or {}
  center(c, 4, "THIS UNIT IS YOURS", T.C.faint)
  center(c, 6, tostring(u.reg or ""), T.C.text)
  center(c, 7, tostring(u.call or ""), T.C.text)
  center(c, 8, kindWord(u.kind), T.C.faint)
  center(c, 11, "UPDATE ITS SOFTWARE, OR CHANGE ITS TYPE AND CALLSIGN", T.C.faint)
  footButtons(T, c, hits, { { "cancel", "CANCEL" }, { "change", "CHANGE" }, { "update", "UPDATE", true } })
end

function S.type(T, c, view, hits)
  header(T, c, nil, "1/3")
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
  header(T, c, nil, "2/3")
  keyboard(T, c, hits, { prompt = "CALLSIGN: WHAT TRAFFIC CALLS IT", text = view.call, max = M.CALL_MAX,
    okLive = #tostring(view.call or "") >= 2, note = view.note })
end

function S.confirm(T, c, view, hits)
  header(T, c, nil, "3/3")
  center(c, 3, "CHECK, THEN REGISTER", T.C.text)
  local rows = { { "OWNER", tostring(view.who or ""):upper() }, { "TYPE", kindWord(view.kind) },
                 { "CALLSIGN", tostring(view.call or "") }, { "REGISTRATION", tostring(view.reg or "") } }
  local x = max(2, floor((c.w - 34) / 2))
  for i, r in ipairs(rows) do
    c:text(x, 4 + i * 2, r[1], T.C.faint)
    c:text(x + 14, 4 + i * 2, r[2], T.C.text)
  end
  center(c, 14, view.mode == "change" and "THE SAME UNIT, THE SAME REGISTRATION"
    or "YOUR KIT: THE UNIT, TWO MONITORS, AN ENDER MODEM", T.C.faint)
  center(c, 15, "YOUR UNIT REPORTS ITS POSITION TO CINDER", T.C.faint)
  footButtons(T, c, hits, { { "back", "BACK" }, { "register", view.mode == "change" and "SAVE" or "REGISTER", true } })
end

function S.working(T, c, view, hits)
  header(T, c, nil, "")
  center(c, floor(c.h / 2) - 1, view.say or "PREPARING YOUR KIT", T.C.text)
  local bw = min(40, c.w - 10)
  T.bar(c, floor((c.w - bw) / 2) + 1, floor(c.h / 2) + 1, bw, view.frac or 0, T.C.accent)
end

function S.done(T, c, view, hits)
  header(T, c, nil, "")
  center(c, 3, view.updated and "UPDATED" or "REGISTERED", T.C.ok)
  local reg = tostring(view.reg or "")
  local cells = math.ceil(T.headlinePx(reg, 2) / 2)
  T.headline(c, max(1, floor((c.w - cells) / 2) + 1), 5, reg, T.C.text, 2)
  center(c, 10, tostring(view.call or ""), T.C.text)
  if view.kit then
    center(c, 12, "YOUR KIT IS IN THE CHEST BESIDE YOU", T.C.text)
    center(c, 13, "THE UNIT, TWO ADVANCED MONITORS, AN ENDER MODEM", T.C.faint)
    center(c, 14, "PUT THEM ON YOUR VEHICLE: SCREENS AND MODEM", T.C.faint)
    center(c, 15, "TOUCHING THE UNIT. IT STARTS BY ITSELF", T.C.faint)
  else
    center(c, 12, "TAKE YOUR UNIT FROM THE CHEST BESIDE YOU", T.C.text)
  end
  footButtons(T, c, hits, { { "done", "DONE", true } })
end

function S.appname(T, c, view, hits)
  header(T, c, "CINDER NAV  TRAFFIC CENTRE", "1/3")
  keyboard(T, c, hits, { prompt = "THE CENTRE'S NAME", text = view.text, max = 12,
    okLive = #tostring(view.text or "") >= 2, note = view.note or "SHOWN ON EVERY RADAR", keys = "0123456789QWERTYUIOPASDFGHJKL-ZXCVBNM" })
end

function S.appwhere(T, c, view, hits)
  header(T, c, "CINDER NAV  TRAFFIC CENTRE", "2/3")
  keyboard(T, c, hits, { prompt = "WHERE: X, A SPACE, THEN Z (F3)", text = view.text, max = 15,
    okLive = tostring(view.text or ""):match("^%-?%d+ %-?%d+$") ~= nil, note = view.note, keys = "0123456789-" })
end

function S.appconfirm(T, c, view, hits)
  header(T, c, "CINDER NAV  TRAFFIC CENTRE", "3/3")
  center(c, 3, "APPLY TO HOST A TRAFFIC CENTRE", T.C.text)
  local rows = { { "APPLICANT", tostring(view.who or ""):upper() }, { "CENTRE", tostring(view.appName or "") },
                 { "AT", string.format("%s %s", tostring(view.x), tostring(view.z)) } }
  local x = max(2, floor((c.w - 34) / 2))
  for i, r in ipairs(rows) do
    c:text(x, 4 + i * 2, r[1], T.C.faint)
    c:text(x + 14, 4 + i * 2, r[2], T.C.text)
  end
  center(c, 12, "A CENTRE SHOWS CINDER'S TRAFFIC PICTURE ROUND ITSELF:", T.C.faint)
  center(c, 13, "A COMPUTER, AN ENDER MODEM, A 3X3 MONITOR OR BIGGER", T.C.faint)
  center(c, 14, "CINDER REVIEWS EVERY APPLICATION", T.C.faint)
  footButtons(T, c, hits, { { "back", "BACK" }, { "send", "APPLY", true } })
end

function S.appdone(T, c, view, hits)
  header(T, c, "CINDER NAV  TRAFFIC CENTRE", "")
  center(c, floor(c.h / 2) - 2, "APPLICATION RECEIVED", T.C.ok)
  center(c, floor(c.h / 2), tostring(view.appName or ""), T.C.text)
  center(c, floor(c.h / 2) + 2, "CINDER WILL REVIEW IT", T.C.faint)
  footButtons(T, c, hits, { { "done", "DONE", true } })
end

function S.error(T, c, view, hits)
  header(T, c, nil, "")
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
