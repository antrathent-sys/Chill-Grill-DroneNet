--- db: a small log-structured key/value store for CC:Tweaked.
--
-- Why this shape. A CC computer has a 1,000,000 byte disk (config
-- `computer_space_limit`; a floppy is 125,000). Rewriting a whole table on
-- every change is O(n) on a slow machine and loses everything if the game
-- stops mid-write. So instead:
--
--   * writes append one line and nothing else, which is O(1) and crash-safe
--   * an in-memory index maps key -> byte offset, so reads seek straight there
--   * scans read line by line, never loading the file into memory
--   * compaction rewrites the log without the dead records, when you ask
--
-- A torn final line from a crash fails to parse and is dropped on the next
-- open, costing at most the last write.
--
--   local db  = dofile("lib/db.lua")
--   local ord = db.open("orders")
--   ord:put("o-1042", { customer = "alex", state = "placed", cost = 120 })
--   local rec = ord:get("o-1042")
--   for key, r in ord:iter() do ... end
--   ord:compact()
--   ord:close()

local db = {}

local Store = {}
Store.__index = Store

-- JSON, deliberately, not textutils.serialize. On Lua 5.1 `%q` escapes a
-- newline inside a string as a backslash followed by a REAL newline, which
-- would split one record across two lines and silently corrupt the log. JSON
-- escapes it as a backslash-n escape and can never emit a raw newline.
--
-- The cost is that records must be JSON-representable: string keys, and
-- values that are strings, numbers, booleans, arrays or nested tables of
-- those. That is no restriction for order and mission records.
local function encode(t) return textutils.serializeJSON(t) end

local function decode(s)
  if type(s) ~= "string" or s == "" then return nil end
  local ok, v = pcall(textutils.unserializeJSON, s)
  if not ok then return nil end
  return v
end

--- Rebuild the key -> offset index by streaming the file once.
-- Returns the index, live count, dead bytes, and the offset of the first torn
-- byte if the log ends in a partial write.
local function reindex(path)
  local index, live, dead, size = {}, 0, 0, 0
  if not fs.exists(path) then return index, 0, 0, nil end

  local h = fs.open(path, "r")
  if not h then error("db: cannot open " .. path) end

  local off, torn = 0, nil
  while true do
    local line = h.readLine()
    if not line then break end
    local n = #line + 1                  -- +1 for the newline we wrote
    local rec = decode(line)
    if type(rec) ~= "table" or rec.k == nil then
      -- Only the final line may legitimately be torn. Anything earlier means
      -- real corruption, so stop and let compaction drop the tail.
      torn = off
      break
    end
    if index[rec.k] then dead = dead + index[rec.k].len end
    if rec.d then
      if index[rec.k] then live = live - 1 end
      index[rec.k] = nil
      dead = dead + n
    else
      if not index[rec.k] then live = live + 1 end
      index[rec.k] = { off = off, len = n }
    end
    off = off + n
    size = off
  end
  h.close()
  return index, live, dead, torn, size
end

--- Open (or create) a store.
-- @tparam string path file to back the store with
-- @tparam[opt] table opts `reserve` bytes of free space to keep spare
function db.open(path, opts)
  opts = opts or {}
  local index, live, dead, torn, size = reindex(path)
  local self = setmetatable({
    path = path,
    index = index,
    live = live,
    dead = dead,
    size = size or 0,
    reserve = opts.reserve or 8192,
    torn = torn,
  }, Store)
  if torn then self:compact() end       -- drop the partial tail immediately
  return self
end

--- Number of live records.
function Store:count() return self.live end

--- Is a key present?
function Store:has(key) return self.index[key] ~= nil end

--- Read one record. Seeks straight to it, so this does not scan.
function Store:get(key)
  local e = self.index[key]
  if not e then return nil end
  local h = fs.open(self.path, "r")
  if not h then return nil end
  h.seek("set", e.off)
  local line = h.readLine()
  h.close()
  local rec = decode(line)
  if type(rec) ~= "table" then return nil end
  return rec.v
