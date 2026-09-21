# Deliveries

A delivery is a shuttle job with a box in place of a passenger. It uses the
same queue, dispatch, watchdog, job record and ledger as a ride. Written
2026-09-21; the auto loader works (2026-09-22), no code yet. This replaces the package parts of COMMAND.md.
Who can send, and how they pay, is in [STATIONS.md](STATIONS.md): anyone can
walk up to a depot and pay coins, and members with a pocket computer have more.

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
4. **Flying loaded:** every tune so far was flown empty. Fly a full box on its
   own before carrying anyone's goods. One change per flight.
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
