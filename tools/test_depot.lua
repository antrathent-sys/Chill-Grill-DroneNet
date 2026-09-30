-- Desktop tests for depot.lua: the computer at a dock that works its loading
-- station. A pretend base on the other end of the radio sends it loads and
-- answers "have it stick", all sealed, and hears everything it says.
local DIR = ...
local pass, fail = 0, 0
local function check(n, c, d)
  if c then pass = pass + 1 print("  ok   " .. n)
  else fail = fail + 1 print("  FAIL " .. n .. (d and ("  " .. tostring(d)) or "")) end
end

dofile(DIR .. "/cc_shim.lua")
local S = dofile(DIR .. "/../lib/seclink.lua")
S.ROOT = DIR .. "/../"
local LINK = dofile(DIR .. "/../lib/link.lua")
local F = dofile(DIR .. "/../lib/fleet.lua")
local C = dofile(DIR .. "/../lib/cargo.lua")
local W = dofile(DIR .. "/cc_world.lua")
local KEYHEX = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
local KEY = S.parseKey(KEYHEX)

local STATION = [[
return {
  place = { left = { relay = "redstone_relay_0", side = "top" }, right = { relay = "redstone_relay_1", side = "top" } },
  assemble = { relay = "redstone_relay_2", side = "top" },
  lift = { relay = "redstone_relay_3", side = "top" },
  retract = { relay = "redstone_relay_3", side = "bottom" },
  stick = { left = "Create_Sticker_0", right = "Create_Sticker_1" },
  fill = { secs = 3 },
  silo = { left = "create:item_vault_0", right = "create:item_vault_1" },
  intake = "minecraft:chest_0",
  wait = { place = 1, assemble = 1, lift = 1, stick = 1, retract = 1 },
  liftoff = "ferry nowhere",
}
]]

