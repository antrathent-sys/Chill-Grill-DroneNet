-- kiosk: the boot for anything a customer holds.
--
-- `provision` writes this onto a customer's pass as its startup.lua, and it
-- is the only startup a pass ever has. So the device has:
--   * no updater and no GitHub token - nothing on it can fetch code, and there
--     is no secret on it worth taking except the customer's own key, which only
--     ever speaks for them;
--   * no shell - Ctrl+T does nothing, and if the program stops for any reason
--     the pass shows OUT OF SERVICE and starts again;
--   * no debug on screen - a boot screen with the name and a filling line, and
--     what went wrong (if anything) written to .crash, for `provision` to show
--     when the pass comes back to the base.
-- Ctrl+R and Ctrl+S cannot be stopped by any program. Both only bring it back
-- here.
--
-- A pass is updated by putting it back in the provisioning drive, never over
-- the air.
--
--   .pass    who it belongs to - the label is set from it on every boot,
--            because the base knows the key by that name
--   .kiosk   which program it runs (hail)
--   .version the commit it was made from, shown small on the boot screen

os.pullEvent = os.pullEventRaw           -- terminate is just another event now

local PASS, PROGRAM, CRASH = ".pass", ".kiosk", ".crash"
local ALLOWED = { hail = true }          -- stations will join this list
local CRASH_MAX = 4096                   -- bytes of history kept

local function readLine(path)
  if not fs.exists(path) then return nil end
  local h = fs.open(path, "r")
  if not h then return nil end
  local s = h.readLine()
  h.close()
  if not s then return nil end
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local D, T, UI
do
  local okD, d = pcall(dofile, "lib/display.lua")
  if okD and type(d) == "table" and d.canvas then D = d end
  local okT, t = pcall(dofile, "lib/tui.lua")
  if okT and type(t) == "table" and t.masthead then T = t end
  local okU, u = pcall(dofile, "lib/hailui.lua")
  if okU and type(u) == "table" and u.boot then UI = u end
end
if T then T.apply(term) end

local function draw(screenName, view)
  local w, h = term.getSize()
  if D and T and UI then
    local c = D.canvas(w, h)
    UI[screenName](T, c, view or {})
    c:flush(term)
  else
    term.setBackgroundColour(colours.black)
    term.clear()
    term.setCursorPos(math.max(1, math.floor(w / 2) - 3), math.floor(h / 2))
    term.write(screenName == "down" and "OUT OF SERVICE" or "SHUTTLE")
  end
end

-- the base knows this pass's key by the owner's name, and hail signs with the
-- label, so the label is put back if anything changed it
local owner = readLine(PASS)
if owner and owner ~= "" and os.getComputerLabel() ~= owner then
  pcall(os.setComputerLabel, owner)
end

local version = readLine(".version")
for i = 1, 10 do
  draw("boot", { frac = i / 10, ver = version })
  sleep(0.08)
end

local prog = readLine(PROGRAM) or "hail"
if not ALLOWED[prog] then prog = "hail" end

-- Run it ourselves rather than through shell.run, so an error comes back here
-- as a value instead of being printed across the customer's screen.
local ok, err
local env = setmetatable({ shell = shell, multishell = multishell }, { __index = _G })
local fn, loadErr = loadfile(prog .. ".lua", nil, env)
if fn then
  ok, err = pcall(fn, "kiosk")
else
  ok, err = false, loadErr
end

-- It should never come back. If it did, keep a note for the base and start
-- again after a moment.
do
  local line = string.format("%s %s: %s\n",
    tostring(os.epoch and os.epoch("utc") or os.clock()), prog,
    ok and "ended" or tostring(err))
  if fs.exists(CRASH) and fs.getSize(CRASH) > CRASH_MAX then fs.delete(CRASH) end
  local h = fs.open(CRASH, "a")
  if h then h.write(line) h.close() end
end

for s = 5, 1, -1 do
  draw("down", { secs = s })
  sleep(1)
end
os.reboot()
