-- startup: pull the latest controller files from GitHub on boot, then run
-- this computer's autorun command, if it has one.
-- Fetches each file below from the repo's raw URL, writes it to the root of
-- this computer, and prints what changed. Needs http enabled in the CC config.
--
--   startup autorun console     base computer: bring the wall back after every reboot
--   startup autorun rsio        redstone slave on a drone
--   startup autorun off         stop autorunning
--   startup role                which kind of computer this is
--   startup role <name>         drone, base, pocket, rs, or all: pull only that
--                               role's files (manifest.lua) from now on
--
-- The autorun command is kept in .autorun on this computer. It waits 3 s
-- (press any key to get the shell instead) and restarts the command if it
-- crashes or ends. `fly` is refused: a drone must never take off by itself
-- because a chunk reloaded.
local REPO   = "antrathent-sys/Chill-Grill-DroneNet"
local BRANCH = "main"
local FILES  = { "fly.lua", "kill.lua", "startup.lua", "probe.lua", "upload.lua", "preflight.lua",
                 "mixcal.lua",
                 "rsio.lua", "chimes.lua", "docktest.lua", "stickers.lua",
                 "lib/chime.lua", "lib/db.lua", "lib/mission.lua", "lib/rs.lua",
                 "lib/mixer.lua", "lib/attitude.lua", "lib/link.lua", "lib/pads.lua",
                 "lib/display.lua", "console.lua", "lib/state.lua", "lib/screens.lua", "control.lua",
                 "lib/seclink.lua", "seckey.lua",
                 "ccryptolib/aead.lua", "ccryptolib/chacha20.lua", "ccryptolib/poly1305.lua",
                 "ccryptolib/random.lua", "ccryptolib/blake3.lua", "ccryptolib/config.lua",
                 "ccryptolib/internal/util.lua", "ccryptolib/internal/packing.lua",
                 "ccryptolib/internal/hw.lua" }

-- FILES is only the fallback for a computer with no role when manifest.lua
-- cannot be read. Normally the manifest in the repo decides what to pull.
local AUTORUN_FILE = ".autorun"
local ROLE_FILE = ".role"            -- this computer's role, one word
local INSTALLED_FILE = ".installed"  -- the files startup put here, one per line
local MANIFEST = "manifest.lua"

local function isFlight(cmd)
  return cmd == "fly" or cmd:match("^fly%s") ~= nil
end

-- ---------------------------------------------------------- startup autorun
local args = { ... }
if args[1] == "autorun" then
  local cmd = table.concat(args, " ", 2)
  if cmd == "" or cmd == "off" then
    if fs.exists(AUTORUN_FILE) then fs.delete(AUTORUN_FILE) end
    print("autorun off")
  elseif isFlight(cmd) then
    print("refusing: a drone must never take off by itself on boot")
  else
    local f = fs.open(AUTORUN_FILE, "w")
    f.write(cmd)
    f.close()
    print("every boot, after updating, this computer runs: " .. cmd)
    print("(startup autorun off to stop)")
  end
  return
end

local roleRequest = nil
if args[1] == "role" then
  if not args[2] then
    local role = ""
    if fs.exists(ROLE_FILE) then
      local f = fs.open(ROLE_FILE, "r")
      role = (f.readAll() or ""):gsub("%s+", "")
      f.close()
    end
    print("role: " .. (role ~= "" and role or "none - this computer pulls every file"))
    print("startup role <drone|base|pocket|rs|all> to change it")
    return
  end
  roleRequest = args[2]:lower()
end

-- Private repo? Put a GitHub token (fine-grained, read-only Contents scope on
-- this repo only) in a file called .ghtoken on THIS computer. It is read here
-- and sent as an Authorization header; it never lives in the repo.
local TOKEN_FILE = ".ghtoken"
local HEADERS = nil
if fs.exists(TOKEN_FILE) then
  local f = fs.open(TOKEN_FILE, "r")
  local tok = (f.readAll() or ""):gsub("%s+", "")
  f.close()
  if #tok > 0 then HEADERS = { Authorization = "token " .. tok } end
end

local function readLocal(name)
  if not fs.exists(name) then return nil end
  local f = fs.open(name, "r")
  local s = f.readAll()
  f.close()
  return s
end

