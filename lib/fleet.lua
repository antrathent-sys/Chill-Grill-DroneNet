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
-- A nonce is "<who>-<counter>" and never repeats for that sender: a customer
-- leaning on the button must not launch two drones (COMMAND.md:139-142).

local F = {}

F.VERSION = 1
F.PROTO = "dronenet"

-- a job walks: assigned -> enroute (flying to the pad) -> waiting (docked at
-- the pad, doors open) -> riding (flying to the destination) -> done. failed
-- ends it from anywhere.
F.STATES = { assigned = true, enroute = true, waiting = true, riding = true, done = true, failed = true }
F.TYPES = { ["taxi.request"] = true, ["job.assign"] = true, ["job.ack"] = true,
            ["job.state"] = true, ["job.go"] = true, ["pad.stats"] = true,
            ["ops.fly"] = true, ["ops.ping"] = true, ["job.track"] = true,
            ["places.ask"] = true, ["places.list"] = true,
            ["account.ask"] = true, ["account.info"] = true,
            ["credit.arm"] = true, ["credit.ok"] = true, ["here"] = true }

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
  elseif m.type == "job.track" then
    if not str(m.job) then return false, "no job id" end
    if not (num(m.x) and num(m.z)) then return false, "no position" end
  elseif m.type == "account.info" then
    if not str(m.who) then return false, "no customer" end
    if not num(m.balance) then return false, "no balance" end
  elseif m.type == "here" then
    if not (num(m.x) and num(m.z)) then return false, "no position" end
    if m.amount ~= nil and not num(m.amount) then return false, "bad amount" end
  elseif m.type == "credit.arm" then
    if not num(m.amount) or m.amount <= 0 then return false, "bad amount" end
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
           tx = dest.x, tz = dest.z, ty = dest.y }
end

function F.assign(job, req)
  return { v = F.VERSION, type = "job.assign", nonce = req.nonce, job = job,
           pad = req.pad, px = req.px, py = req.py, pz = req.pz,
           tx = req.tx, tz = req.tz, ty = req.ty }
end

function F.ack(job, drone, ok, why, nonce)
  return { v = F.VERSION, type = "job.ack", nonce = nonce or (job .. "-ack"),
           job = job, drone = drone, ok = ok and true or false, why = why }
end

function F.state(job, drone, state, detail, nonce)
  return { v = F.VERSION, type = "job.state", nonce = nonce or (job .. "-" .. state),
           job = job, drone = drone, state = state, detail = detail }
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
      out[#out + 1] = string.format("%s:%d:%d", tostring(p.name):gsub("[|:]", ""), math.floor(p.x), math.floor(p.z))
    end
  end
  return table.concat(out, "|")
end

function F.unpackPlaces(text)
  local out = {}
  for chunk in tostring(text or ""):gmatch("[^|]+") do
    local name, x, z = chunk:match("^([^:]+):(-?%d+):(-?%d+)$")
    if name then out[#out + 1] = { name = name, x = tonumber(x), z = tonumber(z) } end
  end
  return out
end

function F.placesAsk(nonce) return { v = F.VERSION, type = "places.ask", nonce = nonce } end
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
    -- a pad: ferry to it and dock. Anywhere else: land beside the customer.
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
F.JOB_HEADER = "id,at,drone,customer,pickup,px,pz,tx,tz,blocks,waited,rode,total,outcome"

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
