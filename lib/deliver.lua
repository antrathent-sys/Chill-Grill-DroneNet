--- deliver: what `fly deliver` was asked to do, and which payload goes where.
--
--   fly deliver <drop> [and <drop>] [to <dock> | to <x> <y> <z>] [empty]
--   <drop> = <x> <y> <z> [cruiseY]   or   <place> [cruiseY]
--
-- y is the height to hover at over the drop. The cruise height belongs to
-- the first drop only (it is the whole trip's). `to` docks somewhere other
-- than home at the end. `empty` flies the trip with nothing aboard - a test
-- flight; without it a delivery needs a payload: a silo held by an extended
-- sticker, one per drop.
--
-- Which silo drops where: the stickers holding something, in name order
-- (Create_Sticker_0 before Create_Sticker_1). With one drop everything is let
-- go there. With two, the first drop lets go of the first sticker and the
-- last drop of whatever is left.
--
-- Pure: fly.lua hands in its arguments and the stickers it found, so
-- tools/test_deliver.lua checks all of it on the desktop.

local D = {}

D.USAGE = "deliver <x> <y> <z> [cruiseY] [and <x> <y> <z>] [to <dock>] [empty]   (or a place name for any drop)"

local function fail(msg) error(msg .. "\n  " .. D.USAGE, 0) end

--- Read the arguments after the word deliver (args[1] is "deliver").
-- Returns { drops = { { x, y, z } | { place }, ... }, cruiseY, to, empty }.
-- to is { place = name } or { x, y, z }, or nil for home.
function D.parse(args)
  local words, empty = {}, false
  for i = 2, #args do
    local a = tostring(args[i])
    if a == "empty" then empty = true else words[#words + 1] = a end
  end
  -- split off `to ...`, then the drops at each `and`
  local to
  for i, a in ipairs(words) do
    if a == "to" then
      local rest = { (table.unpack or unpack)(words, i + 1) }
      if #rest == 1 and not tonumber(rest[1]) then
        to = { place = rest[1] }
      elseif #rest == 3 and tonumber(rest[1]) and tonumber(rest[2]) and tonumber(rest[3]) then
        to = { x = tonumber(rest[1]), y = tonumber(rest[2]), z = tonumber(rest[3]) }
      else
        fail("to needs a dock name or <x> <padY> <z>")
      end
      for j = #words, i, -1 do words[j] = nil end
      break
    end
  end
  local segs, cur = {}, {}
  for _, a in ipairs(words) do
    if a == "and" then
      segs[#segs + 1] = cur
      cur = {}
    else
      cur[#cur + 1] = a
    end
  end
  segs[#segs + 1] = cur

  local out = { drops = {}, to = to, empty = empty }
  for i, s in ipairs(segs) do
    local drop
    if #s == 0 then
      fail(i == 1 and "deliver where?" or "nothing after `and`")
    elseif not tonumber(s[1]) then
      drop = { place = s[1] }
      if s[2] then
        if i > 1 or not tonumber(s[2]) or s[3] then fail("unexpected " .. tostring(s[2]) .. " after " .. s[1]) end
        out.cruiseY = tonumber(s[2])
      end
    else
      local x, y, z = tonumber(s[1]), tonumber(s[2]), tonumber(s[3])
      if not (x and y and z) then fail("a drop needs <x> <y> <z>") end
      drop = { x = x, y = y, z = z }
      if s[4] then
        if i > 1 or not tonumber(s[4]) or s[5] then
          fail(i > 1 and "the cruise height goes after the first drop" or ("unexpected " .. tostring(s[5] or s[4])))
        end
        out.cruiseY = tonumber(s[4])
      end
    end
    out.drops[#out.drops + 1] = drop
  end
  return out
end

--- Which stickers each drop lets go of. held is the names of the stickers
-- that are out (holding a silo). Returns a list, one entry per drop, each a
-- list of names - empty lists when flown empty. Errors when the payload does
-- not match the drops: better on the ground than over the first drop.
function D.assign(nDrops, held, empty)
  local out = {}
  if empty then
    for i = 1, nDrops do out[i] = {} end
    return out
  end
  local names = {}
  for _, n in ipairs(held or {}) do names[#names + 1] = n end
  table.sort(names)
  if #names == 0 then
    error("deliver needs a payload: no sticker is holding anything. Load it first " ..
          "(ops load run), or add `empty` to fly the trip with nothing aboard", 0)
  end
  if nDrops > #names then
    error(string.format("%d drops but %d payload%s aboard: one silo per drop", nDrops, #names,
      #names == 1 and "" or "s"), 0)
  end
  for i = 1, nDrops do
    if i < nDrops then
      out[i] = { names[i] }
    else
      out[i] = {}
      for j = i, #names do out[i][#out[i] + 1] = names[j] end
    end
  end
  return out
end

return D
