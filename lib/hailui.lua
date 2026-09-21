-- hailui: the customer's screens, built out of lib/tui.lua.
--
-- Two of them, and no more: pick a place, then watch the taxi come. Both are
-- laid out for a 26x20 pocket screen, both scale up to a monitor without
-- changing, and both are drawn by tools/preview_pocket.py on the desktop so
-- the layout can be judged without a game running.
--
-- What the customer is doing decides what the screen shows. On the list that
-- is the highlighted row and nothing else; on the ride it is the range and the
-- bar, with everything else quieter than they are.

local M = {}

M.NAME = "CINDER"                  -- what the mastheads say
M.SUB = "TRANSIT DIRECTORATE"       -- and the line under the first one
M.BRANCH = "TRANSIT"                -- the right-hand end of the slim header

-- One word for each thing, in the Directorate's voice: terse, formal, and a
-- shade less friendly than a transit company would be.
M.WORDS = {
  queued  = "HOLDING",
  calling = "REQUESTED",
  enroute = "INBOUND",
  waiting = "ON STATION",
  riding  = "IN TRANSIT",
  done    = "COMPLETE",
  failed  = "ABORTED",
}

--- What a customer calls a craft: its class and its number. The passenger
-- craft are Lambdas, so drone-1 is LAMBDA-1; anything named otherwise is
-- shown as it is.
function M.unitName(id)
  if type(id) ~= "string" or id == "" then return nil end
  local n = id:lower():match("^drone%-(%d+)$")
  return n and ("LAMBDA-" .. n) or id:upper()
end

--- The slim header for screens with work on them: the name at the left, the
-- branch at the right, a hairline between. The full masthead is kept for the
-- boot and the home list; everywhere else the screen's own content is the
-- heaviest thing on it.
function M.header(T, c, label)
  local w = c.w
  label = tostring(label or M.BRANCH):upper()
  c:text(1, 1, M.NAME, T.C.text)
  local lx = w - #label + 1
  c:text(lx, 1, label, T.C.faint)
  local x0, x1 = #M.NAME + 2, lx - 2
  if x1 >= x0 then c:line((x0 - 1) * 2 + 1, 2, x1 * 2, 2, T.C.rule) end
end

--- A progress line one sub-pixel tall: the track in the rule grey, the part
-- done in ink. Cells x .. x+w-1 on row y.
function M.hairbar(T, c, x, y, w, frac, ink)
  local py = (y - 1) * 3 + 2
  local px0, px1 = (x - 1) * 2 + 1, (x - 1 + w) * 2
  c:line(px0, py, px1, py, T.C.rule)
  local fill = math.floor((px1 - px0 + 1) * math.max(0, math.min(1, frac or 0)))
  if fill > 0 then c:line(px0, py, px0 + fill - 1, py, ink or T.C.accent) end
end

-- spurs, as people say them: the ledger's own formatting, kept here so the
-- screen and the base never disagree about what a number means
function M.money(spurs)
  spurs = math.floor(tonumber(spurs) or 0)
  local sign, n = spurs < 0 and "-" or "", math.abs(spurs)
  if n >= 4096 then return string.format("%s%.1f SUN", sign, n / 4096) end
  if n >= 64 then return string.format("%s%.1f COG", sign, n / 64) end
  return string.format("%s%d SPUR", sign, n)
end

local function clock(sec)
  if not sec then return "--:--" end
  return string.format("%d:%02d", math.floor(sec / 60), math.floor(sec % 60))
end

