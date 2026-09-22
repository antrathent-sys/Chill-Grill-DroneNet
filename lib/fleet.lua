-- fleet: the shared language for asking a drone to come and fetch someone.
--
-- Three programs speak it: taxipad (a customer terminal standing at a pad),
-- ops (the admin panel at the base) and the listener inside beacon (on the
-- drone). This module is pure - no peripherals, no files, no clock of its own -
-- so all of it is tested on the desktop in tools/test_fleet.lua.
--
-- Two transports, and which one a message takes is a security decision.
--
--   ORDERS (ops -> drone: job.assign, job.go, ops.fly) go by RADIO, SEALED
--   with that drone's own key (lib/seclink.lua, direction BASE_TO_DRONE) on
--   link.CHANNEL. Only the base, holding .fleetkeys, can make one; the counter
--   rises so a copied packet cannot be replayed; the drone opens it with its
--   own .dronekey and ignores anything it cannot open. This replaced a
--   wired-only rule on 2026-09-20: the fleet flies with no cables, so the
--   proof has to travel with the message rather than with the wire.
--
--   REQUESTS and REPORTS (taxi.request, ops.ping, pad.stats, and what a
--   customer's terminal is told back) go as plain rednet on fleet.PROTO. They
--   ask; they never command. ops rate-limits callers and may refuse. The worst
--   a forged one can do is ask for a taxi.
--
-- So the rule that matters still holds: nothing flies on an unauthenticated
-- message, no matter how it arrived.
--
-- Messages (all flat tables, v = fleet.VERSION):
--   taxi.request  [pad] px py pz tx tz [ty] [who] nonce    pad  -> ops
--   job.assign    job [pad] px py pz tx tz [ty] nonce      ops  -> drone
-- The pickup is a place, not necessarily a pad: with a pad name the drone
-- ferries to it and docks, without one it lands in the open at px/pz, which is
-- how someone hails a taxi from where they are standing.
--   job.ack       job drone ok [why] nonce                 drone-> ops, pad
--   job.state     job drone state [detail] nonce           drone-> everyone
--   job.go        job nonce                                pad  -> drone
--   pad.stats     pad rides requests failures lastRide     pad  -> ops
--   ops.fly       args nonce                                ops  -> drone
--   job.queued    place wait nonce                           ops  -> customer
--                 (nobody is free; you are Nth, about `wait` seconds)
--   job.cancel    nonce                                     customer -> ops
--   job.track     job drone x z [eta] nonce                  ops  -> customer
--                 (where the taxi is, a few times a second-ish, so the
--                  terminal can show how far away it is)
--   places.ask    nonce                                     anyone -> ops
--   places.list   places nonce                              ops  -> anyone
--                 (places is "name:x:z|name:x:z|...", the pads ops knows)
--   account.ask   nonce                                     customer -> ops
--   account.info  who balance rides owed nonce               ops -> customer
--   credit.arm    amount nonce                               customer -> ops
--                 (I am about to pay this much at a depositor - watch for it)
--   here          x y z [amount] nonce                      customer -> ops
--                 (my terminal is standing at this spot, right now). The pay
--                 pad works on this alone: whoever is ON the pad when the
--                 depositor fires is who gets the credit, so nothing has to
--                 identify the PLAYER at all - only which account is present.
--   credit.ok     who amount balance nonce                   ops -> customer
--   ops.ping      nonce                                     anyone -> ops
--                 (answered with a job.ack, so a customer can tell "the base
--                  cannot hear me" from "the base has no drone free")
--   unit.stick    job stickers on nonce                      ops  -> drone
--                 (sealed: extend - or with on = false retract - these
--                  stickers, "Create_Sticker_0,Create_Sticker_1"; the loading
--                  station has lifted silos up against them)
--   unit.stuck    job drone ok [why] [detail] nonce         drone-> ops
--   unit.dropped  drone sticker ok x y z nonce              drone-> ops
-- A depot is the computer at a dock that runs its loading station
-- (depot.lua). It is keyed like a drone - id "depot-<dock>" - and everything
-- between it and ops is sealed; it never talks to a drone.
--   depot.hello   depot [load] [step] nonce                  depot-> ops
--                 (awake - the drone's chunk loader woke it; load/step: a
--                  load that was under way when it last stopped)
--   load.start    load drone [items] [stack] nonce           ops  -> depot
--   load.step     load depot step [text] nonce               depot-> ops
--   load.lifted   load depot stickers nonce                  depot-> ops
--                 (the silos are up against the drone: have it stick)
--   load.stuck    load ok [why] nonce                        ops  -> depot
--   load.done     load depot ok [why] [at] sides stickers [counted]
--                 [silo_left] [silo_right] [silo_both] nonce depot-> ops
--                 (silo_* is what was counted in that silo, lib/cargo.pack)
--                 (sealed: a delivery let go of this sticker's silo here;
--                  ok = false means the sticker was still out afterwards)
-- A nonce is "<who>-<counter>" and never repeats for that sender: a customer
-- leaning on the button must not launch two drones (COMMAND.md:139-142).

local F = {}

F.VERSION = 1
F.PROTO = "dronenet"

-- a job walks: assigned -> enroute (flying to the pad) -> waiting (docked at
-- the pad, doors open) -> riding (flying to the destination) -> done. failed
-- ends it from anywhere.
F.STATES = { assigned = true, enroute = true, waiting = true, riding = true, done = true, failed = true,
             relocate = true }     -- could not land: holding above for a new spot
F.TYPES = { ["taxi.request"] = true, ["job.assign"] = true, ["job.ack"] = true,
            ["job.state"] = true, ["job.go"] = true, ["pad.stats"] = true,
            ["ops.fly"] = true, ["ops.ping"] = true, ["job.track"] = true,
            ["places.ask"] = true, ["places.list"] = true,
            ["account.ask"] = true, ["account.info"] = true,
            ["credit.arm"] = true, ["credit.ok"] = true, ["here"] = true,
            ["till.open"] = true, ["job.queued"] = true, ["job.cancel"] = true,
            ["fare.ask"] = true, ["fare.quote"] = true, ["unit.distress"] = true,
            ["job.relocate"] = true, ["unit.stick"] = true, ["unit.stuck"] = true,
            ["unit.dropped"] = true, ["depot.hello"] = true, ["load.start"] = true,
            ["load.step"] = true, ["load.lifted"] = true, ["load.stuck"] = true, ["load.done"] = true }

-- ops.fly carries a fly command line for the admin panel's full control. It is
-- handed to shell.run, so the characters allowed are only the ones a fly
-- command is made of: no quotes, no semicolons, no slashes, nothing that could
-- start a second program. Length is capped so a malformed packet cannot fill
-- the drone's screen.
function F.flyArgs(s)
  if type(s) ~= "string" then return nil, "not a string" end
  s = s:match("^%s*(.-)%s*$")
  if s == "" then return nil, "empty" end
  if #s > 60 then return nil, "too long" end
  if not s:match("^[%w%s%.%-_]+$") then return nil, "only letters, numbers, . - _ and spaces" end
  if s:match("^fly%s") or s == "fly" then return nil, "leave off the word fly" end
  return s
end

local function num(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end
local function str(v) return type(v) == "string" and v ~= "" end

-- Only wired modems, by name. A drone or a pad opens rednet on these and on
-- nothing else, so a wireless message can never even arrive (the rednet_message
-- event does not say which modem carried it, so the check has to be here).
function F.wired(periph)
  local out = {}
  for _, nm in ipairs(periph.getNames()) do
    if periph.getType(nm) == "modem" then
      local ok, wireless = pcall(periph.call, nm, "isWireless")
      if ok and wireless == false then out[#out + 1] = nm end
    end
  end
  table.sort(out)
  return out
end

function F.nonce(who, n) return tostring(who or "?") .. "-" .. tostring(n or 0) end

-- Remember a nonce for a while; true the first time, false for a repeat. The
-- store is a plain table the caller keeps: { [nonce] = whenSeen }.
function F.fresh(store, nonce, now, ttl)
  if not str(nonce) then return false end
  ttl = ttl or 300
  -- only ever age out our own timestamps: a caller that hands in a table it
  -- also uses for something else must not make this throw (ops did exactly
  -- that with its jobs table, 2026-09-20)
  for k, t in pairs(store) do if type(t) == "number" and now - t > ttl then store[k] = nil end end
  if store[nonce] then return false end
  store[nonce] = now
  return true
end

-- One hail per caller per `every` seconds. A pad on the cable is trusted; a
-- pocket in the air is not, and without this one caller could keep the whole
-- fleet in the air by holding a key down.
function F.rateOk(store, caller, now, every)
  caller = tostring(caller or "?")
  local last = store[caller]
  if last and now - last < (every or 20) then return false, "called one " .. math.floor(now - last) .. "s ago" end
  store[caller] = now
  return true
end

function F.check(m)
  if type(m) ~= "table" then return false, "not a table" end
  if m.v ~= F.VERSION then return false, "version " .. tostring(m.v) end
  if not F.TYPES[m.type] then return false, "type " .. tostring(m.type) end
  if not str(m.nonce) then return false, "no nonce" end
  if m.type == "taxi.request" or m.type == "job.assign" then
    if m.pad ~= nil and not str(m.pad) then return false, "bad pad name" end
    if not (num(m.px) and num(m.pz)) then return false, "no pickup position" end
    if not (num(m.tx) and num(m.tz)) then return false, "no destination" end
    if m.ty ~= nil and not num(m.ty) then return false, "bad destination height" end
    if m.type == "job.assign" and not str(m.job) then return false, "no job id" end
  elseif m.type == "job.ack" then
    if not (str(m.job) and str(m.drone)) then return false, "no job or drone" end
    if type(m.ok) ~= "boolean" then return false, "no verdict" end
  elseif m.type == "job.state" then
    if not (str(m.job) and str(m.drone)) then return false, "no job or drone" end
    if not F.STATES[m.state] then return false, "state " .. tostring(m.state) end
  elseif m.type == "job.queued" then
    if not num(m.place) then return false, "no place in the queue" end
  elseif m.type == "job.track" then
    if not str(m.job) then return false, "no job id" end
    if not (num(m.x) and num(m.z)) then return false, "no position" end
  elseif m.type == "fare.ask" then
    if not (num(m.px) and num(m.pz) and num(m.tx) and num(m.tz)) then return false, "no route" end
  elseif m.type == "fare.quote" then
    if not num(m.fare) then return false, "no fare" end
  elseif m.type == "unit.distress" then
    if not (str(m.drone) and str(m.why)) then return false, "no unit or reason" end
  elseif m.type == "job.relocate" then
    if not str(m.job) then return false, "no job id" end
    if not (num(m.px) and num(m.pz)) then return false, "no new spot" end
  elseif m.type == "unit.stick" then
    if not str(m.job) then return false, "no job id" end
    if not (str(m.stickers) and m.stickers:match("^[%w_:%.%-,]+$")) then return false, "bad sticker list" end
    if type(m.on) ~= "boolean" then return false, "extend or retract?" end
  elseif m.type == "depot.hello" then
    if not str(m.depot) then return false, "no depot" end
  elseif m.type == "load.start" then
    if not (str(m.load) and str(m.drone)) then return false, "no load or drone" end
    if m.items ~= nil and not num(m.items) then return false, "bad item count" end
  elseif m.type == "load.step" then
    if not (str(m.load) and str(m.depot) and str(m.step)) then return false, "no load, depot or step" end
  elseif m.type == "load.lifted" then
    if not (str(m.load) and str(m.depot)) then return false, "no load or depot" end
    if not (str(m.stickers) and m.stickers:match("^[%w_:%.%-,]+$")) then return false, "bad sticker list" end
  elseif m.type == "load.stuck" then
    if not str(m.load) then return false, "no load" end
    if type(m.ok) ~= "boolean" then return false, "no verdict" end
  elseif m.type == "load.done" then
    if not (str(m.load) and str(m.depot)) then return false, "no load or depot" end
    if type(m.ok) ~= "boolean" then return false, "no verdict" end
  elseif m.type == "unit.dropped" then
    if not (str(m.drone) and str(m.sticker)) then return false, "no unit or sticker" end
    if type(m.ok) ~= "boolean" then return false, "no verdict" end
  elseif m.type == "unit.stuck" then
    if not (str(m.job) and str(m.drone)) then return false, "no job or drone" end
    if type(m.ok) ~= "boolean" then return false, "no verdict" end
  elseif m.type == "account.info" then
    if not str(m.who) then return false, "no customer" end
    if not num(m.balance) then return false, "no balance" end
  elseif m.type == "here" then
    if not (num(m.x) and num(m.z)) then return false, "no position" end
    if m.amount ~= nil and not num(m.amount) then return false, "bad amount" end
  elseif m.type == "credit.arm" then
    if not num(m.amount) or m.amount <= 0 then return false, "bad amount" end
  elseif m.type == "till.open" then
    if not (str(m.who) and num(m.amount)) then return false, "bad till" end
  elseif m.type == "credit.ok" then
    if not (str(m.who) and num(m.amount) and num(m.balance)) then return false, "bad credit" end
  elseif m.type == "places.list" then
    if type(m.places) ~= "string" then return false, "no places" end
  elseif m.type == "job.go" then
    if not str(m.job) then return false, "no job id" end
  elseif m.type == "ops.fly" then
    local args, why = F.flyArgs(m.args)
    if not args then return false, "args: " .. why end
  elseif m.type == "pad.stats" then
    if not str(m.pad) then return false, "no pad" end
    if not num(m.rides) then return false, "no ride count" end
  end
  return true
end

-- from is where the customer is: a pad record { name, x, y, z } if they are
-- standing on one, or just { x, y, z } if they hailed from anywhere else.
function F.request(from, dest, nonce, who)
  return { v = F.VERSION, type = "taxi.request", nonce = nonce, who = who,
           pad = from.name, px = from.x, py = from.y, pz = from.z,
           tx = dest.x, tz = dest.z, ty = dest.y, toName = dest.name }
end

-- How close typed coordinates have to be to a known place to count as it.
F.PLACE_NEAR = 16

--- Which known place a request means, if any. By name first, and then the
-- place's own record wins over whatever the terminal sent, so a name cannot
-- be borrowed for somewhere else (a free ride "home" to the far side of the
-- map). Failing that, coordinates within `near` blocks of a place count as
-- that place, so typing the base's coordinates is still a ride home. nil
-- means open ground.
function F.placeFor(list, name, x, z, near)
  near = near or F.PLACE_NEAR
  if str(name) then
    local want = name:lower()
    for _, p in ipairs(list or {}) do if p.name == want then return p end end
  end
  if not (num(x) and num(z)) then return nil end
  local best, bd
  for _, p in ipairs(list or {}) do
    local d = math.sqrt((p.x - x) ^ 2 + (p.z - z) ^ 2)
    if d <= near and (not bd or d < bd) then best, bd = p, d end
  end
  return best
end

function F.assign(job, req)
  return { v = F.VERSION, type = "job.assign", nonce = req.nonce, job = job,
           pad = req.pad, px = req.px, py = req.py, pz = req.pz,
           tx = req.tx, tz = req.tz, ty = req.ty,
           -- a unit already on station where the customer is: no pickup
           -- flight, they walk to it and press G
           board = req.board and true or nil }
end

--- A new pickup spot for a job whose unit could not land. The customer's
-- terminal sends it to the base; the base sends it on to the unit, sealed.
-- pad names the spot when it is a dock (the unit ferries to it then).
function F.relocate(job, x, y, z, nonce, pad)
  return { v = F.VERSION, type = "job.relocate", nonce = nonce, job = job,
           px = num(x) and math.floor(x) or nil, py = num(y) and math.floor(y) or nil,
           pz = num(z) and math.floor(z) or nil, pad = pad }
end

--- A unit that has gone down: a flight it was ordered to fly failed. Sent
-- sealed by the drone, with where it is, so someone can go and get it.
function F.distress(drone, why, x, y, z, nonce)
  return { v = F.VERSION, type = "unit.distress", nonce = nonce, drone = drone, why = why,
           x = num(x) and math.floor(x) or nil, y = num(y) and math.floor(y) or nil,
           z = num(z) and math.floor(z) or nil }
end

function F.ack(job, drone, ok, why, nonce)
  return { v = F.VERSION, type = "job.ack", nonce = nonce or (job .. "-ack"),
           job = job, drone = drone, ok = ok and true or false, why = why }
end

function F.state(job, drone, state, detail, nonce)
  return { v = F.VERSION, type = "job.state", nonce = nonce or (job .. "-" .. state),
           job = job, drone = drone, state = state, detail = detail }
end

--- The loading station's silos are up against these stickers: extend them
-- (on = false retracts). names is a list of peripheral names on the drone.
function F.stick(job, names, on, nonce)
  return { v = F.VERSION, type = "unit.stick", nonce = nonce, job = job,
           stickers = table.concat(names, ","), on = on ~= false }
end

--- The sticker list out of a unit.stick, as a list of names.
function F.stickers(m)
  local out = {}
  for n in tostring(m and m.stickers or ""):gmatch("[^,]+") do out[#out + 1] = n end
  return out
end

--- The drone's answer: ok when every sticker ended where it was asked to be.
-- detail says what each one reports, for the operator.
function F.stuck(job, drone, ok, why, detail, nonce)
  return { v = F.VERSION, type = "unit.stuck", nonce = nonce, job = job, drone = drone,
           ok = ok and true or false, why = why, detail = detail }
end

--- A silo let go of on a delivery, and where.
function F.dropped(drone, sticker, ok, x, y, z, nonce)
  return { v = F.VERSION, type = "unit.dropped", nonce = nonce, drone = drone, sticker = sticker,
           ok = ok and true or false, x = num(x) and math.floor(x) or nil,
           y = num(y) and math.floor(y) or nil, z = num(z) and math.floor(z) or nil }
end

-- ------------------------------------------------------------- depots ---
function F.depotHello(depot, load, step, nonce)
  return { v = F.VERSION, type = "depot.hello", nonce = nonce, depot = depot, load = load, step = step }
end

function F.loadStart(load, drone, items, stack, nonce)
  return { v = F.VERSION, type = "load.start", nonce = nonce, load = load, drone = drone,
           items = num(items) and math.floor(items) or nil, stack = num(stack) and math.floor(stack) or nil }
end

function F.loadStep(load, depot, step, text, nonce)
  return { v = F.VERSION, type = "load.step", nonce = nonce, load = load, depot = depot, step = step, text = text }
end

function F.loadLifted(load, depot, names, nonce)
  return { v = F.VERSION, type = "load.lifted", nonce = nonce, load = load, depot = depot,
           stickers = table.concat(names, ",") }
end

function F.loadStuck(load, ok, why, nonce)
  return { v = F.VERSION, type = "load.stuck", nonce = nonce, load = load, ok = ok and true or false, why = why }
end

--- The end of a load at a depot. report: sides and stickers (lists), counted
-- (how), and silos { [side] = packed items } - the sealed link carries flat
-- fields only.
function F.loadDone(load, depot, ok, why, at, report, nonce)
  report = report or {}
  local m = { v = F.VERSION, type = "load.done", nonce = nonce, load = load, depot = depot,
              ok = ok and true or false, why = why, at = at, counted = report.counted,
              sides = table.concat(report.sides or {}, ","), stickers = table.concat(report.stickers or {}, ",") }
  for side, packed in pairs(report.silos or {}) do
    if side == "left" or side == "right" or side == "both" then m["silo_" .. side] = packed end
  end
  return m
end

--- A list field ("a,b") back into a list.
function F.list(s)
  local out = {}
  for v in tostring(s or ""):gmatch("[^,]+") do out[#out + 1] = v end
  return out
end

function F.flyCommand(args, nonce)
  return { v = F.VERSION, type = "ops.fly", nonce = nonce, args = args }
end

function F.track(job, drone, x, z, eta, nonce)
  return { v = F.VERSION, type = "job.track", nonce = nonce or (job .. "-t"),
           job = job, drone = drone, x = x, z = z, eta = eta }
end

-- The places a customer can pick from, packed flat because a sealed message
-- cannot carry a table: "name:x:z|name:x:z|..."
function F.packPlaces(list)
  local out = {}
  for _, p in ipairs(list or {}) do
    if type(p) == "table" and p.name and p.x and p.z then
      -- name:x:z, then :y when the place has one - height is where a landing
      -- starts braking, so it travels with the place
      local entry = string.format("%s:%d:%d", tostring(p.name):gsub("[|:]", ""), math.floor(p.x), math.floor(p.z))
      if p.y then entry = entry .. ":" .. math.floor(p.y) end
      out[#out + 1] = entry
    end
  end
  return table.concat(out, "|")
end

function F.unpackPlaces(text)
  local out = {}
  for chunk in tostring(text or ""):gmatch("[^|]+") do
    local name, x, z, y = chunk:match("^([^:]+):(-?%d+):(-?%d+):?(-?%d*)$")
    if name then out[#out + 1] = { name = name, x = tonumber(x), z = tonumber(z), y = tonumber(y) } end
  end
  return out
end

function F.placesAsk(nonce) return { v = F.VERSION, type = "places.ask", nonce = nonce } end

--- What would this ride cost? Asked from the confirm screen, before anyone
-- is charged anything. The base answers with fare.quote, naming this ask's
-- nonce in `re` so the terminal knows which question it answers.
function F.fareAsk(from, dest, nonce)
  return { v = F.VERSION, type = "fare.ask", nonce = nonce, px = from.x, pz = from.z,
           tx = dest.x, tz = dest.z, toName = dest.name }
end

function F.fareQuote(fare, why, nonce, re, near)
  local q = { v = F.VERSION, type = "fare.quote", nonce = nonce, fare = math.floor(fare or 0),
              why = why, re = re }
  -- a free unit already on station near the customer: they can walk to it
  if type(near) == "table" and str(near.unit) then
    q.near, q.nx, q.ny, q.nz, q.nplace = near.unit, near.x, near.y, near.z, near.place
  end
  return q
end

--- An available unit within `within` blocks of x, z, nearest first: the one
-- a customer standing there can simply walk to. Returns id, its record and
-- the distance, or nil.
function F.nearUnit(fleet, x, z, now, within, maxAge)
  if not (num(x) and num(z)) then return nil end
  local best, bestD
  for id, d in pairs(fleet or {}) do
    if (F.available(d, now, maxAge)) and num(d.x) and num(d.z) then
      local dist = math.sqrt((d.x - x) ^ 2 + (d.z - z) ^ 2)
      if dist <= (within or 24) and (not bestD or dist < bestD) then best, bestD = id, dist end
    end
  end
  if best then return best, fleet[best], bestD end
  return nil
end

--- How far a ride really goes, and to which known place: the destination is
-- resolved exactly as dispatch resolves it (F.placeFor), so a quote is worked
-- out on the same distance the charge at the end will be.
function F.quoteBlocks(list, ask)
  local dest = F.placeFor(list, ask.toName, ask.tx, ask.tz)
  local tx, tz = ask.tx, ask.tz
  if dest then tx, tz = dest.x, dest.z end
  return math.sqrt((tx - ask.px) ^ 2 + (tz - ask.pz) ^ 2), dest and dest.name or nil
end
function F.accountAsk(nonce) return { v = F.VERSION, type = "account.ask", nonce = nonce } end

function F.accountInfo(who, balance, rides, nonce, fare)
  return { v = F.VERSION, type = "account.info", nonce = nonce, who = who,
           balance = math.floor(balance or 0), rides = rides or 0, fare = fare }
end

function F.creditArm(amount, nonce)
  return { v = F.VERSION, type = "credit.arm", nonce = nonce, amount = math.floor(amount or 0) }
end

-- "I am standing here": the whole pay-pad mechanism.
function F.here(x, y, z, nonce, amount)
  return { v = F.VERSION, type = "here", nonce = nonce,
           x = math.floor(x or 0), y = y and math.floor(y), z = math.floor(z or 0), amount = amount }
end

-- Which of the terminals reporting themselves is on the pad. Returns the
-- name, or nil and why: two people on one pad is ambiguous, and guessing
-- would put someone else's money on the wrong account.
--   present = { [who] = { x, z, at, amount } }
function F.onPad(present, pad, now, radius, maxAge)
  radius, maxAge = radius or 2, maxAge or 15
  local found, count = nil, 0
  for who, p in pairs(present or {}) do
    if num(p.x) and num(p.z) and (now - (p.at or 0)) <= maxAge then
      local d = math.sqrt((p.x - pad.x) ^ 2 + (p.z - pad.z) ^ 2)
      if d <= radius then
        count = count + 1
        found = { who = who, dist = d, amount = p.amount }
      end
    end
  end
  if count == 1 then return found.who, found.amount end
  if count == 0 then return nil, nil, "nobody on the pad" end
  return nil, nil, count .. " terminals on the pad"
end

-- A name read off a Create Display Link through CC:C Bridge's target block.
-- It is whatever Minecraft would render above the player's head, so it can
-- carry team colours, nicknames and stray spaces - and it is the one thing in
-- this modpack that names a real player to a computer. Anything that is not a
-- plain name is refused rather than turned into an account.
function F.seatName(line)
  if type(line) ~= "string" then return nil, "no reading" end
  local name = line:gsub("\194\167%x", "")          -- strip colour codes
  name = name:match("^%s*(.-)%s*$")
  if name == "" then return nil, "seat empty" end
  if #name > 16 then return nil, "too long for a name" end
  if not name:match("^[%w_]+$") then return nil, "not a plain name" end
  return name
end

function F.queued(place, wait, nonce)
  return { v = F.VERSION, type = "job.queued", nonce = nonce,
           place = math.floor(place or 0), wait = math.floor(wait or 0) }
end

function F.cancel(nonce) return { v = F.VERSION, type = "job.cancel", nonce = nonce } end

function F.tillOpen(who, amount, nonce)
  return { v = F.VERSION, type = "till.open", nonce = nonce, who = who,
           amount = math.floor(amount or 0) }
end

function F.creditOk(who, amount, balance, nonce)
  return { v = F.VERSION, type = "credit.ok", nonce = nonce, who = who,
           amount = math.floor(amount or 0), balance = math.floor(balance or 0) }
end
function F.placesList(list, nonce)
  return { v = F.VERSION, type = "places.list", nonce = nonce, places = F.packPlaces(list) }
end

function F.ping(nonce)
  return { v = F.VERSION, type = "ops.ping", nonce = nonce }
end

function F.go(job, nonce)
  return { v = F.VERSION, type = "job.go", nonce = nonce or (job .. "-go"), job = job }
end

-- A drone may take a job when the base has heard from it recently, it says it
-- is docked, and it is not already on one. "available" is the default pick:
-- ops send <name> overrides it, ops send any takes the nearest of these.
function F.available(d, now, maxAge)
  if type(d) ~= "table" then return false, "unknown" end
  if d.job then return false, "on job " .. tostring(d.job) end
  if not num(d.seen) or now - d.seen > (maxAge or 15) then return false, "no telemetry" end
  if d.phase == "sos" then return false, "in distress" end
  if not d.docked then return false, "flying" end
  return true
end

-- Pick the docked drone nearest the pad. fleet is { [id] = { seen, docked, job,
-- x, z } }, as ops builds it from telemetry.
function F.pick(fleet, pad, now, maxAge)
  local best, bestD, why
  for id, d in pairs(fleet) do
    local ok, reason = F.available(d, now, maxAge)
    if ok then
      local dist = (num(d.x) and num(pad.x)) and math.sqrt((d.x - pad.x) ^ 2 + (d.z - pad.z) ^ 2) or 1e9
      if not best or dist < bestD then best, bestD = id, dist end
    else
      why = why or (id .. ": " .. reason)
    end
  end
  if best then return best, bestD end
  return nil, why or "no drones have called in"
end

-- The two flights a taxi job is made of, as fly command lines. Nothing here
-- runs them: beacon does, and only while it is already running, because fly
-- must never start itself (startup.lua:45-47).
-- fly land takes <x> <z>, or <x> <y> <z> where y is the GROUND at the far end
-- (fly.lua:1852-1874) - so a height always goes in the MIDDLE, never last.
local function landAt(x, y, z)
  if num(y) then return string.format("land %d %d %d", math.floor(x), math.floor(y), math.floor(z)) end
  return string.format("land %d %d", math.floor(x), math.floor(z))
end

function F.legCommand(step, m)
  if step == "pickup" then
    if m.board then return nil end        -- already where the customer is
    -- A named DOCK: ferry to it and latch on. Anywhere else - a landing pad
    -- included - land beside the customer. ops only names docks, so a job
    -- never asks a craft to latch onto a field.
    if str(m.pad) then return "ferry " .. m.pad end
    if num(m.px) and num(m.pz) then return landAt(m.px, m.py, m.pz) end
    return nil
  end
  if step == "ride" then
    if not (num(m.tx) and num(m.tz)) then return nil end
    return landAt(m.tx, m.ty, m.tz)
  end
  if step == "home" then return "ferry home" end
  return nil
end

-- ------------------------------------------------------------- job records --
-- One finished job, one CSV line, appended to a file on the base. CSV rather
-- than lib/db.lua on purpose: these are facts that never change once written,
-- the interesting questions (rides an hour, how long people waited, which
-- places earn) are all sums over rows, and `upload joblog.csv` puts it in the
-- repo where it can be read with a spreadsheet or a script. A key/value store
-- would only make that harder.
-- `fare` is what the ride actually earned, in spurs. It is on the ride record
-- and not only in the ledger because the interesting question later is what a
-- day WOULD have earned at a different price, and that needs the distance and
-- the fare on the same line.
F.JOB_HEADER = "id,at,drone,customer,pickup,px,pz,tx,tz,blocks,waited,rode,total,fare,outcome"

local function csvSafe(v)
  return (tostring(v == nil and "" or v):gsub("[,\r\n]", " "))
end

-- j is the job record ops keeps; secs are its own clock, so the row carries
-- both the wall time (for reading) and the durations (for adding up).
function F.jobRow(j, at)
  return table.concat({
    csvSafe(j.id), csvSafe(at or 0), csvSafe(j.drone), csvSafe(j.who or j.client or ""),
    csvSafe(j.pad or ""), csvSafe(j.px or ""), csvSafe(j.pz or ""),
    csvSafe(j.tx or ""), csvSafe(j.tz or ""),
    string.format("%d", math.floor(j.blocks or 0)),
    string.format("%.1f", j.waited or 0),      -- from assigned to the customer aboard
    string.format("%.1f", j.rode or 0),        -- from aboard to landed
    string.format("%.1f", j.total or 0),       -- assigned to free again
    string.format("%d", math.floor(j.fare or 0)),
    csvSafe(j.outcome or j.state or "?"),
  }, ",")
end

-- Read rows back for `ops jobs`: a list of tables, newest last.
function F.jobRows(text)
  local out = {}
  local keys
  for line in tostring(text or ""):gmatch("[^\r\n]+") do
    local cells = {}
    for cell in (line .. ","):gmatch("([^,]*),") do cells[#cells + 1] = cell end
    if not keys then
      if cells[1] == "id" then keys = cells end
    elseif #cells >= 4 then
      local row = {}
      for i, k in ipairs(keys or {}) do row[k] = cells[i] end
      out[#out + 1] = row
    end
  end
  return out
end

-- What the operator actually wants to know, from those rows.
function F.jobSummary(rows)
  local n, done, blocks, waited, rode = 0, 0, 0, 0, 0
  local byPlace = {}
  for _, r in ipairs(rows) do
    n = n + 1
    if r.outcome == "done" then done = done + 1 end
    blocks = blocks + (tonumber(r.blocks) or 0)
    waited = waited + (tonumber(r.waited) or 0)
    rode = rode + (tonumber(r.rode) or 0)
    local where = (r.pickup ~= "" and r.pickup) or "open ground"
    byPlace[where] = (byPlace[where] or 0) + 1
  end
  return { jobs = n, done = done, failed = n - done, blocks = math.floor(blocks),
           avgWait = n > 0 and (waited / n) or 0, avgRide = n > 0 and (rode / n) or 0,
           byPlace = byPlace }
end

function F.newStats(pad)
  return { pad = pad, requests = 0, rides = 0, failures = 0, lastRide = nil, blocks = 0 }
end

-- One place that counts, so the pad and ops agree on what a ride is: a request
-- is every button press that got as far as a drone being asked for; a ride is
-- one that actually carried someone; blocks is pad-to-destination distance.
function F.record(st, event, info)
  info = info or {}
  if event == "request" then st.requests = (st.requests or 0) + 1
  elseif event == "ride" then
    st.rides = (st.rides or 0) + 1
    st.lastRide = info.at
    st.blocks = (st.blocks or 0) + (num(info.blocks) and math.floor(info.blocks) or 0)
  elseif event == "failure" then st.failures = (st.failures or 0) + 1
  else return false, "unknown event " .. tostring(event) end
  return true
end

function F.statsMessage(st, nonce)
  return { v = F.VERSION, type = "pad.stats", nonce = nonce or (tostring(st.pad) .. "-stats"),
           pad = st.pad, rides = st.rides or 0, requests = st.requests or 0,
           failures = st.failures or 0, lastRide = st.lastRide, blocks = st.blocks or 0 }
end

function F.statsText(st)
  return string.format("%s: %d rides of %d asked, %d failed, %d blocks flown",
    tostring(st.pad), st.rides or 0, st.requests or 0, st.failures or 0, st.blocks or 0)
end

function F.serialiseStats(st)
  return string.format(
    "-- taxi pad usage, written by taxipad. Safe to delete; the counters restart.\nreturn {\n" ..
    "  pad = %q,\n  requests = %d,\n  rides = %d,\n  failures = %d,\n  blocks = %d,\n  lastRide = %s,\n}\n",
    tostring(st.pad), st.requests or 0, st.rides or 0, st.failures or 0, st.blocks or 0,
    st.lastRide and string.format("%d", st.lastRide) or "nil")
end

function F.loadStats(path, fsys, pad)
  if not (fsys and fsys.exists and fsys.exists(path)) then return F.newStats(pad) end
  local h = fsys.open(path, "r")
  if not h then return F.newStats(pad) end
  local text = h.readAll() or ""
  h.close()
  local chunk = (loadstring or load)(text, "padstats")
  if chunk and setfenv then setfenv(chunk, {}) end
  local ok, t = false, nil
  if chunk then ok, t = pcall(chunk) end
  if not (ok and type(t) == "table") then return F.newStats(pad) end
  local st = F.newStats(pad or t.pad)
  st.requests, st.rides = tonumber(t.requests) or 0, tonumber(t.rides) or 0
  st.failures, st.blocks = tonumber(t.failures) or 0, tonumber(t.blocks) or 0
  st.lastRide = tonumber(t.lastRide)
  return st
end

function F.saveStats(path, st, fsys)
  local h = fsys.open(path, "w")
  if not h then return false, "cannot write " .. tostring(path) end
  h.write(F.serialiseStats(st))
  h.close()
  return true
end

return F
