-- ledger: what each customer owes, and why.
--
-- An append-only file of lines, one per event, and a balance that is simply
-- their sum. Nothing is ever edited or deleted, so a disputed charge can be
-- read back move by move, and a half-written line at the end of the file is
-- skipped rather than corrupting a balance - which is what you want on a
-- computer that can be switched off mid-write.
--
--   when,who,kind,amount,note
--   1789867493,alex,credit,500,depositor base
--   1789867552,alex,fare,-84,pier to market 1104 blocks
--
-- Amounts are whole SPURS, positive for money in, negative for money out, as
-- Numismatics counts them (lib/fleet.lua has no opinion about money; this
-- module is the only place that does).
--
-- Balances may go negative on purpose. Someone stranded with an empty account
-- is a worse outcome than someone owing a few spurs, and a ride TO the base is
-- always free, so there is always a way home.

local L = {}

L.HEADER = "when,who,kind,amount,note"
L.KINDS = { credit = true, fare = true, refund = true, adjust = true }

local function clean(v) return (tostring(v == nil and "" or v):gsub("[,\r\n]", " ")) end

function L.row(when, who, kind, amount, note)
  return table.concat({ math.floor(when or 0), clean(who), clean(kind),
                        string.format("%d", math.floor(amount or 0)), clean(note) }, ",")
end

-- Read a whole ledger. Bad lines are counted, not guessed at.
function L.parse(text)
  local rows, bad = {}, 0
  for line in tostring(text or ""):gmatch("[^\r\n]+") do
    if line ~= L.HEADER and not line:match("^%s*#") then
      -- the note's comma is REQUIRED, so a line cut off mid-write is rejected
      -- rather than read as a smaller amount: "...,fare,-20,to market" cut
      -- after the 2 would otherwise parse as a fare of -2
      local when, who, kind, amount, note = line:match("^(%-?%d+),([^,]*),([^,]*),(%-?%d+),(.*)$")
      if when and L.KINDS[kind] then
        rows[#rows + 1] = { when = tonumber(when), who = who, kind = kind,
                            amount = tonumber(amount), note = note }
      else
        bad = bad + 1
      end
    end
  end
  return rows, bad
end

-- Everyone's balance, and each person's last movement.
function L.balances(rows)
  local out = {}
  for _, r in ipairs(rows) do
    local a = out[r.who] or { balance = 0, spent = 0, paid = 0, rides = 0, last = 0 }
    a.balance = a.balance + r.amount
    if r.amount < 0 then a.spent = a.spent - r.amount else a.paid = a.paid + r.amount end
    if r.kind == "fare" then a.rides = a.rides + 1 end
    if r.when > a.last then a.last = r.when end
    out[r.who] = a
  end
  return out
end

function L.balanceOf(rows, who)
  local a = L.balances(rows)[who]
  return a and a.balance or 0
end

-- ------------------------------------------------------------------ fares --
-- A tariff is deliberately small: a rate per block, a minimum that covers the
-- climb and the descent (which cost the same whether the leg is 200 blocks or
-- 2000), and the places that are free to travel TO.
L.TARIFF = {
  -- A flat fare, if you want one: every ride costs the same whatever the
  -- distance. Simple to explain and simple to price - a tenth of a cog is 6
  -- spurs, since a cog is 64. Set it and the rate below stops being used.
  flat = 0,             -- spurs a ride (0 = charge by distance instead)

  perBlock = 0.08,      -- spurs a block: a 1,000-block hop is 80, about a cog
  minimum = 20,         -- every ride costs at least this
  freeTo = { home = true },
  freeUnder = 0,        -- blocks: rides shorter than this are free (0 = none)
}

function L.tariff(t)
  local out = {}
  for k, v in pairs(L.TARIFF) do out[k] = v end
  for k, v in pairs(t or {}) do
    if k == "freeTo" and type(v) == "table" then
      local set = {}
      for _, name in ipairs(v) do set[tostring(name):lower()] = true end
      for name, on in pairs(v) do if type(name) == "string" then set[name:lower()] = on and true or nil end end
      out.freeTo = set
    elseif type(v) == type(out[k]) then
      out[k] = v
    end
  end
  return out
end

-- What a ride costs. Returns the fare in spurs and why it is what it is.
function L.fare(blocks, dest, tariff)
  tariff = tariff or L.TARIFF
  blocks = math.max(0, tonumber(blocks) or 0)
  local to = tostring(dest or ""):lower()
  if tariff.freeTo and tariff.freeTo[to] then return 0, "free to " .. to end
  if (tariff.freeUnder or 0) > 0 and blocks < tariff.freeUnder then return 0, "short hop" end
  if (tariff.flat or 0) > 0 then return math.floor(tariff.flat), "flat fare" end
  local raw = blocks * (tariff.perBlock or 0)
  if raw < (tariff.minimum or 0) then return math.floor(tariff.minimum or 0), "minimum fare" end
  return math.floor(raw + 0.5), string.format("%d blocks", math.floor(blocks))
end

-- Spurs are the base unit; people think in cogs (64) and suns (4096).
function L.money(spurs)
  spurs = math.floor(tonumber(spurs) or 0)
  local sign = spurs < 0 and "-" or ""
  local n = math.abs(spurs)
  if n >= 4096 then return string.format("%s%.1f SUN", sign, n / 4096) end
  if n >= 64 then return string.format("%s%.1f COG", sign, n / 64) end
  return string.format("%s%d SPUR", sign, n)
end

return L
