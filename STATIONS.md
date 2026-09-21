# Stations: the service for anyone

Two ways in, one service behind both. Written 2026-09-21, nothing built yet.

| | **Walk-up** (anyone) | **Member** (issued a pocket computer) |
|---|---|---|
| Rides from | a station | anywhere, from GPS |
| Rides to | any listed place | anywhere, typed coordinates included |
| Parcels | handed in at a depot, dropped at any listed place | handed in at a depot, dropped anywhere |
| Pays | coins in the station's depositor, trip by trip | account credit, which may go negative |
| Needs | nothing: walk up, pick, pay | a sealed key, set up by Alex on request |

A **station** is a dock with a touch monitor, a computer and a depositor. A
station that also takes parcels is a **depot** ([DELIVERIES.md](DELIVERIES.md)).
Members keep everything they have today.

Parcels start at a depot for both groups. Picking a box up off open ground
needs sticker precision that our landings do not have.

## Why walk-ups need no identity

All the work on who paid (the seat, the pay pad, arming the till) exists to
put money on the right *account*. A walk-up has no account. They pay on the
spot for a trip that is about to happen, so there is nothing to credit and no
one to identify.

The station is the account. Its own depositor credits it, and the trips it
books debit it. That reuses the ledger unchanged, and `ops account` then shows
each station's takings for free. The station will not book a trip its balance
cannot cover. A trip to the base stays free for walk-ups too.

## A walk-up ride

1. **Pick.** On the touch monitor, pick a destination from the listed places.
   The screen shows the fare and whether a drone is in.
2. **No drone in:** press CALL. It costs nothing, and the job joins the same
   queue as everyone else. A drone that comes and finds nobody just sits
   latched and charging at the dock until another job wants it. A no-show
   costs one flight and nothing else.
3. **Drone in:** the shutter opens and the depositor is priced at the fare.
   Pay, board, go. Paying only once a drone is actually in means nobody ever
   pays for a ride that does not come, so there are no refunds to handle.
4. The ride and the fare are recorded like any other: one joblog line and
   one ledger line.

A walk-up parcel is the same screen at a depot. Load the intake, pick a place,
pay, and walk away. It is paid at hand-in, because the goods and the drone
both wait for the next free drone.

## Pieces

- **`station` role:** touch monitor, depositor pulse, shutter, sealed link to
  ops. The screens are the pocket's (`lib/hailui.lua`) drawn on a monitor
  sized to match, so there is one design and not two.
- **Station keys are not customer keys.** A station reports cash taken, and ops
  must never accept that report from a customer's pocket. Stations get their
  own keyring (`seckey station new <dock>`), and only those keys may post a
  payment.
- **The depositor:** `setTotalPrice` prices it per trip and locks it between
  trips (LOCK_PRICE, as the base till does), with the shutter in front. If
  this pack's Numismatics has no CC methods (`ops till` says which), set the
  depositor by hand to the flat fare and let the shutter alone decide when it
  can be paid. The flat fare is what makes that fallback work.

## Leaving: people decide, not sensors

Seat detection was the first idea, and it fails for groups. It can tell that
a seat is taken, but not that everyone who paid is aboard, and a party of
three may fill two seats and stand. So the signal comes from people, with a
clock behind it, the way a bus works:

- **A GO button in the cabin.** A button wired to a redstone input on the drone
  computer. The beacon reads it only while the job is waiting to board, and
  treats it exactly like a pocket's G. The last one aboard presses it. It is
  physical, so only someone standing in the cabin can press it. Members get
  it too, alongside G on the pocket.
- **A departure clock at the station.** Once the fare is paid the monitor counts
  down, 45 s to start with, and the drone leaves when it runs out. HOLD adds
  30 s for someone still coming. The station is the job's client, so its go is
  accepted by ops the same way a pocket's is today.
- **One fare per trip, not per head.** The shuttle is hired, like a taxi. A
  depositor cannot count people, and nobody should have to. Seats set the size
  of the party.

A group that misses the clock has missed the bus. That is easier to explain
than a sensor that is right most of the time.

## Open questions, settled in game

1. **Monitor size.** The pocket screens are 26x20. A 2x2 advanced monitor at
   text scale 0.5 fits them with room to spare. Check that it reads from where
   a player stands.
2. **The GO button's side** on each airframe, and that nothing else on that
   side (the dock signal is on `back`) can press it by accident.
