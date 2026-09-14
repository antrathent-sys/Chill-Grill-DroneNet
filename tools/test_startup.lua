-- Desktop tests for startup.lua: autorun command, the fly refusal, updating
-- with http missing or failing, and the restart loop. Everything CC-specific
-- is stubbed here.
local DIR = ...
local pass, fail = 0, 0
local function check(n, c, d)
  if c then pass = pass + 1 print("  ok   " .. n)
  else fail = fail + 1 print("  FAIL " .. n .. (d and ("  " .. tostring(d)) or "")) end
end

local SRC = DIR .. "/../startup.lua"

local function world(opts)
  opts = opts or {}
  local w = { files = opts.files or {}, printed = {}, runs = {}, keys = opts.keys or {}, waits = 0 }
  local env = setmetatable({}, { __index = _G })
  env.print = function(s) w.printed[#w.printed + 1] = tostring(s) end
  env.fs = {
    exists = function(p) return w.files[p] ~= nil or p == "lib" or p == "ccryptolib" or p == "ccryptolib/internal" end,
    open = function(p, mode)
      if mode == "r" then
        local data = w.files[p]
        return data and { readAll = function() return data end, close = function() end } or nil
      end
      local buf = {}
      return { write = function(s) buf[#buf + 1] = s end, close = function() w.files[p] = table.concat(buf) end }
    end,
    delete = function(p) w.files[p] = nil end,
    makeDir = function() end,
    getFreeSpace = function() return 900000 end,
    getSize = function(p) return #(w.files[p] or "") end,
  }
  env.textutils = { unserializeJSON = function(s)
    local sha = s:match('"sha"%s*:%s*"(%x+)"')
    return sha and { sha = sha } or nil
  end }
  if opts.http == "missing" then
    env.http = nil
  elseif opts.http == "throws" then
    env.http = { get = function() error("connection reset", 0) end }
  else
    env.http = { get = function(url)
      if url:find("api.github.com", 1, true) then
        return { readAll = function() return '{"sha":"' .. string.rep("a", 40) .. '"}' end, close = function() end }
      end
      local name = url:match("/" .. string.rep("a", 40) .. "/(.+)$")
      if not name then return nil, "bad url " .. url end
      return { readAll = function() return "-- " .. name end, close = function() end }
    end }
  end
  -- parallel.waitForAny(sleepFn, keyFn): a scripted key press picks the key branch
  env.parallel = { waitForAny = function(a, b)
    w.waits = w.waits + 1
    if w.keys[w.waits] then b() else a() end
  end }
  env.sleep = function() end
  env.os = setmetatable({ pullEvent = function() return "key", 57 end }, { __index = os })
  -- after the scripted runs, a key press stops the loop so the test ends
  env.shell = { run = function(cmd)
    w.runs[#w.runs + 1] = cmd
    if #w.runs >= (opts.stopAfter or 1) then
      w.keys[w.waits + 1] = true
    end
    return opts.runResult ~= false
  end }
  w.env = env
  return w
end

local function run(w, ...)
  local f = assert(loadfile(SRC))
  setfenv(f, w.env)
  local ok, err = pcall(f, ...)
  return ok, err
end

local function printedHas(w, s)
  for _, line in ipairs(w.printed) do if line:find(s, 1, true) then return true end end
  return false
end

print("startup autorun <cmd>")
local w = world()
run(w, "autorun", "console")
check("saves the command", w.files[".autorun"] == "console")
check("does not update or run anything", #w.runs == 0 and not printedHas(w, "pulling"))
local w2 = world({ files = { [".autorun"] = "console" } })
run(w2, "autorun", "off")
check("off removes it", w2.files[".autorun"] == nil and printedHas(w2, "autorun off"))
local w3 = world()
run(w3, "autorun", "fly", "deliver", "2000", "120", "5000")
check("refuses to autorun a flight", w3.files[".autorun"] == nil and printedHas(w3, "refusing"))
local w4 = world()
run(w4, "autorun", "flyer")
check("a command that only starts with fly is fine", w4.files[".autorun"] == "flyer")
local w5 = world()
run(w5, "autorun", "console", "demo")
check("keeps arguments", w5.files[".autorun"] == "console demo")

print("boot")
local b1 = world({ files = { [".autorun"] = "console" } })
local ok1, err1 = run(b1)
check("updates every file by commit", ok1 and b1.files["fly.lua"] == "-- fly.lua" and b1.files["ccryptolib/internal/hw.lua"] == "-- ccryptolib/internal/hw.lua", err1)
check("then runs the autorun command", b1.runs[1] == "console", b1.runs[1])
check("a key press ends the loop", #b1.runs == 1 and printedHas(b1, "skipped"))

local b2 = world({ files = { [".autorun"] = "console" }, http = "missing" })
local ok2, err2 = run(b2)
check("http disabled: no crash, says so", ok2 and printedHas(b2, "http API disabled"), err2)
check("http disabled: still autoruns", b2.runs[1] == "console")

local b3 = world({ files = { [".autorun"] = "console" }, http = "throws" })
local ok3, err3 = run(b3)
check("update throwing: reported, not fatal", ok3 and printedHas(b3, "update failed"), err3)
check("update throwing: still autoruns", b3.runs[1] == "console")

local b4 = world({ files = { [".autorun"] = "console" }, stopAfter = 3, runResult = false })
run(b4)
check("a crashing command is restarted", #b4.runs == 3, #b4.runs)
check("and says so", printedHas(b4, "stopped with an error - restarting"))

local b5 = world({ files = { [".autorun"] = "console" }, keys = { true } })
run(b5)
check("key during the 3 s window skips the run", #b5.runs == 0 and printedHas(b5, "skipped"))

local b6 = world({ files = { [".autorun"] = "  fly go 100 100  " } })
run(b6)
check("a fly command already in .autorun is refused at boot", #b6.runs == 0 and printedHas(b6, "refusing"))

local b7 = world({})
local ok7 = run(b7)
check("no .autorun: update only, nothing run", ok7 and #b7.runs == 0 and b7.waits == 0)

print("")
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then error("startup tests failed", 0) end
