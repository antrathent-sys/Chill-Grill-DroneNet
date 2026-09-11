-- kill: panic stop. Cuts thruster power and zeroes the nozzle vector.
-- Run this after Ctrl+T-ing fly, or bind it to whatever you trigger in a hurry.
-- Set this to the same side as CFG.DOCK_SIDE in fly.lua. Dropping that signal
-- is what undocks the drone, so a panic stop must never clear it.
-- A plain side string, or a remote target as in fly.lua's CFG, e.g.
--   { slave = "drone-rs", side = "back" }
local DOCK_SIDE = nil

local thrs = { peripheral.find("vector_thruster") }
if #thrs == 0 then error("no vector_thruster found") end
for _, thr in ipairs(thrs) do
  thr.setPowerNormalized(0)
  thr.setVector(0, 0)
end
-- drop any pump/clutch the computer is holding on, but never the docking
-- connector: cutting its signal releases the drone from the pad.
local okR, RS = pcall(dofile, "lib/rs.lua")
if okR and type(RS) == "table" then
  RS.clear(DOCK_SIDE)          -- clears remote sides too, never the dock one
else
  for _, side in ipairs(redstone.getSides()) do
    if side ~= DOCK_SIDE then redstone.setOutput(side, false) end
  end
  if type(DOCK_SIDE) == "table" then print("  WARNING: lib/rs.lua missing - remote sides NOT cleared") end
end
for _, m in ipairs({ peripheral.find("electric_motor") }) do m.stop() end
print("KILL: " .. #thrs .. " thruster(s) power 0, vectors zeroed, redstone + motors off")
if DOCK_SIDE then
  local d = type(DOCK_SIDE) == "table" and ((DOCK_SIDE.slave or DOCK_SIDE.relay or "?") .. ":" .. tostring(DOCK_SIDE.side)) or DOCK_SIDE
  print("  " .. d .. " held - docking connector left extended")
end
