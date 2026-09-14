-- seckey: per-drone keys for the sealed radio link (lib/seclink.lua).
--
-- On the BASE computer:
--   seckey new drone-1     make a key for drone-1, keep it in .fleetkeys, print it
--                          (and write it to a floppy if one is in a disk drive)
--   seckey list            which drones have a key
--   seckey show drone-1    print drone-1's key again
--   seckey drop drone-1    forget drone-1's key (its telemetry is then refused)
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
local FLEET, DRONE, FLOPPY = ".fleetkeys", ".dronekey", "disk/.dronekey"

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
  print("drone: seckey set <hex> | set disk | check")
end

local cmd = args[1]

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
  if fs.exists("disk") and fs.isDir("disk") then
    writeText(FLOPPY, hex .. "\n")
    print("also written to the floppy: on the drone, run  seckey set disk")
  end
  print("on the drone (label " .. id .. "), run:")
  print("seckey set " .. hex)

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
  print("seckey set " .. SEC.keyHex(key))

elseif cmd == "drop" then
  local keys = loadFleet()
  if not (args[2] and keys[args[2]]) then print("no key for " .. tostring(args[2])) return end
  keys[args[2]] = nil
  saveFleet(keys)
  print("forgot " .. args[2] .. " - its telemetry will now be refused")

elseif cmd == "set" then
  local src
  if args[2] == "disk" then
    src = readText(FLOPPY)
    if not src then print("no " .. FLOPPY .. " - insert the floppy from seckey new") return end
  else
    src = table.concat(args, "", 2)
  end
  local key, why = SEC.parseKey(src)
  if not key then print("not a key: " .. tostring(why)) return end
  writeText(DRONE, SEC.keyHex(key) .. "\n")
  print("key saved in " .. DRONE .. " (" .. SEC.keyHex(key):sub(1, 4) .. "...)")
  if args[2] == "disk" then
    fs.delete(FLOPPY)
    print("removed it from the floppy")
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

else
  usage()
end
