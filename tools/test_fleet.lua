local DIR = ...
local pass, fail = 0, 0
local function check(n, c, d)
  if c then pass = pass + 1 print("  ok   " .. n)
  else fail = fail + 1 print("  FAIL " .. n .. (d and ("  " .. tostring(d)) or "")) end
end

local F = dofile(DIR .. "/../lib/fleet.lua")

local PAD = { name = "pier", x = 100, y = 70, z = -50 }
local DEST = { x = 1200, z = 340 }

print("messages")
local req = F.request(PAD, DEST, F.nonce("pier", 1), "alex")
check("a request carries the pad and the destination",
  req.pad == "pier" and req.px == 100 and req.tx == 1200 and req.tz == 340, req.pad)
check("and passes its own check", (F.check(req)))
local asg = F.assign("j-1", req)
check("an assignment keeps the request's nonce", asg.nonce == req.nonce and asg.job == "j-1")
check("assignment checks out", (F.check(asg)))
check("ack checks out", (F.check(F.ack("j-1", "drone-1", true))))
check("state checks out", (F.check(F.state("j-1", "drone-1", "enroute"))))
check("go checks out", (F.check(F.go("j-1"))))

print("a bad message is refused, with a reason")
local function why(m) local ok, w = F.check(m) return (not ok) and w or "ACCEPTED" end
check("not a table", why("hello") == "not a table", why("hello"))
check("wrong version", why({ v = 99, type = "job.go", nonce = "a", job = "j" }):match("^version"))
check("unknown type", why({ v = 1, type = "job.explode", nonce = "a" }):match("^type"))
check("no nonce", why({ v = 1, type = "job.go", job = "j" }) == "no nonce")
check("a request with no destination", why({ v = 1, type = "taxi.request", nonce = "a",
  pad = "pier", px = 1, pz = 2 }) == "no destination")
check("a request with no pickup", why({ v = 1, type = "taxi.request", nonce = "a",
  tx = 1, tz = 2 }) == "no pickup position")
check("a state nobody has heard of", why(F.state("j", "d", "dancing")):match("^state"))
check("an ack with no verdict", why({ v = 1, type = "job.ack", nonce = "a", job = "j",
  drone = "drone-1" }) == "no verdict")

print("the admin panel's free-hand fly command")
check("a plain one is fine", F.flyArgs("ferry pier") == "ferry pier")
check("trimmed", F.flyArgs("  land 10 20  ") == "land 10 20")
check("numbers and dots", F.flyArgs("go 100 -50 0.5") == "go 100 -50 0.5")
local function noArgs(s) local a, w = F.flyArgs(s) return (a == nil) and w or "ACCEPTED" end
check("no semicolons", noArgs("land; shutdown"):match("^only"), noArgs("land; shutdown"))
check("no quotes", noArgs([[land "x"]]):match("^only"))
check("no slashes", noArgs("land ../x"):match("^only"))
check("not empty", noArgs("   ") == "empty")
check("not endless", noArgs(string.rep("a", 61)) == "too long")
check("without the word fly", noArgs("fly land 1 2"):match("^leave off"))
check("the message checks out", (F.check(F.flyCommand("ferry pier", "ops-1"))))
local shellish = { v = 1, type = "ops.fly", nonce = "a", args = "land 1 2; shutdown" }
check("a bad one is refused", why(shellish):match("^args:"), why(shellish))
-- (a harmless-but-wrong command like "rm -rf" is only letters and dashes, so
-- it passes the character check and fly itself says it does not know it)

print("a nonce is only good once")
local seen = {}
check("first time", F.fresh(seen, "pier-1", 100))
check("second time, no", not F.fresh(seen, "pier-1", 101))
check("a different nonce is fine", F.fresh(seen, "pier-2", 101))
check("and it is forgotten after the ttl", F.fresh(seen, "pier-1", 100 + 301))
check("an empty nonce is never fresh", not F.fresh(seen, "", 100))

check("a ping checks out", (F.check(F.ping("p-1"))))
local mixed = { ["n-1"] = 100, job = { id = "j-1" } }   -- a store with junk in it
check("ageing nonces steps over anything that is not a timestamp",
  (F.fresh(mixed, "n-2", 500)) and mixed.job ~= nil)

