-- startup: pull the latest controller files from GitHub on boot, then run
-- this computer's autorun command, if it has one.
-- Fetches each file below from the repo's raw URL, writes it to the root of
-- this computer, and prints what changed. Needs http enabled in the CC config.
--
--   startup autorun console     base computer: bring the wall back after every reboot
--   startup autorun rsio        redstone slave on a drone
--   startup autorun off         stop autorunning
--   startup role                which kind of computer this is
--   startup role <name>         drone, base, pocket, rs, or all: pull only that
--                               role's files (manifest.lua) from now on
--   startup hold <side>         drone: raise this side first thing at every boot,
--                               so the docking connector is powered whenever the
--                               computer is on. Only fly releases it (the undock
--                               step). startup hold off stops it.
--
-- The autorun command is kept in .autorun on this computer. It waits 3 s
-- (press any key to get the shell instead) and restarts the command if it
-- crashes or ends. `fly` is refused: a drone must never take off by itself
-- because a chunk reloaded.
--
-- A customer's program (hail) boots differently: straight into the CINDER
-- boot screen, the update running quietly behind its loading line, then the
-- program - no 3 s wait and no file list. What startup would have printed
-- goes to .startup.log. Ctrl+T is the way to the shell. Running `startup` by
-- hand later is the developer's boot again, output and all.
local REPO   = "antrathent-sys/Chill-Grill-DroneNet"
local BRANCH = "main"
local FILES  = { "fly.lua", "kill.lua", "startup.lua", "probe.lua", "upload.lua", "paste.lua", "preflight.lua",
                 "mixcal.lua",
                 "rsio.lua", "chimes.lua", "docktest.lua", "stickers.lua", "beacon.lua",
                 "lib/chime.lua", "lib/db.lua", "lib/mission.lua", "lib/rs.lua", "lib/deliver.lua",
                 "lib/mixer.lua", "lib/attitude.lua", "lib/link.lua", "lib/pads.lua",
                 "lib/display.lua", "console.lua", "lib/state.lua", "lib/screens.lua", "control.lua",
                 "lib/devices.lua", "basectl.lua", "devices.example.lua",
                 "lib/loader.lua", "station.example.lua",
                 "lib/fleet.lua", "ops.lua", "taxipad.lua", "hail.lua", "lib/hailui.lua", "lib/tui.lua",
                 "lib/ledger.lua", "lib/queue.lua", "tariff.example.lua",
                 "lib/opsui.lua", "provision.lua", "lib/provision.lua", "kiosk.lua",
                 "lib/seclink.lua", "seckey.lua", "radiotest.lua",
                 "ccryptolib/aead.lua", "ccryptolib/chacha20.lua", "ccryptolib/poly1305.lua",
                 "ccryptolib/random.lua", "ccryptolib/blake3.lua", "ccryptolib/config.lua",
                 "ccryptolib/internal/util.lua", "ccryptolib/internal/packing.lua",
                 "ccryptolib/internal/hw.lua" }

-- FILES is only the fallback for a computer with no role when manifest.lua
-- cannot be read. Normally the manifest in the repo decides what to pull.
local AUTORUN_FILE = ".autorun"
local ROLE_FILE = ".role"            -- this computer's role, one word
local INSTALLED_FILE = ".installed"  -- the files startup put here, one per line
local MANIFEST = "manifest.lua"
local HOLD_FILE = ".hold"            -- the side to raise at every boot
local HOLD_SIDES = { top = true, bottom = true, left = true, right = true, front = true, back = true }

-- ------------------------------------------------------------- quiet boot
-- Decided before anything prints: a customer's program, at power-on (not a
-- `startup` typed later), with no arguments.
local QUIET = { hail = true }
local BOOT_LOG = ".startup.log"
local quietCmd = nil
if select("#", ...) == 0 and os.clock() < 10 and fs.exists(AUTORUN_FILE) then
  local f = fs.open(AUTORUN_FILE, "r")
  local c = f and f.readAll() or ""
  if f then f.close() end
  c = c:gsub("^%s+", ""):gsub("%s+$", "")
  if QUIET[c:match("^(%S+)") or ""] then quietCmd = c end
