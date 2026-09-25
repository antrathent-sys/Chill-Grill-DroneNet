-- queue: the line of people waiting for a shuttle.
--
-- The whole thing in four sentences, which is also how to explain it to a
-- customer:
--
--   1. Everyone waits in one line, in the order they asked.
--   2. When a shuttle comes free it takes the person who has waited longest -
--      unless someone in the next two is much closer, in which case it takes
--      them instead, and nobody can be passed over more than twice.
--   3. Someone stranded with no credit, heading home, goes to the front.
--   4. After dropping you off, the shuttle goes straight to the next person
--      rather than flying home empty.
--
-- Pure: no peripherals, no clock of its own, no files. ops keeps the list and
-- calls these; tools/run_queue_test.py proves the rules.

local Q = {}

Q.LOOK = 3          -- how far down the line a free shuttle may look
Q.SKIPS = 2         -- how many times one request may be passed over
Q.TTL = 600         -- seconds before an unanswered request is dropped
-- A terminal that says "still waiting" (job.wait) every few seconds and then
-- stops has gone - closed, flat, out of range - and leaves the line after
-- this long. One that never said it (a pass not updated yet) keeps TTL.
Q.ALIVE = 45

-- Flight time, from the measured numbers: 2,140 blocks a minute of cruise,
-- plus the climb, descent and settle that every flight pays whatever its
-- length (34 flights, 2026-09-20).
Q.CRUISE = 2140 / 60
Q.OVERHEAD = 50

function Q.flightTime(blocks)
  return Q.OVERHEAD + math.max(0, blocks or 0) / Q.CRUISE
end

-- req = { who, nonce, px, pz, tx, tz, at, client, priority, skips }
function Q.add(list, req)
  for _, e in ipairs(list) do
    if e.who and e.who == req.who then return nil, "already waiting" end
  end
  req.skips = 0
  list[#list + 1] = req
  return #list
end

function Q.removeAt(list, i)
  return table.remove(list, i)
end

function Q.removeWho(list, who)
  for i, e in ipairs(list) do
    if e.who == who then return table.remove(list, i) end
  end
  return nil
end

--- The entry a terminal made: by the customer's name when the request was
-- sealed, else by the computer that asked. A name merely written in a message
-- is never enough to reach someone else's place in the line.
function Q.find(list, who, client)
  for i, e in ipairs(list) do
    if who ~= nil and e.who == who then return i, e end
    if who == nil and client ~= nil and e.client == client then return i, e end
  end
  return nil
end

function Q.removeFor(list, who, client)
  local i = Q.find(list, who, client)
  if i then return table.remove(list, i) end
  return nil
end

--- A terminal saying it is still there.
function Q.alive(list, who, client, now)
  local _, e = Q.find(list, who, client)
  if e then e.seen, e.alive = now, true end
  return e
end

function Q.position(list, who)
  for i, e in ipairs(list) do if e.who == who then return i end end
  return nil
end

-- Drop requests nobody ever answered, so a queue cannot grow for ever, and
-- anyone whose terminal has stopped saying it is still there. Each dropped
-- entry says why: "ttl" or "quiet".
function Q.expire(list, now, ttl, alive)
  local gone = {}
  for i = #list, 1, -1 do
    local e = list[i]
    if e.alive and now - (e.seen or e.at or 0) > (alive or Q.ALIVE) then
      e.gone = "quiet"
      gone[#gone + 1] = table.remove(list, i)
    elseif now - (e.at or 0) > (ttl or Q.TTL) then
      e.gone = "ttl"
      gone[#gone + 1] = table.remove(list, i)
    end
  end
  return gone
end

-- Who a free shuttle should take. `from` is where that shuttle is now.
-- Returns the entry and its index, or nil when the line is empty.
function Q.pick(list, from, look)
  if #list == 0 then return nil end
  -- anyone stranded goes first, oldest of them
  for i, e in ipairs(list) do
    if e.priority then return e, i end
  end
  look = math.min(look or Q.LOOK, #list)
  -- ...and nobody who has been passed over too often may be passed again
  for i = 1, look do
    if (list[i].skips or 0) >= Q.SKIPS then return list[i], i end
  end
  local best, bestI, bestD = list[1], 1, nil
  if from and from.x and from.z then
    for i = 1, look do
      local e = list[i]
      local d = math.sqrt(((e.px or 0) - from.x) ^ 2 + ((e.pz or 0) - from.z) ^ 2)
      if not bestD or d < bestD then best, bestI, bestD = e, i, d end
    end
  end
  -- everyone the shuttle passed over has been passed over once more
  for i = 1, look do
    if i ~= bestI then list[i].skips = (list[i].skips or 0) + 1 end
  end
  return best, bestI, bestD
end

-- What to tell someone waiting: how long until a shuttle reaches THEM.
--   busy   seconds the working shuttle still needs to finish what it is doing
--   from   where that shuttle will be when it is free
-- With several shuttles, ops passes the soonest-free one; the arithmetic is
-- the same.
function Q.wait(list, index, busy, from)
  local secs = math.max(0, busy or 0)
  local at = from
  for i = 1, math.min(index, #list) do
    local e = list[i]
    local blocks = (at and at.x) and math.sqrt(((e.px or 0) - at.x) ^ 2 + ((e.pz or 0) - at.z) ^ 2) or 0
    secs = secs + Q.flightTime(blocks)
    if i < index then
      -- the shuttle in front of you has to carry them there first
      local ride = math.sqrt(((e.tx or e.px or 0) - (e.px or 0)) ^ 2 + ((e.tz or e.pz or 0) - (e.pz or 0)) ^ 2)
      secs = secs + Q.flightTime(ride) + 30      -- and they take a moment to board
      at = { x = e.tx or e.px, z = e.tz or e.pz }
    end
  end
  return math.floor(secs)
end

return Q