-- --------------------------------------------------------------- the list ---
-- view = { places = { {name, dist}, ... }, sel = n, top = n, from = {x,z} }
-- Returns how many rows fitted, so the caller can page by the same number.
function M.places(T, c, view)
  local w, h = c.w, c.h
  c:clear()
  -- row 2, never row 1: a letter cell drawn with swapped colours on the top
  -- row would paint the screen's margin above it (see T.masthead)
  local y = T.masthead(c, 2, M.NAME, T.C.text, M.SUB)

  -- one band says what the list is and what the account holds
  local owed = view.balance and view.balance < 0
  T.band(c, y + 1, "DESTINATIONS", view.balance and M.money(view.balance) or nil,
         nil, owed and T.C.warn or T.C.text)

  local top, bottom = y + 2, h - 2
  local rows = bottom - top + 1
  local first = math.max(1, math.min(view.top or 1, math.max(1, #view.places - rows + 1)))
  for i = 0, rows - 1 do
    local p = view.places[first + i]
    if p then
      T.row(c, 1, top + i, w, p.name:upper(), string.format("%d", math.floor(p.dist or 0)),
            (first + i) == view.sel)
    end
  end
  if #view.places == 0 then
    local function mid(y, s, ink) c:text(math.max(1, math.floor((w - #s) / 2) + 1), y, s, ink) end
    mid(top + 4, "NO DESTINATIONS YET", T.C.text)
    mid(top + 6, "C  ENTER COORDINATES", T.C.faint)
  end

  -- the arrows explain themselves once a row is lit, so the bar spends its
  -- width on the keys nobody would guess: credit and typed coordinates
  T.keys(c, h, { { "ENT", "GO", true }, { "T", "CREDIT" }, { "C", "XZ" } })
  return rows
end

-- --------------------------------------------------------------- the boot ---
-- Nothing to read, on purpose: the name, a line that fills, and that is all.
-- A customer's pass shows this while it starts (kiosk.lua) and hail finds
-- where they are standing. view = { frac = 0..1, ver = "a1b2c3d" }
function M.boot(T, c, view)
  local w, h = c.w, c.h
  c:clear()
  local y = math.max(1, math.floor(h / 2) - 3)
  local after = T.masthead(c, y, M.NAME, T.C.text, M.SUB)
  -- a hairline, one sub-pixel tall, like the rules either side of the name
  local bw = math.max(6, w - 10)
  M.hairbar(T, c, math.floor((w - bw) / 2) + 1, after + 1, bw, view.frac, T.C.accent)
  -- the build, in the corner, in the same grey as the rules: there for
  -- whoever looks for it, and not for anyone else
  if view.ver then c:text(2, h, "REV " .. tostring(view.ver):upper():sub(1, 7), T.C.rule) end
end

-- ---------------------------------------------------------- out of service ---
-- When the program behind a pass stops. What went wrong is written to .crash
-- for the base to read; the customer only needs to know it is coming back.
function M.down(T, c, view)
  local w, h = c.w, c.h
  c:clear()
  local y = math.max(1, math.floor(h / 2) - 4)
  local after = T.masthead(c, y, M.NAME, T.C.text, M.SUB)
  local function mid(row, s, ink) c:text(math.max(1, math.floor((w - #s) / 2) + 1), row, s, ink) end
  mid(after + 1, "SERVICE SUSPENDED", T.C.warn)
  mid(after + 3, "STAND BY", T.C.faint)
end

-- -------------------------------------------------------------- the till ---
-- view = { who, balance, amount, state = "choose"|"waiting"|"done", got }
function M.topup(T, c, view)
  local w, h = c.w, c.h
  c:clear()
  M.header(T, c, "CREDIT")
  local r = T.section(c, 3, "ACCOUNT")
  c:text(2, r, tostring(view.who or "ANONYMOUS"):upper():sub(1, w - 2), T.C.text)
  c:text(2, r + 1, M.money(view.balance or 0), (view.balance or 0) < 0 and T.C.warn or T.C.text)

  r = T.section(c, 7, "ADD CREDIT")
  if view.state == "ready" then
    c:text(2, r, "TILL OPEN", T.C.ok)
    c:text(2, r + 1, "DEPOSIT " .. M.money(view.amount) .. " NOW", T.C.text)
    c:text(2, r + 3, "CREDITED TO", T.C.faint)
    c:text(2, r + 4, tostring(view.who or ""):upper():sub(1, w - 2), T.C.text)
    T.keys(c, h, { { "Q", "BACK" } })
  elseif view.state == "waiting" then
    c:text(2, r, "PROCEED TO THE TILL", T.C.text)
    c:text(2, r + 1, "AND BE SEATED", T.C.text)
    c:text(2, r + 3, "AMOUNT " .. M.money(view.amount), T.C.faint)
    c:text(2, r + 4, "IT OPENS WHEN YOU ARE", T.C.faint)
    T.keys(c, h, { { "Q", "BACK" } })
  elseif view.state == "done" then
    c:text(2, r, "RECEIVED " .. M.money(view.got or 0), T.C.ok)
    c:text(2, r + 2, "BALANCE " .. M.money(view.balance or 0), T.C.text)
    T.keys(c, h, { { "Q", "BACK" } })
  else
    c:text(2, r, "SELECT AMOUNT", T.C.text)
    c:text(2, r + 2, "1  64 SPUR  (1 COG)", T.C.faint)
    c:text(2, r + 3, "2  512 SPUR (8 COG)", T.C.faint)
    c:text(2, r + 4, "3  4096 SPUR (1 SUN)", T.C.faint)
    T.keys(c, h, { { "1/2/3", "PICK", true }, { "Q", "BACK" } })
  end
  c:text(w, h, T.spin(view.spin), T.C.rule, T.C.panel)
  return c
end

-- --------------------------------------------------------------- the ride ---
-- view = { unit, state, away, start, eta, log = {...}, detail, spin }
local function xyz(p)
  if not (p and p.x and p.z) then return "UNKNOWN" end
  if p.y then return string.format("%d %d %d", math.floor(p.x), math.floor(p.y), math.floor(p.z)) end
  return string.format("%d %d", math.floor(p.x), math.floor(p.z))
end

-- view = { state, unit, away, start, eta, log, showLog, spin, place,
--          from = {x,y,z}, to = {x,y,z},     the order, in coordinates
--          zone = n, zoneR = n,              customer's distance from the pickup spot
--          board = true }                    walk to a unit already on station
function M.ride(T, c, view)
  local w, h = c.w, c.h
  c:clear()
  local away = view.away
  local start = math.max(view.start or away or 1, 1)
  local frac = away and (1 - away / start) or 0
  if view.state == "waiting" or view.state == "done" then frac = 1 end
  local failed = view.state == "failed"
  local here = view.state == "waiting"
  local zoneR = view.zoneR or 4

  M.header(T, c)

  -- UNIT: which craft, and what it is doing, on one line
  T.band(c, 3, "UNIT")
  local unit = M.unitName(view.unit)
    or (view.place and ("QUEUE POSITION " .. view.place)) or "ASSIGNING"
  local word = M.WORDS[view.state] or "STANDING BY"
  c:text(2, 4, unit:sub(1, w - #word - 3), T.C.text)
  c:text(w - #word, 4, word, failed and T.C.warn or (here and T.C.ok or T.C.accent))

  -- ROUTE: the order in coordinates, from the first screen to the last
  T.band(c, 5, "ROUTE")
  c:text(2, 6, "FROM", T.C.faint)
  c:text(7, 6, xyz(view.from):sub(1, w - 7), T.C.text)
  c:text(2, 7, "TO", T.C.faint)
  c:text(7, 7, xyz(view.to):sub(1, w - 7), T.C.text)

  -- The number the customer is waiting on, in the big type: the ETA, HERE
  -- once it is on station, or - walking to a unit already standing nearby -
  -- how far they have left to go.
  local label, big, ink
  if view.board and view.state ~= "riding" then
    label = "WALK TO UNIT"
    big = view.zone and tostring(math.floor(view.zone)) or "--"
    ink = (view.zone and view.zone <= zoneR) and T.C.ok or (view.zone and T.C.text or T.C.rule)
  elseif here then
    label, big, ink = "ARRIVAL", "HERE", T.C.ok
  else
    label = view.state == "queued" and "EST. WAIT" or (view.state == "riding" and "TO DESTINATION" or "ARRIVAL")
    big, ink = clock(view.eta), view.eta and T.C.text or T.C.rule
  end
  T.band(c, 8, label)
  T.headline(c, 2, 9, big, ink, 2)

  -- RANGE, quieter: how far, and a hairline for how much of it is done.
  -- Not while walking to a unit that is already there: the big number is
  -- the range then.
  if not (view.board and view.state ~= "riding") then
    T.band(c, 13, "RANGE")
    local num = away and tostring(math.floor(away)) or "----"
    c:text(2, 14, num, T.C.text)
    c:text(2 + #num + 1, 14, "BLOCKS", T.C.faint)
    c:text(w - 4, 14, string.format("%3d%%", math.floor(frac * 100 + 0.5)), T.C.faint)
    M.hairbar(T, c, 2, 15, w - 2, frac, failed and T.C.warn or T.C.accent)
  end

  if view.log and view.showLog then
    -- LOG, only when it is wanted: the least Imperial thing on the screen
    local log = view.log
    local rows = h - 17
    local first = math.max(1, #log - rows + 1)
    for k = first, #log do
      c:text(2, 17 + (k - first), tostring(log[k]):upper():sub(1, w - 2),
             (k == #log) and T.C.text or T.C.faint)
    end
  elseif view.board and view.state ~= "riding" and view.zone then
    if view.zone <= zoneR then
      c:text(2, 17, "ALONGSIDE", T.C.ok)
      c:text(2, 18, "BOARD, THEN PRESS G", T.C.faint)
    else
      c:text(2, 17, "UNIT ON STATION NEARBY", T.C.text)
      c:text(2, 18, "WALK OVER, BOARD, PRESS G", T.C.faint)
    end
  elseif view.zone and view.state ~= "riding" and not here then
    -- the pickup: keep the customer out of where the unit is coming down
    if view.zone < zoneR + 1 then
      c:text(2, 17, "STAND CLEAR OF THE ZONE", T.C.warn)
      c:text(2, 18, string.format("YOU ARE %d FROM THE SPOT", math.floor(view.zone)), T.C.faint)
    else
      c:text(2, 17, "ZONE CLEAR", T.C.ok)
      c:text(2, 18, string.format("YOU ARE %d FROM THE SPOT", math.floor(view.zone)), T.C.faint)
    end
  end
  if failed and view.detail then
    c:text(2, h - 2, tostring(view.detail):upper():sub(1, w - 2), T.C.warn)
  end

  if here then
    T.keys(c, h, { { "G", "DEPART", true }, { "L", "LOG" }, { "Q", "ABORT" } })
  else
    T.keys(c, h, { { "L", "LOG" }, { "Q", "ABORT" } })
  end
  return c
end

return M
