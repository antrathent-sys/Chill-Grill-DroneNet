-- provision: make customers' passes, and look after them.
--
-- Runs on the base computer, with a disk drive against it: the customer key
-- file (.custkeys) lives here and ops reads it, so a pass made here works the
-- moment it leaves the drive. A pocket computer put in a disk drive mounts
-- like a disk, and that is how its files get written.
--
--   provision              watch the drive. Put a pocket computer in, answer at
--                          most one question, and it comes out ready.
--   provision alex sam     the next blank pockets become alex's, then sam's,
--                          with no questions at all
--   provision list         everyone with a pass
--   provision drop <name>  that pass stops working at once. Their account and
--                          balance stay; a new pass for the same name picks
--                          them up.
--
-- What it does with whatever goes in the drive:
--   a blank pocket        asks whose it is (their Minecraft name), makes a key,
--                         writes the pass, labels it, ejects it
--   one of our passes     shows any crash note, puts the current programs on,
--                         keeps the key, ejects it. This is how passes update.
--   a revoked or replaced pass   offers to reissue it or wipe it
--   one of your machines  refused and ejected untouched: anything with
--                         .ghtoken, .fleetkeys, a drone key or a startup role
--   anything else         lists what is on it and asks before wiping
--
-- Run it in a second tab on the base (`bg provision`) and ops keeps running in
-- the first. ops notices .custkeys changing, so a new pass works and a dropped
-- one stops without restarting anything.

local SEC = dofile("lib/seclink.lua")
local P = dofile("lib/provision.lua")
local CUSTS = ".custkeys"
local args = { ... }

local function loadKeys() return (SEC.readFleetKeys(CUSTS)) end
local function saveKeys(keys)
  local h = fs.open(CUSTS, "w")
  if not h then error("provision: cannot write " .. CUSTS, 0) end
  h.write(SEC.formatFleetKeys(keys, SEC.CUST_HEADER))
  h.close()
end

local function sortedNames(keys)
  local t = {}
  for id in pairs(keys) do t[#t + 1] = id end
  table.sort(t)
  return t
end

-- ------------------------------------------------------------ list, drop ---
if args[1] == "list" then
  local names = sortedNames(loadKeys())
  if #names == 0 then print("no passes yet - provision, then put a pocket computer in the drive") end
  for _, n in ipairs(names) do print("  " .. n) end
  return
end

if args[1] == "drop" then
  local keys, name = loadKeys(), args[2]
  if not (name and keys[name]) then print("no pass for " .. tostring(name)) return end
  keys[name] = nil
  saveKeys(keys)
  print(name .. "'s pass no longer works. Their balance is kept.")
  return
end

-- ------------------------------------------------------------ the drive ---
local queue = {}
for _, n in ipairs(args) do
  if not P.validName(n) then
    print("not a Minecraft name: " .. n .. " (3 to 16 letters, digits or _)")
    return
  end
  queue[#queue + 1] = n
end

local function yes(prompt)
  write(prompt .. " [y/n] ")
  while true do
    local _, ch = os.pullEvent("char")
    ch = tostring(ch):lower()
    if ch == "y" or ch == "n" then print(ch) return ch == "y" end
  end
end

local function eject(drive) pcall(peripheral.call, drive, "ejectDisk") end

local function handle(drive)
  local okM, mount = pcall(peripheral.call, drive, "getMountPath")
  if not (okM and type(mount) == "string") then return end
  print("")
  -- a floppy is not a pass, and writing one would only confuse things later
  local okC, cap = pcall(fs.getCapacity, mount)
  if okC and cap and cap < 500000 then
    print("that is a floppy - put the pocket computer itself in the drive")
    eject(drive)
    return
  end

  local info = P.inspect(fs, mount)
  if info.kind == "dev" then
    print("refused: this is one of your own machines (it has " .. info.marker .. ") - not touching it")
    eject(drive)
    return
  end

  local keys = loadKeys()
  local name, mode
  if info.kind == "pass" then
    name = info.owner
    local note = P.crashNote(fs, mount, 3)
    if note then
      print(name .. "'s pass stopped since it was last here:")
      for _, line in ipairs(note) do print("  " .. line) end
    end
    local current = keys[name] and SEC.keyHex(keys[name])
    if current and info.keyHex and current:lower() == info.keyHex:lower() then
      mode = "update"
    else
      print(current and ("this is an old pass of " .. name .. "'s - their key was replaced since")
                     or (name .. "'s pass was dropped"))
      if yes("reissue it to " .. name .. "?") then
        mode = "reissue"
      elseif yes("wipe it blank?") then
        P.wipe(fs, mount)
        pcall(peripheral.call, drive, "setDiskLabel", nil)
        print("wiped")
        eject(drive)
        return
      else
        eject(drive)
        return
      end
    end
  else
    if info.kind == "other" then
      print("this pocket has files on it: " .. table.concat(info.files, ", "))
      if not yes("wipe them and make a pass?") then eject(drive) return end
    end
    name = table.remove(queue, 1)
    if name then
      print("this one is " .. name .. "'s")
    else
      while true do
        write("whose pass? (their Minecraft name, blank to eject) ")
        name = read()
        if name == "" then eject(drive) return end
        if P.validName(name) then break end
        print("3 to 16 letters, digits or _")
      end
    end
    if keys[name] and not yes(name .. " already has a pass. Replace it? The old one stops working.") then
      eject(drive)
      return
    end
    mode = "new"
  end

  local keyHex
  if mode ~= "update" then
    print("making a key...")
    keys[name] = SEC.newKey()
    keyHex = SEC.keyHex(keys[name])
  end
  local version
  if fs.exists(".commit") then
    local h = fs.open(".commit", "r")
    version = h and h.readLine()
    if h then h.close() end
  end
  local ok, why = P.install(fs, mount, { owner = name, keyHex = keyHex, program = "hail", version = version })
  if not ok then
    print("could not make the pass: " .. tostring(why))
    eject(drive)
    return
  end
  -- the base learns the key only once the pass has it, so a failed write
  -- never leaves a key that no pass holds
  if keyHex then saveKeys(keys) end
  pcall(peripheral.call, drive, "setDiskLabel", name)
  print(string.format("%s's pass is %s. Hand it over.",
    name, mode == "update" and "up to date" or (mode == "reissue" and "reissued" or "ready")))
  eject(drive)
end

local function drivesWithMedia()
  local out = {}
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n) == "drive" then
      local okD, has = pcall(peripheral.call, n, "hasData")
      if okD and has then out[#out + 1] = n end
    end
  end
  return out
end

local anyDrive = false
for _, n in ipairs(peripheral.getNames()) do
  if peripheral.getType(n) == "drive" then anyDrive = true end
end
if not anyDrive then
  print("provision: no disk drive on this computer - put one against it")
  return
end

print("provision: put a pocket computer in the drive" ..
  (#queue > 0 and (" (next: " .. table.concat(queue, ", ") .. ")") or ""))
for _, d in ipairs(drivesWithMedia()) do handle(d) end
while true do
  local _, drive = os.pullEvent("disk")
  handle(drive)
  if #queue == 0 then print("") print("ready for the next one") end
end
