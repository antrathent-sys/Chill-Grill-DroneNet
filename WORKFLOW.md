# Workflow: any order, start to finish

How Cinder handles whatever a customer asks for, written 2026-09-28 as the one
page to read with a message waiting. The detail behind each step is in
[ORDERS.md](ORDERS.md) (the order book), [DELIVERIES.md](DELIVERIES.md) (the
loader, staging, invoices) and [SERVICE.md](SERVICE.md) (later, outside the
game).

Every step says where it stands:

- **BUILT** - in the code and tested on the desktop
- **UNTESTED** - built, but not yet run in game
- **DESIGNED** - written down, not built

## At a glance

```
 a message arrives
      |
      v
 1. WHAT IS IT?     items / several items / a schematic / a ride
      |
      v
 2. AN ORDER LINE   names checked against the catalogue; a schematic becomes a
      |             bill of materials, split into ours and theirs
      v
 3. QUOTE           shipments, flights, time, stock available -> Alex sets a price
      |
      v
 4. ACCEPT          ops order add -> C-0042, stock reserved
      |
      v
 5. FULFIL          per flight: stage, fill, invoice in last, stick, fly, drop
      |             (repeat until every shipment is down)
      v
 6. PAID + CLOSED   ops order paid, or at a till; the last invoice says COMPLETE
```

## Standing setup

Done once, then kept up.

| what | how | status |
|---|---|---|
| **The catalogue** - what we sell | one of each item in reference chests or vaults at the base; `ops catalogue read` | BUILT |
| **The factory's stock** | Stock Links on every storage vault, one Stock Ticker, a wired modem on it; `depot stock` | UNTESTED |
| **The dual loader** at the factory | two sides, each: placer, assembler, belt, pusher, staging vault, silo sensor | BUILT, run by hand only (`depot seq`) |
| **Receiving** - unload, clear to storage, reuse the silo | unload and reusing the emptied silo exist; a `clear` relay per side moves the staging vault into bulk storage | unload + reuse BUILT, by hand; clearing and base-driven receiving DESIGNED |
| **Silo supply**: a payload burns 3 silo blocks | silos held as factory stock; a Factory Gauge restocker on a packager at each placer's feed, target 6; the depot counts the feed before it places | the count BUILT (`feed` in dock.lua); the restockers DESIGNED |
| **Staging from stock** | a packager on each staging vault (`cinder-A`, `cinder-B`) so the ticker can deliver into it; a hand-filled intake as the fallback | DESIGNED |
| **The invoice printer** | a CC printer on the depot's network, paper and black dye in it | DESIGNED (the page itself is BUILT, `lib/invoice.lua`) |
| **A till**, if customers pay in person | a chest a computer reads, at a Cinder location | DESIGNED |

## 1. What is it?

Four kinds of thing arrive, all by Discord message for now.

| it is | e.g. | goes to |
|---|---|---|
| **Items** | "10k cobble to 1200 70 340" | step 2 |
| **Several items** | "5k cobble, 2k gravel, 640 iron blocks to ..." | step 2 - same path, more pairs |
| **A schematic** | a `.nbt` of something they want to build | step 2, through `tools/schematic.py` first |
| **A ride** | a person, somewhere to somewhere | not this page: the pocket pass and the taxi service, platforms only, at their own risk (INFRASTRUCTURE.md decisions) |

## 2. Turn it into an order line

**Items, one or several.** Every item is named the way the catalogue knows it:
its id, the id without the mod's name, or its display name with underscores.
`ops catalogue find <word>` shows what a word resolves to. BUILT.

- **Not in the catalogue** - we do not supply it; say so. `find` suggests what
  they might have meant.
- **A name two mods share** (`andesite`) - not guessed; use the full id.
- **Things that differ only inside** - enchanted books, potions, named or dyed
  items - the depot cannot tell them apart by id. Decline, or load them by hand
  outside this workflow.

**A schematic.** Save the attachment and run:

```
python tools/schematic.py build.nbt --who steve --to 1200 70 340
```

It lists everything the build takes - copycats' hidden materials included -
splits it into **what we supply** and **what to source elsewhere**, and prints
the order line for our part. BUILT. Send the customer the "source elsewhere"
list so they know what is not coming. It cannot see what is inside blocks (chest
contents, fuel), tells dyed or enchanted items apart only by kind, and checks
belts by hand. Their file stays on Alex's PC, never in the repo.

**Where it goes.** A delivery is a drop - the drone never lands - so bare
coordinates are fine, but they need all three as F3 shows them, because the drop
height comes from the ground's y. Two places means two orders. A pocket's GPS is
not good enough for this (it was 65 blocks out in y at the rules pad); the
customer reads F3.

## 3. Quote

```
ops quote 10000 cobble to 1200 70 340                       DESIGNED
```

What Alex gets to price with:

- **Shipments** - one silo each: 3,776 of a 64-stack item (one slot is kept for
  the invoice), 944 of a 16-stack one, 59 of something that does not stack.
  Several items pack in order, spilling into the next silo. 10k cobble is 3.
  (The packing is BUILT, `lib/invoice.lua`.)
- **Flights** - two shipments a flight on the dual loader. 10k cobble is 2.
- **Silos** - three silo blocks a shipment, so 9 for 10k cobble. They come out
  of stock like the goods.
