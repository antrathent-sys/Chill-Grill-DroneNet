-- Desktop tests for stickers.lua: finding Create Stickers among other
-- peripherals, never moving one unasked, the test / extend / retract / hold
-- paths, and redstone pulses.
local DIR = ...
local pass, fail = 0, 0
local function check(n, c, d)
  if c then pass = pass + 1 print("  ok   " .. n)
  else fail = fail + 1 print("  FAIL " .. n .. (d and ("  " .. tostring(d)) or "")) end
end

local SRC = DIR .. "/../stickers.lua"
local STICKER_METHODS = { "toggle", "retract", "isExtended", "extend", "isAttachedToBlock" }

-- a computer: stickers (name -> { ext, flush, fights }), other peripherals
-- (name -> { types, methods }), typed answers, optional http/upload, and
-- opts.wire = { side, sticker }: redstone on that side reaches that sticker,
-- which flips on each rising edge as Create's does. A sticker with `fights`
-- is pulled back in 0.1 s after it is extended.
local function computer(opts)
  local w = { stickers = opts.stickers or {}, others = opts.others or {}, answers = opts.answers or {},
              printed = {}, calls = {}, files = {}, runs = {}, rs = {}, clock = 0, level = {} }
  local env = setmetatable({}, { __index = _G })
  local function out(s) w.printed[#w.printed + 1] = s end
  env.print = function(...)
    local t = {}
    for i = 1, select("#", ...) do t[#t + 1] = tostring((select(i, ...))) end
    out(table.concat(t, " "))
  end
  env.write = function(s) out(tostring(s)) end
  env.read = function() return table.remove(w.answers, 1) end
  env.sleep = function(s) w.clock = w.clock + (s or 0) end
  env.term = { clear = function() end, setCursorPos = function() end }
  env.http = opts.http
  env.fs = {
    exists = function(p) return (p == "upload.lua" and opts.upload == true) or w.files[p] ~= nil end,
    open = function(p)
      local buf = {}
      return { write = function(s) buf[#buf + 1] = s end, close = function() w.files[p] = table.concat(buf) end }
    end,
  }
  env.shell = { run = function(...) w.runs[#w.runs + 1] = table.concat({ ... }, " ") return true end }
  local function signal(where, side, on)
    w.rs[#w.rs + 1] = string.format("%s%s=%s@%.2f", where, side, tostring(on), w.clock)
    local key = where .. side
    local rising = on and not w.level[key]
    w.level[key] = on
    if rising and opts.wire and opts.wire.side == where .. side then
      local s = w.stickers[opts.wire.sticker]
      s.ext = not s.ext
    end
  end
  env.redstone = { setOutput = function(side, on) signal("", side, on) end }
  env.peripheral = {
    getNames = function()
      local t = {}
      for n in pairs(w.stickers) do t[#t + 1] = n end
      for n in pairs(w.others) do t[#t + 1] = n end
      table.sort(t)
      return t
    end,
    isPresent = function(n) return w.stickers[n] ~= nil or w.others[n] ~= nil end,
    getType = function(n)
      if w.stickers[n] then return "Create_Sticker" end
      if w.others[n] then return unpack(w.others[n].types) end
      return nil
    end,
    getMethods = function(n)
      if w.stickers[n] then
        local t = {}
        for i, m in ipairs(STICKER_METHODS) do t[i] = m end
        return t
      end
      return w.others[n] and w.others[n].methods or nil
    end,
    call = function(n, m, a, b)
      w.calls[#w.calls + 1] = n .. "." .. m
      if w.others[n] and m == "setOutput" then return signal(n .. ":", a, b) end
      local s = w.stickers[n]
      if not s then error("no peripheral " .. n, 0) end
      if s.fights and s.ext and w.clock - (s.extAt or 0) >= 0.1 then s.ext = false end
      if m == "isExtended" then return s.ext end
      if m == "isAttachedToBlock" then return s.ext and s.flush or false end
      if m == "extend" then if s.ext then return false end s.ext, s.extAt = true, w.clock return true end
      if m == "retract" then if not s.ext then return false end s.ext = false return true end
      if m == "toggle" then s.ext = not s.ext return true end
      error("no such method " .. m, 0)
    end,
  }
  if not opts.noHasType then
    env.peripheral.hasType = function(n, t)
      if w.stickers[n] then return t == "Create_Sticker" end
      if not w.others[n] then return nil end
      for _, x in ipairs(w.others[n].types) do if x == t then return true end end
      return false
    end
  end
  w.env = env
  return w
end

local function run(w, ...)
  local f = assert(loadfile(SRC))
  setfenv(f, w.env)
  local ok, err = pcall(f, ...)
  w.err = (not ok) and tostring(err) or nil
  w.text = table.concat(w.printed, "\n")
  return w
end

local function has(w, s) return w.text:find(s, 1, true) ~= nil end
local function count(w, name)
  local n = 0
  for _, c in ipairs(w.calls) do if c == name then n = n + 1 end end
  return n
end
local function moved(w)
  for _, c in ipairs(w.calls) do
    if c:match("%.extend$") or c:match("%.retract$") or c:match("%.toggle$") then return true end
  end
  return #w.rs > 0
end
local function callIndex(w, name)
  for i, c in ipairs(w.calls) do if c == name then return i end end
  return nil
end

local function bay()
  return {
    stickers = { top = { ext = false, flush = true }, Create_Sticker_0 = { ext = true, flush = false } },
    others = {
      docking_connector_0 = { types = { "docking_connector" }, methods = { "getConnectedName", "isExtended" } },
      back = { types = { "modem", "peripheral_hub" }, methods = { "isWireless", "getNamesRemote" } },
      redstone_relay_0 = { types = { "redstone_relay" }, methods = { "setOutput", "getInput" } },
    },
  }
end

print("listing")
local w = run(computer(bay()))
check("finds both stickers", has(w, "stickers: 2 found"), w.text)
check("names the direct one by side", has(w, "top") and has(w, "touching the computer, top side"))
check("names the cabled one as networked", has(w, "Create_Sticker_0") and has(w, "on the wired network"))
check("reports state", has(w, "extended yes") and has(w, "extended no"))
check("lists methods sorted", has(w, "methods: extend, isAttachedToBlock, isExtended, retract, toggle"))
check("a plain listing moves nothing", not moved(w), table.concat(w.calls, " "))
check("no other peripherals without all", not has(w, "docking_connector_0"))

w = run(computer(bay()), "all")
check("all lists other peripherals with their types", has(w, "docking_connector_0") and has(w, "modem/peripheral_hub"))
check("all lists their methods", has(w, "getConnectedName, isExtended"))
check("all moves nothing", not moved(w))

local noHas = bay()
noHas.noHasType = true
w = run(computer(noHas))
check("found by getType where hasType is missing", has(w, "stickers: 2 found"), w.text)

w = run(computer({ others = { left = { types = { "monitor" }, methods = {} } } }))
check("none found says how to wire one", has(w, "stickers: 0 found") and has(w, "wired modem"))

print("test")
local cfg = bay()
cfg.answers = { "y" }
w = run(computer(cfg), "test", "top")
local ie, ir = callIndex(w, "top.extend"), callIndex(w, "top.retract")
check("test extends then retracts", ie and ir and ie < ir, table.concat(w.calls, " "))
check("test sees the block it is flush against", has(w, "attached yes") and has(w, "it reported a block"))
check("test leaves it retracted", w.stickers.top.ext == false)
check("test asks first", has(w, "[y/N]"))

cfg = bay()
cfg.stickers.top.flush = false
cfg.answers = { "y" }
w = run(computer(cfg), "test", "top")
check("nothing flush: says Create's check may not see it", has(w, "never reported a block") and w.stickers.top.ext == false)

cfg = bay()
cfg.answers = { "n" }
w = run(computer(cfg), "test", "top")
check("answer n: nothing moves", not moved(w) and has(w, "nothing changed"))

cfg = bay()
cfg.answers = {}
w = run(computer(cfg), "test", "top")
check("no answer: nothing moves", not moved(w))

cfg = bay()
cfg.answers = { "y" }
w = run(computer(cfg), "test", "Create_Sticker_0")
check("already extended: refuses to touch it", not moved(w) and has(w, "Not touching it") and w.stickers.Create_Sticker_0.ext)

w = run(computer(bay()), "test", "docking_connector_0")
check("not a sticker: refused", w.err and w.err:find("is not a sticker", 1, true) and not moved(w), w.err)
w = run(computer(bay()), "test")
check("no name: usage", w.err and w.err:find("usage", 1, true), w.err)

print("extend and retract")
cfg = bay()
cfg.answers = { "y" }
w = run(computer(cfg), "extend", "top")
check("extend y: extended and says it changed", w.stickers.top.ext == true and has(w, "extend() -> yes") and has(w, "welds"))
cfg = bay()
cfg.answers = { "y" }
w = run(computer(cfg), "retract", "Create_Sticker_0")
check("retract y: retracted, warns it releases", w.stickers.Create_Sticker_0.ext == false and has(w, "releases"))
cfg = bay()
cfg.answers = { "no" }
w = run(computer(cfg), "retract", "Create_Sticker_0")
check("retract no: still extended", w.stickers.Create_Sticker_0.ext == true and not moved(w))

print("hold")
cfg = bay()
cfg.answers = { "y" }
w = run(computer(cfg), "hold", "top", "1")
check("a latching sticker is extended once and stays out", count(w, "top.extend") == 1 and w.stickers.top.ext == true,
  count(w, "top.extend"))
check("hold says extend() latches", has(w, "extend() latches"), w.text)
check("hold runs for the time asked", math.abs(w.clock - 1) < 1e-6, w.clock)

cfg = bay()
cfg.stickers.top.fights = true
cfg.answers = { "y" }
w = run(computer(cfg), "hold", "top", "1")
check("a sticker pulled back in is extended again and counted", count(w, "top.extend") > 1
  and has(w, "found retracted") and has(w, "something pulls it back"), w.text)

cfg = bay()
cfg.answers = { "n" }
w = run(computer(cfg), "hold", "top")
check("hold n: nothing moves", not moved(w) and w.clock == 0)

print("pulse")
cfg = bay()
cfg.wire = { side = "back", sticker = "top" }
cfg.answers = { "y" }
w = run(computer(cfg), "pulse", "back", "10", "top")
check("a 10 tick pulse is on for 0.5 s", w.rs[1] == "back=true@0.00" and w.rs[2] == "back=false@0.50", table.concat(w.rs, " "))
check("the wired sticker flipped and it says so", w.stickers.top.ext == true and has(w, "extended no -> yes  (flipped)"), w.text)

cfg = bay()
cfg.wire = { side = "back", sticker = "top" }
cfg.stickers.top.ext = true
cfg.answers = { "y" }
w = run(computer(cfg), "pulse", "back", "4", "top")
check("the same pulse on an extended sticker retracts it", w.stickers.top.ext == false
  and w.rs[2] == "back=false@0.20" and has(w, "(flipped)"), table.concat(w.rs, " "))

cfg = bay()
cfg.answers = { "y" }
w = run(computer(cfg), "pulse", "redstone_relay_0:left")
check("relay:side pulses through the relay", w.rs[1] == "redstone_relay_0:left=true@0.00"
  and w.rs[2] == "redstone_relay_0:left=false@0.50", table.concat(w.rs, " "))

w = run(computer(bay()), "pulse", "sideways")
check("not a side: refused", w.err and w.err:find("is not a side", 1, true) and #w.rs == 0, w.err)
w = run(computer(bay()), "pulse", "missing_relay:top")
check("unknown relay: refused", w.err and w.err:find("not on this computer", 1, true) and #w.rs == 0, w.err)
cfg = bay()
cfg.answers = { "n" }
w = run(computer(cfg), "pulse", "back")
check("pulse n: no redstone", #w.rs == 0 and has(w, "nothing changed"))

print("save")
cfg = bay()
cfg.upload, cfg.http = true, {}
w = run(computer(cfg), "save")
check("save writes the all listing", w.files["stickers.txt"] and w.files["stickers.txt"]:find("stickers: 2 found", 1, true)
  and w.files["stickers.txt"]:find("docking_connector_0", 1, true))
check("save pushes to data/stickers.txt", w.runs[1] == "upload sync stickers.txt data/stickers.txt", w.runs[1])
check("save moves nothing", not moved(w))
w = run(computer(bay()), "save")
check("save without http says so", has(w, "copy stickers.txt off manually") and #w.runs == 0)

w = run(computer(bay()), "wiggle")
check("unknown command prints usage", has(w, "usage: stickers") and not moved(w))

print("")
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then error("sticker tests failed", 0) end