-- opts: label, nokey, state (the .depotstate file), vaults, intake (items),
-- base = { stuck = true|false|nil (nil: never answers) }, loads = { { t, msg } }
local function depot(opts)
  local w = W.new(DIR, { label = opts.label == nil and "depot-pier" or opts.label or nil, S = S,
                         lines = opts.lines })
  if opts.station ~= false then w.files["station.lua"] = opts.station or STATION end
  if not opts.nokey then w.files[".dronekey"] = KEYHEX end
  if opts.state then w.files[".depotstate"] = opts.state end
  w.heard, w.sets, w.level = {}, {}, {}
  local baseTx = S.sender(KEY, "depot-pier", S.DIR.BASE_TO_DRONE, nil)
  local baseRx = S.receiver()
  local base = opts.base or { stuck = true }
  local function fromBase(t, msg)
    msg.to = msg.to or "depot-pier"
    w.at(t, function() return { "modem_message", "modem_ender", LINK.CHANNEL, LINK.CHANNEL, baseTx.seal(msg) } end)
  end
  w.fromBase = fromBase
  w.periph.modem_ender = { type = "modem", m = {
    isWireless = function() return true end, open = function() end,
    transmit = function(ch, _, env)
      local body = baseRx.open(env, function(id) return id == "depot-pier" and KEY or nil end, S.DIR.DRONE_TO_BASE)
      if not body then return end
      w.heard[#w.heard + 1] = body
      if body.type == "load.lifted" and base.stuck ~= nil then
        fromBase(w.clock + 0.3, F.loadStuck(body.load, base.stuck, (not base.stuck) and "not a sticker" or nil, "b-" .. #w.heard))
      end
    end } }
  for i = 0, 3 do
    local n = "redstone_relay_" .. i
    w.periph[n] = { type = "redstone_relay", m = {
      setOutput = function(side, on)
        w.sets[#w.sets + 1] = { t = w.clock, k = n .. ":" .. side, on = on }
        w.level[n .. ":" .. side] = on
      end,
      getAnalogInput = function() return 0 end } }
  end
  for name, items in pairs(opts.vaults or {}) do
    w.periph[name] = { type = "create:item_vault", m = { list = function()
      local l, i = {}, 0
      for n, c in pairs(items) do i = i + 1 l[i] = { name = n, count = c } end
      return l
    end } }
  end
  if opts.intake then
    w.periph["minecraft:chest_0"] = { type = "minecraft:chest", m = {
      list = function() return opts.intake > 0 and { [1] = { name = "minecraft:cobblestone", count = opts.intake } } or {} end,
      getItemDetail = function() return { name = "minecraft:cobblestone", maxCount = 64 } end } }
  end
  -- opts.printer = { paper = n, ink = n }: a CC printer. What it prints goes
  -- in its tray; pushItems puts a page where it is told (w.pagesInto)
  w.pages, w.pagesInto = {}, {}
  if opts.printer then
    local pr, tray, cur = opts.printer, {}, nil
    w.periph.printer_0 = { type = "printer", m = {
      getPaperLevel = function() return pr.paper end, getInkLevel = function() return pr.ink end,
      newPage = function()
        if pr.paper < 1 or pr.ink < 1 then return false end
        cur = { title = "", lines = {} } return true end,
      setPageTitle = function(t) cur.title = t end,
      setCursorPos = function(_, y) cur.y = y end,
      write = function(t) cur.lines[cur.y] = t end,
      endPage = function()
        pr.paper, pr.ink = pr.paper - 1, pr.ink - 1
        w.pages[#w.pages + 1] = cur
        tray[#tray + 1] = cur
        return true end,
      list = function()
        local l = {}
        for i, pg in ipairs(tray) do l[7 + i] = { name = "computercraft:printed_page", count = 1 } end
        return l end,
      getItemDetail = function(slot) local pg = tray[slot - 7] return pg and { displayName = pg.title } or nil end,
      pushItems = function(into, slot)
        local pg = table.remove(tray, slot - 7)
        if not pg then return 0 end
        w.pagesInto[#w.pagesInto + 1] = { into = into, title = pg.title }
        return 1 end,
    } }
  end
  for _, l in ipairs(opts.loads or {}) do fromBase(l[1], l[2]) end
  return w
end
local function heardOf(w, ty)
  local t = {}
  for _, b in ipairs(w.heard) do if b.type == ty then t[#t + 1] = b end end
  return t
end
local function onCount(w, k)
  local n = 0
  for _, s in ipairs(w.sets) do if s.k == k and s.on then n = n + 1 end end
  return n
end
local VAULTS = { ["create:item_vault_0"] = { ["minecraft:cobblestone"] = 640 } }
local VAULTS2 = { ["create:item_vault_0"] = { ["minecraft:cobblestone"] = 2500 },
                  ["create:item_vault_1"] = { ["minecraft:cobblestone"] = 2400, ["minecraft:iron_ingot"] = 100 } }

print("awake")
local w = depot({}):run("depot.lua", {}, 35)
local hi = heardOf(w, "depot.hello")
check("it says hello to the base as soon as it wakes, sealed", w.err == nil and hi[1] and hi[1].depot == "depot-pier", w.err)
check("...and every 10 s while it is awake", #hi == 4, #hi)
check("nothing moves without a load", #w.sets == 0)

print("a load from the base")
w = depot({ vaults = VAULTS, loads = { { 2, F.loadStart("L1", "drone-1", 640, 64, "b-1") } } }):run("depot.lua", {}, 60)
local steps = {}
for _, b in ipairs(heardOf(w, "load.step")) do steps[#steps + 1] = b.step end
check("it works the machines and reports every step", table.concat(steps, " "):find("place fill fill assemble dock lift stick retract liftoff", 1, true) ~= nil,
  table.concat(steps, " "))
local lifted = heardOf(w, "load.lifted")[1]
check("once the silos are up it asks the base to have the drone stick", lifted and lifted.load == "L1"
  and lifted.stickers == "Create_Sticker_0")
local done = heardOf(w, "load.done")[1]
check("and ends with what it counted in each silo", done and done.ok == true and done.sides == "left"
  and done.stickers == "Create_Sticker_0" and C.unpack(done.silo_left)["minecraft:cobblestone"] == 640
  and done.counted == "read from the silos", done and tostring(done.why))
check("the liftoff is the base's: it flies nothing, says it is over to the base", w.text:find("over to the base", 1, true) ~= nil)
check("the lift came down after the stick", onCount(w, "redstone_relay_3:bottom") == 1)
check("no state file is left behind", w.files[".depotstate"] == nil)

w = depot({ vaults = VAULTS2, loads = { { 2, F.loadStart("L2", "drone-1", 5000, 64, "b-2") } } }):run("depot.lua", {}, 60)
done = heardOf(w, "load.done")[1]
check("two silos: both counted, both stickers", done and done.ok and done.sides == "left,right"
  and done.stickers == "Create_Sticker_0,Create_Sticker_1"
  and C.unpack(done.silo_right)["minecraft:iron_ingot"] == 100, done and tostring(done.why))

w = depot({ vaults = VAULTS, intake = 640, loads = { { 2, F.loadStart("L3", "drone-1", nil, nil, "b-3") } } }):run("depot.lua", {}, 60)
done = heardOf(w, "load.done")[1]
check("no number from the base: it counts its own intake", done and done.ok, done and tostring(done.why))
w = depot({ intake = 0, loads = { { 2, F.loadStart("L4", "drone-1", nil, nil, "b-4") } } }):run("depot.lua", {}, 30)
done = heardOf(w, "load.done")[1]
check("...and an empty intake is a load that never starts", done and done.ok == false and done.why == "the intake is empty"
  and #w.sets == 0, done and done.why)

print("when it goes wrong")
w = depot({ vaults = VAULTS, base = { stuck = false }, loads = { { 2, F.loadStart("L5", "drone-1", 640, 64, "b-5") } } }):run("depot.lua", {}, 60)
done = heardOf(w, "load.done")[1]
check("the drone could not stick: called off at stick, lift down", done and done.ok == false and done.at == "stick"
  and onCount(w, "redstone_relay_3:bottom") == 1, done and done.why)
w = depot({ vaults = VAULTS, base = {}, loads = { { 2, F.loadStart("L6", "drone-1", 640, 64, "b-6") } } }):run("depot.lua", {}, 80)
done = heardOf(w, "load.done")[1]
check("no word from the base: called off after 20 s", done and done.ok == false and tostring(done.why):find("no word", 1, true),
  done and done.why)
w = depot({ vaults = { ["create:item_vault_0"] = {} }, loads = { { 2, F.loadStart("L7", "drone-1", 640, 64, "b-7") } } }):run("depot.lua", {}, 60)
done = heardOf(w, "load.done")[1]
check("empty silos: called off before assembling", done and done.ok == false and done.at == "fill"
  and onCount(w, "redstone_relay_2:top") == 0, done and done.why)

print("only the base, only for this depot")
w = depot({ vaults = VAULTS })
local stranger = S.sender(S.parseKey(string.rep("ab", 32)), "depot-pier", S.DIR.BASE_TO_DRONE, nil)
w.at(2, function() return { "modem_message", "modem_ender", LINK.CHANNEL, LINK.CHANNEL,
  stranger.seal(F.loadStart("L8", "drone-1", 640, 64, "x-1")) } end)
w.at(3, { "modem_message", "modem_ender", LINK.CHANNEL, LINK.CHANNEL, F.loadStart("L9", "drone-1", 640, 64, "x-2") })
w.fromBase(4, (function() local m = F.loadStart("L10", "drone-1", 640, 64, "x-3") m.to = "depot-farm" return m end)())
w:run("depot.lua", {}, 30)
check("a load sealed with another key, sent in the clear, or meant for another depot: nothing moves",
  #w.sets == 0 and #heardOf(w, "load.step") == 0)

print("after a restart part way through a load")
w = depot({ state = "L11 stick" }):run("depot.lua", {}, 25)
hi = heardOf(w, "depot.hello")
check("it lowers the lift at once", onCount(w, "redstone_relay_3:bottom") == 1 and w.sets[1].k == "redstone_relay_3:bottom")
check("and tells the base which load it was in and where", hi[1] and hi[1].load == "L11" and hi[1].step == "stick")
check("...then forgets it", w.files[".depotstate"] == nil)
w = depot({ state = "L12 fill" }):run("depot.lua", {}, 5)
check("stopped before the lift: nothing to lower", onCount(w, "redstone_relay_3:bottom") == 0)

print("setting up")
w = depot({ label = false }):run("depot.lua", {}, 5)
check("not labelled depot-<dock>: says how", w.text:find("label set depot-", 1, true) ~= nil and #w.heard == 0)
w = depot({ nokey = true }):run("depot.lua", {}, 5)
check("no key: says how", w.text:find("seckey new depot-pier", 1, true) ~= nil)
w = depot({ lines = { "y" } }):run("depot.lua", { "test", "lift" }, 5)
check("depot test lift: fires the lift face and lets go", onCount(w, "redstone_relay_3:top") == 1
  and w.level["redstone_relay_3:top"] == false and w.ended)
w = depot({ vaults = VAULTS, intake = 64 }):run("depot.lua", { "status" }, 5)
check("depot status: bays, key, radio, silos and intake", w.text:find("2 bays", 1, true) and w.text:find("key: yes", 1, true)
  and w.text:find("silo left: create:item_vault_0 readable", 1, true) and w.text:find("64 items", 1, true), w.text)

print("probing the dock before there is a station")
-- a relay face that places a silo: firing it makes a new inventory appear
w = depot({ vaults = VAULTS, intake = 64, lines = { "y" } })
w.periph["redstone_relay_1"].m.setOutput = function(side, on)
  w.sets[#w.sets + 1] = { t = w.clock, k = "redstone_relay_1:" .. side, on = on }
  w.level["redstone_relay_1:" .. side] = on
  if side == "top" and on then
    w.periph["create:item_vault_9"] = { type = "create:item_vault",
      m = { list = function() return {} end, size = function() return 60 end } }
  end
end
w = w:run("depot.lua", { "probe", "fire", "redstone_relay_1:top", "1" }, 20)
check("probe fire names the machine that moved: a silo appeared", w.err == nil
  and w.text:find("NEW inventory create:item_vault_9", 1, true) ~= nil, w.err or w.text)
check("...and puts the face back", w.level["redstone_relay_1:top"] == false)

w = depot({ vaults = VAULTS, intake = 64 }):run("depot.lua", { "probe" }, 10)
check("probe lists every relay face and inventory", w.err == nil and w.text:find("4 relays", 1, true)
  and w.text:find("create:item_vault_0", 1, true) and w.text:find("640 cobblestone", 1, true) ~= nil,
  w.err or w.text)
check("...and how to go on", w.text:find("probe fire", 1, true) and w.text:find("probe set", 1, true) ~= nil)

w = depot({ lines = { "y" } }):run("depot.lua", { "probe", "set", "redstone_relay_2:bottom", "on" }, 10)
check("probe set holds a face on, for a toggle", w.err == nil
  and w.level["redstone_relay_2:bottom"] == true
  and w.text:find("set redstone_relay_2:bottom ON", 1, true) ~= nil, w.err or w.text)
w = depot({ lines = { "n" } }):run("depot.lua", { "probe", "fire", "redstone_relay_0:top" }, 10)
check("it asks first", #w.sets == 0 and w.text:find("nothing changed", 1, true) ~= nil)
w = depot({ lines = { "y" } }):run("depot.lua", { "probe", "fire", "nosuch:top" }, 10)
check("a relay that is not there is refused", #w.sets == 0
  and w.text:find("not on this computer", 1, true) ~= nil)
w = depot({ station = false }):run("depot.lua", { "probe" }, 10)
check("it runs before there is any station.lua", w.err == nil and w.text:find("relay", 1, true) ~= nil, w.err)
check("...and `depot` itself says to probe first", depot({ station = false }):run("depot.lua", {}, 5).text
  :find("depot probe", 1, true) ~= nil)

-- kept and pushed, so a probing session can be read from anywhere
w = depot({ vaults = VAULTS, intake = 64 }):run("depot.lua", { "probe" }, 10)
check("what it printed is kept in probe.txt", (w.files["probe.txt"] or ""):find("create:item_vault_0", 1, true) ~= nil
  and (w.files["probe.txt"] or ""):find("depot-pier", 1, true) ~= nil, w.files["probe.txt"])
check("...and it says how to send it when it cannot push", w.text:find("paste probe.txt", 1, true) ~= nil)
w = depot({ vaults = VAULTS, lines = { "y" } })
w.files["upload.lua"] = "-- pretend"
w.files["probe.txt"] = "---- an earlier look ----\n"
w.env.http = {}
w.ran = {}
w.env.shell = { run = function(...) w.ran[#w.ran + 1] = table.concat({ ... }, " ") return true end }
w = w:run("depot.lua", { "probe" }, 10)
check("with http and upload.lua it pushes it to this machine's own folder",
  w.ran[1] == "upload sync probe.txt machines/depot-pier/probe.txt", w.ran[1] or "nothing run")
check("...appending to what was there, not replacing it",
  (w.files["probe.txt"] or ""):find("an earlier look", 1, true) ~= nil)
w = depot({ station = false })
w.files["probe.txt"] = "old\n"
w = w:run("depot.lua", { "probe", "clear" }, 5)
check("probe clear starts a fresh one", w.files["probe.txt"] == nil and w.text:find("fresh", 1, true) ~= nil)

print("walking every relay")
w = depot({ lines = { "y",
  "p", "A", "p",          -- redstone_relay_0: placement, side A, ON places a silo
  "p", "b", "r",          -- redstone_relay_1: placement, side B (lower case), ON removes
  "b", "A", "f",          -- redstone_relay_2: belt, side A, ON fills the cargo
  "n" } })                -- redstone_relay_3: nothing
w = w:run("depot.lua", { "probe", "map", "1" }, 60)
local rel = w.files["relays.lua"] or ""
check("it walks every relay and writes relays.lua", w.err == nil and rel:find("redstone_relay_3", 1, true) ~= nil,
  w.err or rel)
check("...with what each one works, which side, and what ON does",
  rel:find('{ relay = "redstone_relay_0", device = "place", side = "A", on = "places" }', 1, true) ~= nil
  and rel:find('{ relay = "redstone_relay_1", device = "place", side = "B", on = "removes" }', 1, true) ~= nil
  and rel:find('{ relay = "redstone_relay_2", device = "belt", side = "A", on = "fills" }', 1, true) ~= nil
  and rel:find('{ relay = "redstone_relay_3", device = "nothing" }', 1, true) ~= nil, rel)
check("relays.lua is data a station can be read from", (function()
  local f = loadstring(rel)
  local ok, t = pcall(f)
  return ok and type(t) == "table" and #t == 4 and t[3].device == "belt"
end)())
check("it says what it did not find", w.text:find("not found: A assemble, A pusher, B assemble, B belt, B pusher", 1, true) ~= nil,
  w.text)
check("every relay is back off at the end", (function()
  for k, v in pairs(w.level) do if v then return false, k end end
  return true
end)())
check("...and each one was on, every face, while it was asked about", (function()
  local faces = 0
  for _, s in ipairs(w.sets) do if s.k:find("^redstone_relay_2:") and s.on then faces = faces + 1 end end
  return faces == 6
end)())
check("the walk goes in probe.txt too", (w.files["probe.txt"] or ""):find("the map:", 1, true) ~= nil)
w = depot({ lines = { "n" } }):run("depot.lua", { "probe", "map" }, 10)
check("it asks before anything moves", #w.sets == 0 and w.files["relays.lua"] == nil)

print("the two-sided dock, driven by hand")
local DOCK = [[return {
  sides = { A = { place = "redstone_relay_0", assemble = "redstone_relay_1", pusher = "redstone_relay_2" } },
  storage = { "create:item_vault_0" },
  wait = { pulse = 1, place = 1, assemble = 1, push = 1, retract = 1, step = 1 },
  fill = { settle = 2, start = 5, max = 30 },
}]]
-- the vault drains 64 a second once the silo has been assembled
local function seqDock(lines)
  local w = depot({ lines = lines })
  w.files["dock.lua"] = DOCK
  local store = 640
  w.periph["create:item_vault_0"] = { type = "create:item_vault", m = { list = function()
    if w.level["redstone_relay_1:top"] ~= nil then store = math.max(0, store - 16) end
    return store > 0 and { [1] = { name = "minecraft:cobblestone", count = store } } or {}
  end } }
  return w
end
w = seqDock({ "y" })
-- ENT for the drone, with `ask`: latched, then stuck
-- the fill takes ~45 s here (640 at 16 a look); the drone is ready after that
w.at(70, { "key", 28 })
w.at(80, { "key", 28 })
w = w:run("depot.lua", { "seq", "load", "A", "ask" }, 150)
check("depot seq load A runs the side's machines in order", w.err == nil
  and w.text:find("PLACE", 1, true) and w.text:find("ASSEMBLE", 1, true) and w.text:find("FILL", 1, true)
  and w.text:find("load done", 1, true) ~= nil, w.err or w.text)
check("...waits for ENT where the drone would act", w.text:find("the drone: latch it on the dock", 1, true)
  and w.text:find("the drone: stick the silo", 1, true) ~= nil)
check("...and remembers side A has no silo now", (w.files[".dockstate"] or ""):find("A=none", 1, true) ~= nil,
  w.files[".dockstate"])
check("...every relay off at the end", (function()
  for k, v in pairs(w.level) do if v then return false end end
  return true
end)())
check("the run is kept in probe.txt", (w.files["probe.txt"] or ""):find("load side A", 1, true) ~= nil)

w = seqDock({ "y" })
w.at(70, { "key", 45 })            -- X at the latch prompt
w = w:run("depot.lua", { "seq", "load", "A", "ask" }, 150)
check("X calls it off, and it says where", w.text:find("called off at dock", 1, true) ~= nil, w.text)

w = seqDock({})
w = w:run("depot.lua", { "seq", "silo", "A", "empty" }, 5)
check("depot seq silo A empty corrects what it remembers", (w.files[".dockstate"] or ""):find("A=empty", 1, true) ~= nil)
w = seqDock({ "n" })
w = w:run("depot.lua", { "seq", "load", "A" }, 10)
check("it asks before anything moves", w.text:find("nothing moved", 1, true) ~= nil and (function()
  for _, s in ipairs(w.sets) do if s.on then return false end end
  return true
end)())
w = depot({})
w = w:run("depot.lua", { "seq" }, 5)
check("no dock.lua: says where it comes from", w.text:find("machines/depot-pier/dock.lua", 1, true) ~= nil, w.text)

print("the placer's feed")
local FDOCK = DOCK:gsub('pusher = "redstone_relay_2" }', 'pusher = "redstone_relay_2", feed = "minecraft:chest_7" }')
local function feedDock(lines, blocks)
  local fw = seqDock(lines)
  fw.files["dock.lua"] = FDOCK
  fw.periph["minecraft:chest_7"] = { type = "minecraft:chest", m = { list = function()
    return { [1] = { name = "create_connected:item_silo", count = blocks }, [2] = { name = "minecraft:dirt", count = 9 } }
  end } }
  return fw
end
w = feedDock({}, 7)
w = w:run("depot.lua", { "seq" }, 5)
check("depot seq shows each feed's silo blocks and the payloads they make, counting nothing else",
  w.text:find("7 silo blocks (2 payloads)", 1, true) ~= nil, w.text)
w = feedDock({ "y" }, 2)
w = w:run("depot.lua", { "seq", "load", "A" }, 30)
check("a feed short of a payload: the load is called off at the feed, nothing placed",
  w.text:find("called off at feed", 1, true) ~= nil and (function()
    for _, st in ipairs(w.sets) do if st.k:find("^redstone_relay_0:") and st.on then return false end end
    return true
  end)(), w.text)

print("the lasers across the bays")
-- laser_sensor_3 watches side A, laser_sensor_4 side B; relay 0 places a silo
-- on A, which blocks A's beam
local function laserDepot(lines)
  local w = depot({ lines = lines })
  w.bayA = false
  -- as Alex's are: power high when a silo is in the bay, low when not
  w.periph["laser_sensor_3"] = { type = "laser_sensor", m = {
    getClosestHitDistance = function() if w.bayA then return 4.5 end return nil end,
    getPower = function() return w.bayA and 15 or 0 end } }
  w.periph["laser_sensor_4"] = { type = "laser_sensor", m = {
    getClosestHitDistance = function() return 3 end,
    getPower = function() return 15 end } }
  local set = w.periph["redstone_relay_0"].m.setOutput
  w.periph["redstone_relay_0"].m.setOutput = function(side, on)
    if on then w.bayA = true end
    return set(side, on)
  end
  return w
end
w = laserDepot({}):run("depot.lua", { "probe" }, 10)
check("depot probe lists each laser sensor with its power", w.err == nil
  and w.text:find("laser_sensor_3 (laser_sensor)  power 0  no beam", 1, true) ~= nil
  and w.text:find("laser_sensor_4 (laser_sensor)  power 15  beam hitting at 3.0", 1, true) ~= nil, w.err or w.text)
check("...and that goes in probe.txt", (w.files["probe.txt"] or ""):find("laser_sensor_3", 1, true) ~= nil)
w = laserDepot({ "y" }):run("depot.lua", { "probe", "fire", "redstone_relay_0", "1" }, 20)
check("probe fire says when a sensor's power changes: a silo arrived", w.err == nil
  and w.text:find("laser_sensor_3: power 0 -> 15, beam hitting", 1, true) ~= nil, w.err or w.text)
w = laserDepot({ "y", "p", "A", "p", "n", "n", "n" }):run("depot.lua", { "probe", "map", "1" }, 60)
check("the map walk shows it too, as the placer runs", w.text:find("laser_sensor_3: power 0 -> 15", 1, true) ~= nil,
  w.text)
w = laserDepot({})
w.files["dock.lua"] = [[return {
  sides = { A = { place = "redstone_relay_0", pusher = "redstone_relay_2" }, B = { pusher = "redstone_relay_3" } },
  detect = { A = "laser_sensor_3", B = "laser_sensor_4" },
}]]
w = w:run("depot.lua", { "seq" }, 5)
check("depot seq shows what each side's sensor sees, and its power", w.err == nil
  and w.text:find("detector laser_sensor_3: the bay is clear (power 0)", 1, true) ~= nil
  and w.text:find("detector laser_sensor_4: a silo is in the bay (power 15)", 1, true) ~= nil, w.err or w.text)
w = laserDepot({})
w.files["dock.lua"] = [[return { sides = { A = { pusher = "redstone_relay_2" } }, detect = { A = "laser_sensor_9" } }]]
w = w:run("depot.lua", { "seq" }, 5)
check("...and says so plainly when the name is wrong", w.text:find("laser_sensor_9: NOT FOUND", 1, true) ~= nil, w.text)

print("a sensor the probe has never met")
local function opticalDepot(lines)
  local w = depot({ lines = lines })
  w.bayA = false
  w.periph["optical_sensor_6"] = { type = "optical_sensor", m = {
    getPower = function() return w.bayA and 15 or 0 end,
    isDetecting = function() return w.bayA end,
    getRange = function() return 16 end,
    setRange = function() error("a setter must never be called") end } }
  local set = w.periph["redstone_relay_0"].m.setOutput
  w.periph["redstone_relay_0"].m.setOutput = function(side, on)
    if on then w.bayA = true end
    return set(side, on)
  end
  return w
end
w = opticalDepot({}):run("depot.lua", { "probe" }, 10)
check("depot probe lists what an unknown device says, and what it can be asked", w.err == nil
  and w.text:find("optical_sensor_6 (optical_sensor)  getPower=0 getRange=16 isDetecting=false", 1, true) ~= nil
  and w.text:find("methods: getPower, getRange, isDetecting, setRange", 1, true) ~= nil, w.err or w.text)
w = opticalDepot({ "y" }):run("depot.lua", { "probe", "fire", "redstone_relay_0", "1" }, 20)
check("probe fire shows the sensor changing as the silo lands", w.err == nil
  and w.text:find("optical_sensor_6 getPower 0 -> 15", 1, true) ~= nil
  and w.text:find("optical_sensor_6 isDetecting false -> true", 1, true) ~= nil, w.err or w.text)
check("...and it never calls a setter", w.err == nil)
w = opticalDepot({ "y", "p", "A", "p", "n", "n", "n" }):run("depot.lua", { "probe", "map", "1" }, 60)
check("the map walk shows it too", w.text:find("optical_sensor_6 getPower 0 -> 15", 1, true) ~= nil, w.text)

print("an optical sensor, inverted")
local function opticalSeq(hitA)
  local w = depot({})
  w.files["dock.lua"] = [[return {
    sides = { A = { place = "redstone_relay_0", pusher = "redstone_relay_2" } },
    detect = { A = "optical_sensor_6" }, silo_when = "low",
  }]]
  w.periph["optical_sensor_6"] = { type = "optical_sensor", m = {
    hasHit = function() return hitA end,
    getBlock = function() return "create_connected:item_silo" end,
    getDistance = function() return 0.5155 end,
    getRange = function() return 15 end } }
  return w
end
w = opticalSeq(true):run("depot.lua", { "seq" }, 5)
check("a hit, inverted, is a clear bay - and it says what the sensor hit", w.err == nil
  and w.text:find("detector optical_sensor_6: the bay is clear (hit create_connected:item_silo at 0.52)", 1, true) ~= nil,
  w.err or w.text)
-- a side with its own storage on the status screen: it counts it (this
-- crashed on the dock - the counter was defined below the status code)
w = opticalSeq(true)
w.files["dock.lua"] = [[return {
  sides = { A = { place = "redstone_relay_0", pusher = "redstone_relay_2", storage = "create:item_vault_0" } },
  detect = { A = "optical_sensor_6" }, silo_when = "low",
}]]
w.periph["create:item_vault_0"] = { type = "create:item_vault", m = { list = function()
  return { [1] = { name = "minecraft:barrel", count = 64 } } end } }
w = w:run("depot.lua", { "seq" }, 5)
check("depot seq shows each side's own storage and how much is in it", w.err == nil
  and w.text:find("storage A: create:item_vault_0, 64 items", 1, true) ~= nil, w.err or w.text)
w = opticalSeq(false):run("depot.lua", { "seq" }, 5)
check("no hit, inverted, is a silo in the bay", w.text:find("detector optical_sensor_6: a silo is in the bay (no hit)", 1, true) ~= nil,
  w.text)

print("putting the dock at rest")
w = depot({})
w.files["dock.lua"] = [[return {
  sides = { A = { place = "redstone_relay_0", assemble = "redstone_relay_1", pusher = "redstone_relay_2",
                  belt = "redstone_relay_3", belt_on = "fills" } },
}]]
w.level["redstone_relay_3:top"] = true           -- a belt left loading
w.level["redstone_relay_2:top"] = true           -- and a pusher left up
w = w:run("depot.lua", { "seq", "rest" }, 5)
check("depot seq rest: everything off, and the belt back to unloading", w.err == nil
  and (function() for k, v in pairs(w.level) do if v then return false, k end end return true end)()
  and w.text:find("side A belt redstone_relay_3 OFF (unloading)", 1, true) ~= nil, w.err or w.text)
w = depot({})
w.files["dock.lua"] = [[return { sides = { A = { pusher = "redstone_relay_2", belt = "redstone_relay_3", belt_on = "fills" } } }]]
w.files[".dockstate"] = "A=full\nB=none\n"
w = w:run("depot.lua", { "seq", "rest" }, 5)
check("...but a filled silo waiting keeps its belt loading", w.level["redstone_relay_3:top"] == true
  and w.text:find("a filled silo is waiting: loading", 1, true) ~= nil, w.text)

print("the drone taken to be ready")
w = seqDock({ "y" })
w = w:run("depot.lua", { "seq", "load", "A" }, 150)
check("without `ask` a load runs to the end with no key pressed for the drone", w.err == nil
  and w.text:find("load done", 1, true) ~= nil
  and w.text:find("the drone: latch it on the dock - taken as done", 1, true) ~= nil
  and w.text:find("the drone: stick the silo (stickers out) - taken as done", 1, true) ~= nil, w.err or w.text)
w = seqDock({ "y" })
w = w:run("depot.lua", { "seq", "load", "A", "640" }, 150)
check("...and a count still works beside it", w.err == nil and w.text:find("640 items", 1, true) ~= nil, w.err or w.text)

print("depot stock: what the factory holds, through its Stock Ticker")
local requested = 0
local function ticker(w)
  w.periph["Create_StockTicker_0"] = { type = "Create_StockTicker", m = {
    stock = function(detailed)
      return {
        [1] = { name = "minecraft:gravel", displayName = "Gravel", count = 900 },
        [2] = { name = "minecraft:cobblestone", displayName = "Cobblestone", count = 12000 },
        [3] = { name = "minecraft:cobblestone", displayName = "Cobblestone", count = 400 },
      }
    end,
    requestFiltered = function() requested = requested + 1 return 0 end,
    getStockItemDetail = function() error("needs a slot", 0) end,
  } }
end
w = depot({ station = false })
ticker(w)
w.files["upload.lua"] = "-- pretend"
w.env.http = {}
w.ran = {}
w.env.shell = { run = function(...) w.ran[#w.ran + 1] = table.concat({ ... }, " ") return true end }
w = w:run("depot.lua", { "stock" }, 5)
check("it finds the ticker and reads every linked vault, needing no station.lua",
  w.err == nil and w.text:find("2 kinds, 13300 items", 1, true) ~= nil, w.err or w.text)
check("most first, the same item added together",
  w.text:find("12400  Cobblestone", 1, true) ~= nil and w.text:find("12400", 1, true) < w.text:find("900  Gravel", 1, true))
check("kept in stock.txt and pushed to this machine's folder",
  (w.files["stock.txt"] or ""):find("Cobblestone", 1, true) ~= nil
  and w.ran[1] == "upload sync stock.txt machines/depot-pier/stock.txt", w.ran[1])
check("read only: it never asks the ticker to send anything", requested == 0, requested)
w = depot({ station = false }):run("depot.lua", { "stock" }, 5)
check("no ticker on the network: says how to fit one", w.err == nil
  and w.text:find("no Stock Ticker on this network", 1, true) ~= nil, w.err or w.text)

print("depot stock send: one request, by hand, to test the route")
local asked = {}
local function sender(w)
  w.periph["Create_StockTicker_0"] = { type = "Create_StockTicker", m = {
    stock = function()
      return { [1] = { name = "minecraft:cobblestone", displayName = "Cobblestone", count = 12400, maxCount = 64 } }
    end,
    requestFiltered = function(address, filter)
      asked[#asked + 1] = { address = address, filter = filter }
      return filter._requestCount or 12400
    end,
  } }
end
w = depot({ station = false, lines = { "y" } })
sender(w)
w = w:run("depot.lua", { "stock", "send", "3776", "cobblestone", "cinder-A" }, 5)
check("after a yes, one request: the count, the item's full id, the packager's address",
  w.err == nil and #asked == 1 and asked[1].address == "cinder-A"
  and asked[1].filter.name == "minecraft:cobblestone" and asked[1].filter._requestCount == 3776
  and w.text:find("sending 3776", 1, true) ~= nil, w.err or #asked)
w = depot({ station = false, lines = { "n" } })
sender(w)
w = w:run("depot.lua", { "stock", "send", "100", "cobblestone", "cinder-A" }, 5)
check("anything but yes sends nothing", #asked == 1 and w.text:find("nothing sent", 1, true) ~= nil)
w = depot({ station = false, lines = { "y" } })
sender(w)
w = w:run("depot.lua", { "stock", "send", "9000", "cobblestone", "cinder-A" }, 5)
check("more than one silo of it is refused, even after a yes", #asked == 1
  and w.text:find("not sent", 1, true) ~= nil, w.text)
w = depot({ station = false, lines = { "y" } })
sender(w)
w = w:run("depot.lua", { "stock", "send", "10", "netherite_block", "cinder-A" }, 5)
check("something the factory does not hold is refused", #asked == 1
  and w.text:find("holds none", 1, true) ~= nil)

print("depot stock: the loader's silos")
w = depot({ station = false })
w.periph["Create_StockTicker_0"] = { type = "Create_StockTicker", m = {
  stock = function()
    return { [1] = { name = "minecraft:cobblestone", displayName = "Cobblestone", count = 500, maxCount = 64 },
             [2] = { name = "create_connected:item_silo", displayName = "Item Silo", count = 312, maxCount = 64 } }
  end,
  requestFiltered = function() error("nothing should be asked") end,
} }
w = w:run("depot.lua", { "stock" }, 5)
check("counted in payloads and dual flights", w.text:find("312 blocks - 104 payloads, 52 dual flights", 1, true) ~= nil,
  w.err or w.text)
w = depot({ station = false, lines = {} })
sender(w)
w = w:run("depot.lua", { "stock" }, 5)
check("none in stock: it says so", w.text:find("silos: NONE", 1, true) ~= nil, w.err or w.text)

print("invoices: one per silo, printed from its own count, put in the silo")
local O = dofile(DIR .. "/../lib/orders.lua")
O.use(dofile(DIR .. "/../lib/invoice.lua"))
local ord = O.replay(O.accepted(1, "C-0042", { who = "steve", to = { x = 1200, y = 70, z = 340 }, price = 1500,
  lines = { { item = "minecraft:cobblestone", amount = 10000, stack = 64 } } }))["C-0042"]
local invF = O.invoiceFields(ord, O.nextFlight(ord), "2026-09-30")
local function orderLoad(id, nonce) return F.loadStart(id, "drone-1", 5000, 64, nonce, "1200", invF) end
w = depot({ vaults = VAULTS2, printer = { paper = 5, ink = 5 }, loads = { { 2, orderLoad("C-0042.1", "b-i1") } } }):run("depot.lua", {}, 80)
local pg1, pg2 = w.pages[1], w.pages[2]
check("two silos, two pages: C-0042-1 and C-0042-2", w.err == nil and #w.pages == 2 and pg1.title == "CINDER INVOICE C-0042-1"
  and pg2 and pg2.title == "CINDER INVOICE C-0042-2", w.err or #w.pages)
local t1, t2 = table.concat(pg1 and pg1.lines or {}, "\n"), table.concat(pg2 and pg2.lines or {}, "\n")
check("each says what was counted into its own silo, and the second counts the first as shipped before",
  t1:find("THIS SHIPMENT%s+2,500") and t2:find("THIS SHIPMENT%s+2,400") and t2:find("SHIPPED BEFORE%s+2,500")
  and t1:find("1 OF 3") and t2:find("2 OF 3"), t1 .. "\n--\n" .. t2)
check("each page goes into its own silo while it is still a block", #w.pagesInto == 2
  and w.pagesInto[1].into == "create:item_vault_0" and w.pagesInto[2].into == "create:item_vault_1")
local said = {}
for _, b in ipairs(heardOf(w, "load.step")) do if b.step == "invoice" then said[#said + 1] = b.text end end
check("the base hears each one", #said == 2 and said[1]:find("C-0042-1 printed, in the left silo", 1, true), table.concat(said, " / "))
local done1 = heardOf(w, "load.done")[1]
check("and the load goes on", done1 and done1.ok == true)
w = depot({ vaults = VAULTS2, printer = { paper = 0, ink = 5 }, loads = { { 2, orderLoad("C-0042.1", "b-i2") } } }):run("depot.lua", {}, 80)
local said2 = {}
for _, b in ipairs(heardOf(w, "load.step")) do if b.step == "invoice" then said2[#said2 + 1] = b.text end end
check("out of paper: the page is skipped and said so, and the load still goes", #w.pages == 0
  and (said2[1] or ""):find("not printed: no paper", 1, true) and heardOf(w, "load.done")[1].ok == true, said2[1])
w = depot({ vaults = VAULTS, printer = { paper = 5, ink = 5 }, loads = { { 2, F.loadStart("C-0043.1", "drone-1", 640, 64, "b-i3") } } }):run("depot.lua", {}, 60)
check("a load that is not a customer's order prints nothing", w.err == nil and #w.pages == 0)
w = depot({ printer = { paper = 5, ink = 5 } }):run("depot.lua", { "print" }, 10)
check("depot print: a sample page, and the name it reads back as", w.err == nil and #w.pages == 1
  and w.text:find("CINDER INVOICE C-0000-1", 1, true) and w.text:find("named \"CINDER INVOICE C-0000-1\"", 1, true), w.err or w.text)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then error("depot tests failed", 0) end
