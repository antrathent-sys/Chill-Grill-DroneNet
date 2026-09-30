# Where CINDER is going

Written 2026-09-30 from a step back with Alex: ten questions about the whole
ecosystem, his answers, and what they mean for what gets built, pruned and
proven next. [BACKLOG.md](BACKLOG.md) stays the item list; this is the
direction it is ordered by.

## What Alex said

| asked | answer |
|---|---|
| Who is the freight for? | Both: Cinder's own supply chain and other players ordering cargo. |
| Rides or cargo? | Both, pushed equally. Rides are opted into. Deliveries are a player's own goods depot to place or depot to depot, **or goods bought from Cinder's stock**. |
| A good day in three months? | Units available across the network, people and goods moving at the same time, orders placed and delivered, the default way to move a player or a thing. **Everything logged**: trips, items, destinations. |
| Who is at the board? | **Nobody.** Fully automated; Cinder members step in only to fix. |
| When is LAMBDA-002? | Beta. One craft has been enough because it only taxis Alex so far. |
| Money? | Must be properly handled **before the service goes public**. Function first. |
| The spectacle? | A lot of the value, but function has to be there too. |
| Prune or add? | **Prune.** The whole system is visible now, so each part's role and place is clear. |
| Prove first? | Unsure. The focus right now is **a delivery demo**. |
| Other operators? | Yes, maybe soon. Cinder's senior people must at least be able to find a craft and reset it. |

## The products, in one order model

Three things move, and they are one record ([ORDERS.md](ORDERS.md)):

- **A ride.** A person hails from a pass or a station and is flown place to
  place. Opted into, paid per trip.
- **A delivery.** A customer's own goods from a depot to a place, or depot to
  depot. The customer brings the goods to a depot (or they are already at
  one); Cinder moves the silo.
- **A sale.** Goods from Cinder's stock, from the catalogue, delivered. The
  same flight as a delivery, with stock and a price attached.

Two of the three are new against the 2026-09-14 note that Cinder would not
sell its own stock. That note is superseded: the catalogue (`ops catalog`), the
stock feed and the offsite depot decided on 2026-09-28 were already the first
steps back towards it.

## What the target state requires

| the service must | today | gap |
|---|---|---|
| **run with nobody at the board** | rides auto-dispatch on a hail while the board is open; a load, unload or order flight starts only when someone types `ops order run` / `ops load send`; the base loses trips and the queue on restart | a dispatcher that turns a paid order into flights on its own; the base journal so a restart resumes; auto-suspend when it cannot promise a flight; an alert to a person only when a job is stuck |
| **log everything** | `orders.log` (orders), `cargo.csv` (items), `joblog.csv` / `ledger.csv` (rides and money), `incidents.csv`, `.drops.log` on the craft | one journal the others are views of; rides on the same numbers as orders |
| **handle money properly** | ride fares and customer credit (`ops account`, `credit`, `till`, `ledger.csv`); orders carry a price and a `paid` event typed in by hand | one money model for rides and orders: quote, take, refund rules already decided (none), and how a player actually pays in Numismatics |
| **run several units** | fleet, trips, names and the A/B dock are sized for many; one tune, one craft | LAMBDA-002 when the hardware is settled: tune transfer, the per-role first command, dispatch by nearest idle unit with battery |
| **let Cinder people intervene** | the admin pocket finds a unit, stops it in the air, sends it home or to a place; one admin key | a **reset** order (stop, clear the mission, come home, restart the beacon); a key per official; a pocket alert feed (distress, stuck load, held order) |
| **carry the brand** | the flight wall, the control room, the pockets, the depot screens, one theme (`lib/tui.lua`), one naming scheme (`lib/names.lua`) | the older screens (`lib/display.lua`, `lib/screens.lua`) onto the same theme; the tower |

## The prune

Now that every part exists once, several exist twice. Each of these is a
change that removes code, and each carries its tests with it.

1. **One number scheme.** Rides are `J-0042`, orders `C-0042`. Rides become
   orders of kind `ride`, numbered from the same counter, written to
   `orders.log`. `joblog.csv` goes; the board's job list is a view of the
   journal.
2. **One journal.** `orders.log` is the truth. `loads.queue` goes: an order's
   next unflown flight *is* the queue. `cargo.csv` and `ledger.csv` become
   reports rebuilt from the journal (or are written from the same events, but
   never read as truth). This is also the base journal that restart resume
   needs, so the prune and the automation are one piece of work.
