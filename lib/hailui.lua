-- hailui: the ride screen on the customer's pocket terminal.
--
-- Built to look like a terminal dashboard - the kind with thin boxes, a title
-- set into the top rule of each one, a coloured bar that is a bar rather than
-- a row of hashes, and the keys along the bottom.
--
-- ComputerCraft has no box-drawing characters, so the boxes are drawn as
-- one-pixel lines with lib/display.lua's canvas (teletext sub-pixels, 2x3 to a
-- cell) and the titles are written as text into the cells the line passes
-- through. A cell is either text or pixels, never both, which is why the
-- layout keeps text one cell clear of every edge.
--
-- Colours are the standard ComputerCraft palette: cyan furniture, white
-- values, grey labels, green for progress, red for trouble. No theme is
-- applied, so it looks the same on any pocket.
--
-- tools/preview_pocket.py draws this same code on the desktop.

local M = {}

M.WORDS = {
  calling = "REQUESTING UNIT",
  enroute = "INBOUND",
  waiting = "ON STATION",
  riding  = "IN TRANSIT",
  done    = "ARRIVED",
  failed  = "ENDED",
}

M.SPIN = { "|", "/", "-", "\\" }

-- blit slots, standard palette
M.C = {
  cyan = "9", white = "0", grey = "8", dark = "7", green = "d", blue = "b",
  red = "e", black = "f", yellow = "4",
}

-- A box of thin lines around cells (x, y) to (x + w - 1, y + h - 1), with the
-- title written into the top rule. Text inside starts at x + 1.
function M.box(c, x, y, w, h, title, edge, ink)
  local px0, px1 = (x - 1) * 2 + 1, (x + w - 1) * 2
  local py0, py1 = (y - 1) * 3 + 2, (y + h - 1) * 3 - 1
  c:line(px0, py0, px1, py0, edge)          -- top
  c:line(px0, py1, px1, py1, edge)          -- bottom
  c:line(px0, py0, px0, py1, edge)          -- left
  c:line(px1, py0, px1, py1, edge)          -- right
  if title then c:text(x + 1, y, " " .. title .. " ", ink or edge) end
  return y + 1                               -- first row inside
end

-- A bar: lit cells on a dark track, drawn as coloured spaces.
function M.bar(c, x, y, w, frac, ink, track)
  frac = math.max(0, math.min(1, frac or 0))
  local lit = math.floor(w * frac + 0.5)
  if lit > 0 then c:text(x, y, string.rep(" ", lit), ink, ink) end
  if lit < w then c:text(x + lit, y, string.rep(" ", w - lit), track, track) end
end

local function clock(sec)
  if not sec then return "--:--" end
  return string.format("%d:%02d", math.floor(sec / 60), math.floor(sec % 60))
end

-- view = { unit, state, away, start, eta, log = {...}, detail, spin }
--
-- The layout is fixed rows, because a pocket screen is 26x20 and there is no
-- room to be adaptive: a title, UNIT and ETA side by side with a gap, RANGE
-- with its bar, then LOG taking whatever is left, and the keys on the last
-- line.
function M.ride(D, c, view)
  local K = M.C
  c:clear()
  local w, h = c.w, c.h
  local away = view.away
  local start = math.max(view.start or away or 1, 1)
  local frac = away and (1 - away / start) or 0
  if view.state == "waiting" or view.state == "done" then frac = 1 end
  local failed = view.state == "failed"

  -- caption, with the rule running out to both edges
  local title = " AIR TAXI "
  local tx = math.floor((w - #title) / 2) + 1
  c:line(1, 2, w * 2, 2, K.cyan)
  c:text(tx, 1, title, K.white)

  -- UNIT (with the status under it) and ETA, side by side, one column apart
  local etaW = 9
  local unitW = w - etaW - 1
  local r = M.box(c, 1, 2, unitW, 4, "UNIT", K.cyan, K.cyan)
  c:text(3, r, tostring(view.unit or "ASSIGNING"):upper():sub(1, unitW - 3), K.white)
  c:text(3, r + 1, (M.WORDS[view.state] or "STANDING BY"):sub(1, unitW - 3),
         failed and K.red or (view.state == "waiting" and K.green or K.yellow))
  local r2 = M.box(c, unitW + 2, 2, etaW, 4, "ETA", K.cyan, K.cyan)
  c:text(unitW + 4, r2, (view.state == "waiting" and "HERE" or clock(view.eta)):sub(1, etaW - 3), K.white)
  c:text(unitW + 4, r2 + 1, view.state == "riding" and "TO GO" or "OUT", K.grey)

  -- RANGE: the number, the percentage, and the bar under them
  r = M.box(c, 1, 6, w, 4, "RANGE", K.cyan, K.cyan)
  local num = away and tostring(math.floor(away)) or "----"
  c:text(3, r, num, K.white)
  c:text(3 + #num + 1, r, "BLOCKS", K.grey)
  c:text(w - 4, r, string.format("%3d%%", math.floor(frac * 100 + 0.5)), K.grey)
  M.bar(c, 3, r + 1, w - 4, frac, failed and K.red or K.green, K.dark)

  -- LOG fills the rest, one line per thing that has happened
  local logY, logBottom = 10, h - 1
  r = M.box(c, 1, logY, w, logBottom - logY + 1, "LOG", K.cyan, K.cyan)
  local log = view.log or {}
  local rows = (logBottom - 1) - r + 1
  local first = math.max(1, #log - rows + 1)
  for i = first, #log do
    c:text(3, r + (i - first), tostring(log[i]):upper():sub(1, w - 4), K.grey)
  end
  if failed and view.detail then
    c:text(3, logBottom - 1, tostring(view.detail):upper():sub(1, w - 4), K.red)
  end

  -- keys, and a turning slash in the corner while anything is happening
  if view.state == "waiting" then
    c:text(1, h, "[G]", K.green)
    c:text(5, h, "BOARD", K.white)
    c:text(12, h, "[Q]", K.grey)
    c:text(16, h, "ABORT", K.grey)
  else
    c:text(1, h, "[Q]", K.grey)
    c:text(5, h, "ABORT", K.grey)
  end
  c:text(w, h, M.SPIN[((view.spin or 0) % 4) + 1], K.cyan)
  return c
end

return M
