-- ops: the admin panel. It watches the whole fleet and gives orders.
--
--   ops                  the live board, and it dispatches taxi pads
--   ops list             one snapshot of the fleet, then quit
--   ops fly <who> <...>  fly a command on a drone: ops fly any ferry pier
--   ops send <who> <pad> shorthand for: ops fly <who> ferry <pad>
--   ops land|hold|undock <who>     the in-flight words fly already takes
--   ops stats            what the taxi pads have reported
--   ops closed           run the board but turn radio hails away
--   ops open             also take hails from terminals with no key - for
--                        testing only. By default only passes made with
--                        `provision` (or seckey cust) can call a shuttle.
--   ops poke <drone>     prove the link: ask a drone to answer, nothing flies
--   ops free <drone>     it is not on a job, whatever ops thinks
--   ops jobs [n]         the last n rides and what they cost in time
--   ops account [who]    balances, or one customer's history
--   ops credit <who> <n> put credit on an account by hand (spurs)
--   ops till             what the till can see: the seat, the pad, the depositor
--   ops place            the destinations customers can pick from
--   ops place add <name> <x> <y> <z> [dock]   add one (or move it), in F3's
--                                         order; a pad unless `dock`
--   ops place del <name>                  take one off the list
--   ops sos [n]          the last n incidents: every unit that went down or
--                        silent, with where it was, for recovery
--
-- It runs on the base computer and, just as happily, on an ender pocket
-- computer: the board lays itself out for 26 columns and keeps the keys that
-- matter. A pocket running ops needs .fleetkeys on it to seal orders, so that
-- pocket can order any drone in the fleet - treat it as the keys to the
-- hangar, not as a customer terminal (customers run hail, which holds no
-- keys).
--
-- <who> is a drone id, or "any" for the nearest one that is docked, has called
-- in within the last 15 s and is not already on a job.
--
-- All radio, no cables:
--   * telemetry comes in on the ENDER modem, sealed by each drone with its own
--     key, exactly as the wall reads it.
--   * ORDERS go back out the same modem, sealed by ops with that drone's key
--     from .fleetkeys (direction BASE_TO_DRONE). Only this computer can make
--     one, the counter rises so a copied packet is refused as a replay, and a
--     drone ignores anything it cannot open with its own key. That is what
--     replaces the cable: the proof rides with the message.
--   * customers' requests arrive as plain rednet. They ask, they never
--     command; ops decides and rate-limits them.
--
-- Hails are rate-limited per caller, logged as they arrive, and `ops closed`
-- turns them away entirely while the cabled pads keep working.
--
-- ops cannot forge telemetry: the keys open drone-to-base packets and seal
-- base-to-drone ones, and the two directions have separate nonces.

local F = dofile("lib/fleet.lua")
local LEDGER = dofile("lib/ledger.lua")
local QUEUE = dofile("lib/queue.lua")
local SEC = dofile("lib/seclink.lua")
local link = dofile("lib/link.lua")
-- the screen, the same kit the customer's terminal uses; ops still runs
-- without them and falls back to printing
local D, T, UI
do
  local okD, d = pcall(dofile, "lib/display.lua")
  if okD and type(d) == "table" and d.canvas then D = d end
  local okT, t = pcall(dofile, "lib/tui.lua")
  if okT and type(t) == "table" and t.box then T = t end
  local okU, u = pcall(dofile, "lib/opsui.lua")
  if okU and type(u) == "table" and u.board then UI = u end
end

local args = { ... }
local cmd = (args[1] or "watch"):lower()
-- `keys` is the name of this program's key loop further down, so the API gets
-- its own name before that shadows it
local keys_api = keys

local fleetKeys, nKeys = SEC.readFleetKeys(".fleetkeys")
-- Customers have their own keys, one per pass (`provision`). A sealed request
-- names the customer beyond doubt. An unsealed one is anonymous, and it is
-- refused unless ops was started with `ops open`: anyone can write a few lines
-- of Lua, so an open door would mean free anonymous rides for all of them.
local custKeys, nCusts = SEC.readFleetKeys(".custkeys")
local custRx = SEC.receiver()
local knownOnly = true

-- .custkeys changes while ops runs: provision adds a pass, `provision drop`
-- takes one away. It is read again whenever it changes, so a new pass works
-- the moment it leaves the drive and a dropped one stops at once - a revoked
-- key that kept working until the next restart would be a back door. A key
-- that changed also has its replay counter forgotten, because the new pass
-- counts from 1 again.
local custStamp = nil
local function custKeysFresh()
  local stamp
  if fs.attributes then
    local okA, a = pcall(fs.attributes, ".custkeys")
    stamp = okA and a and (tostring(a.modified) .. ":" .. tostring(a.size)) or "none"
  else
    stamp = tostring(math.floor(os.clock() / 10))      -- no attributes: every 10 s
  end
  if stamp == custStamp then return end
  custStamp = stamp
  local fresh, n = SEC.readFleetKeys(".custkeys")
  for id, k in pairs(custKeys) do
    if not fresh[id] or SEC.keyHex(fresh[id]) ~= SEC.keyHex(k) then custRx.forget(id) end
  end
  custKeys, nCusts = fresh, n
end
custKeysFresh()
local me = (os.getComputerLabel and os.getComputerLabel()) or ("ops-" .. tostring(os.getComputerID()))

-- ---------------------------------------------------------------- the wire --
-- Wired modems are opened if there are any - a pad on a cable still works -
-- but nothing needs one any more.
local wired = F.wired(peripheral)
for _, nm in ipairs(wired) do pcall(rednet.open, nm) end
-- the radio, for customers' requests (and, sealed, for every order)
local HAIL_EVERY = 20        -- seconds a caller must wait between hails
local openToHails = (cmd ~= "closed")
local lastHail = {}
if openToHails then
  for _, nm in ipairs(peripheral.getNames()) do
    if peripheral.getType(nm) == "modem" then
      local okW, wireless = pcall(peripheral.call, nm, "isWireless")
      if okW and wireless then pcall(rednet.open, nm) end
    end
  end
end
if cmd == "closed" then cmd = "watch" end
if cmd == "open" then knownOnly, cmd = false, "watch" end
if cmd == "known" then cmd = "watch" end            -- the default now; the old word still works


-- one sealed sender per drone, made on first use; the counter persists so a
-- restart of ops never reuses a nonce
local radio = link.findRadio(peripheral)
if radio then peripheral.call(radio, "open", link.CHANNEL) end
local senders = {}
local function senderFor(id)
  if senders[id] ~= nil then return senders[id] end
  local key = fleetKeys[id]
  if not key then senders[id] = false return false end
  senders[id] = SEC.sender(key, id, SEC.DIR.BASE_TO_DRONE, ".ops-" .. id .. ".ctr")
  return senders[id]
end

-- Every finished job, one CSV line, appended. Facts that never change, summed
-- later - so a file, not a database. `upload joblog.csv` puts it in the repo
-- where a script or a spreadsheet can read it, the same way flight logs work.
local JOBLOG = "joblog.csv"

-- ------------------------------------------------------------------ money ---
-- Every movement is a line in ledger.csv; a balance is their sum. Customers
-- may go negative, and a ride to a free place (the base, by default) costs
-- nothing, so nobody can strand themselves.
local LEDGER_FILE, TARIFF_FILE = "ledger.csv", "tariff.lua"
local tariff = LEDGER.TARIFF
do
  local okT, t = pcall(dofile, TARIFF_FILE)
  if okT and type(t) == "table" then
    tariff = LEDGER.tariff(t)
    if type(t.shutterSide) == "string" then shutterSide = t.shutterSide end
    if type(t.payPad) == "table" and tonumber(t.payPad.x) and tonumber(t.payPad.z) then
      payPad = { x = tonumber(t.payPad.x), z = tonumber(t.payPad.z),
                 r = tonumber(t.payPad.r) or PAD_RADIUS,
                 amount = tonumber(t.payPad.amount) or 512 }
    end
  end