end

-- Everything below prints through this. On a quiet boot it writes the log.
local print = print
local bootLog = nil
if quietCmd then
  if fs.exists(BOOT_LOG) then fs.delete(BOOT_LOG) end
  bootLog = fs.open(BOOT_LOG, "w")
  print = function(...)
    local t = {}
    for i = 1, select("#", ...) do t[#t + 1] = tostring((select(i, ...))) end
    if bootLog then
      pcall(bootLog.write, table.concat(t, " ") .. "\n")
      if bootLog.flush then pcall(bootLog.flush) end
    end
  end
end

-- The boot screen, drawn from the libraries already on this computer (the
-- update may replace them; this boot keeps the ones it started with).
-- frac is how far the loading line has filled.
local bootDraw = function() end
if quietCmd then
  local okD, D = pcall(dofile, "lib/display.lua")
  local okT, T = pcall(dofile, "lib/tui.lua")
  local okU, UI = pcall(dofile, "lib/hailui.lua")
  if okD and okT and okU and type(D) == "table" and type(T) == "table"
     and type(UI) == "table" and UI.boot then
    T.apply(term)
    local ver = nil
    if fs.exists(".commit") then
      local f = fs.open(".commit", "r")
      ver = f and f.readLine()
      if f then f.close() end
    end
    bootDraw = function(frac)
      local w, h = term.getSize()
      local c = D.canvas(w, h)
      UI.boot(T, c, { frac = frac, ver = ver })
      c:flush(term)
    end
  else
    bootDraw = function()
      term.setBackgroundColour(colours.black)
      term.clear()
    end
  end
  bootDraw(0)
end

local function isFlight(cmd)
  return cmd == "fly" or cmd:match("^fly%s") ~= nil
end

-- ---------------------------------------------------------- startup autorun
local args = { ... }
if args[1] == "autorun" then
  local cmd = table.concat(args, " ", 2)
  if cmd == "" or cmd == "off" then
    if fs.exists(AUTORUN_FILE) then fs.delete(AUTORUN_FILE) end
    print("autorun off")
  elseif isFlight(cmd) then
    print("refusing: a drone must never take off by itself on boot")
  else
    local f = fs.open(AUTORUN_FILE, "w")
    f.write(cmd)
    f.close()
    print("every boot, after updating, this computer runs: " .. cmd)
    print("(startup autorun off to stop)")
  end
  return
end

local function heldSide()
  if not fs.exists(HOLD_FILE) then return "" end
  local f = fs.open(HOLD_FILE, "r")
  local side = (f.readAll() or ""):gsub("%s+", "")
  f.close()
  return side
end

if args[1] == "hold" then
  local side = args[2] and args[2]:lower()
  if not side then
    local cur = heldSide()
    print("hold: " .. (cur ~= "" and (cur .. " is raised at every boot") or "off"))
    print("startup hold <side> keeps a docking connector powered; startup hold off stops it")
  elseif side == "off" then
    if fs.exists(HOLD_FILE) then fs.delete(HOLD_FILE) end
    print("hold off - nothing is raised at boot (the output stays as it is now)")
  elseif not HOLD_SIDES[side] then
    print("hold: '" .. side .. "' is not a side of this computer (top bottom left right front back)")
  else
    local f = fs.open(HOLD_FILE, "w")
    f.write(side)
    f.close()
    redstone.setOutput(side, true)
    print("hold: " .. side .. " raised now and at every boot - fly undock is what releases it")
  end
  return
end

local roleRequest = nil
if args[1] == "role" then
  if not args[2] then
    local role = ""
    if fs.exists(ROLE_FILE) then
      local f = fs.open(ROLE_FILE, "r")
      role = (f.readAll() or ""):gsub("%s+", "")
      f.close()
    end
    print("role: " .. (role ~= "" and role or "none - this computer pulls every file"))
    print("startup role <drone|base|pad|pocket|admin|rs|all> to change it")
    return
  end
  roleRequest = args[2]:lower()
end

-- The dock hold, first thing on every boot: a reboot drops every output, so
-- the connector's side goes straight back up before anything slower (the
-- update) runs. The connector lets go on its power going OFF, and only fly's
-- undock step does that on purpose.
if not roleRequest then
  local side = heldSide()
  if HOLD_SIDES[side] and redstone then
    redstone.setOutput(side, true)
    print("hold: " .. side .. " high - docking connector powered (fly undock releases it)")
  end
