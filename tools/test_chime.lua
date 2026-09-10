local DIR = ...
local pass, fail = 0, 0
local function check(n, c, d)
  if c then pass = pass + 1 print("  ok   " .. n)
  else fail = fail + 1 print("  FAIL " .. n .. (d and ("  " .. tostring(d)) or "")) end
end

local played, slept = {}, 0
local spk = { playNote = function(i, v, p) played[#played+1] = {i=i, v=v, p=p} return true end }
_G.sleep = function(t) slept = slept + (t or 0) coroutine.yield(t) end

local chime = dofile(DIR .. "/../lib/chime.lua")

print("no speaker: everything is a silent no-op")
check("play returns false", chime.play("docked") == false)
check("has() is false", chime.has() == false)

print("attached")
chime.attach(spk)
check("has() is true", chime.has())
check("known name queues", chime.play("docked") == true)
check("unknown name is ignored, not an error", chime.play("nonsense") == false)

-- drain the loop for a bounded number of steps
local function drain(steps)
  local co = coroutine.create(chime.loop)
  for _ = 1, steps do
    local ok, err = coroutine.resume(co)
    if not ok then return false, err end
  end
  return true
end

chime.detach() chime.attach(spk)   -- clear the queue left by the checks above
played = {}
chime.play("docked")
local ok, err = drain(12)
check("loop runs without error", ok, err)
check("docked played 3 notes", #played == 3, #played)
check("notes rise", played[1].p < played[2].p and played[2].p < played[3].p,
      table.concat({played[1].p, played[2].p, played[3].p}, ","))

print("every set is well formed")
local bad = {}
for name, seq in pairs(chime.sets) do
  for i, note in ipairs(seq) do
    if type(note.inst) ~= "string" then bad[#bad+1] = name .. " note " .. i .. " has no instrument" end
    if note.pitch < 0 or note.pitch > 24 then bad[#bad+1] = name .. " pitch " .. note.pitch .. " out of range" end
    if note.vol < 0 or note.vol > 3 then bad[#bad+1] = name .. " volume " .. note.vol .. " out of range" end
  end
end
check("all pitches 0-24 and volumes 0-3", #bad == 0, bad[1])

local valid = {}
for _, i in ipairs({"harp","basedrum","snare","hat","bass","flute","bell","guitar","chime",
                    "xylophone","iron_xylophone","cow_bell","didgeridoo","bit","banjo","pling"}) do
  valid[i] = true
end
local badInst = nil
for name, seq in pairs(chime.sets) do
  for _, note in ipairs(seq) do
    if not valid[note.inst] then badInst = name .. " uses " .. note.inst end
  end
end
check("all instruments are real", badInst == nil, badInst)

print("chord safety: no step exceeds 8 simultaneous notes")
local worst = 0
for _, seq in pairs(chime.sets) do
  local run = 0
  for _, note in ipairs(seq) do
    if note.wait == 0 then run = run + 1 else run = 0 end
    if run + 1 > worst then worst = run + 1 end
  end
end
check("worst chord is under the 8/tick limit", worst <= 8, worst)

print("queue does not build up")
for i = 1, 50 do chime.play("tick") end
played = {}
drain(30)
check("dropped the backlog rather than queueing 50", #played < 12, #played)

print("a broken speaker cannot kill the loop")
chime.attach({ playNote = function() error("speaker exploded") end })
chime.play("alarm")
ok, err = drain(12)
check("loop survives a throwing speaker", ok, err)

print("")
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then error("chime tests failed", 0) end
