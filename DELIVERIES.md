# Deliveries

A delivery is a shuttle job with a box in place of a passenger. It uses the
same queue, dispatch, watchdog, job record and ledger as a ride. Written
2026-09-21; the auto loader works (2026-09-22), no code yet. This replaces the package parts of COMMAND.md.
Who can send, and how they pay, is in [STATIONS.md](STATIONS.md): anyone can
walk up to a depot and pay coins, and members with a pocket computer have more.

## The minimum delivery (2026-09-28)

What Alex wants working first, before anything around it: **take an order,
fill the factory's loader by hand, have the loader count what went into the
silos and split a big order into runs, and keep the order attached to the cargo
the whole way to the drop.**

### The chain, for one order

```
ops order add steve 10000 cobble to 1200 70 340 for 1500
      |
      |  the base plans it: 2 runs  (7,552 + 2,448)
      v
ops order run O1759050000        (Alex, once per run for now)
      |
      |  load.start  load=O1759050000.1  item=cobble  A=3776 B=3776  manifest
      v
FACTORY DEPOT
  1. count the intake: is there cobble, and how much?
  2. move exactly A into side A's storage and B into side B's - counted
  3. print a manifest page for each silo, put it in with the goods
  4. place, assemble, fill (the belt empties each side's storage into its silo)
  5. count what went in: that is the confirmation
  6. drone latched -> pusher up -> drone sticks -> pusher down
      |
      |  load.done  load=O1759050000.1  counted A=3776 B=3776
      v
DRONE  deliver 1200 72 340    (both silos, one drop point)
      |
      |  unit.dropped  sticker=Create_Sticker_0 at 1200 72 340 ...
      v
BASE   run 1 delivered: 7,552 cobble. 2,448 to go. Next run when Alex says.
```

### How the order travels with the cargo

**The load id is the order.** A run's load id is the order id and the run
number: `O1759050000.1`. Every message a load already sends - `load.start`,
`load.step`, `load.lifted`, `load.stuck`, `load.done` - carries its load id, and
so does every row `cargo.csv` writes for it. When the drone lets a silo go, the
cargo ledger already works out which load that sticker was holding
(`CARGO.openFor`), so the drop is tied back to the order and the run without a
single new message.

**The cargo carries it too.** A CC printer on the depot's network prints one
page per silo and the depot pushes it into that side's storage with the goods,
so the belt carries it into the silo:

```
CINDER TRANSIT DIRECTORATE
ORDER O1759050000  RUN 1 OF 2
SILO A OF 2
3,776 COBBLE
TO 1200 70 340
FOR STEVE
CARGO AT CONSIGNEE'S RISK
```

The customer opens the vault and their receipt is in it, with the id to quote
if anything is wrong. A page takes one of the silo's 60 slots, so **a silo
carries 3,776 of a 64-stack item and a run 7,552.** A printer out of paper or
ink skips the page and says so; it never holds a delivery up. The records are
the truth, the page is a courtesy.

The **base writes the page's text** and sends it in `load.start`; the depot
only prints what it is given. The base knows the order, the depot knows the
machines, and neither has to learn the other's job.

### Batching, and why it is re-planned every run

The base plans runs from the amount and the item's stack size: two silos a run,
3,776 of a 64-stack item in each (944 of a 16-stack item, 59 of something that
does not stack). 10,000 cobble is 3,776 + 3,776 in run 1 and 2,448 in run 2.

But a plan is only a plan. The intake might be short, the item might stack to
16 not 64, a belt might stop. So **every run after the first is planned from
what has actually been counted into silos that were actually dropped**, never
from what the first plan said. What an order has delivered is the sum of the
depot's fill counts for silos the drone reported letting go - nothing else.

### The intake

**One intake chest that Alex fills by hand,** on the depot's wired network,
named `intake` in the dock's `dock.lua`. For each run the depot:

