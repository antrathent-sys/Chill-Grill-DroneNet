-- tariff: what a shuttle ride costs. Copy to tariff.lua on the BASE computer
-- (ops reads it at start) and edit. Amounts are in SPURS: 64 to a cog, 4096 to
-- a sun. Every value is optional; anything missing keeps the default in
-- lib/ledger.lua.
return {
  -- The rate. A 1,000-block hop at 0.08 costs 80 spurs, about a cog and a
  -- quarter. Flights measured on 2026-09-20 average 2,140 blocks a minute of
  -- cruise, so this is roughly 5 cogs for a minute in the air.
  perBlock = 0.08,

  -- Every ride costs at least this, because the climb and the descent take
  -- the same 40-60 seconds whether the leg is 200 blocks or 2,000.
  minimum = 20,

  -- Places that are free to travel TO. A ride home is always free, so an
  -- empty account can never strand anyone.
  freeTo = { "home" },

  -- Rides shorter than this are free. 0 turns it off.
  freeUnder = 0,
}
