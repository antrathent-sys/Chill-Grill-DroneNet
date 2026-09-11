-- startup: pull the latest controller files from GitHub on boot.
-- Fetches each file below from the repo's raw URL, writes it to the root of
-- this computer, and prints what changed. Needs http enabled in the CC config.
local REPO   = "antrathent-sys/Chill-Grill-DroneNet"
local BRANCH = "main"
local FILES  = { "fly.lua", "kill.lua", "startup.lua", "probe.lua", "upload.lua", "preflight.lua",
                 "mixcal.lua",
                 "rsio.lua", "chimes.lua", "docktest.lua",
                 "lib/chime.lua", "lib/db.lua", "lib/mission.lua", "lib/rs.lua",
                 "lib/mixer.lua", "lib/attitude.lua" }

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

local REF = latestSha()
if REF then
  print("pulling commit " .. REF:sub(1, 7))
else
  REF = BRANCH
  print("WARNING: could not resolve latest commit, pulling '" .. BRANCH .. "' (may be up to 5 min stale)")
end

local function fetch(name)
  local url = string.format("https://raw.githubusercontent.com/%s/%s/%s", REPO, REF, name)
  local res, err = http.get(url, HEADERS)
  if not res then return nil, err end
  local body = res.readAll()
  res.close()
  return body
end

local function readLocal(name)
  if not fs.exists(name) then return nil end
  local f = fs.open(name, "r")
  local s = f.readAll()
  f.close()
  return s
end

if not http then
  print("startup: http API disabled - skipping update")
  return
end

-- Space. A flight writes ~230 bytes a row at 10 Hz, so a three minute flight
-- is a 400 KB flightlog, and the repo itself is another 300 KB. On a computer
-- with the default 1 MB that is survivable; on a server that has turned the
-- limit down it is not, and the failure looks like "Out of space" halfway
-- through an update with the tree left half old and half new.
local DISPOSABLE = { "flightlog", "probe.txt", "preflight.txt", "mixmap.csv", "probelog.csv" }

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

do
  local free = freeSpace()
  if free ~= math.huge then
    print(string.format("space: %.0fKB free", free / 1024))
    if free < 400 * 1024 then
      -- these are all either uploaded to the repo already or regenerable
      free = reclaim(400 * 1024)
      print(string.format("space: %.0fKB free after tidying", free / 1024))
    end
  end
end

local updated, unchanged, failed = {}, {}, {}
for _, name in ipairs(FILES) do
  local body, err = fetch(name)
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
    local ok, err = pcall(function()
      local f = fs.open(name, "w")
      f.write(body)
      f.close()
    end)
    if ok then
      updated[#updated + 1] = name
    else
      failed[#failed + 1] = string.format("%s (%s, %.0fKB free, needs %.0fKB)",
        name, tostring(err), freeSpace() / 1024, #body / 1024)
    end
  end
end

if #updated > 0   then print("updated:   " .. table.concat(updated, ", ")) end
if #unchanged > 0 then print("unchanged: " .. table.concat(unchanged, ", ")) end
if #failed > 0    then print("FAILED:    " .. table.concat(failed, ", ")) end
if #updated == 0 and #failed == 0 then print("startup: all files current") end
