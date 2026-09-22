-- depot: the computer at a dock that works its loading station.
--
--   depot                        wait for loads from the base
--   startup autorun depot        ...from every boot, which is how it should run
--   depot status                 the station from station.lua, and what it can reach
--   depot test <action> [side]   fire one action's relay: place assemble lift retract
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

if not fs.exists("station.lua") then
  print("no station.lua here: copy station.example.lua to station.lua and fill it in")
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
