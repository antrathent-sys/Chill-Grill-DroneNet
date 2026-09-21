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

M.NAME = "SHUTTLE"                 -- what the mastheads say
M.SUB = "CHILL GRILL SHUTTLE SVC"   -- and the line under the first one

M.WORDS = {
  queued  = "IN THE QUEUE",
  -- kept short: the UNIT box is 13 characters wide and the masthead has
  -- already said SHUTTLE
  calling = "REQUESTED",
  enroute = "INBOUND",
  waiting = "ON STATION",
  riding  = "IN TRANSIT",
  done    = "ARRIVED",
  failed  = "ENDED",
}

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
  T.masthead(c, 1, M.NAME, T.C.text, M.SUB)
  c:text(1, 4, "WHERE TO?", T.C.text)
  c:text(1, 5, string.format("AT %d, %d", view.from.x, view.from.z), T.C.faint)
  if view.balance then
    local owed = view.balance < 0
    c:text(w - 11, 5, string.format("%11s", M.money(view.balance)), owed and T.C.warn or T.C.text)
  end

  local top, bottom = 6, h - 2
  T.section(c, top, "PLACES")
  local rows = bottom - top
  local first = math.max(1, math.min(view.top or 1, math.max(1, #view.places - rows + 1)))
  for i = 0, rows - 1 do
    local p = view.places[first + i]
    if p then
      T.row(c, 1, top + 1 + i, w, p.name:upper(), string.format("%5d", math.floor(p.dist or 0)),
            (first + i) == view.sel)
    end
  end
  if #view.places == 0 then c:text(2, top + 1, "NONE KNOWN - PRESS C", T.C.faint) end

  T.keys(c, h, { { "UP/DN", "PICK", true }, { "ENT", "GO" }, { "C", "XZ" }, { "T", "TOP UP" } })
  return rows
end

-- -------------------------------------------------------------- the till ---
-- view = { who, balance, amount, state = "choose"|"waiting"|"done", got }
function M.topup(T, c, view)
  local w, h = c.w, c.h
  c:clear()
  T.masthead(c, 1, "CREDIT", T.C.text)
  local r = T.section(c, 4, "ACCOUNT")
  c:text(2, r, tostring(view.who or "ANONYMOUS"):upper():sub(1, w - 2), T.C.text)
  c:text(2, r + 1, M.money(view.balance or 0), (view.balance or 0) < 0 and T.C.warn or T.C.text)

  r = T.section(c, 8, "TOP UP")
  if view.state == "ready" then
    c:text(2, r, "TILL OPEN", T.C.ok)
    c:text(2, r + 1, "PAY " .. M.money(view.amount) .. " NOW", T.C.text)
    c:text(2, r + 3, "IT CREDITS YOU AS", T.C.faint)
    c:text(2, r + 4, tostring(view.who or ""):upper():sub(1, w - 2), T.C.text)
    T.keys(c, h, { { "Q", "BACK" } })
  elseif view.state == "waiting" then
    c:text(2, r, "GO TO THE TILL", T.C.text)
    c:text(2, r + 1, "AND SIT DOWN", T.C.text)
    c:text(2, r + 3, "PAYING " .. M.money(view.amount), T.C.faint)
    c:text(2, r + 4, "IT OPENS WHEN YOU DO", T.C.faint)
    T.keys(c, h, { { "Q", "BACK" } })
  elseif view.state == "done" then
    c:text(2, r, "PAID " .. M.money(view.got or 0), T.C.ok)
    c:text(2, r + 2, "BALANCE " .. M.money(view.balance or 0), T.C.text)
    T.keys(c, h, { { "Q", "BACK" } })
  else
    c:text(2, r, "HOW MUCH?", T.C.text)
    c:text(2, r + 2, "1  64 SPUR  (1 COG)", T.C.faint)
    c:text(2, r + 3, "2  512 SPUR (8 COG)", T.C.faint)
    c:text(2, r + 4, "3  4096 SPUR (1 SUN)", T.C.faint)
    T.keys(c, h, { { "1/2/3", "PICK", true }, { "Q", "BACK" } })
  end
  c:text(w, h, T.spin(view.spin), T.C.rule)
  return c
end

-- --------------------------------------------------------------- the ride ---
-- view = { unit, state, away, start, eta, log = {...}, detail, spin }
function M.ride(T, c, view)
  local w, h = c.w, c.h
  c:clear()
  local away = view.away
  local start = math.max(view.start or away or 1, 1)
  local frac = away and (1 - away / start) or 0
  if view.state == "waiting" or view.state == "done" then frac = 1 end
  local failed = view.state == "failed"

  T.masthead(c, 1, M.NAME, T.C.text)

  -- UNIT and its status
  local r = T.section(c, 3, "UNIT")
  c:text(2, r, tostring(view.unit or (view.place and ("No " .. view.place .. " IN LINE")) or "ASSIGNING")
           :upper():sub(1, w - 10), T.C.text)
  c:text(w - 7, r, (view.state == "waiting" and "HERE" or clock(view.eta)), T.C.text)
  c:text(2, r + 1, (M.WORDS[view.state] or "STANDING BY"):sub(1, w - 10),
         failed and T.C.warn or (view.state == "waiting" and T.C.ok or T.C.accent))
  c:text(w - 7, r + 1, view.state == "riding" and "TO GO" or "OUT", T.C.faint)

  -- RANGE, the number the customer actually wants, with its bar
  r = T.section(c, 6, "RANGE")
  local num = away and tostring(math.floor(away)) or "----"
  c:text(2, r, num, T.C.text)
  c:text(2 + #num + 1, r, "BLOCKS", T.C.faint)
  c:text(w - 4, r, string.format("%3d%%", math.floor(frac * 100 + 0.5)), T.C.faint)
  T.bar(c, 2, r + 1, w - 2, frac, failed and T.C.warn or T.C.accent, T.C.panel)

  -- LOG, only when it is wanted: a scrolling transcript is the least Imperial
  -- thing on the screen, so it is off unless the customer presses L
  if view.log and view.showLog then
    local logY, logBottom = 9, h - 1
    r = T.section(c, logY, "LOG")
    local log = view.log
    local rows = logBottom - logY
    local first = math.max(1, #log - rows + 1)
    for i = first, #log do
      c:text(2, r + (i - first), tostring(log[i]):upper():sub(1, w - 2),
             (i == #log) and T.C.text or T.C.faint)
    end
  end
  if failed and view.detail then
    c:text(2, h - 2, tostring(view.detail):upper():sub(1, w - 2), T.C.warn)
  end

  if view.state == "waiting" then
    T.keys(c, h, { { "G", "BOARD", true }, { "L", "LOG" }, { "Q", "ABORT" } })
  else
    T.keys(c, h, { { "L", "LOG" }, { "Q", "ABORT" } })
  end
  c:text(w, h, T.spin(view.spin), T.C.rule)
  return c
end

return M
