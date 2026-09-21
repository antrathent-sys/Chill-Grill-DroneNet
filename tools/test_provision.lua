-- Desktop tests for lib/provision.lua: what it recognises in a drive, what a
-- pass gets, what an update keeps, and that the file list really is what the
-- pass's programs load and what the base carries.
local DIR = ...
local ROOT = DIR .. "/.."
local pass, fail = 0, 0
local function check(n, c, d)
  if c then pass = pass + 1 print("  ok   " .. n)
  else fail = fail + 1 print("  FAIL " .. n .. (d and ("  " .. tostring(d)) or "")) end
end

local P = dofile(ROOT .. "/lib/provision.lua")

-- An in-memory fs with the calls lib/provision.lua makes. Paths are plain
-- strings; a directory exists if anything lives under it or it was made.
local function memfs(seed)
  local files, dirs = {}, {}
  for k, v in pairs(seed or {}) do files[k] = v end
  local m = {}
  local function under(p, q) return q:sub(1, #p + 1) == p .. "/" end
  function m.exists(p)
    if files[p] or dirs[p] then return true end
    for q in pairs(files) do if under(p, q) then return true end end
    return false
  end
  function m.isDir(p) return m.exists(p) and not files[p] end
  function m.list(p)
    local seen, out = {}, {}
    local pre = (p == "" and "") or (p .. "/")
    local function add(q)
      if q:sub(1, #pre) == pre and #q > #pre then
        local name = q:sub(#pre + 1):match("^[^/]+")
        if not seen[name] then seen[name] = true out[#out + 1] = name end
      end
    end
    for q in pairs(files) do add(q) end
    for q in pairs(dirs) do add(q) end
    return out
  end
  function m.delete(p)
    files[p], dirs[p] = nil, nil
    for q in pairs(files) do if under(p, q) then files[q] = nil end end
    for q in pairs(dirs) do if under(p, q) then dirs[q] = nil end end
  end
  function m.copy(a, b)
    if files[b] then error("copy: destination exists " .. b, 0) end
    if not files[a] then error("copy: no source " .. a, 0) end
    files[b] = files[a]
  end
  function m.makeDir(p) dirs[p] = true end
  function m.getDir(p) return p:match("^(.*)/[^/]*$") or "" end
  function m.open(p, mode)
    if mode == "r" then
      local s = files[p]
      if not s then return nil end
      local pos = 1
      return {
        readAll = function() return s end,
        readLine = function()
          if pos > #s then return nil end
          local e = s:find("\n", pos, true)
          local line = s:sub(pos, (e or #s + 1) - 1)
          pos = (e or #s) + 1
          return line
        end,
        close = function() end }
    end
    local buf = { mode == "a" and (files[p] or "") or "" }
    return { write = function(x) buf[#buf + 1] = x end,
             close = function() files[p] = table.concat(buf) end }
  end
  m.files = files
  return m
end

local function sourceSeed()
  local seed = {}
  for _, f in ipairs(P.FILES) do seed[f] = "-- " .. f end
  seed[P.STARTUP] = "-- the kiosk"
  seed["startup.lua"] = "-- the base's own dev startup"
  seed[".custkeys"] = "# base keys, never copied"
  return seed
end
local KEY1 = string.rep("ab", 32)
local KEY2 = string.rep("cd", 32)

print("names")
check("a Minecraft name", P.validName("Alex_99"))
check("too short", not P.validName("al"))
check("too long", not P.validName(string.rep("a", 17)))
check("no spaces or dashes", not P.validName("alex smith") and not P.validName("al-ex"))

print("what is in the drive")
local f = memfs({ ["disk/.ghtoken"] = "x", ["disk/fly.lua"] = "x" })
local info = P.inspect(f, "disk")
check("one of Alex's machines is recognised", info.kind == "dev" and info.marker == ".ghtoken", info.kind)
check("so is a drone", P.inspect(memfs({ ["disk/.dronekey"] = "k" }), "disk").kind == "dev")
check("and anything startup installed", P.inspect(memfs({ ["disk/.installed"] = "x" }), "disk").kind == "dev")
check("a blank pocket", P.inspect(memfs({}), "disk").kind == "blank")
check("a settings file alone is still blank", P.inspect(memfs({ ["disk/.settings"] = "{}" }), "disk").kind == "blank")
local other = P.inspect(memfs({ ["disk/mygame.lua"] = "x" }), "disk")
check("somebody's own files", other.kind == "other" and other.files[1] == "mygame.lua")

print("a new pass")
f = memfs(sourceSeed())
f.files["disk/old.lua"] = "someone's"
local ok, n = P.install(f, "disk", { owner = "alex", keyHex = KEY1, version = "8f3c2a1" })
check("made", ok and n == #P.FILES + 1, tostring(n))
check("every program is on it", f.exists("disk/hail.lua") and f.exists("disk/ccryptolib/internal/hw.lua"))
check("its startup is the kiosk, not the base's", f.files["disk/startup.lua"] == "-- the kiosk")
check("it knows whose it is", f.files["disk/.pass"] == "alex\n")
check("and what to run", f.files["disk/.kiosk"] == "hail\n")
check("and which build it is", f.files["disk/.version"] == "8f3c2a1\n")
check("it has the key", f.files["disk/.custkey"] == KEY1 .. "\n")
check("what was there before is gone", not f.exists("disk/old.lua"))
check("no token and no key list ever go on a pass",
  not f.exists("disk/.ghtoken") and not f.exists("disk/.custkeys") and not f.exists("disk/kiosk.lua"))
info = P.inspect(f, "disk")
check("and it reads back as a pass", info.kind == "pass" and info.owner == "alex" and info.keyHex == KEY1)

print("an update")
f.files["disk/.custkey.ctr"] = "41"
f.files["disk/.hailstats"] = "rides=9"
f.files["disk/.crash"] = "1 hail: boom\n2 hail: bang\n"
f.files["disk/hail.lua"] = "-- last week's"
check("the crash note is read", (P.crashNote(f, "disk", 3) or {})[2] == "2 hail: bang")
ok = P.install(f, "disk", { owner = "alex" })
check("done without a new key", ok)
check("the programs are current", f.files["disk/hail.lua"] == "-- hail.lua")
check("the key and its counter are kept", f.files["disk/.custkey"] == KEY1 .. "\n" and f.files["disk/.custkey.ctr"] == "41")
check("so is its usage", f.files["disk/.hailstats"] == "rides=9")
check("the crash note is cleared", not f.exists("disk/.crash"))

print("a reissue")
ok = P.install(f, "disk", { owner = "alex", keyHex = KEY2 })
check("new key", ok and f.files["disk/.custkey"] == KEY2 .. "\n")
check("the old counter goes with the old key", not f.exists("disk/.custkey.ctr"))
check("usage is kept", f.files["disk/.hailstats"] == "rides=9")

print("refusals")
local g = memfs(sourceSeed())
g.files["lib/tui.lua"] = nil
g.files["disk/keepme.lua"] = "theirs"
local bad, why = P.install(g, "disk", { owner = "alex", keyHex = KEY1 })
check("a missing program is caught before anything is deleted",
  bad == nil and why:match("lib/tui.lua") and g.exists("disk/keepme.lua"), why)
bad, why = P.install(memfs(sourceSeed()), "disk", { owner = "alex" })
check("an update with no key on the pass is refused", bad == nil and why:match("no key"), why)
bad = P.install(memfs(sourceSeed()), "disk", { owner = "x y", keyHex = KEY1 })
check("so is a name that is not one", bad == nil)
local w = memfs({ ["disk/a"] = "1", ["disk/b"] = "2" })
P.wipe(w, "disk")
check("wipe leaves nothing", #w.list("disk") == 0)

print("the file list is the truth")
-- every dofile in the pass's programs, followed through the libraries
local function readFile(p)
  local h = io.open(ROOT .. "/" .. p, "r")
  if not h then return nil end
  local s = h:read("*a")
  h:close()
  return s
end
local onPass = {}
for _, x in ipairs(P.FILES) do onPass[x] = true end
local missing, todo, seen = {}, { "hail.lua", P.STARTUP }, {}
while #todo > 0 do
  local p = table.remove(todo)
  if not seen[p] then
    seen[p] = true
    local src = readFile(p)
    if not src then missing[#missing + 1] = p .. " (not in the repo)" else
      for dep in src:gmatch('dofile%(%s*"([^"]+)"%s*%)') do
        if not onPass[dep] then missing[#missing + 1] = dep .. " (from " .. p .. ")" end
        todo[#todo + 1] = dep
      end
    end
  end
end
check("everything hail and the kiosk load is on the pass", #missing == 0, table.concat(missing, ", "))
for _, x in ipairs(P.FILES) do
  if not readFile(x) then missing[#missing + 1] = x end
end
check("and every file on the list exists", #missing == 0, table.concat(missing, ", "))
local man = dofile(ROOT .. "/manifest.lua")
local onBase = {}
for _, x in ipairs(man.common) do onBase[x] = true end
for _, x in ipairs(man.base) do onBase[x] = true end
local absent = {}
for _, x in ipairs(P.FILES) do if not onBase[x] then absent[#absent + 1] = x end end
for _, x in ipairs({ P.STARTUP, "provision.lua", "lib/provision.lua" }) do
  if not onBase[x] then absent[#absent + 1] = x end
end
check("the base carries everything it copies", #absent == 0, table.concat(absent, ", "))

print("")
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then error("provision tests failed", 0) end