end

-- The till's state lives up here with the rest of the money: `handle` arms a
-- top-up long before the watcher below runs, and a local declared after its
-- first use is a global - which silently armed nothing at all.
local ARM_WINDOW = 60          -- seconds a customer has to actually pay
local DEPOSIT_SIDE = "back"    -- where the depositor's pulse arrives
local armed, depositor
-- The pay pad. A customer's terminal says where it is standing; whoever is on
-- the pad when the depositor fires gets the credit. This sidesteps the thing
-- Numismatics will not tell us - which PLAYER paid - by not needing to know:
-- the question becomes which account is present, and a terminal can prove
-- that about itself. Set the spot in tariff.lua as payPad = { x=, z=, r= }.
local present, payPad = {}, nil
local PAD_RADIUS, PRESENCE_AGE = 2, 15
-- Locking the till. Numismatics has no "disabled" state for a depositor, but
-- it does have a price, and nobody can pay a price they cannot afford - so an
-- idle till is priced out of reach and only drops to the real amount when
-- there is somebody to credit. That closes the hole where a payment arrives
-- with no owner and has to be sorted out by hand.
--
-- With a shutter side set, it also drives redstone: a Create door, a piston,
-- anything that physically covers the block. Belt and braces, and the shutter
-- is the part a customer can see, which is worth more than a silent refusal.
local LOCK_PRICE = 2000000000     -- spurs: more than the mod can hold in an account
local shutterSide, lockedNow, pricedAt = nil, nil, nil
-- The seat. Create's "Entity Name" display source writes whoever is sitting in
-- a Create Seat onto a Display Link; CC:C Bridge's target block hands that text
-- to us. It is the only thing in this modpack that names a real player to a
-- computer, and it needs no card, no terminal and no admin - the customer just
-- sits down to pay. Build: seat at the till, display link aimed at it, source
-- "Entity Name", target a CC:C Bridge target block on the network.
local seat
for _, nm in ipairs(peripheral.getNames()) do
  if peripheral.getType(nm) == "create_target" then seat = nm end
end

local function whoIsSitting()
  if not seat then return nil end
  local ok, line = pcall(peripheral.call, seat, "getLine", 1)
  if not ok then return nil end
  return (F.seatName(line))
end
for _, nm in ipairs(peripheral.getNames()) do
  if peripheral.getType(nm) == "Numismatics_Depositor" then depositor = nm end
end

local function ledgerRows()
  if not fs.exists(LEDGER_FILE) then return {} end
  local h = fs.open(LEDGER_FILE, "r")
  local text = h.readAll() or ""
  h.close()
  return (LEDGER.parse(text))
end

local takings = 0        -- what has come in since ops started, for the board

local function post(who, kind, amount, note)
  local new = not fs.exists(LEDGER_FILE)
  local h = fs.open(LEDGER_FILE, new and "w" or "a")
  if not h then return nil, "cannot write " .. LEDGER_FILE end
  if new then h.writeLine(LEDGER.HEADER) end
  local when = os.epoch and math.floor(os.epoch("utc") / 1000) or os.time()
  h.writeLine(LEDGER.row(when, who, kind, amount, note))
  h.close()
  if amount < 0 then takings = takings - amount end   -- fares are takings too
  return LEDGER.balanceOf(ledgerRows(), who)
end
local function writeJob(j)
  local at = os.epoch and math.floor(os.epoch("utc") / 1000) or os.time()
  local new = not fs.exists(JOBLOG)
  local h = fs.open(JOBLOG, new and "w" or "a")
  if not h then return false end
  if new then h.writeLine(F.JOB_HEADER) end
  h.writeLine(F.jobRow(j, at))
  h.close()
  return true
end

local seq = 0
local function nonce()
  seq = seq + 1
  return F.nonce(me, tostring(os.epoch and os.epoch("utc") or os.time()) .. "." .. seq)
end

local function shout(msg) pcall(rednet.broadcast, msg, F.PROTO) end

-- ------------------------------------------------------------- the fleet ----
-- Built from telemetry alone: a drone exists the moment a packet of its opens.
local fleet, pads, jobs, padStats = {}, {}, {}, {}
-- Everyone waiting for a shuttle, in the order they asked. Nothing is promised
-- to anyone until a drone is actually free - see lib/queue.lua for the rules,
-- which are four sentences long on purpose.
local waiting = {}
-- nonces live in their OWN table. They were sharing `jobs`, whose values are
-- job records, and fleet.fresh does arithmetic on every value it finds while
-- ageing them out: the first hail after a job existed crashed ops with
-- "attempt to perform arithmetic on a table value" (2026-09-20).
local seenNonce = {}

