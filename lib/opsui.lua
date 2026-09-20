-- opsui: the operator's screen at the base, built out of lib/tui.lua.
--
-- One board, the same look as the customer's terminal: a masthead, the fleet
-- as a list with the selected unit highlighted, what that unit is doing, and
-- the log of everything the base has heard. Whatever the operator can do to
-- the selected unit is on the key bar, and nothing that needs a drone selected
-- is offered when none is.
--
-- It sizes itself: a 51x19 advanced computer gets the fleet and the log side
-- by side, a smaller screen stacks them and drops the log first. Nothing here
-- talks to a peripheral - ops passes in a table and this draws it - so
-- tools/preview_ops.py renders the same board on the desktop.

local M = {}

M.STATES = {         -- what a drone's line says, and how loudly
  DOCKED = "text", IDLE = "faint", FLYING = "accent", CRUISE = "accent",
  BRAKE = "accent", CLIMB = "accent", LAND = "accent", STALE = "warn", LOST = "warn",
}

local function pct(v)
  return (type(v) == "number") and string.format("%3d%%", math.floor(v + 0.5)) or "  --"
end

-- view = {
--   units = { { id, state, batt, spd, job, x, z, age }, ... },  sorted
--   sel = n, log = { "0612 ..." }, jobs = n, refused = n, clock = "06:12",
--   hails = true, keys = { {"F","FLY"}, ... },
-- }
function M.board(T, c, view)
  local w, h = c.w, c.h
  c:clear()
  local y = T.masthead(c, 1, "CONTROL", T.C.text)

  -- a status strip under the masthead: the things that are true right now
  local strip = string.format("%s   %d UNIT%s   %d JOB%s   %s",
    view.clock or "--:--", #view.units, #view.units == 1 and "" or "S",
    view.jobs or 0, (view.jobs or 0) == 1 and "" or "S",
    view.hails and "HAILS OPEN" or "HAILS CLOSED")
  c:text(1, y + 1, strip:sub(1, w), T.C.faint)
  if (view.refused or 0) > 0 then
    c:text(w - 12, y + 1, string.format("%4d REFUSED", view.refused), T.C.warn)
  end

  -- the fleet, and the log under or beside it
  local top = y + 2
  local bottom = h - 1
  local wide = w >= 46
  local fleetW = wide and math.floor(w * 0.52) or w
  local fleetH = wide and (bottom - top + 1) or math.max(5, math.floor((bottom - top + 1) * 0.6))

  local r = T.box(c, 1, top, fleetW, fleetH, "FLEET", T.C.rule, T.C.rule)
  -- one format string for the header and the rows, so the columns cannot
  -- drift apart (they did: STATE and BATT overlapped at 29 columns)
  local inner = fleetW - 3
  local nameW = math.max(6, inner - 14)
  local fmt = "%-" .. nameW .. "s %-7s %s"
  c:text(3, r, string.format(fmt, "UNIT", "STATE", "BATT"), T.C.faint)
  local rows = (top + fleetH - 2) - (r + 1) + 1
  local first = math.max(1, math.min((view.sel or 1) - math.floor(rows / 2), #view.units - rows + 1))
  if first < 1 then first = 1 end
  for i = 0, rows - 1 do
    local u = view.units[first + i]
    if u then
      -- the job marker goes IN the line, not in a right-hand column: a
      -- right-hand value landed on top of the battery figure
      T.row(c, 2, r + 1 + i, fleetW - 2,
            string.format(fmt, tostring(u.id):upper():sub(1, nameW), tostring(u.state):sub(1, 7), pct(u.batt))
              .. (u.job and " *" or ""),
            nil, (first + i) == view.sel)
    end
  end
  if #view.units == 0 then c:text(3, r + 1, "NOTHING HAS CALLED IN", T.C.faint) end

  -- the selected unit, in words
  local sel = view.units[view.sel or 1]
  local logX, logY, logW, logH
  if wide then
    -- share the border column with the fleet box rather than drawing two
    logX, logY = fleetW, top
    logW, logH = w - fleetW + 1, bottom - top + 1
  else
    logX, logY = 1, top + fleetH
    logW, logH = w, bottom - (top + fleetH) + 1
  end

  if wide and sel then
    local d = T.box(c, logX, logY, logW, 6, "UNIT", T.C.rule, T.C.rule)
    c:text(logX + 2, d, tostring(sel.id):upper():sub(1, logW - 4), T.C.text)
    c:text(logX + 2, d + 1, tostring(sel.state):upper():sub(1, logW - 4),
           sel.state == "LOST" and T.C.warn or T.C.accent)
    c:text(logX + 2, d + 2, (sel.x and string.format("%d, %d", sel.x, sel.z) or "POSITION UNKNOWN"):sub(1, logW - 4), T.C.faint)
    c:text(logX + 2, d + 3, (sel.job and ("JOB " .. tostring(sel.job):sub(1, logW - 8)) or "NO JOB"), T.C.faint)
    logY = logY + 6
    logH = logH - 6
  end

  local lr = T.box(c, logX, logY, logW, logH, "LOG", T.C.rule, T.C.rule)
  local log = view.log or {}
  local lrows = (logY + logH - 2) - lr + 1
  local lfirst = math.max(1, #log - lrows + 1)
  for i = lfirst, #log do
    c:text(logX + 2, lr + (i - lfirst), tostring(log[i]):upper():sub(1, logW - 4),
           (i == #log) and T.C.text or T.C.faint)
  end

  T.keys(c, h, view.keys or { { "UP/DN", "PICK", true }, { "F", "FLY" }, { "P", "POKE" },
                              { "R", "FREE" }, { "Q", "QUIT" } })
  return c
end

return M
