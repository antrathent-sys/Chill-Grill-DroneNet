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
  -- kept short: the UNIT box is 13 characters wide and the masthead has
  -- already said SHUTTLE
  calling = "REQUESTED",
  enroute = "INBOUND",
  waiting = "ON STATION",
  riding  = "IN TRANSIT",
  done    = "ARRIVED",
  failed  = "ENDED",
}

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

  local top, bottom = 6, h - 2
  T.box(c, 1, top, w, bottom - top + 1, "PLACES", T.C.rule, T.C.rule)
  local rows = (bottom - 1) - (top + 1) + 1
  local first = math.max(1, math.min(view.top or 1, math.max(1, #view.places - rows + 1)))
  for i = 0, rows - 1 do
    local p = view.places[first + i]
    if p then
      T.row(c, 2, top + 1 + i, w - 2, p.name:upper(), string.format("%5d", math.floor(p.dist or 0)),
            (first + i) == view.sel)
    end
  end
  if #view.places == 0 then c:text(3, top + 1, "NONE KNOWN - PRESS C", T.C.faint) end

  T.keys(c, h, { { "UP/DN", "PICK", true }, { "ENT", "GO" }, { "C", "XZ" } })
  return rows
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

  -- UNIT, with the status under it, and ETA beside it
  local etaW = 9
  local unitW = w - etaW - 1
  local r = T.box(c, 1, 3, unitW, 4, "UNIT", T.C.rule, T.C.rule)
  c:text(3, r, tostring(view.unit or "ASSIGNING"):upper():sub(1, unitW - 3), T.C.text)
  c:text(3, r + 1, (M.WORDS[view.state] or "STANDING BY"):sub(1, unitW - 3),
         failed and T.C.warn or (view.state == "waiting" and T.C.ok or T.C.accent))
  local r2 = T.box(c, unitW + 2, 3, etaW, 4, "ETA", T.C.rule, T.C.rule)
  c:text(unitW + 4, r2, (view.state == "waiting" and "HERE" or clock(view.eta)):sub(1, etaW - 3), T.C.text)
  c:text(unitW + 4, r2 + 1, view.state == "riding" and "TO GO" or "OUT", T.C.faint)

  -- RANGE, the number the customer actually wants, with its bar
  r = T.box(c, 1, 7, w, 4, "RANGE", T.C.rule, T.C.rule)
  local num = away and tostring(math.floor(away)) or "----"
  c:text(3, r, num, T.C.text)
  c:text(3 + #num + 1, r, "BLOCKS", T.C.faint)
  c:text(w - 5, r, string.format("%3d%%", math.floor(frac * 100 + 0.5)), T.C.faint)
  T.bar(c, 3, r + 1, w - 4, frac, failed and T.C.warn or T.C.accent, T.C.panel)

  -- LOG: what has happened, newest last, the newest line lit
  local logY, logBottom = 11, h - 1
  r = T.box(c, 1, logY, w, logBottom - logY + 1, "LOG", T.C.rule, T.C.rule)
  local log = view.log or {}
  local rows = (logBottom - 1) - r + 1
  local first = math.max(1, #log - rows + 1)
  for i = first, #log do
    local last = (i == #log)
    c:text(3, r + (i - first), tostring(log[i]):upper():sub(1, w - 4), last and T.C.text or T.C.faint)
  end
  if failed and view.detail then
    c:text(3, logBottom - 1, tostring(view.detail):upper():sub(1, w - 4), T.C.warn)
  end

  if view.state == "waiting" then
    T.keys(c, h, { { "G", "BOARD", true }, { "Q", "ABORT" } })
  else
    T.keys(c, h, { { "Q", "ABORT" } })
  end
  c:text(w, h, T.spin(view.spin), T.C.rule)
  return c
end

return M
