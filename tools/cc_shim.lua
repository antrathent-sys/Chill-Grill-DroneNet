-- cc_shim: TEST-ONLY stand-ins for what CC:Tweaked provides natively, so the
-- vendored ccryptolib runs on desktop Lua (lupa 5.1 and 5.5). Never deployed.
--   bit32      CC has it; Lua 5.1 and 5.3+ do not. Pure arithmetic, 32-bit.
--   load(src)  CC's load takes source strings; plain 5.1 wants loadstring.
--   cc.expect  CC ships it in /rom/modules/main/cc/expect.lua.
--   os.epoch   CC's millisecond clock (ccryptolib.random reads it on load).

if not os.epoch then
  os.epoch = function() return math.floor(os.time() * 1000 + (os.clock() * 1000) % 1000) end
end
if not os.day then
  os.day = function() return math.floor(os.time() / 86400) end
end

if not bit32 then
  local floor = math.floor
  local M = 4294967296
  local function norm(a) return a % M end
  local function op(a, b, fn)
    a, b = norm(a), norm(b)
    local r, bit = 0, 1
    for _ = 1, 32 do
      local x, y = a % 2, b % 2
      if fn(x, y) then r = r + bit end
      a, b, bit = floor(a / 2), floor(b / 2), bit * 2
    end
    return r
  end
  local AND = function(x, y) return x == 1 and y == 1 end
  local OR = function(x, y) return x == 1 or y == 1 end
  local XOR = function(x, y) return x ~= y end
  local function fold(fn, a, b, ...)
    if b == nil then return norm(a) end
    local r = op(a, b, fn)
    if ... ~= nil then return fold(fn, r, ...) end
    return r
  end
  bit32 = {
    band = function(...) return fold(AND, ...) end,
    bor = function(...) return fold(OR, ...) end,
    bxor = function(...) return fold(XOR, ...) end,
    bnot = function(a) return M - 1 - norm(a) end,
    lshift = function(a, n) if n >= 32 then return 0 end return norm(norm(a) * 2 ^ n) end,
    rshift = function(a, n) if n >= 32 then return 0 end return floor(norm(a) / 2 ^ n) end,
    lrotate = function(a, n) n = n % 32 a = norm(a) return norm(a * 2 ^ n) + floor(a / 2 ^ (32 - n)) end,
    rrotate = function(a, n) n = n % 32 a = norm(a) return floor(a / 2 ^ n) + norm(a * 2 ^ (32 - n)) end,
  }
end

if _VERSION == "Lua 5.1" and not _G.__cc_shim_load then
  _G.__cc_shim_load = true
  local load51 = load
  load = function(src, name, mode, env)
    if type(src) ~= "string" then return load51(src, name) end
    local f, err = loadstring(src, name)
    if f and env then setfenv(f, env) end
    return f, err
  end
end

package.preload["cc.expect"] = package.preload["cc.expect"] or function()
  local function expect(i, v, ...)
    local t = type(v)
    for n = 1, select("#", ...) do if select(n, ...) == t then return v end end
    error(("bad argument #%d (%s expected, got %s)"):format(i, table.concat({ ... }, " or "), t), 3)
  end
  return { expect = expect, field = function(t, k, ...) return expect(1, t[k], ...) end }
end
