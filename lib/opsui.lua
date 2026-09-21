-- opsui: the operator's screen at the base, built out of lib/tui.lua.
--
-- One board, the same look as the customer's terminal: a masthead, the fleet
-- as a list with the selected unit highlighted, what that unit is doing, and
-- the log of everything the base has heard. Whatever the operator can do to
-- the selected unit is on the key bar, and nothing that needs a drone selected
-- is offered when none is.
--
-- It sizes itself for the three screens this actually runs on: an advanced
-- computer (51x19) puts the fleet and the log side by side; a pocket computer
-- (26x20) stacks them, shortens the status strip and carries the selected unit
-- on one line; a monitor is just a bigger version of the first. The key bar
-- changes with the width too - the operator's own pocket is the one place
-- where QUIT must never be the key that falls off the end.
--
-- Nothing here talks to a peripheral - ops passes in a table and this draws it
-- - so tools/preview_ops.py renders the same board on the desktop at any size.

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
  local y = T.masthead(c, 2, "CONTROL", T.C.text)      -- never row 1: see T.masthead

  -- a status strip under the masthead: the things that are true right now,
  -- abbreviated rather than truncated when the screen is narrow
  local wide = w >= 46
  local strip
  if wide then
    strip = string.format("%s   %d UNIT%s   %d JOB%s   %d WAITING",
      view.clock or "--:--", #view.units, #view.units == 1 and "" or "S",
      view.jobs or 0, (view.jobs or 0) == 1 and "" or "S", view.queue or 0)
  else
    strip = string.format("%s  %dU  %dJ  %dQ", view.clock or "--:--",
      #view.units, view.jobs or 0, view.queue or 0)
  end
  c:text(1, y + 1, strip:sub(1, w), T.C.faint)
  -- the till: what has come in today, and whether someone is mid-payment
  if view.till then
    local line = view.arming and ("OPEN " .. view.arming)
                 or (view.shut and "TILL SHUT" or ("TILL " .. view.till))
    c:text(math.max(1, w - #line), y + 1, line, view.arming and T.C.accent or T.C.faint)
  end
  if (view.refused or 0) > 0 and wide then
    c:text(w - 12, y + 1, string.format("%4d REFUSED", view.refused), T.C.warn)
  end
  -- a unit down takes the strip over until someone acknowledges it: where
  -- it is, first, because that is what the operator needs to go and get it
  if view.alert then
    local a = view.alert
    local where = (type(a.x) == "number" and type(a.z) == "number")
      and string.format("%d %d %d", math.floor(a.x), math.floor(type(a.y) == "number" and a.y or 0), math.floor(a.z))
      or "POSITION UNKNOWN"
    local text = string.format(" DISTRESS %s  %s  %s", tostring(a.drone):upper(), where, tostring(a.why):upper())
    c:text(1, y + 1, string.rep(" ", w), T.C.text, T.C.warn)
    c:text(1, y + 1, text:sub(1, w), T.C.text, T.C.warn)
  end

  -- the fleet, and the log under or beside it
  local top = y + 2
  local bottom = h - 1
  local fleetW = wide and math.floor(w * 0.52) or w
  local fleetH = wide and (bottom - top + 1) or math.max(5, math.floor((bottom - top + 1) * 0.6))

  local r = T.section(c, top, "FLEET")
  -- one format string for the header and the rows, so the columns cannot
  -- drift apart (they did: STATE and BATT overlapped at 29 columns)
  local inner = fleetW - 2
  local nameW = math.max(6, inner - 14)
  local fmt = "%-" .. nameW .. "s %-7s %s"
  c:text(2, r, string.format(fmt, "UNIT", "STATE", "BATT"), T.C.faint)
  local rows = (top + fleetH - 2) - (r + 1) + 1
  local first = math.max(1, math.min((view.sel or 1) - math.floor(rows / 2), #view.units - rows + 1))
  if first < 1 then first = 1 end
  for i = 0, rows - 1 do
    local u = view.units[first + i]
    if u then
      -- the job marker goes IN the line, not in a right-hand column: a
      -- right-hand value landed on top of the battery figure
      T.row(c, 1, r + 1 + i, fleetW - 1,
            string.format(fmt, tostring(u.id):upper():sub(1, nameW), tostring(u.state):sub(1, 7), pct(u.batt))
              .. (u.job and " *" or ""),
            nil, (first + i) == view.sel)
    end
  end
  if #view.units == 0 then c:text(2, r + 1, "NOTHING HAS CALLED IN", T.C.faint) end

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
    local d = T.section(c, logY, "UNIT")
    c:text(logX + 1, d, tostring(sel.id):upper():sub(1, logW - 2), T.C.text)
    c:text(logX + 1, d + 1, tostring(sel.state):upper():sub(1, logW - 2),
           sel.state == "LOST" and T.C.warn or T.C.accent)
    c:text(logX + 1, d + 2, (sel.x and string.format("%d, %d", sel.x, sel.z) or "NO FIX"):sub(1, logW - 2), T.C.faint)
    c:text(logX + 1, d + 3, (sel.job and ("JOB " .. tostring(sel.job):sub(1, logW - 6)) or "NO JOB"), T.C.faint)
    logY = logY + 5
    logH = logH - 5
  end

  if not wide and sel then
    -- no room for a panel, so the selected unit gets one line
    c:text(1, logY, (tostring(sel.id):upper() .. " " ..
      (sel.x and string.format("%d,%d", sel.x, sel.z) or "NO FIX") ..
      (sel.job and " ON JOB" or "")):sub(1, w), T.C.text)
    logY = logY + 1
    logH = logH - 1
  end

  local lr = T.section(c, logY, "LOG")
  local log = view.log or {}
  local lrows = (logY + logH - 1) - lr + 1
  local lfirst = math.max(1, #log - lrows + 1)
  for i = lfirst, #log do
    c:text(logX + 1, lr + (i - lfirst), tostring(log[i]):upper():sub(1, logW - 2),
           (i == #log) and T.C.text or T.C.faint)
  end

  local keys = view.keys
  if not keys then
    if view.alert then
      keys = { { "A", "ACKNOWLEDGE", true }, { "F", "FLY" }, { "Q", "QUIT" } }
    elseif wide then
      keys = { { "UP/DN", "PICK", true }, { "F", "FLY" }, { "P", "POKE" },
               { "R", "FREE" }, { "Q", "QUIT" } }
    else
      -- the arrows are obvious, so they are not listed. QUIT goes FIRST here:
      -- the bar drops whatever does not fit, and at 26 columns that was QUIT -
      -- the one key someone must always be able to find.
      keys = { { "Q", "QUIT" }, { "F", "FLY" }, { "P", "POKE" }, { "R", "FREE" } }
    end
  end
  T.keys(c, h, keys)
  return c
end

return M