-- raw.githubusercontent.com caches a branch path for 5 minutes and ignores
-- query strings, so a fetch by branch name within 5 minutes of a push returns
-- the PREVIOUS version. That bit this project repeatedly. A fetch by commit
-- SHA is immutable, so it is always correct however it is cached. One API
-- call finds the SHA; if that fails we fall back to the branch and say so.
local function latestSha()
  local url = string.format("https://api.github.com/repos/%s/commits/%s", REPO, BRANCH)
  local res = http.get(url, HEADERS)
  if not res then return nil end
  local body = res.readAll()
  res.close()
  local ok, t = pcall(textutils.unserializeJSON, body)
  if ok and type(t) == "table" and type(t.sha) == "string" and #t.sha == 40 then
    return t.sha
  end
  return nil
end

local function fetch(ref, name)
  local url = string.format("https://raw.githubusercontent.com/%s/%s/%s", REPO, ref, name)
  local res, err = http.get(url, HEADERS)
  if not res then return nil, err end
  local body = res.readAll()
  res.close()
  return body
end

-- Space. A flight writes ~230 bytes a row at 10 Hz, so a three minute flight
-- is a 400 KB flightlog, and the repo itself is another 300 KB. On a computer
-- with the default 1 MB that is survivable; on a server that has turned the
-- limit down it is not, and the failure looks like "Out of space" halfway
-- through an update with the tree left half old and half new.
local DISPOSABLE = { "flightlog", "probe.txt", "preflight.txt", "mixmap.csv", "probelog.csv", "stickers.txt" }

local function freeSpace() return (fs.getFreeSpace and fs.getFreeSpace("/")) or math.huge end

