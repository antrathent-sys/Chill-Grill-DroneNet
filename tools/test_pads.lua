-- Desktop tests for lib/pads.lua: the named dock point list, its file format,
-- and the round trip `fly pad add` depends on.
local DIR = ...
local pass, fail = 0, 0
local function check(n, c, d)
  if c then pass = pass + 1 print("  ok   " .. n)
  else fail = fail + 1 print("  FAIL " .. n .. (d and ("  " .. tostring(d)) or "")) end
end

local pads = dofile(DIR .. "/../lib/pads.lua")

-- a computer's disk: name -> text
local function disk(files)
  local d = { files = files or {} }
  d.fs = {
    exists = function(p) return d.files[p] ~= nil end,
    open = function(p, mode)
      if mode == "r" then
        local text = d.files[p]
        if not text then return nil end
        return { readAll = function() return text end, close = function() end }
      end
      local buf = {}
      return { write = function(s) buf[#buf + 1] = s end, close = function() d.files[p] = table.concat(buf) end }
    end,
  }
  return d
end

print("check")
local p = pads.check({ name = "Depot", x = -1500, y = 72, z = 2200 })
check("a pad checks out, name lowercased", p and p.name == "depot" and p.x == -1500 and p.y == 72 and p.z == 2200, p and p.name)
check("trims default to zero", p.trimX == 0 and p.trimZ == 0 and p.cruiseY == nil)
check("optional fields kept", (pads.check({ name = "a", x = 1, y = 2, z = 3, trimX = 0.5, cruiseY = 300, note = "north shed" }) or {}).cruiseY == 300)
check("no name refused", select(2, pads.check({ x = 1, y = 2, z = 3 })) == "no name")
check("a name with punctuation refused", (select(2, pads.check({ name = "de pot!", x = 1, y = 2, z = 3 }))):find("not plain") ~= nil)
check("missing coordinates refused", (select(2, pads.check({ name = "depot", y = 2, z = 3 }))):find("needs x, y and z") ~= nil)
check("a string coordinate refused", pads.check({ name = "depot", x = "1500", y = 2, z = 3 }) == nil)
check("not a table refused", select(2, pads.check("depot")) == "not a table")

print("parse")
local list, bad = pads.parse({
  { name = "home", x = 0, y = 63, z = 0 },
  { name = "depot", x = -1500, y = 72, z = 2200 },
  { name = "depot", x = 5, y = 5, z = 5 },
  { name = "broken", y = 1 },
})
check("good entries kept in order", #list == 2 and list[1].name == "home" and list[2].name == "depot")
check("the first of a duplicate wins", list[2].x == -1500)
check("both problems reported", #bad == 2 and bad[1]:find("twice") and bad[2]:find("entry 4"), table.concat(bad, "; "))
check("a non-table file complains", (select(2, pads.parse("nope")))[1]:find("did not return a table") ~= nil)

print("lookup")
check("get is case-insensitive", pads.get(list, "DEPOT").x == -1500)
check("get misses cleanly", pads.get(list, "nowhere") == nil and pads.get(list, nil) == nil)
check("names in order", table.concat(pads.names(list), ",") == "home,depot")
local near, d = pads.nearest(list, -1490, 2190)
check("nearest pad and its distance", near.name == "depot" and math.abs(d - math.sqrt(200)) < 1e-6, d)
check("nearest of nothing is nothing", pads.nearest({}, 0, 0) == nil)

print("file")
local text = pads.serialise(list)
check("serialise writes a Lua table", text:find("return {", 1, true) and text:find('name = "depot"', 1, true))
check("zero trims are left out of the entries", not text:find("trimX =", 1, true))
local d1 = disk()
check("save then load round-trips", pads.save("pads.lua", list, d1.fs)
  and (function()
    local back, b = pads.load("pads.lua", d1.fs)
    return #b == 0 and #back == 2 and back[2].name == "depot" and back[2].y == 72
  end)())
local full = { { name = "shed", x = 1.5, y = 2, z = -3, trimX = 0.5, trimZ = -0.5, cruiseY = 280, note = "by the trees" } }
local d2 = disk()
pads.save("pads.lua", full, d2.fs)
local back2 = pads.load("pads.lua", d2.fs)
check("trims, cruise altitude and note survive", back2[1].trimX == 0.5 and back2[1].trimZ == -0.5
  and back2[1].cruiseY == 280 and back2[1].note == "by the trees")
check("no file is an empty list, not an error", (function()
  local l, b = pads.load("pads.lua", disk().fs)
  return #l == 0 and #b == 0
end)())
check("a broken file complains and loses nothing else", (function()
  local l, b = pads.load("pads.lua", disk({ ["pads.lua"] = "return { { name = " }).fs)
  return #l == 0 and #b == 1 and b[1]:find("pads.lua:", 1, true) ~= nil
end)())
check("a pads file cannot reach the computer", (function()
  local l, b = pads.load("pads.lua", disk({ ["pads.lua"] = "fs.delete('everything') return {}" }).fs)
  return #l == 0 and #b == 1
end)())

print("edit")
local l3 = { { name = "home", x = 0, y = 63, z = 0 } }
pads.put(l3, { name = "depot", x = 10, y = 70, z = 20 })
check("put adds", #l3 == 2 and l3[2].name == "depot")
pads.put(l3, { name = "DEPOT", x = 11, y = 71, z = 21 })
check("put replaces by name, keeping position in the list", #l3 == 2 and l3[2].x == 11 and l3[2].y == 71)
check("put refuses a bad pad", select(1, pads.put(l3, { name = "x" })) == nil and #l3 == 2)
check("remove returns what it removed", pads.remove(l3, "Depot").x == 11 and #l3 == 1)
check("remove of a stranger does nothing", pads.remove(l3, "nowhere") == nil and #l3 == 1)

print("")
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then error("pads tests failed", 0) end
