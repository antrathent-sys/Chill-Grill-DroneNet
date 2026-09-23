--- pads: the named places the fleet knows, of which there are exactly two kinds.
--
--   DOCK  a built facility: the connector latches, the craft charges, and
--         cargo can be loaded. A craft may sit at one indefinitely. Recording
--         one means standing the craft on it, because the coordinates have to
--         be the connector's to a block.
--   PAD   a known-good place to land. Nothing is provided and nothing latches;
--         it is simply somewhere a craft will not tip over or land in a lake.
--         A pad can be typed in from the map.
--
-- The difference decides what a craft is told to do: it FERRIES to a dock and
-- it LANDS at a pad. Getting that wrong means asking a craft to latch onto a
-- field, so the kind is a field in the record and not a convention.
--
-- Both carry block coordinates as F3 shows them and the landing altitude (for
-- a dock, the block the connector stands on - the same y `fly dock` takes),
-- plus optional per-pad trims for a connector that is not directly under the
-- centre of mass.
--
-- The list lives in a file on the computer (fly.lua CFG.PADS_FILE, "pads.lua")
-- and NOT in the repo: pads are per world, and startup would overwrite them.
-- `fly pad add <name> [dock|pad]` writes it from where the craft is standing;
-- `ops place add <name> <x> <z> [y] [dock|pad]` types one in from the map.
--
--   local pads = dofile("lib/pads.lua")
--   local list, bad = pads.load("pads.lua", fs)
--   local depot = pads.get(list, "depot")
--
-- Pure: every function takes what it needs, and file access goes through the
-- fs table passed in (fly.lua passes CC's), so it all tests on the desktop.

local pads = {}
pads.VERSION = 1

-- The home dock is the one place every part of the service knows, so it has
-- one name everywhere: `home` on the command line (short to type, and what
-- fly, ops and the tariff already use) and CINDER HQ on every screen. Any
-- place can carry its own `label` to be shown by; this is the default for
-- home. The brand itself is in lib/hailui.lua (M.NAME).
pads.HOME = "home"
pads.HOME_LABEL = "CINDER HQ"
pads.LABEL_MAX = 18

--- What to call a place on a screen: its own label, the home dock's standard
-- name, or the name itself. Always upper case, as the screens are.
function pads.label(p)
  if type(p) == "string" then p = { name = p } end
  if type(p) ~= "table" then return "" end
  local name = tostring(p.name or "")
  if type(p.label) == "string" and p.label ~= "" then return p.label:upper() end
  if name:lower() == pads.HOME then return pads.HOME_LABEL end
  return name:upper()
end

local function num(v)
  if type(v) ~= "number" or v ~= v then return nil end
  return v
end

--- Check one entry. Returns a clean pad, or nil and why not.
function pads.check(e)
  if type(e) ~= "table" then return nil, "not a table" end
  local name = type(e.name) == "string" and (e.name:lower():gsub("%s+", "")) or ""
  if name == "" then return nil, "no name" end
  if not name:match("^[%w_%-]+$") then
    return nil, "name " .. name .. " is not plain (letters, digits, - and _)"
  end
  local x, y, z = num(e.x), num(e.y), num(e.z)
  if not (x and y and z) then return nil, name .. " needs x, y and z numbers" end
  -- A record with no kind at all predates the field, and everything written
  -- before it existed was put there by standing a craft on the spot - home
  -- included - so it is a dock. Both commands that write places now name the
  -- kind outright (`fly pad add` a dock, `ops place add` a pad), so this only
  -- ever applies to an old file.
  local kind = type(e.kind) == "string" and e.kind:lower() or "dock"
  if kind ~= "dock" and kind ~= "pad" then
    return nil, name .. ": kind must be dock or pad, not " .. kind
  end
  -- what customers see this place called, when it is not just the name
  local label
  if e.label ~= nil and e.label ~= "" then
    label = type(e.label) == "string" and e.label:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "") or ""
    if not label:match("^[%w _%-%.]+$") or #label > pads.LABEL_MAX then
      return nil, name .. ": a label is up to " .. pads.LABEL_MAX .. " letters, digits, spaces, - _ ."
    end
  end
  return { name = name, x = x, y = y, z = z, kind = kind, label = label,
           trimX = num(e.trimX) or 0, trimZ = num(e.trimZ) or 0,
           cruiseY = num(e.cruiseY),
           note = type(e.note) == "string" and e.note or nil }
end

--- Is this one a dock - somewhere a craft can latch on and charge?
function pads.isDock(e) return type(e) == "table" and e.kind == "dock" end

