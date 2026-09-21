--- seclink: sealed messages between drones and the base.
--
-- Every packet on the radio is encrypted AND authenticated with
-- ChaCha20-Poly1305 (vendored ccryptolib, MIT, in ccryptolib/). Nobody without
-- the key can read a position, a route or the home pad, and nobody without the
-- key can make a packet the other side will accept - a forged or altered one
-- fails its tag and is dropped before anything reads it.
--
-- Keys are per drone: 32 random bytes, shared by that drone (.dronekey) and
-- the base (.fleetkeys, one line per drone). Made with `seckey new <id>` on the
-- base and typed or pasted on the drone with `seckey set <hex>`. They never go
-- in the repo (.gitignore) and never over the radio.
--
-- Envelope, the only thing that is transmitted (a flat table):
--   { sl = 1, id = "drone-1", d = <direction>, n = <counter>, c = <ciphertext>, g = <tag> }
-- id, d and n travel in the clear so the receiver can pick the key and check
-- order; all three are bound into the tag as associated data, so changing any
-- of them breaks it. The nonce is the direction byte plus the counter, and the
-- counter is persisted in reserved blocks, so a nonce is never reused under a
-- key even across reboots. The receiver accepts each (id, direction) counter
-- only once and only increasing, and only after the tag has checked out.
--
--   local SEC = dofile("lib/seclink.lua")
--   local key = assert(SEC.readKeyFile(".dronekey"))
--   local tx = SEC.sender(key, "drone-1", SEC.DIR.DRONE_TO_BASE, ".dronekey.ctr")
--   modem.transmit(ch, ch, tx.seal({ type = "tlm", x = 12 }))
--   local rx = SEC.receiver()
--   local msg, why = rx.open(envelope, function(id) return keys[id] end, SEC.DIR.DRONE_TO_BASE)

local S = {}

S.VERSION = 1
S.DIR = { DRONE_TO_BASE = 1, BASE_TO_DRONE = 2 }
S.RESERVE = 64          -- counter values reserved per disk write
S.ROOT = ""             -- where ccryptolib/ lives; tests point this at the repo

-- ---------------------------------------------------------------- crypto lib

