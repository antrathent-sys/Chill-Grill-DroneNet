-- Desktop tests for lib/watch.lua: the base's read-only feed - relayed
-- packets keep their drone's id, and the summary of jobs, queue and places
-- survives sealing and parsing.
local DIR = ...
local pass, fail = 0, 0
local function check(n, c, d)
  if c then pass = pass + 1 print("  ok   " .. n)
  else fail = fail + 1 print("  FAIL " .. n .. (d and ("  " .. tostring(d)) or "")) end
end

dofile(DIR .. "/cc_shim.lua")
local S = dofile(DIR .. "/../lib/seclink.lua")
S.ROOT = DIR .. "/../"
local W = dofile(DIR .. "/../lib/watch.lua")
local KEY = S.parseKey("0f0e0d0c0b0a09080706050403020100f0e0d0c0b0a090807060504030201000")
local DRONEKEY = S.parseKey("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")

print("a relayed packet keeps its drone")
local tlm = { v = 1, type = "tlm", id = "drone-1", seq = 4, t = 1, phase = "cruise", x = 10, y = 350, z = -20,
              mode = "linger", wait = 412 }
local tx = S.sender(KEY, "screens", S.DIR.BASE_TO_WATCH, nil)
local rx = S.receiver()
local got = rx.open(tx.seal(W.wrap(tlm)), function(id) return id == "screens" and KEY or nil end, S.DIR.BASE_TO_WATCH)
check("it opens with the watcher's key", got ~= nil)
check("opening stamps the watcher's name on id...", got and got.id == "screens")
W.unwrap(got)
check("...and unwrap puts the drone's back", got and got.id == "drone-1" and got.unit == nil, got and got.id)
check("every field survives, the wait on the pad too", got and got.x == 10 and got.phase == "cruise" and got.wait == 412)
local rx2 = S.receiver()
check("a drone's key cannot open it", rx2.open(tx.seal(W.wrap(tlm)), function() return DRONEKEY end, S.DIR.BASE_TO_WATCH) == nil)
local rx3 = S.receiver()
check("nor does it pass for a drone's packet to the base",
  rx3.open(tx.seal(W.wrap(tlm)), function() return KEY end, S.DIR.DRONE_TO_BASE) == nil)

print("the summary")
local jobs = {
  ["j-1727000042-drone-1"] = { id = "j-1727000042-drone-1", drone = "drone-1", state = "riding", who = "alex",
                               pad = "rules", toName = "market", at = 50 },
  ["j-1727000001-drone-2"] = { id = "j-1727000001-drone-2", drone = "drone-2", state = "done", who = "sam",
                               pad = "farm", toName = "home", at = 10, updated = 95 },
  ["j-1727000000-drone-2"] = { id = "j-1727000000-drone-2", drone = "drone-2", state = "done", who = "old",
                               pad = "farm", toName = "home", at = 5, updated = 20 },
  ["j-1727000009-drone-3"] = { id = "j-1727000009-drone-3", drone = "drone-3", state = "failed", who = "x", at = 60 },
}
local places = { { name = "home", x = 1892, y = 91, z = 365, kind = "dock" }, { name = "rules", x = -40, y = 70, z = 812, kind = "pad" } }
local sum = W.summary(jobs, 2, 13, places, 100)
local sealed = tx.seal(sum)
check("it is flat enough to seal", sealed ~= nil)
local back = W.parse(W.unwrap(rx.open(sealed, function(id) return id == "screens" and KEY or nil end, S.DIR.BASE_TO_WATCH)))
check("and parses back", back ~= nil and back.queue == 2 and back.done == 13)
check("open jobs, and one finished a moment ago; not an old one, not a failed one", back and #back.jobs == 2,
  back and #back.jobs)
local j1 = back and W.jobFor(back, "DRONE-1")
check("a unit's job, found by its id in any case", j1 and j1.who == "alex" and j1.from == "rules" and j1.to == "market")
check("riding is the FLY stage, with a short code", j1 and j1.stage == 3 and j1.code == "J-0042", j1 and j1.code)
local j2 = back and W.jobFor(back, "drone-2")
check("just finished is DRP", j2 and j2.stage == 4)
check("places come along, so a watcher needs no pads.lua", back and #back.places == 2 and back.places[2].name == "rules"
  and back.places[2].x == -40 and back.places[2].z == 812 and back.places[2].kind == "pad")
check("nobody's job for a unit with none", back and W.jobFor(back, "drone-9") == nil)

print("names that would break the lists")
local odd = W.summary({ a = { id = "j-1-drone-1", drone = "drone-1", state = "enroute", who = "a|b;c:d", pad = "x;y",
                              toName = "m|n", at = 1 } }, 0, 0, { { name = "p:q;r", x = 1, z = 2 } }, 1)
local o = W.parse(odd)
check("separators in names are blanked, not trusted", o and #o.jobs == 1 and o.jobs[1].who == "a b c d"
  and o.jobs[1].from == "x y" and o.jobs[1].to == "m n" and #o.places == 1, o and o.jobs[1] and o.jobs[1].who)
check("a summary of the wrong version is not read", W.parse({ type = "ops", v = 99 }) == nil)
check("nor anything that is not one", W.parse({ type = "tlm", v = 1 }) == nil and W.parse(nil) == nil)

print("size")
local many = {}
for i = 1, 40 do
  many["j" .. i] = { id = "j-17270000" .. string.format("%02d", i) .. "-drone-1", drone = "drone-1", state = "assigned",
                     who = string.rep("n", 30), pad = string.rep("p", 30), toName = string.rep("t", 30), at = i }
end
local manyPlaces = {}
for i = 1, 80 do manyPlaces[i] = { name = string.rep("q", 30) .. i, x = 10000 * i, z = -10000 * i } end
local big = W.summary(many, 99, 99999, manyPlaces, 1)
local bigEnv = tx.seal(big)
check("40 jobs and 80 places still seal (capped at 8 and 40)", bigEnv ~= nil and #W.parse(big).jobs == 8
  and #W.parse(big).places == 40)

print("admin trips in the summary")
local st = W.summary({}, 0, 0, {}, 1, { "T-3|drone-1|stopped|1/2|rules|alex", "T-2|drone-2|done|2/2|home|alex" })
local sp = W.parse(st)
check("they come back as trips", sp and #sp.trips == 2 and sp.trips[1].id == "T-3" and sp.trips[1].drone == "drone-1"
  and sp.trips[1].state == "stopped" and sp.trips[1].leg == "1/2" and sp.trips[1].stop == "rules" and sp.trips[1].who == "alex")
check("a summary without them still parses", #W.parse(W.summary({}, 0, 0, {}, 1)).trips == 0)

print("")
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then error("watch tests failed", 0) end
