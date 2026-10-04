-- navdesk: a CINDER NAV registration kiosk (AVIONICS.md). A computer of its
-- own wherever players are - the HQ lobby first - with a touch monitor, the
-- seat (Create Seat, Display Link reading Entity Name, CC:C Bridge target
-- block), a disk drive, a stock chest on CINDER's side and an out chest the
-- player opens. A player sits, registers their vehicle on the screen and
-- takes the kit from the chest: a unit written onto a computer from the
-- stock, two advanced monitors and an ender modem. The same kiosk takes
-- applications to host a traffic centre.
--
-- The master tower decides everything - callsigns, the limit, the number -
-- and keeps the registry and every unit's key. The kiosk asks it over the
-- radio, sealed with the kiosk's own key (SEC.DIR.KIOSK_TO_TOWER), and the
-- tower answers it alone. A new unit's key comes back once, sealed, to be
-- written onto the unit.
--
--   navdesk              run (startup autorun navdesk)
--   navdesk setup        find the monitor, drive and seat; ask which chest is which
--   navdesk stock <inventory> [more...] | out <inventory> | monitor <name> | drive <name>
--                        the stock can be several chests - one per part of the kit (Alex,
--                        2026-10-02: chest_0 gives, the others each hold one part)
--   navdesk join         take this kiosk's identity off the floppy the master wrote
--   navdesk status       what it is, what it uses, how many kits it holds
--
--   .navdesk      its name and master (tower kiosk add on the master)
--   .navdeskkey   its key
--   navdesk.cfg   which monitor, drive, stock and out chest

local N = dofile("lib/nav.lua")
local SEC = dofile("lib/seclink.lua")

local ME_FILE, ME_KEY, CFG, CTR = ".navdesk", ".navdeskkey", "navdesk.cfg", ".navdesk.ctr"
local STATUS_EVERY = 30     -- s between telling the tower how many kits are left
local ASK_WAIT = 3          -- s to wait for the tower's answer

local args = { ... }
local cmd = (args[1] or "run"):lower()

local function readAll(p)
  if not fs.exists(p) then return nil end
  local h = fs.open(p, "r")
  if not h then return nil end
  local s = h.readAll()
  h.close()
  return s
end
local function writeText(p, s)
  local h = fs.open(p, "w")
  if not h then return false end
  h.write(s)
  h.close()
  return true
end

local function loadCfg()
  local t = {}
  for k, v in (readAll(CFG) or ""):gmatch("(%w+)=([^\n]*)") do t[k] = v:gsub("%s+$", "") end
  return t