-- A loader for the vendored library that works whether or not this chunk has
-- `require` (dofile'd libraries on CC do not).
local cache = {}
local function req(name)
  if cache[name] ~= nil then return cache[name] end
  if package and package.preload and package.preload[name] then
    cache[name] = package.preload[name](name)
    return cache[name]
  end
  local path
  if name == "cc.expect" then
    path = "/rom/modules/main/cc/expect.lua"
  else
    path = S.ROOT .. (name:gsub("%.", "/")) .. ".lua"
  end
  local env = setmetatable({ require = req }, { __index = _G })
  local f, err = loadfile(path, "t", env)
  if not f then error("seclink: cannot load " .. path .. ": " .. tostring(err), 2) end
  if setfenv then pcall(setfenv, f, env) end
  local mod = f(name)
  if mod == nil then mod = true end
  cache[name] = mod
  return mod
end

function S.aead() return req("ccryptolib.aead") end
S._req = req   -- tests seed the random generator through this

-- --------------------------------------------------------------------- keys

function S.keyHex(key)
  return (key:gsub(".", function(ch) return string.format("%02x", ch:byte()) end))
end

--- 64 hex characters (spaces allowed) -> 32-byte key, or nil and why.
function S.parseKey(hex)
  if type(hex) ~= "string" then return nil, "no key" end
  hex = hex:gsub("%s", ""):lower()
  if #hex ~= 64 then return nil, "a key is 64 hex characters, got " .. #hex end
  if hex:find("[^0-9a-f]") then return nil, "a key is hex digits only" end
  return (hex:gsub("..", function(h) return string.char(tonumber(h, 16)) end))
end

--- A fresh random key. Seeds ccryptolib's generator from VM timing noise
-- first if nothing has seeded it (about half a second on CC).
function S.newKey()
  local random = req("ccryptolib.random")
  if not random.isInit() then random.initWithTiming() end
  return random.random(32)
end

local function readAll(path)
  if not (fs and fs.exists and fs.exists(path)) then return nil end
  local h = fs.open(path, "r")
  if not h then return nil end
  local s = h.readAll()
  h.close()
  return s
end

function S.readKeyFile(path)
  local s = readAll(path)
  if not s then return nil, "no key file " .. tostring(path) end
  return S.parseKey(s)
end

--- .fleetkeys: "drone-1=<64 hex>" per line, # comments. Returns { id = key }, count, bad lines.
function S.parseFleetKeys(text)
  local keys, n, bad = {}, 0, 0
  for raw in ((text or "") .. "\n"):gmatch("([^\n]*)\n") do
    local line = raw:gsub("#.*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if line ~= "" then
      local id, hex = line:match("^([%w%-_]+)%s*=%s*(%x+)$")
      local key = id and S.parseKey(hex)
      if key then
        if not keys[id] then n = n + 1 end
        keys[id] = key
      else
        bad = bad + 1
      end
    end
  end
  return keys, n, bad
end

function S.readFleetKeys(path)
  return S.parseFleetKeys(readAll(path) or "")
end

S.CUST_HEADER = "Shuttle customer keys - one line per pass you issued."

--- The text of a key list, sorted by id, under a comment line: the one place
-- the file format is written, so seckey and provision cannot drift apart.
function S.formatFleetKeys(keys, header)
  local ids = {}
  for id in pairs(keys or {}) do ids[#ids + 1] = id end
  table.sort(ids)
  local out = { "# " .. (header or "keys") .. "\n" }
  for _, id in ipairs(ids) do out[#out + 1] = id .. "=" .. S.keyHex(keys[id]) .. "\n" end
  return table.concat(out)
end

-- -------------------------------------------------------------------- codec

-- A flat table as text: key US type value RS ... Numbers, strings and
-- booleans only. Parsed only AFTER the tag has been checked, and even then it
-- is data, never code (no load, no textutils.unserialise).
local RS, US = "\30", "\31"

function S.encode(t)
  local keys = {}
  for k, v in pairs(t) do
    if type(k) ~= "string" or k == "" or k:find("[\30\31]") then error("seclink: bad field name", 2) end
    local tv = type(v)
    if tv ~= "number" and tv ~= "string" and tv ~= "boolean" then
      error("seclink: field " .. k .. " is a " .. tv, 2)
    end
    keys[#keys + 1] = k
  end
  table.sort(keys)
  local out = {}
  for i, k in ipairs(keys) do
    local v = t[k]
    local s
    if type(v) == "number" then
      s = "n" .. string.format("%.17g", v)
    elseif type(v) == "boolean" then
      s = v and "t" or "f"
    else
      if v:find("[\30\31]") then error("seclink: field " .. k .. " holds a separator", 2) end
      s = "s" .. v
    end
    out[i] = k .. US .. s
  end
  return table.concat(out, RS)
end

function S.decode(s)
  if type(s) ~= "string" then return nil end
  local t = {}
  if s == "" then return t end
  for item in (s .. RS):gmatch("([^\30]*)\30") do
    local k, tag, v = item:match("^([^\31]+)\31(.)(.*)$")
    if not k then return nil end
    if tag == "n" then
      v = tonumber(v)
      if not v then return nil end
    elseif tag == "t" then v = true
    elseif tag == "f" then v = false
    elseif tag ~= "s" then return nil end
    t[k] = v
  end
  return t
end

-- ------------------------------------------------------------ seal and open

local function nonceFor(dir, n)
  local b = {}
  local v = n
  for i = 8, 1, -1 do
    b[i] = string.char(v % 256)
    v = math.floor(v / 256)
  end
  return string.char(dir, 0, 0, 0) .. table.concat(b)
end

local function aadFor(id, dir, n)
  return string.format("DRN%d|%s|%d|%.0f", S.VERSION, id, dir, n)
end

local function nowMs()
  if os and os.epoch then
    local ok, v = pcall(os.epoch, "utc")
    if ok and type(v) == "number" then return v end
  end
  return nil
end

--- A sender for one (key, id, direction). ctrPath persists the counter.
function S.sender(key, id, dir, ctrPath)
  local o = { n = 0, mark = 0 }
  local stored = ctrPath and tonumber(readAll(ctrPath) or "")
  if stored then o.n, o.mark = stored, stored end

  local function reserve()
    local mark = o.n + S.RESERVE
    if ctrPath then
      local h = fs.open(ctrPath, "w")
      if not h then return false end
      h.write(tostring(mark))
      h.close()
    end
    o.mark = mark
    return true
  end

  --- Seal a flat table. Adds ts (ms, UTC). Returns the envelope, or nil and why.
  function o.seal(t)
    if o.n + 1 > o.mark and not reserve() then return nil, "cannot persist the counter" end
    o.n = o.n + 1
    local body = {}
    for k, v in pairs(t) do body[k] = v end
    body.ts = body.ts or nowMs()
    local ct, tag = S.aead().encrypt(key, nonceFor(dir, o.n), S.encode(body), aadFor(id, dir, o.n))
    return { sl = S.VERSION, id = id, d = dir, n = o.n, c = ct, g = tag }
  end

  return o
end

--- A receiver. open() returns the message table, or nil and a reason.
-- keyFor(id) -> key or nil. wantDir: the only direction accepted.
-- maxAgeMs (optional): reject messages whose ts is further than this from now.
function S.receiver()
  local last = {}
  local o = {}

  function o.open(env, keyFor, wantDir, maxAgeMs, now)
    if type(env) ~= "table" or env.sl ~= S.VERSION then return nil, "not sealed" end
    local id, d, n, c, g = env.id, env.d, env.n, env.c, env.g
    if type(id) ~= "string" or #id == 0 or #id > 32 then return nil, "bad id" end
    if d ~= wantDir then return nil, "wrong direction" end
    if type(n) ~= "number" or n < 1 or n ~= math.floor(n) or n > 2 ^ 53 then return nil, "bad counter" end
    if type(c) ~= "string" or #c > 8192 or type(g) ~= "string" or #g ~= 16 then return nil, "bad body" end
    local key = keyFor(id)
    if not key then return nil, "unknown drone " .. id end
    local slot = id .. "/" .. d
    if last[slot] and n <= last[slot] then return nil, "replay" end
    local plain = S.aead().decrypt(key, nonceFor(d, n), g, c, aadFor(id, d, n))
    if not plain then return nil, "bad tag" end
    local msg = S.decode(plain)
    if not msg then return nil, "bad encoding" end
    if maxAgeMs then
      now = now or nowMs()
      if now and (type(msg.ts) ~= "number" or math.abs(now - msg.ts) > maxAgeMs) then return nil, "stale" end
    end
    last[slot] = n
    msg.id = id
    return msg
  end

  --- Forget the counters seen from one id. For when its key is replaced: the
  -- new pass counts from 1 again, and without this every message from it would
  -- look like a replay until the base restarted.
  function o.forget(id)
    for slot in pairs(last) do
      if slot:sub(1, #id + 1) == id .. "/" then last[slot] = nil end
    end
  end

  return o
end

return S
