# Mission control

The base side of a flight: plan a mission, hand it to a docked drone, watch it
fly, and keep a record of what actually happened. Scoped 2026-09-14, nothing
built yet.

Read [ARCHITECTURE.md](ARCHITECTURE.md) (L3 mission, L4 link) and
[COMMAND.md](COMMAND.md) (order intake, depot) first. This document is the
part between them: the mission record, the telemetry, and the display.

## What exists today

- `fly deliver x y z` is typed **on the drone**. It builds its own leg list
  (`cruise(undock) -> hover -> action(drop) -> dock`) and flies it. No base
  computer is involved and nothing is recorded except the flightlog.
- `lib/mission.lua` can plan, budget and validate a leg queue and compute a
  point-of-no-return verdict, but nothing calls it in flight, and its
  performance table is still the defaults (`cruise = 8` b/s against a
  measured ~195).
- The drone already holds everything telemetry needs in shared tables:
  `pos` (position, velocity), `phase`, `legs` / `legIdx`, `mon` (accumulator
  % and drain rate), `fuel` (thruster FE), `dock`, the TRIAD attitude.
- Radio: in-flight commands are wired-modem only (`CMD_RADIO_STRICT`). The
  drone has no authenticated link yet.

## The system

```
 drone (fly.lua)                         base computer (ops.lua)
 ---------------                         -----------------------
 L1-L3 as today                          missions.db   (lib/db.lua)
 status table  --->  linkLoop  --telemetry 1 Hz-->  telemetry intake
                     (own coroutine)                 mission tracker
 mission queue <---  over cable when docked  <---   planner + dispatch
                                                     renderer --> monitors
```

Three pieces, each its own file:

| Piece | Where | Job |
|---|---|---|
| `lib/link.lua` | drone and base | packet format, send and receive, later signing |
| `ops.lua` | base | mission records, planning, dispatch, telemetry intake |
| `lib/display.lua` | base | draws screens from plain tables onto any `term`-like object |

The renderer takes tables and a terminal and never reads a peripheral or the
network itself, so every screen can be tested on the desktop with a fake
terminal, like the other `lib/` modules.

## Transport, and what may travel over it

| Path | When | Carries |
|---|---|---|
| **Cable** (the docking connector bridges the base wired network in) | docked | mission assignment, flightlog summary back, full telemetry |
| **Radio** (ender modem - legs are 5,400 blocks) | in flight | telemetry out; `recall` / `hold` in, **only once signed** |

**A mission is only ever assigned over the cable.** A drone that can be given a
new destination by radio can be sent anywhere by anyone who copies the packet.
Over the cable an attacker has to be on the base network already.

In-flight commands stay off until `lib/link.lua` signs them (ccryptolib
ChaCha20-Poly1305, pre-shared key kept out of the repo, persisted counter
against replay, verify before parsing).

**Telemetry is a privacy leak, not a hijack.** A broadcast position tells any
listener where the drone is going and where home is. Send it unencrypted while
testing; encrypt it with the same link once that exists.

**Fitted:** the drone carries an ender modem (confirmed 2026-09-14). Telemetry
is **send-only** on it: raw `modem.transmit`, never `rednet.open` or
`modem.open`. Opening it for rednet would let `drone-cmd` words arrive over
radio again and undo `CMD_RADIO_STRICT`, because a `rednet_message` event does
not say which modem it came in on.

## Telemetry packet

One small table, about 1 Hz, packed by `linkLoop` from the shared tables. The
link coroutine never reads a peripheral; the modem send is its only yield, and
it is outside L1 (ARCHITECTURE.md rule 4).

| Field | Source | Notes |
|---|---|---|
| `v, id, seq, t` | link | protocol version, drone name, packet counter, drone clock |
| `mission, leg, legN, legKind, phase` | `legs`, `legIdx`, `phase` | |
| `x, y, z, vx, vz, vv` | `pos`, altimeter | |
| `spd, hdg, lean` | derived, TRIAD | |
| `tx, tz, dist, eta` | current leg target | ETA from measured cruise speed plus brake time |
| `off` | CRUISE_TRACK line | blocks off the start->target line |
| `energy, drain, fe` | `mon`, `fuel` | %, %/min, thruster FE % |
| `dock, payload` | `dock`, sticker state | |
| `verdict` | `mission.checkReturn` | `go` / `turn back` / `land now` |
| `warn` | monLoop warnings | short strings, capped |

About 300 bytes. The base keeps the last packet per drone in memory, a short
ring of positions for the map trail, and nothing else from the stream.

## Mission record

Stored by `ops.lua` in `missions.db`. A summary, never the trace (a flightlog
is ~130 KB per 30 s; see COMMAND.md "Sizing").

