--- chime: short note sequences for flight events.
--
-- Runs in its OWN coroutine. Nothing here may block the control loop, so
-- `play` only queues a name and returns immediately; the loop does the
-- sleeping. If there is no speaker, everything is a silent no-op.
--
--   local chime = dofile("lib/chime.lua")
--   chime.attach(peripheral.find("speaker"))
--   chime.play("docked")            -- returns instantly
--   chime.play("alarm", true)       -- jumps the queue
--   parallel.waitForAny(controlLoop, chime.loop)
--
-- Notes are {inst, pitch, vol, wait}. Pitch is 0-24 semitones and 12 is the
-- middle, so the helpers below take offsets from the centre and clamp. Steps
-- sharing a `wait` of 0 sound together as a chord; the speaker allows 8 notes
-- per tick, so chords stay small.
--
-- THE GRAMMAR, so a new sound joins the family instead of being invented
-- twice:
--   rising      something began and is going well
--   falling     something finished, or is being given up
--   repeated    attend to this
--   dissonant   broken
--   THEME       the craft's own signature, 0 7 5 12. It opens `boot`, closes
--               `delivered`, and runs backwards for `home`, so the same four
--               notes bracket a whole delivery.

local chime = {}

local B = 12          -- base pitch, middle of the range
local VOL = 1.0       -- global scale, see chime.volume()

local function n(inst, semi, vol, wait)
  return { inst = inst,
           pitch = math.max(0, math.min(24, B + semi)),
           vol = math.max(0, math.min(3, vol or 1)),
           wait = wait or 0.12 }
end

