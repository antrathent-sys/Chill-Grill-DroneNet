--- names: what a unit is called, everywhere a person reads it (Alex,
-- 2026-09-30: "drone-01 ... should be listed as LAMBDA-001").
--
-- A unit's computer label stays drone-N: its key is filed under it (seckey,
-- .fleetkeys), and every sealed packet carries it. Everything shown - the
-- screens, the ops board and its log, the pockets, the depots - says the
-- craft's name instead: its class and a three-digit number, LAMBDA-001.
-- LAMBDA is the passenger class; freighters are ZETA (DroneNet branding),
-- named per unit in N.CLASS_OF when there are any. Commands take either:
-- `ops fly lambda-001 ...` is `ops fly drone-1 ...`.
--
-- Pure; tools/test_names.lua.

local N = {}

N.CLASS = "LAMBDA"
N.CLASS_OF = {}            -- { ["drone-2"] = "ZETA" } for a freighter
N.CLASSES = { LAMBDA = true, ZETA = true }

--- drone-1 -> "LAMBDA-001". Anything that is not a unit's label comes back
-- as it is, in capitals - so a name shown twice is never mangled.
function N.unit(id)
  if type(id) ~= "string" or id == "" then return id end
  local n = id:lower():match("^drone%-(%d+)$")
  if not n then return id:upper() end
  local class = N.CLASS_OF[id:lower()] or N.CLASS
  return string.format("%s-%03d", class, tonumber(n))
end

--- "LAMBDA-001", "lambda-1", "zeta-002" -> "drone-1" / "drone-2"; a label
-- stays a label; nil for anything that is not a unit.
function N.id(name)
  if type(name) ~= "string" then return nil end
  local s = name:lower()
  if s:match("^drone%-%d+$") then return s end
  local class, n = s:match("^(%a+)%-?(%d+)$")
  if class and N.CLASSES[class:upper()] then return "drone-" .. tonumber(n) end
  return nil
end

--- Every drone-N in a line of text, as its name: for logs and messages.
function N.text(s)
  if type(s) ~= "string" then return s end
  return (s:gsub("[Dd][Rr][Oo][Nn][Ee]%-(%d+)", function(n) return N.unit("drone-" .. n) end))
end

return N