3. **One loader.** The single-bay station (`lib/loader.lua`, `station.lua`)
   and the A/B dock (`lib/dockseq.lua`, `dock.lua`) are two sequences with two
   configs and two sets of hooks. A station is a dock with one side. Fold it
   in, and `lib/loader.lua` goes.
4. **One dispatcher.** The ride `dispatch()` in ops, `ops order run` and
   `ops load send` all pick a unit and start a flight. One `lib/dispatch.lua`
   takes any order kind, and is the thing that runs unattended.
5. **One state vocabulary.** A unit has a state (`lib/state.lua`), a job has a
   state (`F.STATES`), a trip has a state (`lib/trip.lua`). Two are enough: the
   unit's, and the order's. Written down once.
6. **ops.lua by area.** 2,666 lines and 25 commands. The board stays one
   command; orders, money, places and flying move to libraries the commands
   call, so the pocket, the admin app and the dispatcher share them.
7. **Docs.** Sixteen documents, several written before the thing they describe
   changed: `COMMAND.md` and `MISSIONCONTROL.md` predate the sealed link and
   the no-cable rule; `BACKLOG.md` still says `lib/orders.lua` is unwritten.
   Merge to: README (the map), ARCHITECTURE (the craft), OPERATIONS (WORKFLOW +
   DELIVERIES + ORDERS + STATIONS: how an order moves), SERVICE (outside the
   game), PERFORMANCE, FRAMES, INFRASTRUCTURE, BACKLOG (index and history).
   The two old ones go into the history section.
8. **Per-role installs.** Built 2026-09-30, forced by the repo passing 1 MB:
   `wget run .../startup.lua role <name>` pulls one role, sets its autorun,
   and a computer with no role pulls nothing. Still to sort: `taxipad.lua`,
   `mixcal.lua`, `probe.lua`, `preflight.lua` and `stickers.lua` into "ships
   with a role", "developer tool" or "gone"; and the base at 770 KB.
9. **fly.lua last.** 4,138 lines at the local limit. Pads, ferry, deliver and
   the order legs can move out, but flight code changes one at a time against
   the mock and then a flight. Not during the demo push.

## The delivery demo

Proposed definition, so it can be tested against: **a player orders from a
pass (or Alex types the order); the base takes it, and with nobody at the
board sends LAMBDA-001 to CHID 1, the dock loads one silo on side A with its
invoice, the unit flies to the customer's place, drops, comes home; the
journal shows accepted, paid, flight, loaded, dropped, done; the depot screens
and the pass show it as it happens.**

In order, and what each step is:

| | step | state |
|---|---|---|
| 1 | CHID 1 depot up: `depot-chid-1` keyed, `dock.lua` from the example, `depot probe map`; `fly pad add chid-1 dock` from the craft; `ops send lambda-001 chid-1` ferries there by name; the dock heading is right | built, **untested** |
| 2 | `depot seq load A` with an empty silo: place, assemble, fill, invoice on the belt, push; a sticker holds an assembled silo | built, **untested** |
| 3 | `ops order add ... ` then `ops order run <id> chid-1 lambda-001`: base-driven load, stick, liftoff, deliver, drop, `unit.dropped` closes the order | built, **untested** |
| 4 | the same with nobody typing step 3: the dispatcher (prune item 4) and the journal (item 2) | **not built** |
| 5 | the customer orders from the pass, or by Discord against the published list | designed (SERVICE.md, WORKFLOW.md), **not built** |
| 6 | the price is taken from the customer's credit like a fare | credit exists for rides, **not wired** to orders |

Steps 1 to 3 are a staffed demo and need flying time, not code. Step 4 is the
first piece of the automated service and the first prune. Steps 5 and 6 are
what makes it public.

## The order of work

1. **Prove** steps 1 to 3 in game. Fix only what the flights find. No new
   features in this block. (Also the two unflown flight changes: stop and
   hover from cruise, `APPROACH_DECEL 2`, one per flight.)
2. **Prune and automate together**: the journal, then the dispatcher, then
   rides onto the same numbers, then the loader fold. Each step removes a file
   and its tests move.
3. **Unattended**: restart resume, auto-suspend, the reset order, a key per
   official, alerts on the admin pocket.
4. **Public**: money across rides and orders, ordering from the pass,
   LAMBDA-002, the private logs repo and signed releases from
   [INFRASTRUCTURE.md](INFRASTRUCTURE.md).
5. **Then the rest of the prune**: ops by area, docs, per-role installs,
   fly.lua.