--- Notes that sound together: everything waits 0 except the last.
local function ch(inst, semis, vol, wait)
  local out = {}
  for i, s in ipairs(semis) do
    out[#out + 1] = n(inst, s, vol, i == #semis and (wait or 0.12) or 0)
  end
  return out
end

--- A melodic run: one note per entry, same instrument, even spacing.
local function run(inst, semis, vol, step, tail)
  local out = {}
  for i, s in ipairs(semis) do
    out[#out + 1] = n(inst, s, vol, i == #semis and (tail or step or 0.12) or (step or 0.12))
  end
  return out
end

local function cat(...)
  local out = {}
  for _, part in ipairs({ ... }) do
    if part.inst then out[#out + 1] = part                      -- a bare note
    else for _, x in ipairs(part) do out[#out + 1] = x end end   -- a sequence
  end
  return out
end

local THEME      = { 0, 7, 5, 12 }
local THEME_BACK = { 12, 5, 7, 0 }

--- The set. Add a name here and any phase of that name chimes automatically,
-- because fly.lua's enter() plays the phase name.
chime.sets = {
  -- ---------- power and readiness ----------
  -- the signature over a root in the bass, resolving onto the tonic chord
  boot        = cat(n("bass", -12, 0.9, 0),
                    run("bell", THEME, 1.0, 0.16),
                    ch("bell", { 0, 4, 7, 12 }, 1.2, 0.5)),
  ready       = run("pling", { 7, 12 }, 0.9, 0.09, 0.25),
  preflight_ok   = cat(run("pling", { 0, 4, 7 }, 0.9, 0.08),
                       n("chime", 12, 1.0, 0.35)),
  preflight_fail = run("didgeridoo", { -2, -9 }, 1.1, 0.22, 0.5),
  shutdown    = cat(n("bass", -12, 0.8, 0),
                    run("bell", { 7, 0 }, 0.9, 0.2, 0.45)),

  -- ---------- getting airborne ----------
  -- a thump under an accelerating run: the pitch steps shrink as it climbs
  launch      = cat(n("basedrum", -12, 1.5, 0),
                    run("bit", { -12, -7, -3, 0, 4, 7 }, 1.0, 0.07),
                    n("basedrum", -12, 1.2, 0),
                    ch("bit", { 0, 7, 12 }, 1.3, 0.4)),
  climb       = run("harp", { 0, 7 }, 0.75, 0.09, 0.2),
  find        = run("harp", { 0, 5 }, 0.7, 0.12, 0.35),   -- unresolved: still looking
  fly         = run("harp", { 4, 7 }, 0.6, 0.1, 0.25),

  -- ---------- cruise ----------
  dash        = run("bit", { 2, 7, 12 }, 1.0, 0.06, 0.2),
  brake       = cat(n("hat", 0, 0.5, 0), run("bass", { 9, 2 }, 0.95, 0.09, 0.2)),
  hold        = n("harp", 4, 0.6, 0.25),

  -- ---------- docking ----------
  align       = cat(run("hat", { 0, 0 }, 0.5, 0.1), n("pling", 7, 0.6, 0.3)),
  descend     = run("cow_bell", { 5, 2, 0 }, 0.75, 0.11, 0.3),
  capture     = cat(run("chime", { 0, 3, 7 }, 0.7, 0.13), n("snare", 0, 0.8, 0.3)),
  -- the lock: bass root and a chime fifth together, then the octave over it
  docked      = cat(n("bass", -12, 1.0, 0), ch("chime", { 0, 7 }, 1.0, 0.16),
                    n("chime", 12, 1.2, 0.45)),
  undocked    = cat(run("chime", { 12, 7 }, 0.9, 0.1), n("bass", -12, 0.8, 0.35)),

  -- ---------- landing ----------
  -- a long settle, then the weight arriving on the legs
  land        = cat(run("harp", { 12, 9, 7, 4, 2, 0 }, 0.7, 0.09),
                    n("basedrum", -12, 1.0, 0.3)),
  touchdown   = cat(n("basedrum", -12, 1.3, 0), n("bell", -5, 0.9, 0.4)),

  -- ---------- payload ----------
  -- release: the run falls away from you, then lands somewhere below
  drop        = cat(run("xylophone", { 12, 9, 5, 0, -5 }, 0.9, 0.06),
                    n("bass", -12, 0.7, 0.55)),
  delivered   = cat(run("xylophone", THEME, 1.0, 0.12),
                    n("snare", 0, 0.7, 0),
                    ch("xylophone", { 12, 16, 19 }, 1.3, 0.5)),
  home        = cat(run("bell", THEME_BACK, 0.9, 0.14),
                    ch("bell", { 0, 7 }, 1.0, 0.4)),

  -- ---------- attention ----------
  -- warn nags; alarm is a problem; the two faults that can end a flight get
  -- their own voices so you know which one it is without reading the screen
  warn        = run("didgeridoo", { -7, -7 }, 1.0, 0.18, 0.5),
  alarm       = cat(n("basedrum", -12, 1.5, 0), n("snare", 0, 1.5, 0.1),
                    n("basedrum", -12, 1.5, 0), n("snare", 0, 1.5, 0.1),
                    n("basedrum", -12, 1.5, 0), n("snare", 0, 1.5, 0.35)),
  -- a tritone, deliberately wrong-sounding: a corner has stopped answering
  lost        = cat(ch("bit", { 0, 6 }, 1.3, 0.16), ch("bit", { 0, 6 }, 1.3, 0.4)),
  -- wobble, because that is what the craft is doing
  spin        = run("banjo", { 0, 5, 0, 5, 0 }, 1.0, 0.07, 0.3),
  lowpower    = run("didgeridoo", { 0, -3, -7, -12 }, 1.0, 0.14, 0.4),
  lowfuel     = run("didgeridoo", { -2, -5, -9 }, 1.0, 0.16, 0.4),

  -- ---------- housekeeping ----------
  upload      = run("bit", { 12, 16, 12, 19 }, 0.6, 0.05, 0.2),

  -- one tick, for altimeter callouts on the way down
  tick        = n("hat", 7, 0.4, 0.05),
  tickLow     = n("hat", 0, 0.4, 0.05),
}

--- An opt-in groove for long cruises: two bars of a minor-pentatonic riff,
-- bass on the beat, hat on the offbeat, banjo on top. Queue it again when you
-- want another two bars - it deliberately does not loop itself, so it can
-- never crowd a real chime out of a four-deep queue.
do
  local bass = { 0, nil, 0, nil, 3, nil, 0, nil, 0, nil, 0, nil, -2, nil, 0, nil }
  local lead = { 12, 15, 12, 10, nil, 10, 12, nil, 12, 15, 17, 15, 12, 10, nil, nil }
  local seq, step = {}, 0.13
  for i = 1, 16 do
    local before = #seq
    if bass[i] then seq[#seq + 1] = n("bass", bass[i] - 12, 0.9, 0) end
    if lead[i] then seq[#seq + 1] = n("banjo", lead[i], 0.55, 0) end
    if i % 2 == 0 then seq[#seq + 1] = n("hat", 0, 0.35, 0) end
    if #seq == before then seq[#seq + 1] = n("hat", 0, 0, 0) end   -- a rest still waits
    seq[#seq].wait = step
  end
  chime.sets.cruise = seq
end

local speaker = nil
local queue = {}
local MAXQ = 4          -- drop the oldest rather than build a backlog

function chime.attach(s) speaker = s return speaker ~= nil end
function chime.detach() speaker = nil queue = {} end
function chime.has() return speaker ~= nil end

--- Global volume scale. 0 silences without detaching, so the drone can be
-- flown quietly without losing the fault chimes' meaning in the log.
function chime.volume(v)
  if v then VOL = math.max(0, math.min(1, v)) end
  return VOL
end

--- Every name, sorted. Used by the `chimes` audition program.
function chime.list()
  local out = {}
  for k in pairs(chime.sets) do out[#out + 1] = k end
  table.sort(out)
  return out
end

-- A single note and a sequence look the same to the player.
local function asSeq(item)
  if type(item) == "string" then item = chime.sets[item] end
  if type(item) ~= "table" then return nil end
  if item.inst then return { item } end
  return item
end

--- Queue a chime by name. Returns immediately. Unknown names are ignored so a
-- typo in a phase name can never take a flight down. `now` clears whatever is
-- waiting, for faults that should not sit behind a queue of phase chimes.
function chime.play(name, now)
  if not speaker then return false end
  if not chime.sets[name] then return false end
  if now then queue = {} end
  queue[#queue + 1] = name
  while #queue > MAXQ do table.remove(queue, 1) end
  return true
end

--- Queue an ad-hoc sequence built with the helpers, or a single note table.
function chime.melody(seq)
  if not speaker or type(seq) ~= "table" then return false end
  queue[#queue + 1] = seq
  while #queue > MAXQ do table.remove(queue, 1) end
  return true
end

--- Play a rising or falling run, for altimeter style callouts.
-- `frac` 0..1 maps to the low..high end of the range.
function chime.pitchTick(frac)
  if not speaker then return false end
  local semi = math.floor(-9 + 18 * math.max(0, math.min(1, frac)))
  return chime.melody({ n("hat", semi, 0.5, 0.05) })
end

local function sound(note)
  if speaker and note.vol * VOL > 0 then
    pcall(speaker.playNote, note.inst, note.vol * VOL, note.pitch)
  end
end

--- Play a sequence synchronously, blocking until it finishes. Only safe once
-- the flight is over, because it sleeps. The queued `play` is what the control
-- loop uses; this exists for the shutdown path, where the coroutine is already
-- dead and the last chime would otherwise never sound.
function chime.playNow(name)
  if not speaker then return false end
  local seq = asSeq(name)
  if not seq then return false end
  for _, note in ipairs(seq) do
    sound(note)
    if note.wait and note.wait > 0 then sleep(note.wait) end
  end
  return true
end

--- The coroutine. Never returns, never throws: if it died it would take the
-- flight down with it through parallel.waitForAny.
function chime.loop()
  while true do
    local item = table.remove(queue, 1)
    local seq = item and asSeq(item)
    if seq then
      for _, note in ipairs(seq) do
        sound(note)
        if note.wait and note.wait > 0 then sleep(note.wait) end
      end
    else
      sleep(0.1)
    end
  end
end

return chime
