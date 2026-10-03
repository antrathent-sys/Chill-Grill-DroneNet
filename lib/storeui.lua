--- storeui: a site's stock list on a monitor (Alex, 2026-10-03: "a 4x5
-- portrait screen for a stock list for the CHI base ... scrollable, sorted by
-- number of items, updating as new stock comes in"). Drawn by the store
-- computer (store.lua) from its own count, every time it counts.
--
--   M.list(totals, names) -> { { key, label, count } }   most first
--   M.rows(c)                how many items one screenful shows
--   M.render(T, c, view) -> hits
--   M.hit(hits, x, y) -> "up" | "down" | "top" | nil
--
-- view: { site, list (from M.list), top (the first row shown), at (when it
--         was counted, as text), problems (count of unreadable inventories) }
-- Pure; tools/test_store.lua and tools/preview_store.py.

local M = {}

local floor, max, min = math.floor, math.max, math.min

local function commas(n)
  local s = tostring(floor(n or 0))
  return (s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end
M.commas = commas

--- The count as a list, the most held first (then by name).
function M.list(totals, names)
  local out = {}
  for k, t in pairs(totals or {}) do
    out[#out + 1] = { key = k, label = (names and names[k]) or k, count = t.count or 0 }
  end
  table.sort(out, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a.label < b.label
  end)
  return out
end

local BUTTON_H = 3
--- Items on one screenful: the band, a line of totals, the column heads,
-- one blank, and the buttons take the rest.
function M.rows(c) return max(1, c.h - 4 - BUTTON_H) end

--- The first row to show, kept on the list: never past the last screenful.
function M.clamp(top, n, rows)
  return max(1, min(top or 1, max(1, n - rows + 1)))
end

local function center(c, y, s, ink, bg)
  s = tostring(s):sub(1, c.w)
  c:text(max(1, floor((c.w - #s) / 2) + 1), y, s, ink, bg)
end

local function button(T, c, hits, id, x, y, w, h, label, live)
  local bg = live and T.C.panel or T.C.ground
  for yy = y, y + h - 1 do c:text(x, yy, string.rep(" ", w), T.C.text, bg) end
  label = tostring(label):sub(1, w)
  c:text(x + floor((w - #label) / 2), y + floor((h - 1) / 2), label, live and T.C.text or T.C.rule, bg)
  hits[#hits + 1] = { id = id, x1 = x, y1 = y, x2 = x + w - 1, y2 = y + h - 1 }
end

function M.render(T, c, view)
  c:fill(1, 1, c.w, c.h, T.C.ground)
  local hits = {}
  local list = view.list or {}
  local total = 0
  for _, e in ipairs(list) do total = total + e.count end
  T.band(c, 1, "CINDER STOCK  " .. tostring(view.site or ""), commas(total) .. " ITEMS", T.C.text, T.C.faint)
  local info = string.format("%d KINDS", #list) .. (view.at and ("  COUNTED " .. view.at) or "")
  c:text(2, 2, info:sub(1, c.w - 2), T.C.faint)
  if (view.problems or 0) > 0 then
    -- an inventory that would not read: its stock is missing from the list
    c:text(2 + #info + 2, 2, (view.problems .. " UNREADABLE"):sub(1, math.max(0, c.w - #info - 4)), T.C.warn)
  end
  local cw = math.max(9, #commas(list[1] and list[1].count or 0))   -- the count column, as wide as the biggest
  local rk = #tostring(#list) + 1                                   -- the rank column
  c:text(2, 3, "#", T.C.rule)
  c:text(2 + rk, 3, "ITEM", T.C.rule)
  c:text(c.w - cw, 3, string.format("%" .. cw .. "s", "COUNT"), T.C.rule)
  local rows = M.rows(c)
  local top = M.clamp(view.top, #list, rows)
  if #list == 0 then
    center(c, floor(c.h / 2) - 1, view.empty or "NOTHING COUNTED YET", T.C.faint)
  end
  for i = 0, rows - 1 do
    local e = list[top + i]
    if not e then break end
    local y = 4 + i
    local rank = string.format("%" .. (rk - 1) .. "d", top + i)
    local nameW = c.w - 2 - rk - cw - 1
    c:text(2, y, rank, T.C.rule)
    c:text(2 + rk, y, e.label:upper():sub(1, nameW), T.C.text)
    c:text(c.w - cw, y, string.format("%" .. cw .. "s", commas(e.count)), T.C.text)
  end
  -- where in the list, and the buttons
  local pages = max(1, math.ceil(#list / rows))
  local page = (top + rows - 1 >= #list) and pages or min(pages, floor((top - 1) / rows) + 1)
  if #list > rows then
    c:text(2, c.h - BUTTON_H, string.format("%d-%d OF %d", top, min(#list, top + rows - 1), #list), T.C.faint)
  end
  local by = c.h - BUTTON_H + 1
  local third = floor((c.w - 2) / 3)
  button(T, c, hits, "up", 1, by, third, BUTTON_H, "UP", top > 1)
  button(T, c, hits, "top", third + 2, by, c.w - 2 * third - 2, BUTTON_H, page .. "/" .. pages, top > 1)
  button(T, c, hits, "down", c.w - third + 1, by, third, BUTTON_H, "DOWN", top + rows - 1 < #list)
  return hits, top
end

function M.hit(hits, x, y)
  for _, h in ipairs(hits or {}) do
    if x >= h.x1 and x <= h.x2 and y >= h.y1 and y <= h.y2 then return h.id end
  end
  return nil
end

return M
