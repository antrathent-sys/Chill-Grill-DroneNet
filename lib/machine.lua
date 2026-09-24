--- machine: one computer's own settings, kept in the repo under its name.
--
-- Everything that is true of ONE machine and nothing else - a dock's relay
-- map, a drone's calibration and tune, a base's places and prices - lives in
--
--   machines/<label>/<file>
--
-- and nowhere else. The computer labelled `test-dock` reads and writes
-- machines/test-dock/, and no other machine touches it. That way a second
-- dock is a second folder rather than an edit to everyone's copy, a rebuilt
-- computer comes back by pulling its own folder, and what a machine is
-- actually running can be read here instead of by standing at it.
--
--   startup            pulls this machine's folder over its local copies
--   machine            what is here, and what is in the repo
--   machine push       put this machine's settings in the repo
--   machine restore    take them back out of it
--
-- KEYS NEVER GO IN. A key is per machine too, but the repo is the one place
-- it must not be: `.dronekey`, `.fleetkeys`, `.custkey(s)`, `.ghtoken` and the
-- replay counters are refused here, by name and by shape, whatever a file
-- list says.
--
-- Pure: the file list and the rules only; the program does the reading,
-- writing and fetching, so tools/test_machine.lua checks all of this on the
-- desktop.

local M = {}

M.DIR = "machines"

-- What counts as this machine's own settings. A file is only ever pushed or
-- restored if it is on this list AND passes M.allowed.
M.FILES = {
  common = { "pads.lua" },
  drone  = { "cal.lua", "tune.lua", "mixmap.csv" },
  depot  = { "dock.lua", "station.lua", "relays.lua", "probe.txt" },
  base   = { "station.lua", "tariff.lua", "devices.lua", "probe.txt" },
  pad    = {},
  pocket = { "places.lua" },
  rs     = {},
}

-- Never, whatever anything else says: keys, counters, and the updater's own
-- bookkeeping. Matched on the name, so a list cannot smuggle one through.
M.NEVER = {
  [".ghtoken"] = true, [".dronekey"] = true, [".fleetkeys"] = true,
  [".custkey"] = true, [".custkeys"] = true, [".role"] = true,
  [".autorun"] = true, [".installed"] = true, [".pass"] = true,
}

--- Is this a file a machine may keep in the repo? Returns true, or false and
-- why not.
function M.allowed(name)
  if type(name) ~= "string" or name == "" then return false, "no name" end
  if M.NEVER[name] then return false, name .. " never leaves the computer it is on" end
  if name:sub(1, 1) == "." then return false, "a dotfile is the computer's own business" end
  if name:find("[/\\]") then return false, "one file, not a path" end
  if name:find("%.ctr$") then return false, "a replay counter never leaves its computer" end
  if name:lower():find("key") then return false, "anything with a key in the name stays put" end
  if not name:match("^[%w_%-%.]+$") then return false, "odd characters in " .. name end
  return true
end

--- A machine's folder in the repo. nil for a computer with no label: its
-- settings have nowhere to live until it has a name.
function M.folder(label)
  if type(label) ~= "string" or label == "" then return nil end
  if not label:match("^[%w_%-]+$") then return nil end
  return M.DIR .. "/" .. label
end

--- The files this machine keeps, by its role. Unknown role: the common ones
-- plus everything any role keeps, so nothing is silently left behind.
function M.wanted(role)
  local seen, out = {}, {}
  local function add(list)
    for _, f in ipairs(list or {}) do
      if not seen[f] and (M.allowed(f)) then seen[f] = true out[#out + 1] = f end
    end
  end
  add(M.FILES.common)
  if type(role) == "string" and M.FILES[role] then
    add(M.FILES[role])
  else
    for name, list in pairs(M.FILES) do if name ~= "common" then add(list) end end
  end
  table.sort(out)
  return out
end

--- The names in a GitHub contents listing, for the one call that says what a
-- machine's folder holds. Nothing here trusts the JSON beyond the names, and
-- each is checked by M.allowed before it is used.
function M.namesIn(json)
  local out = {}
  for name in tostring(json or ""):gmatch('"name"%s*:%s*"([^"]+)"') do
    if (M.allowed(name)) then out[#out + 1] = name end
  end
  return out
end

return M
