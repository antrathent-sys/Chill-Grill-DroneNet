-- hailmap: the little map a customer watches while their taxi comes.
--
-- Pure drawing onto a lib/display.lua canvas, so the pocket terminal and
-- tools/preview_pocket.py draw exactly the same picture and the one on the
-- desktop can be trusted.
--
-- The customer is always the middle. The scale follows the distance, so the
-- taxi stays on screen and the map zooms in as it closes. Rings are round
-- numbers; the footer says which. A 26x20 pocket screen is 52x60 sub-pixels,
-- which is enough for a bearing, a distance and a tail, and not enough for
-- anything clever - so there is nothing clever here.

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

-- view = { from = {x,z}, drone = {x,z} or nil, trail = {...}, away = blocks,
--          state = "enroute"|..., unit = "drone-1", spin = n, dest = {x,z} }
function M.draw(D, c, view)
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
  c:text(1, c.h, (spin .. " " .. tostring(view.state or ""):upper() .. "   ring " .. ring):sub(1, c.w), amber)
  if view.state == "waiting" then
    local bar = " HERE - PRESS G "
    c:text(math.max(1, math.floor((c.w - #bar) / 2)), math.floor(c.h / 2), bar, paper, amber)
  end
  return c
end

return M
