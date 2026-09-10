-- Test lib/db.lua against a real filesystem, outside Minecraft.
--   python tools/run_db_test.py
-- Stubs the CC `fs` and `textutils` APIs over Lua's io library, then exercises
-- put/get/delete/iter/find/compact, crash recovery from a torn line, and the
-- disk-full guard.

local DIR = ... or "."
local function path(p) return DIR .. "/" .. p end

-- ---------- textutils stub: strict one-line JSON ----------
local function esc(s)
  s = s:gsub('[\\"]', '\\%0')
  s = s:gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
  return s
end

local function isArray(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" then return false end
    n = n + 1
  end
  return n == #t
end

local function jenc(v)
  local ty = type(v)
  if ty == "nil" then return "null"
  elseif ty == "boolean" then return tostring(v)
  elseif ty == "number" then return string.format("%.14g", v)
  elseif ty == "string" then return '"' .. esc(v) .. '"'
  elseif ty == "table" then
    local parts = {}
    if isArray(v) then
      for _, item in ipairs(v) do parts[#parts + 1] = jenc(item) end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    for _, k in ipairs(keys) do parts[#parts + 1] = '"' .. esc(k) .. '":' .. jenc(v[k]) end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  error("jenc: " .. ty)
end

local function jdec(s)
  local pos = 1
  local function skip() while pos <= #s and s:sub(pos, pos):match("%s") do pos = pos + 1 end end
  local parse
  local function pstr()
    pos = pos + 1
    local out = {}
    while true do
      local c = s:sub(pos, pos)
      if c == "" then error("eof in string") end
      if c == '"' then pos = pos + 1 break end
      if c == "\\" then
        local n = s:sub(pos + 1, pos + 1)
        local map = { n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\" }
        out[#out + 1] = map[n] or n
        pos = pos + 2
      else
        out[#out + 1] = c
        pos = pos + 1
      end
    end
    return table.concat(out)
  end
  parse = function()
    skip()
    local c = s:sub(pos, pos)
    if c == '"' then return pstr() end
    if c == "{" then
      pos = pos + 1
      local t = {}
      skip()
      if s:sub(pos, pos) == "}" then pos = pos + 1 return t end
      while true do
        skip()
        local k = pstr()
        skip()
        pos = pos + 1 -- ':'
        t[k] = parse()
        skip()
        local d = s:sub(pos, pos)
        pos = pos + 1
        if d == "}" then break end
      end
      return t
    end
    if c == "[" then
      pos = pos + 1
      local t = {}
      skip()
      if s:sub(pos, pos) == "]" then pos = pos + 1 return t end
      while true do
        t[#t + 1] = parse()
        skip()
        local d = s:sub(pos, pos)
        pos = pos + 1
        if d == "]" then break end
      end
      return t
    end
    local lit = s:match("^[%w%.%+%-eE]+", pos)
    if not lit then error("bad json at " .. pos) end
    pos = pos + #lit
    if lit == "true" then return true end
    if lit == "false" then return false end
    if lit == "null" then return nil end
    return tonumber(lit)
  end
  local ok, v = pcall(parse)
  if not ok then return nil, v end
  return v
end

_G.textutils = {
  serializeJSON = jenc,
  unserializeJSON = function(str) return jdec(str) end,
}

-- ---------- fs stub over real files ----------
local FREE = { bytes = 1000 * 1000 }   -- mimic computer_space_limit

local function fileSize(p)
  local f = io.open(p, "rb")
  if not f then return 0 end
  local n = f:seek("end")
  f:close()
  return n
end

_G.fs = {
  exists = function(p)
    local f = io.open(p, "rb")
    if f then f:close() return true end
    return false
  end,
  delete = function(p) os.remove(p) end,
  move = function(a, b) os.rename(a, b) end,
  getFreeSpace = function() return FREE.bytes end,
  open = function(p, mode)
    local m = mode == "a" and "ab" or (mode == "w" and "wb" or "rb")
    local f = io.open(p, m)
    if not f then return nil end
    return {
      readLine = function()
        local l = f:read("*l")
        return l
      end,
      readAll = function() return f:read("*a") end,
      writeLine = function(t) f:write(t, "\n") end,
      write = function(t) f:write(t) end,
      seek = function(whence, off) return f:seek(whence or "cur", off or 0) end,
      flush = function() f:flush() end,
      close = function() f:close() end,
    }
  end,
}

-- ---------- tests ----------
local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then
    pass = pass + 1
    print("  ok   " .. name)
  else
    fail = fail + 1
    print("  FAIL " .. name .. (detail and ("  " .. tostring(detail)) or ""))
  end
end

local DB = path("orders.db")
os.remove(DB)
os.remove(DB .. ".new")

local db = dofile(DIR .. "/../lib/db.lua")

print("basic put/get")
local d = db.open(DB)
d:put("o-1", { customer = "alex", state = "placed", cost = 120 })
d:put("o-2", { customer = "sam", state = "placed", cost = 45 })
check("count is 2", d:count() == 2, d:count())
check("get returns record", d:get("o-1") and d:get("o-1").customer == "alex")
check("get on missing key is nil", d:get("nope") == nil)
check("has works", d:has("o-2") and not d:has("nope"))

print("overwrite")
d:put("o-1", { customer = "alex", state = "delivered", cost = 120 })
check("value updated", d:get("o-1").state == "delivered", d:get("o-1").state)
check("count unchanged", d:count() == 2, d:count())

print("nested and array values survive round trip")
d:put("o-3", {
  customer = "kim",
  dest = { x = 1234, y = 72, z = -889 },
  items = { { n = "minecraft:iron_ingot", c = 64 }, { n = "minecraft:coal", c = 12 } },
})
local r3 = d:get("o-3")
check("nested table", r3.dest.z == -889, r3.dest.z)
check("array of tables", #r3.items == 2 and r3.items[2].n == "minecraft:coal")

print("strings with newlines do not corrupt the log")
d:put("o-note", { note = "line one\nline two\twith tab" })
check("newline survives", d:get("o-note").note == "line one\nline two\twith tab",
      "(" .. tostring(d:get("o-note") and d:get("o-note").note) .. ")")
check("still 4 records", d:count() == 4, d:count())

print("iterate and find")
local seen = 0
for _ in d:iter() do seen = seen + 1 end
check("iter yields live only", seen == 4, seen)
local placed = d:find(function(_, v) return v.state == "placed" end)
check("find by predicate", #placed == 1 and placed[1].key == "o-2", #placed)

print("delete")
d:delete("o-2")
check("count drops", d:count() == 3, d:count())
check("deleted key gone", d:get("o-2") == nil)
local afterDel = 0
for _ in d:iter() do afterDel = afterDel + 1 end
check("iter skips tombstoned", afterDel == 3, afterDel)

print("reopen rebuilds the index from disk")
d:close()
local d2 = db.open(DB)
check("count survives reopen", d2:count() == 3, d2:count())
check("value survives reopen", d2:get("o-1").state == "delivered")
check("delete survives reopen", d2:get("o-2") == nil)

print("compaction")
local before = d2:stats()
d2:compact()
local after = d2:stats()
check("dead bytes reclaimed", after.dead == 0 and after.size < before.size,
      before.size .. " -> " .. after.size)
check("records intact after compact", d2:count() == 3, d2:count())
check("data intact after compact", d2:get("o-3").dest.x == 1234)
check("no temp file left", not fs.exists(DB .. ".new"))

print("crash recovery: torn final line")
d2:close()
local f = io.open(DB, "ab")
f:write('{"k":"o-torn","v":{"cust')     -- half a record, no newline
f:close()
local d3 = db.open(DB)
check("torn tail dropped", d3:count() == 3, d3:count())
check("good records kept", d3:get("o-1") ~= nil and d3:get("o-3") ~= nil)
d3:put("o-4", { customer = "after-crash" })
check("writable after recovery", d3:get("o-4").customer == "after-crash")

print("disk-full guard")
FREE.bytes = 100
local okPut = pcall(function() d3:put("o-5", { customer = "should-fail" }) end)
check("put refuses when nearly full", not okPut)
FREE.bytes = 1000 * 1000
check("still works once space returns", pcall(function() d3:put("o-5", { customer = "fine" }) end))

print("")
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then error("db tests failed", 0) end
