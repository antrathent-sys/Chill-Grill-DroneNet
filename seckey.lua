-- seckey: per-drone keys for the sealed radio link (lib/seclink.lua).
--
-- On the BASE computer:
--   seckey new drone-1     make a key for drone-1, keep it in .fleetkeys, print it
--                          (and write it to a floppy if one is in a disk drive)
--   seckey list            which drones have a key
--   seckey show drone-1    print drone-1's key again
--   seckey drop drone-1    forget drone-1's key (its telemetry is then refused)
--
-- Customers get their own keys, so a shuttle is ordered by someone you issued
-- a terminal to and not by anyone in radio range:
--   seckey cust new alex   make a customer key, keep it in .custkeys, hand it over
--                          NAME IT AFTER THEIR MINECRAFT USERNAME: the till
--                          reads the name of whoever sits in the Create Seat,
--                          and the two only line up if they match
--   seckey cust list       who has one
--   seckey cust drop alex  forget it - that terminal can no longer order
-- and on the customer's pocket:
--   seckey cust set <hex>  save it as .custkey (or `cust set disk`)
--
-- On the DRONE:
--   seckey set <64 hex>    save this drone's key in .dronekey (Ctrl+V pastes)
--   seckey set disk        copy it from the floppy `seckey new` wrote
--   seckey check           is there a key, and which id the telemetry will use
--
-- The drone's computer label must match the id the key was made for
-- (`label set drone-1`): the label is how the base picks the key.
-- Keys never go in the repo and never over the radio.

local SEC = dofile("lib/seclink.lua")
local args = { ... }
local FLEET, DRONE, KEYNAME = ".fleetkeys", ".dronekey", ".dronekey"
local CUSTS, CUST, CUSTNAME = ".custkeys", ".custkey", ".custkey"