end
local function saveCfg(t)
  local lines = {}
  for _, k in ipairs({ "monitor", "drive", "stock", "out" }) do
    if t[k] and t[k] ~= "" then lines[#lines + 1] = k .. "=" .. t[k] end
  end
  writeText(CFG, table.concat(lines, "\n") .. "\n")
end
local function isInventory(n)
  local ok, l = pcall(peripheral.call, n, "list")
  return ok and type(l) == "table"
end
-- the first peripheral of a kind, or nil (said, not left out: tostring() of
-- nothing at all is an error - the first setup in game, 2026-10-02)
-- the stock chests, from navdesk.cfg's comma-separated stock=
local function stocksOf(cfg)
  local out = {}
  for n in tostring(cfg.stock or ""):gmatch("[^,%s]+") do out[#out + 1] = n end
  return out
end
-- what all of them hold, as one list() for N.kitsIn
local function stockList(names)
  local all = {}
  for _, n in ipairs(names) do
    local okL, l = pcall(peripheral.call, n, "list")
    if okL and type(l) == "table" then for _, it in pairs(l) do all[#all + 1] = it end end
  end
  return all
end

local function firstOf(kind)
  for _, n in ipairs(peripheral.getNames()) do if peripheral.getType(n) == kind then return n end end
  return nil
end

-- ------------------------------------------------------------- commands --
if cmd == "join" then
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n) == "drive" and peripheral.call(n, "hasData") then
      local mount = peripheral.call(n, "getMountPath")
      local f, k = mount .. "/" .. ME_FILE, mount .. "/" .. ME_KEY
      if fs.exists(f) and fs.exists(k) then
        writeText(ME_FILE, readAll(f))
        writeText(ME_KEY, readAll(k))
        fs.delete(f) fs.delete(k)
        local me = N.parseKioskFile(readAll(ME_FILE))
        print("this computer is now the " .. (me and me.name or "?") .. " kiosk. Wiped the floppy. navdesk setup next.")
        return
      end
    end
  end
  print("no kiosk floppy in any drive - on the master: tower kiosk add <NAME> with it in the drive")
  return
end

if cmd == "setup" or cmd == "stock" or cmd == "out" or cmd == "monitor" or cmd == "drive" then
  local cfg = loadCfg()
  if cmd ~= "setup" then
    local names = {}
    for i = 2, (cmd == "stock") and #args or 2 do names[#names + 1] = args[i] end
    if #names == 0 then print("navdesk " .. cmd .. " <peripheral name>" .. (cmd == "stock" and " [more...]" or "")) return end
    for _, name in ipairs(names) do
      if not peripheral.isPresent(name) then print(name .. " is not on this computer's network") return end
      if (cmd == "stock" or cmd == "out") and not isInventory(name) then print(name .. " is not an inventory") return end
    end
    cfg[cmd] = table.concat(names, ",")
    saveCfg(cfg)
    print(cmd .. ": " .. cfg[cmd])
    return
  end
  -- the monitor: the biggest advanced one; the drive and the seat: the first
  local best, area = nil, 0
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n) == "monitor" then
      local okC, colour = pcall(peripheral.call, n, "isColour")
      local okS, w, h = pcall(peripheral.call, n, "getSize")
      if okC and colour and okS and w * h > area then best, area = n, w * h end
    end
  end
  cfg.monitor, cfg.drive = best, firstOf("drive")
  print("monitor: " .. (cfg.monitor and "every monitor on the network shows the kiosk"
    or "NONE - an advanced monitor, 3x2 or bigger") .. "   drive: " .. (cfg.drive or "NONE"))
  print("seat: " .. (firstOf("create_target")
    or "NONE - a Create Seat, a Display Link on it reading Entity Name, a CC:C Bridge target block"))
  local invs = {}
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n) ~= "drive" and isInventory(n) then invs[#invs + 1] = n end
  end
  if #invs < 2 then
    print("needs two chests or more on this computer's network - stock (CINDER's side) and the out chest (the player's)")
  else
    for i, n in ipairs(invs) do print(string.format("  %d  %s", i, n)) end
    write("which is the OUT chest the player opens (number)? ")
    local o = invs[tonumber(read() or "")]
    if o then
      local st = {}
      for _, n in ipairs(invs) do if n ~= o then st[#st + 1] = n end end
      cfg.out, cfg.stock = o, table.concat(st, ",")
      print("out: " .. o)
      print("stock: " .. cfg.stock .. "  (" .. N.kitsIn(stockList(st)) .. " kits in them)")
    else
      print("no such number - nothing saved for the chests")
    end
  end
  saveCfg(cfg)
  print("saved in " .. CFG .. " - reboot, or run navdesk")
  return
end

local me = N.parseKioskFile(readAll(ME_FILE))
local key = SEC.readKeyFile(ME_KEY)

if cmd == "status" then
  local cfg = loadCfg()
  print("kiosk: " .. (me and (me.name .. " of " .. tostring(me.master)) or "not joined - tower kiosk add on the master"))
  print("key: " .. (key and "yes" or "no - open: the master must have tower kiosk open"))
  for _, k in ipairs({ "monitor", "drive", "stock", "out" }) do print(string.format("  %-8s %s", k, tostring(cfg[k]))) end
  -- what each chest really holds, by item name: a wrong kind of modem or
  -- monitor is the usual reason a full chest counts as no kits
  for _, n in ipairs(stocksOf(cfg)) do
    local okL, l = pcall(peripheral.call, n, "list")
    if not (okL and type(l) == "table") then
      print("  " .. n .. ": CANNOT READ - not on this computer's network?")
    else
      local names = {}
      for _, it in pairs(l) do names[it.name] = (names[it.name] or 0) + it.count end
      local parts = {}
      for name, c in pairs(names) do parts[#parts + 1] = c .. " " .. name end
      print("  " .. n .. ": " .. (#parts > 0 and table.concat(parts, ", ") or "empty"))
    end
  end
  if cfg.stock then
    local all = stockList(stocksOf(cfg))
    print("kits in stock: " .. N.kitsIn(all) .. "  (" .. N.kitParts(all) .. ")")
  else
    print("no stock chests set - navdesk setup")
  end
  if not cfg.out then print("no out chest set - navdesk setup") end
  return
end

if cmd ~= "run" then
  print("navdesk [run | setup | stock <inv> | out <inv> | monitor <name> | drive <name> | join | status]")
  return
end

-- -------------------------------------------------------------------- run --
-- No key: open, for testing (tower kiosk open on the master) - questions and
-- answers in the clear, named after this computer's label
local open = not key
if open then
  local label = os.getComputerLabel and os.getComputerLabel() or nil
  me = me or { name = N.validCentre(tostring(label or ""):gsub("^kiosk%-", "")) or ("K" .. os.getComputerID()) }
  print("NO KEY: talking to the tower in the clear as " .. me.name .. " - the master needs tower kiosk open")
end
local myId = N.kioskId(me.name)
local radio
repeat
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n) == "modem" then
      local okW, wl = pcall(peripheral.call, n, "isWireless")
      if okW and wl then radio = n break end
    end
  end
  if not radio then print("no ender modem - waiting for one") os.pullEvent("peripheral") end
until radio
pcall(peripheral.call, radio, "open", N.CHANNEL)

local KL, KUI = dofile("lib/navkiosk.lua"), dofile("lib/kioskui.lua")
local D, T = dofile("lib/display.lua"), dofile("lib/tui.lua")
local tx, rx = (not open) and SEC.sender(key, myId, SEC.DIR.KIOSK_TO_TOWER, CTR) or nil, SEC.receiver()
local cfg = loadCfg()
local seq = 0

-- One question to the master tower, and its answer (or nil and why). Other
-- events that arrive while it waits are let go: a touch in those few
-- tenths of a second is lost, which the screen survives.
local function ask(op, fields)
  seq = seq + 1
  local q = tostring(os.epoch and os.epoch("utc") or os.clock()) .. "-" .. seq
  local m = { type = "kq", q = q, op = op }
  for k, v in pairs(fields or {}) do m[k] = v end
  local env = m
  if open then m.kiosk = me.name
  else
    env = tx.seal(m)
    if not env then return nil, "COULD NOT SEAL THE REQUEST" end
  end
  pcall(peripheral.call, radio, "transmit", N.CHANNEL, N.CHANNEL, env)
  local timer = os.startTimer(ASK_WAIT)
  while true do
    local e, a, ch, _, msg = os.pullEvent()
    if e == "timer" and a == timer then return nil, "THE REGISTRY CANNOT BE REACHED" end
    if open and e == "modem_message" and ch == N.CHANNEL and type(msg) == "table" and not msg.sl
       and msg.type == "ka" and msg.re == q and msg.to == myId then
      return msg
    end
    if e == "modem_message" and ch == N.CHANNEL and type(msg) == "table" and msg.sl and msg.d == SEC.DIR.TOWER_TO_KIOSK then
      local b = rx.open(msg, function(id) return id == myId and key or nil end, SEC.DIR.TOWER_TO_KIOSK, N.MAX_AGE_MS)
      if b and b.type == "ka" and b.re == q then return b end
    end
  end
end

local function drive() return cfg.drive and peripheral.isPresent(cfg.drive) and cfg.drive or firstOf("drive") end
local function inDrive()
  local d = drive()
  if not (d and peripheral.call(d, "hasData")) then return d, nil end
  return d, peripheral.call(d, "getMountPath")
end
-- what is in the drive goes to the out chest, or out of the drive
local function handBack(d)
  if not (cfg.out and pcall(peripheral.call, cfg.out, "pullItems", d, 1)) then pcall(peripheral.call, d, "ejectDisk") end
end
local function recOf(a)
  return { reg = a.reg, call = a.call, kind = a.kind, unit = a.unit, owner = a.owner, revoked = a.revoked }
end

local kiosk
kiosk = KL.new({
  seated = function()
    local s = firstOf("create_target")
    if not s then return nil end
    local okL, line = pcall(peripheral.call, s, "getLine", 1)
    return okL and N.seatName(line) or nil
  end,
  drive = function()
    local _, m = inDrive()
    return m and N.inspect(fs, m) or nil
  end,
  eject = function() local d = drive() if d then handBack(d) end end,
  find = function(unit)
    local a = ask("find", { unit = unit })
    return (a and a.ok) and recOf(a) or nil
  end,
  count = function(owner)
    local a = ask("info", { owner = owner })
    return a and a.count or 0
  end,
  nextReg = function()
    local a = ask("info", { owner = "" })
    return a and a.nextReg or "CR-????"
  end,
  stock = function()
    if not (cfg.stock and cfg.out) then return nil, cfg.stock and "NO OUT CHEST SET" or "NO STOCK CHESTS SET" end
    return N.kitsIn(stockList(stocksOf(cfg)))
  end,
  callFree = function(call, except)
    local a, why = ask("callFree", { call = call, except = except })
    if not a then return nil, why end
    if a.ok then return a.call end
    return nil, a.why
  end,
  -- a computer from the stock into the drive (one the drive cannot read goes
  -- back), the unit the tower files written onto it, then it, two monitors
  -- and an ender modem into the out chest
  kit = function(owner, kind, call)
    local d, stocks, out = drive(), stocksOf(cfg), cfg.out
    if not (d and #stocks > 0 and out) then return nil, "THE KIOSK'S CHESTS ARE NOT SET UP" end
    if peripheral.call(d, "hasData") then return nil, "THE DRIVE IS NOT EMPTY" end
    -- st: the chest the computer came from, and goes back to if anything fails
    -- which step failed is said exactly (2026-10-02: "nothing in stock" read
    -- the same for a computer that would not move and one never switched on)
    local loaded, st, tried, unread, stuck = false, nil, 0, 0, nil
    for _, from in ipairs(stocks) do
      local okL, list = pcall(peripheral.call, from, "list")
      for slot, it in pairs(okL and list or {}) do
        if not loaded and it.name == N.KIT.computer then
          tried = tried + 1
          local okP, moved = pcall(peripheral.call, from, "pushItems", d, slot, 1)
          if okP and moved == 1 then
            for _ = 1, 10 do
              if peripheral.call(d, "hasData") then loaded = true break end
              sleep(0.1)
            end
            if loaded then st = from
            else
              unread = unread + 1
              pcall(peripheral.call, from, "pullItems", d, 1)
            end
          else
            stuck = okP and "the drive would not take it" or tostring(moved)
          end
        end
      end
    end
    if not loaded then
      print(string.format("kit: %d computer(s) tried, %d never switched on, moving: %s", tried, unread, tostring(stuck or "fine")))
      if tried == 0 then return nil, "NO ADVANCED COMPUTER IN STOCK" end
      if unread > 0 then
        print("put new computers through the prep turtle first (startup role prep)")
        return nil, "STOCK COMPUTERS WERE NEVER SWITCHED ON"
      end
      return nil, "COULD NOT MOVE A COMPUTER INTO THE DRIVE"
    end
    local a, why = ask("register", { owner = owner, kind = kind, call = call })
    if not (a and a.ok) then
      pcall(peripheral.call, st, "pullItems", d, 1)
      return nil, a and a.why or why
    end
    local rec = { n = a.n, unit = a.unit, owner = a.owner, call = a.call, kind = a.kind }
    local okI, whyI = N.install(fs, peripheral.call(d, "getMountPath"),
      { rec = rec, keyHex = a.key, src = "", version = readAll(".commit") })
    if not okI then
      ask("written", { unit = a.unit, ok = false })
      pcall(peripheral.call, st, "pullItems", d, 1)
      return nil, whyI
    end
    pcall(peripheral.call, d, "setDiskLabel", a.unit)
    ask("written", { unit = a.unit, ok = true })
    pcall(peripheral.call, out, "pullItems", d, 1)
    for _, need in ipairs(N.KIT) do
      local left = need.count
      for _, from in ipairs(stocks) do
        local okL2, l2 = pcall(peripheral.call, from, "list")
        for slot, it in pairs(okL2 and l2 or {}) do
          if left > 0 and it.name == need.name then
            local okM, moved = pcall(peripheral.call, from, "pushItems", out, slot, left)
            if okM and type(moved) == "number" then left = left - moved end
          end
        end
      end
    end
    return recOf(a)
  end,
  -- the seated player's own unit, in the drive: the tower checks it is theirs
  refresh = function(unit, kind, call)
    local d, m = inDrive()
    if not m then return nil, "THE UNIT WAS TAKEN OUT" end
    local a, why = ask("refresh", { unit = unit, kind = kind, call = call, owner = kiosk.view.who })
    if not (a and a.ok) then return nil, a and a.why or why end
    local okI, whyI = N.install(fs, m, { rec = { n = a.n, unit = a.unit, owner = a.owner, call = a.call, kind = a.kind },
      src = "", version = readAll(".commit") })
    if not okI then return nil, whyI end
    handBack(d)
    return recOf(a)
  end,
  validCentre = N.validCentre,
  apply = function(owner, name, x, z)
    local a, why = ask("apply", { owner = owner, name = name, x = x, z = z })
    if not a then return nil, why end
    return a.ok or nil, a.why
  end,
  now = os.clock,
})

-- Every monitor on the network shows the kiosk, and a touch on any of them
-- works (Alex, 2026-10-04: "let it use any monitor on the network"). The
-- monitor setup once chose is not needed: a side that now holds something
-- else crashed it ("No such method setCursorPos").
local mons = {}          -- name -> { canvas, hits }
local function monitorNames()
  local out = {}
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n) == "monitor" then out[#out + 1] = n end
  end
  table.sort(out)
  return out
end
local function draw()
  local seen = {}
  for _, name in ipairs(monitorNames()) do
    seen[name] = true
    local m = mons[name] or {}
    mons[name] = m
    local okS, w, h = pcall(peripheral.call, name, "getSize")
    if okS and w and h then
      if not m.canvas or m.canvas.w ~= w or m.canvas.h ~= h then
        pcall(peripheral.call, name, "setTextScale", 0.5)
        T.apply({ setPaletteColour = function(...) return peripheral.call(name, "setPaletteColour", ...) end })
        okS, w, h = pcall(peripheral.call, name, "getSize")
        if okS and w and h then m.canvas = D.canvas(w, h) end
      end
      if m.canvas then
        m.canvas:clear()
        m.hits = KUI.render(T, m.canvas, kiosk.view)
        pcall(m.canvas.flush, m.canvas, { setCursorPos = function(x, y) peripheral.call(name, "setCursorPos", x, y) end,
                                          blit = function(s2, f, b) peripheral.call(name, "blit", s2, f, b) end })
      end
    end
  end
  for n in pairs(mons) do if not seen[n] then mons[n] = nil end end
end

local nMon = #monitorNames()
print(string.format("kiosk %s for %s - %s, drive %s", me.name, me.master or "the master tower",
  nMon > 0 and (nMon .. " monitor" .. (nMon == 1 and "" or "s")) or "NO MONITOR", cfg.drive or "none"))
if not (cfg.stock and cfg.out) then print("not set up: navdesk setup") end
if cfg.stock then
  local all = stockList(stocksOf(cfg))
  print("kits in stock: " .. N.kitsIn(all) .. "  (" .. N.kitParts(all) .. ")")
end
print("out chest: " .. (cfg.out or "NONE - navdesk setup"))
local timer = os.startTimer(0.5)
local lastStatus = -STATUS_EVERY
while true do
  local e, a, x, y = os.pullEvent()
  if e == "timer" and a == timer then
    kiosk:tick()
    draw()
    if os.clock() - lastStatus >= STATUS_EVERY and kiosk.view.state == "attract" then
      lastStatus = os.clock()
      ask("status", { stock = kiosk.io.stock() or -1 })
    end
    timer = os.startTimer(0.5)
  elseif e == "monitor_touch" and mons[a] then
    if kiosk:touch(KUI.hit(mons[a].hits, x, y)) then draw() end
    -- a question to the tower may have let the tick's timer go by
    timer = os.startTimer(0.5)
  end
end
