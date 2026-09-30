--- depotscreens: a depot's two monitors (Alex, 2026-09-30).
--
--   HERO   3x3 blocks, text scale 0.5 (57x38)   the loader as built, face
--          on: the unit docked on top, the glass collar, a pillar each side,
--          the legs. Nothing moves: each silo is drawn where it is, and the
--          part at work flashes - placer window, belt, pusher, silo, the join
--          to the unit - with a lamp per side and one on the connector
--   ORDER  2x3 blocks portrait, text scale 0.5 (36x38)   the order in hand:
--          load or unload, which side, how many of what, where it is going,
--          which unit, every step ticked off as it happens, and today's counts
--
-- One state table drives both (M.new); depot.lua keeps it up to date from the
-- steps it already reports to the base (M.begin / M.step / M.finish), and
-- `depot screens demo` plays M.demo through every state. Layouts read their
-- size from the canvas; the pictogram scales to fit, so another size works,
-- only coarser.
--
-- Pure drawing onto a lib/display.lua canvas - no peripherals, no network -
-- so tools/test_depotscreens.lua renders every state on the desktop and
-- tools/preview_depot.py turns them into pictures.
--
--   local DV = dofile("lib/depotscreens.lua")
--   DV.applyPalette(mon)
--   DV.render("hero", canvas, state, os.clock())  canvas:flush(mon)

local M = {}

local floor, max, min, abs = math.floor, math.max, math.min, math.abs

-- colour roles -> blit digit; M.PALETTE says what each looks like. The control
-- room's steel, ice and amber, with a green for done.
M.K = {
  bg = "f", white = "0", lgrey = "8", grey = "7", dark = "b", ice = "3", iceDim = "9",
  amber = "1", amberDim = "c", red = "e", redDim = "a", green = "4", greenDim = "2",
  steel = "6", silver = "d", bright = "5",
}
local K = M.K

M.PALETTE = {
  f = 0x05070a, ["0"] = 0xf2f5f7, ["8"] = 0xa9b1b9, ["7"] = 0x5f6770, b = 0x1c2229,
  ["3"] = 0x9fdcf2, ["9"] = 0x2b5566, ["1"] = 0xffb02e, c = 0x5a3d0a, e = 0xe8342a,
  a = 0x5a1812, ["4"] = 0x5fd38a, ["2"] = 0x1d4a31, ["6"] = 0x7d858e, d = 0xc9d1d8,
  ["5"] = 0xffffff,
}

local HEX_COLOUR = {
  ["0"] = 1, ["1"] = 2, ["2"] = 4, ["3"] = 8, ["4"] = 16, ["5"] = 32, ["6"] = 64, ["7"] = 128,
  ["8"] = 256, ["9"] = 512, a = 1024, b = 2048, c = 4096, d = 8192, e = 16384, f = 32768,
}

function M.applyPalette(t)
  if not (t and t.setPaletteColour) then return false end
  for k, rgb in pairs(M.PALETTE) do pcall(t.setPaletteColour, HEX_COLOUR[k], rgb) end
  return true
end

-- ------------------------------------------------------------------ model

-- a job's steps, in order, as the two docks report them. The station loader
-- (lib/loader.lua) uses a few other names for the same things (M.ALIAS).
M.LOAD_STEPS = { "silo", "feed", "place", "assemble", "fill", "dock", "push", "stick", "retract", "done" }
M.UNLOAD_STEPS = { "push", "release", "retract", "empty", "done" }
M.ALIAS = { lift = "push", count = "fill", liftoff = "done" }
M.STEP_WORD = {
  silo = "CHECK BAY", feed = "COUNT FEED", place = "PLACE SILO", assemble = "ASSEMBLE",
  fill = "FILL", dock = "AWAIT UNIT", push = "PUSH UP", stick = "STICK", retract = "LOWER",
  release = "RELEASE", empty = "EMPTY", done = "DONE",
}
-- a step, in the header's words: what the dock is doing
M.DOING = {
  silo = "CHECKING BAY", feed = "COUNTING FEED", place = "PLACING SILO", assemble = "ASSEMBLING",
  fill = "LOADING", dock = "AWAITING UNIT", push = "PUSHING UP", stick = "STICKING", retract = "LOWERING",
  release = "RELEASING", empty = "UNLOADING", done = "DONE",
}
M.SIDES = { "A", "B" }

--- The side letter a dock's bay name stands for: A and B as they are; the
-- station loader's left and right are A and B.
function M.sideOf(name)
  name = tostring(name or ""):lower()
  if name == "a" or name == "left" then return "A" end
  if name == "b" or name == "right" then return "B" end
  return nil
end

--- What a depot calls itself on screen: depot-chid-1 -> CHID 1.
function M.nameOf(label)
  local s = tostring(label or "DEPOT"):gsub("^depot%-", ""):gsub("[-_]", " ")
  return s:upper()
end

