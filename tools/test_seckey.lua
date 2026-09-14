-- Desktop tests for seckey.lua: moving a key between computers by floppy on
-- whichever drive it is mounted in (disk, disk2, ...), and the typed fallback.
local DIR = ...
local pass, fail = 0, 0
local function check(n, c, d)
  if c then pass = pass + 1 print("  ok   " .. n)
  else fail = fail + 1 print("  FAIL " .. n .. (d and ("  " .. tostring(d)) or "")) end
end

dofile(DIR .. "/cc_shim.lua")
local S = dofile(DIR .. "/../lib/seclink.lua")
S.ROOT = DIR .. "/../"
S._req("ccryptolib.random").init("desktop test seed - not random")

-- a computer: memory files, some disk drives (name -> mount path or false for empty)
local function computer(opts)
  local c = { files = opts.files or {}, printed = {}, drives = opts.drives or {} }
  local env = setmetatable({}, { __index = _G })
  env.print = function(s) c.printed[#c.printed + 1] = tostring(s) end
  env.dofile = function(p)
    if p == "lib/seclink.lua" then return S end
    return dofile(p)
  end
  env.fs = {
    exists = function(p) return c.files[p] ~= nil end,
    isDir = function() return false end,
    open = function(p, mode)
      if mode == "r" then
        local data = c.files[p]
        return data and { readAll = function() return data end, close = function() end } or nil
      end
      local buf = {}
      return { write = function(s) buf[#buf + 1] = s end, close = function() c.files[p] = table.concat(buf) end }
    end,
    delete = function(p) c.files[p] = nil end,
  }
  env.peripheral = {
    getNames = function()
      local t = { "monitor_0" }
      for n in pairs(c.drives) do t[#t + 1] = n end
      table.sort(t)
      return t
    end,
    getType = function(n) return c.drives[n] ~= nil and "drive" or "monitor" end,
    call = function(n, m)
      local mount = c.drives[n]
      if m == "hasData" then return mount ~= false end
      if m == "getMountPath" then return mount or nil end
      error("no method " .. m, 0)
    end,
  }
  env.os = setmetatable({
    getComputerLabel = function() return opts.label end,
    getComputerID = function() return 12 end,
  }, { __index = os })
  c.env = env
  return c
end

local function run(c, ...)
  local f = assert(loadfile(DIR .. "/../seckey.lua"))
  setfenv(f, c.env)
  -- seclink reads key files through the global fs, as it does on CC
  _G.fs = c.env.fs
  return pcall(f, ...)
end

local function printed(c, s)
  for _, l in ipairs(c.printed) do if l:find(s, 1, true) then return l end end
end

print("base: seckey new")
local base = computer({ drives = { drive_empty = false, drive_left = "disk2" } })
local ok, err = run(base, "new", "drone-1")
check("runs", ok, err)
local keys = S.parseFleetKeys(base.files[".fleetkeys"] or "")
check("key kept in .fleetkeys", keys["drone-1"] and #keys["drone-1"] == 32)
check("written to the floppy in disk2, not a hardcoded disk", base.files["disk2/.dronekey"] ~= nil and base.files["disk/.dronekey"] == nil)
check("floppy holds the same key", S.parseKey(base.files["disk2/.dronekey"] or "") == keys["drone-1"])
check("tells you what to run on the drone", printed(base, "seckey set disk"))

print("drone: seckey set disk")
local drone = computer({ label = "drone-1", drives = { drive_top = "disk3" },
                         files = { ["disk3/.dronekey"] = base.files["disk2/.dronekey"] } })
ok, err = run(drone, "set", "disk")
check("runs", ok, err)
check("key saved on the drone", S.readKeyFile and S.parseKey(drone.files[".dronekey"] or "") == keys["drone-1"])
check("wiped from the floppy", drone.files["disk3/.dronekey"] == nil and printed(drone, "wiped"))
check("reports the telemetry id", printed(drone, "telemetry id: drone-1"))

local empty = computer({ label = "drone-2", drives = { drive_top = false } })
run(empty, "set", "disk")
check("no floppy: says so, saves nothing", empty.files[".dronekey"] == nil and printed(empty, "no key on any floppy"))

print("no floppy at the base: typed fallback")
local base2 = computer({ drives = {} })
run(base2, "new", "drone-2")
local line = printed(base2, "seckey set ")
check("prints the key in four groups", line and line:match("^seckey set %x+ %x+ %x+ %x+$"), line)
local typed = computer({ label = "drone-2" })
local parts = {}
for w in (line or ""):gmatch("%S+") do parts[#parts + 1] = w end
ok, err = run(typed, parts[2], parts[3], parts[4], parts[5], parts[6])
local keys2 = S.parseFleetKeys(base2.files[".fleetkeys"] or "")
check("typing those groups gives the same key", ok and S.parseKey(typed.files[".dronekey"] or "") == keys2["drone-2"], err)

print("show and bad input")
local base3 = computer({ files = { [".fleetkeys"] = base.files[".fleetkeys"] }, drives = { d = "disk" } })
run(base3, "show", "drone-1")
check("show writes to a floppy when there is one", S.parseKey(base3.files["disk/.dronekey"] or "") == keys["drone-1"])
local bad = computer({ label = "drone-9" })
run(bad, "set", "nothex")
check("a bad key is refused", bad.files[".dronekey"] == nil and printed(bad, "not a key"))

print("")
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then error("seckey tests failed", 0) end
