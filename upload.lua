-- upload: push the last flightlog to GitHub so it can be read without anyone
-- copying files out of the save.
--
--   upload              downsample and push flightlog
--   upload full         push every row (big, use sparingly)
--   upload <file>       push some other file
--
-- Needs a .ghtoken on this computer with **Contents: write** on the repo.
-- The read-only token startup.lua uses is not enough.

local REPO   = "antrathent-sys/Chill-Grill-DroneNet"
local BRANCH = "main"
local DIR    = "logs/flights"      -- where logs land in the repo
local KEEP   = 12                  -- keep every Nth row when downsampling

local args = { ... }
local full = args[1] == "full"
local src  = (not full and args[1]) or "flightlog"

-- ---------- base64, for the GitHub contents API ----------
local B = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function b64(data)
  local out, n = {}, #data
  local i = 1
  while i + 2 <= n do
    local a, b, c = data:byte(i, i + 2)
    local v = a * 65536 + b * 256 + c
    out[#out + 1] = B:sub(math.floor(v / 262144) + 1, math.floor(v / 262144) + 1)
    out[#out + 1] = B:sub(math.floor(v / 4096) % 64 + 1, math.floor(v / 4096) % 64 + 1)
    out[#out + 1] = B:sub(math.floor(v / 64) % 64 + 1, math.floor(v / 64) % 64 + 1)
    out[#out + 1] = B:sub(v % 64 + 1, v % 64 + 1)
    i = i + 3
  end
  local rem = n - i + 1
  if rem == 1 then
    local a = data:byte(i)
    local v = a * 16
    out[#out + 1] = B:sub(math.floor(v / 64) + 1, math.floor(v / 64) + 1)
    out[#out + 1] = B:sub(v % 64 + 1, v % 64 + 1)
    out[#out + 1] = "=="
  elseif rem == 2 then
    local a, b = data:byte(i, i + 1)
    local v = (a * 256 + b) * 4
    out[#out + 1] = B:sub(math.floor(v / 4096) + 1, math.floor(v / 4096) + 1)
    out[#out + 1] = B:sub(math.floor(v / 64) % 64 + 1, math.floor(v / 64) % 64 + 1)
    out[#out + 1] = B:sub(v % 64 + 1, v % 64 + 1)
    out[#out + 1] = "="
  end
  return table.concat(out)
end

-- ---------- read, and thin out the boring rows ----------
-- A 30 second flight is ~600 rows. Keeping every row for every flight would
-- bloat the repo fast, so by default keep the header, every phase change (the
-- interesting bits) and every KEEPth row otherwise.
local function readLog(path)
  if not fs.exists(path) then error("no " .. path .. " on this computer") end
  local h = fs.open(path, "r")
  local lines, total = {}, 0
  local header = h.readLine()
  if not header then h.close() error(path .. " is empty") end
  lines[1] = header
  local lastPhase, i = nil, 0
  while true do
    local line = h.readLine()
    if not line then break end
    total = total + 1
    i = i + 1
    local phase = line:match("^[^,]*,([^,]*)")
    local keep = full or (i % KEEP == 0) or (phase ~= lastPhase)
    lastPhase = phase
    if keep then lines[#lines + 1] = line end
  end
  h.close()
  return table.concat(lines, "\n") .. "\n", total, #lines - 1
end

-- ---------- push ----------
local function token()
  if not fs.exists(".ghtoken") then
    error("no .ghtoken on this computer (needs Contents: write)")
  end
  local f = fs.open(".ghtoken", "r")
  local t = (f.readAll() or ""):gsub("%s+", "")
  f.close()
  if #t == 0 then error(".ghtoken is empty") end
  return t
end

-- One blocking request. Returns code, body.
local function call(method, url, body)
  local ok, err = http.request({
    url = url, body = body, method = method,
    headers = {
      Authorization = "token " .. token(),
      Accept = "application/vnd.github+json",
      ["Content-Type"] = "application/json",
    },
  })
  if ok == false then error("http.request refused: " .. tostring(err), 0) end
  -- http_success is (url, handle); http_failure is (url, message, handle)
  while true do
    local ev, evUrl, a, b = os.pullEvent()
    if evUrl == url then
      if ev == "http_success" then
        local code, text = a.getResponseCode(), a.readAll()
        a.close()
        return code, text
      elseif ev == "http_failure" then
        local code = b and b.getResponseCode() or nil
        local text = b and b.readAll() or ""
        if b then b.close() end
        if code then return code, text end
        error("http failed: " .. tostring(a), 0)
      end
    end
  end
end

-- GitHub needs the current blob sha to replace an existing file. Absent for a
-- new path, which is why flight logs use unique names and never need this.
local function shaOf(url)
  local code, text = call("GET", url)
  if code ~= 200 then return nil end
  local t = textutils.unserializeJSON(text)
  return t and t.sha
end

local function put(path, content, message)
  local url = "https://api.github.com/repos/" .. REPO .. "/contents/" .. path
  local payload = {
    message = message,
    content = b64(content),
    branch  = BRANCH,
  }
  local sha = shaOf(url)          -- nil for a new file
  if sha then payload.sha = sha end

  local code, text = call("PUT", url, textutils.serializeJSON(payload))
  if code ~= 200 and code ~= 201 then
    error(string.format("upload failed (%s): %s", tostring(code), tostring(text):sub(1, 200)), 0)
  end
  return code
end

if not http then error("http API is disabled on this server") end

local stamp = os.date("%Y-%m-%d_%H-%M-%S")

-- `upload sync <file> <repo/path>` pushes any file to a fixed path, replacing
-- whatever is there. This is how the depot mirrors its database into the repo.
if args[1] == "sync" then
  local from, to = args[2], args[3]
  if not from or not to then error("usage: upload sync <file> <repo/path>", 0) end
  if not fs.exists(from) then error("no " .. from, 0) end
  local f = fs.open(from, "r")
  local content = f.readAll()
  f.close()
  print(string.format("sync %s -> %s (%d bytes)", from, to, #content))
  print("done, HTTP " .. tostring(put(to, content, "sync " .. to .. " " .. stamp)))
  return
end

local content, total, kept = readLog(src)
local name = string.format("%s/%s_%s.csv", DIR, stamp, full and "full" or "sampled")

print(string.format("%s: %d rows -> %d kept, %d bytes", src, total, kept, #content))
print("pushing " .. name)
print("done, HTTP " .. tostring(put(name, content,
  string.format("flightlog %s (%d of %d rows)", stamp, kept, total))))
