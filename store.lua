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
--   store status       label, key, radio, screen, output, each stock inventory
--   store pick <amount> <item words>   move that many into the output (a
--                      barrel for now, a dock's intake later); while store
--                      runs, type the same at its prompt: pick 64 cobblestone
--
-- With no key or no ender modem it still counts, shows and picks for the
-- site; only the base is not told (2026-10-03: CHI is local for now).
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
  local function opt(v) return (v and v ~= "") and v or nil end
  return { stock = stock, match = opt(t.match), screen = opt(t.screen), out = opt(t.out) }
end
local function saveCfg(c)
  return writeText(CFG, "stock=" .. table.concat(c.stock, ",") .. "\nmatch=" .. (c.match or "")
    .. "\nscreen=" .. (c.screen or "") .. "\nout=" .. (c.out or "") .. "\n")
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
-- Never the output: what is picked out is no longer stock.
local function stockOf(cfg)
  local out = {}
  local from = cfg.stock
  if cfg.match then from = inventories() end
  for _, n in ipairs(from) do
    if n ~= cfg.out and (not cfg.match or cfg.match == "all" or n:find(cfg.match, 1, true)) then out[#out + 1] = n end
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
  return totals, problems, stacks, lists
end

--- Move `amount` of the item `words` names into the output. ask(matches)
-- picks one of several (nil: refuse). Returns a line saying what happened.
local function pick(cfg, names, amount, words, ask)
  if not cfg.out then return "no output set - store setup" end
  if not peripheral.isPresent(cfg.out) then return "the output " .. cfg.out .. " is not on the network" end
  amount = math.floor(tonumber(amount) or 0)
  if amount < 1 then return "how many? pick <amount> <item>" end
  local invs = stockOf(cfg)
  local totals, _, _, lists = countNow(invs, names)
  local found = St.find(totals, names, words)
  if #found == 0 then return "nothing in stock matches " .. tostring(words) end
  local e = found[1]
  if #found > 1 then
    e = ask and ask(found) or nil
    if not e then return #found .. " items match - say which more exactly" end
  end
  local moves, planned = St.plan(lists, invs, e.key, amount)
  local moved, full = 0, false
  inBatches(moves, function(m)
    if full then return end
    local ok, n = pcall(peripheral.call, m.inv, "pushItems", cfg.out, m.slot, m.n)
    n = ok and tonumber(n) or 0
    moved = moved + n
    if n < m.n then full = true end
  end)
  local line = string.format("picked %s %s into %s", St.commas(moved), e.label, cfg.out)
  if moved < amount then
    line = line .. (full and moved < planned and " - the output is full" or
      string.format(" - only %s in stock", St.commas(planned)))
  end
  return line
end

-- several match: show them, and take a number
local function askWhich(found)
  for i = 1, math.min(#found, 9) do
    print(string.format("%d  %s  (%s)", i, found[i].label, St.commas(found[i].count)))
  end
  write("which? ")
  local n = tonumber(read() or "")
  return n and found[n] or nil
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
  -- the output: where picks go (a barrel for now, a dock's intake later)
  print("")
  print("Which is the output, where picked items go? A number from")
  print("the list, 0 for none, Enter keeps " .. (cfg.out or "none") .. ".")
  write("> ")
  local ans = read() or ""
  if tonumber(ans) == 0 then cfg.out = nil
  elseif tonumber(ans) and invs[tonumber(ans)] then cfg.out = invs[tonumber(ans)] end
  local now = stockOf(cfg)
  print(string.format("%d inventories are stock%s", #now, cfg.match and (" - every one with '" .. cfg.match
    .. "' in its name, now and later") or ""))
  if cfg.out then print("output: " .. cfg.out .. " - never counted as stock") end
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
    local ansM = read() or ""
    if tonumber(ansM) == 0 then cfg.screen = nil
    elseif tonumber(ansM) and mons[tonumber(ansM)] then cfg.screen = mons[tonumber(ansM)] end
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
  print("output: " .. (cfg.out and (cfg.out .. (peripheral.isPresent(cfg.out) and "" or " - NOT FOUND")) or "none - store setup"))
  print("stock:  " .. #invs .. " inventories" .. (cfg.match and (" (every '" .. cfg.match .. "')") or "")
    .. (#invs == 0 and " - store setup" or ""))
  for _, n in ipairs(invs) do
    local ok, size = pcall(peripheral.call, n, "size")
    print(string.format("  %-30s %s", n, ok and (size .. " slots") or "CANNOT READ - not on the network?"))
  end
  return
end

if cmd == "pick" then
  -- store pick <amount> <item words>: into the output, here and now
  print(pick(loadCfg(), loadNames(), args[2], table.concat(args, " ", 3), askWhich))
  return
end

if cmd ~= "run" then
  print("store [run | setup | count | status | pick <amount> <item>]")
  return
end

-- ------------------------------------------------------------------- run --
if not site then print("label this computer store-<site> first: label set store-chi") return end
-- With a key and a radio the base is sent the count; without, the site's
-- own screen and picking still work (Alex, 2026-10-03: "just local at CHI").
local key = SEC.readKeyFile(KEY)
local radio = link.findRadio(peripheral)
local tx = (key and radio) and SEC.sender(key, id, SEC.DIR.DRONE_TO_BASE, CTR) or nil
if not tx then
  print(not key and "no key: counting for this site only, nothing sent to the base"
    or "no ender modem: counting for this site only, nothing sent to the base")
end
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
local screen = { list = {}, top = 1, touched = -1e9, at = nil, problems = 0, sort = "count" }
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
    problems = screen.problems, sort = screen.sort })
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

local lastTotals, history = {}, {}
local function countLoop()
  while true do
    local cfg = loadCfg()
    local invs = stockOf(cfg)
    if #invs == 0 then
      screen.list, screen.problems = {}, 0
      print("no stock inventories yet - store setup")
    else
      local totals, problems = countNow(invs, names)
      lastTotals = totals
      St.remember(history, totals, os.clock())
      local okD, stamp = pcall(textutils.formatTime, os.time(), true)
      screen.list = UI and UI.list(totals, names, St.deltas(history, totals, os.clock())) or {}
      screen.problems, screen.at = #problems, okD and stamp or nil
      if os.clock() - lastSent >= St.EVERY then
        lastSent = os.clock()
        local kinds, items = summary(totals)
        local said = ""
        if tx then
          local sent, n = send(totals)
          said = string.format(" - %d/%d pages to the base", sent, n)
        end
        print(string.format("%s  %s items, %d kinds%s%s", screen.at or "", St.commas(items), kinds, said,
          #problems > 0 and ("  " .. #problems .. " unreadable") or ""))
      end
    end
    draw()
    -- every SCREEN_EVERY, or at once after a pick
    local timer = os.startTimer(SCREEN_EVERY)
    while true do
      local e, a = os.pullEvent()
      if (e == "timer" and a == timer) or e == "store_recount" then break end
    end
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
      elseif hit == "sort" then screen.sort, screen.top = UI.nextSort(screen.sort), 1 end
      if hit then screen.touched = os.clock() draw() end
    end
  end
end

-- typed at this computer while it runs: pick into the output, find an item
local function termLoop()
  print("type  pick <amount> <item>  or  find <item>")
  while true do
    write("> ")
    local line = read()
    -- no keyboard to read from: stop asking, but keep counting
    if line == nil then while true do os.pullEvent("store_never") end end
    local amount, words = line:match("^%s*pick%s+(%d+)%s+(.-)%s*$")
    if not amount then amount, words = line:match("^%s*(%d+)%s+(.-)%s*$") end
    local findWords = line:match("^%s*find%s+(.-)%s*$")
    if amount then
      print(pick(loadCfg(), names, amount, words, askWhich))
      os.queueEvent("store_recount")
    elseif findWords then
      local found = St.find(lastTotals, names, findWords)
      if #found == 0 then print("nothing in stock matches " .. findWords) end
      for i = 1, math.min(#found, 9) do print(string.format("%12s  %s", St.commas(found[i].count), found[i].label)) end
      if #found > 9 then print(string.format("  ...and %d more", #found - 9)) end
    elseif not line:match("^%s*$") then
      print("pick <amount> <item>  or  find <item>")
    end
  end
end

print(string.format("store %s: counting site %s every %d s%s", id, site, SCREEN_EVERY,
  tx and (", the base told every " .. St.EVERY .. " s, sealed") or ""))
parallel.waitForAny(countLoop, touchLoop, termLoop)
