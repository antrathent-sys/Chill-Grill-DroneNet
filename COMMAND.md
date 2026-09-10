# Central command

The ground side: order intake, package assembly, fleet dispatch. Runs on a
depot computer, not on any drone.

Read [ARCHITECTURE.md](ARCHITECTURE.md) first. The depot talks to a drone's link
layer and never to its control loop.

## Keep the GPS array

CC: Sable removes the drone's need for GPS, not everyone's. The `sublevel` API
only answers for a computer sitting on a sub-level; on the ground
`isInPlotGrid()` is false and `getLogicalPose()` raises. A customer's pocket
computer is not on a sub-level, so **`gps.locate()` is still the only way it can
find itself**.

Since the volcano hosts carry ender modems, and an ender modem receives at any
range while still reporting a true distance, that array already covers the whole
dimension. It is what makes "deliver to where I am standing" work. Leave it up.

The drone should stop depending on it. The customers still do.

## Packages are physics sub-levels

The package is **its own Sable sub-level**, a physics barrel carried on a
docking connector, not an item in a bay. Release is an undock: the drone drops
the redstone on its connector, the constraint is removed, and the package falls
under physics as an independent rigid body.

This is better than dropping an item in every way that matters. Nothing
despawns, nothing scatters, the contents are real blocks in real inventories,
and the "package" can be any contraption you like rather than one container.

Consequences that shape the rest of this document:

- **The two bodies stay separate.** Docking adds a *fixed constraint* between
  two sub-levels, it does not merge them. So `sublevel.getMass()` on the drone
  reports the **drone alone**, never the drone plus package.
- **Rigid, not slung.** The constraint is fixed, so the package cannot swing.
  The combined system is one rigid body for handling purposes, with a larger
  inertia and a centre of mass shifted toward the connector.
- **Delivery is confirmed by the connector, not by mass.** After release
  `getConnectedName()` returns `""`. That is the delivery signal.

Assembly is therefore a Physics Assembler loop, not an item-packing loop: build
or stage the barrel contraption, fill its inventories, assemble it into a
sub-level, and name it with the order id so `getName()` identifies it. The drone
verifies the right package by reading `getConnectedName()` after capture and
comparing it against the order.

A landed package persists. The sub-level simply unloads with its chunk and comes
back when someone arrives, so a delivery keeps until the customer collects it.
Nothing expires, which is the whole reason this beats dropping items.

Still to establish on the first trials: how much drop height the barrel tolerates
before it tips or takes damage. That sets `dropAlt`, and it may argue for a low
hover and a gentle release rather than a true airdrop.

### Tell the customer where it actually landed

A package released from height falls, and may roll or settle. The release point
is not the landing point, and once the chunk unloads nobody can go looking with
a sensor. So the landing position has to be captured at the moment of delivery
and stored with the order.

Two ways, pick by how much a package is worth:

- **Cheap.** Report the release position and the drop altitude. Good enough from
  a low hover, and it costs nothing.
- **Exact.** Put a computer and an ender modem in the package contraption. The
  package is a sub-level, so its own computer can call
  `sublevel.getLogicalPose()` and report precisely where it came to rest, then
  go quiet when the chunk unloads. Worth it for a reusable barrel, overkill for
  a one-way crate.

## Entities

### Order

| State | Meaning | Next |
|---|---|---|
| `placed` | received, not yet checked | `accepted`, `rejected` |
| `accepted` | in range, in stock, drone available | `picking` |
| `picking` | package contraption being built and assembled | `ready`, `failed` |
| `ready` | package built, waiting for a drone | `loaded` |
| `loaded` | captured on the connector, name verified against the order | `enroute` |
| `enroute` | mission dispatched | `delivered`, `returning` |
| `delivered` | released at destination, connector reports disconnected | `closed` |
| `returning` | aborted in flight, package still aboard | `ready`, `failed` |
| `rejected` | refused at intake, with a reason | terminal |
| `failed` | needs a human | terminal |

`delivered` is confirmed by `getConnectedName()` going empty at the release
point, not by having dropped the redstone. A signal that failed to release a
stuck connector is not a delivery.

### Drone

`docked`, `charging`, `loading`, `outbound`, `delivering`, `returning`, `fault`.

Only a `docked` drone above the charge threshold is dispatchable.

### Package

Tracked by order id for its whole life, not just to release. Location is one of
`fill_pad`, `staging`, `drone:<id>`, `landed`, `collected`, `lost`.

Delivery is not the end of the record. A landed package sits in the world until
the customer collects it, so the depot keeps the landing coordinates and the
order stays queryable: a customer who forgets where their drop went can ask.

Barrels are not free, so the empty ones are an asset worth recovering. Because
the docking connector works in both directions, a later flight can re-dock with
an empty package and carry it home, which makes recovery an ordinary mission
rather than a special mechanism. That is what the `collected` state is for.

## Protocol

One rednet protocol, `dronenet`. Depot hosts it with `rednet.host`, clients
find it with `rednet.lookup`, so nobody hardcodes a computer id.

Every message is a table with a version and a type:

```lua
{ v = 1, type = "order.place", nonce = "<client id>-<counter>", ... }
```

| Type | Direction | Carries |
|---|---|---|
| `order.place` | client to depot | `nonce`, `dest {x,y,z}`, `items`, optional `dropAlt` |
| `order.ack` | depot to client | `nonce`, `orderId`, `state`, `reason` if rejected |
| `order.status` | depot to client | `orderId`, `state`, `eta` |
| `order.cancel` | client to depot | `orderId` |
| `drone.telemetry` | drone to depot | position, leg, energy, mass, dock state |
| `drone.assign` | depot to drone | `orderId`, the mission leg queue, and the package `name` plus **`mass`**, since the drone cannot measure a docked package |
| `drone.command` | depot to drone | `recall`, `abort`, `hold`, `resume` |
| `drone.report` | drone to depot | `orderId`, `event`, detail |

