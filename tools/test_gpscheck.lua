-- gpscheck.lua against fake GPS hosts: one of them typed in wrong, and an
-- array laid out flat. The distances are what an ender modem reports, the
-- true distance from each host's REAL block to where the player stands.
local DIR = ...
local ROOT = DIR .. "/.."
local pass, fail = 0, 0
local function check(n, c, d)
  if c then pass = pass + 1 print("  ok   " .. n)
  else fail = fail + 1 print("  FAIL " .. n .. (d and ("  " .. tostring(d)) or "")) end
end

-- hosts: { real = {x,y,z}, says = {x,y,z} }
local function run(hosts, me, args, opts)
  opts = opts or {}
  local w = { printed = {}, files = {}, clock = 0, sent = {}, ran = {} }
  local queue = {}
  local env = setmetatable({}, { __index = _G })
  env.print = function(s) w.printed[#w.printed + 1] = tostring(s) end
  env.peripheral = {
    getNames = function() return { "back" } end,
    getType = function() return "modem" end,
    call = function(_, m, ...)
      if m == "isWireless" then return true end
      if m == "isOpen" then return false end
      if m == "transmit" then
        local ch, reply, msg = ...
        w.sent[#w.sent + 1] = msg
        if msg == "PING" then
          for _, h in ipairs(hosts) do
            local r = h.real
            local d = math.sqrt((r[1] - me[1]) ^ 2 + (r[2] - me[2]) ^ 2 + (r[3] - me[3]) ^ 2)
            queue[#queue + 1] = { "modem_message", "back", reply, ch, { h.says[1], h.says[2], h.says[3] }, d }
          end
        end
      end
    end,
  }
  env.os = setmetatable({
    clock = function() return w.clock end,
    startTimer = function() return 7 end,
    pullEvent = function()
      w.clock = w.clock + 0.1
      if #queue > 0 then return (table.unpack or unpack)(table.remove(queue, 1)) end
      w.clock = w.clock + 5
      return "timer", 7
    end,
    getComputerLabel = function() return "alex-pocket" end,
    getComputerID = function() return 12 end,
  }, { __index = os })
  env.gps = { CHANNEL_GPS = 65534, locate = function()
    if opts.fix then return (table.unpack or unpack)(opts.fix) end
    return nil
  end }
  env.fs = {
    exists = function(p) return w.files[p] ~= nil or (opts.canUpload and (p == ".ghtoken" or p == "upload.lua")) end,
    open = function(p) local buf = {} return { write = function(s) buf[#buf + 1] = s end,
                                               close = function() w.files[p] = table.concat(buf) end } end,
  }
  env.shell = { run = function(...) w.ran[#w.ran + 1] = table.concat({ ... }, " ") return true end }
  local fn = assert(loadfile(ROOT .. "/gpscheck.lua"))
  setfenv(fn, env)
  local ok, err = pcall(fn, (table.unpack or unpack)(args or {}))
  w.err = (not ok) and tostring(err) or nil
  w.text = table.concat(w.printed, "\n")
  return w
end
local function has(w, s) return w.text:find(s, 1, true) ~= nil end

-- four hosts round a volcano, one offset in Y; the player at the rules pad
local ME = { -669, 65, 2828 }
local GOOD = {
  { real = { 1000, 90, 400 }, says = { 1000, 90, 400 } },
  { real = { 1020, 90, 400 }, says = { 1020, 90, 400 } },
  { real = { 1000, 90, 420 }, says = { 1000, 90, 420 } },
  { real = { 1010, 110, 410 }, says = { 1010, 110, 410 } },
}

print("an honest array")
local w = run(GOOD, ME, { "-669", "65", "2828" }, { fix = { -669.2, 65.1, 2828.3 } })
check("it runs", w.err == nil, w.err)
check("all four answered", has(w, "4 hosts answered"))
check("every host agrees with where you stand", has(w, "every host agrees") and not has(w, "WRONG"))
check("the fix is reported against the truth", has(w, "gps.locate says -669.2 65.1 2828.3"))
check("and written to gpscheck.txt", (w.files["gpscheck.txt"] or ""):find("4 hosts answered", 1, true) ~= nil)

print("one host typed in wrong")
local BAD = {
  GOOD[1], GOOD[2],
  { real = { 1000, 90, 420 }, says = { 1000, 90, 402 } },    -- z typed as 402
  GOOD[4],
}
w = run(BAD, ME, { "-669", "65", "2828" })
check("the wrong host is named, and only that one", select(2, w.text:gsub("WRONG", "")) == 1
  and w.text:find("3  says 1000 90 402[^\n]*WRONG") ~= nil, w.text)
check("and what to do about it", has(w, "1 host with wrong coordinates"))

print("an array laid out flat")
local FLAT = {
  { real = { 1000, 90, 400 }, says = { 1000, 90, 400 } },
  { real = { 1020, 90, 400 }, says = { 1020, 90, 400 } },
  { real = { 1000, 90, 420 }, says = { 1000, 90, 420 } },
  { real = { 1020, 90, 420 }, says = { 1020, 90, 420 } },
}
w = run(FLAT, ME, {})
check("four at one height: it says the vertical is a guess", has(w, "too flat") and has(w, "in one plane"))
check("with no truth given it says how to give one", has(w, "gpscheck <x> <y> <z>"))

print("nothing answering, and uploading")
w = run({}, ME, {})
check("no hosts: said plainly", has(w, "0 hosts answered") and has(w, "no GPS at all"))
w = run(GOOD, ME, {}, { canUpload = true })
check("a computer that can upload pushes the result under its label",
  w.ran[1] == "upload sync gpscheck.txt data/gpscheck-alex-pocket.txt", w.ran[1])
w = run(GOOD, ME, { "1", "2" })
check("two numbers is not a position", w.err == nil and has(w, "three numbers"))

print("")
print(string.format("%d passed, %d failed", pass, fail))
