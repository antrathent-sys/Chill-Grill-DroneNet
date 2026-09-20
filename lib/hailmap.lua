-- hailmap: what a customer watches while their taxi comes.
--
-- Two screens, both pure drawing onto a lib/display.lua canvas so that
-- tools/preview_pocket.py renders exactly what the pocket shows:
--
--   M.gauge  the default. How far away, in big digits, a bar that fills as it
--            closes, and the time left. This is what someone standing in a
--            field actually wants: one number and a sense of progress.
--   M.map    the same ride as a picture - the customer in the middle, the taxi
--            a block with its track behind it, range rings on round numbers.
--            Prettier, and worse at answering "how long".
--
-- A 26x20 pocket screen is 52x60 sub-pixels. That is enough for a big number
-- or a bearing, and not enough for anything clever, so there is nothing clever
-- in here.

local M = {}

M.TRAIL_MIN = 8      -- blocks a taxi must move before the tail records it
M.TRAIL_MAX = 40     -- points kept

-- Round numbers a person reads without thinking.
function M.ring(span)
  local steps = { 10, 25, 50, 100, 250, 500, 1000, 2500, 5000 }
  for _, s in ipairs(steps) do if span <= s then return s end end
  return 10000
end

-- Add a point to a tail, but only where it actually moved: a parked drone
-- must not smear one bright dot over the map.
function M.addTrail(trail, x, z)
  local last = trail[#trail]
  if last and math.sqrt((last.x - x) ^ 2 + (last.z - z) ^ 2) <= M.TRAIL_MIN then return trail end
  trail[#trail + 1] = { x = x, z = z }
  while #trail > M.TRAIL_MAX do table.remove(trail, 1) end
  return trail
end


-- ------------------------------------------------------------------ gauge ---
-- Text. Nothing but text: rules of equals signs, labels in a column, values in
-- a column, and a loading bar made of hashes. No sub-pixel drawing at all, so
-- it looks like a terminal reporting rather than a phone app - which is the
-- point. Imperial colours: bone for what matters, grey for the furniture, red
-- when something has gone wrong.
M.WORDS = {
  calling = "REQUESTING UNIT",
  enroute = "UNIT INBOUND",
  waiting = "UNIT ON STATION",
  riding  = "IN TRANSIT",
  done    = "ARRIVED",
  failed  = "OPERATION ENDED",
}

M.SPIN = { "|", "/", "-", "\\" }

-- [########............] with the fill rounded down, so it only shows full
-- when it really is.
function M.bar(width, frac)
  local inner = math.max(1, width - 2)
  local lit = math.floor(inner * math.max(0, math.min(1, frac or 0)))
  return "[" .. string.rep("#", lit) .. string.rep(".", inner - lit) .. "]"
end

-- "1332 BLOCKS", "0:47", that sort of thing
local function clock(sec)
  if not sec then return "--:--" end
  return string.format("%d:%02d", math.floor(sec / 60), math.floor(sec % 60))
end

function M.gauge(D, c, view)
  local C = D.C
  local dim, bone, bright, red = C.dim, C.white, C.bright, C.red
  c:clear()
  local w = c.w
  local away = view.away
  local start = math.max(view.start or away or 1, 1)
  local frac = away and (1 - away / start) or 0
  if view.state == "waiting" or view.state == "done" then frac = 1 end
  local failed = view.state == "failed"
  local function row(y, label, value, col)
    c:text(1, y, label, dim)
    if value then c:text(9, y, tostring(value):sub(1, w - 9), col or bone) end
  end

  c:text(1, 1, string.rep("=", w), dim)
  c:text(1, 2, ("CHILL GRILL // AIR TAXI"):sub(1, w), bone)
  c:text(1, 3, string.rep("=", w), dim)

  row(5, "UNIT", tostring(view.unit or "-- ASSIGNING"):upper(), bone)
  row(6, "STATUS", M.WORDS[view.state] or "STANDING BY", failed and red or bright)
  row(7, "RANGE", away and (math.floor(away) .. " BLOCKS") or "----", bone)
  row(8, "ETA", view.state == "waiting" and "ON STATION" or clock(view.eta), bone)

  c:text(1, 10, M.bar(w, frac), bone)
  c:text(1, 11, string.format("%d%% %s", math.floor(frac * 100 + 0.5),
    view.state == "riding" and "OF THE WAY" or view.state == "waiting" and "ON STATION" or "CLOSING"), dim)

  if view.state == "waiting" then
    c:text(1, 13, string.rep("-", w), dim)
    c:text(1, 14, "BOARD, THEN PRESS G", bright)
    c:text(1, 15, string.rep("-", w), dim)
  elseif failed and view.detail then
    c:text(1, 14, tostring(view.detail):upper():sub(1, w), red)
  else
    -- the empty middle is where a terminal would print what it has been
    -- doing, so it does: the last few lines of the job, oldest at the top
    local log = view.log or {}
    local room = (c.h - 4) - 13
    local first = math.max(1, #log - room + 1)
    local y = 13
    for i = first, #log do
      c:text(1, y, tostring(log[i]):upper():sub(1, w), dim)
      y = y + 1
    end
  end

  c:text(1, c.h - 2, string.rep("-", w), dim)
  c:text(1, c.h - 1, "M MAP    Q ABORT", dim)
  c:text(1, c.h, "> " .. M.SPIN[((view.spin or 0) % 4) + 1] ..
                 (((view.spin or 0) % 2 == 0) and " _" or ""), bone)
  return c
end

-- view = { from = {x,z}, drone = {x,z} or nil, trail = {...}, away = blocks,
--          state = "enroute"|..., unit = "drone-1", spin = n, dest = {x,z} }
function M.map(D, c, view)
  -- A canvas cell holds a blit palette SLOT ("1", "8", ...), not a CC colour
  -- number: lib/display.lua:33 names the roles and the theme decides what they
  -- look like. Handing it colours.orange writes the number 2 into the blit
  -- string and the row comes out as nonsense - which is exactly what the first
  -- desktop render showed.
  local C = D.C
  local grey, white, amber, paper = C.dim, C.white, C.amber, C.bg

  c:clear()
  local pw, ph = c.w * 2, c.h * 3
  local top, bot = 6, ph - 12                      -- room for a heading and a readout
  local cx, cy = pw / 2, (top + bot) / 2
  local away = view.away or 0
  local span = math.max(away, 40) * 1.3            -- blocks from the middle to the edge
  local radius = math.min(pw / 2, (bot - top) / 2) - 1
  local function toPx(x, z)
    return cx + (x - view.from.x) / span * radius, cy + (z - view.from.z) / span * radius
  end

  local ring = M.ring(span / 2)
  for mult = 1, 3 do
    local rr = ring * mult / span * radius
    if rr < radius then c:circle(cx, cy, rr, grey, 1, 3) end
  end

  -- where the ride is going, if it is on the map
  if view.dest then
    local dx, dy = toPx(view.dest.x, view.dest.z)
    if dx > 0 and dx <= pw and dy > top and dy < bot then
      c:pix(dx - 1, dy - 1, white) c:pix(dx + 1, dy - 1, white)
      c:pix(dx - 1, dy + 1, white) c:pix(dx + 1, dy + 1, white)
    end
  end

  local prev
  for _, p in ipairs(view.trail or {}) do
    local px, py = toPx(p.x, p.z)
    if prev then c:line(prev[1], prev[2], px, py, grey, 1, 2) end
    prev = { px, py }
  end

  -- The customer is a hollow ring and the taxi a solid block. In the imperial
  -- theme everything is one shade of bone, so the two have to be told apart by
  -- SHAPE - the first desktop render had both as pale crosses and they were
  -- indistinguishable at a glance.
  for dx = -1, 1 do
    for dy = -1, 1 do
      if not (dx == 0 and dy == 0) then c:pix(cx + dx, cy + dy, white) end
    end
  end

  -- the taxi: a blob on a line of sight, pinned to the rim when it is further
  -- out than the map goes
  if view.drone then
    local px, py = toPx(view.drone.x, view.drone.z)
    local d = math.sqrt((px - cx) ^ 2 + (py - cy) ^ 2)
    if d > radius then
      local ang = math.atan2(py - cy, px - cx)
      px, py = cx + math.cos(ang) * radius, cy + math.sin(ang) * radius
    end
    c:line(cx, cy, px, py, grey, 1, 4)
    for dx = -1, 1 do
      for dy = -1, 1 do c:pix(px + dx, py + dy, amber) end
    end
  end

  c:text(1, 1, ("CGAT " .. tostring(view.unit or "NO UNIT")):upper():sub(1, c.w), white)
  c:text(1, c.h - 1, (view.away and string.format("RANGE %d", math.floor(view.away)) or "LOCATING"):sub(1, c.w), white)
  local spin = ({ "|", "/", "-", "\\" })[((view.spin or 0) % 4) + 1]
  c:text(1, c.h, (spin .. " " .. tostring(view.state or ""):upper() .. "  ring " .. ring .. "  M"):sub(1, c.w), amber)
  if view.state == "waiting" then
    local bar = " ON STATION - G "
    c:text(math.max(1, math.floor((c.w - #bar) / 2)), math.floor(c.h / 2), bar, paper, amber)
  end
  return c
end

return M