- moves only the order's item out of it; anything else in there stays put
- moves exactly each side's amount, and counts what the move returned
- if the intake is **short**, loads what is there up to the run's size and
  reports how many; the next run is planned from the rest
- if it is **empty**, refuses the run with "the intake has no cobble" and
  touches nothing

That is the whole of the batching machinery: the belt already empties a side's
storage into its silo, so putting exactly the right amount into that storage
is putting exactly the right amount into the silo.

### Two counts, and what happens when they disagree

- **Staged**: what the move from the intake into a side's storage returned.
- **Filled**: what left that storage into the silo (the dock sequence already
  measures this - it is how it knows a fill is done).

They should match. If the fill comes up short - a silo full, a belt stopped -
the load reports both, the shortfall stays in the side's storage for the next
run, and the order records what actually went.

### What exists and what is new

| | |
|---|---|
| **exists** | `ops load send` runs one load at a depot and flies a `deliver` after it. The two-sided dock sequence (`lib/dockseq.lua`) places, assembles, fills, pushes and retracts, proven on the test dock. `cargo.csv` records every silo; `unit.dropped` reports every release; a drop with two silos and one point lets both go there. |
| **the gap** | The depot daemon still runs base-driven loads through the older single-bay `lib/loader.lua`. The two-sided dock only runs by hand (`depot seq`), with the drone's part "taken as done". |
| **new** | the order record and runs (`lib/orders.lua`); `ops order add / run / paid`, `ops orders`, `ops quote`; the depot running `lib/dockseq.lua` for base-driven loads, staging from the intake and answering the drone's stick through the base; the manifest printer. |

This assumes the factory loader is built like the test dock: two sides, each
with a placer, assembler, belt, pusher, its own storage and a silo sensor -
plus one intake chest and, if wanted, a printer.

### Proven in game first

Each is one quick test, and the first decides the batching design:

1. **The depot can move a counted amount from a chest into a side's storage** -
   `pushItems` into a Create connected silo, over a wired modem.
2. **A printed page put in a side's storage rides the belt into the silo** with
   the goods, and is still there when the vault is opened after a drop.
3. **A two-sided load where the base answers "stick"**, with a real drone
   latched, not the depot pretending.

### Building it, smallest first

1. `lib/orders.lua`, pure and tested on the desktop: the order, runs from an
   amount and a stack size, the silo split, re-planning from counts, the log.
2. `ops order add`, `ops orders`, `ops order paid`, `ops quote` - the order
   book. Useful the day it exists, before anything flies it.
3. The depot runs `lib/dockseq.lua` for base-driven loads: stage from the
   intake, print, fill, push, and ask the base to have the drone stick.
4. `ops order run`: the next run, through the load queue that already exists,
   with the order's load id, amounts, manifest and a `deliver` liftoff built
   from the order's coordinates. The drop and `load.done` update the order.

Then, once it has carried real orders: chaining runs without Alex saying
"next", and the rest of this document.

## Where a delivery can start and end

It follows from the dock/pad split:

- **It starts at a dock.** Taking items in and loading them onto a drone needs
  machines: an intake chest, a funnel and a packer. A pad is only a safe place
  to land and has none of those. A dock with an intake is a **depot**.
- **It ends anywhere.** At another dock the box is emptied into that dock's
  storage. At a pad or bare coordinates the drone drops the box.

A pad can only be the origin if the sender brings a finished box and the drone
lands on it and sticks. A sticker needs flush contact to a fraction of a
block, and our landings miss by more than that. So that is not in the first
version.

## One box per drone

The drone carries one 1x1x2 item vault, held on by a sticker. The depot fills
the vault while it is still a block and only then assembles it (proven
2026-09-22), so a box is never filled on the drone. The rule:

> Depots pack a full box. Wherever it goes, the drone lets go of it and the
> destination keeps it. The drone flies back empty.

That covers both jobs:

| Job | From | To | At the end |
|---|---|---|---|
| **Parcel**: a customer sends something | a depot | anywhere | drop at a pad or coordinates, or let go at a dock |
| **Restock**: top up a dock's silo | any dock with stock | a dock | let go at the dock, which empties it |