print("where the taxi is, and where a customer can go")
local tr = F.track("j-1", "drone-1", 100.6, -50.2, 14)
check("a track message carries the position", (F.check(tr)) and tr.x == 100.6 and tr.eta == 14)
check("without a position it is refused", why({ v = 1, type = "job.track", nonce = "a", job = "j" }) == "no position")
local packed = F.packPlaces({ { name = "pier", x = 100.7, z = -50.2 }, { name = "depot", x = -12, z = 3 },
                              { name = "bad" }, "nonsense" })
-- floor, so a coordinate always names the block it is in, negatives included
check("places pack flat", packed == "pier:100:-51|depot:-12:3", packed)
local back = F.unpackPlaces(packed)
check("and come back whole", #back == 2 and back[1].name == "pier" and back[1].x == 100
  and back[1].z == -51 and back[2].z == 3)
check("rubbish unpacks to nothing", #F.unpackPlaces("|:|x:y:z|") == 0)
check("an empty list is still a valid message", (F.check(F.placesList({}, "n-1"))))
check("and the ask is too", (F.check(F.placesAsk("n-2"))))
check("a name with a separator in it cannot break the packing",
  F.unpackPlaces(F.packPlaces({ { name = "a:b|c", x = 1, z = 2 } }))[1].name == "abc")

print("the pay pad: who is standing on it")
local PAD = { x = 100, z = -50 }
check("a here message checks out", (F.check(F.here(100, 70, -50, "n-1", 512))))
check("without a position it is refused", why({ v = 1, type = "here", nonce = "a" }) == "no position")
local present = { alex = { x = 100.4, z = -50.2, at = 1000, amount = 512 } }
local who, amount = F.onPad(present, PAD, 1002)
check("one terminal on the pad is that terminal", who == "alex" and amount == 512, tostring(who))
present.sam = { x = 140, z = -50, at = 1002 }
check("someone across the yard does not count", (F.onPad(present, PAD, 1002)) == "alex")
present.sam = { x = 101, z = -51, at = 1002 }
local none, _, whyPad = F.onPad(present, PAD, 1002)
check("two on the pad is refused, not guessed", none == nil and whyPad:match("2 terminals"), whyPad)
present.sam = nil
present.alex.at = 900
none, _, whyPad = F.onPad(present, PAD, 1002)
check("a stale report does not count", none == nil and whyPad:match("nobody"), whyPad)
check("nobody at all says so", select(3, F.onPad({}, PAD, 1002)):match("nobody"))

print("a name read off the seat")
check("a plain name", F.seatName("alex") == "alex")
check("trimmed", F.seatName("  alex  ") == "alex")
check("colour codes stripped", F.seatName("\194\1676alex") == "alex", tostring(F.seatName("\194\1676alex")))
local none, whyName = F.seatName("")
check("an empty seat is not a customer", none == nil and whyName == "seat empty")
check("nothing longer than a name can be", (F.seatName(string.rep("a", 17))) == nil)
check("a decorated nickname is refused", (F.seatName("[VIP] alex")) == nil)
check("and so is nothing at all", (F.seatName(nil)) == nil)

print("one hail per caller at a time")
local rate = {}
check("first hail goes through", (F.rateOk(rate, "pocket-1", 100, 20)))
local rOk, rWhy = F.rateOk(rate, "pocket-1", 105, 20)
check("a second one five seconds later does not", not rOk and rWhy:match("5s ago"), rWhy)
check("someone else is unaffected", (F.rateOk(rate, "pocket-2", 105, 20)))
check("and after the wait it is fine again", (F.rateOk(rate, "pocket-1", 121, 20)))

print("who can take a job")
local now = 1000
check("a docked drone that just called in", (F.available({ seen = now - 1, docked = true }, now)))
local ok, reason = F.available({ seen = now - 1, docked = false }, now)
check("one in the air cannot", not ok and reason == "flying", reason)
ok, reason = F.available({ seen = now - 60, docked = true }, now)
check("one that has gone quiet cannot", not ok and reason == "no telemetry", reason)
ok, reason = F.available({ seen = now, docked = true, job = "j-9" }, now)
check("one already on a job cannot", not ok and reason:match("^on job"), reason)

print("picking one")
local fleet = {
  ["drone-1"] = { seen = now, docked = true, x = 900, z = 0 },
  ["drone-2"] = { seen = now, docked = true, x = 120, z = -40 },
  ["drone-3"] = { seen = now, docked = false, x = 101, z = -50 },
}
local pick, dist = F.pick(fleet, PAD, now)
check("the nearest docked drone wins", pick == "drone-2", pick)
check("and it says how far", dist and dist < 30, dist)
fleet["drone-2"].job = "j-2"
check("busy, so the far one goes", F.pick(fleet, PAD, now) == "drone-1")
local none, whyNot = F.pick({ ["drone-1"] = { seen = now, docked = false } }, PAD, now)
check("nobody free: nil and a reason", none == nil and whyNot:match("flying"), whyNot)
none, whyNot = F.pick({}, PAD, now)
check("an empty fleet says so", none == nil and whyNot:match("called in"), whyNot)

print("the flights a job turns into")
check("pickup ferries to the pad", F.legCommand("pickup", asg) == "ferry pier", F.legCommand("pickup", asg))
check("the ride lands at the destination", F.legCommand("ride", asg) == "land 1200 340", F.legCommand("ride", asg))
-- fly land puts the ground height in the MIDDLE: land <x> <y> <z>
local withY = F.assign("j-2", F.request(PAD, { x = 10, z = 20, y = 90 }, "n-1"))
check("a height goes between x and z, as fly land takes it",
  F.legCommand("ride", withY) == "land 10 90 20", F.legCommand("ride", withY))

print("hailed from anywhere, not just a pad")
local hail = F.request({ x = 812, y = 71, z = -344 }, { x = 1200, z = 340 }, "pocket-1", "alex")
check("a hail carries a pickup and no pad", hail.pad == nil and hail.px == 812 and hail.pz == -344)
check("and it checks out", (F.check(hail)))
local hj = F.assign("j-3", hail)
check("the drone is sent to land by the customer",
  F.legCommand("pickup", hj) == "land 812 71 -344", F.legCommand("pickup", hj))
local noY = F.assign("j-4", F.request({ x = 812, z = -344 }, { x = 1, z = 2 }, "pocket-2"))
check("no ground height known: just x and z",
  F.legCommand("pickup", noY) == "land 812 -344", F.legCommand("pickup", noY))
check("a pad pickup still ferries", F.legCommand("pickup", asg) == "ferry pier")
check("then home", F.legCommand("home", asg) == "ferry home")
check("and nothing else", F.legCommand("teleport", asg) == nil)

print("which place a ride is going to")
local known = { { name = "home", kind = "dock", x = 1892, y = 91, z = 365 },
                { name = "market", kind = "pad", x = 865, y = 70, z = 248 } }
local rq = F.request({ x = 1, y = 2, z = 3 }, { x = 865, z = 248, y = 70, name = "market" }, "n-dest", "alex")
check("a request says where by name as well", rq.toName == "market", rq.toName)
check("found by name", (F.placeFor(known, "Market", 0, 0) or {}).name == "market")
check("a name cannot be borrowed for somewhere else - the place's own record wins",
  F.placeFor(known, "home", 9000, 9000).x == 1892)
check("typed coordinates next to a place are that place", (F.placeFor(known, nil, 1900, 370) or {}).name == "home")
check("typed coordinates as a name are just coordinates",
  (F.placeFor(known, "1900, 370", 1900, 370) or {}).name == "home")
check("open ground is no place", F.placeFor(known, nil, 5000, 5000) == nil)
check("a name nobody knows falls back to where", F.placeFor(known, "narnia", 5000, 5000) == nil)

print("places carry their height")
check("y travels with a place", F.packPlaces({ { name = "home", x = 1, y = 70, z = 2 } }) == "home:1:2:70",
  F.packPlaces({ { name = "home", x = 1, y = 70, z = 2 } }))
check("and comes back", F.unpackPlaces("home:1:2:70")[1].y == 70)
check("a place without one still reads", F.unpackPlaces("home:1:2")[1].y == nil
  and F.unpackPlaces("home:1:2")[1].z == 2)

print("a price before the ride")
local ask = F.fareAsk({ x = 100, z = 200 }, { x = 1900, z = 370, name = "home" }, "n-fare")
check("a fare question is a valid message", (F.check(ask)))
check("and so is the answer", (F.check(F.fareQuote(13, "flat fare", "n-q", "n-fare"))))
check("an answer names the question", F.fareQuote(13, "x", "n-q", "n-fare").re == "n-fare")
check("a question with no route is refused", not F.check({ v = F.VERSION, type = "fare.ask", nonce = "x" }))
local blocks, toName = F.quoteBlocks(known, ask)
check("a quote goes to the place itself, not to what was typed",
  toName == "home" and math.abs(blocks - math.sqrt(1792 ^ 2 + 165 ^ 2)) < 0.01, blocks)
local openBlocks, openName = F.quoteBlocks(known, { px = 0, pz = 0, tx = 300, tz = 400 })
check("open ground is quoted by distance, with no place", openBlocks == 500 and openName == nil)

print("safety")
local fl = {
  ["drone-1"] = { seen = 100, docked = true, x = 1892, z = 365 },
  ["drone-2"] = { seen = 100, docked = true, x = 5000, z = 5000 },
  ["drone-3"] = { seen = 100, docked = false, phase = "sos", x = 1890, z = 366 },
}
local nid, _, ndist = F.nearUnit(fl, 1880, 360, 101, 24)
check("a free unit on station nearby is found", nid == "drone-1" and ndist < 24, tostring(nid))
check("one far away is not", F.nearUnit(fl, 3000, 3000, 101, 24) == nil)
check("a unit in distress is never available", not F.available(fl["drone-3"], 101))
local dm = F.distress("drone-1", "pickup flight failed", 1892.7, 91.2, 365.4, "d-1")
check("a distress call is a valid message, with whole coordinates", (F.check(dm)) and dm.x == 1892 and dm.z == 365)
check("and needs a reason", not F.check({ v = F.VERSION, type = "unit.distress", nonce = "x", drone = "drone-1" }))
local nq = F.fareQuote(13, "flat fare", "q-1", "a-1", { unit = "drone-1", x = 1892, y = 91, z = 365, place = "home" })
check("a quote can say a unit is on station nearby", nq.near == "drone-1" and nq.nplace == "home" and (F.check(nq)))
local boardReq = F.request({ x = 1890, y = 92, z = 366 }, { x = 1200, z = 340 }, "b-1")
boardReq.board = true
local ba = F.assign("j-b", boardReq)
check("boarding travels in the order", ba.board == true)
check("and means no pickup flight", F.legCommand("pickup", ba) == nil)
local rel = F.relocate("j-1", 130.6, 64.2, 215.9, "r-1")
check("a new spot is a valid message, in whole blocks", (F.check(rel)) and rel.px == 130 and rel.pz == 215)
check("holding above is a job state", (F.check(F.state("j-1", "drone-1", "relocate", "held", "s-1"))))

print("what a finished job leaves behind")
local job = { id = "j-7", drone = "drone-1", who = "hail-41", pad = "pier", px = 100, pz = -50,
              tx = 1200, tz = 340, blocks = 1104.7, waited = 62.4, rode = 48.25, total = 190,
              outcome = "done" }
job.fare = 6
local row = F.jobRow(job, 1789867493)
check("one line, in the header order", row ==
  "j-7,1789867493,drone-1,hail-41,pier,100,-50,1200,340,1104,62.4,48.2,190.0,6,done", row)
check("a ride nobody was charged for records a zero fare",
  F.jobRow({ id = "j-9", outcome = "done" }, 1):match(",0,done$") ~= nil, F.jobRow({ id = "j-9" }, 1))
check("a comma in a name cannot break the file",
  F.jobRow({ id = "j,8", drone = "d", outcome = "done" }, 1):match("^j 8,"), F.jobRow({ id = "j,8" }, 1))
local rows = F.jobRows(F.JOB_HEADER .. "\n" .. row .. "\n" .. F.jobRow(
  { id = "j-8", drone = "drone-1", pad = "", blocks = 400, waited = 20, rode = 30, outcome = "failed" }, 2))
check("and it reads back", #rows == 2 and rows[1].id == "j-7" and rows[2].outcome == "failed")
check("rubbish lines are skipped", #F.jobRows("not,a,header\nnor this") == 0)
local sum = F.jobSummary(rows)
check("summed: two jobs, one done", sum.jobs == 2 and sum.done == 1 and sum.failed == 1)
check("blocks added up", sum.blocks == 1504, sum.blocks)
check("average wait", math.abs(sum.avgWait - 41.2) < 0.1, sum.avgWait)
check("counted by pickup place", sum.byPlace["pier"] == 1 and sum.byPlace["open ground"] == 1)

print("pad usage")
local st = F.newStats("pier")
F.record(st, "request")
F.record(st, "request")
F.record(st, "ride", { at = 1234, blocks = 1102.7 })
F.record(st, "failure")
check("counts requests", st.requests == 2)
check("counts rides", st.rides == 1 and st.lastRide == 1234)
check("counts blocks, whole ones", st.blocks == 1102, st.blocks)
check("counts failures", st.failures == 1)
local okE, whyE = F.record(st, "elevenses")
check("an event it does not know is refused", not okE and whyE:match("elevenses"), whyE)
check("the text reads plainly", F.statsText(st) == "pier: 1 rides of 2 asked, 1 failed, 1102 blocks flown", F.statsText(st))
check("the report message checks out", (F.check(F.statsMessage(st))))

print("usage survives a reboot")
local files = {}
local disk = {
  exists = function(p) return files[p] ~= nil end,
  open = function(p, mode)
    if mode == "r" then
      if not files[p] then return nil end
      return { readAll = function() return files[p] end, close = function() end }
    end
    local buf = {}
    return { write = function(s) buf[#buf + 1] = s end,
             close = function() files[p] = table.concat(buf) end }
  end,
}
check("saved", (F.saveStats(".padstats", st, disk)))
local back = F.loadStats(".padstats", disk, "pier")
check("rides come back", back.rides == 1 and back.requests == 2 and back.failures == 1)
check("blocks come back", back.blocks == 1102)
check("the last ride comes back", back.lastRide == 1234)
check("a missing file just starts at zero", F.loadStats(".nothing", disk, "pier").rides == 0)
files[".junk"] = "this is not lua at all ]]"
check("so does a damaged one", F.loadStats(".junk", disk, "pier").rides == 0)
files[".evil"] = "os.exit() return { rides = 5 }"
local evil = F.loadStats(".evil", disk, "pier")
check("a stats file cannot reach the world (no os, so it errors out)", evil.rides == 0, evil.rides)

print("only wired modems are listed")
local periph = {
  getNames = function() return { "back", "monitor_1", "top", "left" } end,
  getType = function(n) return (n == "monitor_1") and "monitor" or "modem" end,
  call = function(n, m)
    if m ~= "isWireless" then error("unexpected " .. tostring(m), 0) end
    if n == "top" then return true end            -- ender modem
    if n == "left" then error("rubbish", 0) end   -- a modem that throws
    return false
  end,
}
local wired = F.wired(periph)
check("just the wired one", #wired == 1 and wired[1] == "back", table.concat(wired, ","))

print("what a place is called travels with it")
local withLabel = F.packPlaces({ { name = "home", x = 10, z = -20, y = 64, label = "CINDER HQ" },
                                 { name = "pier", x = 5, z = 6 } })
local back = F.unpackPlaces(withLabel)
check("a place carries its label", back[1].label == "CINDER HQ" and back[1].y == 64 and back[1].x == 10)
check("one without a label is unchanged", back[2].label == nil and back[2].x == 5 and back[2].z == 6)
local noY = F.unpackPlaces(F.packPlaces({ { name = "hq", x = 1, z = 2, label = "HQ" } }))
check("a label with no height keeps the gap", noY[1].label == "HQ" and noY[1].y == nil and noY[1].x == 1)
check("the old four-field form still reads", F.unpackPlaces("home:10:-20:64")[1].y == 64)
check("a label cannot smuggle a separator", F.packPlaces({ { name = "a", x = 1, z = 2, label = "x|y:z" } })
  :find("|") == nil)

print("docked, landed")
check("a drone landed, not latched, still takes the next job",
  (F.available({ seen = 10, landed = true, docked = false, energy = 80 }, 11)) == true)
local okL, whyL = F.available({ seen = 10, landed = true, docked = false, energy = F.LANDED_MIN - 1 }, 11)
check("...but not on a low battery, since nothing is charging it - and says why",
  okL == false and tostring(whyL):find("not charging", 1, true) ~= nil, whyL)
check("a docked one takes it at any battery (it is on the charger)",
  (F.available({ seen = 10, docked = true, energy = 5 }, 11)) == true)
check("one in the air does not", (F.available({ seen = 10, docked = false, landed = false }, 11)) == false)

print("")
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then error("fleet tests failed", 0) end
