-- Desktop tests for the site stock: lib/store.lua (counting, pages, the
-- base's side), lib/storeui.lua (the stock list screen) and store.lua on a
-- stand-in computer with vaults, a monitor and a radio.
local DIR = ...
local pass, fail = 0, 0
local function check(n, c, d)
  if c then pass = pass + 1 print("  ok   " .. n)
  else fail = fail + 1 print("  FAIL " .. n .. (d and ("  " .. tostring(d)) or "")) end
end
dofile(DIR .. "/cc_shim.lua")
local St = dofile(DIR .. "/../lib/store.lua")
local UI = dofile(DIR .. "/../lib/storeui.lua")
local D = dofile(DIR .. "/../lib/display.lua")
local T = dofile(DIR .. "/../lib/tui.lua")
local S = dofile(DIR .. "/../lib/seclink.lua")
S.ROOT = DIR .. "/../"
local W = dofile(DIR .. "/cc_world.lua")

print("counting")
check("an item's key: its id, and the hash of its own data when it has any",
  St.keyOf({ name = "minecraft:stone", count = 5 }) == "minecraft:stone"
  and St.keyOf({ name = "minecraft:enchanted_book", count = 1, nbt = "ab12" }) == "minecraft:enchanted_book#ab12")
local lists = {
  vault_0 = { [1] = { name = "minecraft:stone", count = 64 }, [2] = { name = "minecraft:stone", count = 30 },
              [5] = { name = "minecraft:enchanted_book", count = 1, nbt = "aa" } },
  vault_1 = { [1] = { name = "minecraft:stone", count = 64 }, [9] = { name = "minecraft:enchanted_book", count = 2, nbt = "bb" } },
}
local totals, problems, stacks = St.count(lists, { "vault_0", "vault_1", "vault_9" })
check("summed across every inventory, by item", totals["minecraft:stone"].count == 158 and stacks == 5)
check("...two books with different enchantments are two items", totals["minecraft:enchanted_book#aa"].count == 1
  and totals["minecraft:enchanted_book#bb"].count == 2)
check("...and one that cannot be read is said, not taken as empty", #problems == 1 and problems[1]:find("vault_9", 1, true))
check("a book's name says what is on it", St.label({ displayName = "Enchanted Book",
  enchantments = { { displayName = "Sharpness V" }, { displayName = "Unbreaking III" } } })
  == "Enchanted Book (Sharpness V, Unbreaking III)")
check("the site is the store's own name: store-chi counts for CHI", St.siteOf("store-chi") == "CHI"
  and St.siteOf("depot-chid1") == nil and St.siteOf(nil) == nil)
check("numbers with commas", St.commas(1234567) == "1,234,567" and St.commas(999) == "999" and St.commas(0) == "0")

print("pages, and the base")
-- a big site: 600 kinds, far more than one sealed message holds
local big, bigNames = {}, {}
for i = 1, 600 do
  local k = string.format("somemod:item_number_%04d", i)
  big[k] = { count = i * 100 }
  bigNames[k] = "Some Item Number " .. i
end
local pages = St.pages(1700000000123, big, bigNames)
local biggest, seenKinds = 0, 0
for _, p in ipairs(pages) do
  biggest = math.max(biggest, #p.items)
  for _ in p.items:gmatch("[^\n]+") do seenKinds = seenKinds + 1 end
end
check("a big count goes in pages, each under what a sealed message holds", #pages > 1 and biggest <= St.PAGE_BYTES
  and seenKinds == 600, #pages .. " pages, biggest " .. biggest)
check("an empty site still sends one page", #St.pages(1, {}, {}) == 1)
local st = St.new()
local r1 = St.take(st, "store-chi", pages[2], 100)
local rDup = St.take(st, "store-chi", pages[2], 100)
check("pages may come in any order, twice even, and the count waits for all of them", r1 == false and rDup == false
  and st.sites.CHI == nil)
for i = #pages, 1, -1 do if i ~= 2 then St.take(st, "store-chi", pages[i], 100) end end
local got = 0
for _ in pairs(st.sites.CHI and st.sites.CHI.items or {}) do got = got + 1 end
check("...then the site's count is whole", got == 600 and st.sites.CHI.items["somemod:item_number_0600"].count == 60000
  and st.sites.CHI.items["somemod:item_number_0001"].label == "Some Item Number 1")
local small = St.pages(1700000099999, { ["minecraft:stone"] = { count = 5 } }, { ["minecraft:stone"] = "Stone" })
local done, site = St.take(st, "store-chi", small[1], 200)
check("a newer count replaces the site's last one whole", done == true and site == "CHI"
  and st.sites.CHI.items["somemod:item_number_0001"] == nil and st.sites.CHI.items["minecraft:stone"].count == 5)
local refused, why = St.take(st, "depot-chid1", small[1], 200)
check("only a store's key counts a site", refused == nil and tostring(why):find("not a store", 1, true))
check("a page that is not one is refused", St.take(st, "store-chi", { rep = 1, page = 3, pages = 2, items = "" }, 1) == nil
  and St.take(st, "store-chi", { rep = 1, page = 1, pages = 1, items = "nonsense" }, 1) == nil)
St.take(st, "store-north", St.pages(5, { ["minecraft:stone"] = { count = 7 }, ["minecraft:dirt"] = { count = 3 } },
  { ["minecraft:stone"] = "Stone", ["minecraft:dirt"] = "Dirt" })[1], 300)
local all = St.merge(st)
local stone
for _, e in ipairs(all) do if e.key == "minecraft:stone" then stone = e end end
check("customers see one stock: every site added up, the base knowing which has what", #all == 2 and stone.count == 12
  and stone.sites.CHI == 5 and stone.sites.NORTH == 7 and stone.label == "Stone")
local again = St.load(St.serialise(st))
check("the base's file reads back the same", again.sites.CHI.items["minecraft:stone"].count == 5
  and again.sites.NORTH.items["minecraft:dirt"].label == "Dirt" and again.sites.NORTH.at == 300)

print("the stock list screen")
local sl = UI.list({ a = { count = 5 }, b = { count = 500 }, c = { count = 50 } }, { a = "Apple", b = "Brick", c = "Coal" })
check("sorted by how many, the most first", sl[1].label == "Brick" and sl[2].label == "Coal" and sl[3].label == "Apple")
local long = {}
for i = 1, 80 do long[i] = { key = "k" .. i, label = "Item " .. i, count = 100000 - i } end
local function shot(w, h, view)
  local c = D.canvas(w, h)
  local hits, top = UI.render(T, c, view)
  local rows = {}
  for y = 1, h do rows[y] = (c:row(y)):gsub("[\128-\255]", " ") end
  return table.concat(rows, "\n"), hits, top, c
end
local txt, hits, top, cv = shot(39, 33, { site = "CHI", list = long, top = 1, at = "12:04" })
check("4x5 at text scale 1: the site, the total, kinds, when counted", txt:find("CINDER STOCK  CHI", 1, true)
  and txt:find("7,996,760 ITEMS", 1, true) and txt:find("80 KINDS", 1, true) and txt:find("COUNTED 12:04", 1, true), txt)
check("...ranked rows with the count on the right", txt:find(" 1 ITEM 1 ", 1, true) and txt:find("99,999", 1, true), txt)
local rows = UI.rows(cv)
check("...where it is in the list, and the buttons", txt:find("1-" .. rows .. " OF 80", 1, true) and txt:find("UP", 1, true)
  and txt:find("DOWN", 1, true) and txt:find("1/" .. math.ceil(80 / rows), 1, true), txt)
check("a touch on DOWN, UP, the page number", UI.hit(hits, 35, 32) == "down" and UI.hit(hits, 3, 32) == "up"
  and UI.hit(hits, 20, 32) == "top" and UI.hit(hits, 20, 10) == nil)
local endTxt, _, endTop = shot(39, 33, { site = "CHI", list = long, top = 999 })
check("scrolled past the end: held on the last screenful, the last page", endTop == 80 - rows + 1
  and endTxt:find("ITEM 80", 1, true) and endTxt:find(math.ceil(80 / rows) .. "/" .. math.ceil(80 / rows), 1, true), endTop)
check("an unreadable inventory is said, in full", shot(39, 33, { site = "CHI", list = long, at = "12:05", problems = 1 })
  :find("1 UNREADABLE", 1, true))
check("an empty site says so", shot(39, 33, { site = "CHI", list = {} }):find("NOTHING COUNTED YET", 1, true))

print("the store computer")
local KEYHEX = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
local KEY = S.parseKey(KEYHEX)
local function vault(w, name, items)
  w.periph[name] = { type = "create:item_vault", types = { "inventory" }, m = {
    size = function() return 60 end,
    list = function() return w.vaults[name] end,
    pushItems = function(to, slot, n)
      local it = w.vaults[name][slot]
      local out = w.vaults[to]
      if not (it and out) then return 0 end
      local room = (w.room or 1e9) - (w.inOut or 0)
      local k = math.max(0, math.min(n, it.count, room))
      it.count = it.count - k
      if it.count == 0 then w.vaults[name][slot] = nil end
      out[#out + 1] = { name = it.name, count = k }
      w.inOut = (w.inOut or 0) + k
      return k
    end,
    getItemDetail = function(slot)
      local it = w.vaults[name][slot]
      return it and { name = it.name, count = it.count, displayName = it.name:gsub("^.*:", ""):gsub("^%l", string.upper) }
    end } }
  w.vaults[name] = items
end
local function storeWorld(cfg, lines)
  local w = W.new(DIR, { label = "store-chi", S = S, lines = lines })
  w.vaults, w.sent, w.rows = {}, {}, {}
  w.files[".dronekey"] = KEYHEX .. "\n"
  w.files["store.cfg"] = cfg or "match=vault\nscreen=monitor_0\n"
  for _, f in ipairs({ "lib/store.lua", "lib/storeui.lua", "lib/display.lua", "lib/tui.lua", "lib/seclink.lua",
                       "lib/link.lua", "lib/fleet.lua" }) do
    local h = io.open(DIR .. "/../" .. f, "r")
    w.files[f] = h:read("*a") h:close()
  end
  w.periph.modem_0 = { type = "modem", m = { isWireless = function() return true end, open = function() end,
    transmit = function(ch, _, env) w.sent[#w.sent + 1] = { t = w.clock, env = env } end } }
  local cy = 1
  w.periph.monitor_0 = { type = "monitor", m = { setTextScale = function() end, setPaletteColour = function() end,
    getSize = function() return 39, 33 end, setCursorPos = function(_, y) cy = y end,
    blit = function(s) w.rows[cy] = s:gsub("[\128-\255]", " ") end } }
  vault(w, "create:item_vault_0", { [1] = { name = "minecraft:stone", count = 64 }, [2] = { name = "minecraft:coal", count = 9 } })
  vault(w, "create:item_vault_1", { [1] = { name = "minecraft:stone", count = 40 } })
  return w
end
local sw = storeWorld()
sw.at(20, function(world)
  -- a third vault cabled in, and more coal, while it runs
  vault(world, "create:item_vault_2", { [3] = { name = "minecraft:coal", count = 500 } })
  return { "noop" }
end)
local seenScreen = {}
sw.at(14, function(world) local t = {} for y = 1, 33 do t[y] = world.rows[y] or "" end seenScreen.first = table.concat(t, "\n") return { "noop" } end)
sw.at(40, function(world) local t = {} for y = 1, 33 do t[y] = world.rows[y] or "" end seenScreen.later = table.concat(t, "\n") return { "noop" } end)
sw = sw:run("store.lua", {}, 70)
local base, rx = St.new(), S.receiver()
for _, s in ipairs(sw.sent) do
  local body = rx.open(s.env, function(id) return id == "store-chi" and KEY or nil end, S.DIR.DRONE_TO_BASE, nil)
  if body and body.type == "stock.page" then St.take(base, "store-chi", body, s.t) end
end
check("it counts the vaults and sends the base its count, sealed with its own key", sw.err == nil and base.sites.CHI
  and base.sites.CHI.items["minecraft:stone"].count == 104 and base.sites.CHI.items["minecraft:stone"].label == "Stone",
  sw.err or sw.text)
check("...one count a minute to the base, not one every 15 s", #sw.sent >= 1 and #sw.sent <= 3, #sw.sent)
check("the stock list on its screen, the most first", (seenScreen.first or ""):find("CINDER STOCK  CHI", 1, true)
  and (seenScreen.first or ""):find("1 STONE", 1, true), seenScreen.first)
check("...and a vault cabled in later counted with no setup: coal now first", (seenScreen.later or ""):find("1 COAL", 1, true)
  and (seenScreen.later or ""):find("509", 1, true), seenScreen.later)

local cw = storeWorld("stock=create:item_vault_0\n")
cw = cw:run("store.lua", { "count" }, 5)
check("store count: what is there, nothing sent", cw.text:find("73 items, 2 kinds", 1, true) and #cw.sent == 0, cw.err or cw.text)
local nolabel = storeWorld()
nolabel.env.os.getComputerLabel = function() return "chi-stock" end
nolabel = nolabel:run("store.lua", {}, 3)
check("not labelled store-<site>: says so, sends nothing", nolabel.text:find("label set store-chi", 1, true) and #nolabel.sent == 0)
local setupW = W.new(DIR, { label = "store-chi", S = S, lines = { "vault", "2", "1" } })
setupW.vaults = {}
for _, f in ipairs({ "lib/store.lua", "lib/seclink.lua", "lib/link.lua", "lib/fleet.lua" }) do
  local h = io.open(DIR .. "/../" .. f, "r") setupW.files[f] = h:read("*a") h:close()
end
vault(setupW, "create:item_vault_0", {})
vault(setupW, "minecraft:chest_0", {})
setupW.periph.monitor_3 = { type = "monitor", m = { getSize = function() return 39, 33 end } }
setupW = setupW:run("store.lua", { "setup" }, 5)
check("store setup: a word is a rule (vaults now and later), the output and the monitor picked",
  (setupW.files["store.cfg"] or ""):find("match=vault", 1, true) and (setupW.files["store.cfg"] or ""):find("screen=monitor_3", 1, true)
  and (setupW.files["store.cfg"] or ""):find("out=minecraft:chest_0", 1, true)
  and setupW.text:find("1 inventories are stock", 1, true), setupW.err or setupW.text)

print("picking")
local tf = { ["minecraft:stone"] = { count = 500 }, ["minecraft:stone_bricks"] = { count = 40 },
             ["minecraft:enchanted_book#aa"] = { count = 2 } }
local nf = { ["minecraft:stone"] = "Stone", ["minecraft:stone_bricks"] = "Stone Bricks",
             ["minecraft:enchanted_book#aa"] = "Enchanted Book (Mending)" }
check("find by words: several match, the most first", #St.find(tf, nf, "stone") == 1 and St.find(tf, nf, "stone")[1].label == "Stone"
  and #St.find(tf, nf, "bricks") == 1 and #St.find(tf, nf, "st") == 2 and St.find(tf, nf, "st")[1].label == "Stone")
check("...an exact name wins on its own, and data-items by what is on them", St.find(tf, nf, "mending")[1].count == 2
  and #St.find(tf, nf, "nothing like it") == 0)
local pl = { v0 = { [1] = { name = "minecraft:stone", count = 20 }, [2] = { name = "minecraft:stone", count = 64 } },
             v1 = { [4] = { name = "minecraft:stone", count = 64 } } }
local moves, planned = St.plan(pl, { "v0", "v1" }, "minecraft:stone", 100)
check("a pick takes the fullest stacks first, only what is asked", planned == 100 and #moves == 2 and moves[1].n == 64
  and moves[2].n == 36)
local _, short = St.plan(pl, { "v0", "v1" }, "minecraft:stone", 1000)
check("...and says when there is not that much", short == 148)

local function barrelWorld(lines, room)
  local w = storeWorld("match=vault\nscreen=monitor_0\nout=minecraft:barrel_0\n", lines)
  w.vaults["minecraft:barrel_0"] = {}
  w.periph["minecraft:barrel_0"] = { type = "minecraft:barrel", types = { "inventory" }, m = {
    size = function() return 27 end, list = function() return w.vaults["minecraft:barrel_0"] end } }
  w.room = room
  return w
end
local function inBarrel(w, item)
  local n = 0
  for _, it in pairs(w.vaults["minecraft:barrel_0"]) do if it.name == item then n = n + it.count end end
  return n
end
local pw = barrelWorld():run("store.lua", { "pick", "70", "stone" }, 5)
check("store pick: that many into the output, out of the vaults", inBarrel(pw, "minecraft:stone") == 70
  and pw.text:find("picked 70 Stone into minecraft:barrel_0", 1, true), pw.err or pw.text)
local pshort = barrelWorld():run("store.lua", { "pick", "500", "coal" }, 5)
check("...not that much in stock: all there is, and says so", inBarrel(pshort, "minecraft:coal") == 9
  and pshort.text:find("only 9 in stock", 1, true), pshort.err or pshort.text)
local pfull = barrelWorld(nil, 50):run("store.lua", { "pick", "100", "stone" }, 5)
check("...the output full: what fitted, and says so", inBarrel(pfull, "minecraft:stone") == 50
  and pfull.text:find("the output is full", 1, true), pfull.err or pfull.text)
local typed = barrelWorld({ "pick 30 stone", "find coal" })
typed.files[".dronekey"] = nil
typed = typed:run("store.lua", {}, 40)
local tscreen = {}
for y = 1, 33 do tscreen[y] = typed.rows[y] or "" end
check("while it runs: typed at its prompt, into the output, and the screen counts it gone", inBarrel(typed, "minecraft:stone") == 30
  and table.concat(tscreen, "\n"):find("74", 1, true) and typed.text:find("9  Coal", 1, true), typed.err or typed.text)
check("...no key: counts and picks for the site, sends the base nothing", #typed.sent == 0
  and typed.text:find("counting for this site only", 1, true), typed.text)
local nobase = barrelWorld()
nobase = nobase:run("store.lua", { "count" }, 5)
check("the output is never counted as stock", not nobase.text:find("barrel", 1, true) and nobase.text:find("113 items", 1, true),
  nobase.text)

print("")
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then error("store tests failed", 0) end