**The nonce is not optional.** Rednet drops messages, so clients retry, and a
customer double-tapping the order key must not launch two drones. The depot
keys accepted orders by nonce and returns the existing `orderId` for a repeat
rather than creating a second order. Same rule for `drone.assign`.

Commands to a drone are queue edits, vetted by the depot against the drone's
energy budget. Never raw actuator commands. See ARCHITECTURE.md.

## Intake validation

Run in this order, cheapest first, and always return a reason:

1. **Malformed** - missing fields, bad types.
2. **Rate limit** - per customer, per minute.
3. **Destination sane** - inside world bounds, not absurdly far.
4. **Stock** - the depot can actually assemble it.
5. **Range** - round-trip energy against the observed drain rate, with reserve.
   This is the same check the mission layer runs in flight; here it decides
   whether to accept the order at all.
6. **Fleet** - a drone is or will be available.

Rejections are cheap and honest. An order accepted that cannot be flown is
worse than one refused at intake.

## Persistence: `lib/db.lua`

The depot must survive a reboot mid-order, and it has to do it inside a
**1,000,000 byte disk** (`computer_space_limit`; a floppy is 125,000). That
number is the whole reason for the design.

`lib/db.lua` is a log-structured key/value store built for exactly this:

- **Writes append one line.** O(1), no matter how large the store gets.
  Rewriting a whole serialized table on every change is O(n) on a slow machine
  and loses everything if the game stops mid-write.
- **An in-memory index maps key to byte offset**, so `get` seeks straight to
  the record instead of scanning.
- **Scans stream line by line.** The file is never loaded into memory, which
  matters as much as disk space on a CC computer.
- **Compaction** rewrites without the dead records, building alongside and
  swapping in only once complete.
- **A torn final line is dropped on the next open**, costing at most the last
  write. That is what a crash actually looks like on an appending log.

```lua
local db  = dofile("lib/db.lua")
local ord = db.open("orders.db")
ord:put("o-1042", { customer = "alex", state = "placed", cost = 120 })
local rec = ord:get("o-1042")
local open_orders = ord:find(function(_, v) return v.state == "placed" end)
if ord:stats().shouldCompact then ord:compact() end
```

Records are JSON, one per line. That is deliberate: on Lua 5.1
`textutils.serialize` escapes a newline inside a string as a backslash followed
by a **real newline**, which would split one record across two lines and
silently corrupt the log. JSON cannot emit a raw newline. The cost is that
values must be JSON-representable, which is no restriction for order records.

Run `python tools/run_db_test.py` to exercise it outside the game.

### Sizing, and what not to store

A compact order record is roughly 200-300 bytes, so a 1 MB disk holds a few
thousand orders. That is plenty for the order book.

**Flight telemetry is not.** A 30 second flight log is already over 600 rows,
around 130 KB, so eight flights would fill the disk on their own. Keep raw
flight logs where they are: written on the drone, overwritten each flight,
pulled off when a flight is interesting. The depot stores a mission *summary*,
not the trace.

When the order book does grow too large, in rough order of effort: compact,
then archive closed orders to a disk drive, then offload over `http` to
something outside the game. The http route is already proven here, since
`startup.lua` uses it.

**Put a computer in the disk drive, not a floppy.** A floppy mounts with the
125,000 byte limit, but a computer or pocket computer item mounts with the
*computer* limit of 1,000,000 - eight times the storage per drive, for a
cheaper item. This is a real behaviour, not a trick: `MountMedia.COMPUTER` is
backed by `computer_space_limit`.

### What everyone else does

Worth knowing, since it sets expectations. There is no standard CC database
library; searching turns up only near-zero-star one-offs. Almost every CC
program serializes one whole table to one file and rewrites it on every change.
That is genuinely fine at small scale and you should not feel clever for
avoiding it.

It stops being fine here for two reasons: an order book grows without bound, so
the rewrite cost grows with it, and a whole-table load has to fit in memory as
well as on disk. The crossover is somewhere in the low hundreds of records. The
built-in `settings` API is not an alternative - it is for configuration, keeps
everything in memory, and only persists when you call `save()`.

If the pack happens to include a database peripheral mod such as `cc-dbp-lite`,
that gives real SQL and is worth using instead. Check before building more here.

## Dispatch policy

Pick the drone that is docked, charged above threshold, has the range for this
destination with reserve, and is nearest to it. Ties go to the fullest battery.

An order that is `ready` with no eligible drone waits in a queue rather than
being rejected. It was already accepted, so the range check passed; it only
needs a machine.

## Failure modes to design for now

| Failure | Response |
|---|---|
| Customer out of range | reject at intake with the distance |
| Drone loses link mid-flight | it flies the mission anyway, telemetry is advisory |
| Capture fails on return | retry, then hold, then a human alert |
| Release fires but the connector stays linked | do not mark delivered, retry, then return with the package |
| Depot reboots mid-flight | rebuild from `orders.db`, re-adopt drones by telemetry |
| Two depots answer a lookup | host one name; a second host is a config error, log it loudly |

## What not to do

- Do not let a client message reach a drone without passing depot validation.
- Do not mark an order delivered on a redstone pulse. Confirm with
  `getConnectedName()`.
- Do not assume `sublevel.getMass()` includes the package. It does not.
- Do not put order state on the drone. The drone carries a mission; the depot
  owns the order.
- Do not tear down the GPS array. The customers still need it.
