-- basectl: the base's devices, from this computer's keyboard.
--
--   basectl                      every device and its state, once
--   basectl watch                refresh every second (Ctrl+T stops)
--   basectl <device> <action>    on / off / toggle / open / close for outputs,
--                                open / close for gearshifts,
--                                speed <rpm> / stop for speed controllers
--   basectl find                 every peripheral on this computer, by name and
--                                type, to write devices.lua from
--
-- Devices are listed in devices.lua on this computer: copy devices.example.lua
-- to devices.lua and edit it. The same commands will come from the pocket
-- terminal over the sealed link; this is the local, wired way in.

local DV = dofile("lib/devices.lua")
local args = { ... }

if args[1] == "find" then
  local names = peripheral.getNames()
  table.sort(names)
  for _, n in ipairs(names) do
    print(string.format("%-30s %s", n, table.concat({ peripheral.getType(n) }, "/")))
  end
  if #names == 0 then print("no peripherals - wired modems switched on?") end
  return
end

local list, bad = DV.load("devices.lua", fs)
for _, why in ipairs(bad) do print("devices.lua: " .. why) end
if #list == 0 then
  print("no devices yet: copy devices.example.lua devices.lua, then edit devices.lua")
  print("(basectl find lists the peripheral names here)")
  return
end

local ctx = { P = peripheral, R = redstone, fs = fs }
local bank = DV.bank(list)
DV.restore(bank, ctx, os.clock())

local COLOUR = { ok = colours.lime, info = colours.lightGrey, warn = colours.orange, fault = colours.red }

local function show()
  DV.poll(bank, ctx, os.clock())
  for _, d in ipairs(list) do
    local s = bank.state[d.name]
    write(string.format("%-14s %-11s ", d.name, d.kind))
    if term.isColour() then term.setTextColour(COLOUR[s.level] or colours.white) end
    write(s.text)
    term.setTextColour(colours.white)
    print(s.detail and ("  " .. s.detail) or "")
  end
end

if args[1] == nil then
  show()
elseif args[1] == "watch" then
  while true do
    term.clear()
    term.setCursorPos(1, 1)
    show()
    print("")
    print("refreshing - Ctrl+T stops")
    sleep(1)
  end
else
  local ok, msg = DV.command(bank, ctx, args[1], args[2], args[3], os.clock())
  print(msg)
  if ok then
    sleep(0.5)
    DV.poll(bank, ctx, os.clock())
    local s = bank.state[args[1]:lower()]
    if s then print("now: " .. s.text .. (s.detail and ("  " .. s.detail) or "")) end
  end
end