function M.new(name)
  return { name = name or "DEPOT", sides = { A = { silo = "none" }, B = { silo = "none" } },
           counts = { loads = 0, unloads = 0, items = 0 }, job = nil, last = nil, unit = nil }
end

--- The base was heard from (any sealed message): the header shows it alive.
function M.heard(st, now) st.baseAt = now end

--- The unit this dock is working with: id, and "inbound", "docked" or nil.
function M.unit(st, id, state, now)
  if not id then st.unit = nil return end
  local carry = st.unit and st.unit.id == id and st.unit.carry or nil
  st.unit = { id = id, state = state or "docked", at = now, carry = carry }
end

--- The unit has gone, with whatever it was carrying.
function M.left(st) st.unit = nil end

--- A job starts. kind "load" or "unload"; sides: a letter, a bay name, or a
-- list of them; info: { id, items, item, dest, unit }.
function M.begin(st, kind, sides, info, now)
  info = info or {}
  local list = {}
  for _, s in ipairs(type(sides) == "table" and sides or { sides }) do
    local l = M.sideOf(s)
    if l then list[#list + 1] = l end
  end
  if #list == 0 then list = { "A" } end
  for _, s in ipairs(list) do st.sides[s].fault, st.sides[s].faultAt = nil, nil end
  st.job = { kind = kind == "unload" and "unload" or "load", sides = list, id = info.id, items = info.items,
             item = info.item, dest = info.dest, t0 = now, step = nil, stepAt = now, done = {}, moved = nil,
             text = nil }
  if info.unit then M.unit(st, info.unit, "docked", now) end
  if st.job.kind == "unload" then
    for _, s in ipairs(list) do st.sides[s].silo = "none" end
  end
end

-- what each step leaves in the bay, for the side(s) being worked
local SILO_AT = {
  load = { place = "placing", assemble = "assembling", fill = "filling", dock = "full", push = "lifting",
           stick = "up", retract = "gone", done = "none" },
  unload = { push = "reaching", release = "up", retract = "lowering", empty = "emptying", done = "empty" },
}

--- A step reported: moves the bays on, and ticks the one before off.
function M.step(st, step, text, now)
  local job = st.job
  if not job then return end
  step = M.ALIAS[step] or step
  if job.step and job.step ~= step then job.done[job.step] = true end
  -- the dock's own report says a waiting silo is already there
  if step == "silo" and type(text) == "string" then
    local full = text:find("filled", 1, true)
    local empty = text:find("empty silo", 1, true)
    for _, s in ipairs(job.sides) do
      if full then st.sides[s].silo = "full" elseif empty then st.sides[s].silo = "empty" end
    end
  end
  job.step, job.stepAt, job.text = step, now, text
  local n = type(text) == "string" and tonumber(text:match("^(%d+) items")) or nil
  if n then job.moved = n end
  if step == "feed" and type(text) == "string" then
    local f = tonumber(text:match("^(%d+) silo blocks"))
    if f then for _, s in ipairs(job.sides) do st.sides[s].feed = f end end
  end
  local set = SILO_AT[job.kind][step]
  if set then for _, s in ipairs(job.sides) do st.sides[s].silo = set end end
  if step == "dock" and st.unit then st.unit.state = "docked" end
end

--- The job ended: done, or called off (why).
function M.finish(st, ok, why, now)
  local job = st.job
  if not job then return end
  if job.step then job.done[job.step] = ok and true or nil end
  if ok then
    job.done.done = true
    job.step = "done"
    if job.kind == "load" then
      st.counts.loads = st.counts.loads + 1
      for _, s in ipairs(job.sides) do st.sides[s].silo = "none" end
      -- the silos went with the drone, and are drawn under it until it goes
      if st.unit then st.unit.carry = job.sides end
    else
      st.counts.unloads = st.counts.unloads + 1
      for _, s in ipairs(job.sides) do st.sides[s].silo = "empty" end
    end
    st.counts.items = st.counts.items + (job.moved or job.items or 0)
  else
    -- called off: what is in the bay now, as best it can be told
    local AFTER = { placing = "none", assembling = "empty", filling = "partial", lifting = "full", up = "full",
                    reaching = "none", lowering = "full", emptying = "partial" }
    for _, s in ipairs(job.sides) do
      local sd = st.sides[s]
      sd.fault, sd.faultAt = why or "called off", now
      sd.silo = AFTER[sd.silo] or sd.silo
    end
  end
  st.last = { kind = job.kind, sides = job.sides, id = job.id, items = job.moved or job.items, item = job.item,
              dest = job.dest, ok = ok and true or false, why = why, at = now, took = now - (job.t0 or now) }
  st.job = nil
end

-- ----------------------------------------------------------------- helpers

local function blink(now, rate) return floor((now or 0) * (rate or 2)) % 2 == 0 end

local function put(c, x, y, s, fg, bg)
  s = tostring(s)
  if x < 1 then s = s:sub(2 - x) x = 1 end
  if x > c.w or y < 1 or y > c.h then return end
  if x + #s - 1 > c.w then s = s:sub(1, c.w - x + 1) end
  c:text(x, y, s, fg, bg)
end

local function right(c, y, x1, s, fg, bg) put(c, x1 - #tostring(s) + 1, y, s, fg, bg) end
local function centre(c, y, x0, x1, s, fg, bg) put(c, x0 + floor((x1 - x0 + 1 - #tostring(s)) / 2), y, s, fg, bg) end

local function int(n)
  n = floor(tonumber(n) or 0)
  local s = tostring(abs(n))
  local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
  return (n < 0 and "-" or "") .. out
end

local function clock(secs)
  secs = max(0, floor(secs or 0))
  if secs >= 3600 then return string.format("%d:%02d:%02d", floor(secs / 3600), floor(secs / 60) % 60, secs % 60) end
  return string.format("%d:%02d", floor(secs / 60), secs % 60)
end
M.clock = clock

-- 3x5 letters and digits, scaled up in teletext pixels
local GLYPH = {
  A = "111101111101101", B = "110101110101110", C = "011100100100011", D = "110101101101110",
  E = "111100110100111", F = "111100110100100", G = "011100101101011", H = "101101111101101",
  I = "111010010010111", J = "001001001101010", K = "101101110101101", L = "100100100100111",
  M = "101111111101101", N = "110101101101101", O = "111101101101111", P = "110101110100100",
  Q = "010101101110011", R = "110101110101101", S = "011100010001110", T = "111010010010010",
  U = "101101101101111", V = "101101101101010", W = "101101111111101", X = "101101010101101",
  Y = "101101010010010", Z = "111001010100111",
  ["0"] = "111101101101111", ["1"] = "010110010010111", ["2"] = "111001111100111", ["3"] = "111001111001111",
  ["4"] = "101101111001001", ["5"] = "111100111001111", ["6"] = "111100111101111", ["7"] = "111001010010010",
  ["8"] = "111101111101111", ["9"] = "111101111001111", ["-"] = "000000111000000", ["."] = "000000000000010",
  [":"] = "000010000010000", ["/"] = "001001010100100", ["+"] = "000010111010000", [" "] = "000000000000000",
  [","] = "000000000010100",
}

--- Big text from the 3x5 font; each font pixel scale x scale teletext pixels.
-- Returns the width in pixels.
function M.big(c, px, py, s, col, scale)
  scale = scale or 2
  s = tostring(s):upper()
  local adv = 4 * scale
  for i = 1, #s do
    local g = GLYPH[s:sub(i, i)] or GLYPH[" "]
    for gy = 0, 4 do
      for gx = 0, 2 do
        if g:sub(gy * 3 + gx + 1, gy * 3 + gx + 1) == "1" then
          for sy = 0, scale - 1 do
            for sx = 0, scale - 1 do
              c:pix(px + (i - 1) * adv + gx * scale + sx, py + gy * scale + sy, col)
            end
          end
        end
      end
    end
  end
  return #s * adv - scale
end

-- pixel -> the cell it is in
local function cellX(px) return floor((px - 1) / 2) + 1 end
local function cellY(py) return floor((py - 1) / 3) + 1 end

-- a bar of cells: filled part in col, the rest in the dark
local function bar(c, x, y, n, frac, col)
  frac = max(0, min(1, frac or 0))
  local on = floor(n * frac + 0.5)
  c:fill(x, y, n, 1, K.dark)
  if on > 0 then c:fill(x, y, on, 1, col) end
end

-- ------------------------------------------------------------ the pictogram
-- The loader as built (Alex's screenshot, 2026-09-30), face on, in a 114 x 84
-- design box scaled to whatever area it is given: the unit (the rocket) docked
-- on top, the glass collar the silos are pushed up into, the body with a
-- pillar each side, and the legs. Side A is on the left, B on the right.
--
-- Nothing moves (Alex: "just flashing of different components"). A silo is
-- drawn where it is - in its bay, or up against the unit - and the part at
-- work flashes: the placer window, the belt, the pusher, the silo, the join
-- to the unit. The lamps say the rest.

local BOX_W, BOX_H = 114, 84
local BAY = { A = 45, B = 69 }        -- silo centre x
local SILO_W, SILO_H = 10, 14
local REST_TOP = 46                   -- a silo in its bay
local UP_TOP = 27                     -- ...and pushed up against the unit

local function painter(c, x0, y0, w, h)
  local s = min(w / BOX_W, h / BOX_H)
  local ox, oy = x0 + (w - BOX_W * s) / 2, y0 + (h - BOX_H * s) / 2
  local P = { s = s }
  function P.x(x) return floor(ox + x * s + 0.5) end
  function P.y(y) return floor(oy + y * s + 0.5) end
  function P.fill(xa, ya, xb, yb, col)
    for py = P.y(ya), P.y(yb) do
      for px = P.x(xa), P.x(xb) do c:pix(px, py, col) end
    end
  end
  function P.box(xa, ya, xb, yb, col, dotted)
    local X0, Y0, X1, Y1 = P.x(xa), P.y(ya), P.x(xb), P.y(yb)
    local on, per = dotted and 1 or nil, dotted and 2 or nil
    c:line(X0, Y0, X1, Y0, col, on, per)
    c:line(X0, Y1, X1, Y1, col, on, per)
    c:line(X0, Y0, X0, Y1, col, on, per)
    c:line(X1, Y0, X1, Y1, col, on, per)
  end
  return P
end

local function isActive(st, side)
  local job = st.job
  if job then for _, s in ipairs(job.sides) do if s == side then return true end end end
  return false
end

M.FAULT_SHOW = 120
local function faulted(sd, now) return sd.fault and now - (sd.faultAt or now) <= M.FAULT_SHOW end

-- a flashing part: `on` colour half the time, `off` the rest
local function flash(now, on, off) return blink(now, 2) and on or off end

-- the unit on top: "docked", "inbound" (its outline, flashing) or nil (its
-- place, dotted)
local function drawRocket(P, how, now)
  if not how then
    P.box(46, 5, 68, 24, K.grey, true)
    P.box(50, 1, 64, 4, K.grey, true)
    return
  end
  if how == "docked" then
    P.fill(50, 1, 64, 4, K.iceDim)
    P.fill(46, 5, 68, 24, K.iceDim)
    P.fill(40, 19, 45, 24, K.steel)
    P.fill(69, 19, 74, 24, K.steel)
    P.box(46, 5, 68, 24, K.ice)
    P.box(50, 1, 64, 4, K.ice)
  elseif blink(now, 2) then
    P.box(46, 5, 68, 24, K.amber)
    P.box(50, 1, 64, 4, K.amber)
    P.box(40, 19, 45, 24, K.amber)
    P.box(69, 19, 74, 24, K.amber)
  end
end

-- the glass collar and the connector column's lamp: red with nothing
-- latched, flashing amber while one is awaited, green when latched
local function drawCollar(P, st, how, now)
  P.box(38, 26, 76, 42, K.iceDim)
  P.fill(55, 26, 59, 42, K.grey)
  local lamp = K.red
  if st.job and st.job.step == "dock" then lamp = flash(now, K.amber, K.amberDim)
  elseif how == "docked" then lamp = K.green
  elseif how == "inbound" then lamp = K.amber end
  P.fill(56, 32, 58, 35, lamp)
end

-- the body and legs; each pillar's lamp shows its side
local function drawBody(P, st, now)
  P.fill(20, 43, 94, 44, K.steel)
  P.fill(55, 45, 59, 65, K.dark)
  P.fill(20, 66, 94, 68, K.dark)
  P.fill(23, 69, 31, 74, K.steel)
  P.fill(83, 69, 91, 74, K.steel)
  P.fill(26, 75, 28, 81, K.grey)
  P.fill(86, 75, 88, 81, K.grey)
  P.fill(51, 69, 52, 81, K.grey)
  P.fill(62, 69, 63, 81, K.grey)
  for _, side in ipairs(M.SIDES) do
    local x0 = side == "A" and 20 or 87
    local sd = st.sides[side] or {}
    P.fill(x0, 45, x0 + 7, 68, K.dark)
    P.box(x0, 45, x0 + 7, 68, K.steel)
    local lamp = K.grey
    if faulted(sd, now) then lamp = flash(now, K.red, K.redDim)
    elseif isActive(st, side) then lamp = K.amber
    elseif sd.silo == "full" then lamp = K.green end
    P.fill(x0 + 2, 57, x0 + 5, 61, lamp)
  end
end

-- silos the unit carries away after a load
local function drawCarried(P, st)
  for _, side in ipairs(st.unit and st.unit.carry or {}) do
    local cx = BAY[side]
    P.fill(cx - SILO_W / 2 + 1, UP_TOP + 1, cx + SILO_W / 2 - 1, UP_TOP + SILO_H - 2, K.amberDim)
    P.box(cx - SILO_W / 2, UP_TOP, cx + SILO_W / 2, UP_TOP + SILO_H - 1, K.ice)
  end
end

-- one silo: top y, how full (0..1), outline colour, fill colour
local function drawSilo(P, cx, top, full, col, fillCol)
  local x0, x1 = cx - SILO_W / 2, cx + SILO_W / 2
  local y1 = top + SILO_H - 1
  if full and full > 0 then
    local h = floor((SILO_H - 2) * min(1, full) + 0.5)
    if h > 0 then P.fill(x0 + 1, y1 - h, x1 - 1, y1 - 1, fillCol or K.amber) end
  end
  P.box(x0, top, x1, y1, col)
end

local UP = { lifting = true, up = true, gone = true, reaching = true }

local function drawBay(P, st, side, now)
  local cx = BAY[side]
  local sd = st.sides[side] or {}
  local job = st.job
  local active = isActive(st, side)
  local step = active and job.step or nil
  local silo = sd.silo or "none"
  local bad = faulted(sd, now)

  -- the placer's window: flashes while it counts its feed and places
  local wx0 = side == "A" and 30 or 77
  local placing = step == "silo" or step == "feed" or step == "place"
  P.fill(wx0 + 1, 48, wx0 + 6, 55, placing and flash(now, K.amber, K.amberDim) or K.amberDim)
  P.box(wx0, 47, wx0 + 7, 56, placing and K.amber or K.steel)

  -- the belt between the pillar and the bay: flashes while items move
  local bx0 = side == "A" and 28 or cx + SILO_W / 2 + 1
  local bx1 = side == "A" and cx - SILO_W / 2 - 1 or 86
  local moving = step == "fill" or step == "empty"
  P.fill(bx0, 61, bx1, 62, moving and flash(now, K.amber, K.amberDim) or K.grey)

  -- the pusher, and its rod while a silo is up on it
  local pushing = step == "push" or step == "retract" or step == "release"
  P.fill(cx - 3, 63, cx + 3, 65, pushing and flash(now, K.amber, K.amberDim) or K.steel)
  if silo == "lifting" or silo == "up" or silo == "reaching" then
    P.fill(cx - 1, UP_TOP + SILO_H, cx, 62, K.silver)
  end

  -- the silo, where it is
  local fill = 0
  if silo == "full" or silo == "lifting" or silo == "up" or silo == "lowering" or silo == "reaching" then fill = 1 end
  if silo == "partial" then fill = 0.4 end
  if silo == "filling" or silo == "emptying" then
    local items, moved = job and job.items, job and job.moved
    local done = (items and moved and items > 0) and (moved / items) or 0.5
    fill = silo == "filling" and done or (1 - done)
  end
  local top = UP[silo] and UP_TOP or REST_TOP
  if silo == "none" or silo == "gone" then
    P.box(cx - SILO_W / 2, REST_TOP, cx + SILO_W / 2, REST_TOP + SILO_H - 1, bad and flash(now, K.red, K.dark) or K.dark)
    if silo == "gone" then drawSilo(P, cx, UP_TOP, 1, K.ice, K.amberDim) end
  else
    local col = K.steel
    if silo == "full" or silo == "up" then col = K.silver end
    if silo == "placing" then col = flash(now, K.amber, K.steel) end
    if silo == "assembling" then col = flash(now, K.bright, K.iceDim) end
    if silo == "reaching" or silo == "lifting" or silo == "up" then col = K.ice end
    if bad then col = flash(now, K.red, K.redDim) end
    drawSilo(P, cx, top, fill, col, K.amber)
  end

  -- sticking or letting go: the join with the unit flashes
  if (step == "stick" or step == "release") and blink(now, 2) then
    P.fill(cx - 5, 25, cx + 5, 26, step == "stick" and K.green or K.amber)
  end
end

-- ------------------------------------------------------------------- HERO

local function sideWord(st, side, now)
  local sd = st.sides[side] or {}
  local job = st.job
  local active = false
  if job then for _, s in ipairs(job.sides) do if s == side then active = true end end end
  if faulted(sd, now) then return "FAULT", K.red end
  if active then
    local w = M.DOING[job.step or ""] or (job.kind == "unload" and "UNLOADING" or "LOADING")
    if job.step == "dock" then return "AWAITING UNIT", K.amber end
    return w, K.amber
  end
  local silo = sd.silo or "none"
  if silo == "full" then return "SILO FULL", K.silver end
  if silo == "partial" then return "PART FILLED", K.amber end
  if silo == "empty" then return "EMPTY SILO", K.lgrey end
  return "NO SILO", K.grey
end

local function status(st, now)
  local job = st.job
  if job then
    local w = M.DOING[job.step or ""] or (job.kind == "unload" and "UNLOADING" or "LOADING")
    if job.step == nil then w = job.kind == "unload" and "UNLOADING" or "LOADING" end
    return w .. " " .. table.concat(job.sides, "+"), K.amber
  end
  if st.last and not st.last.ok and now - (st.last.at or 0) < 60 then return "CALLED OFF", K.red end
  if st.last and st.last.ok and now - (st.last.at or 0) < 20 then
    return (st.last.kind == "unload" and "UNLOADED " or "LOADED ") .. table.concat(st.last.sides or {}, "+"), K.green
  end
  if st.unit and st.unit.state == "inbound" then return "UNIT INBOUND", K.ice end
  return "STANDING BY", K.lgrey
end

local function baseLink(st, now)
  if not st.baseAt then return "BASE --", K.grey end
  if now - st.baseAt <= (M.BASE_STALE or 30) then return "BASE OK", K.green end
  return "BASE LOST", K.red
end
M.BASE_STALE = 30

function M.drawHero(c, st, now)
  now = now or 0
  local w, h = c.w, c.h
  -- header
  c:fill(1, 1, w, 1, K.dark)
  put(c, 2, 1, st.name, K.white, K.dark)
  put(c, 3 + #st.name, 1, "DEPOT", K.lgrey, K.dark)
  local word, wcol = status(st, now)
  local dot = st.job and blink(now, 2) and "\7 " or "  "
  right(c, 1, w - 1, dot .. word, wcol, K.dark)

  -- the pictogram, between the header and the strip at the bottom
  local strip = 7
  local top, bottom = 2, h - strip - 1
  local P = painter(c, 1, top * 3 + 1, w * 2, (bottom - top) * 3)
  local how = st.unit and (st.unit.state == "docked" and "docked" or "inbound") or nil
  drawBody(P, st, now)
  drawCollar(P, st, how, now)
  drawRocket(P, how, now)
  for _, side in ipairs(M.SIDES) do drawBay(P, st, side, now) end
  if how == "docked" then drawCarried(P, st) end
  -- the side letters, big, out beyond each pillar
  local ls = max(1, floor(3 * P.s + 0.5))
  for _, side in ipairs(M.SIDES) do
    local sd = st.sides[side]
    local col = faulted(sd, now) and K.red or (isActive(st, side) and K.amber or K.lgrey)
    M.big(c, P.x(side == "A" and 9 or 105) - floor(1.5 * ls), P.y(46), side, col, ls)
  end
  if not how then centre(c, cellY(P.y(14)), 1, w, "NO UNIT", K.grey) end
  if how == "inbound" then centre(c, cellY(P.y(14)), 1, w, "UNIT INBOUND", K.amber) end

  -- the strip: one panel per side, and the unit and the base underneath
  local y0 = h - strip + 1
  for x = 1, w do c:text(x, y0 - 1, "\140", K.dark) end
  local half = floor(w / 2)
  for i, side in ipairs(M.SIDES) do
    local x0 = i == 1 and 2 or half + 2
    local x1 = i == 1 and half - 1 or w - 1
    local sd = st.sides[side]
    local sw, scol = sideWord(st, side, now)
    put(c, x0, y0, "SIDE " .. side, K.white)
    right(c, y0, x1, sw, scol)
    local job = st.job
    local active = false
    if job then for _, s in ipairs(job.sides) do if s == side then active = true end end end
    local detail, frac, fcol
    if active and (job.step == "fill" or job.step == "empty") then
      local n, of = job.moved, job.items
      detail = (n and of) and string.format("%s / %s items", int(n), int(of))
               or (of and (int(of) .. " items") or "items moving")
      frac = (n and of and of > 0) and (n / of) or ((now / 8) % 1)
      fcol = K.amber
    elseif active then
      detail = M.STEP_WORD[job.step or ""] or ""
      local list = job.kind == "unload" and M.UNLOAD_STEPS or M.LOAD_STEPS
      local k = 0
      for j, s in ipairs(list) do if s == job.step then k = j end end
      frac, fcol = k / #list, K.ice
    else
      local silo = sd.silo or "none"
      detail = silo == "full" and "loaded, waiting" or (silo == "empty" and "ready to fill")
               or (silo == "partial" and "part filled - check it") or "bay clear"
      if faulted(sd, now) then detail = tostring(sd.fault) end
      frac, fcol = 0, K.grey
    end
    put(c, x0, y0 + 1, tostring(detail):sub(1, x1 - x0 + 1), K.lgrey)
    bar(c, x0, y0 + 2, x1 - x0 + 1, frac, fcol)
    local feed = sd.feed and string.format("feed %d = %d load%s", sd.feed, floor(sd.feed / 3), floor(sd.feed / 3) == 1 and "" or "s")
                 or "feed --"
    put(c, x0, y0 + 3, feed, sd.feed and sd.feed < 3 and K.red or K.grey)
  end
  -- unit and base
  local uy = h
  c:fill(1, uy, w, 1, K.dark)
  local u = st.unit
  put(c, 2, uy, "UNIT", K.grey, K.dark)
  if u then
    put(c, 7, uy, u.id:upper(), K.white, K.dark)
    put(c, 8 + #u.id, uy, u.state:upper(), u.state == "docked" and K.ice or K.amber, K.dark)
  else
    put(c, 7, uy, "NONE", K.grey, K.dark)
  end
  local bw, bcol = baseLink(st, now)
  right(c, uy, w - 1, bw, bcol, K.dark)
end

-- ------------------------------------------------------------------ ORDER

function M.drawOrder(c, st, now)
  now = now or 0
  local w, h = c.w, c.h
  local job = st.job
  c:fill(1, 1, w, 1, K.dark)
  put(c, 2, 1, "ORDER", K.white, K.dark)
  right(c, 1, w - 1, job and job.id and tostring(job.id):upper() or st.name, job and K.amber or K.lgrey, K.dark)

  if not job then
    -- standing by: the last order, and the day so far
    M.big(c, 5, 8, "STANDBY", K.lgrey, 2)
    put(c, 3, 8, "", K.grey)
    local l = st.last
    local y = 12
    put(c, 3, y, "NO ORDER IN HAND", K.grey)
    if l then
      y = y + 2
      put(c, 3, y, "LAST", K.grey)
      put(c, 9, y, (l.id and tostring(l.id):upper() or "") , K.lgrey)
      put(c, 3, y + 1, string.format("%s %s", l.kind == "unload" and "UNLOAD" or "LOAD", table.concat(l.sides or {}, "+")), K.white)
      if l.items then put(c, 3, y + 2, int(l.items) .. " " .. (l.item and l.item:upper() or "ITEMS"), K.lgrey) end
      if l.ok then
        put(c, 3, y + 3, "DONE IN " .. clock(l.took) .. ", " .. clock(now - l.at) .. " AGO", K.green)
      else
        put(c, 3, y + 3, "CALLED OFF", K.red)
        local why, row = tostring(l.why or ""), y + 4
        while #why > 0 and row <= y + 6 do
          local cut = #why <= w - 4 and #why or (why:sub(1, w - 3):match("^.*() ") or (w - 3))
          put(c, 3, row, why:sub(1, cut - (cut < #why and 1 or 0)), K.lgrey)
          why, row = why:sub(cut + 1), row + 1
        end
      end
    end
    -- the bays, ready or not
    local by = h - 11
    for x = 2, w - 1 do c:text(x, by, "`", K.dark) end
    put(c, 3, by, " BAYS ", K.grey)
    for i, side in ipairs(M.SIDES) do
      local sd = st.sides[side]
      local sw, scol = sideWord(st, side, now)
      put(c, 3, by + i, side, K.white)
      put(c, 5, by + i, sw, scol)
      local feed = sd.feed and ("FEED " .. sd.feed) or "FEED --"
      right(c, by + i, w - 2, feed .. ((sd.feed and sd.feed < 3) and " LOW" or ""), (sd.feed and sd.feed < 3) and K.red or K.grey)
    end
  else
    -- what it is: LOAD or UNLOAD, big, and the side
    local kind = job.kind == "unload" and "UNLOAD" or "LOAD"
    local kw = M.big(c, 5, 7, kind, K.amber, 2)
    local side = table.concat(job.sides, "")
    local ss = 3
    if w * 2 - 4 - (#side * 4 * ss - ss) < 5 + kw + 4 then ss = 2 end
    local sx = w * 2 - 4 - (#side * 4 * ss - ss)
    M.big(c, sx, 8, side, K.white, ss)
    put(c, cellX(sx), 2, #job.sides > 1 and "SIDES" or "SIDE", K.grey)
    local y = 8
    -- how many of what
    put(c, 3, y, "ITEMS", K.grey)
    if job.items then
      M.big(c, 5, (y) * 3 + 2, int(job.items):gsub(",", ""), K.white, 2)
      if job.item then put(c, 3, y + 5, tostring(job.item):upper():sub(1, w - 4), K.lgrey) end
    else
      put(c, 3, y + 2, "COUNTING AT THE INTAKE", K.lgrey)
    end
    local moving = job.step == "fill" or job.step == "empty"
    if job.items or job.moved then
      local n = job.moved or 0
      local frac = (job.items and job.items > 0) and (n / job.items) or 0
      bar(c, 3, y + 6, w - 12, frac, moving and K.amber or K.ice)
      right(c, y + 6, w - 2, job.items and string.format("%d%%", floor(100 * frac + 0.5)) or int(n), K.lgrey)
    end
    y = y + 8
    put(c, 3, y, job.kind == "unload" and "FROM" or "TO", K.grey)
    put(c, 9, y, job.dest and tostring(job.dest):upper() or "--", K.white)
    put(c, 3, y + 1, "UNIT", K.grey)
    local u = st.unit
    if u then
      put(c, 9, y + 1, u.id:upper(), K.white)
      put(c, 10 + #u.id, y + 1, u.state:upper(), u.state == "docked" and K.ice or K.amber)
    else
      put(c, 9, y + 1, "NONE", K.grey)
    end
    -- the sequence
    y = y + 3
    for x = 2, w - 1 do c:text(x, y, "\140", K.dark) end
    put(c, 3, y, " SEQUENCE ", K.grey)
    right(c, y, w - 2, " T+" .. clock(now - (job.t0 or now)) .. " ", K.lgrey)
    local list = job.kind == "unload" and M.UNLOAD_STEPS or M.LOAD_STEPS
    for i, s in ipairs(list) do
      local ry = y + i
      if ry > h - 4 then break end
      local mark, col
      if s == job.step then
        mark, col = blink(now, 2) and "\16" or " ", K.amber
        right(c, ry, w - 2, clock(now - (job.stepAt or now)), K.amber)
      elseif job.done[s] then
        mark, col = "\4", K.green
      else
        mark, col = "\7", K.grey
      end
      put(c, 3, ry, mark, col)
      put(c, 5, ry, M.STEP_WORD[s] or s:upper(), s == job.step and K.white or (job.done[s] and K.lgrey or K.grey))
    end
  end

  -- the day, at the foot
  local fy = h - 2
  for x = 2, w - 1 do c:text(x, fy - 1, "\140", K.dark) end
  put(c, 3, fy - 1, " TODAY ", K.grey)
  put(c, 3, fy, "LOADS", K.grey)
  put(c, 9, fy, tostring(st.counts.loads), K.white)
  put(c, 13, fy, "UNLOADS", K.grey)
  put(c, 21, fy, tostring(st.counts.unloads), K.white)
  put(c, 3, fy + 1, "ITEMS", K.grey)
  put(c, 9, fy + 1, int(st.counts.items), K.white)
  local said = job and job.text
  if said then
    c:fill(1, h, w, 1, K.dark)
    put(c, 2, h, tostring(said):sub(1, w - 2), K.lgrey, K.dark)
  end
end

function M.render(name, c, st, now)
  c:clear()
  if name == "order" then M.drawOrder(c, st, now) else M.drawHero(c, st, now) end
end

-- ------------------------------------------------------------------- demo
-- Every state in turn, on a loop: standing by, a unit inbound, a load on side
-- A step by step, a two-sided unload, a load called off. demo(t) -> state.

local DEMO = {
  { at = 0, fn = function(st, t) M.heard(st, t) end },
  { at = 4, fn = function(st, t) M.unit(st, "drone-1", "inbound", t) end },
  { at = 10, fn = function(st, t)
      M.begin(st, "load", "A", { id = "L-0042", items = 640, item = "Cobblestone", dest = "Kodiak", unit = "drone-1" }, t)
      M.step(st, "silo", "no silo on side A", t) end },
  { at = 12, fn = function(st, t) M.step(st, "feed", "9 silo blocks in the feed", t) end },
  { at = 14, fn = function(st, t) M.step(st, "place", "placing a silo on side A", t) end },
  { at = 18, fn = function(st, t) M.step(st, "assemble", "assembling it", t) end },
  { at = 22, fn = function(st, t) M.step(st, "fill", "filling 640 items", t) end },
  { at = 24, fn = function(st, t) M.step(st, "fill", "160 items in", t) end },
  { at = 26, fn = function(st, t) M.step(st, "fill", "352 items in", t) end },
  { at = 28, fn = function(st, t) M.step(st, "fill", "544 items in", t) end },
  { at = 30, fn = function(st, t) M.step(st, "fill", "640 items in", t) end },
  { at = 31, fn = function(st, t) M.step(st, "dock", "waiting for the drone to latch", t) end },
  { at = 34, fn = function(st, t) M.step(st, "push", "pusher up", t) end },
  { at = 38, fn = function(st, t) M.step(st, "stick", "the drone sticks the silo", t) end },
  { at = 41, fn = function(st, t) M.step(st, "retract", "pusher down", t) end },
  { at = 45, fn = function(st, t) st.sides.A.feed = 6 M.finish(st, true, nil, t) end },
  { at = 50, fn = function(st, t) M.left(st) end },
  { at = 52, fn = function(st, t) M.unit(st, "drone-2", "inbound", t) end },
  { at = 56, fn = function(st, t)
      M.begin(st, "unload", { "A", "B" }, { id = "U-0017", items = 2560, item = "Iron Ingot", dest = "CHI", unit = "drone-2" }, t)
      M.step(st, "push", "pusher up, under the drone's silo", t) end },
  { at = 60, fn = function(st, t) M.step(st, "release", "the drone lets go", t) end },
  { at = 63, fn = function(st, t) M.step(st, "retract", "pusher down", t) end },
  { at = 67, fn = function(st, t) M.step(st, "empty", "emptying 2560 items into storage", t) end },
  { at = 70, fn = function(st, t) M.step(st, "empty", "1024 items out", t) end },
  { at = 73, fn = function(st, t) M.step(st, "empty", "2048 items out", t) end },
  { at = 76, fn = function(st, t) M.step(st, "empty", "2560 items out", t) end },
  { at = 77, fn = function(st, t) M.finish(st, true, nil, t) end },
  { at = 82, fn = function(st, t)
      M.begin(st, "load", "B", { id = "L-0043", items = 320, item = "Oak Log", dest = "Market", unit = "drone-2" }, t)
      M.step(st, "silo", "an empty silo is waiting on side B", t) end },
  { at = 84, fn = function(st, t) M.step(st, "fill", "filling 320 items", t) end },
  { at = 89, fn = function(st, t) M.finish(st, false, "nothing left the storage in 20 s - is it empty?", t) end },
  { at = 96, fn = function(st, t) M.left(st) end },
}
M.DEMO_LOOP = 100

function M.demo(t, name)
  t = t % M.DEMO_LOOP
  local st = M.new(name or "CHID 1")
  st.sides.A.feed, st.sides.B.feed = 9, 2
  for _, e in ipairs(DEMO) do
    if e.at <= t then e.fn(st, e.at) end
  end
  st.baseAt = t
  return st
end

return M
