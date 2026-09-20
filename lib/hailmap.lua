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
-- A bar of `n` cells wide filled to `frac`, drawn in sub-pixels so it moves in
-- steps of half a character rather than whole ones.
local function bar(c, x0, y0, wpx, hpx, frac, ink, edge)
  frac = math.max(0, math.min(1, frac or 0))
  for x = 0, wpx - 1 do
    c:pix(x0 + x, y0, edge)
    c:pix(x0 + x, y0 + hpx - 1, edge)
  end
  for y = 0, hpx - 1 do
    c:pix(x0, y + y0, edge)
    c:pix(x0 + wpx - 1, y + y0, edge)
  end
  local fill = math.floor((wpx - 4) * frac + 0.5)
  for x = 0, fill - 1 do
    for y = 2, hpx - 3 do c:pix(x0 + 2 + x, y0 + y, ink) end
  end
end

-- view as for M.map, plus:
--   start = the distance when the leg began, so the bar has something to fill
--   eta   = seconds left, or nil while it is still working that out
function M.gauge(D, c, view)
  local C = D.C
  local grey, white, amber, paper = C.dim, C.white, C.amber, C.bg
  c:clear()
  local pw = c.w * 2
  local away = view.away
  local start = math.max(view.start or away or 1, 1)
  local frac = away and (1 - away / start) or 0
  if view.state == "waiting" or view.state == "done" then frac = 1 end

  c:text(1, 1, ("TAXI " .. tostring(view.unit or "")):sub(1, c.w), amber)
  c:text(1, 2, (view.state == "riding" and "TAKING YOU THERE"
             or view.state == "waiting" and "YOUR TAXI IS HERE"
             or view.state == "enroute" and "ON ITS WAY TO YOU"
             or "CALLING"):sub(1, c.w), white)

  -- the number, as big as the screen allows
  local digits = away and tostring(math.floor(away)) or "--"
  local scale = (#digits <= 3) and 4 or 3
  local wpx = #digits * 4 * scale
  -- the digits sit in pixel rows 10..10+5*scale, so the word underneath has to
  -- clear them: at scale 4 that is text row 11, at scale 3 row 9
  c:bigText(math.max(1, math.floor((pw - wpx) / 2)), 10, digits, white, scale)
  local lastPx = 10 + 5 * scale - 1                  -- bottom pixel row of the digits
  c:text(math.max(1, math.floor((c.w - 6) / 2)), math.floor(lastPx / 3) + 2, "BLOCKS", grey)

  bar(c, 3, 40, pw - 6, 7, frac, amber, grey)

  local left = view.eta and string.format("%d:%02d left", math.floor(view.eta / 60), math.floor(view.eta % 60))
               or "working it out"
  if view.state == "waiting" then left = "PRESS G TO GO" end
  c:text(1, c.h - 1, left:sub(1, c.w), view.state == "waiting" and white or grey)
  local spin = ({ "|", "/", "-", "\\" })[((view.spin or 0) % 4) + 1]
  c:text(1, c.h, (spin .. " " .. tostring(view.state or ""):upper() .. "   M = map"):sub(1, c.w), amber)
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
  local top, bot = 9, ph - 12                      -- room for a heading and a readout
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

  local head = "TAXI"
  if view.unit then head = head .. " " .. view.unit end
  c:text(1, 1, head:sub(1, c.w), amber)
  c:text(1, c.h - 1, (view.away and string.format("%d blocks", math.floor(view.away)) or "locating"):sub(1, c.w), white)
  local spin = ({ "|", "/", "-", "\\" })[((view.spin or 0) % 4) + 1]
  c:text(1, c.h, (spin .. " " .. tostring(view.state or ""):upper() .. "  ring " .. ring .. "  M"):sub(1, c.w), amber)
  if view.state == "waiting" then
    local bar = " HERE - PRESS G "
    c:text(math.max(1, math.floor((c.w - #bar) / 2)), math.floor(c.h / 2), bar, paper, amber)
  end
  return c
end

return M
