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
--                                in probe.txt and pushed to the repo as
--                                data/probe-<this computer>.txt, so a whole
--                                session of "fire that, see what moved" can be
--                                read from anywhere. `depot probe clear` starts
--                                a fresh one; with no http or no .ghtoken here,
--                                `paste probe.txt` sends it instead.
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

local function snapshot()
  local s = { type = {}, relay = {}, inv = {} }
  for _, n in ipairs(peripheral.getNames()) do
    local t = peripheral.getType(n)
    s.type[n] = t
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
      if inv then s.inv[n] = inv end
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
  for _, n in ipairs(other) do psay("  " .. n) end
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
