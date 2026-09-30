--- depotscreens: a depot's two monitors (Alex, 2026-09-30).
--
--   HERO   3x3 blocks, text scale 0.5 (57x38)   the loader as built, face
--          on - the unit docked on top, the glass collar, a pillar each side,
--          the legs - as a line schematic. Nothing moves: each silo is drawn
--          where it is, and the part at work flashes. Under it, one column
--          per side: what it is doing, items, silo stock.
--   ORDER  2x3 blocks portrait, text scale 0.5 (36x38)   the order in hand:
--          its number (C-0042, flight .1 - ORDERS.md), load or unload, which
--          side, how many of what, where it goes, which unit, every step
--          ticked off as it happens, and today's counts.
--
-- The look is the fleet's own, lib/tui.lua: its palette and colour roles
-- (dark red for anything live, rust for attention, muted green for done,
-- three greys for everything else), bands for sections, the CINDER header,
-- the block faces for headlines. M.use(tui) hands it over; depot.lua does.
--
-- One state table drives both (M.new); depot.lua keeps it up to date from the
-- steps it already reports to the base (M.begin / M.step / M.finish), and
-- `depot screens demo` plays M.demo through every state. Pure drawing onto a
-- lib/display.lua canvas - tools/test_depotscreens.lua renders every state on
-- the desktop, tools/preview_depot.py makes pictures of them.

local M = {}

local floor, max, min, abs = math.floor, math.max, math.min, math.abs

local T                                -- lib/tui.lua, from M.use
function M.use(tui) T = tui end
local function tui()
  if not T then T = dofile("lib/tui.lua") end
  return T
end

function M.applyPalette(t) return tui().apply(t) end

-- ------------------------------------------------------------------ model

-- a job's steps, in order, as the two docks report them. The station loader
-- (lib/loader.lua) uses a few other names for the same things (M.ALIAS).
M.LOAD_STEPS = { "silo", "feed", "place", "assemble", "fill", "invoice", "dock", "push", "stick", "retract", "done" }
M.UNLOAD_STEPS = { "push", "release", "retract", "empty", "done" }
M.ALIAS = { lift = "push", count = "fill", liftoff = "done" }
M.STEP_WORD = {
  silo = "CHECK BAY", feed = "CHECK SILO STOCK", place = "PLACE SILO", assemble = "ASSEMBLE",
  fill = "FILL", invoice = "PRINT INVOICE", dock = "AWAIT UNIT", push = "PUSH UP", stick = "STICK", retract = "LOWER",
  release = "RELEASE", empty = "EMPTY", done = "COMPLETE",
}
-- a step, as what the dock is doing
M.DOING = {
  silo = "CHECKING BAY", feed = "CHECKING STOCK", place = "PLACING SILO", assemble = "ASSEMBLING",
  fill = "LOADING", invoice = "PRINTING INVOICE", dock = "AWAITING UNIT", push = "PUSHING UP", stick = "STICKING", retract = "LOWERING",
  release = "RELEASING", empty = "UNLOADING", done = "COMPLETE",
}
M.SIDES = { "A", "B" }
M.SILO_BLOCKS = 3                      -- silo blocks one payload takes (lib/dockseq.lua)

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

--- A load id as the order and its flight: "C-0042.1" -> "C-0042", 1. Any
-- other id is its own order number, with no flight.
function M.orderOf(id)
  id = tostring(id or "")
  local order, flight = id:match("^(%u%-%d+)%.(%d+)$")
  if order then return order, tonumber(flight) end
  return id ~= "" and id:upper() or nil, nil
end

function M.new(name)
  return { name = name or "DEPOT", sides = { A = { silo = "none" }, B = { silo = "none" } },
           counts = { loads = 0, unloads = 0, items = 0 }, job = nil, last = nil, unit = nil }
end

