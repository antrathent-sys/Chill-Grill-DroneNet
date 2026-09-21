-- tui: the terminal look shared by every screen in the fleet - the pocket
-- terminal now, the base's flight control later.
--
-- Three decisions live here so every screen inherits them:
--
--   1. Borders are CHARACTERS, not pixels. A one-pixel line on the canvas is
--      half a cell wide and reads as a chunky bar; the font's own "-" and "|"
--      are hairlines and sit on the text grid, so boxes look the weight the
--      text does. Corners are "+", which is the closest ComputerCraft has to a
--      box-drawing set.
--   2. One palette: imperial. Near-black ground, light grey type, dark red for
--      anything live or selected. tui.apply(term) redefines the colour slots,
--      so a screen only ever names a role - tui.C.text, tui.C.accent - and
--      never a colour.
--   3. A highlighted row means the selected row, and nothing else. It is the
--      one place the accent colour fills a whole line, so the eye goes there
--      first on any screen.
--
-- Everything is drawn onto a lib/display.lua canvas, so tools/preview_pocket.py
-- renders the same screens on the desktop as the hardware shows.

local T = {}

-- Blit slots this kit uses. The names are roles; apply() gives them colour.
T.C = {
  ground = "f",   -- the page
  panel  = "7",   -- inside a box, a bar's empty track
  rule   = "8",   -- borders, labels, anything structural
  text   = "0",   -- values, the things being read
  faint  = "c",   -- secondary text
  accent = "e",   -- live, selected, in progress
  warn   = "4",   -- attention, not failure
  ok     = "d",   -- done
}

-- Imperial: dark ground, dark red, light grey. Deliberately narrow - the
-- readability comes from contrast between three levels of grey, not from hue.
T.PALETTE = {
  f = 0x0b0c0e,   -- ground, near black with a little blue in it
  ["7"] = 0x25282d,  -- panel fill / bar track: bands, lifted so they read in game
  ["8"] = 0x5b6169,  -- rules and labels: visible, never loud
  ["0"] = 0xd8dbdf,  -- primary type, light grey
  c = 0x8d939b,      -- secondary type
  e = 0x8e2420,      -- dark red: selection, progress, live
  ["4"] = 0xb8542c,  -- warning, a rust rather than a yellow
  d = 0x6f8f5f,      -- done, a muted green
}

function T.apply(t)
  if not (t and t.setPaletteColour) then return false end
  for slot, rgb in pairs(T.PALETTE) do pcall(t.setPaletteColour, 2 ^ tonumber(slot, 16), rgb) end
  return true
end

-- ------------------------------------------------------------------ pieces --

-- A box of hairline characters with its title set into the top rule:
--   +- TITLE ---------------+
-- Returns the first row inside it. Text inside starts at x + 1.
function T.box(c, x, y, w, h, title, rule, ink)
  rule, ink = rule or T.C.rule, ink or T.C.text
  local top = "+" .. string.rep("-", w - 2) .. "+"
  c:text(x, y, top, rule)
  c:text(x, y + h - 1, top, rule)
  for i = 1, h - 2 do
    c:text(x, y + i, "|", rule)
    c:text(x + w - 1, y + i, "|", rule)
  end
  if title then c:text(x + 2, y, " " .. title .. " ", ink) end
  return y + 1
end

