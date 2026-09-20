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
  ["7"] = 0x1b1d20,  -- panel fill / bar track
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
function T.keys(c, y, list)
  local x = 1
  for _, k in ipairs(list) do
    local live, key, label = k[3], tostring(k[1]), tostring(k[2])
    if x + #key + #label + 3 > c.w + 1 then return end   -- never wrap the key bar
    c:text(x, y, "[", T.C.rule)
    c:text(x + 1, y, key, live and T.C.accent or T.C.text)
    c:text(x + 1 + #key, y, "]", T.C.rule)
    c:text(x + 3 + #key, y, label, live and T.C.text or T.C.faint)
    x = x + #key + #label + 4
  end
end

-- A caption with a rule running out to both edges.
function T.caption(c, y, title)
  local w = c.w
  c:text(1, y, string.rep("-", w), T.C.rule)
  local tx = math.max(1, math.floor((w - #title - 2) / 2) + 1)
  c:text(tx, y, " " .. title .. " ", T.C.text)
end

T.SPIN = { "|", "/", "-", "\\" }
function T.spin(n) return T.SPIN[((n or 0) % 4) + 1] end

return T
