--- cargo: what went into each silo, and where each silo went.
--
-- cargo.csv on the base, appended, never rewritten - the same shape of
-- record as the ledger and the job log:
--
--   when,load,drone,silo,sticker,item,count,dest,state,x,y,z
--
-- Two kinds of row:
--   loaded     one per item per silo, written by `ops load run` once the
--              drone has stuck the silos on. The count comes from reading the
--              silo itself before it is assembled (CC sees a placed vault as
--              an inventory), or - with no silo readable - from what left the
--              intake, which cannot tell two silos apart (silo "both").
--   delivered  one per silo let go of, from the drone's own report of the
--   / held     drop: where it was, and whether the sticker really let go.
--
-- What went where is the join: a load's loaded rows for a sticker, and that
-- sticker's drop row for the same load. `ops cargo` prints it.
--
-- Pure: inventories and files come in as tables and text, so
-- tools/test_cargo.lua checks all of it on the desktop.

local C = {}

C.HEADER = "when,load,drone,silo,sticker,item,count,dest,state,x,y,z"

local floor = math.floor

--- An inventory's list() - slot -> { name, count } - as item -> count.
function C.tally(list)
  local out = {}
  for _, it in pairs(list or {}) do
    if type(it) == "table" and type(it.name) == "string" and type(it.count) == "number" then
      out[it.name] = (out[it.name] or 0) + it.count
    end
  end
  return out
end

--- What left: before minus after, only what went down.
function C.diff(before, after)
  local out = {}
  for name, n in pairs(before or {}) do
    local gone = n - ((after or {})[name] or 0)
    if gone > 0 then out[name] = gone end
  end
  return out
end

function C.total(m)
  local n = 0
  for _, c in pairs(m or {}) do n = n + c end
  return n
end