end

--- Append a record. Overwrites any previous value for the key.
-- Errors if the disk is nearly full, rather than corrupting the log.
function Store:put(key, value)
  if type(key) ~= "string" then error("db: key must be a string", 2) end
  local line = encode({ k = key, v = value })
  local need = #line + 1

  local free = fs.getFreeSpace(self.path)
  if free ~= nil and free < need + self.reserve then
    error("db: disk nearly full (" .. tostring(free) .. " bytes free), compact or archive", 2)
  end

  local h = fs.open(self.path, "a")
  if not h then error("db: cannot append to " .. self.path) end
  h.writeLine(line)
  h.close()

  local prev = self.index[key]
  if prev then self.dead = self.dead + prev.len else self.live = self.live + 1 end
  self.index[key] = { off = self.size, len = need }
  self.size = self.size + need
  return true
end

--- Append a tombstone. The bytes come back on the next compaction.
function Store:delete(key)
  if not self.index[key] then return false end
  local line = encode({ k = key, d = true })
  local h = fs.open(self.path, "a")
  if not h then error("db: cannot append to " .. self.path) end
  h.writeLine(line)
  h.close()
  self.dead = self.dead + self.index[key].len + #line + 1
  self.size = self.size + #line + 1
  self.index[key] = nil
  self.live = self.live - 1
  return true
end

--- Iterate live records, streaming the file. Never holds it all in memory.
-- Yields key, value.
function Store:iter()
  local h = fs.exists(self.path) and fs.open(self.path, "r") or nil
  local off = 0
  return function()
    if not h then return nil end
    while true do
      local line = h.readLine()
      if not line then h.close() h = nil return nil end
      local n = #line + 1
      local rec = decode(line)
      local here = off
      off = off + n
      -- Only yield the entry the index still points at, so superseded
      -- versions and tombstoned keys are skipped.
      if type(rec) == "table" and rec.k and not rec.d then
        local e = self.index[rec.k]
        if e and e.off == here then return rec.k, rec.v end
      end
    end
  end
end

--- Collect records matching a predicate. Returns an array of {key, value}.
function Store:find(pred, limit)
  local out = {}
  for key, value in self:iter() do
    if pred(key, value) then
      out[#out + 1] = { key = key, value = value }
      if limit and #out >= limit then break end
    end
  end
  return out
end

--- Rewrite the log with only live records. Safe against a crash mid-write:
-- the new file is built alongside and only swapped in once complete.
function Store:compact()
  local tmp = self.path .. ".new"
  if fs.exists(tmp) then fs.delete(tmp) end

  local out = fs.open(tmp, "w")
  if not out then error("db: cannot write " .. tmp) end

  local index, off, live = {}, 0, 0
  -- Stream the old file rather than loading it, same as iter().
  if fs.exists(self.path) then
    local h = fs.open(self.path, "r")
    local scan = 0
    while true do
      local line = h.readLine()
      if not line then break end
      local n = #line + 1
      local rec = decode(line)
      local here = scan
      scan = scan + n
      if type(rec) == "table" and rec.k and not rec.d then
        local e = self.index[rec.k]
        if e and e.off == here then
          out.writeLine(line)
          index[rec.k] = { off = off, len = n }
          off = off + n
          live = live + 1
        end
      end
    end
    h.close()
  end
  out.close()

  if fs.exists(self.path) then fs.delete(self.path) end
  fs.move(tmp, self.path)

  self.index, self.live, self.dead, self.size, self.torn = index, live, 0, off, nil
  return true
end

--- Bytes reclaimable, and whether it is worth reclaiming them.
function Store:stats()
  return {
    path = self.path,
    live = self.live,
    dead = self.dead,
    size = self.size,
    free = fs.getFreeSpace(self.path),
    -- compact once a third of the file is dead weight
    shouldCompact = self.size > 4096 and self.dead > self.size / 3,
  }
end

function Store:close() self.index = nil end

db.Store = Store
return db
