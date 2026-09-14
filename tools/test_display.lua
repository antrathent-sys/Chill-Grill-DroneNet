local DIR = ...
local pass, fail = 0, 0
local function check(n, c, d)
  if c then pass = pass + 1 print("  ok   " .. n)
  else fail = fail + 1 print("  FAIL " .. n .. (d and ("  " .. tostring(d)) or "")) end
end

local D = dofile(DIR .. "/../lib/display.lua")

local function fakeTerm(w, h)
  local t = { w = w, h = h, blits = 0, grid = {}, palette = {}, pcalls = 0 }
  function t.getSize() return t.w, t.h end
  function t.setCursorPos(x, y) t.cx, t.cy = x, y end
  function t.blit(s, f, b)
    assert(#s == #f and #f == #b, "blit length mismatch")
    t.blits = t.blits + 1
    t.grid[t.cy] = { s = s, f = f, b = b }
  end
  function t.setPaletteColour(c, rgb) t.pcalls = t.pcalls + 1 t.palette[c] = rgb end
  return t
end

local function screenHas(t, needle)
  for y = 1, t.h do
    local r = t.grid[y]
    if r and r.s:find(needle, 1, true) then return y end
  end
  return nil
end

local function renderTo(w, h, m, now)
  local c = D.canvas(w, h)
  local t = fakeTerm(w, h)
  D.render(c, m, now)
  c:flush(t)
  return c, t
end

print("teletext")
local allRound = true
for pat = 0, 63 do
  local c = D.canvas(1, 1)
  local k = 0
  for sy = 1, 3 do
    for sx = 1, 2 do
      local bit = 2 ^ k
      if floor == nil then end
      if math.floor(pat / bit) % 2 == 1 then c:pix(sx, sy, "d") end
      k = k + 1
    end
  end
  local s, f, b = c:row(1)
  local code = s:byte(1)
  local on
  if code == 32 then on = 0
  elseif b == "d" then on = 63 - (code - 128)
  else on = code - 128 end
  if on ~= pat then allRound = false print("    pattern " .. pat .. " came back " .. tostring(on)) break end
end
check("all 64 pixel patterns round-trip through a cell", allRound)
local c1 = D.canvas(1, 1)
c1:pix(1, 1, "d") c1:text(1, 1, "A", "0")
check("text wins over pixels", (c1:row(1)) == "A")

print("helpers")
check("fmtInt thousands", D.fmtInt(5303) == "5,303" and D.fmtInt(-1234567) == "-1,234,567" and D.fmtInt(12) == "12",
  D.fmtInt(5303) .. " " .. D.fmtInt(-1234567))
check("fmtInt nil", D.fmtInt(nil) == "--")
check("fmtClock", D.fmtClock(2477) == "00:41:17", D.fmtClock(2477))
check("fmtEta", D.fmtEta(31.2) == "0:31" and D.fmtEta(nil) == "--:--")
check("niceStep", D.niceStep(830) == 1000 and D.niceStep(240) == 200 and D.niceStep(3.1) == 2,
  D.niceStep(830) .. " " .. D.niceStep(240))
check("arrow north", D.arrowFor(0, -100) == string.char(30))
check("arrow east", D.arrowFor(100, 0) == string.char(16))
check("arrow south", D.arrowFor(0, 100) == string.char(31))
check("arrow west", D.arrowFor(-100, 0) == string.char(17))
check("hovering shows a dot", D.arrowFor(0.5, 0.5) == "o")

print("model")
local route = D.parseRoute("cruise:2000.5:5000.5|hover:2000.5:5000.5|drop|dock:0.5:0.5")
check("route parses 4 legs", #route == 4 and route[3].kind == "drop" and route[3].x == nil and route[4].x == 0.5)
check("empty route", #D.parseRoute("") == 0 and #D.parseRoute(nil) == 0)
local m = D.newModel()
D.ingest(m, { id = "drone-2", x = 0, z = 0 }, 1)
D.ingest(m, { id = "drone-1", x = 0, z = 0 }, 1)
check("fleet order sorted, first seen selected", m.order[1] == "drone-1" and m.selected == "drone-2")
D.ingest(m, { id = "drone-1", x = 2, z = 2 }, 2)
check("trail ignores a move under 4 blocks", #m.drones["drone-1"].trail == 1)
D.ingest(m, { id = "drone-1", x = 10, z = 0 }, 3)
check("trail records a real move", #m.drones["drone-1"].trail == 2)
D.ingestPlan(m, { id = "drone-1", leg = 1, n = 2, route = "cruise:100:100|dock:0:0", hx = 0, hz = 0 }, 3)
check("plan sets home", m.home and m.home.x == 0)
check("state LIVE / STALE / LOST", D.droneState(m.drones["drone-1"], 4) == "LIVE"
  and D.droneState(m.drones["drone-1"], 12) == "STALE" and D.droneState(m.drones["drone-1"], 40) == "LOST")

print("palette")
local pt = fakeTerm(10, 10)
check("applyPalette redefines 16 slots", D.applyPalette(pt) and pt.pcalls == 16, pt.pcalls)
local pow2 = true
for col in pairs(pt.palette) do if math.floor(math.log(col) / math.log(2) + 0.5) ~= math.log(col) / math.log(2) then pow2 = false end end
check("palette slots are CC colour values", pow2)
check("no palette on a plain term is fine", D.applyPalette({}) == false)

print("render")
local NOW = 100.0   -- blink phases on
for _, size in ipairs({ { 100, 66 }, { 164, 80 }, { 71, 38 }, { 60, 30 } }) do
  local w, h = size[1], size[2]
  local ok, err = pcall(function()
    local c, t = renderTo(w, h, D.demoModel(NOW), NOW)
    local good = true
    for y = 1, h do
      local r = t.grid[y]
      if not r or #r.s ~= w or not r.f:match("^[0-9a-f]+$") or not r.b:match("^[0-9a-f]+$") then good = false end
    end
    assert(good, "a row is missing, the wrong width, or has a bad colour")
  end)
  check(string.format("demo renders at %dx%d", w, h), ok, err)
end
local c, t = renderTo(100, 66, D.demoModel(NOW), NOW)
check("header title", screenHas(t, "DRONENET") == 1)
check("status is ALERT with a lost drone", screenHas(t, "STATUS: ALERT") == 2)
check("tactical map title", screenHas(t, "TACTICAL MAP") ~= nil)
check("flight data panel", screenHas(t, "FLIGHT DATA") ~= nil and screenHas(t, "B/S") ~= nil)
check("selected drone tagged on the map with speed", screenHas(t, "DRONE-1 196B/S") ~= nil)
check("lost drone tagged", screenHas(t, "DRONE-3 LOST") ~= nil)
check("fleet lists all three", screenHas(t, "DRONE-2") and screenHas(t, "DRONE-3") and screenHas(t, "FLEET"))
check("home marker", screenHas(t, "HOME") ~= nil)
check("mission chain", screenHas(t, "[CRUISE]") ~= nil and screenHas(t, "[DOCK]") ~= nil and screenHas(t, "[DROP]") ~= nil)
check("leg progress", screenHas(t, "LEG PROGRESS") ~= nil)
check("scheduled trips with countdown", screenHas(t, "M-0043") ~= nil and screenHas(t, "T-00:18:20") ~= nil)
check("alert ticker names the lost drone", screenHas(t, "! LINK LOST DRONE-3") ~= nil)
local arrows = 0
local L = D.layout(100, 66)
for y = L.map.y + 1, L.map.y + L.map.h - 2 do
  local s = t.grid[y].s:sub(L.map.x + 1, L.map.x + L.map.w - 2)
  for _, a in ipairs({ 30, 16, 31, 17 }) do if s:find(string.char(a), 1, true) then arrows = arrows + 1 end end
end
check("a drone arrow is inside the map", arrows >= 1, arrows)

print("animation and flush")
local mapRows = function(tt)
  local out = {}
  for y = L.map.y + 1, L.map.y + L.map.h - 2 do out[#out + 1] = tt.grid[y].s:sub(1, L.map.w) end
  return table.concat(out, "\n")
end
local _, tA = renderTo(100, 66, D.demoModel(NOW), NOW)
local _, tB = renderTo(100, 66, D.demoModel(NOW), NOW + 0.125)
check("the active leg's dots march between frames", mapRows(tA) ~= mapRows(tB))
local cf = D.canvas(100, 66)
local tf = fakeTerm(100, 66)
local mm = D.demoModel(NOW)
D.render(cf, mm, NOW) local first = cf:flush(tf)
D.render(cf, mm, NOW) local again = cf:flush(tf)
check("first flush writes every row", first == 66, first)
check("an unchanged frame writes nothing", again == 0, again)

print("touch")
local ct = D.canvas(100, 66)
local mt = D.demoModel(NOW)
D.render(ct, mt, NOW)
local rowOf2
for y, h in pairs(ct.hits) do if h.id == "drone-2" then rowOf2 = y end end
check("fleet rows are touchable", rowOf2 ~= nil)
check("touch selects drone-2", rowOf2 and D.touch(ct, mt, L.side.x + 3, rowOf2) == "drone-2" and mt.selected == "drone-2")
check("touch outside the list does nothing", D.touch(ct, mt, 1, 1) == nil)
local _, t2 = renderTo(100, 66, mt, NOW)
check("flight data follows the selection", screenHas(t2, "DOCK  LATCHED") ~= nil)

print("empty and tiny")
local _, te = renderTo(100, 66, D.newModel(), NOW)
check("no drones: NO CONTACT", screenHas(te, "NO CONTACT") ~= nil and screenHas(te, "AWAITING TELEMETRY") ~= nil)
check("no drones: no mission", screenHas(te, "NO ACTIVE MISSION") ~= nil)
local _, ts = renderTo(40, 12, D.demoModel(NOW), NOW)
check("too small says so", screenHas(ts, "MONITOR TOO SMALL") ~= nil)

print("")
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then error("display tests failed", 0) end
