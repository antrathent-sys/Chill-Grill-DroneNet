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


-- ------------------------------------------------------------------ badge ---
-- The cog, drawn out by hand. A circle with spokes came out as a smudge at
-- this size - nine sub-pixels across leaves no room for an algorithm to be
-- clever in, so the shape is a bitmap and every pixel was chosen. 9 wide by 9
-- tall fills five cells across and three rows down, and the header line still
-- has room for the name.
M.BADGE = {
  "...XXX...",
  ".XXXXXXX.",
  ".XX.X.XX.",
  "XXXXXXXXX",
  "XX..X..XX",
  "XXXXXXXXX",
  ".XX.X.XX.",
  ".XXXXXXX.",
  "...XXX...",
}

function M.badge(c, x0, y0, ink)
  for row = 1, #M.BADGE do
    local line = M.BADGE[row]
    for col = 1, #line do
      if line:sub(col, col) == "X" then c:pix(x0 + col - 1, y0 + row - 1, ink) end
    end
  end
  return #M.BADGE[1]
end

-- ------------------------------------------------------------------ gauge ---
-- A terminal readout, not a dashboard. Imperial: bone on near-black, one red
-- for trouble, rules instead of boxes, everything in capitals with the labels
-- on the left and the values lined up under each other. The bar is segmented
-- because a solid bar looks like a modern progress spinner and a run of blocks
-- looks like a machine reporting.
M.WORDS = {
  calling = "REQUESTING UNIT",
  enroute = "UNIT INBOUND",
  waiting = "UNIT ON STATION",
  riding  = "IN TRANSIT",
  done    = "ARRIVED",
  failed  = "OPERATION ENDED",
}

local function ruleRow(c, y, slot)
  c:text(1, y, string.rep("-", c.w), slot)
end

-- A segmented bar: `cells` blocks with a gap between them, filled to frac.
local function segbar(c, x0, ypx, wpx, hpx, frac, ink, dim)
  frac = math.max(0, math.min(1, frac or 0))
  local seg, gap = 2, 1
  local n = math.floor((wpx + gap) / (seg + gap))
  local lit = math.floor(n * frac + 0.5)
  for i = 0, n - 1 do
    local col = (i < lit) and ink or dim
    for x = 0, seg - 1 do
      for y = 0, hpx - 1 do c:pix(x0 + i * (seg + gap) + x, ypx + y, col) end
    end
  end
  return n, lit
end

-- view as for M.map, plus:
--   start = the distance when this leg began, so the bar has something to fill
--   eta   = seconds left, or nil while it is still working that out
function M.gauge(D, c, view)
  local C = D.C
  local dim, bone, bright, red = C.dim, C.white, C.bright, C.red
  c:clear()
  local pw = c.w * 2
  local away = view.away
  local start = math.max(view.start or away or 1, 1)
  local frac = away and (1 - away / start) or 0
  if view.state == "waiting" or view.state == "done" then frac = 1 end
  local failed = view.state == "failed"

  -- header: the cog, who is serving you, and the unit
  M.badge(c, 1, 1, bone)
  c:text(7, 1, "CHILL GRILL", bone)
  c:text(7, 2, "AIR TAXI", dim)
  c:text(7, 3, tostring(view.unit or "NO UNIT"):upper():sub(1, c.w - 7), dim)
  ruleRow(c, 4, dim)
  c:text(1, 5, (M.WORDS[view.state] or "STANDING BY"):sub(1, c.w), failed and red or bright)

  -- Fixed rows, counted from the bottom, so the layout does not move when the
  -- number gains a digit. Derived rows put the ETA under the rule at three
  -- digits and hid it, which is exactly the sort of thing the desktop render
  -- is for.
  local rowBlocks = c.h - 7        -- the word under the digits
  local rowVector = c.h - 5        -- VECTOR and its bar
  local rowEta    = c.h - 3
  local rowRule   = c.h - 2
  local digits = away and tostring(math.floor(away)) or "----"
  local scale = (#digits <= 3) and 4 or 3
  c:text(1, 7, "RANGE", dim)
  local wpx = #digits * 4 * scale
  -- sit the digits on the line above BLOCKS, whatever their size
  c:bigText(math.max(1, pw - wpx - 2), (rowBlocks - 1) * 3 - 5 * scale + 1, digits, bone, scale)
  c:text(c.w - 5, rowBlocks, "BLOCKS", dim)

  c:text(1, rowVector, "VECTOR", dim)
  segbar(c, 3, rowVector * 3 + 1, pw - 6, 3, frac, bone, C.grid)

  c:text(1, rowEta, "ETA", dim)
  local left = view.eta and string.format("%d:%02d", math.floor(view.eta / 60), math.floor(view.eta % 60))
               or "--:--"
  if view.state == "waiting" then left = "ON STATION" end
  c:text(9, rowEta, left:upper(), bright)

  ruleRow(c, rowRule, dim)
  if view.state == "waiting" then
    c:text(1, c.h - 1, "BOARD, THEN PRESS G", bright)
  elseif failed then
    c:text(1, c.h - 1, tostring(view.detail or "NO UNIT AVAILABLE"):upper():sub(1, c.w), red)
  else
    c:text(1, c.h - 1, "M MAP    Q ABORT", dim)
  end
  -- a cursor that blinks where a terminal would leave one
  local spin = ({ "|", "/", "-", "\\" })[((view.spin or 0) % 4) + 1]
  c:text(1, c.h, (spin .. " " .. tostring(view.state or ""):upper()):sub(1, c.w), dim)
  if (view.spin or 0) % 2 == 0 then c:text(c.w, c.h, "_", bone) end
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
  local top, bot = 12, ph - 12                      -- room for a heading and a readout
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

  M.badge(c, 1, 1, white)
  c:text(7, 1, "CHILL GRILL", white)
  c:text(7, 2, tostring(view.unit or "NO UNIT"):upper():sub(1, c.w - 7), grey)
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