local function reclaim(needed)
  local freed = {}
  for _, name in ipairs(DISPOSABLE) do
    if freeSpace() >= needed then break end
    if fs.exists(name) then
      local sz = fs.getSize(name)
      fs.delete(name)
      freed[#freed + 1] = string.format("%s (%.0fKB)", name, sz / 1024)
    end
  end
  if #freed > 0 then print("reclaimed: " .. table.concat(freed, ", ")) end
  return freeSpace()
end

-- The manifest runs with no environment at all: it can only list files.
local function parseManifest(text)
  if type(text) ~= "string" or text == "" then return nil end
  local chunk
  if setfenv then
    chunk = (loadstring or load)(text, "manifest")
    if chunk then setfenv(chunk, {}) end
  else
    chunk = load(text, "manifest", "t", {})
  end
  if not chunk then return nil end
  local ok, t = pcall(chunk)
  if not ok or type(t) ~= "table" or type(t.common) ~= "table" then return nil end
  for k, list in pairs(t) do
    if type(k) ~= "string" or type(list) ~= "table" then return nil end
    for _, name in ipairs(list) do
      if type(name) ~= "string" or name:sub(1, 1) == "." or name:find("..", 1, true) then return nil end
    end
  end
  return t
end

local function rolesOf(man)
  local keys = {}
  for k in pairs(man) do
    if k ~= "common" then keys[#keys + 1] = k end
  end
  table.sort(keys)
  return keys
end

-- common, then the named roles' files (every role when roles is nil), once each
local function filesFor(man, roles)
  local out, seen = {}, {}
  local function add(list)
    for _, name in ipairs(list or {}) do
      if not seen[name] then seen[name], out[#out + 1] = true, name end
    end
  end
  add(man.common)
  for _, k in ipairs(roles or rolesOf(man)) do add(man[k]) end
  return out
end

local function readList(name)
  local s = readLocal(name)
  if not s then return nil end
  local t = {}
  for line in s:gmatch("[^\r\n]+") do t[#t + 1] = line end
  return t
end

local function writeText(name, text)
  if fs.exists(name) then fs.delete(name) end
  local f = fs.open(name, "w")
  f.write(text)
  f.close()
end

local function update(roleRequest)
  -- checked before anything touches http: with the API disabled this used to
  -- crash on the commit lookup, and then nothing after it (autorun) ran
  if not http then
    print("startup: http API disabled - skipping update")
    if roleRequest then print("startup: role not changed - it needs http to fetch its file list") end
    return
  end

  local ref = latestSha()
  if ref then
    print("pulling commit " .. ref:sub(1, 7))
  else
    ref = BRANCH
    print("WARNING: could not resolve latest commit, pulling '" .. BRANCH .. "' (may be up to 5 min stale)")
  end

  -- Which files: the manifest decides, by this computer's role.
  local man = parseManifest((fetch(ref, MANIFEST)))
  local role = roleRequest or (readLocal(ROLE_FILE) or ""):gsub("%s+", "")
  local wanted
  if man then
    if role == "" or role == "all" then
      wanted = filesFor(man)
    elseif role ~= "common" and man[role] then
      wanted = filesFor(man, { role })
    else
      print(string.format("startup: no role '%s' (roles: %s, all)", role, table.concat(rolesOf(man), ", ")))
      return
    end
  elseif roleRequest then
    print("startup: role not changed - could not read " .. MANIFEST .. " from the repo")
    return
  elseif role ~= "" and role ~= "all" then
    -- a role but no manifest: refresh what is already here, remove nothing
    print("WARNING: could not read " .. MANIFEST .. " - updating only the files already installed")
    wanted = readList(INSTALLED_FILE)
    if not wanted then return end
  else
    wanted = FILES
  end
  if roleRequest then
    if roleRequest == "all" then
      if fs.exists(ROLE_FILE) then fs.delete(ROLE_FILE) end
    else
      writeText(ROLE_FILE, roleRequest)
    end
  end
  print(string.format("role: %s - %d files", (role == "" or role == "all") and "all" or role, #wanted))

  local free = freeSpace()
  if free ~= math.huge then
    print(string.format("space: %.0fKB free", free / 1024))
    if free < 400 * 1024 then
      -- these are all either uploaded to the repo already or regenerable
      free = reclaim(400 * 1024)
      print(string.format("space: %.0fKB free after tidying", free / 1024))
    end
  end

  local updated, unchanged, failed = {}, {}, {}
  for _, name in ipairs(wanted) do
    local body, err = fetch(ref, name)
    if not body or #body == 0 then
      failed[#failed + 1] = name .. " (" .. tostring(err or "empty") .. ")"
    elseif body == readLocal(name) then
      unchanged[#unchanged + 1] = name
    else
      -- files under lib/ need their directory to exist first
      local dir = name:match("^(.*)/[^/]+$")
      if dir and not fs.exists(dir) then fs.makeDir(dir) end
      -- Delete first: writing over a file that is still taking up room can run
      -- the disk out on the very file we are replacing. And say which file it
      -- was, rather than dying on an anonymous line number.
      if fs.exists(name) then fs.delete(name) end
      if freeSpace() < #body then reclaim(#body + 8192) end
      local ok, werr = pcall(function()
        local f = fs.open(name, "w")
        f.write(body)
        f.close()
      end)
      if ok then
        updated[#updated + 1] = name
      else
        failed[#failed + 1] = string.format("%s (%s, %.0fKB free, needs %.0fKB)",
          name, tostring(werr), freeSpace() / 1024, #body / 1024)
      end
    end
  end

  if #updated > 0   then print("updated:   " .. table.concat(updated, ", ")) end
  if #unchanged > 0 then print("unchanged: " .. table.concat(unchanged, ", ")) end
  if #failed > 0    then print("FAILED:    " .. table.concat(failed, ", ")) end
  if #updated == 0 and #failed == 0 then print("startup: all files current") end

  -- Remove only what startup installed and this role no longer wants. A
  -- computer that has never recorded what it installed may lose any file the
  -- manifest names - never keys, logs, pads.lua or anything else of its own.
  if man then
    local keep = {}
    for _, name in ipairs(wanted) do keep[name] = true end
    local removed = {}
    for _, name in ipairs(readList(INSTALLED_FILE) or filesFor(man)) do
      if not keep[name] and name ~= "startup.lua" and name:sub(1, 1) ~= "." and fs.exists(name) then
        fs.delete(name)
        removed[#removed + 1] = name
      end
    end
    if #removed > 0 then print("removed:   " .. table.concat(removed, ", ")) end
    local have = {}
    for _, name in ipairs(wanted) do
      if fs.exists(name) then have[#have + 1] = name end
    end
    writeText(INSTALLED_FILE, table.concat(have, "\n") .. "\n")
  end
end

-- An update that throws must not stop the autorun: a base wall that stays
-- dark because GitHub hiccuped is worse than one running yesterday's code.
local okU, errU = pcall(update, roleRequest)
if not okU then print("startup: update failed - " .. tostring(errU)) end
if roleRequest then return end

-- ---------------------------------------------------------------- autorun
local cmd = readLocal(AUTORUN_FILE)
cmd = cmd and cmd:gsub("^%s+", ""):gsub("%s+$", "") or ""
if cmd == "" then return end
if isFlight(cmd) then
  print("autorun: refusing '" .. cmd .. "' - flights are never started on boot")
  return
end

while true do
  print("autorun: " .. cmd .. " in 3 s - press any key for the shell")
  local skipped = false
  parallel.waitForAny(
    function() sleep(3) end,
    function() os.pullEvent("key") skipped = true end)
  if skipped then
    print("autorun: skipped - run 'startup' to try again")
    return
  end
  local ok = shell.run(cmd)
  print("autorun: " .. cmd .. (ok and " ended" or " stopped with an error") .. " - restarting")
end
