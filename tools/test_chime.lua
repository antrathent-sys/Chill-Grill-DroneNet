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
check("docked plays 4 notes, root included", #played == 4, #played)
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

print("the signature theme brackets a delivery")
local function pitches(name)
  chime.detach() chime.attach(spk) played = {}
  chime.play(name) drain(40)
  local t = {} for _, x in ipairs(played) do t[#t+1] = x.p end return t
end
local function has(seq, sub)
  for i = 0, #seq - #sub do
    local hit = true
    for j = 1, #sub do if seq[i+j] ~= sub[j] then hit = false break end end
    if hit then return true end
  end
  return false
end
local THEME = { 12, 19, 17, 24 }              -- 0 7 5 12 around the centre
check("boot opens with the theme", has(pitches("boot"), THEME), table.concat(pitches("boot"), " "))
check("delivered opens with the theme", has(pitches("delivered"), THEME))
check("home runs it backwards", has(pitches("home"), { 24, 17, 19, 12 }))

print("faults can jump the queue")
chime.detach() chime.attach(spk) played = {}
chime.play("hold") chime.play("hold") chime.play("hold")
chime.play("alarm", true)
drain(30)
check("alarm played first", played[1] and played[1].i == "basedrum", played[1] and played[1].i)

print("volume scales everything, including what is already queued")
chime.detach() chime.attach(spk) played = {}
chime.volume(0.5) chime.play("docked") drain(20)
local loud = played[#played].v
chime.volume(1.0) played = {}
chime.play("docked") drain(20)
check("half volume is half as loud", math.abs(loud * 2 - played[#played].v) < 1e-6,
      loud .. " vs " .. played[#played].v)
chime.volume(0) played = {}
chime.play("docked") drain(20)
check("zero volume plays nothing", #played == 0, #played)
chime.volume(1)

print("ad-hoc melodies and the name list")
chime.detach() chime.attach(spk) played = {}
check("melody queues", chime.melody({ { inst = "harp", pitch = 12, vol = 1, wait = 0.1 } }))
drain(6)
check("melody played", #played == 1, #played)
local names = chime.list()
check("list is sorted and populated", #names > 20 and names[1] < names[2], #names)

print("every set can finish: non-empty, and the last note waits")
local bad = nil
for _, name in ipairs(chime.list()) do
  local seq = chime.sets[name]
  if seq.inst then seq = { seq } end
  if #seq == 0 then bad = name .. " is empty"
  elseif not (seq[#seq].wait and seq[#seq].wait > 0) then bad = name .. " ends on wait 0" end
end
check("all sets terminate", bad == nil, bad)

print("the cruise groove is two bars and stays inside the chord limit")
local cruise = chime.sets.cruise
local steps, worst, cur = 0, 0, 0
for _, note in ipairs(cruise) do
  cur = cur + 1
  if note.wait > 0 then steps = steps + 1 if cur > worst then worst = cur end cur = 0 end
end
check("16 steps", steps == 16, steps)
check("at most 3 voices at once", worst <= 3, worst)

print("a broken speaker cannot kill the loop")
chime.attach({ playNote = function() error("speaker exploded") end })
chime.play("alarm")
ok, err = drain(12)
check("loop survives a throwing speaker", ok, err)

print("")
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then error("chime tests failed", 0) end