-- The board clears the screen every two seconds, so anything printed from the
-- serve loop vanished before it could be read - including the error that took
-- the loop down. Events go in here instead and the board draws them.
local events = {}
local function log(fmt, ...)
  local line = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
  events[#events + 1] = string.format("%s  %s", textutils.formatTime(os.time(), true), line)
  while #events > 8 do table.remove(events, 1) end
  return line
end

-- -------------------------------------------------------------- incidents ---
-- Every flight that ends badly, and every unit that goes silent mid-job, is
-- written to incidents.csv with where the unit was, so it can be recovered.
-- The newest one nobody has acknowledged stands across the top of the board
-- until A is pressed. `ops sos` lists them. One row per episode: a unit still
-- calling updates its alert rather than adding rows.
local INCIDENTS = "incidents.csv"
local INCIDENT_HEADER = "when,drone,job,customer,x,y,z,why"
local BOARD_NEAR = 24         -- blocks: a free unit this close is walked to, not flown in
local alerts = {}             -- unacknowledged: { drone, x, y, z, why }

local function coords(x, y, z)
  if type(x) ~= "number" or type(z) ~= "number" then return "position unknown" end
  return string.format("%d %d %d", math.floor(x), math.floor(type(y) == "number" and y or 0), math.floor(z))
end

incident = function(drone, j, why, x, y, z, alert)
  local f = fleet[drone] or {}
  x, y, z = x or f.x, y or f.y, z or f.z
  if alert ~= false then
    for _, a in ipairs(alerts) do
      if a.drone == drone then
        a.x, a.y, a.z = x or a.x, y or a.y, z or a.z
        if a.why == "distress signal" then a.why = why end
        return
      end
    end
  end
  local function cell(v) return (tostring(v == nil and "" or v):gsub("[,\r\n]", " ")) end
  local function whole(v) return type(v) == "number" and tostring(math.floor(v)) or "" end
  local line = table.concat({ cell(os.epoch and math.floor(os.epoch("utc") / 1000) or os.time()),
    cell(drone), cell(j and j.id), cell(j and j.who), whole(x), whole(y), whole(z), cell(why) }, ",")
  local fresh = not fs.exists(INCIDENTS)
  local h = fs.open(INCIDENTS, "a")
  if h then
    if fresh then h.writeLine(INCIDENT_HEADER) end
    h.writeLine(line)
    h.close()
  end
  if alert ~= false then
    alerts[#alerts + 1] = { drone = drone, x = x, y = y, z = z, why = why }
    log("DISTRESS %s at %s: %s", drone, coords(x, y, z), why)
  else
    log("incident %s at %s: %s", drone, coords(x, y, z), why)
  end
end
local rejected = 0

do
  local okP, P = pcall(dofile, "lib/pads.lua")
  if okP and type(P) == "table" then pads = P.load("pads.lua", fs) or {} end
end
local function padByName(name)
  for _, p in ipairs(pads) do if p.name == tostring(name):lower() then return p end end
  return nil
end

local incident            -- defined once log() exists, below

local function note(d)
  local id = d.id
  fleet[id] = fleet[id] or {}
  local f = fleet[id]
  f.seen = os.clock()
  f.x, f.z, f.y = d.x, d.z, d.y
  f.phase, f.mode = d.phase, d.mode
  f.docked = (d.dock == 1) or d.phase == "docked"
  f.energy, f.spd = d.energy, d.spd
  -- a unit whose telemetry reads sos is down: a base that restarted, or
  -- missed the distress call itself, still finds out from the next packet
  if d.phase == "sos" and not f.sos then
    f.sos = true
    incident(id, nil, "distress signal", d.x, d.y, d.z)
  elseif d.phase ~= "sos" then
    f.sos = nil
  end
  if f.docked and f.job and jobs[f.job] and jobs[f.job].state == "done" then f.job = nil end
end

local handle    -- set below; a drone's sealed reply goes through the same path

local function receive()
  if not radio then
    print("ops: no ender modem - this computer cannot hear or order anything")
    while true do sleep(3600) end
  end
  local rx = SEC.receiver()
  while true do
    local _, _, ch, _, msg = os.pullEvent("modem_message")
    if ch == link.CHANNEL and type(msg) == "table" and msg.sl then
      local ok, body = pcall(rx.open, msg, function(id) return fleetKeys[id] end,
                             SEC.DIR.DRONE_TO_BASE, 120000)
      if ok and body then
        if body.type == "tlm" and link.check(body) then note(body)
        elseif F.TYPES[body.type] and handle then pcall(handle, nil, body) end
      else
        rejected = rejected + 1
      end
    end
  end
end

-- ------------------------------------------------------------ dispatching ---
local function pickWho(who, near)
  who = (who or "any"):lower()
  if who ~= "any" then
    local ok, why = F.available(fleet[who], os.clock())
    if not ok then return who, "warning: " .. who .. " is " .. why end
    return who
  end
  local id, why = F.pick(fleet, near or { x = 0, z = 0 }, os.clock())
  if not id then return nil, why end
  return id
end

-- An order: sealed with that drone's key and sent on the telemetry channel.
-- Nobody else can make one, and no other drone can open it.
local lastSent           -- what the last order looked like on the air
local function order(id, msg)
  msg.to = id
  local s = senderFor(id)
  if not s then return false, "no key for " .. id .. " - run seckey new " .. id .. " here" end
  if not radio then return false, "no ender modem on this computer" end
  local env, why = s.seal(msg)
  if not env then return false, tostring(why) end
  local ok = pcall(peripheral.call, radio, "transmit", link.CHANNEL, link.CHANNEL, env)
  lastSent = string.format("%s n=%d d=%d to %s", tostring(msg.type), env.n, env.d, id)
  return ok, ok and nil or "the modem refused the packet"
end

-- Who asked, so the answer and every state update go back to them. A pad on
-- the cable and a pocket in the air are answered the same way.
local function reply(to, msg)
  if to then pcall(rednet.send, to, msg, F.PROTO) end
  shout(msg)
end

local function dispatch(req, from)
  -- The destination as this computer knows it. A known place's own record
  -- wins over what the terminal sent, which is also what makes a ride home
  -- free only when it really goes home.
  local dest = F.placeFor(pads, req.toName, req.tx, req.tz)
  if dest then req.toName, req.tx, req.tz, req.ty = dest.name, dest.x, dest.z, dest.y
  else req.toName = nil end
  -- The pickup is a known place if it names one, otherwise wherever the
  -- caller is. Only a DOCK is named in the order: the drone ferries there and
  -- latches on. At a landing pad it lands beside the customer like anywhere
  -- else. The name stays on the job record either way.
  local known = req.pad and padByName(req.pad)
  local pickupName = req.pad
  if known then
    req.px, req.py, req.pz = req.px or known.x, req.py or known.y, req.pz or known.z
    if known.kind == "pad" then req.pad = nil end
  end
  local pad = known or { name = pickupName, x = req.px, y = req.py, z = req.pz }
  local id, why = F.pick(fleet, pad, os.clock())
  if not id then
    -- nobody free: take a place in the line rather than turning them away
    local stranded = false
    if req.who then
      local b = LEDGER.balances(ledgerRows())[req.who]
      stranded = (b and b.balance < 0) and (tostring(req.toName or ""):lower() == "home")
    end
    local place = QUEUE.add(waiting, { who = req.who or tostring(from), nonce = req.nonce,
      px = req.px, pz = req.pz, tx = req.tx, tz = req.tz, toName = req.toName,
      pad = pickupName, at = os.clock(), client = from, priority = stranded })
    if not place then
      reply(from, F.ack("j-none", "ops", false, "you are already in the queue", nonce()))
      return nil, "already waiting"
    end
    local secs = QUEUE.wait(waiting, place, 0, nil)
    pcall(rednet.send, from, F.queued(place, secs, nonce()), F.PROTO)
    log("%s queued at %d (%s free: %s)", tostring(req.who or from), place, "none", tostring(why))
    return nil, "queued " .. place
  end
  -- a free unit already on station near the customer: no pickup flight, they
  -- walk to it and press G. The ride starts from where it stands.
  do
    local nid, nd = F.nearUnit(fleet, req.px, req.pz, os.clock(), BOARD_NEAR)
    if nid then
      id = nid
      req.board = true
      req.px, req.pz = math.floor(nd.x), math.floor(nd.z)
      local at = F.placeFor(pads, nil, nd.x, nd.z, 8)
      pickupName = at and at.name or pickupName
      req.pad = nil
      log("%s is on station near %s - boarding there", nid, tostring(req.who or from))
    end
  end
  local job = "j-" .. tostring(os.epoch and math.floor(os.epoch("utc") / 1000) or os.time()) .. "-" .. id
  jobs[job] = { id = job, drone = id, pad = pickupName, toName = req.toName, px = req.px, pz = req.pz,
                tx = req.tx, tz = req.tz, state = "assigned",
                at = os.clock(), who = req.who, client = from,
                blocks = math.sqrt((req.tx - req.px) ^ 2 + (req.tz - req.pz) ^ 2) }
  fleet[id] = fleet[id] or {}
  fleet[id].job = job
  local assign = F.assign(job, req)
  local sent, whySent = order(id, assign)     -- sealed, to that drone only
  if not sent then
    jobs[job] = nil
    fleet[id].job = nil
    if from then pcall(rednet.send, from, F.ack(job, id, false, whySent, nonce()), F.PROTO) end
    return nil, whySent
  end
  if from then pcall(rednet.send, from, assign, F.PROTO) end   -- and to whoever asked
  return id, job
end

-- ------------------------------------------------------------------ board ---
local function line(id, f, now)
  local age = f.seen and (now - f.seen) or 999
  local state = age > 30 and "LOST" or (age > 5 and "STALE" or (f.docked and "DOCKED" or (f.phase or "FLYING"):upper()))
  local job = f.job and jobs[f.job]
  return string.format("%-10s %-7s %6s %5s %s",
    id, state,
    (type(f.energy) == "number") and (string.format("%d%%", math.floor(f.energy + 0.5))) or "--",
    (type(f.spd) == "number") and string.format("%3.0f", f.spd) or "--",
    job and (job.state .. " " .. job.id:sub(1, 14)) or "")
end

local function board()
  local now = os.clock()
  local ids = {}
  for id in pairs(fleet) do ids[#ids + 1] = id end
  table.sort(ids)
  print(string.format("%-10s %-7s %6s %5s %s", "DRONE", "STATE", "BATT", "SPD", "JOB"))
  if #ids == 0 then print("  (nothing has called in yet)") end
  for _, id in ipairs(ids) do print(line(id, fleet[id], now)) end
  return #ids
end

-- ------------------------------------------------------------ one-shot use --
if cmd == "list" then
  print(string.format("ops: %d key%s, %d pad%s", nKeys, nKeys == 1 and "" or "s", #pads, #pads == 1 and "" or "s"))
  print("listening 3 s for telemetry...")
  parallel.waitForAny(receive, function() sleep(3) end)
  board()
  if rejected > 0 then print(rejected .. " packet(s) refused - a drone whose key is not in .fleetkeys") end
  return
end

if cmd == "fly" or cmd == "send" or cmd == "land" or cmd == "hold" or cmd == "undock" then
  local who, line2
  if cmd == "fly" then
    who = args[2]
    line2 = table.concat({ table.unpack and table.unpack(args, 3) or unpack(args, 3) }, " ")
  elseif cmd == "send" then
    who, line2 = args[2], "ferry " .. tostring(args[3] or "")
    if not args[3] then print("ops send <drone|any> <pad>") return end
  end
  if not who then print("ops " .. cmd .. " <drone|any> ...") return end
  print("listening 3 s so the board is current...")
  parallel.waitForAny(receive, function() sleep(3) end)

  if cmd == "land" or cmd == "hold" or cmd == "undock" then
    -- fly's own in-flight words. fly only ever takes these on a WIRED modem
    -- (CMD_RADIO_STRICT), so this reaches a drone that is on a cable and
    -- nothing else; a drone in the air on radio alone cannot be stopped this
    -- way, and that is fly's rule, not ops's.
    if who:lower() == "any" then print("name the drone for " .. cmd) return end
    local okB = pcall(rednet.broadcast, { cmd = cmd }, "drone-cmd")
    print(okB and (cmd .. " sent on the cable (fly takes it by word, not by name)")
                or ("no wired modem here, so " .. cmd .. " cannot be sent"))
    return
  end

  local near = padByName(args[3]) or nil
  local argsOk, whyArgs = F.flyArgs(line2)
  if not argsOk then print("ops: that command is no good: " .. whyArgs) return end
  local id, why = pickWho(who, near)
  if not id then print("ops: " .. tostring(why)) return end
  if why then print(why) end
  print(string.format("%s -> %s: fly %s", me, id, argsOk))
  local seen, sent, whySent = orderAndWait(id, F.flyCommand(argsOk, nonce()), 6)
  if not sent then print("ops: " .. tostring(whySent)) return end
  if seen then
    print(seen.ok and ("  " .. id .. " took it") or ("  " .. id .. " refused: " .. tostring(seen.why)))
  else
    print("  no ack - is beacon running on it, and does its key match (seckey check)?")
  end
  return
end

-- Listen first, send second. The ack comes back in milliseconds - the drone
-- answers before it runs anything - so a send followed by a listen misses it
-- every time, and the poke reported no answer while the drone was happily
-- carrying out the order (2026-09-20).
local function orderAndWait(id, msg, secs)
  local got, rx = nil, SEC.receiver()
  local sent, whySent
  parallel.waitForAny(function()
    while not got do
      local _, _, ch, _, m = os.pullEvent("modem_message")
      if ch == link.CHANNEL and type(m) == "table" and m.sl then
        local okO, body = pcall(rx.open, m, function(idd) return fleetKeys[idd] end,
                                SEC.DIR.DRONE_TO_BASE, 120000)
        if okO and body and body.type == "job.ack" and body.drone == id then got = body end
      end
    end
  end, function()
    sleep(0.1)                      -- let the listener be waiting first
    sent, whySent = order(id, msg)
    if not sent then return end
    print("sent on channel " .. link.CHANNEL .. ": " .. tostring(lastSent))
    sleep(secs or 6)
  end)
  return got, sent, whySent
end

if cmd == "poke" then
  -- The wire test. It sends the drone a command it can obey without moving
  -- (fly pads just prints its pad list), so an ack proves the whole path:
  -- this computer -> cable -> docking connector -> beacon.
  local who = args[2]
  if not who then print("ops poke <drone>   (the id on the board)") return end
  print("poking " .. who .. " - it will print its pads and fly nothing")
  local answered, sent, whySent = orderAndWait(who, F.flyCommand("pads", nonce()), 6)
  if not sent then print("ops: " .. tostring(whySent)) return end
  if answered then
    print(who .. " answered. Its radio, its key and its beacon are all fine.")
    return
  end
  print("(if the drone says 'replay', delete .ops-" .. who .. ".ctr here and poke again)")
  print(who .. " did not answer. Check, in this order:")
  print(" 1 beacon is running on it (its screen shows #n DOCKED)")
  print(" 2 it has been updated: run startup on the drone")
  print(" 3 its key matches: seckey list here, seckey check on the drone")
  return
end

if cmd == "free" then
  -- the operator's override: this drone is not on a job, whatever ops thinks
  local who = args[2]
  if not who then print("ops free <drone>") return end
  print("listening 3 s...")
  parallel.waitForAny(receive, function() sleep(3) end)
  local had = fleet[who] and fleet[who].job
  if fleet[who] then fleet[who].job = nil end
  for _, j in pairs(jobs) do
    if type(j) == "table" and j.drone == who and j.state ~= "done" then j.state = "failed" end
  end
  print(had and (who .. " was on " .. tostring(had) .. " - cleared") or (who .. " was already free"))
  print("(ops in watch mode keeps its own list; restart it there if it still says busy)")
  return
end

if cmd == "sos" then
  -- every unit that went down or went silent, newest last, with where it was
  if not fs.exists(INCIDENTS) then print("no incidents - nothing has gone down") return end
  local h = fs.open(INCIDENTS, "r")
  local rows = {}
  while true do
    local line = h.readLine()
    if not line then break end
    if line ~= INCIDENT_HEADER and line ~= "" then rows[#rows + 1] = line end
  end
  h.close()
  local n = tonumber(args[2]) or 10
  print(string.format("%-11s %-9s %-22s %s", "WHEN", "UNIT", "WHERE (X Y Z)", "WHAT"))
  for i = math.max(1, #rows - n + 1), #rows do
    local when, drone, _, _, x, y, z, why = rows[i]:match("^([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),(.*)$")
    local t = tonumber(when)
    local okD, stamp = pcall(os.date, "%m-%d %H:%M", t)
    print(string.format("%-11s %-9s %-22s %s", okD and stamp or tostring(when), tostring(drone),
      (x ~= "" and (x .. " " .. y .. " " .. z)) or "unknown", tostring(why)))
  end
  return
end

if cmd == "place" then
  -- The destinations the pocket terminals offer. They live in pads.lua on this
  -- computer, the same file and format the drones use, so a place added here
  -- shows up on every terminal the next time one asks. A destination needs
  -- all three coordinates: y is the ground a landing brakes for, so it is
  -- asked for rather than guessed. A place is a PAD (somewhere safe to land) unless it is
  -- added as a DOCK (a built facility the craft latches onto); a pickup at a
  -- dock also needs the drone to know it, which is `fly pad add <name>`
  -- standing on the spot.
  local P = dofile("lib/pads.lua")
  local list = P.load("pads.lua", fs) or {}
  local sub = (args[2] or "list"):lower()
  if sub == "add" then
    local name, x, y, z = args[3], tonumber(args[4]), tonumber(args[5]), tonumber(args[6])
    if not (name and x and y and z) then
      print("ops place add <name> <x> <y> <z> [dock|pad]")
      print("  x y z as F3 shows them, standing on the landing spot")
      return
    end
    local kind = (args[7] or "pad"):lower()
    local entry = { name = name:lower(), kind = kind,
                    x = math.floor(x), y = math.floor(y), z = math.floor(z) }
    local ok, why = P.check(entry)
    if not ok then print("no: " .. tostring(why)) return end
    list = P.put(list, entry)
    local okW, whyW = P.save("pads.lua", list, fs)
    print(okW and string.format("%s (%s) is at %d %d %d", entry.name, entry.kind, entry.x, entry.y, entry.z)
               or ("could not save: " .. tostring(whyW)))
    return
  elseif sub == "del" then
    if not args[3] then print("ops place del <name>") return end
    list = P.remove(list, args[3]:lower())
    local okW = P.save("pads.lua", list, fs)
    print(okW and ("removed " .. args[3]:lower()) or "could not save pads.lua")
    return
  end
  if #list == 0 then print("no places yet - ops place add <name> <x> <y> <z>") return end
  print(string.format("%-14s %-4s %8s %5s %8s", "PLACE", "KIND", "X", "Y", "Z"))
  for _, p in ipairs(list) do
    print(string.format("%-14s %-4s %8d %5d %8d", p.name, p.kind or "dock", p.x, p.y or 0, p.z))
  end
  print("")
  print("a drone lands at a pad and docks at a dock. terminals pick these up")
  print("the next time they ask; a dock also needs the drone to know it:")
  print("fly pad add <name>, standing on it")
  return
end

if cmd == "till" then
  print("depositor: " .. (depositor or "none found (Numismatics_Depositor)"))
  print("seat     : " .. (seat or "none found (CC:C Bridge target block, type create_target)"))
  if seat then
    local okS, line = pcall(peripheral.call, seat, "getLine", 1)
    print("  reading: " .. (okS and ("\"" .. tostring(line) .. "\" -> " ..
      tostring(F.seatName(line) or "not a name")) or "could not read it"))
  end
  print("pay pad  : " .. (payPad and string.format("%d, %d r%d default %s", payPad.x, payPad.z, payPad.r,
    LEDGER.money(payPad.amount)) or "not set (tariff.lua payPad = { x=, z=, r=, amount= })"))
  print("side     : " .. DEPOSIT_SIDE .. " (redstone in)")
  print("shutter  : " .. (shutterSide and (shutterSide .. " (redstone out, on = open)")
                          or "not set (tariff.lua shutterSide = \"left\")"))
  print("")
  print("when nobody is there the depositor is priced at " .. LOCK_PRICE .. " spurs,")
  print("which nobody can pay - so a payment always has an owner.")
  return
end

if cmd == "account" then
  local rows = ledgerRows()
  local who = args[2]
  if who then
    local b = LEDGER.balances(rows)[who]
    if not b then print("nothing on record for " .. who) return end
    print(string.format("%s: %s, %d ride%s, paid %s, spent %s", who, LEDGER.money(b.balance),
      b.rides, b.rides == 1 and "" or "s", LEDGER.money(b.paid), LEDGER.money(b.spent)))
    print("")
    local shown = 0
    for i = #rows, 1, -1 do
      if rows[i].who == who and shown < 12 then
        shown = shown + 1
        print(string.format("%-8s %8s  %s", rows[i].kind, LEDGER.money(rows[i].amount), rows[i].note))
      end
    end
    return
  end
  local bal = LEDGER.balances(rows)
  local names = {}
  for n in pairs(bal) do names[#names + 1] = n end
  table.sort(names)
  if #names == 0 then print("no accounts yet - ops credit <who> <spurs>") return end
  print(string.format("%-14s %10s %6s", "CUSTOMER", "BALANCE", "RIDES"))
  for _, n in ipairs(names) do
    print(string.format("%-14s %10s %6d", n, LEDGER.money(bal[n].balance), bal[n].rides))
  end
  return
end

if cmd == "credit" then
  local who, amount = args[2], tonumber(args[3])
  if not (who and amount) then print("ops credit <who> <spurs>   (negative to take it back)") return end
  local bal = post(who, amount >= 0 and "credit" or "adjust", amount, "by hand")
  print(string.format("%s: %s, balance %s", who, LEDGER.money(amount), LEDGER.money(bal or 0)))
  return
end

if cmd == "jobs" then
  local want = tonumber(args[2]) or 10
  if not fs.exists(JOBLOG) then
    print("no rides recorded yet (" .. JOBLOG .. " appears after the first one)")
    return
  end
  local h = fs.open(JOBLOG, "r")
  local rows = F.jobRows(h.readAll() or "")
  h.close()
  local sum = F.jobSummary(rows)
  print(string.format("%d rides, %d finished, %d failed, %d blocks carried",
    sum.jobs, sum.done, sum.failed, sum.blocks))
  print(string.format("average wait %.0fs, average ride %.0fs", sum.avgWait, sum.avgRide))
  local earned, far = 0, 0
  for _, r in ipairs(rows) do
    earned = earned + (tonumber(r.fare) or 0)
    far = far + (tonumber(r.blocks) or 0)
  end
  print(string.format("earned %s over %d blocks (%s a ride)", LEDGER.money(earned), far,
    LEDGER.money(sum.done > 0 and (earned / sum.done) or 0)))
  local places = {}
  for where, n in pairs(sum.byPlace) do places[#places + 1] = { where, n } end
  table.sort(places, function(a, b) return a[2] > b[2] end)
  for i = 1, math.min(#places, 4) do
    print(string.format("  %-14s %d", places[i][1], places[i][2]))
  end
  print("")
  print(string.format("%-16s %-10s %6s %6s %s", "WHEN", "DRONE", "BLOCKS", "WAIT", "OUTCOME"))
  for i = math.max(1, #rows - want + 1), #rows do
    local r = rows[i]
    print(string.format("%-16s %-10s %6s %5ss %s",
      textutils.formatTime((tonumber(r.at) or 0) % 86400 / 3600, true),
      (r.drone or "?"):sub(1, 10), r.blocks or "?", math.floor(tonumber(r.waited) or 0), r.outcome or "?"))
  end
  print("")
  print("upload joblog.csv  pushes this to the repo")
  return
end

if cmd == "stats" then
  print("listening 10 s for pad reports (each pad sends on the minute and after a ride)...")
  local heard = 0
  parallel.waitForAny(function()
    while true do
      local _, msg = rednet.receive(F.PROTO)
      if type(msg) == "table" and msg.type == "pad.stats" and F.check(msg) then
        heard = heard + 1
        print(string.format("  %-10s %4d rides  %4d asked  %3d failed  %8d blocks",
          msg.pad, msg.rides, msg.requests or 0, msg.failures or 0, msg.blocks or 0))
      end
    end
  end, function() sleep(10) end)
  if heard == 0 then print("  nothing reported - are the pads cabled to this computer?") end
  return
end

if cmd ~= "watch" then
  print("ops: watch | list | fly <who> <...> | send <who> <pad> | poke <who> | free <who>")
  print("     | jobs [n] | land|hold|undock <who> | stats | closed")
  return
end

-- ---------------------------------------------------------------- watching --
print(string.format("ops %s: %d key%s, %d pad%s, orders sealed on %s", me,
  nKeys, nKeys == 1 and "" or "s", #pads, #pads == 1 and "" or "s",
  radio and (radio .. " channel " .. link.CHANNEL) or "NOTHING - no ender modem"))
print(string.format("%s  %d customer key%s%s",
  openToHails and "dispatching pads and radio hails." or "dispatching pads only - hails turned away.",
  nCusts, nCusts == 1 and "" or "s", knownOnly and "" or "  OPEN TO ANY TERMINAL (testing)"))

-- One message. Kept separate so serve can run it under pcall: a single
-- malformed packet must never be able to stop ops answering customers.
-- What only a drone may say. Those arrive sealed on the telemetry channel,
-- where handle is called with no rednet sender. The same types by plain
-- rednet are someone pretending to be a drone: a "failed" or "done" for
-- another customer's ride would free its unit mid-flight, a false distress
-- would send the operator out for nothing.
local DRONE_ONLY = { ["job.state"] = true, ["job.ack"] = true, ["unit.distress"] = true }

function handle(from, msg, customer)
  do
    if type(msg) == "table" and from ~= nil and DRONE_ONLY[msg.type] then
      log("ignored a %s by plain radio from %s - drones speak sealed", tostring(msg.type), tostring(from))
      msg = nil
    end
    if type(msg) == "table" and (F.check(msg)) then
      if msg.type == "taxi.request" then
        -- a proven name beats a claimed one
        local caller = tostring(customer or msg.who or from)
        msg.who = caller
        if not F.fresh(seenNonce, msg.nonce, os.clock()) then
          -- a repeat of one already in hand: a customer leaning on the button
        else
          -- the rate slot is only spent on a hail we are really going to act on
          local slowEnough, whyRate = F.rateOk(lastHail, caller, os.clock(), HAIL_EVERY)
          if not slowEnough then
            pcall(rednet.send, from, F.ack("j-none", "ops", false, whyRate, nonce()), F.PROTO)
            log("another hail from %s, %s", caller, whyRate)
          else
            local id, why = dispatch(msg, from)
            log("%s from %s: %s",
              msg.pad and ("pad " .. msg.pad) or string.format("hail at %d,%d", msg.px or 0, msg.pz or 0),
              caller,
              id and (id .. " " .. tostring(why)) or ("nobody: " .. tostring(why)))
          end
        end
      elseif msg.type == "account.ask" then
        local who = customer or msg.who
        if who then
          local b = LEDGER.balances(ledgerRows())[who] or { balance = 0, rides = 0 }
          pcall(rednet.send, from, F.accountInfo(who, b.balance, b.rides, nonce()), F.PROTO)
        end
      elseif msg.type == "fare.ask" then
        -- a price for the confirm screen: the same destination rules and the
        -- same tariff as the charge at the end, so the quote is the fare
        -- a free unit already on station nearby: the customer walks to it,
        -- and the ride - and so the fare - starts from where it stands
        local nid, nd = F.nearUnit(fleet, msg.px, msg.pz, os.clock(), BOARD_NEAR)
        local near
        if nid then
          local at = F.placeFor(pads, nil, nd.x, nd.z, 8)
          near = { unit = nid, x = math.floor(nd.x), y = type(nd.y) == "number" and math.floor(nd.y) or nil,
                   z = math.floor(nd.z), place = at and at.name or nil }
          msg.px, msg.pz = nd.x, nd.z
        end
        local blocks, toName = F.quoteBlocks(pads, msg)
        local fare, why = LEDGER.fare(blocks, toName, tariff)
        pcall(rednet.send, from, F.fareQuote(fare, why, nonce(), msg.nonce, near), F.PROTO)
      elseif msg.type == "job.cancel" then
        local who = customer or msg.who
        local gone = who and QUEUE.removeWho(waiting, who)
        if gone then log("%s left the queue", tostring(who)) end
      elseif msg.type == "here" then
        -- a terminal saying where it is. Only a SEALED one counts: an
        -- unsealed "here" is just someone claiming to be somewhere.
        if customer then
          present[customer] = { x = msg.x, z = msg.z, at = os.clock(), amount = msg.amount, client = from }
        end
      elseif msg.type == "credit.arm" then
        -- "I am about to put money in a depositor": remember who, so the
        -- redstone pulse can be credited to them. The depositor itself cannot
        -- say who paid (Numismatics has no such API), which is exactly why
        -- this has to be armed from the customer's own sealed terminal.
        local who = customer or msg.who
        if not who then
          log("a top-up was armed with no name - ignored")
        else
          armed = { who = who, amount = math.floor(msg.amount), at = os.clock(), client = from }
          if depositor then pcall(peripheral.call, depositor, "setTotalPrice", armed.amount) end
          log("%s topping up %s - waiting for the depositor", who, LEDGER.money(armed.amount))
        end
      elseif msg.type == "places.ask" then
        -- the pads this base knows, so a customer picks a name instead of
        -- typing coordinates off F3
        pcall(rednet.send, from, F.placesList(pads, nonce()), F.PROTO)
      elseif msg.type == "ops.ping" then
        -- "can you hear me?" - and how many drones are free right now
        local free = 0
        for _, d in pairs(fleet) do if (F.available(d, os.clock())) then free = free + 1 end end
        pcall(rednet.send, from, F.ack("ping", "ops", true, free .. " free", nonce()), F.PROTO)
        log("ping from %s - answered, %d free", tostring(from), free)
      elseif msg.type == "job.relocate" then
        -- the unit could not land and is holding above: the customer has found
        -- somewhere clear. Only the terminal that ordered the job may move it,
        -- the same rule as job.go. A platform that is a dock is named, so the
        -- unit ferries to it; anywhere else it lands at the coordinates.
        local j = jobs[msg.job]
        if not j then
          -- nothing to do
        elseif j.client and from ~= j.client then
          log("ignored a new spot for %s from %s - not the caller", tostring(msg.job), tostring(from))
        elseif j.state ~= "relocate" then
          log("ignored a new spot for %s - it is %s, not holding", tostring(msg.job), tostring(j.state))
        else
          local known = msg.pad and padByName(msg.pad)
          local pad = (known and known.kind == "dock") and known.name or nil
          j.px, j.pz = msg.px, msg.pz
          j.blocks = math.sqrt(((j.tx or msg.px) - msg.px) ^ 2 + ((j.tz or msg.pz) - msg.pz) ^ 2)
          local sent, why = order(j.drone, F.relocate(j.id, msg.px, msg.py, msg.pz, nonce(), pad))
          log(sent and ("%s: new spot %d %d for %s"):format(j.id, msg.px, msg.pz, tostring(j.drone))
                   or ("new spot not sent: " .. tostring(why)))
        end
      elseif msg.type == "job.go" then
        -- The customer is aboard. Only the terminal that ORDERED this job may
        -- say so: hails are broadcast in the clear, so anyone in radio range
        -- can read a job id, and without this check a passer-by could send the
        -- shuttle off before the customer had climbed in (2026-09-21).
        local j = jobs[msg.job]
        if not j then
          -- nothing to do
        elseif j.client and from ~= j.client then
          log("ignored a go for %s from %s - not the caller", tostring(msg.job), tostring(from))
        else
          order(j.drone, F.go(j.id, nonce()))
        end
      elseif msg.type == "job.ack" then
        local j = jobs[msg.job]
        if j then
          j.acked = os.clock()
          if not msg.ok then
            log("%s refused %s: %s", tostring(msg.drone), msg.job, tostring(msg.why))
            if fleet[j.drone] then fleet[j.drone].job = nil end
            j.state = "failed"
            if j.client then pcall(rednet.send, j.client, F.state(j.id, msg.drone, "failed", tostring(msg.why), nonce()), F.PROTO) end
          end
        end
      elseif msg.type == "job.state" then
        local j = jobs[msg.job]
        if j then
          j.state, j.updated = msg.state, os.clock()
          -- the two numbers worth knowing about a ride: how long the customer
          -- waited for the taxi, and how long the ride itself took
          if msg.state == "riding" then j.waited = os.clock() - j.at end
          if msg.state == "done" or msg.state == "failed" then
            j.rode = j.waited and (os.clock() - j.at - j.waited) or 0
            j.total = os.clock() - j.at
            j.outcome = msg.state
            -- the fare, once: for a ride that finished, and for one dropped
            -- because the customer gave the unit nowhere it could land
            local dropped = msg.state == "failed" and tostring(msg.detail or ""):find("job dropped", 1, true)
            if (msg.state == "done" or dropped) and j.who and not j.charged then
              -- the DESTINATION decides a free ride; where they were picked up never does
              local fare, why = LEDGER.fare(j.blocks, j.toName, tariff)
              if dropped then why = "dropped, no clear spot - " .. why end
              j.charged, j.fare = true, fare
              if fare > 0 then
                local bal = post(j.who, "fare", -fare, why)
                log("%s charged %s (%s)", j.who, LEDGER.money(fare), LEDGER.money(bal or 0))
                if j.client then
                  pcall(rednet.send, j.client, F.accountInfo(j.who, bal or 0, 0, nonce(), fare), F.PROTO)
                end
              else
                log("%s: %s", j.who, why)
                if j.client then
                  pcall(rednet.send, j.client,
                        F.accountInfo(j.who, LEDGER.balanceOf(ledgerRows(), j.who), 0, nonce(), 0), F.PROTO)
                end
              end
            end
            if not j.logged then j.logged = writeJob(j) end
          end
          if (msg.state == "relocate" or msg.state == "failed")
             and tostring(msg.detail or ""):find("obstructed", 1, true) then
            incident(msg.drone, j, tostring(msg.detail), j.px, nil, j.pz, false)
          end
          if j.client then pcall(rednet.send, j.client, msg, F.PROTO) end
          if msg.state == "done" or msg.state == "failed" then
            if fleet[msg.drone] then fleet[msg.drone].job = nil end
          end
        end
        log("%s %s%s", msg.drone, msg.state, msg.detail and (" - " .. msg.detail) or "")
      elseif msg.type == "unit.distress" then
        local f = fleet[msg.drone] or {}
        fleet[msg.drone] = f
        f.sos = true
        incident(msg.drone, f.job and jobs[f.job] or nil, msg.why, msg.x, msg.y, msg.z)
      elseif msg.type == "pad.stats" then
        padStats[msg.pad] = msg
      end
    elseif type(msg) == "table" and msg.v ~= nil then
      local _, whyBad = F.check(msg)
      log("ignored a %s: %s", tostring(msg.type), tostring(whyBad))
    end
  end
end

local function serve()
  while true do
    local from, msg = rednet.receive(F.PROTO)
    -- a sealed request: open it with that customer's key, and remember who
    -- they are. Anything that fails to open is dropped, not guessed at.
    local who
    if type(msg) == "table" and msg.sl then
      custKeysFresh()
      local okO, body = pcall(custRx.open, msg, function(id) return custKeys[id] end,
                              SEC.DIR.DRONE_TO_BASE, 120000)
      if okO and body then
        who, msg = body.id, body
      else
        log("refused a sealed request from %s: %s", tostring(msg.id), tostring(body))
        msg = nil
      end
    elseif knownOnly and type(msg) == "table" and msg.type == "taxi.request" then
      log("refused a hail from a terminal with no pass (ops open takes them, for testing)")
      -- and say so, or the terminal waits out its timeout and reports that
      -- nothing answered, which sends people looking for the wrong fault
      pcall(rednet.send, from, F.ack("j-none", "ops", false, "no pass on this terminal", nonce()), F.PROTO)
      msg = nil
    end
    local ok, err = pcall(handle, from, msg, who)
    if not ok then log("ERROR handling %s: %s", type(msg) == "table" and tostring(msg.type) or "?", tostring(err)) end
  end
end

-- An assignment the drone never answers. Without this the drone sits with a
-- job against its name and no later hail can have it, while the customer
-- waits on a taxi that was never told to come.
local ACK_WAIT, JOB_STUCK, JOB_SILENT = 6, 45, 180
local function finish(j, why)
  j.state = "failed"
  j.outcome, j.total = "failed:" .. why, os.clock() - j.at
  j.rode = j.waited and (j.total - j.waited) or 0
  if not j.logged then j.logged = writeJob(j) end
  if fleet[j.drone] and fleet[j.drone].job == j.id then fleet[j.drone].job = nil end
  log("%s: %s - %s is free again", j.id, why, tostring(j.drone))
  if j.client then
    pcall(rednet.send, j.client, F.state(j.id, j.drone, "failed", why, nonce()), F.PROTO)
  end
end

-- ------------------------------------------------------------- the till ----
-- A Brass Depositor pulses redstone when someone pays it, and says nothing
-- about who paid. So the customer arms a top-up from their own terminal first,
-- and the next pulse inside ARM_WINDOW is credited to them. No arming, no
-- credit - the money is still taken by the block, so ops says so loudly.
-- Who the till would credit right now, and for how much. One answer, used
-- both to decide the price and to decide who gets the money, so the two can
-- never disagree.
local function tillOwner()
  local sitting = whoIsSitting()
  if sitting then
    local p = present[sitting]
    local amount = (p and p.amount) or (armed and armed.who == sitting and armed.amount)
                   or (payPad and payPad.amount) or 512
    return sitting, math.floor(amount), "seat"
  end
  if payPad then
    local who, amount = F.onPad(present, payPad, os.clock(), payPad.r, PRESENCE_AGE)
    if who then return who, math.floor(amount or payPad.amount), "pad" end
  end
  if armed and os.clock() - armed.at <= ARM_WINDOW then
    return armed.who, math.floor(armed.amount), "armed"
  end
  return nil
end

-- Keep the depositor priced for whoever is standing there, and shut when
-- nobody is. Only writes when something actually changes: setting a price
-- every tick would be a peripheral call per tick for nothing.
local function lock()
  while true do
    local who, amount = tillOwner()
    local wantLocked = (who == nil)
    local wantPrice = wantLocked and LOCK_PRICE or amount
    if depositor and wantPrice ~= pricedAt then
      if pcall(peripheral.call, depositor, "setTotalPrice", wantPrice) then pricedAt = wantPrice end
    end
    if shutterSide and wantLocked ~= lockedNow then
      pcall(redstone.setOutput, shutterSide, not wantLocked)
    end
    if wantLocked ~= lockedNow then
      lockedNow = wantLocked
      if wantLocked then
        log("till shut")
      else
        log("till open for %s at %s", tostring(who), LEDGER.money(amount))
        -- tell their terminal, so it can stop saying "go and pay" and start
        -- saying "pay now" - the difference between a hint and an instruction
        local p = present[who]
        if p and p.client then
          pcall(rednet.send, p.client, F.tillOpen(who, amount, nonce()), F.PROTO)
        end
      end
    end
    sleep(0.4)
  end
end

local function till()
  while true do
    local ev, side = os.pullEvent("redstone")
    if redstone.getInput(DEPOSIT_SIDE) then
      -- whoever the till was open for is whose money this is: the same
      -- answer that set the price, so the two can never disagree
      local who, amount, howKnown = tillOwner()
      if who then
        local bal = post(who, "credit", amount, howKnown)
        log("%s paid %s (%s) - balance %s", who, LEDGER.money(amount), howKnown, LEDGER.money(bal or 0))
        local p = present[who]
        if p and p.client then
          pcall(rednet.send, p.client, F.creditOk(who, amount, bal or 0, nonce()), F.PROTO)
        end
        armed = nil
        pricedAt = nil                 -- re-price for the next customer
      else
        log("payment with no owner - credit by hand (ops credit <who> <spurs>)")
      end
      sleep(0.5)      -- one pulse is one payment
    end
  end
end

-- A shuttle has come free. Take whoever the queue says, from where the shuttle
-- actually is - which is why this runs on release and not when someone asks.
local function serveQueue()
  while true do
    if #waiting > 0 then
      for _, e in ipairs(QUEUE.expire(waiting, os.clock())) do
        log("%s waited too long and was dropped", tostring(e.who))
        if e.client then
          pcall(rednet.send, e.client, F.ack("j-none", "ops", false, "nobody came free", nonce()), F.PROTO)
        end
      end
    end
    if #waiting > 0 then
      -- the first free drone takes the pick made from where IT is
      for id, f in pairs(fleet) do
        if #waiting > 0 and (F.available(f, os.clock())) then
          local e, i = QUEUE.pick(waiting, { x = f.x, z = f.z })
          if e then
            QUEUE.removeAt(waiting, i)
            local ok, job = dispatch({ v = F.VERSION, type = "taxi.request", nonce = e.nonce,
              pad = e.pad, px = e.px, py = e.py, pz = e.pz, tx = e.tx, tz = e.tz,
              toName = e.toName, who = e.who }, e.client)
            log("%s off the queue -> %s", tostring(e.who), tostring(ok or job))
          end
        end
      end
      -- and everyone still waiting is told where they now stand
      for i, e in ipairs(waiting) do
        if e.client then
          pcall(rednet.send, e.client, F.queued(i, QUEUE.wait(waiting, i, 0, nil), nonce()), F.PROTO)
        end
      end
    end
    sleep(3)
  end
end

-- Where the taxi is, sent to the customer while their job is live. They hold
-- no keys and cannot read telemetry themselves, so this is the only way their
-- terminal can say how far away it is.
local function tracker()
  while true do
    for _, j in pairs(jobs) do
      if type(j) == "table" and j.client and j.state ~= "done" and j.state ~= "failed" then
        local d = fleet[j.drone]
        if d and d.x and d.z then
          pcall(rednet.send, j.client, F.track(j.id, j.drone, d.x, d.z, nil, nonce()), F.PROTO)
        end
      end
    end
    sleep(1)
  end
end

local function watchdog()
  while true do
    local now = os.clock()
    for _, j in pairs(jobs) do
      -- a job that has gone quiet in ANY state. The first real ride got stuck
      -- at "enroute" because the drone's later packets were refused, and its
      -- drone stayed "on a job" long after it had been flown home by hand.
      if type(j) == "table" and j.state ~= "done" and j.state ~= "failed"
         and now - (j.updated or j.at) > JOB_SILENT then
        incident(j.drone, j, "silent " .. JOB_SILENT .. "s mid-job - last seen here")
        finish(j, "nothing heard for " .. JOB_SILENT .. "s")
      end
      if type(j) == "table" and j.state == "assigned" then
        if not j.acked and not j.warned and now - j.at > ACK_WAIT then
          j.warned = true
          log("%s has not answered %s", tostring(j.drone), j.id)
          log("  is its beacon running and updated, and is its key right?")
        end
        if now - j.at > JOB_STUCK then
          j.state = "failed"
          if fleet[j.drone] then fleet[j.drone].job = nil end
          log("gave up on %s - %s is free again", j.id, tostring(j.drone))
          if j.client then
            pcall(rednet.send, j.client, F.state(j.id, j.drone, "failed", "the drone never answered", nonce()), F.PROTO)
          end
        end
      end
    end
    sleep(2)
  end
end

-- ---------------------------------------------------------------- the board --
-- What the operator sees, and what they can do to whatever is selected.
local sel, canvas = 1, nil

-- the fleet as the screen wants it: newest state, sorted by id
local function units()
  local now, out = os.clock(), {}
  for id, f in pairs(fleet) do
    local age = f.seen and (now - f.seen) or 999
    local state = (age > 30 and "LOST") or (age > 5 and "STALE")
                  or (f.docked and "DOCKED" or (f.phase or "FLYING"):upper())
    out[#out + 1] = { id = id, state = state, batt = f.energy, spd = f.spd,
                      job = f.job, x = f.x and math.floor(f.x), z = f.z and math.floor(f.z), age = age }
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

local function liveJobs()
  local n = 0
  for _, j in pairs(jobs) do
    if type(j) == "table" and j.state ~= "done" and j.state ~= "failed" then n = n + 1 end
  end
  return n
end

local function drawBoard()
  local list = units()
  if sel > #list then sel = math.max(1, #list) end
  if not (D and T and UI) then           -- no kit: the old printed board
    term.clear()
    term.setCursorPos(1, 1)
    print(string.format("OPS  %s   %d refused", textutils.formatTime(os.time(), true), rejected))
    board()
    for _, line in ipairs(events) do print(line) end
    return list
  end
  if not canvas then
    -- the kit names colours by role, and only means anything once its
    -- palette is on the screen: without this the board came up in CC's
    -- stock colours, brown text and a bright red bar
    T.apply(term)
    canvas = D.canvas(term.getSize())
  end
  UI.board(T, canvas, {
    units = list, sel = sel, log = events, jobs = liveJobs(), refused = rejected,
    clock = textutils.formatTime(os.time(), true), hails = openToHails,
    till = LEDGER.money(takings), queue = #waiting,
    alert = alerts[#alerts],
    arming = (tillOwner()) or nil,
    shut = lockedNow,
  })
  canvas:flush(term)
  return list
end

local function draw()
  while true do
    drawBoard()
    sleep(1)
  end
end

-- Ask for a line of text over the board, then put the board back.
local function prompt(question)
  term.setBackgroundColour(colours.black)
  term.setTextColour(colours.white)
  term.clear()
  term.setCursorPos(1, 1)
  print(question)
  term.write("> ")
  local said = read()
  canvas = nil                      -- the prompt scribbled over it
  return said
end

local function keys()
  while true do
    local ev, key = os.pullEvent()
    local list = units()
    local who = list[sel] and list[sel].id
    if ev == "key" then
      if key == keys_api.down then sel = math.min(math.max(#list, 1), sel + 1)
      elseif key == keys_api.up then sel = math.max(1, sel - 1)
      elseif key == keys_api.q then return
      elseif key == keys_api.a and #alerts > 0 then
        local a = table.remove(alerts)
        log("acknowledged: %s at %s", a.drone, coords(a.x, a.y, a.z))
      elseif key == keys_api.p and who then
        local sent, why = order(who, F.flyCommand("pads", nonce()))
        log(sent and ("poked %s"):format(who) or ("poke failed: " .. tostring(why)))
      elseif key == keys_api.r and who then
        if fleet[who] then fleet[who].job = nil end
        for _, j in pairs(jobs) do
          if type(j) == "table" and j.drone == who and j.state ~= "done" then j.state = "failed" end
        end
        log("%s freed by hand", who)
      elseif key == keys_api.f and who then
        local line = prompt("fly command for " .. who .. "   (eg ferry home)")
        local argsOk, whyArgs = F.flyArgs(line or "")
        if not argsOk then
          log("not sent: %s", tostring(whyArgs))
        else
          local sent, why = order(who, F.flyCommand(argsOk, nonce()))
          log(sent and ("%s: fly %s"):format(who, argsOk) or ("not sent: " .. tostring(why)))
        end
      end
      drawBoard()
    end
  end
end

parallel.waitForAny(receive, serve, watchdog, tracker, till, lock, serveQueue, draw, keys)
print("ops stopped")
