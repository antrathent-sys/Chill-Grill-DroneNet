-- hailmap: the ride screen on the customer's pocket terminal.
--
-- A boxed terminal dashboard, the way a system monitor looks: panels with
-- their titles set into the top rule, values in columns, and bars drawn as
-- filled cells rather than characters so they read as bars and not as text.
-- Everything is characters and cell colours - no sub-pixel drawing anywhere -
-- and it is all built for a 26x20 pocket screen, so the panels stack instead
-- of sitting side by side.
--
-- Colours come from the theme's roles (lib/display.lua:33), so the imperial
-- palette gives bone on near-black with grey furniture, and red is kept for
-- something having gone wrong.
--
-- tools/preview_pocket.py draws this same code on the desktop, which is how
-- the layout gets checked without a game running.

local M = {}

M.WORDS = {
  calling = "REQUESTING UNIT",
  enroute = "UNIT INBOUND",
  waiting = "UNIT ON STATION",
  riding  = "IN TRANSIT",
  done    = "ARRIVED",
  failed  = "OPERATION ENDED",
}

M.SPIN = { "|", "/", "-", "\\" }

-- A panel: a top rule with the title set into it, a bottom rule, and sides.
-- Returns the first row inside it.
--   +- TITLE ---------------+
--   |                       |
--   +-----------------------+
function M.panel(c, y, h, title, edge, ink)
  local w = c.w
  local head = "+-"
  if title then head = head .. " " .. title .. " " end
  c:text(1, y, (head .. string.rep("-", math.max(0, w - #head - 1)) .. "+"):sub(1, w), edge)
  if title then c:text(4, y, " " .. title .. " ", ink) end
  for i = 1, h do
    c:text(1, y + i, "|", edge)
    c:text(w, y + i, "|", edge)
  end
  c:text(1, y + h + 1, ("+" .. string.rep("-", w - 2) .. "+"):sub(1, w), edge)
  return y + 1
end

-- A bar of filled cells: the lit part is a run of spaces on the ink colour,
-- the rest a run of spaces on the dark one. Reads as a bar because it is one.
function M.bar(c, x, y, width, frac, ink, dark)
  frac = math.max(0, math.min(1, frac or 0))
  local lit = math.floor(width * frac + 0.5)
  if lit > 0 then c:text(x, y, string.rep(" ", lit), ink, ink) end
  if lit < width then c:text(x + lit, y, string.rep(" ", width - lit), dark, dark) end
end

local function clock(sec)
  if not sec then return "--:--" end
  return string.format("%d:%02d", math.floor(sec / 60), math.floor(sec % 60))
end

-- view = { unit, state, away, start, eta, log = { "0612 ..." }, detail }
function M.gauge(D, c, view)
  local C = D.C
  -- the empty half of a bar needs a visible track, so it is the grid slot and
  -- not the panel slot: panel is the background colour and the bar vanished
  local edge, dim, bone, bright, red, dark = C.grid, C.dim, C.white, C.bright, C.red, C.grid
  c:clear()
  local w = c.w
  local away = view.away
  local start = math.max(view.start or away or 1, 1)
  local frac = away and (1 - away / start) or 0
  if view.state == "waiting" or view.state == "done" then frac = 1 end
  local failed = view.state == "failed"

  -- title bar
  local title = " CHILL GRILL AIR TAXI "
  c:text(1, 1, string.rep("=", w), edge)
  c:text(math.max(1, math.floor((w - #title) / 2) + 1), 1, title, bone)

  -- unit and status
  local r = M.panel(c, 2, 2, "UNIT", edge, dim)
  c:text(3, r, tostring(view.unit or "-- ASSIGNING"):upper():sub(1, w - 4), bone)
  c:text(3, r + 1, (M.WORDS[view.state] or "STANDING BY"):sub(1, w - 4), failed and red or bright)

  -- range, with the bar under it
  r = M.panel(c, 6, 3, "RANGE", edge, dim)
  c:text(3, r, (away and (math.floor(away) .. " BLOCKS") or "----"):sub(1, w - 4), bone)
  c:text(w - 8, r, string.format("%3d%%", math.floor(frac * 100 + 0.5)), dim)
  M.bar(c, 3, r + 1, w - 4, frac, bright, dark)
  c:text(3, r + 2, ("ETA  " .. (view.state == "waiting" and "ON STATION" or clock(view.eta))):sub(1, w - 4), dim)

  -- what the job has done so far
  local logTop = 11
  local logH = (c.h - 3) - logTop - 1
  r = M.panel(c, logTop, logH, "LOG", edge, dim)
  local log = view.log or {}
  local first = math.max(1, #log - logH + 1)
  for i = first, #log do
    c:text(3, r + (i - first), tostring(log[i]):upper():sub(1, w - 4), dim)
  end

  -- the one thing to do, then the keys
  if view.state == "waiting" then
    c:text(1, c.h - 2, (" BOARD, THEN PRESS G "):sub(1, w), bright)
  elseif failed and view.detail then
    c:text(1, c.h - 2, tostring(view.detail):upper():sub(1, w), red)
  end
  c:text(1, c.h - 1, string.rep("-", w), edge)
  local keys = (view.state == "waiting") and "[G] BOARD  [Q] ABORT" or "[Q] ABORT"
  c:text(1, c.h, keys, dim)
  c:text(w - 1, c.h, M.SPIN[((view.spin or 0) % 4) + 1], bone)
  return c
end

return M
