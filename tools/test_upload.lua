-- Test upload.lua against a mocked GitHub contents API.
--   python tools/run_upload_test.py
-- Covers everything except the actual network hop: request shape, base64 round
-- trip, sha handling for new vs existing files, downsampling, sync mode, and
-- the failure paths.

local DIR = ...

-- ---------- minimal JSON, one line, matching CC's textutils ----------
local function esc(s)
  s = s:gsub('[\\"]', '\\%0'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
  return s
end
local function jenc(v)
  local ty = type(v)
  if ty == "boolean" or ty == "number" then return tostring(v) end
  if ty == "string" then return '"' .. esc(v) .. '"' end
  if ty == "table" then
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = '"' .. k .. '":' .. jenc(v[k]) end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  error("jenc " .. ty)
end
local function jdec(s)
  -- only needs to handle the flat objects the mock returns
  local t = {}
  for k, v in s:gmatch('"([%w_]+)":"([^"]*)"') do t[k] = v end
  return t
end
_G.textutils = { serializeJSON = jenc, unserializeJSON = jdec }

-- ---------- base64 decode, to prove the upload round trips ----------
local B = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function unb64(data)
  data = data:gsub("=", "")
  local bits, out = "", {}
  for c in data:gmatch(".") do
    local idx = B:find(c, 1, true) - 1
    local b = ""
    for i = 5, 0, -1 do b = b .. (math.floor(idx / 2 ^ i) % 2) end
    bits = bits .. b
  end
  for i = 1, #bits - 7, 8 do
    local byte = 0
    for j = 0, 7 do byte = byte * 2 + tonumber(bits:sub(i + j, i + j)) end
    out[#out + 1] = string.char(byte)
  end
  return table.concat(out)
end

-- ---------- fs over real files, plus a fake .ghtoken ----------
local files = {}
_G.fs = {
  exists = function(p)
    if files[p] then return true end
    local f = io.open(p, "rb"); if f then f:close() return true end
    return false
  end,
  open = function(p, mode)
    if files[p] then
      local content, pos = files[p], 1
      return {
        readAll = function() local r = content:sub(pos) pos = #content + 1 return r end,
        readLine = function()
          if pos > #content then return nil end
          local nl = content:find("\n", pos, true)
          local line
          if nl then line = content:sub(pos, nl - 1) pos = nl + 1
          else line = content:sub(pos) pos = #content + 1 end
          return line
        end,
        close = function() end,
      }
    end
    local f = io.open(p, mode == "a" and "ab" or (mode == "w" and "wb" or "rb"))
    if not f then return nil end
    return {
      readAll = function() return f:read("*a") end,
      readLine = function() return f:read("*l") end,
      writeLine = function(t) f:write(t, "\n") end,
      write = function(t) f:write(t) end,
      close = function() f:close() end,
    }
  end,
}
files[".ghtoken"] = "ghp_faketoken123\n"

-- ---------- mocked http ----------
local requests, responses, queue = {}, {}, {}
_G.http = {
  request = function(req)
    requests[#requests + 1] = req
    local key = req.method .. " " .. req.url
    local r = responses[key] or responses[req.method] or { code = 500, body = "no mock for " .. key }
    queue[#queue + 1] = { url = req.url, code = r.code, body = r.body, fail = r.fail }
    return true
  end,
}
_G.os = _G.os or {}
local realDate = os.date
os.date = function(fmt) return "2026-09-10_12-00-00" end
os.pullEvent = function()
  local e = table.remove(queue, 1)
  if not e then error("pullEvent with nothing queued", 0) end
  local handle = {
    getResponseCode = function() return e.code end,
    readAll = function() return e.body end,
    close = function() end,
  }
  if e.fail then return "http_failure", e.url, e.body, handle end
  return "http_success", e.url, handle
end

-- ---------- helpers ----------
local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1 print("  ok   " .. name)
  else fail = fail + 1 print("  FAIL " .. name .. (detail and ("  " .. tostring(detail)) or "")) end
end
local function run(...)
  requests = {}
  local f = assert(loadfile(DIR .. "/../upload.lua"))
  return pcall(f, ...)
end
local function bodyOf(req) return jdec(req.body) end
local API = "https://api.github.com/repos/antrathent-sys/Chill-Grill-DroneNet/contents/"

-- a small flight log with phase changes
local rows = { "t,phase,height,err,pwr,gps,x,z,ex,ez,vxw,vzw,hdg,rawhdg,mothdg,tp,tr,p,r,vx,vy,sched,fwdRaw,latRaw,vrtRaw,fwdH,latH,energy,fuel" }
for i = 1, 100 do
  local ph = i < 30 and "climb" or (i < 60 and "dash" or "hold")
  rows[#rows + 1] = string.format("%.2f,%s,64,0,0.5,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,90,80", i * 0.05, ph)
end
files["flightlog"] = table.concat(rows, "\n") .. "\n"

print("new file: no sha, 201")
responses = {
  ["GET " .. API .. "logs/flights/2026-09-10_12-00-00_sampled.csv"] = { code = 404, body = "{}", fail = true },
  ["PUT"] = { code = 201, body = '{"content":"ok"}' },
}
local ok, err = run()
check("runs clean", ok, err)
check("two requests: GET then PUT", #requests == 2 and requests[1].method == "GET" and requests[2].method == "PUT",
      #requests .. " requests")
local put = requests[2]
check("PUT hits the timestamped path",
      put and put.url == API .. "logs/flights/2026-09-10_12-00-00_sampled.csv", put and put.url)
local b = put and bodyOf(put) or {}
check("no sha on a new file", b.sha == nil, b.sha)
check("branch is main", b.branch == "main", b.branch)
check("auth header sent", put and put.headers.Authorization == "token ghp_faketoken123",
      put and put.headers.Authorization)
local decoded = b.content and unb64(b.content) or ""
check("base64 round trips", decoded:sub(1, 8) == "t,phase,", decoded:sub(1, 20))
local n = select(2, decoded:gsub("\n", ""))
check("downsampled", n > 5 and n < 40, n .. " lines")
check("header preserved", decoded:match("^t,phase,height"))
local seen = {}
for ph in decoded:gmatch("\n[%d%.]+,(%a+)") do seen[ph] = true end
check("all three phases survive", seen.climb and seen.dash and seen.hold,
      table.concat({ tostring(seen.climb), tostring(seen.dash), tostring(seen.hold) }, ","))

print("existing file: sha fetched and sent")
responses = {
  ["GET"] = { code = 200, body = '{"sha":"abc123def"}' },
  ["PUT"] = { code = 200, body = '{"content":"ok"}' },
}
ok, err = run("sync", "flightlog", "data/orders.db")
check("sync runs clean", ok, err)
check("sync PUTs to the given path", requests[2] and requests[2].url == API .. "data/orders.db",
      requests[2] and requests[2].url)
local sb = requests[2] and bodyOf(requests[2]) or {}
check("sha included when replacing", sb.sha == "abc123def", sb.sha)
local synced = sb.content and unb64(sb.content) or ""
check("sync sends the file verbatim, not downsampled",
      select(2, synced:gsub("\n", "")) == 101, select(2, synced:gsub("\n", "")))

print("full mode")
responses = { ["GET"] = { code = 404, body = "{}", fail = true }, ["PUT"] = { code = 201, body = "{}" } }
ok, err = run("full")
check("full runs clean", ok, err)
local fb = requests[2] and bodyOf(requests[2]) or {}
local fullTxt = fb.content and unb64(fb.content) or ""
check("full keeps every row", select(2, fullTxt:gsub("\n", "")) == 101,
      select(2, fullTxt:gsub("\n", "")))
check("full names the file full", requests[2].url:match("_full%.csv") ~= nil, requests[2].url)

print("failure paths")
responses = { ["GET"] = { code = 404, body = "{}", fail = true }, ["PUT"] = { code = 422, body = '{"message":"bad"}' } }
ok, err = run()
check("rejects a 422", not ok and tostring(err):match("422") ~= nil, err)

files[".ghtoken"] = nil
responses = { ["GET"] = { code = 404, body = "{}", fail = true }, ["PUT"] = { code = 201, body = "{}" } }
ok, err = run()
check("errors clearly with no token", not ok and tostring(err):match("ghtoken") ~= nil, err)
files[".ghtoken"] = "ghp_faketoken123"

files["flightlog"] = nil
ok, err = run()
check("errors clearly with no flightlog", not ok and tostring(err):match("flightlog") ~= nil, err)

print("")
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then error("upload tests failed", 0) end