- **Time** - each flight about `64 s + distance / 171`, plus the load
  (PERFORMANCE.md).
- **Stock** - available, which is the factory's count less what open orders
  have reserved. If it is short, say so now: ship what there is and the rest
  when the factory makes it, or wait.

The price is Alex's call; there is no price list. Tell the customer the price,
how many shipments, roughly how long, and the terms: **cargo at the consignee's
risk, no refunds.**

Over 10 shipments, `ops order add` asks before accepting - 100,000 typed for
10,000 is one keystroke. DESIGNED.

## 4. Accept

```
ops order add steve 10000 cobble to 1200 70 340 for 1500    DESIGNED
```

The order gets a short number, **C-0042**, which is what the customer quotes
from now on. Its items are reserved against the factory's stock, so no later
order can be promised the same cobble. Reply with the number.

## 5. Fulfil, flight by flight

```
ops order run C-0042         once per flight, for now           DESIGNED
```

Each flight, in order:

1. **The base picks the next two shipments.** Usually both from one order;
   they can be from two, going to two places - `deliver A and B` already drops
   one silo at each. DESIGNED.
2. **The drone ferries to the factory dock** and latches. BUILT.
3. **The depot stages each shipment** into its side's staging vault - asked of
   the ticker with an exact count, or moved from the hand-filled intake - and
   runs the **five staging checks**: the vault's size, empty before, read back
   after, empty after the fill, and everything balancing. Anything wrong stops
   the load before the drone is asked for anything. DESIGNED.
4. **Place, assemble, fill.** The side's feed must hold 3 silo blocks first,
   or the load stops there. BUILT (`lib/dockseq.lua`, proven on side A; the
   feed count on the desktop).
5. **The invoice goes in last,** printed from the count the fill actually
   measured, so it always says what is in the silo: SHIPMENT 2 OF 3, what this
   one holds, what came before, what is still to follow, the money. DESIGNED
   (the page is BUILT).
6. **Pusher up, the drone sticks, pusher down.** BUILT by hand; the base
   answering "stick" for a real drone is DESIGNED.
7. **The drone flies the drop** to the order's coordinates and lets go. BUILT.
8. **The drop is reported,** and the cargo ledger ties the sticker to the load
   and the load to the order: that shipment is delivered. BUILT (the ledger);
   marking the order is DESIGNED.
9. **Home, or back for the next flight.** The next shipments can be staged
   while it is still in the air, so the fill starts the moment it docks.
   DESIGNED.

Every flight after the first is planned from what was **actually counted** into
silos that were **actually dropped**, never from the first plan. A short
shipment just means one more.

## 6. Paid, and closed

**Payment**, whenever Alex wants it - before the first flight or after the
last:

- By hand or bank transfer: `ops order paid C-0042`. DESIGNED.
- **At a till, against the invoice**: the customer drops the invoice in with
  their card (charged exactly the balance) or coins (no change; any excess held
  as credit). The invoice says what is being paid for, so nobody needs
  identifying. DESIGNED, with four in-game checks first.

An unpaid invoice ends `PAY AT ANY CINDER TILL`; a paid one `PAID IN FULL`.

**Closed** when every shipment is down: the last invoice says `ORDER COMPLETE`.
`ops orders` shows what is open, what is loading, and what is still owed. Tell
the customer it is done.

## When it goes wrong

| what happens | what the system does | what Alex does |
|---|---|---|
| Not enough in stock or the intake | ships what arrived, invoice printed from the real count, the rest planned as one more shipment | nothing, or tell the customer it is split |
| A placer's feed is short of silos | calls the load off at `feed` before anything moves, says which side and how many | check that side's restocker, and `depot stock` for silos |
| Something foreign in a staging vault | stops the load, says what and which side | clear it |
| The counts do not balance | stops before the drone is called, numbers on screen | find what touched a vault |
| A fill comes up short | the shipment is what left; the rest waits in the vault and counts toward the next flight | nothing |
| Printer out of paper or ink | the shipment goes without its page, and says so | refill it; the records are the truth |
| Alex takes stock by hand | nothing breaks; a promised order may come up short and wait | take from available, not reserved |
| A delivery cannot be made (distress, obstruction) | *open decision* - proposed: the drone keeps the silo and brings it back; the depot unloads it into stock and reuses the silo; the order holds | decide |
| The customer disputes it | the invoice number opens `ops order C-0042`: every event, what each silo held, where each dropped | read it |
| The order is cancelled | `ops order cancel C-0042 <why>`: dropped shipments stay delivered, the reservation is released | DESIGNED |
| The base restarts mid-order | open orders are rebuilt from `orders.log` | DESIGNED |

## Before the first real order

Built and waiting on the game:

1. `depot stock` at the factory - the ticker, links and modem all working.
2. A ticker request with a count arriving exactly in a staging vault, and how
   long it takes.
3. A printed page riding the belt into a silo and still there after the drop.
4. A two-sided load where the base answers "stick" to a real drone.
5. A restocker holding a placer's feed at 6 silo blocks while loads draw 3.

And to build, smallest first (ORDERS.md, DELIVERIES.md): `lib/orders.lua` and
the order book commands (useful the day they exist, even flying runs by hand),
then the depot running the dual loader for the base with the staging checks and
the printer, then `ops order run`.
