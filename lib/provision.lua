--- provision: what goes on a customer's pass, and how it gets there.
--
-- A pass is a pocket computer set up for one customer. It carries the
-- customer's programs, their own key, and kiosk.lua as its startup - nothing
-- else, and in particular no updater and no GitHub token. provision.lua on the
-- base drives this through a disk drive: a pocket computer put in a drive
-- mounts like a disk, so the base can write its files directly.
--
-- Pure: every function takes the fs to use, so it all tests on the desktop.

local P = {}

-- Everything a pass runs. hail and the libraries it and kiosk.lua load, the
-- sealed link and the crypto under it. tools/test_provision.lua checks this
-- list against what the programs actually dofile, and that the base carries
-- every file on it.
P.FILES = {
  "hail.lua",
  "lib/fleet.lua", "lib/seclink.lua", "lib/display.lua", "lib/tui.lua", "lib/hailui.lua",
  "ccryptolib/aead.lua", "ccryptolib/chacha20.lua", "ccryptolib/poly1305.lua",
  "ccryptolib/random.lua", "ccryptolib/blake3.lua", "ccryptolib/config.lua",
  "ccryptolib/internal/util.lua", "ccryptolib/internal/packing.lua",
  "ccryptolib/internal/hw.lua",
}
P.STARTUP = "kiosk.lua"                  -- becomes the pass's startup.lua

-- Found on any of Alex's own machines and never on a pass. A medium with one
-- of these is refused outright: provisioning wipes things, and it must never
-- be pointed at a drone or the base by mistake.
P.DEV_MARKERS = { ".ghtoken", ".fleetkeys", ".dronekey", ".custkeys", ".role", ".installed", ".autorun" }

-- What survives an update that keeps the key: the key and its counter, the
-- owner, and the pass's own usage count and places.
P.KEEP = { [".custkey"] = true, [".custkey.ctr"] = true, [".pass"] = true,
           [".hailstats"] = true, ["places.lua"] = true }
-- A new key keeps only the usage history: an old counter with a new key would
-- be refused as a replay, and the old key is dead.
P.KEEP_REISSUE = { [".hailstats"] = true, ["places.lua"] = true }

local function join(a, b) return (a == "" or a == nil) and b or (a .. "/" .. b) end

local function readLine(fsys, path)
  if not fsys.exists(path) then return nil end
  local h = fsys.open(path, "r")
  if not h then return nil end
  local s = h.readLine()
  h.close()
  if not s then return nil end
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function writeText(fsys, path, text)
  local h = fsys.open(path, "w")
  if not h then return false end
  h.write(text)
  h.close()
  return true
end

--- A Minecraft username: 3 to 16 of letters, digits and underscore. The seat
-- at the till reads the player's name, so the pass is named the same.
function P.validName(name)
  return type(name) == "string" and #name >= 3 and #name <= 16 and name:match("^[%w_]+$") ~= nil
end

--- What is on this medium?
--   { kind = "dev", marker = ".ghtoken" }         one of Alex's machines
--   { kind = "pass", owner = "alex", keyHex = }   a pass we made
--   { kind = "blank" }                             nothing on it
--   { kind = "other", files = { ... } }            somebody's files
function P.inspect(fsys, mount)
  local files = fsys.list(mount) or {}
  table.sort(files)
  for _, m in ipairs(P.DEV_MARKERS) do
    if fsys.exists(join(mount, m)) then return { kind = "dev", marker = m, files = files } end
  end
  if fsys.exists(join(mount, ".pass")) then
    return { kind = "pass", owner = readLine(fsys, join(mount, ".pass")),
             keyHex = readLine(fsys, join(mount, ".custkey")), files = files }
  end
  local real = {}
  for _, f in ipairs(files) do if f ~= ".settings" then real[#real + 1] = f end end
  if #real == 0 then return { kind = "blank", files = files } end
  return { kind = "other", files = real }
end

--- The last few lines of a pass's crash note, or nil.
function P.crashNote(fsys, mount, lines)
  local path = join(mount, ".crash")
  if not fsys.exists(path) then return nil end
  local h = fsys.open(path, "r")
  local text = h and h.readAll() or ""
  if h then h.close() end
  local all = {}
  for line in text:gmatch("[^\n]+") do all[#all + 1] = line end
  local from = math.max(1, #all - (lines or 3) + 1)
  local out = {}
  for i = from, #all do out[#out + 1] = all[i] end
  return #out > 0 and out or nil
end

--- Delete everything at the top of the medium except the names in keep.
function P.wipe(fsys, mount, keep)
  for _, f in ipairs(fsys.list(mount) or {}) do
    if not (keep and keep[f]) then fsys.delete(join(mount, f)) end
  end
end

--- Build or refresh a pass.
--   opts.owner    whose it is (a valid name)
--   opts.keyHex   a NEW key to write, or nil to keep the one already there
--   opts.program  what kiosk.lua runs ("hail")
--   opts.files    what to copy (P.FILES), opts.src the folder they are in
--   opts.version  the commit the base is running, shown on the boot screen
-- Every source is checked before anything is deleted, so a missing file never
-- leaves a half-built pass. Returns true, files copied; or nil and why.
function P.install(fsys, mount, opts)
  local files, src = opts.files or P.FILES, opts.src or ""
  if not P.validName(opts.owner) then return nil, "not a name: " .. tostring(opts.owner) end
  if not opts.keyHex and not fsys.exists(join(mount, ".custkey")) then
    return nil, "no key on the pass and none given"
  end
  for _, f in ipairs(files) do
    if not fsys.exists(join(src, f)) then return nil, "this computer is missing " .. f end
  end
  if not fsys.exists(join(src, P.STARTUP)) then return nil, "this computer is missing " .. P.STARTUP end

  P.wipe(fsys, mount, opts.keyHex and P.KEEP_REISSUE or P.KEEP)
  for _, f in ipairs(files) do
    local dst = join(mount, f)
    local dir = fsys.getDir(dst)
    if dir ~= "" and not fsys.exists(dir) then fsys.makeDir(dir) end
    if fsys.exists(dst) then fsys.delete(dst) end
    fsys.copy(join(src, f), dst)
  end
  fsys.copy(join(src, P.STARTUP), join(mount, "startup.lua"))
  writeText(fsys, join(mount, ".kiosk"), (opts.program or "hail") .. "\n")
  writeText(fsys, join(mount, ".pass"), opts.owner .. "\n")
  if opts.version then writeText(fsys, join(mount, ".version"), opts.version .. "\n") end
  if opts.keyHex then
    writeText(fsys, join(mount, ".custkey"), opts.keyHex .. "\n")
    if fsys.exists(join(mount, ".custkey.ctr")) then fsys.delete(join(mount, ".custkey.ctr")) end
  end
  return true, #files + 1
end

return P
