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
      |  the base plans it: order C-0042, 3 shipments  (3,776 + 3,776 + 2,448)
      |  the dual loader fills two at a time, so that is 2 flights
      v
ops order run C-0042             (Alex, once per flight for now)
      |
      |  load.start  load=C-0042.1  item=cobble  A=3776 B=3776  two invoices
      v
FACTORY DEPOT  (dual loader)
  1. count the intake: is there cobble, and how much?
  2. check both staging vaults: empty, or only leftover cobble
  3. move exactly A and B into them, and read them back
  4. place, assemble, fill (the belt empties each staging vault into its silo)
  5. check the staging vaults are empty: what left is what went in
     (3-5 repeat in rounds when a staging vault is smaller than a silo)
  6. print each invoice from that count - shipment 1 of 3, 2 of 3 - put it in last
  7. drone latched -> pusher up -> drone sticks -> pusher down
      |
      |  load.done  load=C-0042.1  counted A=3776 B=3776
      v
DRONE  deliver 1200 72 340    (both silos, one drop point)
      |
      |  unit.dropped  sticker=Create_Sticker_0 at 1200 72 340 ...
      v
BASE   shipments 1 and 2 delivered: 7,552 cobble. Shipment 3 (2,448) when Alex says.
```

### How the order travels with the cargo

**The load id is the order.** A flight's load id is the order number and the
flight: `C-0042.1`. Every message a load already sends - `load.start`,
`load.step`, `load.lifted`, `load.stuck`, `load.done` - carries its load id, and
so does every row `cargo.csv` writes for it. When the drone lets a silo go, the
cargo ledger already works out which load that sticker was holding
(`CARGO.openFor`), so the drop is tied back to the order and the run without a
single new message.

**The cargo carries it too: an invoice in every silo.** A CC printer on the
depot's network prints one invoice per silo, **after the fill has been
measured**, and the depot pushes it into that side's staging vault so the belt
carries it in after the goods - see "Checking the staging vaults" below for why
it goes in last. It is a
regular invoice (Alex: "ordered, delivered, cost"), and **every silo is a
shipment, numbered across the whole order** - 1 of 3, 2 of 3, 3 of 3 - because
that is what the customer receives. How shipments were paired into flights is
ours to know, not theirs.

Built as `lib/invoice.lua`; `tools/test_invoice.lua` renders every case and
checks it fits a CC printed page, which is **25 columns by 21 lines** and not a
character more. The middle shipment of 10k cobble, paid:

```
.-------------------------.
|CINDER                   |
|TRANSIT DIRECTORATE      |
|INVOICE          C-0042-2|
|SHIPMENT           2 OF 3|
|DATE           2026-09-28|
|BILL TO             STEVE|
|SHIP TO       1200 70 340|
|-------------------------|
|COBBLESTONE              |
|ORDERED            10,000|
|THIS SHIPMENT       3,776|
|SHIPPED BEFORE      3,776|
|TO FOLLOW           2,448|
|-------------------------|
|TOTAL          1,500 SPUR|
|PAID           1,500 SPUR|
|BALANCE DUE  PAID IN FULL|
|-------------------------|
|CARGO AT CONSIGNEE'S RISK|
|NO REFUNDS               |
|COMPLIANCE APPRECIATED   |
'-------------------------'
```

The last shipment says `ORDER  COMPLETE` in place of what is to follow, and an
unpaid one shows `PAID  NOTHING YET`, the balance due exactly - money on an
invoice is never rounded to cogs - and signs off `PAY AT ANY CINDER TILL`
instead of the usual line, because the invoice is also how it gets paid
(ORDERS.md, "Paying against an invoice").

**An order of several items** gets a packing list instead of the one-item
figures: what is physically in this silo, and whether more of the order is
coming.

```
|--- THIS SHIPMENT -------|
|COBBLESTONE         1,224|
|GRAVEL              2,000|
|                         |
|                         |
|ORDER      MORE TO FOLLOW|
```

Four item lines fit; a silo with more kinds than that says `+ 3 MORE ITEMS`
on the last rather than dropping them silently. Each item's running total is on
the base, in `ops order <id>`. A long customer name is shortened so its
label stays; coordinates and amounts keep every digit. The page's item name is
`CINDER INVOICE C-0042-2`, so it reads as what it is in an inventory.

`SHIPPED BEFORE` counts shipments sent earlier in the order, including the one
that flew alongside this in the same flight - that is what a partial-shipment
invoice means by it. If a shipment comes up short and the order needs one more
than planned, earlier invoices say "of 3" and the last says "of 4"; each is
true as of when it was printed, and the last always says `ORDER COMPLETE`.

The customer opens the vault and their invoice is in it, with the number to
quote if anything is wrong. A page takes one of the silo's 60 slots, so **a
silo carries 3,776 of a 64-stack item and a flight of two 7,552.** A printer out of paper or
ink skips the page and says so; it never holds a delivery up. The records are
the truth, the page is a courtesy.

The **base writes the page's text** and sends it in `load.start`; the depot
only prints what it is given. The base knows the order, the depot knows the
machines, and neither has to learn the other's job.

### Batching, and why it is re-planned every flight

The base plans shipments from the amount and the item's stack size: 3,776 of a
64-stack item in each silo (944 of a 16-stack item, 59 of something that does
not stack), two silos a flight on the dual loader. 10,000 cobble is shipments
of 3,776 + 3,776 on the first flight and 2,448 on the second.

But a plan is only a plan. The intake might be short, the item might stack to
16 not 64, a belt might stop. So **every flight after the first is planned from
what has actually been counted into silos that were actually dropped**, never
from what the first plan said. What an order has delivered is the sum of the
depot's fill counts for silos the drone reported letting go - nothing else.

### The intake

**One intake that Alex fills by hand,** on the depot's wired network, named
`intake` in the dock's `dock.lua`. It should be a vault rather than a chest: a
full flight stages 118 slots, and a double chest holds 54 (see the limits
below). For each flight the depot:

- moves only the order's items out of it; anything else in there stays put
- moves exactly each side's amount, and counts what the move returned
- if the intake is **short**, loads what is there up to the run's size and
  reports how many; the next run is planned from the rest
- if it is **empty**, refuses the run with "the intake has no cobble" and
  touches nothing

That is the whole of the batching machinery: the belt already empties a side's
storage into its silo, so putting exactly the right amount into that storage
is putting exactly the right amount into the silo.

### Checking the staging vaults

Each side's storage - the vault the belt empties into that side's silo - is
where a shipment is put together, and it is **the only place a shipment's
contents can ever be measured.** Once a silo is assembled it is a physics
object, not an inventory, and no computer can read what is in it. So the
staging vaults are checked at every step (Alex, 2026-09-28), and between them
they are what makes an invoice's numbers true.

1. **How big it is.** The depot reads each staging vault's slot count and
   stages in rounds no bigger than that. A one-block vault is 20 slots - a
   third of a silo - so it takes three rounds of stage and fill to fill one.
2. **Empty before anything goes in.** Anything already there would ride to a
   customer who never ordered it. Leftovers of the same item - a fill that came
   up short last time - count toward this shipment, since cobble is cobble. Any
   other item stops the load, and the depot says what it found and on which
   side.
3. **Read back after staging.** The vault must now hold exactly what the depot
   moved into it: the right items, the right counts. What the move reported is
   only believed when the vault agrees.
4. **Empty again after the fill.** What left the vault is what went into the
   silo. If something is still there - the silo filled early, the belt stopped -
   the shipment is what actually left, and the rest waits for this order's next
   flight, where check 2 counts it.
5. **Everything balances.** For every item: what left the intake equals what
   went into silos plus what is still staged. If it does not, something other
   than the depot touched a vault - a player, a stray hopper - and the load
   stops before the drone is called, with the numbers on screen.

**The invoice goes in last, printed from check 4's count, not from the plan.**
Once the fill has been measured, the page is printed and pushed into the empty
staging vault, the belt - still at its loading level - carries it into the
silo, and the vault is checked empty once more. So the invoice always says
what is in the silo, even when the fill came up short. The slot it takes was
kept free for it (59 for goods, 1 for the page).

### How complex an order can be

No limit in the software: an order is any number of items in any amounts,
packed into as many shipments as it takes. The limits are physical, and
knowing them is how an order gets quoted honestly:

| limit | what sets it |
|---|---|
| **59 kinds of item per silo** | each takes at least one of its 59 slots. More kinds mean more silos, never a refused order |
| **4 items listed per invoice** | the page is 21 lines. A fifth kind in one silo shows as `+ n MORE ITEMS`; nothing is lost, it just is not all printed |
| **2 silos per flight** | the dual loader. Past the first two, every two shipments cost another flight: about a minute in the air, plus the load |
| **the intake** | a full flight stages 118 slots. A chest holds 27 and a double chest 54, so **the intake should be a vault**, or it gets topped up between flights |
| **one destination** | an order goes to one place. A customer with two addresses is two orders |
| **items by name only** | the depot moves items by their name, so things that differ only inside - enchanted books, potions, tipped arrows, named or worn tools - all look alike. An order for `enchanted_book` takes whichever books are in the intake. Keep those out of a shared intake, or load them by hand |

And one guard for the most likely mistake: `ops order add` prints the plan -
shipments and flights - and asks before accepting anything over 10 shipments,
because 100,000 typed for 10,000 is one keystroke away.

### The factory's stock

The catalogue says what we sell; this says what the factory actually holds
(Alex, 2026-09-28): **Create 6 Stock Links on every storage vault**, all on one
logistics network, **one Stock Ticker** tuned to it, and **a wired modem on the
ticker** joining it to the depot computer. The ticker sees every linked vault
as one inventory.

```
depot stock          what the factory holds, most first - read only
```

It prints every item across the linked vaults with its count, keeps the
snapshot in `stock.txt` and pushes it to the depot's machine folder, the same
way the probe log goes. Built on `lib/stock.lua`, from Create's own peripheral
source: `stock(true)` returns every item with its id, name and count.

What it opens up, in order:

1. **An order checked against stock when it is taken** - "the factory has 6,200
   cobble; this order needs 10,000" - before anything flies.
2. **Advertising what is actually there**: the catalogue's items with the
   factory's counts, rounded down so a post never promises more than exists.
3. **The intake goes away.** The ticker does more than count: `requestFiltered`
   packs exact amounts out of storage and sends them to a packager by its
   address. Give each staging vault a packager - `cinder-A`, `cinder-B` - and
   route packages to them, and the depot can ask for exactly one shipment
   straight into the staging vault it is for. Create's own logistics does the
   counting and the carrying; the staging checks above still confirm it
   arrived. The hand-filled intake stays as the fallback.

**One line in the ticker's source decides how requests are made.** A filter's
`_requestCount` is how many to send, and *without it the ticker sends every
matching item there is*. One request that forgets its count empties the factory
of that item. So nothing in this repo builds a request by hand: `S.request` in
`lib/stock.lua` is the only way to ask, and it refuses - without ever calling the
ticker - unless the count is whole, above zero, and no more than the cap it is
given (one shipment). Its tests prove no request without a count can reach the
ticker, and `depot stock` never asks for anything at all.

**Stock is only live while the factory is loaded.** A Stock Link drops out
about 20 s after its chunk unloads. Either the factory is force-loaded - live
stock, and nothing waits on a drone to wake it - or the stock is as of the last
time a drone's chunk loader woke the depot. Every snapshot is stamped with when
it was taken, so a stale one says so.

Proven in game first, in order:

1. `depot stock` lists the factory's vaults - the ticker, the links and the
   modem are all working.
2. A request with a count, to a packager's address, arrives in a staging vault,
   exactly - and how long it takes.
3. Whether packages still on their way count in `stock()` or not, which decides
   how soon after one request the next can trust the numbers.

### Several orders at once: allocated, not set aside

Alex asked (2026-09-28): a staging vault for every order in progress, or keep
track in software? **In software.** The factory's storage is one pool, and an
order is a claim on it, not a pile of its own:

- **reserved** = what every open order still has to ship, per item
- **available** = the latest `depot stock` count, less what is reserved

`ops order add` checks a new order against *available*, not against stock, so
two orders can never both be promised the last 3,000 cobble. A shortfall is
said out loud when the order is taken - accept it as waiting on the factory, or
don't. Nothing new is stored for this: the reservations are worked out from
`orders.log`, the stock from the ticker.

Why not physical staging per order:

- **Only one flight is ever about to leave.** One drone, one dual loader: the
  two staging vaults hold the shipments for the flight being loaded, and that is
  all a staging vault is ever for. An order waiting its turn has no reason to be
  anywhere but in storage, where the ticker can count it.
- **Items are the same by id.** An order does not need *its* cobble, only
  cobble. Setting some aside earns nothing.
- **Every move is a chance to miscount.** Storage to an order's vault to the
  loader is two moves where one will do, and more hardware to route packages
  through.

**Taking from storage by hand breaks nothing** (Alex asked, 2026-09-28).
Nothing here keeps a count of its own that could go stale: stock is read fresh
from the ticker whenever it is needed, the ticker's request returns how many it
actually sent, and every shipment is whatever really arrived - its invoice
printed from that count, the order's next flight planned from what was really
shipped. So the worst a withdrawal can do is leave an order that was already
promised short, and it waits for the factory to make the rest. Nothing ships
wrong, and nothing is silent about it. The clean habit is to take from what is
**available**, not what is **reserved** - then no promise is touched at all -
and the order book will show that split per item.

The lock is for everyone else: a locked Create logistics network only lets its
owner tune blocks to it, so another player's requester or a shop cannot draw on
Cinder's storage without anyone knowing.

Two things the software way gets for free:

- **Staging ahead.** The staging vaults are empty the moment the silos leave
  (staging check 4), so the next flight's shipments can be requested while the
  drone is still in the air. When it docks, the fill starts at once instead of
  waiting on packages. More speed with no more hardware.
- **Two orders on one flight.** Silo A for one order and silo B for another,
  going to two places, is already how `deliver A and B` works - one drop each.
  Allocation decides it; the loader does not care whose shipment is on which
  side.

When physical staging per order *would* earn its keep: storage that has to be
shared with something that is not Cinder's; items that are only told apart by
their insides (enchanted books, potions), where the one promised has to be
physically kept; or several loaders working at once - and even then that is a
pair of staging vaults per loader, not per order.

### What exists and what is new

| | |
|---|---|
| **exists** | `ops load send` runs one load at a depot and flies a `deliver` after it. The two-sided dock sequence (`lib/dockseq.lua`) places, assembles, fills, pushes and retracts, proven on the test dock. `cargo.csv` records every silo; `unit.dropped` reports every release; a drop with two silos and one point lets both go there. |
| **the gap** | The depot daemon still runs base-driven loads through the older single-bay `lib/loader.lua`. The two-sided dock only runs by hand (`depot seq`), with the drone's part "taken as done". |
| **new** | the order record and runs (`lib/orders.lua`); `ops order add / run / paid`, `ops orders`, `ops quote`; the depot running `lib/dockseq.lua` for base-driven loads, staging from the intake with the five staging checks, and answering the drone's stick through the base; the invoice printer. |

**The factory loader is dual** (Alex, 2026-09-28), built like the test dock:
two sides, each with a placer, assembler, belt, pusher, its own storage and a
silo sensor - plus one intake chest and a printer, all on the depot's wired
network.

### Silo supply: a payload burns 3

The silo goes with the cargo and the customer keeps it, so every shipment uses
three `create_connected:item_silo` blocks (Alex, 2026-09-28) and every dual
flight six. Keeping the placers fed:

- **Silos are factory stock.** They sit in the linked vaults like anything
  else, made there or bought in, and `depot stock` counts them in payloads and
  dual flights, or says NONE. Once the factory has a line that makes them, a
  Factory Gauge in production mode can hold that count up too.
- **Create tops up each placer's feed, not our code.** A packager on the
  inventory the placer draws from, and a Factory Gauge on that packager: on a
  packager it is a *restocker*. Filter it to the item silo, target 6 (two
  payloads), address `cinder-silo-A` / `cinder-silo-B` (the frogport by that
  packager). When the feed falls below 6 it requests the difference, or all
  the network has if that is less. Create has a known restocker bug: promises
  pile up when a target empties faster than packages arrive. At 3 blocks every
  few minutes that should not happen. If it does, the feed just holds more.
- **The depot counts the feed before it places.** Put `feed = "<inventory>"` on
  a side in dock.lua. With fewer than 3 silo blocks in it, the load is called
  off at `feed` before the placer fires or the drone is asked for anything: a
  placer with 2 blocks cannot make a whole silo. `depot seq` shows each feed's
  count. BUILT, tested on the desktop.
- **They go in the price.** Three silo blocks are part of what every shipment
  costs. When the order book is built, a quote counts them like goods (10k
  cobble is 3 shipments, 9 blocks) and says so when the factory is short.

### Receiving, and recycling silos

A depot receives as well as sends (Alex, 2026-09-28): a restock, goods a
customer sends in, a delivery that could not be made coming back. Half of it
is already in `lib/dockseq.lua`:

- **UNLOAD takes a silo off a latched drone.** Pusher up, the drone lets go,
  pusher down, and the belt empties the silo into the side's storage. BUILT,
  run by hand (`depot seq unload A`), never yet with a real drone.
- **The emptied silo stays in the bay, and the next LOAD on that side fills
  it** instead of placing a new one, so it takes nothing from the feed. BUILT.
  A visit that brings silos in and takes silos out burns no silo blocks at
  all: unload both sides, fill the same two silos, and the drone takes them
  away.

What is missing:

1. **Clearing the staging vault.** An unload leaves the goods in the side's
   staging vault, and a load refuses a staging vault that is not empty. Each
   side needs a way out to bulk storage: a funnel or chute from the staging
   vault into the stock-linked vaults, on a relay (`clear`). The depot runs it
   after every unload until the staging vault reads empty, and from then on
   the ticker sees what came in like anything else in storage. Printed pages
   (the invoice riding in a returned shipment) are filtered out to a bin on
   the way. DESIGNED.
2. **Receiving, driven by the base.** An inbound job: the drone ferries to the
   depot and latches; the depot unloads each side against what the cargo
   ledger says the silo holds, clears it, and reports the counts. A returned
   delivery's items go back to available stock (what happens to its order is
   still the open failed-delivery decision). DESIGNED.
3. **Surplus silos.** Recycling in place covers a depot that sends at least as
   often as it receives, which is the factory. A bay already holding an empty
   silo cannot take another, so a depot that mostly receives would need to
   take a silo apart into blocks again and put them in the placer's feed.
   Unproven: whether firing the assembler again, or a drill, turns an
   assembled silo back into blocks. Test that before building a depot that
   mostly receives.

### Proven in game first

Each is one quick test, and the first decides the batching design:

1. **The depot can move a counted amount from a chest into a side's storage** -
   `pushItems` into a Create connected silo, over a wired modem - and read the
   staging vault's slot count with `size()`.
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

Every job uses one silo, three silo blocks on the dual loader, restocks
included, unless a dock can take a box apart and reuse it (unproven). Its cost
goes in the fare (silo supply, above).

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
