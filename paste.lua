-- paste: get a file off this computer through a public paste host, and say
-- WHY when it does not work. CC's own `pastebin put` prints "Failed." for
-- every non-success reply and hides pastebin's reason ("Post limit, maximum
-- pastes per 24h reached", "IP blocked", ...): pastebin counts guest pastes
-- per API key and per IP, and CC's key is shared by every player of the mod.
--
--   paste <file>          try pastebin, then paste.rs; print the URL that worked
--   paste <file> rs       paste.rs only
--
-- Big files: `upload thin` first (every 4th row of a flightlog), then paste
-- flightlog.thin. Nothing here needs a token or an account.

local args = { ... }
local name, only = args[1], args[2]
if not name then
  print("usage: paste <file> [rs]")
  return
end
if not fs.exists(name) then
  print("no such file: " .. name)
  return
end
if not http then
  print("the http API is disabled on this computer")
  return
end

local f = fs.open(name, "r")
local text = f.readAll() or ""
f.close()
print(string.format("%s: %d KB", name, math.floor(#text / 1024)))

-- one attempt: returns the URL, or nil and the reason (status and body)
local function try(label, url, body, headers)
  write(label .. " ... ")
  local res, err, failed = http.post(url, body, headers)
  if not res then
    local why = tostring(err)
    if failed then
      local okc, code = pcall(failed.getResponseCode)
      local okb, reply = pcall(failed.readAll)
      pcall(failed.close)
      why = string.format("HTTP %s: %s", okc and tostring(code) or "?", okb and tostring(reply):sub(1, 160) or why)
    end
    print("no - " .. why)
    return nil, why
  end
  local reply = (res.readAll() or ""):gsub("%s+$", "")
  res.close()
  if not reply:match("^https?://") then
    print("no - " .. reply:sub(1, 160))
    return nil, reply
  end
  print("ok")
  return reply
end

local url
if only ~= "rs" then
  -- the same request the rom pastebin program makes, with the reply shown
  local key = "0ec2eb25b6166c0c27a394ae118ad829"
  url = try("pastebin.com", "https://pastebin.com/api/api_post.php",
    "api_option=paste&api_dev_key=" .. key .. "&api_paste_format=text&api_paste_name=" ..
    textutils.urlEncode(name) .. "&api_paste_code=" .. textutils.urlEncode(text))
end
if not url then
  -- paste.rs: the raw body is the paste, the reply is its URL
  url = try("paste.rs", "https://paste.rs/", text, { ["Content-Type"] = "text/plain" })
end
if url then
  print("")
  print(url)
  print("(fetch the raw text at that URL; pastebin needs /raw/ in front of the code)")
else
  print("")
  print("nothing accepted it - wait a while and try again, or set up .ghtoken and use upload")
  if #text > 60 * 1024 then
    print(string.format("(%d KB: paste.rs takes about 60 - `upload thin` picks a step that fits, then paste flightlog.thin)",
      math.floor(#text / 1024)))
  end
end
