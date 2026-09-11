-- chimes: listen to the sound set.
--
--   chimes              play every chime in order, printing each name
--   chimes docked       play one
--   chimes cruise 4     play one N times (the groove is two bars per play)
--   chimes list         just the names
--
-- Runs the sequences synchronously, so do not run it while flying.

local chime = dofile("lib/chime.lua")
local spk = peripheral.find("speaker")
if not spk then error("no speaker attached to this computer", 0) end
chime.attach(spk)

local what, times = ..., tonumber(select(2, ...)) or 1

if what == "list" then
  for _, name in ipairs(chime.list()) do print("  " .. name) end
  return
end

if what then
  if not chime.sets[what] then
    print("no chime called '" .. what .. "'. try: chimes list")
    return
  end
  for i = 1, times do
    print(what .. (times > 1 and ("  " .. i .. "/" .. times) or ""))
    chime.playNow(what)
    if i < times then sleep(0.05) end
  end
  return
end

local names = chime.list()
print("playing " .. #names .. " chimes - Ctrl+T to stop")
for _, name in ipairs(names) do
  print("  " .. name)
  chime.playNow(name)
  sleep(0.45)
end
print("done")