```lua
{ id = "m-0042", kind = "deliver", created = <epoch>,
  drone = "drone-1", from = "home", to = { x=, y=, z= },
  payload = { vault = "v-0042", massEst = nil },   -- filled once stickers carry one
  p2p = nil,                                       -- Delivery Required request, courier jobs
  legs = { ... },                                  -- from mission.plan
  budget = { total = 34, out = 12, back = 12 },    -- % accumulator, planned
  state = "assigned",
  actual = { launched=, legs = { {t0,t1,energy0,energy1}, ... },
             dropPos = {x,z}, dropMiss = 3.1, docked=, energyUsed=, brakes = n },
  reasons = { ... } }                              -- why rejected or failed
```

States: `planned -> validated -> assigned -> outbound -> dropping -> returning
-> docked -> closed`, with `rejected`, `aborted`, `failed` off the side. Every
transition is driven by telemetry (`legKind`, `phase`, `dock`) or by the cable
handshake, never by a timer guessing.

## Planning

`ops.lua` wraps `lib/mission.lua`; it does not replace it.

1. **Places** (`mission.places`): home pad, known drop points, customer Links
   with their ground height. An unsurveyed place is flagged, not assumed flat.
2. **Plan** the leg queue with `mission.plan`: the same legs `fly deliver`
   builds today, plus a sticker `action` once payload is wired.
3. **Validate** against the docked drone's energy and the reserve policy.
4. **Performance from logs, not defaults.** After every docked return the base
   gets a `mission.calibrateFromLog` result over the cable and folds it in
   (cruise speed, drain, climb). Until the first calibration, every plan shows
   "uncalibrated".
5. **Assign** over the cable: the drone stores the leg queue and starts it with
   the same code path `fly deliver` uses, so there is still one flight
   controller.

## Display

CC:Tweaked advanced monitors, touch enabled: a **5x5 wall on the pad's wired
network** (planned 2026-09-14), so the base computer reaches the wall and the
docked drone over the same cable. Screen size is read with `getSize()` at start
and every layout is computed from it, never hardcoded. Teletext drawing
characters give 2x3 sub-pixels per cell for the map. 16 colours, redefinable.

**Built for a fleet from the start:** every screen is keyed by drone id, the
Overview is a list, and nothing assumes there is only one drone.

| Screen | Shows | Touch |
|---|---|---|
| **Overview** | per drone: state, mission, phase, energy bar and drain, FE, dock, verdict, packet age | select drone |
| **Mission** | leg list with the current leg highlighted, progress bar, distance, ETA, planned vs used energy | abort (once signed) |
| **Map** | top-down: home, target, start->target line, trail, drone arrow, off-line distance, brake point | zoom |
| **Plan** | places list, new mission form, validation reasons | plan, assign (docked only) |
| **Log** | recent missions: time, distance, drop miss, energy, result; live warnings | - |

Rules:

- **Stale is loud.** Packet age over 5 s greys the drone out; over 30 s shows
  LINK LOST. Telemetry is advisory (ARCHITECTURE.md): the drone flies on.
- **Redraw on change, at most 2 Hz.** Draw into a `window` and blit what
  changed rather than repainting the whole wall every packet.
- **No flight control from the display.** Touch can plan and assign (docked)
  and, once signed, recall. It never commands a leg, a heading or a throttle.

Optional, later: a Create display board in the hangar fed through CC:C Bridge
`create_source`, for a big "DRONE-1 OUTBOUND 1,240 m ETA 0:42" sign.

## Build order

Each step is usable on its own and testable without the others.

1. **`lib/link.lua` packet + `linkLoop` on the drone** - BUILT 2026-09-14
   (`TELEM_ON`): send-only on the first wireless/ender modem, unsigned,
   channel `TELEM_CHANNEL` 7212, id = computer label. Mock harness: the fake modem records
   transmissions; a case asserts ~1 Hz packets with sane fields, and switch
   off reproduces the previous flight logs exactly.
2. **`lib/display.lua` Overview + Map**, rendered from a recorded packet stream
   onto a fake terminal in a desktop test. Then on a real monitor with the
   drone docked, over the cable.
3. **`ops.lua` mission records**: telemetry drives the state machine, the
   flightlog summary comes back over the cable on docking. Missions still
   launched by typing `fly deliver` on the drone.
4. **Planning and assignment over the cable**: the base builds and validates
   the plan, the drone flies it. `fly deliver` on the drone keeps working.
5. **Signed link** (`recall`, `hold`, encrypted telemetry).
6. **Courier fields**: vault id, Delivery Required request, drop confirmation.

## Decided (2026-09-14)

- Ender modem fitted on the drone.
- 5x5 monitor wall, on the pad's wired network.
- Fleet from the start: drone ids everywhere, one home pad per drone in its
  own CFG. **Label every drone computer** (`label set drone-1`): the label is
  the telemetry id.

## Out of date elsewhere

COMMAND.md still describes packages as barrels carried on a docking connector.
Decided since (2026-09-14): 1x1x2 Create item vaults carried by Create
stickers, released as a drop, optionally as a courier for Delivery Required
P2P requests. Rewrite COMMAND.md when step 6 starts.
