-- depot: the computer at a dock that works its loading station.
--
--   depot                        wait for loads from the base
--   startup autorun depot        ...from every boot, which is how it should run
--   depot status                 the station from station.lua, and what it can reach
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
--   depot seq                    the two-sided dock (dock.lua): `seq load A`,
--                                `seq unload B`, with you standing in for the
--                                drone - ENT when it has latched, stuck or let go
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

local args = { ... }
local cmd = (args[1] or "run"):lower()
local HELLO_EVERY = 10     -- seconds between hellos while awake
local STICK_WAIT = 20      -- seconds to wait for the base's word that the drone stuck
local STATE = ".depotstate"
-- steps from which the lift may be up
local LIFTED = { lift = true, stick = true, retract = true, liftoff = true }

local id = os.getComputerLabel and os.getComputerLabel()

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
local function probeSave()
  if #probeLines == 0 then return end
  local h = fs.open(PROBE_LOG, fs.exists(PROBE_LOG) and "a" or "w")
  if not h then print("could not write " .. PROBE_LOG) return end
  h.write(string.format("---- %s  %s ----\n", tostring(id or "depot"),
    os.date and select(2, pcall(os.date, "%m-%d %H:%M")) or tostring(os.clock())))
  for _, line in ipairs(probeLines) do h.write(line .. "\n") end
  h.close()
  probeLines = {}
  -- and push it, so it can be read without standing at this computer
  local okM, MACHINE = pcall(dofile, "lib/machine.lua")
  local folder = okM and type(MACHINE) == "table" and MACHINE.folder(id) or nil
  if not folder then
    print(string.format("kept in %s - label this computer to keep it in the repo (label set test-dock)", PROBE_LOG))
    return
  end
  local into = folder .. "/" .. PROBE_LOG
  if not (fs.exists("upload.lua") and http and shell) then
    print(string.format("kept in %s - `paste %s` to send it (no http or upload.lua here)", PROBE_LOG, PROBE_LOG))
    return
  end
  print("pushing " .. PROBE_LOG .. " to " .. into .. " ...")
  local okU, whyU = pcall(shell.run, "upload", "sync", PROBE_LOG, into)
  if not okU then
    print("push failed: " .. tostring(whyU))
    print("`paste " .. PROBE_LOG .. "` sends it instead")
  end
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
if cmd == "seq" then
  local DS = dofile("lib/dockseq.lua")
  if not fs.exists("dock.lua") then
    print("no dock.lua here - it lives in this machine's folder in the repo")
    print("(machines/" .. tostring(id) .. "/dock.lua); run startup to pull it")
    return
  end
  local okD, raw = pcall(dofile, "dock.lua")
  local cfg, whyD = DS.check(okD and raw or nil)
  if not cfg then print("dock.lua: " .. tostring(okD and whyD or raw)) return end

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
  -- a side's sensor: is there a silo in its bay? Its power is what it says -
  -- high or low - read straight; nil when there is no sensor for the side, or
  -- it cannot be read. The power, too, for the status line.
  local function present(sd)
    local name = cfg.detect[sd]
    if not name or not peripheral.isPresent(name) then return nil end
    local okP, pow = pcall(peripheral.call, name, "getPower")
    if not (okP and type(pow) == "number") then
      local okH, hit = pcall(peripheral.call, name, "getClosestHitDistance")
      if not okH then return nil end
      pow = hit and 15 or 0
    end
    return (pow > 0) == (cfg.silo_when == "high"), pow
  end

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
          local p, pow = present(sd)
          psay(string.format("        detector %s: %s", d, p == nil and "NOT FOUND - check the name with depot probe"
            or string.format("%s (power %d)", p and "a silo is in the bay" or "the bay is clear", pow)))
        end
      end
    end
    psay("storage: " .. (#cfg.storage > 0 and table.concat(cfg.storage, ", ") or "(none - fills and empties are timed)"))
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
    print("depot seq load <A|B> [items]     place/assemble if needed, fill, push, stick, retract")
    print("depot seq unload <A|B> [items]   push, release, retract, empty into storage")
    print("depot seq silo <A|B> empty|none  correct what it remembers about a side")
    print("  test mode: you stand in for the drone - ENT when it has latched, stuck or let go")
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
  if not (side and cfg.sides[side]) then print("which side: depot seq " .. sub .. " A") return end
  local items = tonumber(args[4])

  local PROMPT = {
    dock = "the drone: latch it on the dock",
    stick = "the drone: stick the silo (stickers out)",
    release = "the drone: let go of the silo (stickers in)",
  }
  local stop = false
  local t0 = os.clock()
  local function storageCount()
    if #cfg.storage == 0 then return nil end
    local n = 0
    for _, inv in ipairs(cfg.storage) do
      local okL, list = pcall(peripheral.call, inv, "list")
      if not (okL and type(list) == "table") then return nil end
      for _, it in pairs(list) do n = n + (it.count or 0) end
    end
    return n
  end
  -- a side's detector: is there a silo in its bay? nil when there is no
  -- detector, or it cannot be read
  local io = {
    set = function(relay, on) return drive({ relay = relay }, on) end,
    sleep = sleep, now = os.clock, count = storageCount, silo = silo, present = present,
    stopped = function() return stop end,
    say = function(step, text) psay(string.format("%5.1f %-8s %s", os.clock() - t0, step:upper(), text)) end,
    drone = function(what)
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
  local ok, why, at, moved
  parallel.waitForAny(function()
    ok, why, at, moved = DS[sub](cfg, side, io, items)
  end, function()
    while true do
      local _, k = os.pullEvent("key")
      if k == keys.x and not stop then stop = true print("calling it off...") end
    end
  end)
  psay(ok and string.format("%s done in %.0f s", sub, os.clock() - t0)
         or string.format("called off at %s: %s", tostring(at), tostring(why)))
  psay(string.format("side A: %s   side B: %s", silo("A"), silo("B")))
  probeSave()
  return
end

if not fs.exists("station.lua") then
  print("no station.lua here: copy station.example.lua to station.lua and fill it in")
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
if not (id and id:match("^depot%-[%w_%-]+$")) then
  print("label this computer depot-<dock>, the dock's name on the base: label set depot-pier")
  return
end
local key = SEC.readKeyFile(".dronekey")
if not key then
  print("no key: on the base `seckey new " .. id .. "`, then here `seckey set disk`")
  return
end
local radio = link.findRadio(peripheral)
if not radio then print("no ender modem - this depot cannot hear the base") return end
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
  return body
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
  print(string.format("load %s for %s: %d items, %d silo%s (%s)", loadId, tostring(msg.drone), plan.items,
    plan.silos, plan.silos == 1 and "" or "s", table.concat(plan.sides, " + ")))
  local t0 = os.clock()
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
    say(F.loadStep(loadId, id, step, text, nonce()))
  end
  -- the drone's liftoff is the base's to order
  local runCfg = {}
  for k, v in pairs(cfg) do runCfg[k] = v end
  runCfg.liftoff = false
  local ok, why, at = LOAD.run(runCfg, plan, io)
  local report = { counted = plan.counted, sides = plan.sides, stickers = plan.stickers, silos = {} }
  for side, got in pairs(plan.manifest or {}) do report.silos[side] = C.pack(got) end
  say(F.loadDone(loadId, id, ok, why, at, report, nonce()))
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
parallel.waitForAny(hellos, orders)