end

-- Thrusters off at boot. A computer that stops mid-flight comes back with
-- the thrusters still at their last command and nothing driving them: on
-- 2026-09-19 the server stopped the drone's computer 3.6 s into a return
-- leg and the craft flew on, inverted, into the sea under power. Nothing
-- legitimately has thrust on while this computer is booting (fly never
-- autoruns), so every vector thruster is zeroed before anything slower runs.
-- Peripheral calls only - the dock hold above is redstone and stays up.
if not roleRequest and peripheral and peripheral.find then
  local thrs = { peripheral.find("vector_thruster") }
  for _, thr in ipairs(thrs) do
    pcall(thr.setPowerNormalized, 0)
    pcall(thr.setVector, 0, 0)
  end
  if #thrs > 0 then
    print("boot: " .. #thrs .. " thruster(s) zeroed - nothing flies until a flight command")
  end
end

-- Private repo? Put a GitHub token (fine-grained, read-only Contents scope on
-- this repo only) in a file called .ghtoken on THIS computer. It is read here
-- and sent as an Authorization header; it never lives in the repo.
local TOKEN_FILE = ".ghtoken"
local HEADERS = nil
if fs.exists(TOKEN_FILE) then
  local f = fs.open(TOKEN_FILE, "r")
  local tok = (f.readAll() or ""):gsub("%s+", "")
  f.close()
  if #tok > 0 then HEADERS = { Authorization = "token " .. tok } end
end

local function readLocal(name)
  if not fs.exists(name) then return nil end
  local f = fs.open(name, "r")
  local s = f.readAll()
  f.close()
  return s
end

-- raw.githubusercontent.com caches a branch path for 5 minutes and ignores
-- query strings, so a fetch by branch name within 5 minutes of a push returns
-- the PREVIOUS version. That bit this project repeatedly. A fetch by commit
-- SHA is immutable, so it is always correct however it is cached. One API
-- call finds the SHA; if that fails we fall back to the branch and say so.
local function latestSha()
  local url = string.format("https://api.github.com/repos/%s/commits/%s", REPO, BRANCH)
  local res = http.get(url, HEADERS)
  if not res then return nil end
  local body = res.readAll()
  res.close()
  local ok, t = pcall(textutils.unserializeJSON, body)
  if ok and type(t) == "table" and type(t.sha) == "string" and #t.sha == 40 then
    return t.sha
  end
  return nil
end

local function fetch(ref, name)
  local url = string.format("https://raw.githubusercontent.com/%s/%s/%s", REPO, ref, name)
  local res, err = http.get(url, HEADERS)
  if not res then return nil, err end
  local body = res.readAll()
  res.close()
  return body
end

-- Space. A flight writes ~230 bytes a row at 10 Hz, so a three minute flight
-- is a 400 KB flightlog, and the repo itself is another 300 KB. On a computer
-- with the default 1 MB that is survivable; on a server that has turned the
-- limit down it is not, and the failure looks like "Out of space" halfway
-- through an update with the tree left half old and half new.
-- Never calibration: mixmap.csv (the thruster corner map mixcal writes) used
-- to be on this list, and on a server with a small disk limit every boot
-- deleted it - the craft cannot fly without it.
local DISPOSABLE = { "flightlog", "probe.txt", "preflight.txt", "probelog.csv", "stickers.txt" }

-- A flightlog is evidence, and a 4,000-block flight's is 700 KB: short of
-- space it is THINNED to flightlog.thin (every 4th row plus every phase
-- change, ~50 KB, what upload thin makes) and only then removed. Alex lost
-- two logs to the plain delete on 2026-09-18.
local function freeSpace() return (fs.getFreeSpace and fs.getFreeSpace("/")) or math.huge end

-- Every 4th row when there is room for that, 1 row in N when there is not:
-- the copy is written while the full log is still on the disk, and on
-- 2026-09-20 a 500 KB log on a disk with 65 KB free died at this write with
-- "Out of space" and took the whole update with it. With no room at all the
-- log goes unthinned - the computer working beats the evidence.
local function thinLog(src, dst)
  local h = fs.open(src, "r")
  if not h then return false end
  if fs.exists(dst) then fs.delete(dst) end
  local room = freeSpace() - 8 * 1024
  local size = (fs.getSize and fs.getSize(src)) or 0
  if room <= 0 then h.close() return false end
  local every = 4
  if size / 4 > room then every = math.ceil(size / room) end
  local out, lastPhase, i = { h.readLine() }, nil, 0
  if not out[1] then h.close() return false end
  while true do
    local line = h.readLine()
    if not line then break end
    i = i + 1
    local phase = line:match("^[^,]*,([^,]*)")
    if i % every == 0 or phase ~= lastPhase then out[#out + 1] = line end
    lastPhase = phase
  end
  h.close()
  local w = fs.open(dst, "w")
  if not w then return false end
  local okW = pcall(w.write, table.concat(out, "\n") .. "\n")
  pcall(w.close)
  if not okW then
    if fs.exists(dst) then fs.delete(dst) end
    return false
  end
  return true, every
end

local function reclaim(needed)
  local freed = {}
  for _, name in ipairs(DISPOSABLE) do
    if freeSpace() >= needed then break end
    if fs.exists(name) then
      local sz = fs.getSize(name)
      local kept = ""
      if name == "flightlog" then
        local ok, every = thinLog(name, "flightlog.thin")
        if ok then kept = string.format(" -> flightlog.thin kept (1 row in %d)", every) end
      end
      fs.delete(name)
      freed[#freed + 1] = string.format("%s (%.0fKB)%s", name, sz / 1024, kept)
    end
  end
  if #freed > 0 then print("reclaimed: " .. table.concat(freed, ", ")) end
  return freeSpace()
end

-- The manifest runs with no environment at all: it can only list files.
local function parseManifest(text)
  if type(text) ~= "string" or text == "" then return nil end
  local chunk
  if setfenv then
    chunk = (loadstring or load)(text, "manifest")
    if chunk then setfenv(chunk, {}) end
  else
    chunk = load(text, "manifest", "t", {})
  end
  if not chunk then return nil end
  local ok, t = pcall(chunk)
  if not ok or type(t) ~= "table" or type(t.common) ~= "table" then return nil end
  for k, list in pairs(t) do
    if type(k) ~= "string" or type(list) ~= "table" then return nil end
    for _, name in ipairs(list) do
      if type(name) ~= "string" or name:sub(1, 1) == "." or name:find("..", 1, true) then return nil end
    end
  end
  return t
end

local function rolesOf(man)
  local keys = {}
  for k in pairs(man) do
    if k ~= "common" then keys[#keys + 1] = k end
  end
  table.sort(keys)
  return keys
end

-- common, then the named roles' files (every role when roles is nil), once each
local function filesFor(man, roles)
  local out, seen = {}, {}
  local function add(list)
    for _, name in ipairs(list or {}) do
      if not seen[name] then seen[name], out[#out + 1] = true, name end
    end
  end
  add(man.common)
  for _, k in ipairs(roles or rolesOf(man)) do add(man[k]) end
  return out
end

local function readList(name)
  local s = readLocal(name)
  if not s then return nil end
  local t = {}
  for line in s:gmatch("[^\r\n]+") do t[#t + 1] = line end
  return t
end

local function writeText(name, text)
  if fs.exists(name) then fs.delete(name) end
  local f = fs.open(name, "w")
  f.write(text)
  f.close()
end

local function update(roleRequest)
  -- checked before anything touches http: with the API disabled this used to
  -- crash on the commit lookup, and then nothing after it (autorun) ran
  if not http then
    print("startup: http API disabled - skipping update")
    if roleRequest then print("startup: role not changed - it needs http to fetch its file list") end
    return
  end

  local ref = latestSha()
  bootDraw(0.1)
  if ref then
    print("pulling commit " .. ref:sub(1, 7))
  else
    ref = BRANCH
    print("WARNING: could not resolve latest commit, pulling '" .. BRANCH .. "' (may be up to 5 min stale)")
  end

  -- Which files: the manifest decides, by this computer's role.
  local man = parseManifest((fetch(ref, MANIFEST)))
  local role = roleRequest or (readLocal(ROLE_FILE) or ""):gsub("%s+", "")
  local wanted
  if man then
    if role == "" or role == "all" then
      wanted = filesFor(man)
    elseif role ~= "common" and man[role] then
      wanted = filesFor(man, { role })
    else
      print(string.format("startup: no role '%s' (roles: %s, all)", role, table.concat(rolesOf(man), ", ")))
      return
    end
  elseif roleRequest then
    print("startup: role not changed - could not read " .. MANIFEST .. " from the repo")
    return
  elseif role ~= "" and role ~= "all" then
    -- a role but no manifest: refresh what is already here, remove nothing
    print("WARNING: could not read " .. MANIFEST .. " - updating only the files already installed")
    wanted = readList(INSTALLED_FILE)
    if not wanted then return end
  else
    wanted = FILES
  end
  if roleRequest then
    if roleRequest == "all" then
      if fs.exists(ROLE_FILE) then fs.delete(ROLE_FILE) end
    else
      writeText(ROLE_FILE, roleRequest)
    end
  end
  print(string.format("role: %s - %d files", (role == "" or role == "all") and "all" or role, #wanted))

  local free = freeSpace()
  if free ~= math.huge then
    print(string.format("space: %.0fKB free", free / 1024))
    if free < 400 * 1024 then
      -- these are all either uploaded to the repo already or regenerable
      free = reclaim(400 * 1024)
      print(string.format("space: %.0fKB free after tidying", free / 1024))
    end
  end

  local updated, unchanged, failed = {}, {}, {}
  for i, name in ipairs(wanted) do
    bootDraw(0.1 + 0.85 * i / math.max(1, #wanted))
    local body, err = fetch(ref, name)
    if not body or #body == 0 then
      failed[#failed + 1] = name .. " (" .. tostring(err or "empty") .. ")"
    elseif body == readLocal(name) then
      unchanged[#unchanged + 1] = name
    else
      -- files under lib/ need their directory to exist first
      local dir = name:match("^(.*)/[^/]+$")
      if dir and not fs.exists(dir) then fs.makeDir(dir) end
      -- Delete first: writing over a file that is still taking up room can run
      -- the disk out on the very file we are replacing. And say which file it
      -- was, rather than dying on an anonymous line number.
      if fs.exists(name) then fs.delete(name) end
      if freeSpace() < #body then reclaim(#body + 8192) end
      local ok, werr = pcall(function()
        local f = fs.open(name, "w")
        f.write(body)
        f.close()
      end)
      if ok then
        updated[#updated + 1] = name
      else
        failed[#failed + 1] = string.format("%s (%s, %.0fKB free, needs %.0fKB)",
          name, tostring(werr), freeSpace() / 1024, #body / 1024)
      end
    end
  end

  -- This craft's tuning lives in the repo as tunes/<name>.lua (the name its
  -- telemetry uses: the label, else drone-<id>) and is installed as tune.lua,
  -- which fly loads over CFG. A tune.lua edited by hand on the drone went
  -- missing on 2026-09-19 and the craft flew its defaults for three hours
  -- without a word. No file in the repo: a local tune.lua is left alone.
  do
    local me = (os.getComputerLabel and os.getComputerLabel())
               or ("drone-" .. tostring(os.getComputerID and os.getComputerID() or "?"))
    local tb = fetch(ref, "tunes/" .. me .. ".lua")
    if tb and tb:match("return%s*{") then
      if tb ~= readLocal("tune.lua") then
        writeText("tune.lua", tb)
        updated[#updated + 1] = "tune.lua (tunes/" .. me .. ".lua)"
      else
        unchanged[#unchanged + 1] = "tune.lua"
      end
    else
      print("tune:      none in the repo for " .. me .. (fs.exists("tune.lua") and " - keeping this computer's tune.lua" or ""))
    end
  end

  if #updated > 0   then print("updated:   " .. table.concat(updated, ", ")) end
  if #unchanged > 0 then print("unchanged: " .. table.concat(unchanged, ", ")) end
  if #failed > 0    then print("FAILED:    " .. table.concat(failed, ", ")) end
  if #updated == 0 and #failed == 0 then print("startup: all files current") end
  -- Which commit this computer is now running, when it is a real commit and
  -- nothing failed: provision stamps it on every pass it makes, and the
  -- pass's boot screen shows it, so a pass in a customer's hand says which
  -- code it carries.
  if ref ~= BRANCH and #failed == 0 then writeText(".commit", ref:sub(1, 7) .. "\n") end

  -- Remove only what startup installed and this role no longer wants. A
  -- computer that has never recorded what it installed may lose any file the
  -- manifest names - never keys, logs, pads.lua or anything else of its own.
  if man then
    local keep = {}
    for _, name in ipairs(wanted) do keep[name] = true end
    local removed = {}
    for _, name in ipairs(readList(INSTALLED_FILE) or filesFor(man)) do
      if not keep[name] and name ~= "startup.lua" and name:sub(1, 1) ~= "." and fs.exists(name) then
        fs.delete(name)
        removed[#removed + 1] = name
      end
    end
    if #removed > 0 then print("removed:   " .. table.concat(removed, ", ")) end
    local have = {}
    for _, name in ipairs(wanted) do
      if fs.exists(name) then have[#have + 1] = name end
    end
    writeText(INSTALLED_FILE, table.concat(have, "\n") .. "\n")
  end
end

-- An update that throws must not stop the autorun: a base wall that stays
-- dark because GitHub hiccuped is worse than one running yesterday's code.
local okU, errU = pcall(update, roleRequest)
if not okU then print("startup: update failed - " .. tostring(errU)) end
if roleRequest then return end

-- ------------------------------------------------------ quiet boot: go
-- Straight into the program as a customer sees it (`hail kiosk`). A crash
-- is noted in the log and it starts again behind the boot screen; Ctrl+T
-- is the developer's way out, to a shell in ordinary colours.
if quietCmd then
  bootDraw(1)
  if bootLog then pcall(bootLog.close) bootLog = nil end
  local prog = quietCmd:match("^(%S+)")
  while true do
    local env = setmetatable({ shell = shell, multishell = multishell }, { __index = _G })
    local fn, lerr = loadfile(prog .. ".lua", nil, env)
    local ok, err
    if fn then ok, err = pcall(fn, "kiosk") else ok, err = false, lerr end
    if not ok and tostring(err) == "Terminated" then
      for i = 0, 15 do
        pcall(term.setPaletteColour, 2 ^ i, term.nativePaletteColour(2 ^ i))
      end
      term.setBackgroundColour(colours.black)
      term.setTextColour(colours.white)
      term.clear()
      term.setCursorPos(1, 1)
      _G.print(prog .. " stopped - `startup` starts it again")
      return
    end
    local h = fs.open(BOOT_LOG, "a")
    if h then
      h.write(prog .. (ok and " ended" or (" stopped: " .. tostring(err))) .. " - restarting\n")
      h.close()
    end
    bootDraw(1)
    sleep(2)
  end
end

-- ---------------------------------------------------------------- autorun
local cmd = readLocal(AUTORUN_FILE)
cmd = cmd and cmd:gsub("^%s+", ""):gsub("%s+$", "") or ""
if cmd == "" then return end
if isFlight(cmd) then
  print("autorun: refusing '" .. cmd .. "' - flights are never started on boot")
  return
end

while true do
  print("autorun: " .. cmd .. " in 3 s - press any key for the shell")
  local skipped = false
  parallel.waitForAny(
    function() sleep(3) end,
    function() os.pullEvent("key") skipped = true end)
  if skipped then
    print("autorun: skipped - run 'startup' to try again")
    return
  end
  local ok = shell.run(cmd)
  print("autorun: " .. cmd .. (ok and " ended" or " stopped with an error") .. " - restarting")
end