-- A section: one rule with the title set into it, and nothing else. Imperial
-- screens are 70-90% unlit, and a full box spends four cells of ink per row on
-- being a box - so this is the default and T.box is for the one panel that has
-- to be fenced off. Returns the first row inside.
-- A band: one full-width row in the panel colour, a label at the left and
-- an optional value at the right. Solid colour is what CC draws cleanly; a
-- rule made of dashes reads as a dotted line in its font. Returns y + 1.
function T.band(c, y, left, right, leftInk, rightInk)
  local w = c.w
  c:text(1, y, string.rep(" ", w), T.C.faint, T.C.panel)
  if left then c:text(2, y, tostring(left):upper():sub(1, w - 2), leftInk or T.C.faint, T.C.panel) end
  if right then
    right = tostring(right)
    c:text(math.max(2, w - #right), y, right, rightInk or T.C.text, T.C.panel)
  end
  return y + 1
end

-- A section heading is a band with its title. rule and ink are accepted for
-- the older callers and ignored.
function T.section(c, y, title, rule, ink)
  return T.band(c, y, title)
end

-- A bar: filled cells on a track, so it reads as a bar and not as text.
function T.bar(c, x, y, w, frac, ink, track)
  frac = math.max(0, math.min(1, frac or 0))
  local lit = math.floor(w * frac + 0.5)
  if lit > 0 then c:text(x, y, string.rep(" ", lit), ink or T.C.accent, ink or T.C.accent) end
  if lit < w then c:text(x + lit, y, string.rep(" ", w - lit), track or T.C.panel, track or T.C.panel) end
end

-- A row of a list. Selected rows are filled across the FULL width, because a
-- half-width highlight reads as a bug.
function T.row(c, x, y, w, left, right, selected)
  if selected then
    c:text(x, y, string.rep(" ", w), T.C.text, T.C.accent)
    c:text(x + 1, y, tostring(left):sub(1, w - 2 - #tostring(right or "")), T.C.text, T.C.accent)
    if right then c:text(x + w - 1 - #tostring(right), y, tostring(right), T.C.text, T.C.accent) end
  else
    c:text(x + 1, y, tostring(left):sub(1, w - 2 - #tostring(right or "")), T.C.text)
    if right then c:text(x + w - 1 - #tostring(right), y, tostring(right), T.C.faint) end
  end
end

-- The keys along the bottom: { {"G", "BOARD", true}, {"Q", "ABORT"} }
-- The key bar: a band along the bottom, each key bright and its label quiet,
-- the live one (what Enter or the main key does) with its label lit as well.
-- On the bottom row CC paints the screen's margin in the band's colour, so
-- the bar runs to the edge of the screen.
function T.keys(c, y, list)
  local w = c.w
  c:text(1, y, string.rep(" ", w), T.C.faint, T.C.panel)
  local x = 2
  for _, k in ipairs(list) do
    local live, key, label = k[3], tostring(k[1]), tostring(k[2])
    if x + #key + #label > w then return end            -- never wrap the key bar
    c:text(x, y, key, T.C.text, T.C.panel)
    c:text(x + #key + 1, y, label, live and T.C.text or T.C.faint, T.C.panel)
    x = x + #key + 1 + #label + 2
  end
end

-- ---------------------------------------------------------------- headline --
-- ComputerCraft has no bold, so a headline is drawn rather than typed: a 3x5
-- block font painted in sub-pixels, which is the only way to make a word
-- heavier than the body text on this hardware. Reserved for the one title at
-- the top of a screen; everything else stays on the text grid.
T.FONT = {
  A = "010,101,111,101,101", B = "110,101,110,101,110", C = "011,100,100,100,011",
  D = "110,101,101,101,110", E = "111,100,110,100,111", F = "111,100,110,100,100",
  G = "011,100,101,101,011", H = "101,101,111,101,101", I = "111,010,010,010,111",
  J = "001,001,001,101,010", K = "101,110,100,110,101", L = "100,100,100,100,111",
  -- M, N and W are wider than the rest: at three pixels a diagonal has
  -- nowhere to go, and N came out as a second M (CINDER read CIMDER)
  M = "10001,11011,10101,10001,10001", N = "1001,1101,1011,1001,1001",
  O = "010,101,101,101,010",
  P = "110,101,110,100,100", Q = "010,101,101,111,011", R = "110,101,110,101,101",
  S = "011,100,010,001,110", T = "111,010,010,010,010", U = "101,101,101,101,011",
  V = "101,101,101,101,010", W = "10001,10001,10101,11011,10001", X = "101,101,010,101,101",
  Y = "101,101,010,010,010", Z = "111,001,010,100,111",
  ["0"] = "111,101,101,101,111", ["1"] = "010,110,010,010,111",
  ["2"] = "111,001,111,100,111", ["3"] = "111,001,111,001,111",
  ["4"] = "101,101,111,001,001", ["5"] = "111,100,111,001,111",
  ["6"] = "111,100,111,101,111", ["7"] = "111,001,010,010,010",
  ["8"] = "111,101,111,101,111", ["9"] = "111,101,111,001,111",
  [" "] = "000,000,000,000,000", ["-"] = "000,000,111,000,000",
  ["."] = "000,000,000,000,010", [":"] = "000,010,000,010,000",
  ["/"] = "001,001,010,100,100",
}

-- How far a word in the block font advances, in sub-pixels: each glyph's own
-- width plus a one-pixel gap. Most glyphs are three wide; a few are not.
function T.headlinePx(text, scale)
  scale = scale or 1
  text = tostring(text):upper()
  local px = 0
  for i = 1, #text do
    local g = T.FONT[text:sub(i, i)] or T.FONT[" "]
    px = px + (#g:match("^[^,]+") + 1) * scale
  end
  return px
end

-- Draw text in the block font. x, y are CELL coordinates; the word occupies
-- two rows at scale 1. Returns the width in cells.
function T.headline(c, x, y, text, col, scale)
  scale = scale or 1
  local px = (x - 1) * 2 + 1
  local py = (y - 1) * 3 + 1
  text = tostring(text):upper()
  local ox = 0
  for i = 1, #text do
    local g = T.FONT[text:sub(i, i)] or T.FONT[" "]
    local gw = #g:match("^[^,]+")
    local row = 0
    for line in g:gmatch("[^,]+") do
      for gx = 1, gw do
        if line:sub(gx, gx) == "1" then
          for sy = 0, scale - 1 do
            for sx = 0, scale - 1 do
              c:pix(px + ox + (gx - 1) * scale + sx, py + row * scale + sy, col or T.C.text)
            end
          end
        end
      end
      row = row + 1
    end
    ox = ox + (gw + 1) * scale
  end
  return math.ceil(ox / 2)
end

-- A caption with a rule running out to both edges.
function T.caption(c, y, title)
  local w = c.w
  c:text(1, y, string.rep("-", w), T.C.rule)
  local tx = math.max(1, math.floor((w - #title - 2) / 2) + 1)
  c:text(tx, y, " " .. title .. " ", T.C.text)
end

-- A masthead: the word in the block font with rules either side, two rows
-- tall. What a screen uses when its title should carry weight.
function T.masthead(c, y, title, col, sub)
  local w = c.w
  local cells = math.ceil(T.headlinePx(title) / 2)
  local x = math.max(1, math.floor((w - cells) / 2) + 1)
  T.headline(c, x, y, title, col or T.C.text)
  -- A double hairline either side of the word, one sub-pixel above and one
  -- below its middle. Never ON the middle: that is the bottom third of a
  -- cell, which CC can only draw by swapping the colours, and then the
  -- screen's margin takes the rule's grey and boxes the name in.
  local top = (y - 1) * 3 + 1
  local rightPx = (x + cells) * 2
  for _, py in ipairs({ top + 1, top + 3 }) do
    if x > 2 then c:line(1, py, (x - 2) * 2, py, T.C.rule) end
    if rightPx < w * 2 then c:line(rightPx, py, w * 2, py, T.C.rule) end
  end
  if sub then c:text(math.max(1, math.floor((w - #sub) / 2) + 1), y + 2, sub, T.C.faint) end
  return y + (sub and 3 or 2)
end

T.SPIN = { "|", "/", "-", "\\" }
function T.spin(n) return T.SPIN[((n or 0) % 4) + 1] end

return T
