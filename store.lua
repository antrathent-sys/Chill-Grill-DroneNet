-- store: a site's stock computer (lib/store.lua). Labelled store-<site> -
-- store-chi counts for CHI - and keyed on the base like a depot: there,
-- `seckey new store-chi` with a floppy in its drive; here, `seckey set disk`.
--
--   store              count the stock every 15 s: the stock list on its
--                      screen, and the base sent the count every minute
--                      (startup role store runs it on boot)
--   store setup        every inventory on this computer's cable network,
--                      numbered: say which are stock - and which monitor is
--                      the stock list
--   store count        count now and show it here - nothing is sent
--   store status       label, key, radio, screen, and each stock inventory
--
-- Stock by numbers is a fixed list; stock by a word in the names (vault) or
-- all is a rule, read again at every count, so a silo added to the network
-- later is counted with no setup.
--
-- The site's silos are on one cable network with this computer, inside the
-- site (and later each dock's intake, for picking orders into). Nothing is
-- cabled between sites: the count goes to the base by sealed radio, in pages.

local SEC = dofile("lib/seclink.lua")
local link = dofile("lib/link.lua")
local F = dofile("lib/fleet.lua")
local St = dofile("lib/store.lua")

local args = { ... }
local CFG, NAMES, KEY, CTR = "store.cfg", ".storenames", ".dronekey", ".dronekey.ctr"
local SCREEN_EVERY = 15        -- s between counts for the screen; the base gets one every St.EVERY
local SCROLL_BACK = 120        -- s untouched before the list goes back to the top
local unpackAll = table.unpack or unpack

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
  for k, v in (readAll(CFG) or ""):gmatch("(%w+)=([^\n]*)") do t[k] = v end
  local stock = {}
  for n in (t.stock or ""):gmatch("[^,%s]+") do stock[#stock + 1] = n end
  return { stock = stock, match = (t.match and t.match ~= "") and t.match or nil,
           screen = (t.screen and t.screen ~= "") and t.screen or nil }
end
local function saveCfg(c)
  return writeText(CFG, "stock=" .. table.concat(c.stock, ",") .. "\nmatch=" .. (c.match or "")
    .. "\nscreen=" .. (c.screen or "") .. "\n")
end

-- what each item is called, read once and kept: getItemDetail is a call a
-- slot, and there are hundreds of kinds
local function loadNames()
  local names = {}
  for k, l in (readAll(NAMES) or ""):gmatch("([^\t\n]+)\t([^\n]*)") do names[k] = l end
  return names
end
local function saveNames(names)
  local lines = {}
  for k, l in pairs(names) do lines[#lines + 1] = k .. "\t" .. l end
  table.sort(lines)
  return writeText(NAMES, table.concat(lines, "\n") .. "\n")
end

local function inventories()
  local out = {}
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.hasType and peripheral.hasType(n, "inventory") then out[#out + 1] = n end
  end
  table.sort(out)
  return out
end

--- The stock inventories now: the fixed list, or every one the rule matches.
local function stockOf(cfg)
  if not cfg.match then return cfg.stock end
  local out = {}
  for _, n in ipairs(inventories()) do
    if cfg.match == "all" or n:find(cfg.match, 1, true) then out[#out + 1] = n end
  end
  return out
end

-- many calls in the same tick: each waits on the server, side by side
local BATCH = 16
local function inBatches(items, fn)
  for i = 1, #items, BATCH do
    local fns = {}
    for j = i, math.min(#items, i + BATCH - 1) do
      local it = items[j]
      fns[#fns + 1] = function() fn(it) end
    end
    parallel.waitForAll(unpackAll(fns))
  end
end

local function countNow(invs, names)
  local lists = {}
  inBatches(invs, function(inv)
    local ok, l = pcall(peripheral.call, inv, "list")
    if ok then lists[inv] = l end
  end)
  local totals, problems, stacks = St.count(lists, invs)
  local need = {}
  for k in pairs(totals) do if not names[k] then need[#need + 1] = k end end
  inBatches(need, function(k)
    local t = totals[k]
    local ok, d = pcall(peripheral.call, t.inv, "getItemDetail", t.slot)
    if ok then names[k] = St.label(d) end
  end)
  if #need > 0 then saveNames(names) end
  return totals, problems, stacks
end

local function summary(totals)
  local kinds, items = 0, 0
  for _, t in pairs(totals) do kinds, items = kinds + 1, items + t.count end
  return kinds, items
end

local cmd = args[1] or "run"
local id = os.getComputerLabel and os.getComputerLabel() or nil
local site = St.siteOf(id)

if cmd == "setup" then
  local invs = inventories()
  if #invs == 0 then print("no inventories on this computer's network - wired modems on the silos, cable to here") return end
  local cfg = loadCfg()
  local chosen = {}
  for _, n in ipairs(stockOf(cfg)) do chosen[n] = true end
  for i, n in ipairs(invs) do
    local okS, size = pcall(peripheral.call, n, "size")
    print(string.format("%3d %s %-30s %s", i, chosen[n] and "*" or " ", n, okS and (size .. " slots") or "?"))
  end
  print("")
  print("Which are stock? Numbers and ranges (1-12 15) for a fixed")
  print("list; a word in their names (vault) or all, and any added")
  print("later count too. Enter keeps the ones marked *.")
  write("> ")
  local line = read() or ""
  if not line:match("^%s*$") then
    local word = line:match("^%s*([%a_:%-]+)%s*$")
    if word and not tonumber(word) then
      cfg.match, cfg.stock = word, {}
    else
      local pick, seen = {}, {}
      local function add(n) if n and not seen[n] then seen[n] = true pick[#pick + 1] = n end end
      for tok in line:gmatch("%S+") do
        local a, b = tok:match("^(%d+)%-(%d+)$")
        if a then
          for i = tonumber(a), tonumber(b) do add(invs[i]) end
        elseif tonumber(tok) then
          add(invs[tonumber(tok)])
        end
      end
      if #pick == 0 then print("nothing matched - nothing changed") return end
      cfg.match, cfg.stock = nil, pick
    end
  end
  local now = stockOf(cfg)
  print(string.format("%d inventories are stock%s", #now, cfg.match and (" - every one with '" .. cfg.match
    .. "' in its name, now and later") or ""))
  -- the stock list's screen
  local mons = {}
  for _, n in ipairs(peripheral.getNames()) do if peripheral.getType(n) == "monitor" then mons[#mons + 1] = n end end
  table.sort(mons)
  if #mons > 0 then
    print("")
    for i, n in ipairs(mons) do
      local okS, w, h = pcall(peripheral.call, n, "getSize")
      print(string.format("%3d %s %-20s %s", i, n == cfg.screen and "*" or " ", n, okS and (w .. "x" .. h) or "?"))
    end
    print("Which monitor is the stock list? A number, 0 for none,")
    print("Enter keeps the one marked *.")
    write("> ")
    local ans = read() or ""
    if tonumber(ans) == 0 then cfg.screen = nil
    elseif tonumber(ans) and mons[tonumber(ans)] then cfg.screen = mons[tonumber(ans)] end
  end
  saveCfg(cfg)
  print("saved. store count to see what is in them; reboot to run.")
  return
end

if cmd == "count" then
  local cfg = loadCfg()
  local invs = stockOf(cfg)
  if #invs == 0 then print("no stock inventories yet - store setup") return end
  local names = loadNames()
  local t0 = os.clock()
  local totals, problems, stacks = countNow(invs, names)
  local kinds, items = summary(totals)
  print(string.format("%s items, %d kinds, %d stacks, in %d inventories (%.1f s)", St.commas(items), kinds, stacks,
    #invs, os.clock() - t0))
  for _, p in ipairs(problems) do print("  " .. p) end
  local list = {}
  for k, t in pairs(totals) do list[#list + 1] = { k = k, n = t.count } end
  table.sort(list, function(a, b) return a.n > b.n end)
  for i = 1, math.min(#list, 12) do
    print(string.format("%12s  %s", St.commas(list[i].n), names[list[i].k] or list[i].k))
  end
  if #list > 12 then print(string.format("  ...and %d more kinds", #list - 12)) end
  return
end

if cmd == "status" then
  local cfg = loadCfg()
  local invs = stockOf(cfg)
  print("label:  " .. tostring(id) .. (site and ("  (site " .. site .. ")") or "  - NOT store-<site>: label set store-chi"))
  print("key:    " .. (fs.exists(KEY) and "yes" or "NONE - on the base: seckey new " .. tostring(id or "store-<site>")
    .. ", then here: seckey set disk"))
  print("radio:  " .. (link.findRadio(peripheral) or "NONE - put an ender modem on this computer"))
  print("screen: " .. (cfg.screen and (cfg.screen .. (peripheral.isPresent(cfg.screen) and "" or " - NOT FOUND")) or "none"))
  print("stock:  " .. #invs .. " inventories" .. (cfg.match and (" (every '" .. cfg.match .. "')") or "")
    .. (#invs == 0 and " - store setup" or ""))
  for _, n in ipairs(invs) do
    local ok, size = pcall(peripheral.call, n, "size")
    print(string.format("  %-30s %s", n, ok and (size .. " slots") or "CANNOT READ - not on the network?"))
  end
  return
end

if cmd ~= "run" then
  print("store [run | setup | count | status]")
  return
end

-- ------------------------------------------------------------------- run --
if not site then print("label this computer store-<site> first: label set store-chi") return end
local key = SEC.readKeyFile(KEY)
if not key then print("no key - on the base: seckey new " .. id .. " (a floppy in its drive); here: seckey set disk") return end
local radio = link.findRadio(peripheral)
if not radio then
  print("no ender modem - put one on this computer; waiting for it")
  repeat os.pullEvent("peripheral") radio = link.findRadio(peripheral) until radio
end
local tx = SEC.sender(key, id, SEC.DIR.DRONE_TO_BASE, CTR)
local names = loadNames()
local seq, lastSent = 0, -1e9

-- the stock list's screen (lib/storeui.lua)
local D, T, UI
do
  local okD, d = pcall(dofile, "lib/display.lua")
  local okT, t = pcall(dofile, "lib/tui.lua")
  local okU, u = pcall(dofile, "lib/storeui.lua")
  if okD and okT and okU then D, T, UI = d, t, u end
end
local screen = { list = {}, top = 1, touched = -1e9, at = nil, problems = 0 }
local function draw()
  local cfg = loadCfg()
  local name = cfg.screen
  if not (UI and name and peripheral.isPresent(name)) then return end
  if os.clock() - screen.touched > SCROLL_BACK then screen.top = 1 end
  pcall(peripheral.call, name, "setTextScale", 1)
  local okS, w, h = pcall(peripheral.call, name, "getSize")
  if not okS then return end
  if not screen.canvas or screen.canvas.w ~= w or screen.canvas.h ~= h then
    screen.canvas = D.canvas(w, h)
    T.apply({ setPaletteColour = function(...) return peripheral.call(name, "setPaletteColour", ...) end })
  end
  local c = screen.canvas
  c:clear()
  local hits, top = UI.render(T, c, { site = site, list = screen.list, top = screen.top, at = screen.at,
    problems = screen.problems })
  screen.hits, screen.top = hits, top
  c:flush({ setCursorPos = function(x, y) peripheral.call(name, "setCursorPos", x, y) end,
            blit = function(s, f, b) peripheral.call(name, "blit", s, f, b) end })
end

local function send(totals)
  local pages = St.pages(os.epoch and os.epoch("utc") or os.clock(), totals, names)
  local sent = 0
  for _, p in ipairs(pages) do
    seq = seq + 1
    p.v, p.nonce = F.VERSION, F.nonce(id, seq)
    local okS, env = pcall(tx.seal, p)
    if okS and env then
      pcall(peripheral.call, radio, "transmit", link.CHANNEL, link.CHANNEL, env)
      sent = sent + 1
    end
  end
  return sent, #pages
end

local function countLoop()
  while true do
    local cfg = loadCfg()
    local invs = stockOf(cfg)
    if #invs == 0 then
      screen.list, screen.problems = {}, 0
      print("no stock inventories yet - store setup")
    else
      local totals, problems = countNow(invs, names)
      local okD, stamp = pcall(textutils.formatTime, os.time(), true)
      screen.list, screen.problems, screen.at = UI and UI.list(totals, names) or {}, #problems, okD and stamp or nil
      if os.clock() - lastSent >= St.EVERY then
        lastSent = os.clock()
        local sent, n = send(totals)
        local kinds, items = summary(totals)
        print(string.format("%s  %s items, %d kinds - %d/%d pages to the base%s", screen.at or "", St.commas(items),
          kinds, sent, n, #problems > 0 and ("  " .. #problems .. " unreadable") or ""))
      end
    end
    draw()
    sleep(SCREEN_EVERY)
  end
end

local function touchLoop()
  while true do
    local _, name, x, y = os.pullEvent("monitor_touch")
    if UI and name == loadCfg().screen and screen.hits then
      local hit = UI.hit(screen.hits, x, y)
      local rows = screen.canvas and UI.rows(screen.canvas) or 10
      if hit == "up" then screen.top = screen.top - rows
      elseif hit == "down" then screen.top = screen.top + rows
      elseif hit == "top" then screen.top = 1 end
      if hit then screen.touched = os.clock() draw() end
    end
  end
end

print(string.format("store %s: counting site %s every %d s, the base told every %d s, sealed", id, site,
  SCREEN_EVERY, St.EVERY))
parallel.waitForAny(countLoop, touchLoop)