-- Mount paths of every disk drive with a floppy in it, attached directly or
-- over a wired network (a docked drone sees the base's drives through the
-- pad cable). The first is "disk", then "disk2", ... - so never assume "disk".
local function floppies()
  local out = {}
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n) == "drive" then
      local okD, has = pcall(peripheral.call, n, "hasData")
      local okM, mount = pcall(peripheral.call, n, "getMountPath")
      if okD and has and okM and type(mount) == "string" then out[#out + 1] = mount end
    end
  end
  table.sort(out)
  return out
end

local function readText(p)
  if not fs.exists(p) then return nil end
  local h = fs.open(p, "r")
  local s = h.readAll()
  h.close()
  return s
end

local function writeText(p, s)
  local h = fs.open(p, "w")
  if not h then error("seckey: cannot write " .. p, 0) end
  h.write(s)
  h.close()
end

local function myId()
  return os.getComputerLabel() or ("drone-" .. os.getComputerID())
end

-- The customer list has the same shape as the fleet list, and is kept apart
-- from it on purpose: a customer key may only ASK for a shuttle, and must
-- never be usable to command one.
local function loadCusts()
  return SEC.readFleetKeys(CUSTS)
end

local function saveCusts(keys)
  local ids = {}
  for id in pairs(keys) do ids[#ids + 1] = id end
  table.sort(ids)
  local out = { "# Shuttle customer keys - one line per terminal you issued.\n" }
  for _, id in ipairs(ids) do out[#out + 1] = id .. "=" .. SEC.keyHex(keys[id]) .. "\n" end
  writeText(CUSTS, table.concat(out))
end

local function loadFleet()
  local keys = SEC.readFleetKeys(FLEET)
  return keys
end

local function saveFleet(keys)
  local ids = {}
  for id in pairs(keys) do ids[#ids + 1] = id end
  table.sort(ids)
  local out = { "# DroneNet fleet keys - one line per drone. Keep this computer private.\n" }
  for _, id in ipairs(ids) do out[#out + 1] = id .. "=" .. SEC.keyHex(keys[id]) .. "\n" end
  writeText(FLEET, table.concat(out))
end

local function usage()
  print("base:  seckey new <id> | list | show <id> | drop <id>")
  print("       seckey cust new|list|show|drop <name>")
  print("drone: seckey set <hex> | set disk | check")
  print("cust:  seckey cust set <hex> | cust set disk")
end

local cmd = args[1]

-- ------------------------------------------------------------- customers ---
if cmd == "cust" then
  local sub, id = args[2], args[3]
  if sub == "new" then
    if not id or not id:match("^[%w%-_]+$") or #id > 32 then
      print("seckey cust new <name>   e.g. seckey cust new alex") return
    end
    local keys = loadCusts()
    if keys[id] then print("replacing " .. id .. "'s key - their terminal will need the new one") end
    print("gathering randomness...")
    keys[id] = SEC.newKey()
    saveCusts(keys)
    local hex = SEC.keyHex(keys[id])
    print("key for " .. id .. " saved in " .. CUSTS)
    local disks = floppies()
    if #disks > 0 then
      writeText(disks[1] .. "/" .. CUSTNAME, hex .. "\n")
      print("written to the floppy in " .. disks[1] .. ".")
      print("On their pocket:  seckey cust set disk   then  label set " .. id)
      print("(use their Minecraft username as the id, so the seat at the till agrees)")
    else
      print("on their pocket, type:")
      print("seckey cust set " .. hex:sub(1, 16) .. " " .. hex:sub(17, 32) .. " " .. hex:sub(33, 48) .. " " .. hex:sub(49, 64))
      print("then  label set " .. id)
    end
    return
  elseif sub == "list" then
    local keys = loadCusts()
    local ids = {}
    for k in pairs(keys) do ids[#ids + 1] = k end
    table.sort(ids)
    if #ids == 0 then print("no customer keys - seckey cust new <name>") end
    for _, k in ipairs(ids) do print(string.format("%-16s %s...", k, SEC.keyHex(keys[k]):sub(1, 4))) end
    return
  elseif sub == "show" then
    local keys = loadCusts()
    if not (id and keys[id]) then print("no key for " .. tostring(id)) return end
    local hex = SEC.keyHex(keys[id])
    local disks = floppies()
    if #disks > 0 then
      writeText(disks[1] .. "/" .. CUSTNAME, hex .. "\n")
      print("written to the floppy in " .. disks[1] .. " - on their pocket: seckey cust set disk")
    else
      print("seckey cust set " .. hex:sub(1, 16) .. " " .. hex:sub(17, 32) .. " " .. hex:sub(33, 48) .. " " .. hex:sub(49, 64))
    end
    return
  elseif sub == "drop" then
    local keys = loadCusts()
    if not (id and keys[id]) then print("no key for " .. tostring(id)) return end
    keys[id] = nil
    saveCusts(keys)
    print("forgot " .. id .. " - that terminal can no longer order a shuttle")
    return
  elseif sub == "set" then
    local src, fromFile
    if args[3] == "disk" then
      for _, mount in ipairs(floppies()) do
        local pth = mount .. "/" .. CUSTNAME
        if fs.exists(pth) then src, fromFile = readText(pth), pth break end
      end
      if not src then print("no customer key on any floppy this computer can see") return end
    else
      src = table.concat(args, "", 3)
    end
    local key, why = SEC.parseKey(src)
    if not key then print("not a key: " .. tostring(why)) return end
    writeText(CUST, SEC.keyHex(key) .. "\n")
    print("customer key saved in " .. CUST .. " (" .. SEC.keyHex(key):sub(1, 4) .. "...)")
    if fromFile then fs.delete(fromFile) print("wiped it from the floppy") end
    if not os.getComputerLabel() then
      print("WARNING: no label. The base knows this key by name - run  label set <your name>")
    else
      print("this terminal orders as: " .. myId())
    end
    return
  end
  usage()
  return
end

if cmd == "new" then
  local id = args[2]
  if not id or not id:match("^[%w%-_]+$") or #id > 32 then
    print("seckey new <id>   e.g. seckey new drone-1") return
  end
  local keys = loadFleet()
  if keys[id] then print("replacing the existing key for " .. id .. " - the drone will need the new one") end
  print("gathering randomness...")
  local key = SEC.newKey()
  keys[id] = key
  saveFleet(keys)
  local hex = SEC.keyHex(key)
  print("key for " .. id .. " saved in " .. FLEET)
  local disks = floppies()
  if #disks > 0 then
    writeText(disks[1] .. "/" .. KEYNAME, hex .. "\n")
    print("written to the floppy in " .. disks[1] .. ".")
    print("Move it to a drive the drone can see (or leave it here while the")
    print("drone is docked) and on the drone run:  seckey set disk")
  else
    print("no floppy found - put one in a disk drive and run seckey show " .. id)
    print("or type it on the drone (spaces are fine):")
    print("seckey set " .. hex:sub(1, 16) .. " " .. hex:sub(17, 32) .. " " .. hex:sub(33, 48) .. " " .. hex:sub(49, 64))
  end

elseif cmd == "list" then
  local keys = loadFleet()
  local ids = {}
  for id in pairs(keys) do ids[#ids + 1] = id end
  table.sort(ids)
  if #ids == 0 then print("no keys - seckey new <id>") end
  for _, id in ipairs(ids) do print(string.format("%-16s %s...", id, SEC.keyHex(keys[id]):sub(1, 4))) end

elseif cmd == "show" then
  local keys = loadFleet()
  local key = args[2] and keys[args[2]]
  if not key then print("no key for " .. tostring(args[2])) return end
  local hex = SEC.keyHex(key)
  local disks = floppies()
  if #disks > 0 then
    writeText(disks[1] .. "/" .. KEYNAME, hex .. "\n")
    print("written to the floppy in " .. disks[1] .. " - on the drone: seckey set disk")
  else
    print("seckey set " .. hex:sub(1, 16) .. " " .. hex:sub(17, 32) .. " " .. hex:sub(33, 48) .. " " .. hex:sub(49, 64))
  end

elseif cmd == "drop" then
  local keys = loadFleet()
  if not (args[2] and keys[args[2]]) then print("no key for " .. tostring(args[2])) return end
  keys[args[2]] = nil
  saveFleet(keys)
  print("forgot " .. args[2] .. " - its telemetry will now be refused")

elseif cmd == "set" then
  local src, fromFile
  if args[2] == "disk" then
    for _, mount in ipairs(floppies()) do
      local p = mount .. "/" .. KEYNAME
      if fs.exists(p) then src, fromFile = readText(p), p break end
    end
    if not src then print("no key on any floppy this computer can see - insert the one from seckey new") return end
  else
    src = table.concat(args, "", 2)
  end
  local key, why = SEC.parseKey(src)
  if not key then print("not a key: " .. tostring(why)) return end
  writeText(DRONE, SEC.keyHex(key) .. "\n")
  print("key saved in " .. DRONE .. " (" .. SEC.keyHex(key):sub(1, 4) .. "...)")
  if fromFile then
    fs.delete(fromFile)
    print("wiped it from the floppy (" .. fromFile .. ")")
  end
  if not os.getComputerLabel() then
    print("WARNING: no label. The base knows this key by id - run  label set <id>")
  else
    print("telemetry id: " .. myId())
  end

elseif cmd == "check" then
  local key = SEC.readKeyFile(DRONE)
  print("telemetry id: " .. myId() .. (os.getComputerLabel() and "" or "  (no label - set one)"))
  print(key and ("key: yes (" .. SEC.keyHex(key):sub(1, 4) .. "...)") or "key: NO - telemetry will not be sent")
  local fleet = readText(FLEET)
  if fleet then print("this computer also holds " .. FLEET .. " (base)") end
  local cust = SEC.readKeyFile(CUST)
  if cust then print("customer key: yes (" .. SEC.keyHex(cust):sub(1, 4) .. "...) - orders as " .. myId()) end

else
  usage()
end