--- "640 cobblestone, 64 iron ingot" - biggest first, the mod prefix dropped.
function C.describe(m, maxItems)
  local list = {}
  for name, n in pairs(m or {}) do list[#list + 1] = { name = name, n = n } end
  table.sort(list, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.name < b.name end)
  local parts = {}
  for i, it in ipairs(list) do
    if maxItems and i > maxItems then
      parts[#parts + 1] = string.format("+%d more", #list - maxItems)
      break
    end
    parts[#parts + 1] = string.format("%d %s", it.n, (it.name:gsub("^[%w_]+:", ""):gsub("_", " ")))
  end
  return #parts > 0 and table.concat(parts, ", ") or "nothing"
end

--- Where each sticker's silo is going, from the load's liftoff command.
-- `deliver A and B` goes through lib/deliver (passed in as D) exactly as the
-- drone will read it, so both ends agree on which silo drops where. Anything
-- else (ferry, none) is the same for every silo.
function C.destinations(D, liftoff, stickers)
  local out = {}
  local words = {}
  for w in tostring(liftoff or ""):gmatch("%S+") do words[#words + 1] = w end
  if words[1] == "deliver" and D then
    local okP, spec = pcall(D.parse, words)
    local okA, release = false, nil
    if okP then okA, release = pcall(D.assign, #spec.drops, stickers, spec.empty) end
    if okP and okA then
      for i, names in ipairs(release) do
        local d = spec.drops[i]
        local where = d.place or string.format("%d %d %d", d.x, d.y, d.z)
        for _, n in ipairs(names) do out[n] = where end
      end
      return out
    end
  end
  local same = liftoff and liftoff:gsub(",", " ") or ""
  for _, n in ipairs(stickers or {}) do out[n] = same end
  return out
end

local function field(v) return (tostring(v == nil and "" or v):gsub("[,\r\n]", " ")) end
local function row(t)
  return table.concat({ field(t.when), field(t.load), field(t.drone), field(t.silo), field(t.sticker),
    field(t.item), field(t.count), field(t.dest), field(t.state), field(t.x), field(t.y), field(t.z) }, ",")
end

--- The loaded rows for one load. silos is a list of
-- { silo, sticker, items = { name -> count } }; dest is sticker -> where.
-- A silo that was not counted gets one row with item "?".
function C.loadedRows(when, load, drone, silos, dest)
  local out = {}
  for _, s in ipairs(silos) do
    local names = {}
    for name in pairs(s.items or {}) do names[#names + 1] = name end
    table.sort(names)
    local where = (dest or {})[s.sticker] or ""
    if #names == 0 then
      out[#out + 1] = row({ when = when, load = load, drone = drone, silo = s.silo, sticker = s.sticker,
        item = "?", count = 0, dest = where, state = "loaded" })
    end
    for _, name in ipairs(names) do
      out[#out + 1] = row({ when = when, load = load, drone = drone, silo = s.silo, sticker = s.sticker,
        item = name, count = s.items[name], dest = where, state = "loaded" })
    end
  end
  return out
end

--- One drop row: ok = the sticker let go ("delivered"), else "held".
function C.dropRow(when, load, drone, silo, sticker, dest, ok, x, y, z)
  local function n(v) return type(v) == "number" and floor(v) or "" end
  return row({ when = when, load = load, drone = drone, silo = silo, sticker = sticker, item = "", count = "",
    dest = dest, state = ok and "delivered" or "held", x = n(x), y = n(y), z = n(z) })
end

--- cargo.csv as a list of rows (tables), header and blank lines skipped.
function C.parse(text)
  local out = {}
  for line in tostring(text or ""):gmatch("[^\r\n]+") do
    if line ~= C.HEADER then
      local f = {}
      for v in (line .. ","):gmatch("([^,]*),") do f[#f + 1] = v end
      if #f >= 9 then
        out[#out + 1] = { when = tonumber(f[1]), load = f[2], drone = f[3], silo = f[4], sticker = f[5],
          item = f[6], count = tonumber(f[7]), dest = f[8], state = f[9],
          x = tonumber(f[10]), y = tonumber(f[11]), z = tonumber(f[12]) }
      end
    end
  end
  return out
end

local function holds(stickerField, sticker)
  for s in tostring(stickerField):gmatch("[^+]+") do if s == sticker then return true end end
  return false
end

--- The load a drop belongs to: the newest load on this drone whose silos
-- include this sticker and that has no drop for it yet. Returns load, silo,
-- dest, or nil.
function C.openFor(rows, drone, sticker)
  local dropped = {}
  for _, r in ipairs(rows) do
    if r.state ~= "loaded" and r.drone == drone and r.sticker == sticker then dropped[r.load] = true end
  end
  for i = #rows, 1, -1 do
    local r = rows[i]
    if r.state == "loaded" and r.drone == drone and holds(r.sticker, sticker) and not dropped[r.load] then
      return r.load, r.silo, r.dest
    end
  end
  return nil
end

--- The newest n loads, each with its silos and where each went:
-- { load, when, drone, silos = { { silo, sticker, items, dest, drops = { row, ... } } } }
function C.summary(rows, n)
  local loads, order = {}, {}
  for _, r in ipairs(rows) do
    local L = loads[r.load]
    if not L then
      L = { load = r.load, when = r.when, drone = r.drone, silos = {}, bySticker = {} }
      loads[r.load] = L
      order[#order + 1] = r.load
    end
    if r.state == "loaded" then
      local s = L.bySticker[r.sticker]
      if not s then
        s = { silo = r.silo, sticker = r.sticker, items = {}, dest = r.dest, drops = {} }
        L.bySticker[r.sticker] = s
        L.silos[#L.silos + 1] = s
      end
      if r.item ~= "?" and r.item ~= "" then s.items[r.item] = (s.items[r.item] or 0) + (r.count or 0) end
    else
      -- a drop: onto the silo that holds that sticker
      for _, s in ipairs(L.silos) do
        if holds(s.sticker, r.sticker) then s.drops[#s.drops + 1] = r end
      end
    end
  end
  local out = {}
  for i = math.max(1, #order - (n or 10) + 1), #order do out[#out + 1] = loads[order[i]] end
  return out
end

return C