--- Just the docks, or just the landing pads.
function pads.ofKind(list, kind)
  local out = {}
  for _, e in ipairs(list or {}) do if (e.kind or "dock") == kind then out[#out + 1] = e end end
  return out
end

--- A list of entries -> the pads that check out, in order, plus complaints
-- about the ones that did not. One bad line never loses the rest.
function pads.parse(t)
  local list, bad = {}, {}
  if type(t) ~= "table" then return list, { "the pads file did not return a table" } end
  local seen = {}
  for i, e in ipairs(t) do
    local p, why = pads.check(e)
    if not p then
      bad[#bad + 1] = string.format("entry %d: %s", i, why)
    elseif seen[p.name] then
      bad[#bad + 1] = p.name .. " is listed twice - keeping the first"
    else
      seen[p.name] = true
      list[#list + 1] = p
    end
  end
  return list, bad
end

--- Look a pad up by name, any case. nil if there is no such pad.
function pads.get(list, name)
  if type(name) ~= "string" then return nil end
  name = name:lower()
  for _, p in ipairs(list or {}) do
    if p.name == name then return p end
  end
  return nil
end

function pads.names(list)
  local t = {}
  for _, p in ipairs(list or {}) do t[#t + 1] = p.name end
  return t
end

function pads.dist(p, x, z)
  local dx, dz = (p.x or 0) - (x or 0), (p.z or 0) - (z or 0)
  return math.sqrt(dx * dx + dz * dz)
end

function pads.nearest(list, x, z)
  local best, bd
  for _, p in ipairs(list or {}) do
    local d = pads.dist(p, x, z)
    if not bd or d < bd then best, bd = p, d end
  end
  return best, bd
end

--- The file text for a list: plain Lua, meant to be readable and editable.
function pads.serialise(list)
  local out = {
    "-- DroneNet places, one per line. kind = \"dock\" is a built facility the",
    "-- craft latches onto and charges at; kind = \"pad\" is somewhere it is",
    "-- simply safe to land. A craft FERRIES to a dock and LANDS at a pad.",
    "-- x, y, z are F3 block coordinates and y is the PAD block, the same",
    "-- number `fly dock <x> <y> <z>` takes. trimX/trimZ shift the park point",
    "-- for a pad whose connector is not under the centre of mass; cruiseY is",
    "-- the altitude to travel there at. label is what customers see it called",
    "-- Written by `fly pad add <name> [dock|pad]` and `ops place add`, and",
    "-- safe to edit by hand.",
    "return {",
  }
  for _, p in ipairs(list or {}) do
    local parts = { string.format("name = %q, kind = %q, x = %g, y = %g, z = %g",
                                  p.name, p.kind or "pad", p.x, p.y, p.z) }
    if (p.trimX or 0) ~= 0 then parts[#parts + 1] = string.format("trimX = %g", p.trimX) end
    if (p.trimZ or 0) ~= 0 then parts[#parts + 1] = string.format("trimZ = %g", p.trimZ) end
    if p.label then parts[#parts + 1] = string.format("label = %q", p.label) end
    if p.cruiseY then parts[#parts + 1] = string.format("cruiseY = %g", p.cruiseY) end
    if p.note then parts[#parts + 1] = string.format("note = %q", p.note) end
    out[#out + 1] = "  { " .. table.concat(parts, ", ") .. " },"
  end
  out[#out + 1] = "}"
  return table.concat(out, "\n") .. "\n"
end

--- Read the file. Returns the list and any complaints; a file that is not
-- there is not a complaint, it is an empty list. The chunk runs with no
-- environment at all, so a pads file can only describe pads.
function pads.load(path, fsys)
  fsys = fsys or fs
  if not (fsys and fsys.exists and fsys.exists(path)) then return {}, {} end
  local f = fsys.open(path, "r")
  if not f then return {}, { "could not open " .. path } end
  local text = f.readAll() or ""
  f.close()
  local chunk, err
  if setfenv then
    chunk, err = (loadstring or load)(text, "pads")
    if chunk then setfenv(chunk, {}) end
  else
    chunk, err = load(text, "pads", "t", {})
  end
  if not chunk then return {}, { path .. ": " .. tostring(err) } end
  local ok, t = pcall(chunk)
  if not ok then return {}, { path .. ": " .. tostring(t) } end
  return pads.parse(t)
end

--- Write the list back. Returns true, or false and why not.
function pads.save(path, list, fsys)
  fsys = fsys or fs
  local f = fsys.open(path, "w")
  if not f then return false, "could not write " .. path end
  f.write(pads.serialise(list))
  f.close()
  return true
end

--- Add a pad, or replace the one with that name. Returns the list and the
-- pad, or nil and why not.
function pads.put(list, entry)
  local p, why = pads.check(entry)
  if not p then return nil, why end
  for i, old in ipairs(list) do
    if old.name == p.name then
      list[i] = p
      return list, p
    end
  end
  list[#list + 1] = p
  return list, p
end

--- Drop a pad by name. Returns the pad that went, or nil.
function pads.remove(list, name)
  if type(name) ~= "string" then return nil end
  name = name:lower()
  for i, p in ipairs(list) do
    if p.name == name then
      table.remove(list, i)
      return p
    end
  end
  return nil
end

return pads
