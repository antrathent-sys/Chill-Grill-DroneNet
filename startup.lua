-- startup: pull the latest controller files from GitHub on boot.
-- Fetches each file below from the repo's raw URL, writes it to the root of
-- this computer, and prints what changed. Needs http enabled in the CC config.
local REPO   = "antrathent-sys/Chill-Grill-DroneNet"
local BRANCH = "main"
local FILES  = { "fly.lua", "kill.lua", "startup.lua", "probe.lua", "upload.lua", "preflight.lua",
                 "mixcal.lua",
                 "lib/chime.lua", "lib/db.lua", "lib/mission.lua",
                 "lib/mixer.lua" }

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

local function fetch(name)
  -- cache-buster so raw.githubusercontent.com doesn't hand back a stale copy
  local url = string.format("https://raw.githubusercontent.com/%s/%s/%s?t=%s",
    REPO, BRANCH, name, tostring(os.epoch("utc")))
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
    local f = fs.open(name, "w")
    f.write(body)
    f.close()
    updated[#updated + 1] = name
  end
end

if #updated > 0   then print("updated:   " .. table.concat(updated, ", ")) end
if #unchanged > 0 then print("unchanged: " .. table.concat(unchanged, ", ")) end
if #failed > 0    then print("FAILED:    " .. table.concat(failed, ", ")) end
if #updated == 0 and #failed == 0 then print("startup: all files current") end