Every job uses one vault, restocks included, unless a dock can take a box
apart and reuse the vault (unproven). The vault's cost goes in the parcel fare.

## A parcel, start to finish

1. **Hand in.** The customer puts items in the depot's intake chest, then picks
   a destination. A walk-up picks on the depot's touch monitor and pays coins
   into its depositor. A member picks on their pocket terminal and it goes on
   their account: whichever sealed terminal is standing on the depot's spot
   gets charged, as at the till.
2. **Book.** The depot computer counts the intake (CC's inventory peripheral),
   posts the fare to the ledger and asks ops for a drone. The job joins the
   same queue as rides, so it waits its turn when the fleet is busy.
3. **Collect.** If a drone is already docked at the depot, it takes the job
   there. If not, ops sends one: `ferry <depot>`, which is correct because a
   depot is a dock.
4. **Load.** The funnel moves the intake into a vault that is still a block,
   which can happen before the drone arrives. Once the drone is latched, the
   packer assembles the full vault and the drone's sticker grabs it. The
   **depot** reports "loaded" to ops, sealed. It is the depot that
   reports and not the drone, because only the depot can see its own
   inventories.
5. **Fly.** If the destination is a dock, the drone ferries there, latches, and
   lets go of the box, and the dock empties it. That dock reports what arrived. For a pad
   or coordinates, the drone hovers at drop height, calls sticker `retract()`,
   checks the box has gone, and the job is done.
6. **Record.** The job goes on one joblog line and the fare goes on one ledger
   line, the same files rides use.

## Restocking silos

- Each dock computer reads its silo and reports its stock to ops, sealed. Docks
  get a device key like every other base device.
- **First version:** `ops restock <dock> <item> <count>` creates a restock job
  from the base (or any dock that has the item) to that dock.
- **Later:** each dock sets a minimum per item, and ops raises restock jobs by
  itself when stock falls below it. Those jobs only run while nobody is
  waiting for a ride or a parcel, because customers come first.

## The loading station (built 2026-09-22)

`ops load` on the base runs the station at the dock (lib/loader.lua; the
layout is `station.lua`, copied from `station.example.lua`). One Redstone
Relay face per action:

| Step | What | Done when |
|---|---|---|
| place | a silo in each bay the load needs | `wait.place` |
| fill | the auto loader fills them | a fixed time, the intake emptying, the silos' count, or a signal; `wait.fill` at most |
| assemble | a deployer clicks each Physics Assembler | `wait.assemble` |
| dock | the drone latched on the station's dock | telemetry says docked there; `wait.dock` at most |
| lift | the lifter takes the silos up to the drone | `wait.lift` |
| stick | the drone extends its stickers (sealed order) | the drone answers |
| retract | the lifter comes down | `wait.retract` |
| liftoff | the drone flies `liftoff`, if set | the drone acks |

A 3x1 silo holds 60 stacks (Create's `vaultCapacity`, 20 per block): 3,840 of
a 64-stack item, 7,680 across both bays. One silo goes in `single`; two are
split evenly, so the drone carries about the same either side. Place, fill
and assemble run before the drone arrives. A failure anywhere calls the load
off with the lift down and every face at rest, and says where it stopped.

## Depots: a computer at each dock (built 2026-09-22)

Each dock that loads has its own computer running `depot.lua`: its relays and
silos need a cable, and the timing of each step has to be local. The base
still decides everything; a depot only works its machines and reports.

A depot sleeps with its chunk. The drone's own chunk loader wakes it on
arrival (proven in game: a computer at a remote dock answered only once the
drone had docked), so no depot needs a chunk loader of its own.

1. `ops load send drone-1 pier 3000 deliver market and farm` queues it; the
   board picks the drone (the one named once free, or `any`) and sends it
   `ferry pier`.
2. The drone docks; its chunk loader wakes depot-pier, which says hello to
   the base every 10 s, sealed.
3. With the drone latched there (telemetry) and the depot awake, the board
   sends the depot the load.
4. The depot places, fills, counts and assembles, lifts, and reports "silos
   up". The board has the drone stick and passes its answer back.
5. The depot lowers the lifter and reports what it counted; the board writes
   cargo.csv and sends the drone its liftoff.

A depot that restarts part way through lowers the lift and says so; the board
calls that load off rather than guess. Keys: `seckey new depot-pier` on the
base, `label set depot-pier` and `seckey set disk` on the depot.

## The cargo ledger (built 2026-09-22)

What was loaded and where it went is `cargo.csv` on the base
(lib/cargo.lua), appended like the other records:

- **Loaded.** Once the fill is done, while the silos are still blocks, the
  station reads each one (CC sees a placed vault as an inventory: set `silo`
  in station.lua to the vault's peripheral name - a wired modem on a block
  beside each bay). One row per item per silo, with where that silo is going
  from the load's `deliver ...`. Silos that count empty call the load off.
  With no silo readable it counts what left the intake instead, which cannot
  tell two silos apart. A Smart Observer cannot do this: it only gives a
  signal for one filtered item.
- **Delivered.** fly writes each silo it let go of to `.drops` on the drone;
  after the flight the beacon reports them to the base, sealed, and keeps a
  copy in `.drops.log`. The board writes a `delivered` row with where (or
  `held` if the sticker stayed out). The board has to be running to record
  it; the drone's copy stays either way.
- `ops cargo [n]` joins the two: each load, each silo's items, and whether it
  was delivered and where.

Unverified in game: that a vault placed fresh each load comes back under the
same peripheral name on the modem beside it.

## What changes in the code (small)

- `lib/fleet.lua`: a job gets a kind, one of `ride`, `parcel` or `restock`. It
  also gets three legs: `load` (sit latched until the dock says loaded),
  `unload` (the same, until the dock says empty) and `drop`.
- `beacon.lua`: the sticker actions for the drop leg. `fly deliver` already has
  a drop leg with nothing behind it.
- A new `depot` role: intake count, funnel into the vault block, packer
  trigger once the drone is latched, sealed reports. The same program runs at a plain dock with the intake left out.
- `ops.lua`: takes parcel bookings from depots, `ops restock`, and shows the
  job kind on the board.
- Fares: a flat fare per parcel, like rides. A restock is internal, so it
  costs nothing.

## Proven in game first, one at a time

The hardware decides whether any of the above works, so these come before
any code:

1. **The sticker holds a vault through a real flight, and CC `retract()` drops
   it.** `stickers test` exists but has never been run against a vault.
2. **Unloading: a funnel or mechanical arm can empty a vault that is already a
   sub-level.** Loading no longer needs this (see 3). Sable claims it supports
   funnels and arms on sub-levels, but that is untested. The dock's CC bridge
   to the drone never appeared in testing (32 peripherals docked and 32
   undocked), so CC cannot move items off the drone.
3. **The packer: works (2026-09-22).** The vault is filled while it is still a
   block, then assembled into its own sub-level. Still to see: the sticker
   grabbing it straight off the packer.
4. **Flying loaded: proven (2026-09-22).** `fly deliver` now needs a payload
   (a sticker that is out) unless `empty` is added, lets go of the silo at the
   drop, and with two silos aboard `deliver A and B` drops one at each.
5. **Drop accuracy:** measure where the box lands against where it was aimed,
   from 10 to 20 blocks up.

**If step 2 fails:** a box that reaches a dock cannot be emptied as it is. The
dock would have to take the box apart with its own machines, or a player
empties it by hand.

## Later

- **Delivery Required courier work:** a parcel dropped into a P2P request zone
  (9x9 around the requester's Link) is a courier delivery. Step 5 decides
  whether our drops are accurate enough for that.
- **Several drones and several depots:** nothing here assumes one of either.
  The queue already handles both.
