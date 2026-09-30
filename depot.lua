-- depot: the computer at a dock that works its loading station.
--
--   depot                        wait for loads from the base
--   startup autorun depot        ...from every boot, which is how it should run
--   depot status                 what this depot has and what it is missing: label,
--                                key, radio, and the dock from dock.lua - each
--                                side's relays, storage, feed, the intake, the
--                                printer and the drone's stickers (the station
--                                from station.lua, on a single-bay depot)
--   depot test <action> [side]   fire one action's relay: place assemble lift retract
--   depot probe                  every relay face and inventory on this network,
--                                and `probe fire`/`probe set` to find out which
--                                machine each face works. Run it before there
--                                is a station.lua. Everything it prints is kept
--                                in probe.txt and pushed to this machine's own
--                                folder, machines/<label>/probe.txt, so a whole
--                                session of "fire that, see what moved" can be
--                                read from anywhere. `depot probe clear` starts
--                                a fresh one; with no http or no .ghtoken here,
--                                `paste probe.txt` sends it instead.
--   depot probe map              every relay on in turn: say what moved and
--                                which side, and relays.lua - the map - goes
--                                in this machine's folder
--   depot stock                  what the factory holds, through its Stock
--                                Ticker: Stock Links on the vaults, a wired
--                                modem on the ticker. Read only. Kept in
--                                stock.txt and pushed like the probe log.
--                                `stock send <count> <item> <address>` asks
--                                the ticker for one silo's worth at most, to
--                                test the packagers and the route
--   depot seq                    the two-sided dock (dock.lua): `seq load A`,
--                                `seq unload B`, with you standing in for the
--                                drone - ENT when it has latched, stuck or let go
--   depot screens                which monitor is which; `depot screens demo`
--                                plays every state on them
--   depot print                  a sample invoice on the printer, to prove it:
--                                paper, ink, and the page's name as an item
--
-- Invoices (DELIVERIES.md): a load that is a customer's order (C-0042.1)
-- comes with what its invoice says; once each silo is counted, while it is
-- still a block, this computer prints that silo's page - numbered C-0042-1,
-- with what was actually counted in it - and puts it in the silo, so it rides
-- to the customer with the goods. The printer is station.lua's `printer`
-- (or the first one on the network); `invoice_into` sends a bay's page
-- somewhere other than its silo. Out of paper or ink, the page is skipped
-- and said so: it never holds a delivery up.
--
-- Screens (lib/depotscreens.lua, Alex 2026-09-30): a 3x3 advanced monitor
-- shows the loader and what it is doing, a 2x3 portrait shows the order in
-- hand. Both run at text scale 0.5, beside every load and every `depot seq`
-- job. The squarer one is taken as the 3x3; to say otherwise:
--   set dronenet.depot.hero monitor_1     set dronenet.depot.order monitor_2
--
-- It sleeps with its chunk. A drone docking here brings its chunk loader, the
-- chunk loads, this computer turns itself back on and runs startup - so the
-- drone's arrival is the start (proven 2026-09-22). Awake, it says hello to
-- the base every 10 s, sealed, as depot-<dock>; the base answers with the load
-- to run, if it has one for this dock and its drone is docked here.
--
-- The base decides everything: which drone, what goes where, the cargo
-- ledger, every order to the drone. This computer only works the machines -
-- place, fill, count, assemble, lift, retract (lib/loader.lua, the same code
-- `ops load` runs) - and reports each step, "silos up: have it stick", and
-- what it counted in each silo. It never talks to a drone.
--
-- Its layout is station.lua here (copy station.example.lua; liftoff is the
-- base's, so it is ignored). Its key: on the base `seckey new depot-<dock>`;
-- here `label set depot-<dock>` and `seckey set disk` (kept as .dronekey,
-- like a drone's). <dock> is the dock's place name on the base.
--
-- Stopped part way through a load (a server restart), it does not carry on by
-- itself: a lift that may be up is lowered, every relay face is put at rest,
-- and its next hello tells the base, which calls the load off. Ctrl+T during
-- a load calls it off the same way, lift down.

local SEC = dofile("lib/seclink.lua")
local F = dofile("lib/fleet.lua")
local link = dofile("lib/link.lua")
local LOAD = dofile("lib/loader.lua")
local C = dofile("lib/cargo.lua")
local INVOICE = dofile("lib/invoice.lua")
local NAMES = dofile("lib/names.lua")        -- drone-1 is LAMBDA-001 wherever it is shown
local DISPLAY = dofile("lib/display.lua")

local args = { ... }
local cmd = (args[1] or "run"):lower()
local HELLO_EVERY = 10     -- seconds between hellos while awake
local STICK_WAIT = 20      -- seconds to wait for the base's word that the drone stuck
local STATE = ".depotstate"
-- steps from which the lift may be up
local LIFTED = { lift = true, stick = true, retract = true, liftoff = true }

local id = os.getComputerLabel and os.getComputerLabel()

-- ---------------------------------------------------------------- screens ---
local DV = dofile("lib/depotscreens.lua")
DV.use(dofile("lib/tui.lua"))            -- the fleet's own look
local view = DV.new(DV.nameOf(id))
local SCREENS = {}                      -- role -> { mon, canvas, name }
local SCREEN_ROLES = { "hero", "order" }
local function findScreens()
  SCREENS = {}
  local mons, used = {}, {}
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n) == "monitor" then mons[#mons + 1] = n end
  end
  table.sort(mons)
  for _, role in ipairs(SCREEN_ROLES) do
    local n = settings and settings.get("dronenet.depot." .. role)
    if n and peripheral.isPresent(n) then SCREENS[role], used[n] = { name = n }, true end
  end
  local free = {}
  for _, n in ipairs(mons) do if not used[n] then free[#free + 1] = n end end
  -- the wider shape is the 3x3 (57x38 at 0.5), the other the portrait 2x3
  local function ratio(n)
    local m = peripheral.wrap(n)
    pcall(m.setTextScale, 0.5)
    local w, h = m.getSize()
    return w / h
  end
  table.sort(free, function(a, b) return ratio(a) > ratio(b) end)
  for _, role in ipairs(SCREEN_ROLES) do
    if not SCREENS[role] and #free > 0 then SCREENS[role] = { name = table.remove(free, 1) } end
  end
  for _, s in pairs(SCREENS) do
    s.mon = peripheral.wrap(s.name)
    pcall(s.mon.setTextScale, 0.5)
    DV.applyPalette(s.mon)
    s.canvas = DISPLAY.canvas(s.mon.getSize())
  end
end
local function drawScreens(now)
  for role, s in pairs(SCREENS) do
    local okD = pcall(function()
      local w, h = s.mon.getSize()
      if w ~= s.canvas.w or h ~= s.canvas.h then s.canvas = DISPLAY.canvas(w, h) end
      DV.render(role, s.canvas, view, now)
      s.canvas:flush(s.mon)
    end)
    if not okD then SCREENS[role] = nil end
  end
end
-- beside whatever else runs: redraws, and lets a unit go a while after its job
local SCREEN_EVERY = 0.25
local UNIT_GONE = 45                    -- s after a job before its unit is taken to have left
local function screensLoop()
  if not next(SCREENS) then while true do sleep(3600) end end
  while true do
    local now = os.clock()
    if view.unit and not view.job and view.last and now - view.last.at > UNIT_GONE then DV.left(view) end
    drawScreens(now)
    sleep(SCREEN_EVERY)
  end
end
findScreens()

local function confirm(q)
  write(q .. " [y/N] ")
  local a = read()
  return type(a) == "string" and a:lower():sub(1, 1) == "y"
end

-- ----------------------------------------------------------------- probe ---
-- Before there is a station.lua there is a pile of relays and inventories
-- with names like redstone_relay_3, and no way to tell which side of the dock
-- each one works. This lists them, and fires one face at a time so the
-- machine it moves gives itself away: a silo placed appears as a NEW
-- inventory, a belt shows up as items moving, a detector as a signal coming
-- back. Nothing here knows anything about a station, so it runs first.
local SIDES = { "top", "bottom", "left", "right", "front", "back" }
-- Everything the probe prints is also kept, so a session of "fire this, see
-- what moved" ends up as one file to read rather than a screen that scrolled.
local PROBE_LOG = "probe.txt"
local probeLines = {}
local function psay(s)
  s = tostring(s)
  probeLines[#probeLines + 1] = s
  print(s)
end
-- A file pushed to this machine's own folder in the repo, so it can be read
-- without standing at this computer: the probe log, the stock snapshot.
local function pushFile(file)
  local okM, MACHINE = pcall(dofile, "lib/machine.lua")
  local folder = okM and type(MACHINE) == "table" and MACHINE.folder(id) or nil
  if not folder then
    print(string.format("kept in %s - label this computer to keep it in the repo (label set test-dock)", file))
    return
  end
  local into = folder .. "/" .. file
  if not (fs.exists("upload.lua") and http and shell) then
    print(string.format("kept in %s - `paste %s` to send it (no http or upload.lua here)", file, file))
    return
  end
  print("pushing " .. file .. " to " .. into .. " ...")
  local okU, whyU = pcall(shell.run, "upload", "sync", file, into)
  if not okU then
    print("push failed: " .. tostring(whyU))
    print("`paste " .. file .. "` sends it instead")
  end
end

local function probeSave()
  if #probeLines == 0 then return end
  local h = fs.open(PROBE_LOG, fs.exists(PROBE_LOG) and "a" or "w")
  if not h then print("could not write " .. PROBE_LOG) return end
  h.write(string.format("---- %s  %s ----\n", tostring(id or "depot"),
    os.date and select(2, pcall(os.date, "%m-%d %H:%M")) or tostring(os.clock())))
  for _, line in ipairs(probeLines) do h.write(line .. "\n") end
  h.close()
  probeLines = {}
  pushFile(PROBE_LOG)
end

local function inventoryOf(n)
  local okL, list = pcall(peripheral.call, n, "list")
  if not (okL and type(list) == "table") then return nil end
  local items, kinds = 0, {}
  for _, it in pairs(list) do
    if type(it) == "table" and it.count then
      items = items + it.count
      kinds[it.name or "?"] = (kinds[it.name or "?"] or 0) + it.count
    end
  end
  local okS, size = pcall(peripheral.call, n, "size")
  return { items = items, kinds = kinds, size = okS and tonumber(size) or nil }
end

-- A device the probe has no special knowledge of - a sensor from a mod it
-- has never met: what can be asked of it, and what it answers to every
-- get/is/has question that needs no argument. Those answers are compared
-- like anything else, so a sensor that changes when a silo lands shows up in
-- `probe fire` and the map walk without anyone knowing its API first.
local QUIET = { modem = true, redstone_relay = true, drive = true, monitor = true, speaker = true, printer = true }
local function readDevice(n)
  local okM, ms = pcall(peripheral.getMethods, n)
  if not (okM and type(ms) == "table") then return nil end
  table.sort(ms)
  local vals = {}
  for _, m in ipairs(ms) do
    if m:match("^get%u") or m:match("^is%u") or m:match("^has%u") then
      local okV, v = pcall(peripheral.call, n, m)
      if okV then
        local tv = type(v)
        if tv == "number" or tv == "boolean" or tv == "string" then vals[m] = v
        elseif v == nil then vals[m] = "nil" end
      end
    end
  end
  return { methods = ms, vals = vals }
end

local function snapshot()
  local s = { type = {}, relay = {}, inv = {}, dev = {} }
  for _, n in ipairs(peripheral.getNames()) do
    local t = peripheral.getType(n)
    s.type[n] = t
    if t == "laser_sensor" then
      local okH, hit = pcall(peripheral.call, n, "getClosestHitDistance")
      local okP, pow = pcall(peripheral.call, n, "getPower")
      s.laser = s.laser or {}
      s.laser[n] = { hit = okH and hit or nil, power = okP and pow or nil }
    end
    if t == "redstone_relay" then
      local faces = {}
      for _, side in ipairs(SIDES) do
        local okO, out = pcall(peripheral.call, n, "getOutput", side)
        local okI, inp = pcall(peripheral.call, n, "getAnalogInput", side)
        faces[side] = { out = okO and out and true or false, inp = (okI and tonumber(inp)) or 0 }
      end
      s.relay[n] = faces
    else
      local inv = inventoryOf(n)
      if inv then
        s.inv[n] = inv
      elseif not QUIET[t] then
        s.dev[n] = readDevice(n)
      end
    end
  end
  return s
end

local function itemsLine(inv, wide)
  local names = {}
  for name in pairs(inv.kinds) do names[#names + 1] = name end
  table.sort(names, function(a, b) return inv.kinds[a] > inv.kinds[b] end)
  local parts = {}
  for i, name in ipairs(names) do
    if i > (wide or 2) then parts[#parts + 1] = "+" .. (#names - (wide or 2)) .. " more" break end
    parts[#parts + 1] = inv.kinds[name] .. " " .. (name:gsub("^[%w_]+:", ""))
  end
  return #parts > 0 and table.concat(parts, ", ") or "empty"
end

-- one face: "." off, "O" driven by us, a digit for a signal coming in
local function faceMark(f)
  if f.out then return "O" end
  if f.inp > 0 then return tostring(math.min(9, f.inp)) end
  return "."
end

local function printSnapshot(s)
  local relays, invs, other = {}, {}, {}
  for n, t in pairs(s.type) do
    if s.relay[n] then relays[#relays + 1] = n
    elseif s.inv[n] then invs[#invs + 1] = n
    else other[#other + 1] = n .. " (" .. tostring(t) .. ")" end
  end
  table.sort(relays) table.sort(invs) table.sort(other)
  psay(string.format("%d relay%s, %d inventor%s", #relays, #relays == 1 and "" or "s",
    #invs, #invs == 1 and "y" or "ies"))
  -- full names, however long: "redstone_re" tells nobody which relay this is,
  -- and the whole point of the listing is to write the name into station.lua
  local wide = 4
  for _, n in ipairs(relays) do wide = math.max(wide, #n) end
  psay(string.rep(" ", wide) .. "  top bot lft rgt fnt bck   (O driven, digit = signal in)")
  for _, n in ipairs(relays) do
    local marks = {}
    for _, side in ipairs(SIDES) do marks[#marks + 1] = faceMark(s.relay[n][side]) end
    psay(string.format("%-" .. wide .. "s  %s", n, table.concat(marks, "   ")))
  end
  for _, n in ipairs(invs) do
    local inv = s.inv[n]
    psay(string.format("%s  %s%s", n, inv.size and (inv.size .. " slots, ") or "", itemsLine(inv)))
  end
  for _, n in ipairs(other) do
    local name = n:match("^(%S+)")
    local l = s.laser and s.laser[name]
    local d = s.dev[name]
    if d and not l then
      local said = {}
      local keys = {}
      for k in pairs(d.vals) do keys[#keys + 1] = k end
      table.sort(keys)
      for _, k in ipairs(keys) do said[#said + 1] = k .. "=" .. tostring(d.vals[k]) end
      psay(string.format("  %s  %s", n, #said > 0 and table.concat(said, " ") or ""))
      psay("      methods: " .. table.concat(d.methods, ", "))
    elseif l then
      psay(string.format("  %s  power %s  %s", n, tostring(l.power or "?"),
        l.hit and string.format("beam hitting at %.1f", l.hit) or "no beam"))
    else
      psay("  " .. n)
    end
  end
  local mine = {}
  for _, side in ipairs(SIDES) do
    local okO, out = pcall(redstone.getOutput, side)
    local okI, inp = pcall(redstone.getAnalogInput, side)
    if (okO and out) or (okI and (tonumber(inp) or 0) > 0) then
      mine[#mine + 1] = side .. (okO and out and " driven" or (" in " .. tostring(inp)))
    end
  end
  if #mine > 0 then psay("this computer's own faces: " .. table.concat(mine, ", ")) end
end

-- what changed between two looks: the machine that moved
local function report(before, after)
  local said = false
  local function say(fmt, ...) said = true psay("  " .. string.format(fmt, ...)) end
  for n, inv in pairs(after.inv) do
    local was = before.inv[n]
    if not was then say("NEW inventory %s: %s", n, itemsLine(inv))
    elseif inv.items ~= was.items then say("%s %+d items (%s)", n, inv.items - was.items, itemsLine(inv)) end
  end
  for n in pairs(before.inv) do if not after.inv[n] then say("GONE %s (assembled, or broken)", n) end end
  for n, l in pairs(after.laser or {}) do
    local was = before.laser and before.laser[n]
    if was and (was.power ~= l.power or (was.hit ~= nil) ~= (l.hit ~= nil)) then
      say("%s: power %s -> %s%s", n, tostring(was.power or "?"), tostring(l.power or "?"),
        ((was.hit ~= nil) ~= (l.hit ~= nil)) and (l.hit and ", beam hitting" or ", beam gone") or "")
    end
  end
  for n, d in pairs(after.dev or {}) do
    local was = before.dev and before.dev[n]
    if was and d then
      for k, v in pairs(d.vals) do
        if was.vals[k] ~= nil and was.vals[k] ~= v then say("%s %s %s -> %s", n, k, tostring(was.vals[k]), tostring(v)) end
      end
    end
  end
  for n, t in pairs(after.type) do if not before.type[n] then say("NEW peripheral %s (%s)", n, tostring(t)) end end
  for n in pairs(before.type) do if not after.type[n] then say("GONE peripheral %s", n) end end
  for n, faces in pairs(after.relay) do
    for _, side in ipairs(SIDES) do
      local was = before.relay[n] and before.relay[n][side]
      if was and faces[side].inp ~= was.inp then say("%s:%s signal %d -> %d", n, side, was.inp, faces[side].inp) end
    end
  end
  if not said then psay("  nothing changed that this computer can see") end
end

-- A relay on its own means every face of it, which is how these are wired:
-- one relay per machine, and which face the dust leaves by does not matter.
-- <relay>:<side> picks one face, for the machine that needs two.
local function faceArg(spec)
  spec = tostring(spec or "")
  local relay, side = spec:match("^(.+):(%a+)$")
  if not relay then
    if peripheral.isPresent(spec) then return { relay = spec } end
    relay, side = nil, spec
  end
  local okSide = false
  for _, s in ipairs(SIDES) do if s == side then okSide = true end end
  if not okSide then
    return nil, "name a relay (every face of it), a <relay>:<side>, or a side of this computer"
  end
  if relay and not peripheral.isPresent(relay) then return nil, relay .. " is not on this computer's network" end
  return { relay = relay, side = side }
end

local function drive(face, on)
  if face.relay and not face.side then
    local okAll, whyAll = true, nil
    for _, side in ipairs(SIDES) do
      local ok, why = pcall(peripheral.call, face.relay, "setOutput", side, on)
      if not ok then okAll, whyAll = false, why end
    end
    return okAll, whyAll
  end
  if face.relay then return pcall(peripheral.call, face.relay, "setOutput", face.side, on) end
  return pcall(redstone.setOutput, face.side, on)
end

-- ----------------------------------------------------------------- stock ---
-- What the factory holds, through its Stock Ticker (lib/stock.lua): Stock
-- Links on every storage vault, the ticker on their network, a wired modem on
-- the ticker. Read only, apart from `stock send`, which asks - after a y - for
-- at most one silo of one item, through lib/stock's S.request, the only way
-- anything asks. The snapshot is kept in stock.txt and pushed to this
-- machine's folder.
if cmd == "stock" then
  local STOCK = dofile("lib/stock.lua")
  local ticker = STOCK.findTicker(peripheral.getNames(), function(n)
    local okM, ms = pcall(peripheral.getMethods, n)
    return okM and ms or {}
  end)
  if not ticker then
    print("no Stock Ticker on this network: put a wired modem on it and turn it on,")
    print("with Stock Links on the vaults tuned to the ticker's network")
    return
  end
  local entries, why = STOCK.read(ticker, peripheral.call)
  if not entries then print(why) return end
  if (args[2] or ""):lower() == "send" then
    -- One request, by hand: the test of the ticker, the packagers and the
    -- package route before the loader relies on them. At most one silo of
    -- the item (59 stacks), and it asks first.
    local count, word, address = tonumber(args[3]), args[4], args[5]
    if not (count and word and address) then
      print("depot stock send <count> <item> <address>    e.g. depot stock send 3776 cobblestone cinder-A")
      return
    end
    local item
    for _, e in ipairs(entries) do
      if e.name == word or e.name:match(":(.+)$") == word then item = item or e end
    end
    if not item then print(word .. ": the factory holds none of that") return end
    local cap = 59 * (item.stack or 64)
    print(string.format("send %d %s to %s? the factory holds %d", count, item.label, address, item.count))
    if not confirm("send it") then print("nothing sent") return end
    local sent, whyS = STOCK.request(ticker, peripheral.call, address, item.name, count, cap)
    if not sent then print("not sent: " .. tostring(whyS)) return end
    print(string.format("the ticker is sending %d - watch the vault at %s fill", sent, address))
    return
  end
  local total = 0
  for _, e in ipairs(entries) do total = total + e.count end
  local okT, stamp = pcall(os.date, "%m-%d %H:%M")
  local lines = { string.format("%s stock via %s, %s: %d kinds, %d items", tostring(id or "depot"), ticker,
    okT and tostring(stamp) or tostring(os.clock()), #entries, total) }
  for _, e in ipairs(entries) do
    lines[#lines + 1] = string.format("%10d  %-28s %s", e.count, e.label:sub(1, 28), e.name)
  end
  -- the loader's silos are stock too, and every payload burns some
  local DS = dofile("lib/dockseq.lua")
  local silos = "silos: NONE in stock - the loader cannot make a payload"
  for _, e in ipairs(entries) do
    if e.name == DS.SILO_ITEM then
      local p = math.floor(e.count / DS.SILO_BLOCKS)
      silos = string.format("silos: %d blocks - %d payloads, %d dual flights", e.count, p, math.floor(p / 2))
    end
  end
  table.insert(lines, 2, silos)
  for _, line in ipairs(lines) do print(line) end
  local h = fs.open("stock.txt", "w")
  if h then h.write(table.concat(lines, "\n") .. "\n") h.close() end
  pushFile("stock.txt")
  return
end

if cmd == "probe" then
  local sub = (args[2] or ""):lower()
  if sub == "clear" then
    if fs.exists(PROBE_LOG) then fs.delete(PROBE_LOG) end
    print(PROBE_LOG .. " started fresh")
    return
  end
  if sub == "" then
    printSnapshot(snapshot())
    probeSave()
    print("")
    print("depot probe watch [secs]        keep looking, to see a machine work")
    print("depot probe fire <relay> [secs]          pulse a relay, say what moved")
    print("depot probe set <relay> on|off           hold a relay on (a toggle)")
    print("  a relay on its own drives every face of it; <relay>:<side> picks one")
    print("depot probe map [secs]          walk every relay: say what moved, get relays.lua")
    print("depot probe clear               start " .. PROBE_LOG .. " again")
    return
  end
  if sub == "watch" then
    local untilT = os.clock() + (tonumber(args[3]) or 60)
    while os.clock() < untilT do
      term.clear()
      term.setCursorPos(1, 1)
      printSnapshot(snapshot())
      print("")
      print("watching - Ctrl+T stops")
      sleep(0.5)
    end
    return
  end
  if sub == "map" then
    -- The walk: every relay on in turn, and the person watching the dock
    -- says what moved. At the end, relays.lua - which relay works which
    -- machine on which side, and what ON means for it - goes in this
    -- machine's folder, and station.lua is written from that.
    local relays = {}
    for _, n in ipairs(peripheral.getNames()) do
      if peripheral.getType(n) == "redstone_relay" then relays[#relays + 1] = n end
    end
    table.sort(relays, function(a, b)
      local na, nb = tonumber(a:match("(%d+)$")), tonumber(b:match("(%d+)$"))
      if na and nb and na ~= nb then return na < nb end
      return a < b
    end)
    if #relays == 0 then print("no redstone relays on this computer's network") return end
    local hold = tonumber(args[3]) or 3
    print(string.format("%d relays. Each goes ON for %gs, then OFF, one at a time.", #relays, hold))
    print("Stand where you can see both sides. Machines WILL move.")
    if not confirm("start?") then print("nothing changed") return end

    local DEVICES = { p = "place", a = "assemble", b = "belt", u = "pusher", n = "nothing" }
    local ON_MEANS = {
      place = "ON [p]laces a silo, or [r]emoves one?",
      belt = "ON the belt [f]ills the cargo, or [e]mpties it into storage?",
      pusher = "ON the pusher goes [u]p, or [d]own?",
    }
    local ON_WORD = { p = "places", r = "removes", f = "fills", e = "empties", u = "up", d = "down" }
    local function ask(q)
      write(q .. " ")
      local a = read()
      return type(a) == "string" and a:gsub("^%s+", ""):gsub("%s+$", "") or ""
    end
    local map = {}
    for i, name in ipairs(relays) do
      print("")
      local before = snapshot()
      drive({ relay = name }, true)
      psay(string.format("[%d/%d] %s is ON", i, #relays, name))
      sleep(hold)
      report(before, snapshot())
      local e = { relay = name }
      local what = ask("what moved?  [p]lacement [a]ssembler [b]elt p[u]sher [n]othing, or type it:")
      e.device = DEVICES[what:lower()] or (what ~= "" and what or "nothing")
      if e.device ~= "nothing" and DEVICES[what:lower()] then
        local side = ask("which side, A or B?"):upper()
        e.side = (side == "A" or side == "B") and side or nil
        if ON_MEANS[e.device] then
          local on = ask(ON_MEANS[e.device]):lower():sub(1, 1)
          e.on = ON_WORD[on]
        end
      end
      drive({ relay = name }, false)
      sleep(1)
      local line = string.format("%-18s %-9s %s%s", name, e.device, e.side and ("side " .. e.side) or "",
        e.on and ("  ON " .. e.on) or "")
      psay("  = " .. line)
      map[#map + 1] = e
    end

    -- what it adds up to, and what is missing
    psay("")
    psay("the map:")
    local have = {}
    for _, e in ipairs(map) do
      if e.side then have[e.side .. ":" .. e.device] = e.relay end
      psay(string.format("  %-18s %-9s %s%s", e.relay, e.device, e.side or "-", e.on and ("  ON " .. e.on) or ""))
    end
    local missing = {}
    for _, side in ipairs({ "A", "B" }) do
      for _, dev in ipairs({ "place", "assemble", "belt", "pusher" }) do
        if not have[side .. ":" .. dev] then missing[#missing + 1] = side .. " " .. dev end
      end
    end
    psay(#missing == 0 and "every device found on both sides"
      or ("not found: " .. table.concat(missing, ", ")))

    -- relays.lua: the map as data, in this machine's own folder
    local out = { string.format("-- relay map for %s, from `depot probe map` %s", tostring(id or "this dock"),
      os.date and select(2, pcall(os.date, "%Y-%m-%d %H:%M")) or ""),
      "-- device: place | assemble | belt | pusher; on: what ON does", "return {" }
    for _, e in ipairs(map) do
      out[#out + 1] = string.format("  { relay = %q, device = %q%s%s },", e.relay, e.device,
        e.side and string.format(", side = %q", e.side) or "", e.on and string.format(", on = %q", e.on) or "")
    end
    out[#out + 1] = "}"
    local h = fs.open("relays.lua", "w")
    if h then h.write(table.concat(out, "\n") .. "\n") h.close() end
    probeSave()
    if fs.exists("upload.lua") and http and shell then
      local okM, MACHINE = pcall(dofile, "lib/machine.lua")
      local folder = okM and type(MACHINE) == "table" and MACHINE.folder(id) or nil
      if folder then pcall(shell.run, "upload", "sync", "relays.lua", folder .. "/relays.lua") end
    end
    print("written to relays.lua")
    return
  end
  if sub == "fire" or sub == "set" then
    local face, whyF = faceArg(args[3])
    if not face then print(whyF) print("depot probe " .. sub .. " <relay>:<side> ...") return end
    local where = face.relay and (face.relay .. (face.side and (":" .. face.side) or " (every face)"))
      or ("this computer's " .. face.side)
    if sub == "set" then
      local on = (args[4] or "on"):lower() ~= "off"
      if not confirm(string.format("hold %s %s? the machines move", where, on and "ON" or "OFF")) then
        print("nothing changed")
        return
      end
      local before = snapshot()
      local okD, whyD = drive(face, on)
      if not okD then print("could not drive it: " .. tostring(whyD)) return end
      sleep(1.5)
      psay(string.format("set %s %s", where, on and "ON" or "OFF"))
      report(before, snapshot())
      probeSave()
      return
    end
    local secs = tonumber(args[4]) or 2
    if not confirm(string.format("pulse %s for %gs? the machines move", where, secs)) then
      print("nothing changed")
      return
    end
    local before = snapshot()
    local okD, whyD = drive(face, true)
    if not okD then print("could not drive it: " .. tostring(whyD)) return end
    sleep(secs)
    drive(face, false)
    sleep(1)
    psay(string.format("pulsed %s for %gs", where, secs))
    report(before, snapshot())
    probeSave()
    return
  end
  print("depot probe [watch [secs] | fire <relay>:<side> [secs] | set <relay>:<side> on|off]")
  return
end

-- ------------------------------------------------------------------ seq ---
-- The two-sided dock (lib/dockseq.lua, laid out in dock.lua): load and unload
-- one side, run here with a person standing in for the drone - ENT when it
-- has latched, stuck or let go. That is how the machines are proven before
-- the base drives them.
-- ---------------------------------------------------------------- printer ---
local PAGE_ITEM = "computercraft:printed_page"
local function printerName(pref)
  if pref and peripheral.isPresent(pref) then return pref end
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n) == "printer" then return n end
  end
  return nil
end
-- one page: title (its name as an item) and up to 21 lines of 25
local function printPage(name, title, lines)
  local function pc(m, ...) return pcall(peripheral.call, name, m, ...) end
  local okP, paper = pc("getPaperLevel")
  if okP and (paper or 0) < 1 then return false, "no paper" end
  local okI, ink = pc("getInkLevel")
  if okI and (ink or 0) < 1 then return false, "no ink" end
  local okN, started = pc("newPage")
  if not (okN and started) then return false, "could not start a page (is its tray full?)" end
  pc("setPageTitle", title)
  for i, l in ipairs(lines) do
    pc("setCursorPos", 1, i)
    pc("write", l)
  end
  local okE, ended = pc("endPage")
  if not (okE and ended) then return false, "could not finish the page" end
  return true
end
-- the printed page from the printer's tray into an inventory
local function takePage(name, into)
  local okL, list = pcall(peripheral.call, name, "list")
  if not (okL and type(list) == "table") then return false, "the printer's tray cannot be read" end
  for slot, it in pairs(list) do
    if it.name == PAGE_ITEM then
      local okM, n = pcall(peripheral.call, name, "pushItems", into, slot, 1)
      if okM and n == 1 then return true end
      return false, "could not put it in " .. into .. (okM and "" or (": " .. tostring(n)))
    end
  end
  return false, "no page in the printer's tray"
end
if cmd == "print" then
  -- a sample invoice, to prove the printer before a customer's goods depend on it
  local name = printerName()
  if not name then print("no printer on this network (a wired modem on it, switched on?)") return end
  local okP, paper = pcall(peripheral.call, name, "getPaperLevel")
  local okI, ink = pcall(peripheral.call, name, "getInkLevel")
  print(string.format("printer %s: paper %s, ink %s", name, okP and tostring(paper) or "?", okI and tostring(ink) or "?"))
  local inv = { order = "C-0000", shipment = 1, shipments = 1, date = "TEST", who = "TEST PAGE", x = 0, y = 0, z = 0,
                item = "minecraft:cobblestone", ordered = 64, before = 0, this = 64, total = 0, paid = 0 }
  local title, lines = INVOICE.page(inv)
  local ok, why = printPage(name, title, lines)
  if not ok then print("not printed: " .. tostring(why)) return end
  local okL, list = pcall(peripheral.call, name, "list")
  local found
  for slot, it in pairs(okL and list or {}) do
    if it.name == PAGE_ITEM then
      local okD, d = pcall(peripheral.call, name, "getItemDetail", slot)
      found = string.format("slot %d, named \"%s\"", slot, okD and d and tostring(d.displayName) or "?")
    end
  end
  print("printed " .. title .. (found and (" - in the tray at " .. found) or " - but the tray cannot be read"))
  print("if that name reads back as " .. title .. ", invoices can be told apart in any chest")
  return
end

if cmd == "screens" then
  if not next(SCREENS) then print("no monitors on this computer's network (wired modems switched on?)") return end
  for role, s in pairs(SCREENS) do
    local w, h = s.mon.getSize()
    print(string.format("%-6s %-12s %dx%d", role:upper(), s.name, w, h))
  end
  print("to change one:  set dronenet.depot.<hero|order> <name>")
  if (args[2] or ""):lower() ~= "demo" then return end
  print("demo - every state in turn. Q stops it.")
  local t0 = os.clock()
  parallel.waitForAny(function()
    while true do
      local t = os.clock() - t0
      view = DV.demo(t, DV.nameOf(id))
      drawScreens(t)
      sleep(SCREEN_EVERY)
    end
  end, function()
    while true do
      local _, ch = os.pullEvent("char")
      if tostring(ch):lower() == "q" then return end
    end
  end)
  view = DV.new(DV.nameOf(id))
  drawScreens(os.clock())
  return
end

-- ------------------------------------------------------ the two-sided dock ---
-- dock.lua (lib/dockseq.lua) and what this computer can see of it: which side
-- has a silo waiting, what each side's storage and feed hold, what its sensor
-- sees. `depot seq` drives it by hand; `depot` runs it for the base.
local DS = dofile("lib/dockseq.lua")
local function dockCfg()
  if not fs.exists("dock.lua") then
    return nil, "no dock.lua here - it lives in this machine's folder in the repo (machines/"
      .. tostring(id) .. "/dock.lua); run startup to pull it"
  end
  local okD, raw = pcall(dofile, "dock.lua")
  local cfg, whyD = DS.check(okD and raw or nil)
  if not cfg then return nil, "dock.lua: " .. tostring(okD and whyD or raw) end
  return cfg
end
local function dockKit(cfg)
  -- whether each side has an empty silo waiting: nothing can see one once it
  -- is assembled, so this computer remembers
  local STATEF = ".dockstate"
  local function readSilos()
    local t = { A = "none", B = "none" }
    if fs.exists(STATEF) then
      local h = fs.open(STATEF, "r")
      for side, st in ((h and h.readAll()) or ""):gmatch("(%u)=(%a+)") do t[side] = st end
      if h then h.close() end
    end
    return t
  end
  local silos = readSilos()
  local function silo(side, st)
    if st then
      silos[side] = st
      local h = fs.open(STATEF, "w")
      if h then h.write(string.format("A=%s\nB=%s\n", silos.A, silos.B)) h.close() end
    end
    return silos[side] or "none"
  end
  -- items in a side's storage (the dock's shared list when the side has none
  -- of its own); nil when there is none to count, or it cannot be read.
  -- Up here, before the status line and the jobs that both use it.
  local function storageCount(sd)
    local list = (sd and cfg.sides[sd] and cfg.sides[sd].storage) or cfg.storage
    if #list == 0 then return nil end
    local n = 0
    for _, inv in ipairs(list) do
      local okL, items = pcall(peripheral.call, inv, "list")
      if not (okL and type(items) == "table") then return nil end
      for _, it in pairs(items) do n = n + (it.count or 0) end
    end
    return n
  end
  -- silo blocks in a side's feed, the inventory its placer draws from; nil
  -- when dock.lua names none for the side, or it cannot be read
  local function feedCount(sd)
    local list = sd and cfg.sides[sd] and cfg.sides[sd].feed
    if not list then return nil end
    local n = 0
    for _, inv in ipairs(list) do
      local okL, items = pcall(peripheral.call, inv, "list")
      if not (okL and type(items) == "table") then return nil end
      for _, it in pairs(items) do
        if it.name == cfg.silo_item then n = n + (it.count or 0) end
      end
    end
    return n
  end
  -- a side's sensor: is there a silo in its bay? nil when there is no sensor
  -- for the side, or it cannot be read. Two kinds: an optical_sensor (a ray:
  -- hasHit, and what it hit and how far) and an Avionics laser_sensor (a
  -- power level). Either way the sensor is ON or OFF, and silo_when says
  -- which of those means a silo. Also what it actually read, for the log.
  local function present(sd)
    local name = cfg.detect[sd]
    if not name or not peripheral.isPresent(name) then return nil end
    local on, said
    if peripheral.getType(name) == "optical_sensor" then
      local okH, hit = pcall(peripheral.call, name, "hasHit")
      if not okH then return nil end
      on = hit and true or false
      if on then
        local okB, blk = pcall(peripheral.call, name, "getBlock")
        local okD, dist = pcall(peripheral.call, name, "getDistance")
        said = string.format("hit %s at %.2f", okB and tostring(blk) or "?", okD and tonumber(dist) or -1)
      else
        said = "no hit"
      end
    else
      local okP, pow = pcall(peripheral.call, name, "getPower")
      if not (okP and type(pow) == "number") then
        local okH, hit = pcall(peripheral.call, name, "getClosestHitDistance")
        if not okH then return nil end
        pow = hit and 15 or 0
      end
      on, said = pow > 0, "power " .. pow
    end
    return on == (cfg.silo_when == "high"), said
  end

  -- a side's storage: its own list, or the dock's shared one
  local function storages(sd) return (sd and cfg.sides[sd] and cfg.sides[sd].storage) or cfg.storage end
  -- item -> count across a side's storage, or nil when it cannot be read
  local function tally(sd)
    local out = {}
    for _, inv in ipairs(storages(sd)) do
      local okL, items = pcall(peripheral.call, inv, "list")
      if not (okL and type(items) == "table") then return nil end
      for _, it in pairs(items) do
        if type(it) == "table" and it.name then out[it.name] = (out[it.name] or 0) + (it.count or 0) end
      end
    end
    return out
  end
  return { silo = silo, count = storageCount, feed = feedCount, present = present, tally = tally,
           storageOf = function(sd) return storages(sd)[1] end }
end

-- The install check for a two-sided dock, or a depot with nothing yet: every
-- line says what is there or what to do about it. A station.lua depot has
-- its own status further down.
if cmd == "status" and not fs.exists("station.lua") then
  local okId = id and id:match("^depot%-[%w_%-]+$")
  print(string.format("%s: %s", tostring(id or "no label"), fs.exists("dock.lua") and "two-sided dock" or "no dock.lua yet"))
  if not okId then print("  label: NOT A DEPOT - label set depot-<dock>, e.g. label set depot-chid-1") end
  print("  key: " .. (fs.exists(".dronekey") and "yes"
    or ("NONE - on the base: seckey new " .. tostring(okId and id or "depot-<dock>") .. ", then here: seckey set disk")))
  print("  radio: " .. tostring(link.findRadio(peripheral) or "NONE - fit an ender modem"))
  local cfg, whyD = dockCfg()
  if not cfg then
    local nRelays = 0
    for _, n in ipairs(peripheral.getNames()) do
      if peripheral.getType(n) == "redstone_relay" then nRelays = nRelays + 1 end
    end
    print(string.format("  %d redstone relays on the network - depot probe map says which does what", nRelays))
    print("  " .. whyD)
    return
  end
  local kit = dockKit(cfg)
  for _, side in ipairs({ "A", "B" }) do
    local s = cfg.sides[side]
    if s then
      local bad = {}
      for _, dev in ipairs({ "place", "assemble", "pusher", "belt" }) do
        if s[dev] and not peripheral.isPresent(s[dev]) then bad[#bad + 1] = dev .. " " .. s[dev] end
      end
      local n, f = kit.count(side), kit.feed(side)
      print(string.format("  side %s: %s", side, #bad == 0 and "relays ok" or ("MISSING " .. table.concat(bad, ", "))))
      print(string.format("    storage %s: %s   feed: %s", tostring(kit.storageOf(side) or "none"),
        n and (n .. " items") or "NOT READABLE", s.feed and (f and (f .. " silo blocks") or "NOT READABLE") or "none named"))
      print(string.format("    silo waiting: %s   drone's sticker this side: %s", kit.silo(side), tostring(cfg.stick[side])))
    end
  end
  if cfg.intake then
    local n = 0
    for _, inv in ipairs(cfg.intake) do
      local okL, items = pcall(peripheral.call, inv, "list")
      if not (okL and type(items) == "table") then n = nil break end
      for _, it in pairs(items) do n = n + (it.count or 0) end
    end
    print(string.format("  intake %s: %s", table.concat(cfg.intake, ", "), n and (n .. " items") or "NOT READABLE"))
  else
    print("  intake: none - a load takes what is already in each side's storage")
  end
  local pr = printerName(cfg.printer)
  print("  printer: " .. (pr or "NONE - silos go out without an invoice"))
  return
end

if cmd == "seq" then
  local cfg, whyD = dockCfg()
  if not cfg then print(whyD) return end
  local kit = dockKit(cfg)
  local silo, storageCount, feedCount, present = kit.silo, kit.count, kit.feed, kit.present

  local sub = (args[2] or ""):lower()
  local side = args[3] and args[3]:upper()
  if sub == "" then
    for _, sd in ipairs(DS.SIDES) do
      local s = cfg.sides[sd]
      if s then
        psay(string.format("side %s  silo: %-5s  place %s  assemble %s  pusher %s  belt %s", sd, silo(sd),
          s.place or "-", s.assemble or "-", s.pusher, s.belt or "(not mapped)"))
        local d = cfg.detect[sd]
        if d then
          local p, said = present(sd)
          psay(string.format("        detector %s: %s", d, p == nil and "NOT FOUND - check the name with depot probe"
            or string.format("%s (%s)", p and "a silo is in the bay" or "the bay is clear", tostring(said))))
        end
      end
    end
    for _, sd in ipairs(DS.SIDES) do
      local s = cfg.sides[sd]
      if s and s.storage then
        psay(string.format("storage %s: %s, %s items", sd, table.concat(s.storage, ", "),
          tostring(storageCount(sd) or "unreadable")))
      end
    end
    for _, sd in ipairs(DS.SIDES) do
      local s = cfg.sides[sd]
      if s and s.feed then
        local n = feedCount(sd)
        local p = n and math.floor(n / cfg.silo_blocks)
        psay(string.format("feed %s: %s, %s", sd, table.concat(s.feed, ", "), n
          and string.format("%d silo blocks (%d payload%s)", n, p, p == 1 and "" or "s") or "unreadable"))
      end
    end
    if #cfg.storage > 0 then psay("storage: " .. table.concat(cfg.storage, ", ")) end
    -- and every sensor this computer CAN see, whatever dock.lua calls them
    for _, n in ipairs(peripheral.getNames()) do
      local t = peripheral.getType(n)
      if t and tostring(t):find("laser") then
        local okP, pow = pcall(peripheral.call, n, "getPower")
        psay(string.format("  seen here: %s (%s) power %s", n, tostring(t), okP and tostring(pow) or "unreadable"))
      end
    end
    probeSave()
    print("")
    print("depot seq load <A|B|AB> [items]  place/assemble if needed, fill, push, stick, retract")
    print("depot seq unload <A|B|AB>        push, release, retract, empty into storage (AB: both at once)")
    print("  the drone is taken to be ready at every step; add `ask` to answer for it with ENT")
    print("depot seq silo <A|B> empty|none  correct what it remembers about a side")
    print("depot seq rest                   everything off, each belt to where its bay wants it")

    return
  end
  if sub == "rest" then
    -- after a messy test: every relay off, and each belt where its bay wants
    -- it - loading only if a filled silo is waiting, unloading otherwise. A
    -- belt left loading holds a silo's funnel busy, and the assembler cannot
    -- take it then (2026-09-24).
    for _, relay in ipairs(DS.relays(cfg)) do drive({ relay = relay }, false) end
    for _, sd in ipairs(DS.SIDES) do
      local s = cfg.sides[sd]
      if s and s.belt then
        local full = silo(sd) == "full"
        local lvl = DS.beltFor(cfg, full and "fill" or "empty", sd)
        if lvl ~= nil then
          drive({ relay = s.belt }, lvl)
          psay(string.format("side %s belt %s %s (%s)", sd, s.belt, lvl and "ON" or "OFF",
            full and "a filled silo is waiting: loading" or "unloading"))
        end
      end
    end
    psay("everything else off")
    probeSave()
    return
  end
  if sub == "silo" then
    local st = (args[4] or ""):lower()
    if not (side and cfg.sides[side]) or (st ~= "empty" and st ~= "none") then
      print("depot seq silo <A|B> empty|none")
      return
    end
    silo(side, st)
    print("side " .. side .. ": " .. st)
    return
  end
  if sub ~= "load" and sub ~= "unload" then print("depot seq [load|unload|silo] <A|B>") return end
  -- AB: both sides at once, as the base runs a flight of two silos
  local both = side == "AB" and cfg.sides.A and cfg.sides.B
  if not (both or (side and cfg.sides[side])) then print("which side: depot seq " .. sub .. " A (or B, or AB for both)") return end
  -- words after the side: a number is how many items; "ask" puts a person
  -- in for the drone again (ENT at each drone step)
  local items, ask = nil, false
  for i = 4, #args do
    if tonumber(args[i]) then items = tonumber(args[i]) end
    if tostring(args[i]):lower() == "ask" then ask = true end
  end

  local PROMPT = {
    dock = "the drone: latch it on the dock",
    stick = "the drone: stick the silo (stickers out)",
    release = "the drone: let go of the silo (stickers in)",
  }
  local stop = false
  local t0 = os.clock()
  -- a side's detector: is there a silo in its bay? nil when there is no
  -- detector, or it cannot be read
  local io = {
    set = function(relay, on) return drive({ relay = relay }, on) end,
    sleep = sleep, now = os.clock, count = storageCount, feed = feedCount, silo = silo, present = present,
    stopped = function() return stop end,
    say = function(step, text)
      psay(string.format("%5.1f %-8s %s", os.clock() - t0, step:upper(), text))
      DV.step(view, step, text, os.clock())
    end,
    -- The drone's part. In service the base answers these: the drone is
    -- latched, it has stuck the silo, it has let go. Here the drone is taken
    -- to be ready every time, after a moment to watch the machines - or a
    -- person answers, with `ask`.
    drone = function(what)
      if not ask then
        psay(string.format("%5.1f %-8s %s - taken as done (no base yet)", os.clock() - t0, what:upper(),
          PROMPT[what] or what))
        sleep(2)
        return not stop, stop and ("called off at " .. what) or nil
      end
      psay(string.format("%5.1f %-8s %s  [ENT] done  [X] call off", os.clock() - t0, what:upper(), PROMPT[what] or what))
      while true do
        local _, k = os.pullEvent("key")
        if k == keys.enter then return true end
        if k == keys.x then stop = true return false, "called off at " .. what end
      end
    end,
  }
  print(string.format("%s side %s%s - the machines move. X calls it off (pusher down).", sub, side,
    items and (", " .. items .. " items") or ""))
  if not confirm("go?") then print("nothing moved") return end
  psay(string.format("---- %s side %s ----", sub, side))
  -- the screens: what each bay holds, as remembered, and the feed
  for _, sd in ipairs(DS.SIDES) do
    view.sides[sd].silo = silo(sd) == "full" and "full" or (silo(sd) == "empty" and "empty" or "none")
    view.sides[sd].feed = feedCount(sd)
  end
  DV.begin(view, sub, both and { "A", "B" } or side, { id = "TEST", items = items }, os.clock())
  local ok, why, at, moved
  parallel.waitForAny(function()
    if not both then
      ok, why, at, moved = DS[sub](cfg, side, io, items)
      return
    end
    -- both at once: each side its own job, side by side
    local res = {}
    parallel.waitForAll(function() res.A = { DS[sub](cfg, "A", io, nil) } end,
                        function() res.B = { DS[sub](cfg, "B", io, nil) } end)
    ok = res.A[1] and res.B[1]
    local bad = (not res.A[1]) and res.A or ((not res.B[1]) and res.B or nil)
    why, at = bad and ((bad == res.A and "side A: " or "side B: ") .. tostring(bad[2])) or nil, bad and bad[3] or "done"
    moved = (res.A[4] or 0) + (res.B[4] or 0)
  end, function()
    while true do
      local _, k = os.pullEvent("key")
      if k == keys.x and not stop then stop = true print("calling it off...") end
    end
  end, screensLoop)
  if moved and view.job then view.job.moved = moved end
  DV.finish(view, ok, why, os.clock())
  for _, sd in ipairs(both and { "A", "B" } or { side }) do view.sides[sd].feed = feedCount(sd) end
  drawScreens(os.clock())
  psay(ok and string.format("%s done in %.0f s", sub, os.clock() - t0)
         or string.format("called off at %s: %s", tostring(at), tostring(why)))
  psay(string.format("side A: %s   side B: %s", silo("A"), silo("B")))
  probeSave()
  return
end

-- ------------------------------------------------------------ the base ---
-- The sealed link to the base, for either kind of dock: say, open what came,
-- and ask for the drone's part (stick, let go) and wait for the base's word.
local function linkUp()
  if not (id and id:match("^depot%-[%w_%-]+$")) then
    print("label this computer depot-<dock>, the dock's name on the base: label set depot-pier")
    return nil
  end
  local key = SEC.readKeyFile(".dronekey")
  if not key then
    print("no key: on the base `seckey new " .. id .. "`, then here `seckey set disk`")
    return nil
  end
  local radio = link.findRadio(peripheral)
  if not radio then print("no ender modem - this depot cannot hear the base") return nil end
  pcall(peripheral.call, radio, "open", link.CHANNEL)

  local tx = SEC.sender(key, id, SEC.DIR.DRONE_TO_BASE, ".dronekey.ctr")
  local rx = SEC.receiver()
  local seenNonce, seq = {}, 0
  local function nonce()
    seq = seq + 1
    return F.nonce(id, tostring(os.epoch and os.epoch("utc") or os.clock()) .. "." .. seq)
  end
  local function say(msg)
    local okS, env = pcall(tx.seal, msg)
    if okS and env then pcall(peripheral.call, radio, "transmit", link.CHANNEL, link.CHANNEL, env) end
  end
  -- one packet from the base for this depot, or nil: our key, the base's
  -- direction, a counter never used before, a nonce not seen before
  local function open(ch, env)
    if ch ~= link.CHANNEL or type(env) ~= "table" or not env.sl or env.d ~= SEC.DIR.BASE_TO_DRONE or env.id ~= id then
      return nil
    end
    local okO, body = pcall(rx.open, env, function(who) return who == id and key or nil end, SEC.DIR.BASE_TO_DRONE, 120000)
    if not (okO and body) then return nil end
    if not F.check(body) or (body.to ~= nil and body.to ~= id) then return nil end
    if not F.fresh(seenNonce, body.nonce, os.clock()) then return nil end
    DV.heard(view, os.clock())
    return body
  end
  local L = { say = say, open = open, nonce = nonce }
  function L.ask(msg, loadId, secs)
    say(msg)
    local timer = os.startTimer(secs)
    while true do
      local ev, a, ch, _, env = os.pullEvent()
      if ev == "modem_message" then
        local m = open(ch, env)
        if m and m.type == "load.stuck" and m.load == loadId then return m.ok, m.why end
      elseif ev == "timer" and a == timer then
        return false, "no word from the base in " .. secs .. " s"
      end
    end
  end
  return L
end

local function readState()
  if not fs.exists(STATE) then return nil end
  local h = fs.open(STATE, "r")
  local s = h and h.readAll() or ""
  if h then h.close() end
  return s:match("^(%S+) (%S+)")
end
local function saveState(load, step)
  local h = fs.open(STATE, "w")
  if h then h.write(load .. " " .. step) h.close() end
end
local function clearState() if fs.exists(STATE) then fs.delete(STATE) end end

-- ------------------------------------------------ run: the two-sided dock ---
-- With a dock.lua here, the base's loads and unloads run on the A/B dock
-- (lib/dockseq.lua) - the same machine code `depot seq` drives by hand - and
-- the drone's part (latched, stick, let go) is answered through the base. Both
-- sides at once: a flight of two silos loads A and B together. Per side:
--   load    stage its silo's share from the intake into the side's storage,
--           when dock.lua names an intake; place and assemble a silo if none
--           is waiting; fill it through the belt - what left the storage is
--           what went in; print its invoice into the storage for the belt to
--           carry into the silo; push up, the drone sticks it, pusher down
--   unload  push up under the drone's silo, the drone lets go, pusher down,
--           empty it into the side's storage - what arrived is what came
-- What goes back to the base is what each side's storage says, never the plan.
local INVOICE_RIDE = 15      -- s for the belt to carry a page from the storage into the silo
if cmd == "run" and fs.exists("dock.lua") then
  local cfg, whyD = dockCfg()
  if not cfg then print(whyD) return end
  local kit = dockKit(cfg)
  local L = linkUp()
  if not L then return end
  local say, open, nonce = L.say, L.open, L.nonce
  local function rest()
    for _, relay in ipairs(DS.relays(cfg)) do drive({ relay = relay }, false) end
  end
  local interrupted, atStep = readState()
  if interrupted then
    print(string.format("stopped part way through %s, at %s - pushers down, everything at rest", interrupted, atStep))
    rest()
    clearState()
  end

  -- the sides a job uses: the ones the base names, else as many as it has silos
  local function sidesFor(msg)
    local list = {}
    for sd in tostring(msg.sides or ""):gmatch("[AB]") do if cfg.sides[sd] then list[#list + 1] = sd end end
    if #list == 0 then
      local n = tonumber(msg.silos) or 1
      for _, sd in ipairs(DS.SIDES) do if cfg.sides[sd] and #list < n then list[#list + 1] = sd end end
    end
    return list
  end

  -- "item count|item count" -> { item = count }
  local function unpackPack(text)
    local out = {}
    for part in tostring(text or ""):gmatch("[^|]+") do
      local item, n = part:match("^(%S+) (%d+)$")
      if item then out[item] = tonumber(n) end
    end
    return out
  end

  -- A silo's share from the intake into this side's storage. What is there
  -- already and is the same item counts toward it (a fill that came up short
  -- last time); anything else stops the load - it would ride to someone who
  -- never ordered it. Read back after. Returns what was moved, or nil and why.
  local function stage(side, pack, tell)
    local want = unpackPack(pack)
    local into = kit.storageOf(side)
    if not into then return nil, "side " .. side .. " has no storage to stage into" end
    local have = kit.tally(side)
    if not have then return nil, "side " .. side .. "'s storage cannot be read" end
    for item, n in pairs(have) do
      if not want[item] then
        return nil, string.format("side %s's storage already has %d %s in it that nobody ordered - clear it first",
          side, n, item)
      end
    end
    local moved = {}
    for item, n in pairs(want) do
      local need, got = n - (have[item] or 0), 0
      for _, src in ipairs(cfg.intake) do
        local okL, list = pcall(peripheral.call, src, "list")
        for slot, it in pairs(okL and type(list) == "table" and list or {}) do
          if need - got <= 0 then break end
          if it.name == item then
            local okM, m = pcall(peripheral.call, src, "pushItems", into, slot, math.min(it.count or 0, need - got))
            if okM and type(m) == "number" then got = got + m end
          end
        end
      end
      moved[item] = got
      if got < need then tell(string.format("the intake was short: %d of %d %s for side %s", got, need, item, side)) end
    end
    local after = kit.tally(side) or {}
    for item, n in pairs(want) do
      local expect = math.min(n, (have[item] or 0) + (moved[item] or 0))
      if (after[item] or 0) < expect then
        return nil, string.format("side %s's storage holds %d %s, not the %d staged into it", side, after[item] or 0,
          item, expect)
      end
    end
    return moved
  end

  -- the silo's invoice, into the side's storage: the belt, still loading,
  -- carries it into the silo after the goods
  local function invoiceFor(msg, k, side, counted, beforeExtra, tell)
    if not msg.inv_order then return end
    local name = printerName(cfg.printer)
    if not name then tell("no printer on this network - no invoice") return end
    local inv = INVOICE.fromFields(msg, k, counted, beforeExtra)
    local title, lines = INVOICE.page(inv)
    local no = INVOICE.number(inv.order, inv.shipment)
    local into = kit.storageOf(side)
    local ok, why = printPage(name, title, lines)
    if ok and into then ok, why = takePage(name, into) end
    if not ok then tell(string.format("invoice %s not printed: %s - the load goes on without it", no, tostring(why))) return end
    local t0 = os.clock()
    while os.clock() - t0 < INVOICE_RIDE do
      local t = kit.tally(side) or {}
      if not t[PAGE_ITEM] then tell(string.format("invoice %s printed, in the %s silo", no, side)) return end
      sleep(1)
    end
    tell(string.format("invoice %s printed, but it is still in side %s's storage - it did not go in", no, side))
  end

  -- Both sides at once (the dual loader fills two at once - ORDERS.md): each
  -- side is its own job, running beside the other. They meet where they have
  -- to: the intake is shared, so staging is one side then the other before
  -- anything else moves; the drone is one, so its stick (or its letting go)
  -- is asked once for every side still going, when all their pushers are up;
  -- and the invoices print A then B, once both are counted, so B's page
  -- counts A's silo as shipped before. A side that fails drops out and the
  -- other carries on.
  local function runJob(msg, kind)
    local loadId = msg.load
    local sides = sidesFor(msg)
    local t0 = os.clock()
    local shipments
    if kind == "load" and msg.inv_first then
      local a, b = msg.inv_first, msg.inv_first + #sides - 1
      shipments = (a == b and tostring(a) or (a .. "-" .. b)) .. " OF " .. tostring(msg.inv_last or b)
    end
    for _, sd in ipairs(DS.SIDES) do
      view.sides[sd].silo = kit.silo(sd) == "full" and "full" or (kit.silo(sd) == "empty" and "empty" or "none")
      view.sides[sd].feed = kit.feed(sd)
    end
    DV.begin(view, kind, sides, { id = loadId, items = msg.items, dest = msg.dest, unit = msg.drone,
      item = msg.inv_item and INVOICE.itemName(msg.inv_item) or nil, shipments = shipments }, t0)
    print("")
    print(string.format("%s %s for %s: side%s %s", kind, loadId, NAMES.unit(tostring(msg.drone)), #sides == 1 and "" or "s",
      table.concat(sides, " + ")))
    local function tell(step, text)
      print(string.format("%5.1f %-8s %s", os.clock() - t0, step:upper(), text))
      saveState(loadId, step)
      DV.step(view, step, text, os.clock())
      say(F.loadStep(loadId, id, step, text, nonce()))
    end
    local report = { sides = {}, stickers = {}, silos = {}, counted = "from each side's storage" }
    local failed = {}                      -- side -> why, at
    -- what the sides share: who is still going, who has reached each meeting
    -- point, the drone's answers, the counts and pages
    local going, met, answer, counts, printed = {}, {}, {}, {}, {}
    local function drop(side, why, at)
      going[side] = nil
      failed[#failed + 1] = { side = side, why = why, at = at }
    end
    local function allThere(point)
      for sd in pairs(going) do if not (met[point] and met[point][sd]) then return false end end
      return true
    end
    local function meet(side, point)
      met[point] = met[point] or {}
      met[point][side] = true
      while not allThere(point) do sleep(0.2) end
    end
    -- the drone's part, asked once for all the sides still going
    local function together(side, what)
      meet(side, what)
      if not answer[what] then
        answer[what] = "asking"
        local stickers = {}
        for _, sd in ipairs(sides) do if going[sd] then stickers[#stickers + 1] = cfg.stick[sd] end end
        local ask = (what == "stick") and F.loadLifted or F.loadRelease
        local ok, why = L.ask(ask(loadId, id, stickers, nonce()), loadId, STICK_WAIT)
        answer[what] = { ok = ok, why = why }
      end
      while answer[what] == "asking" do sleep(0.2) end
      return answer[what].ok, answer[what].why
    end

    -- staging, one side after the other: they share the intake
    if kind == "load" and cfg.intake then
      for k, side in ipairs(sides) do
        local pack = msg["pack" .. k]
        if pack then
          local moved, whyS = stage(side, pack, function(t) tell("stage", t) end)
          if moved then
            local n = 0
            for _, c in pairs(moved) do n = n + c end
            tell("stage", string.format("%d items staged on side %s", n, side))
            going[side] = true
          else
            failed[#failed + 1] = { side = side, why = whyS, at = "stage" }
          end
        else
          going[side] = true
        end
      end
    else
      for _, side in ipairs(sides) do going[side] = true end
    end

    -- then every side still going, at once
    local jobs = {}
    for k, side in ipairs(sides) do
      if going[side] then
        jobs[#jobs + 1] = function()
          local before
          local io = {
            set = function(relay, on) return drive({ relay = relay }, on) end,
            sleep = sleep, now = os.clock, count = kit.count, feed = kit.feed, silo = kit.silo, present = kit.present,
            say = tell,
            -- the base starts a job only once the drone is latched here
            drone = function(what)
              if what == "dock" then return true end
              return together(side, what)
            end,
          }
          local ok, why, at
          if kind == "load" then
            io.beforeFill = function() before = kit.tally(side) or {} end
            io.filled = function()
              local got = C.diff(before or {}, kit.tally(side) or {})
              got[PAGE_ITEM] = nil
              counts[side] = got
              report.silos[side] = C.pack(got)
              -- every side counted (or out) first, then the pages in side order
              meet(side, "counted")
              local shippedBefore = 0
              for j = 1, k - 1 do
                local other = sides[j]
                while going[other] and not printed[other] do sleep(0.2) end
                if counts[other] and msg.inv_item then shippedBefore = shippedBefore + (counts[other][msg.inv_item] or 0) end
              end
              invoiceFor(msg, k, side, got, shippedBefore, function(t) tell("invoice", t) end)
              printed[side] = true
            end
            local n = kit.count(side)
            ok, why, at = DS.load(cfg, side, io, (n and n > 0) and n or nil)
          else
            before = kit.tally(side) or {}
            ok, why, at = DS.unload(cfg, side, io, nil)
            if ok then report.silos[side] = C.pack(C.diff(kit.tally(side) or {}, before)) end
          end
          if ok then printed[side] = true else drop(side, why, at) end
        end
      end
    end
    if #jobs > 0 then parallel.waitForAll((table.unpack or unpack)(jobs)) end

    -- what went with the drone (or came off it), in side order
    for _, side in ipairs(sides) do
      local bad = false
      for _, f in ipairs(failed) do if f.side == side then bad = true end end
      if not bad then
        report.sides[#report.sides + 1] = side
        report.stickers[#report.stickers + 1] = cfg.stick[side]
      else
        report.silos[side] = nil
      end
    end
    local ok, why, at = #failed == 0 and #sides > 0, nil, "done"
    if #sides == 0 then why, at = "this dock has none of the sides asked for", "start" end
    if #failed > 0 then
      why, at = string.format("side %s: %s", failed[1].side, tostring(failed[1].why)), failed[1].at
      if #report.sides > 0 then why = why .. " (side " .. table.concat(report.sides, "+") .. " done)" end
    end
    say(F.loadDone(loadId, id, ok, why, at, report, nonce(), kind))
    DV.finish(view, ok, why, os.clock())
    clearState()
    print(ok and (kind .. " done in " .. math.floor(os.clock() - t0) .. " s - over to the base")
             or ("called off at " .. tostring(at) .. ": " .. tostring(why)))
  end

  local function hellos()
    local n = 0
    while true do
      n = n + 1
      local tell = n <= 3 and interrupted or nil
      say(F.depotHello(id, tell, tell and atStep or nil, nonce()))
      sleep(HELLO_EVERY)
    end
  end
  local function orders()
    while true do
      local _, _, ch, _, env = os.pullEvent("modem_message")
      local msg = open(ch, env)
      if msg and msg.type == "load.start" then runJob(msg, "load")
      elseif msg and msg.type == "unload.start" then runJob(msg, "unload") end
    end
  end
  local nSides = 0
  for _ in pairs(cfg.sides) do nSides = nSides + 1 end
  print(string.format("depot %s: the two-sided dock, %d side%s, awake - telling the base every %d s", id, nSides,
    nSides == 1 and "" or "s", HELLO_EVERY))
  parallel.waitForAny(hellos, orders, screensLoop)
  return
end

if not fs.exists("station.lua") then
  print("no station.lua here: copy station.example.lua to station.lua and fill it in")
  print("(a two-sided dock has dock.lua instead - `depot seq` shows it, and `depot` runs it)")
  print("`depot probe` lists the relays and inventories to fill it in with")
  return
end
local okF, raw = pcall(dofile, "station.lua")
local cfg, whyC = LOAD.check(okF and raw or nil)
if not cfg then print("station.lua: " .. tostring(okF and whyC or raw)) return end
local hands = LOAD.station(cfg, peripheral, redstone, C)

local function atRest()
  for _, face in ipairs(LOAD.allFaces(cfg)) do hands.set(face, face.invert and true or false) end
end

-- every silo of an order's load gets its invoice, from its own count
local function printInvoices(msg, plan, tell)
  if not msg.inv_order then return end
  local name = printerName(cfg.printer)
  if not name then tell("no printer on this network - no invoices") return end
  local before = 0
  for k, side in ipairs(plan.sides) do
    local counted = plan.manifest and (plan.manifest[side] or (#plan.sides == 1 and plan.manifest.both)) or nil
    if not counted then
      tell(string.format("side %s was not counted on its own - no invoice for it", side))
    else
      local inv = INVOICE.fromFields(msg, k, counted, before)
      local title, lines = INVOICE.page(inv)
      local no = INVOICE.number(inv.order, inv.shipment)
      local into = (cfg.invoice_into and cfg.invoice_into[side]) or (cfg.silo and cfg.silo[side])
      local ok, why = printPage(name, title, lines)
      if ok and into then ok, why = takePage(name, into) end
      if ok and into then tell(string.format("invoice %s printed, in the %s silo", no, side))
      elseif ok then tell(string.format("invoice %s printed - it is in the printer: nowhere set to put it", no))
      else tell(string.format("invoice %s not printed: %s - the load goes on without it", no, tostring(why))) end
      if msg.inv_item then before = before + (counted[msg.inv_item] or 0) end
    end
  end
end


if cmd == "status" then
  print(string.format("%s: %d bay%s (%s)", tostring(id), #cfg.bays, #cfg.bays == 1 and "" or "s",
    table.concat(cfg.bays, " + ")))
  if not (id and id:match("^depot%-")) then print("  label it depot-<dock>: label set depot-pier") end
  print("  key: " .. (fs.exists(".dronekey") and "yes" or "NONE - seckey set disk"))
  print("  radio: " .. tostring(link.findRadio(peripheral) or "NONE - fit an ender modem"))
  for _, face in ipairs(LOAD.allFaces(cfg)) do
    if face.relay and not peripheral.isPresent(face.relay) then print("  MISSING: " .. face.relay) end
  end
  for side, name in pairs(cfg.silo or {}) do
    print(string.format("  silo %s: %s %s", side, name, hands.tally(name) and "readable" or "not there (placed?)"))
  end
  if cfg.intake then
    local n = hands.intake()
    print(string.format("  intake %s: %s", cfg.intake, n and (n .. " items") or "NOT READABLE"))
  end
  return
end

if cmd == "test" then
  local act, side = (args[2] or ""):lower(), args[3] and args[3]:lower()
  if not LOAD.ACTIONS[act] then print("depot test <place|assemble|lift|retract> [left|right]") return end
  if not confirm("fire " .. act .. (side and (" " .. side) or "") .. "? the machines move") then
    print("nothing fired")
    return
  end
  local faces, whyF, release = LOAD.fire(cfg, hands, act, side and { side } or nil)
  if not faces then print(whyF) return end
  local held = false
  for _, face in ipairs(faces) do held = held or face.hold end
  if held then
    write("held on - ENT to let go ")
    read()
    release()
  end
  print("done - all back at rest")
  return
end

-- ------------------------------------------------------------------- run ---
local L = linkUp()
if not L then return end
local say, open, nonce = L.say, L.open, L.nonce

-- a load that was under way when this computer last stopped
local interrupted, atStep = readState()
if interrupted then
  print(string.format("stopped part way through load %s, at %s", interrupted, atStep))
  if LIFTED[atStep] then
    print("lowering the lift")
    LOAD.fire(cfg, hands, "retract")
  end
  atRest()
  clearState()
end

-- A load from the base. It runs here, beside the hellos; the base's answer
-- to "have it stick" is picked out of the radio by io.stick.
local function runLoad(msg)
  local loadId = msg.load
  local items, stack, stacks = msg.items, msg.stack, nil
  if not items then
    local n, st, smallest = hands.intake()
    if not n or n == 0 then
      say(F.loadDone(loadId, id, false, n == 0 and "the intake is empty" or "how many items? no intake to count",
        "start", nil, nonce()))
      return
    end
    items, stacks, stack = n, st, smallest
  end
  local plan, whyP = LOAD.plan(cfg, items, stack, stacks)
  if not plan then say(F.loadDone(loadId, id, false, "does not fit: " .. whyP, "start", nil, nonce())) return end
  print("")
  print(string.format("load %s for %s: %d items, %d silo%s (%s)", loadId, NAMES.unit(tostring(msg.drone)), plan.items,
    plan.silos, plan.silos == 1 and "" or "s", table.concat(plan.sides, " + ")))
  local t0 = os.clock()
  local shipments
  if msg.inv_first then
    local a, b = msg.inv_first, msg.inv_first + #plan.sides - 1
    shipments = (a == b and tostring(a) or (a .. "-" .. b)) .. " OF " .. tostring(msg.inv_last or b)
  end
  DV.begin(view, "load", plan.sides, { id = loadId, items = plan.items, dest = msg.dest, unit = msg.drone,
    item = msg.inv_item and INVOICE.itemName(msg.inv_item) or nil, shipments = shipments }, t0)
  local io = {}
  for k, v in pairs(hands) do io[k] = v end
  io.sleep, io.now = sleep, os.clock
  -- the base starts a load only once its telemetry has the drone latched on
  -- this dock, so there is nothing more to wait for here
  io.docked = function() return true end
  io.stick = function(names)
    say(F.loadLifted(loadId, id, names, nonce()))
    local timer = os.startTimer(STICK_WAIT)
    while true do
      local ev, a, ch, _, env = os.pullEvent()
      if ev == "modem_message" then
        local m = open(ch, env)
        if m and m.type == "load.stuck" and m.load == loadId then return m.ok, m.why end
      elseif ev == "timer" and a == timer then
        return false, "no word from the base in " .. STICK_WAIT .. " s"
      end
    end
  end
  io.say = function(step, text)
    print(string.format("%5.1f %-8s %s", os.clock() - t0, step:upper(), text))
    saveState(loadId, step)
    DV.step(view, step, text, os.clock())
    say(F.loadStep(loadId, id, step, text, nonce()))
  end
  io.counted = function(p)
    printInvoices(msg, p, function(text) io.say("invoice", text) end)
  end
  -- the drone's liftoff is the base's to order
  local runCfg = {}
  for k, v in pairs(cfg) do runCfg[k] = v end
  runCfg.liftoff = false
  local ok, why, at = LOAD.run(runCfg, plan, io)
  local report = { counted = plan.counted, sides = plan.sides, stickers = plan.stickers, silos = {} }
  for side, got in pairs(plan.manifest or {}) do report.silos[side] = C.pack(got) end
  say(F.loadDone(loadId, id, ok, why, at, report, nonce()))
  DV.finish(view, ok, why, os.clock())
  clearState()
  print(ok and ("loaded in " .. math.floor(os.clock() - t0) .. " s - over to the base")
           or ("called off at " .. tostring(at) .. ": " .. tostring(why)))
end

local function hellos()
  local n = 0
  while true do
    n = n + 1
    -- the first few carry the interrupted load, in case one is missed
    local tell = n <= 3 and interrupted or nil
    say(F.depotHello(id, tell, tell and atStep or nil, nonce()))
    sleep(HELLO_EVERY)
  end
end

local function orders()
  while true do
    local _, _, ch, _, env = os.pullEvent("modem_message")
    local msg = open(ch, env)
    if msg and msg.type == "load.start" then runLoad(msg) end
  end
end

print(string.format("depot %s: %d bay%s, awake - telling the base every %d s", id, #cfg.bays,
  #cfg.bays == 1 and "" or "s", HELLO_EVERY))
parallel.waitForAny(hellos, orders, screensLoop)
