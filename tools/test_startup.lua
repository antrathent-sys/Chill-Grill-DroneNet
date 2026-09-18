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
  local w = { files = opts.files or {}, printed = {}, runs = {}, keys = opts.keys or {}, waits = 0, rs = {} }
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
    getFreeSpace = function()
      if not opts.disk then return 900000 end
      local used = 0
      for _, v in pairs(w.files) do used = used + #v end
      return opts.disk - used
    end,
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
      w.fetched = w.fetched or {}
      w.fetched[#w.fetched + 1] = name
      if name == "manifest.lua" then
        if not opts.manifest then return nil, "404" end
        return { readAll = function() return opts.manifest end, close = function() end }
      end
      return { readAll = function() return "-- " .. name end, close = function() end }
    end }
  end
  -- parallel.waitForAny(sleepFn, keyFn): a scripted key press picks the key branch
  env.parallel = { waitForAny = function(a, b)
    w.waits = w.waits + 1
    if w.keys[w.waits] then b() else a() end
  end }
  env.sleep = function() end
  env.redstone = { setOutput = function(side, on)
    w.rs[side] = on
    w.firstRs = w.firstRs or (#(w.fetched or {}))
  end }
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

print("short of space")
local big = string.rep("x", 300000)
local d1 = world({ disk = 500000, files = { ["flightlog"] = big, ["mixmap.csv"] = "name,dp,dr\nvector_thruster_5,1,1\n" } })
run(d1)
check("a full disk gives up the flightlog", d1.files["flightlog"] == nil and printedHas(d1, "reclaimed: flightlog"))
check("but never the thruster map mixcal wrote", d1.files["mixmap.csv"] ~= nil)

print("dock hold")
local h1 = world()
run(h1, "hold", "back")
check("hold back: saved and raised now", h1.files[".hold"] == "back" and h1.rs.back == true)
check("hold does not update or autorun", h1.fetched == nil and #h1.runs == 0)
local h2 = world({ files = { [".hold"] = "back", [".autorun"] = "rsio" }, http = "missing" })
run(h2)
check("boot raises the held side even with no http", h2.rs.back == true and printedHas(h2, "hold: back high"))
check("and still autoruns", h2.runs[1] == "rsio")
local h3 = world({ files = { [".hold"] = "back" } })
run(h3)
check("the hold goes up before the update fetches anything", h3.rs.back == true and h3.firstRs == 0, h3.firstRs)
local h4 = world()
run(h4, "hold", "sideways")
check("a bad side is refused", h4.files[".hold"] == nil and next(h4.rs) == nil and printedHas(h4, "not a side"))
local h5 = world({ files = { [".hold"] = "back" } })
run(h5, "hold", "off")
check("hold off forgets it", h5.files[".hold"] == nil and printedHas(h5, "hold off"))
local h6 = world({ files = {} })
run(h6)
check("no hold: nothing raised at boot", next(h6.rs) == nil)
local h7 = world({ files = { [".hold"] = "back" }, manifest = [[return { common = { "startup.lua" }, base = { "control.lua" } }]] })
run(h7, "role", "base")
check("a role change never deletes the hold", h7.files[".hold"] == "back")

print("roles")
local MAN = [[return {
  common = { "startup.lua", "lib/link.lua" },
  drone = { "fly.lua", "lib/db.lua" },
  base = { "control.lua", "lib/display.lua", "lib/db.lua" },
  pocket = {},
}]]
local function lines(s)
  local t = {}
  for l in (s or ""):gmatch("[^\n]+") do t[#t + 1] = l end
  return t
end

local r1 = world({ manifest = MAN, files = { [".autorun"] = "control" } })
local okR1, errR1 = run(r1, "role", "base")
check("role base: pulls common and base only", okR1 and r1.files["control.lua"] and r1.files["lib/display.lua"]
  and r1.files["startup.lua"] and r1.files["lib/link.lua"] and r1.files["lib/db.lua"] and not r1.files["fly.lua"], errR1)
check("role base: saved", r1.files[".role"] == "base")
check("role base: records what it installed", #lines(r1.files[".installed"]) == 5, r1.files[".installed"])
check("setting a role does not start the autorun", #r1.runs == 0)

-- a computer that used to pull everything: the old files go, its own files stay
local full = { ["fly.lua"] = "old", ["control.lua"] = "old", ["console.lua"] = "old", ["lib/display.lua"] = "old",
               [".dronekey"] = "key", ["pads.lua"] = "pads", ["flightlog"] = "log", ["myprog.lua"] = "mine" }
local r2 = world({ manifest = MAN, files = full })
run(r2, "role", "pocket")
check("first role on a full install removes other roles' files", not r2.files["fly.lua"] and not r2.files["control.lua"]
  and not r2.files["lib/display.lua"])
check("but keeps keys, pads, logs and files the manifest never named", r2.files[".dronekey"] and r2.files["pads.lua"]
  and r2.files["flightlog"] and r2.files["myprog.lua"] and r2.files["console.lua"] == "old")
check("pocket gets just the common files", r2.files["startup.lua"] and r2.files["lib/link.lua"]
  and #lines(r2.files[".installed"]) == 2, r2.files[".installed"])

local r3 = world({ manifest = MAN, files = {} })
run(r3, "role", "base")
run(r3, "role", "drone")
check("switching base -> drone removes base files and keeps shared ones", r3.files["fly.lua"] and not r3.files["control.lua"]
  and not r3.files["lib/display.lua"] and r3.files["lib/db.lua"] and r3.files["lib/link.lua"])
check("the role is now drone", r3.files[".role"] == "drone")

local r4 = world({ manifest = MAN, files = { [".role"] = "drone\n", [".autorun"] = "rsio" } })
local okR4 = run(r4)
check("boot reads the role and pulls only its files", okR4 and r4.files["fly.lua"] and not r4.files["control.lua"])
check("boot with a role still autoruns", r4.runs[1] == "rsio")
check("a role never fetches another role's files", (function()
  for _, n in ipairs(r4.fetched) do if n == "control.lua" or n == "lib/display.lua" then return false end end
  return true
end)())

local r5 = world({ manifest = MAN, files = { ["fly.lua"] = "old" } })
run(r5, "role", "toaster")
check("an unknown role is refused and nothing changes", r5.files[".role"] == nil and r5.files["fly.lua"] == "old"
  and printedHas(r5, "no role 'toaster'") and printedHas(r5, "base, drone, pocket"))

local r6 = world({ manifest = MAN, files = { [".role"] = "base" } })
run(r6, "role", "all")
check("role all clears the role and pulls everything", r6.files[".role"] == nil and r6.files["fly.lua"]
  and r6.files["control.lua"])

local r7 = world({ files = { [".role"] = "base", [".installed"] = "startup.lua\ncontrol.lua\n", ["control.lua"] = "old",
                             ["fly.lua"] = "left alone" } })
local okR7 = run(r7)
check("manifest unreadable: refresh installed files only, remove nothing", okR7 and r7.files["control.lua"] == "-- control.lua"
  and r7.files["fly.lua"] == "left alone" and printedHas(r7, "could not read manifest.lua"))
local r8 = world({ files = {} })
run(r8, "role", "base")
check("manifest unreadable: a new role is not saved", r8.files[".role"] == nil and printedHas(r8, "role not changed"))
local r9 = world({ manifest = "os.shutdown() return {}", files = {} })
run(r9)
check("a manifest that is not a file list is ignored (everything, as before)", r9.files["fly.lua"] == "-- fly.lua")
local r10 = world({ manifest = [[return { common = { "../../evil.lua" }, drone = {} }]], files = { [".role"] = "drone" } })
run(r10)
check("a manifest naming paths outside the computer is rejected", r10.files["../../evil.lua"] == nil)

local r11 = world({ manifest = MAN, files = { [".role"] = "base" } })
run(r11, "role")
check("startup role on its own just reports", printedHas(r11, "role: base") and r11.fetched == nil)
local r12 = world({ manifest = MAN, http = "missing", files = {} })
run(r12, "role", "base")
check("no http: role not changed, says why", r12.files[".role"] == nil and printedHas(r12, "needs http"))

print("the real manifest")
local function readFile(p)
  local f = io.open(p, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end
local ROOT = DIR .. "/../"
local realMan = assert(loadstring(assert(readFile(ROOT .. "manifest.lua"), "manifest.lua missing")))()
local all, missing = {}, {}
for role, list in pairs(realMan) do
  for _, name in ipairs(list) do
    all[name] = true
    if not readFile(ROOT .. name) then missing[#missing + 1] = role .. ":" .. name end
  end
end
check("every file the manifest names exists", #missing == 0, table.concat(missing, ", "))
local startupSrc = readFile(ROOT .. "startup.lua")
local block = startupSrc:match("local FILES%s*=%s*(%b{})")
local uncovered = {}
for name in block:gmatch('"([^"]+)"') do
  if not all[name] then uncovered[#uncovered + 1] = name end
end
check("the manifest covers startup's fallback list", #uncovered == 0, table.concat(uncovered, ", "))
local notInFallback = {}
for name in pairs(all) do
  if not block:find('"' .. name .. '"', 1, true) then notInFallback[#notInFallback + 1] = name end
end
check("and the fallback list covers the manifest", #notInFallback == 0, table.concat(notInFallback, ", "))

-- every dofile / shell.run inside a role's programs is carried by that role (or common)
local gaps = {}
for role, list in pairs(realMan) do
  if role ~= "common" then
    local has = {}
    for _, n in ipairs(realMan.common) do has[n] = true end
    for _, n in ipairs(list) do has[n] = true end
    for _, n in ipairs(list) do
      local src = readFile(ROOT .. n) or ""
      for dep in src:gmatch('dofile%s*,?%s*%(?%s*"([%w_/%.%-]+%.lua)"') do
        if all[dep] and not has[dep] then gaps[#gaps + 1] = role .. ":" .. n .. " needs " .. dep end
      end
      for prog in src:gmatch('shell%.run%(%s*"([%w_%-]+)"') do
        local dep = prog .. ".lua"
        if all[dep] and not has[dep] then gaps[#gaps + 1] = role .. ":" .. n .. " runs " .. dep end
      end
    end
  end
end
for _, n in ipairs(realMan.common) do
  local src = readFile(ROOT .. n) or ""
  for dep in src:gmatch('dofile%s*,?%s*%(?%s*"([%w_/%.%-]+%.lua)"') do
    local inCommon = false
    for _, c in ipairs(realMan.common) do if c == dep then inCommon = true end end
    if all[dep] and not inCommon then gaps[#gaps + 1] = "common:" .. n .. " needs " .. dep end
  end
end
check("every role carries what its programs load", #gaps == 0, table.concat(gaps, "; "))

print("")
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then error("startup tests failed", 0) end