--- The base was heard from (any sealed message): the base link shows alive.
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
-- list of them; info: { id, items, item, dest, unit, shipments } - id is the
-- load id ("C-0042.1"), shipments what this flight carries ("1-2 OF 3").
function M.begin(st, kind, sides, info, now)
  info = info or {}
  local list = {}
  for _, s in ipairs(type(sides) == "table" and sides or { sides }) do
    local l = M.sideOf(s)
    if l then list[#list + 1] = l end
  end
  if #list == 0 then list = { "A" } end
  for _, s in ipairs(list) do st.sides[s].fault, st.sides[s].faultAt = nil, nil end
  local order, flight = M.orderOf(info.id)
  st.job = { kind = kind == "unload" and "unload" or "load", sides = list, id = info.id, order = order,
             flight = flight, shipments = info.shipments, items = info.items, item = info.item, dest = info.dest,
             t0 = now, step = nil, stepAt = now, done = {}, moved = nil, text = nil }
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
      -- the silos went with the unit, and are drawn on it until it goes
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
  st.last = { kind = job.kind, sides = job.sides, id = job.id, order = job.order, flight = job.flight,
              items = job.moved or job.items, item = job.item, dest = job.dest, ok = ok and true or false,
              why = why, at = now, took = now - (job.t0 or now) }
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

local function cellY(py) return floor((py - 1) / 3) + 1 end

-- a band across cells x0..x1 of row y: the panel colour, a label at the left
-- and a value at the right (lib/tui.lua's band, for part of a row)
local function band(c, y, x0, x1, left, rightText, leftInk, rightInk)
  local C = tui().C
  c:text(x0, y, string.rep(" ", x1 - x0 + 1), C.faint, C.panel)
  if left then put(c, x0 + 1, y, tostring(left):upper():sub(1, x1 - x0 - 1), leftInk or C.faint, C.panel) end
  if rightText then right(c, y, x1 - 1, tostring(rightText):sub(1, x1 - x0 - 1), rightInk or C.text, C.panel) end
end

-- the fleet's slim header: CINDER, a hairline, and what this screen is
local function header(c, label)
  local C = tui().C
  local w = c.w
  label = tostring(label):upper()
  put(c, 1, 1, "CINDER", C.text)
  local lx = w - #label + 1
  put(c, lx, 1, label, C.faint)
  if lx - 2 >= 8 then c:line(15, 2, (lx - 2) * 2, 2, C.rule) end
end

M.FAULT_SHOW = 120
local function faulted(sd, now) return sd.fault and now - (sd.faultAt or now) <= M.FAULT_SHOW end

local function isActive(st, side)
  local job = st.job
  if job then for _, s in ipairs(job.sides) do if s == side then return true end end end
  return false
end

-- silo stock at a side's placer, in words: blocks, and the payloads they make
local function stock(sd)
  if not sd.feed then return "SILO STOCK --", false end
  local loads = floor(sd.feed / M.SILO_BLOCKS)
  if loads == 0 then return string.format("SILO STOCK %d - NEEDS %d", sd.feed, M.SILO_BLOCKS), true end
  return string.format("SILO STOCK %d = %d LOAD%s", sd.feed, loads, loads == 1 and "" or "S"), false
end

-- ------------------------------------------------------------ the pictogram
-- The loader as built (Alex's screenshot, 2026-09-30), face on, as a line
-- schematic in a 114 x 84 design box, scaled to the area it is given: the
-- unit docked on top, the glass collar the silos are pushed up into, the body
-- with a pillar each side, the legs. Side A left, B right. Structure in the
-- rule grey; the part at work flashes dark red; a filled silo is solid grey;
-- rust for a fault.

local BOX_W, BOX_H = 114, 84
local BAY = { A = 45, B = 69 }        -- silo centre x
local SILO_W, SILO_H = 10, 14
local REST_TOP = 46                   -- a silo in its bay
local UP_TOP = 27                     -- ...and pushed up against the unit
local UP = { lifting = true, up = true, gone = true, reaching = true }

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
  function P.line(xa, ya, xb, yb, col, dotted)
    c:line(P.x(xa), P.y(ya), P.x(xb), P.y(yb), col, dotted and 1 or nil, dotted and 2 or nil)
  end
  function P.box(xa, ya, xb, yb, col, dotted)
    P.line(xa, ya, xb, ya, col, dotted)
    P.line(xa, yb, xb, yb, col, dotted)
    P.line(xa, ya, xa, yb, col, dotted)
    P.line(xb, ya, xb, yb, col, dotted)
  end
  return P
end

local function drawPicture(c, st, now, P)
  local C = tui().C
  local live = function(on) return on and (blink(now, 2) and C.accent or C.rule) or C.rule end
  local how = st.unit and (st.unit.state == "docked" and "docked" or "inbound") or nil

  -- the unit on top: docked, inbound (flashing), or its place (dotted)
  local ucol, dotted = C.faint, false
  if not how then ucol, dotted = C.panel, true
  elseif how == "inbound" then ucol = blink(now, 2) and C.accent or nil end
  if ucol then
    P.box(50, 1, 64, 4, ucol, dotted)
    P.box(46, 5, 68, 24, ucol, dotted)
    if not dotted then
      P.box(40, 18, 45, 24, ucol)
      P.box(69, 18, 74, 24, ucol)
    end
  end
  -- the glass collar and the connector's lamp: lit when latched, flashing
  -- while one is awaited
  P.box(38, 26, 76, 42, C.panel)
  P.line(55, 26, 55, 42, C.panel)
  P.line(59, 26, 59, 42, C.panel)
  local lamp = C.panel
  if st.job and st.job.step == "dock" then lamp = blink(now, 2) and C.accent or C.panel
  elseif how == "docked" then lamp = C.ok
  elseif how == "inbound" then lamp = C.rule end
  P.fill(56, 32, 58, 35, lamp)
  -- the body and the legs
  P.line(20, 43, 94, 43, C.rule)
  P.box(55, 45, 59, 66, C.panel)
  P.line(20, 68, 94, 68, C.rule)
  P.box(23, 69, 31, 74, C.rule)
  P.box(83, 69, 91, 74, C.rule)
  P.line(27, 75, 27, 81, C.rule)
  P.line(87, 75, 87, 81, C.rule)
  P.line(51, 69, 51, 81, C.panel)
  P.line(63, 69, 63, 81, C.panel)

  for _, side in ipairs(M.SIDES) do
    local cx = BAY[side]
    local sd = st.sides[side] or {}
    local step = isActive(st, side) and st.job.step or nil
    local silo = sd.silo or "none"
    local bad = faulted(sd, now)
    -- the pillar, and its lamp: live, full and waiting, or at fault
    local x0 = side == "A" and 20 or 87
    P.box(x0, 45, x0 + 7, 68, C.rule)
    local plamp = C.panel
    if bad then plamp = blink(now, 2) and C.warn or C.panel
    elseif step then plamp = C.accent
    elseif silo == "full" then plamp = C.ok end
    P.fill(x0 + 2, 57, x0 + 5, 60, plamp)
    -- the placer's window, the belt, the pusher: each flashes while at work
    local wx0 = side == "A" and 30 or 77
    P.box(wx0, 48, wx0 + 7, 55, live(step == "silo" or step == "feed" or step == "place"))
    local bx0 = side == "A" and 28 or cx + SILO_W / 2 + 1
    local bx1 = side == "A" and cx - SILO_W / 2 - 1 or 86
    P.line(bx0, 62, bx1, 62, live(step == "fill" or step == "empty"))
    P.box(cx - 3, 63, cx + 3, 66, live(step == "push" or step == "retract" or step == "release"))
    if silo == "lifting" or silo == "up" or silo == "reaching" then P.line(cx, UP_TOP + SILO_H, cx, 62, C.faint) end
    -- the silo, where it is: an outline, filled grey as far as it is full
    local fill = 0
    if silo == "full" or silo == "lifting" or silo == "up" or silo == "lowering" or silo == "reaching" then fill = 1 end
    if silo == "partial" then fill = 0.4 end
    if silo == "filling" or silo == "emptying" then
      local job = st.job
      local done = (job.items and job.moved and job.items > 0) and (job.moved / job.items) or 0.5
      fill = silo == "filling" and done or (1 - done)
    end
    local function siloAt(top, full, col, dot)
      local sx0, sx1, y1 = cx - SILO_W / 2, cx + SILO_W / 2, top + SILO_H - 1
      local h = floor((SILO_H - 1) * min(1, full or 0) + 0.5)
      if h > 0 then P.fill(sx0, y1 - h + 1, sx1, y1, C.faint) end
      P.box(sx0, top, sx1, y1, col, dot)
    end
    if silo == "none" or silo == "gone" then
      siloAt(REST_TOP, 0, bad and (blink(now, 2) and C.warn or C.panel) or C.panel, not bad)
      if silo == "gone" then siloAt(UP_TOP, 1, C.faint) end
    else
      local col = C.rule
      if silo == "placing" or silo == "assembling" then col = blink(now, 2) and C.accent or C.panel end
      if bad then col = blink(now, 2) and C.warn or C.panel end
      siloAt(UP[silo] and UP_TOP or REST_TOP, fill, col)
    end
    -- sticking or letting go: the join with the unit flashes
    if (step == "stick" or step == "release") and blink(now, 2) then P.line(cx - 6, 25, cx + 6, 25, C.accent) end
    -- the silos the unit carries away after a load
    if how == "docked" and st.unit.carry then
      for _, s in ipairs(st.unit.carry) do if s == side then siloAt(UP_TOP, 1, C.faint) end end
    end
  end
  return how
end

-- ------------------------------------------------------------------- HERO

local function sideWord(st, side, now)
  local C = tui().C
  local sd = st.sides[side] or {}
  if faulted(sd, now) then return "FAULT", C.warn end
  -- live words in the type colour: dark red text is too faint to read on a
  -- band (the branding review's open point); the lamps and bars carry the red
  if isActive(st, side) then return M.DOING[st.job.step or ""] or (st.job.kind == "unload" and "UNLOADING" or "LOADING"), C.text end
  local silo = sd.silo or "none"
  if silo == "full" then return "SILO FULL", C.ok end
  if silo == "partial" then return "PART FILLED", C.warn end
  if silo == "empty" then return "EMPTY SILO", C.text end
  return "NO SILO", C.faint
end

local function status(st, now)
  local C = tui().C
  local job = st.job
  if job then
    local w = job.step and M.DOING[job.step] or (job.kind == "unload" and "UNLOADING" or "LOADING")
    return w .. " - SIDE " .. table.concat(job.sides, "+"), C.text
  end
  if st.last and not st.last.ok and now - (st.last.at or 0) < 60 then return "CALLED OFF", C.warn end
  if st.last and st.last.ok and now - (st.last.at or 0) < 20 then
    return (st.last.kind == "unload" and "UNLOADED" or "LOADED") .. " - SIDE " .. table.concat(st.last.sides or {}, "+"), C.ok
  end
  if st.unit and st.unit.state == "inbound" then return "UNIT INBOUND", C.text end
  return "STANDING BY", C.faint
end

M.BASE_STALE = 30

function M.drawHero(c, st, now)
  now = now or 0
  local C = tui().C
  local w, h = c.w, c.h
  header(c, st.name .. " DEPOT")
  local word, wcol = status(st, now)
  band(c, 2, 1, w, "STATUS", word, nil, wcol)

  -- the picture, between the status band and the columns at the foot
  local strip = 6
  local top, bottom = 2, h - strip - 1
  local P = painter(c, 1, top * 3 + 1, w * 2, (bottom - top) * 3)
  local how = drawPicture(c, st, now, P)
  -- the side letters, in the masthead face, out beyond each pillar
  for _, side in ipairs(M.SIDES) do
    local sd = st.sides[side]
    local col = faulted(sd, now) and C.warn or (isActive(st, side) and C.accent or C.rule)
    local lx = floor((P.x(side == "A" and 9 or 105) - 5 - 1) / 2) + 1
    tui().headline(c, lx, cellY(P.y(48)), side, col, 1, tui().FONT7)
  end
  if not how then centre(c, cellY(P.y(14)), 1, w, "NO UNIT", C.rule) end

  -- one column per side: its band, what it is doing, the bar, its silo stock
  local y0 = h - strip + 1
  local half = floor(w / 2)
  for i, side in ipairs(M.SIDES) do
    local x0, x1 = i == 1 and 1 or half + 1, i == 1 and half - 1 or w
    local sd = st.sides[side]
    local sw, scol = sideWord(st, side, now)
    band(c, y0, x0, x1, "SIDE " .. side, sw, nil, scol)
    local job = st.job
    local detail, frac = "", 0
    if isActive(st, side) and (job.step == "fill" or job.step == "empty") then
      local n, of = job.moved, job.items
      detail = (n and of) and string.format("%s / %s ITEMS", int(n), int(of)) or (of and (int(of) .. " ITEMS") or "ITEMS MOVING")
      frac = (n and of and of > 0) and (n / of) or 0
    elseif isActive(st, side) then
      detail = M.STEP_WORD[job.step or ""] or ""
      local list = job.kind == "unload" and M.UNLOAD_STEPS or M.LOAD_STEPS
      for j, s in ipairs(list) do if s == job.step then frac = j / #list end end
    elseif faulted(sd, now) then
      detail = tostring(sd.fault):upper()
    else
      local silo = sd.silo or "none"
      detail = silo == "full" and "LOADED - WAITING" or (silo == "empty" and "READY TO FILL")
               or (silo == "partial" and "PART FILLED - CHECK IT") or "BAY CLEAR"
    end
    put(c, x0 + 1, y0 + 1, detail:sub(1, x1 - x0 - 1), faulted(sd, now) and C.warn or C.text)
    tui().bar(c, x0 + 1, y0 + 2, x1 - x0 - 1, frac, C.accent)
    local words, low = stock(sd)
    put(c, x0 + 1, y0 + 3, words:sub(1, x1 - x0 - 1), low and C.warn or C.faint)
  end
  -- the unit and the base link, on the last row
  local u = st.unit
  local unitText = u and (u.id:upper() .. " " .. u.state:upper()) or "NONE"
  local linkText, linkInk = "BASE LINK --", C.faint
  if st.baseAt then
    if now - st.baseAt <= M.BASE_STALE then linkText, linkInk = "BASE LINK OK", C.ok
    else linkText, linkInk = "BASE LINK LOST", C.warn end
  end
  band(c, h, 1, w, "UNIT " .. unitText, linkText, u and C.text or C.faint, linkInk)
end

-- ------------------------------------------------------------------ ORDER

function M.drawOrder(c, st, now)
  now = now or 0
  local TT = tui()
  local C = TT.C
  local w, h = c.w, c.h
  local job = st.job
  header(c, "ORDER")

  if not job then
    band(c, 2, 1, w, "ORDER", "NONE", nil, C.faint)
    TT.headline(c, 2, 4, "STANDBY", C.rule, 1, TT.FONT7)
    local y = 8
    band(c, y, 1, w, "LAST ORDER", st.last and (st.last.order or "") or "--")
    local l = st.last
    if l then
      put(c, 2, y + 1, string.format("%s SIDE %s%s", l.kind == "unload" and "UNLOAD" or "LOAD",
        table.concat(l.sides or {}, "+"), l.flight and ("  FLIGHT " .. l.flight) or ""), C.text)
      if l.items then put(c, 2, y + 2, int(l.items) .. " " .. (l.item and l.item:upper() or "ITEMS"), C.text) end
      if l.ok then
        put(c, 2, y + 3, "COMPLETE IN " .. clock(l.took) .. ", " .. clock(now - l.at) .. " AGO", C.ok)
      else
        put(c, 2, y + 3, "CALLED OFF", C.warn)
        local why, row = tostring(l.why or ""):upper(), y + 4
        while #why > 0 and row <= y + 6 do
          local cut = #why <= w - 2 and #why or (why:sub(1, w - 1):match("^.*() ") or (w - 1))
          put(c, 2, row, why:sub(1, cut - (cut < #why and 1 or 0)), C.faint)
          why, row = why:sub(cut + 1), row + 1
        end
      end
    else
      put(c, 2, y + 1, "NONE TODAY", C.faint)
    end
    local by = h - 9
    band(c, by, 1, w, "BAYS")
    for i, side in ipairs(M.SIDES) do
      local sd = st.sides[side]
      local sw, scol = sideWord(st, side, now)
      put(c, 2, by + i, side, C.text)
      put(c, 4, by + i, sw, scol)
      local _, low = stock(sd)
      right(c, by + i, w - 1, sd.feed and ("STOCK " .. sd.feed) or "STOCK --", low and C.warn or C.faint)
    end
  else
    -- the order: its number, and this flight of it
    band(c, 2, 1, w, "ORDER", job.order or "--", nil, C.text)
    local kind = job.kind == "unload" and "UNLOAD" or "LOAD"
    TT.headline(c, 2, 4, kind, C.text, 1, TT.FONT7)
    local side = "SIDE " .. table.concat(job.sides, "+")
    right(c, 4, w - 1, side, C.text)
    right(c, 5, w - 1, job.flight and ("FLIGHT " .. job.flight) or "", C.faint)
    if job.shipments then put(c, 2, 7, "SHIPMENT " .. job.shipments, C.faint) end
    -- the cargo: how many, of what, and how far through
    band(c, 8, 1, w, "CARGO", job.item and tostring(job.item):upper() or nil)
    if job.items then
      TT.headline(c, 2, 9, int(job.items):gsub(",", ""), C.text, 2)
      local moving = job.step == "fill" or job.step == "empty"
      local n = job.moved or 0
      local frac = job.items > 0 and (n / job.items) or 0
      right(c, 10, w - 1, string.format("%d%%", floor(100 * frac + 0.5)), moving and C.accent or C.faint)
      right(c, 11, w - 1, int(n) .. " " .. (job.kind == "unload" and "OUT" or "IN"), C.faint)
      TT.bar(c, 2, 13, w - 2, frac, C.accent)
    else
      put(c, 2, 10, "COUNTING AT THE INTAKE", C.faint)
    end
    -- where it goes, and on what
    band(c, 15, 1, w, "ROUTE")
    put(c, 2, 16, job.kind == "unload" and "FROM" or "TO", C.faint)
    put(c, 8, 16, job.dest and tostring(job.dest):upper() or "--", C.text)
    put(c, 2, 17, "UNIT", C.faint)
    local u = st.unit
    put(c, 8, 17, u and (u.id:upper() .. " " .. u.state:upper()) or "NONE", u and C.text or C.faint)
    -- the sequence, ticked off
    local sy = 19
    band(c, sy, 1, w, "SEQUENCE", "T+" .. clock(now - (job.t0 or now)))
    local list = job.kind == "unload" and M.UNLOAD_STEPS or M.LOAD_STEPS
    for i, s in ipairs(list) do
      local ry = sy + i
      if ry > h - 5 then break end
      local mark, col, word = "\7", C.rule, C.rule
      if s == job.step then
        mark, col, word = blink(now, 2) and "\16" or " ", C.accent, C.text
        right(c, ry, w - 1, clock(now - (job.stepAt or now)), C.accent)
      elseif job.done[s] then
        mark, col, word = "\4", C.ok, C.faint
      end
      put(c, 2, ry, mark, col)
      put(c, 4, ry, M.STEP_WORD[s] or s:upper(), word)
    end
  end

  -- the day, at the foot
  local fy = h - 3
  band(c, fy, 1, w, "TODAY")
  put(c, 2, fy + 1, "LOADS", C.faint)
  put(c, 8, fy + 1, tostring(st.counts.loads), C.text)
  put(c, 12, fy + 1, "UNLOADS", C.faint)
  put(c, 20, fy + 1, tostring(st.counts.unloads), C.text)
  put(c, 2, fy + 2, "ITEMS", C.faint)
  put(c, 8, fy + 2, int(st.counts.items), C.text)
  if job and job.text then band(c, h, 1, w, tostring(job.text), nil, C.faint) end
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
      M.begin(st, "load", "A", { id = "C-0042.1", items = 640, item = "Cobblestone", dest = "Kodiak", unit = "drone-1",
                                 shipments = "1 OF 1" }, t)
      M.step(st, "silo", "no silo on side A", t) end },
  { at = 12, fn = function(st, t) M.step(st, "feed", "9 silo blocks in the feed", t) end },
  { at = 14, fn = function(st, t) M.step(st, "place", "placing a silo on side A", t) end },
  { at = 18, fn = function(st, t) M.step(st, "assemble", "assembling it", t) end },
  { at = 22, fn = function(st, t) M.step(st, "fill", "filling 640 items", t) end },
  { at = 24, fn = function(st, t) M.step(st, "fill", "160 items in", t) end },
  { at = 26, fn = function(st, t) M.step(st, "fill", "352 items in", t) end },
  { at = 28, fn = function(st, t) M.step(st, "fill", "544 items in", t) end },
  { at = 30, fn = function(st, t) M.step(st, "fill", "640 items in", t) end },
  { at = 30.5, fn = function(st, t) M.step(st, "invoice", "invoice C-0042-1 printed, in the A silo", t) end },
  { at = 31, fn = function(st, t) M.step(st, "dock", "waiting for the drone to latch", t) end },
  { at = 34, fn = function(st, t) M.step(st, "push", "pusher up", t) end },
  { at = 38, fn = function(st, t) M.step(st, "stick", "the drone sticks the silo", t) end },
  { at = 41, fn = function(st, t) M.step(st, "retract", "pusher down", t) end },
  { at = 45, fn = function(st, t) st.sides.A.feed = 6 M.finish(st, true, nil, t) end },
  { at = 50, fn = function(st, t) M.left(st) end },
  { at = 52, fn = function(st, t) M.unit(st, "drone-2", "inbound", t) end },
  { at = 56, fn = function(st, t)
      M.begin(st, "unload", { "A", "B" }, { id = "C-0039.2", items = 2560, item = "Iron Ingot", dest = "Kodiak",
                                            unit = "drone-2", shipments = "3-4 OF 4" }, t)
      M.step(st, "push", "pusher up, under the drone's silo", t) end },
  { at = 60, fn = function(st, t) M.step(st, "release", "the drone lets go", t) end },
  { at = 63, fn = function(st, t) M.step(st, "retract", "pusher down", t) end },
  { at = 67, fn = function(st, t) M.step(st, "empty", "emptying 2560 items into storage", t) end },
  { at = 70, fn = function(st, t) M.step(st, "empty", "1024 items out", t) end },
  { at = 73, fn = function(st, t) M.step(st, "empty", "2048 items out", t) end },
  { at = 76, fn = function(st, t) M.step(st, "empty", "2560 items out", t) end },
  { at = 77, fn = function(st, t) M.finish(st, true, nil, t) end },
  { at = 82, fn = function(st, t)
      M.begin(st, "load", "B", { id = "C-0043.1", items = 320, item = "Oak Log", dest = "Market", unit = "drone-2",
                                 shipments = "1 OF 1" }, t)
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
