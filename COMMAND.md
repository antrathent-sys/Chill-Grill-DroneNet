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

## Packages: use shulker boxes, not barrels

A shulker box keeps its inventory inside the item when broken. **A barrel does
not** - break one and the contents drop on the depot floor, so an airdropped
barrel arrives empty. Shulker boxes are the only sensible airdrop container.

Assembly is a Create loop the depot drives:

1. A deployer places an empty shulker box on the fill pad.
2. The depot pushes the ordered items into it with the inventory peripheral.
   Only a *placed* shulker exposes an inventory; the item form is opaque to CC.
3. An anvil or a rename step stamps the order id onto the box.
4. A deployer breaks it. Contents and name ride along in the item.
5. The named shulker goes to the drone's payload bay.

Step 3 is what makes package tracking real: the depot can call
`getItemDetail()` on the drone's bay and confirm the right package is aboard
before it launches.

## Entities

### Order

| State | Meaning | Next |
|---|---|---|
| `placed` | received, not yet checked | `accepted`, `rejected` |
| `accepted` | in range, in stock, drone available | `picking` |
| `picking` | shulker being assembled | `ready`, `failed` |
| `ready` | package built, waiting for a drone | `loaded` |
| `loaded` | aboard, id verified | `enroute` |
| `enroute` | mission dispatched | `delivered`, `returning` |
| `delivered` | released at destination, confirmed by mass drop | `closed` |
| `returning` | aborted in flight, package still aboard | `ready`, `failed` |
| `rejected` | refused at intake, with a reason | terminal |
| `failed` | needs a human | terminal |

`delivered` is confirmed by the drone's mass dropping at the release point, not
by having sent the redstone pulse. A pulse that fired into a jammed deployer is
not a delivery.

### Drone

`docked`, `charging`, `loading`, `outbound`, `delivering`, `returning`, `fault`.

Only a `docked` drone above the charge threshold is dispatchable.

### Package

Tracked by order id from assembly to release. Location is one of `fill_pad`,
`staging`, `drone:<id>`, `delivered`, `lost`.

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
| `drone.assign` | depot to drone | `orderId`, the mission leg queue |
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

## Persistence

The depot must survive a reboot mid-order. Two files:

- `orders.db` - the current state, rewritten on change.
- `orders.log` - append-only events, never rewritten. The audit trail, and what
  you read when something goes wrong.

Rewriting the state file is the risky part, since a crash mid-write leaves a
truncated table that will not deserialize. Write to `orders.db.new`, delete the
old, then `fs.move` into place, and on boot prefer `orders.db` but fall back to
`.new` if the main file fails to parse.

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
| Release fires but mass does not drop | do not mark delivered, return with the package |
| Depot reboots mid-flight | rebuild from `orders.db`, re-adopt drones by telemetry |
| Two depots answer a lookup | host one name; a second host is a config error, log it loudly |

## What not to do

- Do not let a client message reach a drone without passing depot validation.
- Do not mark an order delivered on a redstone pulse. Confirm by mass.
- Do not put order state on the drone. The drone carries a mission; the depot
  owns the order.
- Do not tear down the GPS array. The customers still need it.
