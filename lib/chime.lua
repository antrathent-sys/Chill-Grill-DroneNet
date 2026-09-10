--- chime: short note sequences for flight events.
--
-- Runs in its OWN coroutine. Nothing here may block the control loop, so
-- `play` only queues a name and returns immediately; the loop does the
-- sleeping. If there is no speaker, everything is a silent no-op.
--
--   local chime = dofile("lib/chime.lua")
--   chime.attach(peripheral.find("speaker"))
--   chime.play("docked")            -- returns instantly
--   parallel.waitForAny(controlLoop, chime.loop)
--
-- Notes are {instrument, pitch, volume}. Pitch is 0-24 semitones, 12 is the
-- middle. Steps sharing a `wait` of 0 sound together as a chord; the speaker
-- allows 8 notes per tick, so keep chords small.

local chime = {}

local B = 12          -- base pitch, middle of the range
local function n(inst, semi, vol, wait)
  return { inst = inst, pitch = math.max(0, math.min(24, B + semi)), vol = vol or 1, wait = wait or 0.12 }
end

--- The set. Rising means good, falling means finished, repeated means attend.
chime.sets = {
  -- power on: a confident major arpeggio
  boot      = { n("bell", -5, 1.0), n("bell", 0, 1.0), n("bell", 4, 1.0), n("bell", 7, 1.2, 0.3) },

  -- leaving the ground
  launch    = { n("bit", -7, 0.8, 0.08), n("bit", -3, 0.9, 0.08), n("bit", 0, 1.0, 0.08), n("bit", 5, 1.2, 0.25) },

  -- transitions, deliberately short so they do not step on each other
  climb     = { n("harp", 0, 0.7, 0.09), n("harp", 7, 0.8, 0.2) },
  dash      = { n("bit", 2, 0.9, 0.07), n("bit", 9, 1.0, 0.2) },
  brake     = { n("bass", 9, 0.9, 0.09), n("bass", 2, 0.9, 0.2) },
  hold      = { n("harp", 4, 0.6, 0.25) },

  -- docking: a searching pulse, then a lock
  align     = { n("hat", 0, 0.5, 0.1), n("hat", 0, 0.5, 0.3) },
  descend   = { n("cow_bell", 5, 0.7, 0.12), n("cow_bell", 0, 0.7, 0.3) },
  capture   = { n("chime", 0, 0.6, 0.15), n("chime", 3, 0.6, 0.15), n("chime", 7, 0.7, 0.3) },
  docked    = { n("chime", 0, 1.0, 0), n("chime", 7, 1.0, 0.15), n("chime", 12, 1.2, 0.4) },
  undocked  = { n("chime", 12, 0.9, 0.1), n("chime", 5, 0.9, 0.3) },

  -- delivery: the payoff
  delivered = { n("xylophone", 0, 1.0, 0.1), n("xylophone", 4, 1.0, 0.1),
                n("xylophone", 7, 1.0, 0.1), n("xylophone", 12, 1.3, 0.4) },

  -- attention. warn is a nag, alarm is a problem.
  warn      = { n("didgeridoo", -7, 1.0, 0.18), n("didgeridoo", -7, 1.0, 0.5) },
  alarm     = { n("basedrum", -12, 1.5, 0.1), n("snare", 0, 1.5, 0.1),
                n("basedrum", -12, 1.5, 0.1), n("snare", 0, 1.5, 0.35) },

  -- one tick, for altimeter callouts on the way down
  tick      = { n("hat", 7, 0.4, 0.05) },
  tickLow   = { n("hat", 0, 0.4, 0.05) },
}

local speaker = nil
local queue = {}
local MAXQ = 4          -- drop the oldest rather than build a backlog

function chime.attach(s) speaker = s return speaker ~= nil end
function chime.detach() speaker = nil queue = {} end
function chime.has() return speaker ~= nil end

--- Queue a chime by name. Returns immediately. Unknown names are ignored so a
-- typo in a phase name can never take a flight down.
function chime.play(name)
  if not speaker then return false end
  if not chime.sets[name] then return false end
  queue[#queue + 1] = name
  while #queue > MAXQ do table.remove(queue, 1) end
  return true
end

--- Play a rising or falling run, for altimeter style callouts.
-- `frac` 0..1 maps to the low..high end of the range.
function chime.pitchTick(frac)
  if not speaker then return false end
  local semi = math.floor(-9 + 18 * math.max(0, math.min(1, frac)))
  queue[#queue + 1] = { { inst = "hat", pitch = math.max(0, math.min(24, B + semi)), vol = 0.5, wait = 0.05 } }
  while #queue > MAXQ do table.remove(queue, 1) end
  return true
end

--- Play a sequence synchronously, blocking until it finishes. Only safe once
-- the flight is over, because it sleeps. The queued `play` is what the control
-- loop uses; this exists for the shutdown path, where the coroutine is already
-- dead and the last chime would otherwise never sound.
function chime.playNow(name)
  if not speaker then return false end
  local seq = chime.sets[name]
  if not seq then return false end
  for _, note in ipairs(seq) do
    pcall(speaker.playNote, note.inst, note.vol, note.pitch)
    if note.wait and note.wait > 0 then sleep(note.wait) end
  end
  return true
end

--- The coroutine. Never returns, never throws: if it died it would take the
-- flight down with it through parallel.waitForAny.
function chime.loop()
  while true do
    local item = table.remove(queue, 1)
    if item then
      local seq = type(item) == "string" and chime.sets[item] or item
      if seq then
        for _, note in ipairs(seq) do
          if speaker then pcall(speaker.playNote, note.inst, note.vol, note.pitch) end
          if note.wait and note.wait > 0 then sleep(note.wait) end
        end
      end
    else
      sleep(0.1)
    end
  end
end

return chime
