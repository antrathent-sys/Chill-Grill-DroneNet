-- Desktop tests for paste.lua: pastebin's reason is shown, and paste.rs is
-- tried when pastebin refuses.
local DIR = ...
local pass, fail = 0, 0
local function check(n, c, d)
  if c then pass = pass + 1 print("  ok   " .. n)
  else fail = fail + 1 print("  FAIL " .. n .. (d and ("  " .. tostring(d)) or "")) end
end

-- opts.pastebin / opts.rs: a function(body) -> reply text, or { code = n, body = s } for a failure
local function computer(opts)
  local w = { printed = {}, posts = {} }
  local env = setmetatable({}, { __index = _G })
  local function out(s) w.printed[#w.printed + 1] = tostring(s) end
  env.print = out
  env.write = out
  env.fs = {
    exists = function(p) return p == "flightlog.thin" end,
    open = function() return { readAll = function() return "t,phase\n1,fly\n" end, close = function() end } end,
  }
  env.textutils = { urlEncode = function(s) return (s:gsub("[^%w]", function(c) return string.format("%%%02X", c:byte()) end)) end }
  env.http = { post = function(url, body, headers)
    w.posts[#w.posts + 1] = { url = url, body = body, headers = headers }
    local host = url:match("^https?://([^/]+)")
    local r = opts[host == "pastebin.com" and "pastebin" or "rs"]
    if r == nil then return nil, "Could not connect" end
    local reply = r(body)
    if type(reply) == "table" then
      return nil, "HTTP " .. reply.code, { getResponseCode = function() return reply.code end,
                                        readAll = function() return reply.body end, close = function() end }
    end
    return { readAll = function() return reply end, close = function() end }
  end }
  w.env = env
  return w
end

local function run(w, ...)
  local f = assert(loadfile(DIR .. "/../paste.lua"))
  setfenv(f, w.env)
  local ok, err = pcall(f, ...)
  w.err = (not ok) and tostring(err) or nil
  w.text = table.concat(w.printed, "\n")
  return w
end
local function has(w, s) return w.text:find(s, 1, true) ~= nil end

print("pastebin works")
local w = run(computer({ pastebin = function() return "https://pastebin.com/AbCdEf12\n" end }), "flightlog.thin")
check("prints the pastebin url", w.err == nil and has(w, "https://pastebin.com/AbCdEf12"), w.err or w.text)
check("posts the rom program's fields", w.posts[1].body:find("api_option=paste", 1, true)
  and w.posts[1].body:find("api_paste_code=t%2Cphase", 1, true) ~= nil)
check("does not bother paste.rs", #w.posts == 1)

print("pastebin refuses")
w = run(computer({ pastebin = function() return { code = 422, body = "Post limit, maximum pastes per 24h reached" } end,
                   rs = function() return "https://paste.rs/xyz9" end }), "flightlog.thin")
check("shows pastebin's reason", has(w, "HTTP 422: Post limit, maximum pastes per 24h reached"), w.text)
check("falls back to paste.rs and prints its url", has(w, "https://paste.rs/xyz9") and #w.posts == 2)
check("paste.rs gets the raw text", w.posts[2].body == "t,phase\n1,fly\n" and w.posts[2].headers["Content-Type"] == "text/plain")

w = run(computer({ pastebin = function() return "Bad API request, IP blocked" end,
                   rs = function() return "https://paste.rs/abc" end }), "flightlog.thin")
check("a 200 with an error message is still a refusal, shown", has(w, "no - Bad API request, IP blocked") and has(w, "https://paste.rs/abc"))

print("everything refuses")
w = run(computer({ pastebin = function() return { code = 422, body = "Post limit" } end }), "flightlog.thin")
check("says nothing accepted it, with both reasons", has(w, "Post limit") and has(w, "Could not connect") and has(w, "nothing accepted it"))

print("rs only")
w = run(computer({ pastebin = function() return "https://pastebin.com/never" end, rs = function() return "https://paste.rs/only" end }),
  "flightlog.thin", "rs")
check("rs skips pastebin", #w.posts == 1 and has(w, "https://paste.rs/only"))

print("bad input")
w = run(computer({}), "nothere")
check("missing file", has(w, "no such file"))
w = run(computer({}))
check("usage", has(w, "usage: paste"))

print("")
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then error("paste tests failed", 0) end
