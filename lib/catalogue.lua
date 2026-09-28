--- catalogue: what Cinder supplies, read from reference inventories at the base.
--
-- One of each item we sell sits in a chest, a vault, or a row of either at
-- the base (Alex, 2026-09-28). Whatever is in them is the catalogue: adding a
-- product is dropping one in, dropping one is taking it out. Reading them
-- gives every item's exact id - modded namespaces included, no typos - its
-- display name and its stack size, which is everything an order needs to name
-- an item and pack it into silos.
--
-- `ops catalogue read` writes it to catalogue.lua and keeps that in the repo,
-- in the base's machine folder, so tools/schematic.py on the desktop quotes a
-- customer's build against it and a website can one day show it. One entry per
-- line, so a script that is not Lua can read it too.
--
-- Items are told apart by id alone: two enchanted books with different
-- enchantments are one entry. Pure - the inventories come in through `call` -
-- so tools/test_catalogue.lua runs all of it on the desktop.

local C = {}

local function str(v) return type(v) == "string" and v ~= "" end

--- Read the inventories. invs: a list of peripheral names. call(name, method,
-- ...) is peripheral.call, or a stand-in. Returns the entries - { name, label,
-- stack }, one per item id, sorted by label - and a list of problems, one per
-- inventory that could not be read.
function C.read(invs, call)
  local byName, problems = {}, {}
  for _, inv in ipairs(invs or {}) do
    local okL, slots = pcall(call, inv, "list")
    if not (okL and type(slots) == "table") then
      problems[#problems + 1] = inv .. ": cannot be read - not an inventory, or not on this network"
    else
      for slot, it in pairs(slots) do
        if type(it) == "table" and str(it.name) and not byName[it.name] then
          local okD, d = pcall(call, inv, "getItemDetail", slot)
          d = (okD and type(d) == "table") and d or {}
          byName[it.name] = {
            name = it.name,
            label = str(d.displayName) and d.displayName or it.name,
            stack = tonumber(d.maxCount) or 64,
          }
        end
      end
    end
  end
  local out = {}
  for _, e in pairs(byName) do out[#out + 1] = e end
  table.sort(out, function(a, b)
    if a.label:lower() ~= b.label:lower() then return a.label:lower() < b.label:lower() end
    return a.name < b.name
  end)
  return out, problems
end

--- The file: a header naming where it came from, then one entry a line.
function C.serialize(entries, sources)
  local out = {
    "-- The Cinder catalogue: everything we supply. Read from the reference",
    "-- inventories at the base by `ops catalogue read`, which writes this file and",
    "-- keeps it in the repo. Change the chests, not this file.",
    "-- sources: " .. table.concat(sources or {}, " "),
    "return {",
  }
  for _, e in ipairs(entries or {}) do
    out[#out + 1] = string.format("  { name = %q, label = %q, stack = %d },",
      e.name, e.label or e.name, math.floor(tonumber(e.stack) or 64))
  end
  out[#out + 1] = "}"
  return table.concat(out, "\n") .. "\n"
end

--- Back from the file's text: entries, and the inventories it was read from.
function C.parse(text)
  text = tostring(text or "")
  local sources = {}
  local line = text:match("%-%- sources:([^\n]*)")
  if line then for s in line:gmatch("%S+") do sources[#sources + 1] = s end end
  -- CC's load takes a string and an environment; plain Lua 5.1's takes only a
  -- function, so fall back to loadstring there (the desktop tests run on 5.1)
  local okF, fn = pcall(load, text, "catalogue", "t", {})
  if not (okF and type(fn) == "function") then
    fn = loadstring and loadstring(text, "catalogue")
    if fn and setfenv then setfenv(fn, {}) end
  end
  local ok, t = false, nil
  if fn then ok, t = pcall(fn) end
  local entries = {}
  if ok and type(t) == "table" then
    for _, e in ipairs(t) do
      if type(e) == "table" and str(e.name) then
        entries[#entries + 1] = { name = e.name, label = str(e.label) and e.label or e.name,
                                  stack = tonumber(e.stack) or 64 }
      end
    end
  end
  return entries, sources
end

function C.load(path, fsys)
  if not (fsys and fsys.exists and fsys.exists(path)) then return nil, {} end
  local h = fsys.open(path, "r")
  if not h then return nil, {} end
  local text = h.readAll() or ""
  h.close()
  return C.parse(text)
end

local function squash(s) return (tostring(s or ""):lower():gsub("[%s%-]+", "_")) end

--- The entry a word typed in an order means: the exact id
-- (minecraft:cobblestone), the id without its namespace (cobblestone), or
-- the display name with underscores for spaces (light_gray_concrete_powder).
-- Returns the entry, or nil and up to five entries whose id or name contains
-- the word, as suggestions.
function C.find(entries, word)
  local w = squash(word)
  if w == "" then return nil, {} end
  local bare = {}
  for _, e in ipairs(entries or {}) do
    if e.name:lower() == w then return e end
    if (e.name:match(":(.+)$") or e.name):lower() == w then bare[#bare + 1] = e end
  end
  if #bare == 1 then return bare[1] end
  if #bare > 1 then return nil, bare end       -- the same name in two mods: say which
  for _, e in ipairs(entries or {}) do
    if squash(e.label) == w then return e end
  end
  local near = {}
  for _, e in ipairs(entries or {}) do
    if #near < 5 and (e.name:lower():find(w, 1, true) or squash(e.label):find(w, 1, true)) then
      near[#near + 1] = e
    end
  end
  return nil, near
end

return C
