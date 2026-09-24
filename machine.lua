-- machine: this computer's own settings, kept in the repo under its name.
--
--   machine              what this machine keeps, here and in the repo
--   machine push [file]  put its settings in the repo (all of them, or one)
--   machine restore [file]   take them back out of it, over what is here
--
-- The folder is machines/<label>/ and only the computer with that label ever
-- writes it, so a second dock is a second folder rather than an edit to
-- everyone's copy. `startup` pulls this folder on every boot, so the repo is
-- what a machine is actually running; push after you change something here.
--
-- Keys are refused: lib/machine.lua names them, and anything with "key" in
-- it, and every dotfile. They are per machine too, and the repo is the one
-- place they must not be.

local MACHINE = dofile("lib/machine.lua")

local args = { ... }
local cmd = (args[1] or "list"):lower()
local REPO = "antrathent-sys/Chill-Grill-DroneNet"
local BRANCH = "main"

local label = os.getComputerLabel and os.getComputerLabel()
local folder = MACHINE.folder(label)
if not folder then
  print("this computer has no label, so its settings have nowhere to live")
  print("label set <name>   (a dock: its place name, a drone: drone-1)")
  return
end
local role = ""
if fs.exists(".role") then
  local h = fs.open(".role", "r")
  role = ((h and h.readAll()) or ""):gsub("%s+", "")
  if h then h.close() end
end
local wanted = MACHINE.wanted(role ~= "" and role or nil)

local function readLocal(name)
  if not fs.exists(name) then return nil end
  local h = fs.open(name, "r")
  local text = h and h.readAll() or nil
  if h then h.close() end
  return text
end

local HEADERS = { ["User-Agent"] = "dronenet-machine" }
do
  local token = readLocal(".ghtoken")
  if token then HEADERS.Authorization = "token " .. token:gsub("%s+", "") end
end

local function fetch(name)
  if not http then return nil, "the http API is disabled on this computer" end
  local url = string.format("https://raw.githubusercontent.com/%s/%s/%s/%s", REPO, BRANCH, folder, name)
  local res, err = http.get(url, HEADERS)
  if not res then return nil, err end
  local body = res.readAll()
  res.close()
  return body
end

-- what the repo has for this machine: one call, or a look for each file
local function inRepo()
  local out = {}
  if http then
    local url = string.format("https://api.github.com/repos/%s/contents/%s?ref=%s", REPO, folder, BRANCH)
    local res = http.get(url, HEADERS)
    if res then
      local body = res.readAll()
      res.close()
      for _, name in ipairs(MACHINE.namesIn(body)) do out[name] = true end
      return out
    end
  end
  for _, name in ipairs(wanted) do if fetch(name) then out[name] = true end end
  return out
end

if cmd == "list" then
  print(string.format("%s: %s", label, folder))
  local there = inRepo()
  for _, name in ipairs(wanted) do
    local here = fs.exists(name)
    print(string.format("  %-14s %-8s %s", name, here and "here" or "-", there[name] and "in the repo" or "-"))
  end
  for name in pairs(there) do
    local known = false
    for _, w in ipairs(wanted) do if w == name then known = true end end
    if not known then print(string.format("  %-14s %-8s in the repo (not one this role keeps)", name, "-")) end
  end
  print("")
  print("machine push [file] | machine restore [file]")
  return
end

if cmd == "push" then
  if not (fs.exists("upload.lua") and http) then
    print("push needs upload.lua and http here")
    return
  end
  local one = args[2]
  local sent, skipped = 0, 0
  for _, name in ipairs(wanted) do
    if (not one or one == name) and fs.exists(name) then
      local okA, whyA = MACHINE.allowed(name)
      if not okA then
        print(string.format("  %-14s refused: %s", name, whyA))
      else
        local ok = pcall(shell.run, "upload", "sync", name, folder .. "/" .. name)
        if ok then sent = sent + 1 else skipped = skipped + 1 print("  " .. name .. ": push failed") end
      end
    end
  end
  if one and sent == 0 and skipped == 0 then print(one .. " is not one of this machine's settings, or is not here") end
  print(string.format("%d pushed to %s", sent, folder))
  return
end

if cmd == "restore" then
  local one = args[2]
  local got, missing = 0, 0
  for _, name in ipairs(wanted) do
    if not one or one == name then
      local body, why = fetch(name)
      if body and body ~= "" and not body:find("^404") then
        local h = fs.open(name, "w")
        if h then
          h.write(body)
          h.close()
          got = got + 1
          print("  " .. name .. " restored")
        else
          print("  " .. name .. ": could not write it")
        end
      else
        missing = missing + 1
        if one then print("  " .. name .. ": not in the repo" .. (why and (" (" .. tostring(why) .. ")") or "")) end
      end
    end
  end
  print(string.format("%d restored from %s", got, folder))
  return
end

print("machine | machine push [file] | machine restore [file]")
