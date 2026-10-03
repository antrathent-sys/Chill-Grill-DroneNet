--- kioskui: the CINDER NAV registration kiosk's screen (AVIONICS.md). A
-- player registers their own vehicle and is handed the kit for it (Alex,
-- 2026-10-02): they sit in the kiosk's seat, which names them, choose the
-- vehicle type and a callsign on the touch screen, and the kiosk writes a
-- unit from its stock and puts it, with its monitors and ender modem, in the
-- chest beside them. The same screen takes applications to host a traffic
-- centre. CINDER's look and voice (lib/tui.lua): cold, capitals - a form
-- at a government counter (Alex, 2026-10-03: "lean into the cold corp thing
-- and ominous feeling"). The player is the SUBJECT, every screen says the
-- entries are recorded, and nothing is warm: no welcome, no green. Cold but
-- never false - it says plainly that the unit reports where it is.
--
--   M.render(T, c, view) -> hits      draw the screen for view.state
--   M.hit(hits, x, y) -> id           which button a touch at x, y was on
--
-- view.state:
--   attract      nobody in the seat
--   hello        someone seated: REGISTER A CRAFT, APPLY: TRAFFIC CENTRE; their
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

local DIRECTORATE = "CINDER  TRAFFIC DIRECTORATE"
M.FORM_REG, M.FORM_APP = "FORM TD-1", "FORM TD-7"

-- the band along the top: who is asking, the form, the step
local function header(T, c, form, step)
  local right = (form or M.FORM_REG) .. ((step and step ~= "") and ("  STEP " .. step) or "")
  T.band(c, 1, DIRECTORATE, right, T.C.text, T.C.faint)
end

-- bottom left, on every screen with someone in the seat: who this is about,
-- and that it is kept
local function record(T, c, view)
  if view.who then c:text(2, c.h - 2, "SUBJECT  " .. tostring(view.who):upper(), T.C.faint) end
  c:text(2, c.h - 1, "ENTRIES ARE RECORDED", T.C.rule)
end

local function kindWord(id)
  for _, k in ipairs(M.KINDS) do if k.id == id then return k.word end end
  return ""
end

-- label and value, the label in grey: a filled-in form
local function fields(T, c, y, rows)
  local x = max(2, floor((c.w - 36) / 2))
  for i, r in ipairs(rows) do
    c:text(x, y + (i - 1) * 2, r[1], T.C.faint)
    c:text(x + 15, y + (i - 1) * 2, r[2], T.C.text)
  end
end

-- a text field and the on-screen keyboard: keys 3x1 on a 3x2 monitor, 5x3
-- on anything 4x3 or bigger. opts: prompt, text, max, okWord, okLive, note
-- (why the last entry was refused), hint (shown when there is no note),
-- keys (a filter: only these characters get a key)
local function keyboard(T, c, hits, view, opts)
  center(c, 3, opts.prompt, T.C.text)
  local text = tostring(opts.text or "")
  local fw = (opts.max or 16) + 4
  local fx = floor((c.w - fw) / 2) + 1
  c:text(fx, 5, string.rep(" ", fw), T.C.text, T.C.panel)
  c:text(fx + 2, 5, text .. (#text < (opts.max or 16) and "_" or ""), T.C.text, T.C.panel)
  if opts.note then center(c, 6, opts.note, T.C.warn)
  elseif opts.hint then center(c, 6, opts.hint, T.C.faint) end
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
  record(T, c, view)
  footButtons(T, c, hits, { { "back", "BACK" }, { "next", opts.okWord or "NEXT", opts.okLive } })
end

-- ------------------------------------------------------------------ screens --
local S = {}

function S.attract(T, c, view, hits)
  local y = max(2, floor(c.h / 2) - 7)
  local after = T.masthead(c, y, "CINDER", T.C.text, "TRAFFIC DIRECTORATE")
  center(c, after + 2, "ALL CRAFT ARE TO BE REGISTERED", T.C.text)
  center(c, after + 3, "AIRCRAFT   LAND VEHICLES   VESSELS   SUBMARINES", T.C.faint)
  center(c, after + 5, "  BE SEATED  ", T.C.text, T.C.accent)
  center(c, c.h - 2, "UNREGISTERED CRAFT ARE NOT SEEN BY TRAFFIC CONTROL", T.C.faint)
  center(c, c.h - 1, "EQUIPMENT IS ISSUED WITHOUT CHARGE", T.C.rule)
end

local DRIVE = {
  dev = "CINDER PROPERTY IS IN THE DRIVE - REMOVE IT",
  pass = "A TRANSIT PASS IS IN THE DRIVE - REMOVE IT",
  other = "REMOVE THE COMPUTER FROM THE DRIVE",
  theirs = "THAT UNIT IS REGISTERED TO ANOTHER SUBJECT",
}

function S.hello(T, c, view, hits)
  header(T, c, nil, "")
  center(c, 3, "SUBJECT IDENTIFIED", T.C.faint)
  center(c, 4, tostring(view.who or ""):upper(), T.C.text)
  local bw = min(40, c.w - 6)
  local bx = floor((c.w - bw) / 2) + 1
  local out = view.stock ~= nil and view.stock < 1
  button(T, c, hits, "register", bx, 7, bw, 3, "REGISTER A CRAFT", not out,
    out and "NO EQUIPMENT IN STOCK" or "EQUIPMENT ISSUED ON COMPLETION")
  button(T, c, hits, "apply", bx, 11, bw, 3, "APPLY: TRAFFIC CENTRE", false, "SUBJECT TO REVIEW")
  local d = DRIVE[view.drive or ""]
  if d then center(c, 16, d, T.C.warn)
  else center(c, 16, "TO AMEND A UNIT ON RECORD, PLACE IT IN THE DRIVE", T.C.faint) end
  record(T, c, view)
  local bye = "STAND TO END THE SESSION"
  c:text(c.w - #bye, c.h - 1, bye, T.C.faint)
end

function S.mine(T, c, view, hits)
  header(T, c, nil, "")
  local u = view.unit or {}
  center(c, 4, "RECORD FOUND", T.C.faint)
  center(c, 6, tostring(u.reg or ""), T.C.text)
  center(c, 7, tostring(u.call or ""), T.C.text)
  center(c, 8, kindWord(u.kind), T.C.faint)
  center(c, 11, "UPDATE ITS SOFTWARE, OR AMEND THE RECORD", T.C.faint)
  record(T, c, view)
  footButtons(T, c, hits, { { "cancel", "CANCEL" }, { "change", "AMEND" }, { "update", "UPDATE", true } })
end

function S.type(T, c, view, hits)
  header(T, c, nil, "1 OF 3")
  center(c, 3, "DECLARE THE CLASS OF CRAFT", T.C.text)
  local gap = 2
  local bw = floor((c.w - 2 - gap) / 2)
  local bh = max(3, min(5, floor((c.h - 9) / 2)))
  for i, k in ipairs(M.KINDS) do
    local col, row = (i - 1) % 2, floor((i - 1) / 2)
    button(T, c, hits, "kind:" .. k.id, 2 + col * (bw + gap), 5 + row * (bh + 1), bw, bh, k.word,
      view.kind == k.id, k.sees)
  end
  record(T, c, view)
  footButtons(T, c, hits, { { "back", "BACK" } })
end

function S.callsign(T, c, view, hits)
  header(T, c, nil, "2 OF 3")
  keyboard(T, c, hits, view, { prompt = "ASSIGN A CALLSIGN", text = view.call, max = M.CALL_MAX,
    okLive = #tostring(view.call or "") >= 2, note = view.note, hint = "TRAFFIC CONTROL WILL ADDRESS THE CRAFT BY IT" })
end

function S.confirm(T, c, view, hits)
  header(T, c, nil, "3 OF 3")
  center(c, 3, "REVIEW THE DECLARATION", T.C.text)
  fields(T, c, 6, { { "REGISTRANT", tostring(view.who or ""):upper() }, { "CLASS", kindWord(view.kind) },
                    { "CALLSIGN", tostring(view.call or "") }, { "REGISTRATION", tostring(view.reg or "") } })
  center(c, 14, view.mode == "change" and "SAME UNIT. SAME REGISTRATION."
    or "ISSUED: ONE UNIT, TWO MONITORS, ONE ENDER MODEM", T.C.faint)
  center(c, 15, "THE UNIT REPORTS ITS POSITION TO CINDER. CONTINUOUSLY.", T.C.text)
  center(c, 16, "DECLARATIONS ARE KEPT ON RECORD", T.C.faint)
  record(T, c, view)
  footButtons(T, c, hits, { { "back", "BACK" }, { "register", "SUBMIT", true } })
end

function S.working(T, c, view, hits)
  header(T, c, nil, "")
  center(c, floor(c.h / 2) - 1, view.say or "PROCESSING", T.C.text)
  local bw = min(40, c.w - 10)
  T.bar(c, floor((c.w - bw) / 2) + 1, floor(c.h / 2) + 1, bw, view.frac or 0, T.C.accent)
  record(T, c, view)
end

function S.done(T, c, view, hits)
  header(T, c, nil, "")
  center(c, 3, view.updated and "RECORD AMENDED" or "ENTERED INTO THE REGISTRY", T.C.faint)
  local reg = tostring(view.reg or "")
  local cells = math.ceil(T.headlinePx(reg, 2) / 2)
  T.headline(c, max(1, floor((c.w - cells) / 2) + 1), 5, reg, T.C.text, 2)
  center(c, 10, tostring(view.call or ""), T.C.text)
  if view.kit then
    center(c, 12, "COLLECT YOUR EQUIPMENT FROM THE CHEST", T.C.text)
    center(c, 13, "ONE UNIT, TWO ADVANCED MONITORS, ONE ENDER MODEM", T.C.faint)
    center(c, 14, "FIT TO THE CRAFT: SCREENS AND MODEM AGAINST THE UNIT", T.C.faint)
    center(c, 15, "THE UNIT STARTS ITSELF. COMPLIANCE APPRECIATED.", T.C.faint)
  else
    center(c, 12, "COLLECT YOUR UNIT FROM THE CHEST", T.C.text)
  end
  record(T, c, view)
  footButtons(T, c, hits, { { "done", "ACKNOWLEDGE", true } })
end

function S.appname(T, c, view, hits)
  header(T, c, M.FORM_APP, "1 OF 3")
  keyboard(T, c, hits, view, { prompt = "DESIGNATION OF THE CENTRE", text = view.text, max = 12,
    okLive = #tostring(view.text or "") >= 2, note = view.note, hint = "SHOWN ON EVERY RADAR",
    keys = "0123456789QWERTYUIOPASDFGHJKL-ZXCVBNM" })
end

function S.appwhere(T, c, view, hits)
  header(T, c, M.FORM_APP, "2 OF 3")
  keyboard(T, c, hits, view, { prompt = "LOCATION: X, A SPACE, THEN Z (F3)", text = view.text, max = 15,
    okLive = tostring(view.text or ""):match("^%-?%d+ %-?%d+$") ~= nil, note = view.note, keys = "0123456789-" })
end

function S.appconfirm(T, c, view, hits)
  header(T, c, M.FORM_APP, "3 OF 3")
  center(c, 3, "REVIEW THE APPLICATION", T.C.text)
  fields(T, c, 6, { { "APPLICANT", tostring(view.who or ""):upper() }, { "DESIGNATION", tostring(view.appName or "") },
                    { "LOCATION", string.format("%s %s", tostring(view.x), tostring(view.z)) } })
  center(c, 12, "A CENTRE DISPLAYS CINDER'S TRAFFIC PICTURE AROUND ITSELF", T.C.faint)
  center(c, 13, "NEEDS: A COMPUTER, AN ENDER MODEM, A 3X3 MONITOR", T.C.faint)
  center(c, 14, "NOT EVERY APPLICATION IS APPROVED", T.C.text)
  record(T, c, view)
  footButtons(T, c, hits, { { "back", "BACK" }, { "send", "SUBMIT", true } })
end

function S.appdone(T, c, view, hits)
  header(T, c, M.FORM_APP, "")
  center(c, floor(c.h / 2) - 2, "APPLICATION LODGED", T.C.faint)
  center(c, floor(c.h / 2), tostring(view.appName or ""), T.C.text)
  center(c, floor(c.h / 2) + 2, "CINDER WILL BE IN CONTACT", T.C.faint)
  record(T, c, view)
  footButtons(T, c, hits, { { "done", "ACKNOWLEDGE", true } })
end

function S.error(T, c, view, hits)
  header(T, c, nil, "")
  local lines = view.msg or { "PROCEDURE HALTED" }
  local y = max(4, floor(c.h / 2) - #lines)
  for i, l in ipairs(lines) do center(c, y + i - 1, tostring(l):upper(), i == 1 and T.C.warn or T.C.faint) end
  if view.who then record(T, c, view) end
  footButtons(T, c, hits, { { "done", "ACKNOWLEDGE", true } })
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
