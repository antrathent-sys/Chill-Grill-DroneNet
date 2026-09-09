-- kill: panic stop. Cuts thruster power and zeroes the nozzle vector.
-- Run this after Ctrl+T-ing fly, or bind it to whatever you trigger in a hurry.
local thr = peripheral.find("vector_thruster")
if not thr then error("no vector_thruster found") end
thr.setPowerNormalized(0)
thr.setVector(0, 0)
-- drop any pump/clutch the computer is holding on
for _, side in ipairs(redstone.getSides()) do redstone.setOutput(side, false) end
for _, m in ipairs({ peripheral.find("electric_motor") }) do m.stop() end
print("KILL: thruster power 0, vector zeroed, redstone + motors off")
