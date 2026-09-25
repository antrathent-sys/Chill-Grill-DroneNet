# Infrastructure review

A step back, 2026-09-25: what the service is built on, what the evidence says
about it, how it should be set up, and what will hurt the business. Written
after two weeks of flying. Where this says "measured" it comes from the 229
flightlogs in `logs/flights`; where it says "sourced" there is a link at the
end.

## Where we are

**Hardware in service:** one drone (drone-1, LAMBDA-1), one base (ops and the
control board), the HQ dock, one test dock with its depot computer, and
pocket passes. Passes are switched off for now (`ops open`).

**Software:** about 21,000 lines of Lua across drone (`fly`, `beacon`), base
(`ops`, `provision`), depot (`depot`, `lib/dockseq`) and pocket (`hail`,
`kiosk`). Messages between the base and drones or depots are sealed, and so
are orders from a pass. 31 desktop test suites and about 60 mock flights run
before every push.

**What the flightlogs say:**

| | |
|---|---|
| Flights logged | 229, 5.2 flight hours, since 2026-09-10 |
| Ended cleanly | 121 (15 more stopped by hand, 56 early ones predate the END row) |
| Tumbles | 37: 30 on the tuning day (09-19), 7 on 09-22/23, and 5 of those 7 in the landing or just after touchdown (1 in cruise, 1 with no rows) |
| Docking | 61 docked. 13 captures never confirmed, and at least the three on 09-25 had in fact latched (fixed, 14a6bd7) |
| Landing after a cruise | 32 measured: median 5.9 blocks off, worst 40, half within 5 |
| Cruise | about 180 b/s at Y 350, and the brake stops about 100 blocks short |

The flying works. The landing, the ground and everything around the flight
are where the problems are.

## The risks, worst first

### 1. Chunk loading at speed, and with nobody near

When a drone's computer stops, the thrusters lose their Lua throttle and the
craft falls (sourced: the thruster API clears it when the computer
detaches). Two sourced facts make that likely on long flights:

- The pack's chunk loader (Aeronautic Additions and ChunkLoader) says it
  should not be used on very fast aircraft: the craft can outpace the loading
  and get stuck. We cruise at 180 b/s.
- A report against the other common loader (Create Power Loader, NeoForge
  1.21.1, with Sable) says it cannot activate chunks beyond the server's
  simulation distance from a player, so it can't carry a craft on its own.
  Our pack uses the other loader; whether that one has the same limit is
  unknown.

Our own evidence fits: flight cNFSZ (09-19) stopped mid-climb, with no error
and no END row.

**Everything that promises "works while Alex is offline" depends on this.**
Test it before anything else: send the drone on a 3,000-block job with no
player within simulation distance, at 180 b/s and again at a slower cruise,
and see whether the flightlog ends in an END row.

### 2. Server restarts and lag

- Sourced: a CC computer loses its running program on a server restart or a
  chunk unload, and starts again from `startup`. A drone in the air at a
  restart falls. The base forgets every job and the waiting line, because
  they are only in memory (ORDERS.md already covers this).
- Sourced: Sable sub-levels can desync when the server falls far behind on
  ticks. The craft becomes unusable and may not be recoverable.
- Sourced: every Aeronautics craft is a full physics body ticked every server
  tick, and chunk generation is the biggest cause of mid-flight TPS drops.
  Routes over ungenerated land cost the server the most. If the drones make
  the server lag, the admins will limit them.

What to do: learn the server's restart schedule and fly nothing across it.
Keep routes over land that is already generated (ask the admins about a
pre-generation). Make the base survive a restart (the journal in ORDERS.md).
Keep the craft small.

### 3. The code can be taken over through any field device

Every device with a `.ghtoken` (drone, base, depot) holds **write** access to
the repo that **every** device runs at boot. A drone lands at customers'
places and is out in the world. Anyone who gets hold of its computer gets
the token. With the token they can push their own code, and every drone,
base and depot runs it at its next boot. That is the worst thing that could
happen to the service, and it is one theft away.

What to do:

- **Two repos.** Code stays in this public repo, and devices only read it.
  Logs and probes go to a second, **private** repo, and the device token has
  write access to that repo only.
- **Signed releases.** Alex signs a release on his PC with an ed25519 key.
  `startup` checks the signature (ccryptolib has ed25519; we ship only part
  of that library today) and refuses unsigned code. Then even a leaked write
  token can't change what runs.
- **Pin to a release, not to `main`.** A drone should not pick up a
  half-finished commit because it happened to reboot.

### 4. Privacy: the public repo maps customers' homes

Every flightlog has the exact coordinates of the ride's destination, which
is usually somebody's base. They are in a public repo. On a server with
griefing that exposes customers, and it breaks the rule we already have
("ask before putting customers' own places in it"). Moving logs to the
private repo (point 3) fixes this. Until then, stop uploading ride logs, or
blur the coordinates.

### 5. Landing is the dangerous part

Five of the last seven tumbles happened in the landing. The drone has no
ground sensor: it only knows the Y it was told. Open ground holds everything
we can't see: slopes, trees, water, other builds. Already fixed: false
touchdown (e0b4ede), the latch that wasn't seen (14a6bd7), accuracy (the
tune in 43d3148, to be flown).

What to do: **known platforms by default** for pickup and drop-off (the
pocket now offers one first). Each platform is surveyed: its ground Y, its
park height, clear sky above. Open ground stays available but costs more
and carries the customer's risk. Rides to a dock should latch onto it, not
land on it.

### 6. The test world and the server share one configuration

On 09-25 a drone in the test world was sent to the server's HQ coordinates,
because the home dock is written into `fly.lua`. It found nothing there, and
a bug made it fall 30 blocks. Places, home and keys all belong to one world.

What to do: a world file (`server` or `test`) on every machine. Places and
home are kept per world under `machines/`. A device refuses coordinates from
the other world.

### 7. One operator

Alex is the only operator, pilot and recovery crew. When something goes wrong
while he's offline, a drone sits in a field, and so may a customer and their
items. That is also when trust is lost.

What to do: the service must know when it cannot promise a ride, and say
so. SERVICE SUSPENDED goes on every pass automatically when the base has an
unacknowledged incident, when no drone is available, or outside set hours.
Write a short runbook for recovering a downed unit.

### 8. Energy

The HQ pad did not charge the drone (flat at 92% while latched on 09-25),
and a drone that lands instead of docking charges nowhere. `lib/mission.lua`
has a reserve policy that taxi jobs don't use yet. Every job should be
checked against the battery before it's accepted, with a floor high enough
to get home.

### 9. More than one drone

With a second drone come things one drone never needed: two craft at the
same dock, two craft on crossing routes, and two jobs racing for one place.
It needs altitude lanes by direction, a reservation for every dock slot, and
a base that assigns the dock as well as the drone.

### 10. Mod updates

Cosmonautics is coming, and every mod we call (thrusters, Sable, CC:Sable,
Avionics, the docking connector) can change or remove a method in any update.
The test world must run the same versions as the server. After any pack
update, `preflight` and a short hop come before any customer ride.

## How it should be set up

The principles:

1. **The base is the one record of truth, and it survives a restart.** Jobs,
   the line, the fleet, loads and money are written to disk as they change
   (ORDERS.md).
2. **Drones do what they're told, and keep themselves safe.** A drone never
   cuts thrust in the air, always knows a safe place to set down, keeps a
   battery reserve, and refuses a job it can't finish.
3. **Places are infrastructure.** Platforms and docks are surveyed and named,
   and they are the default. Open ground is the exception.
4. **Customers are known.** Passes are on and orders are sealed. Open mode
   is for testing only.
5. **Code is released, not pulled.** Signed, pinned, on the test world first,
   drone-1 first, one flight-control change per flight.
6. **Logs are private and read.** Flightlogs, incidents and the ledger go
   to the private repo, with one summary a day.
7. **The service says when it's down.** Suspended is better than a ride
   that doesn't come.

What to build or set up, in order:

| # | What | Why |
|---|---|---|
| 1 | The chunk test: an autonomous 3,000-block job, no player near, at two speeds | Go or no-go for offline service (risk 1) |
| 2 | Private logs repo, device tokens scoped to it, the current token revoked | Risks 3 and 4 |
| 3 | Signed, pinned releases checked in `startup` | Risk 3 |
| 4 | World files, and places and home kept per world | Risk 6 |
| 5 | The base journal and restart recovery (ORDERS.md) | Risk 2 |
| 6 | Base and HQ in forceloaded chunks that stay loaded offline (Open Parties and Claims has offline forceload, but only if the server config allows it: ask the admins) | The base has to be there to answer |
| 7 | A surveyed platform network around the hubs, platforms by default, and rides to a dock ferry onto it | Risk 5 |
| 8 | Auto-suspend and the runbook | Risk 7 |
| 9 | A battery check on every job, and working charging at the HQ pad | Risk 8 |
| 10 | Service terms: fares, refunds, lost cargo, the passenger's own risk | Trust, see below |
| 11 | Walk-up stations (STATIONS.md), then deliveries (DELIVERIES.md) | Demand |
| 12 | Lanes and dock reservations, then a second drone | Risk 9 |

Items 1 to 4 come before any more customer work. Item 1 decides what the
business can promise.

## Business pitfalls

**Who needs it.** On this server everyone can build an aircraft, many
players have an elytra, and Create 6's logistics network moves items free at
any range once its chunks are loaded. A ride has to beat all of that. The
buyers are likely: new or casual players without flight gear, bulk or awkward
cargo to places with no network, and people who value convenience or
spectacle. That is a small market on a small server. Plan for a few rides a
day, not a queue.

**Density.** Sourced: on-demand services fail when there are too few users
in one area to match rides, and when units sit idle. One drone serving the
whole map means long waits and a lot of empty flying. It's better to serve a
few hubs well: platforms at spawn, the market and HQ, and a station at each.
Grow outward only when those are busy.

**Trust is the product.** One passenger dropped from Y 350 loses their items
and tells everyone. The fixes that matter most are the ones that stop that:
platforms, landing reliability, and never flying across a restart. Publish
what happens when it fails: a refund, an item compensation fund, a
slow-falling advisory for passengers. A service that is honest about its
limits beats one that promises everywhere.

**The economy.** Sourced: player economies inflate when money has nowhere to
go. Keep the fare simple and review it against what spurs actually buy on
the server. Our costs are Alex's time, materials, repairs and energy. Free
rides to HQ are a good hook, but track what they cost.

**Abuse.** Open mode lets anyone call the drone for nothing: fake calls
waste flights, and a joker can call it to a trap. Someone can stand on a
platform, block a pad, or break a parked drone for its parts or its token.
Keep passes on, rate limits on, and parked drones inside claims.

**The server's life.** Servers wipe, packs update, players leave. Sourced:
"people left" is the most common way an SMP fails. Keep the code and the
knowledge in this repo, so the service can be rebuilt on a new world in a
day. Don't sink months into anything that only works on one map.

**The admins.** A fleet of physics craft adds CPU load (sourced), and chunk
loaders on the move have leaked lag in other loaders (sourced, Create Power
Loader). Talk to the admins before scaling: routes, loaded chunks, how many
craft. A service the admins like survives. One that lags their server
doesn't.

## Decisions for Alex

1. After the chunk test: do we promise service while you're offline, or only
   while you're on?
2. May logs move to a private repo, with the current token revoked?
3. Platforms only for customers, or open ground as a paid extra?
4. Passengers: do they ride at their own risk, and what is refunded or
   compensated when a ride fails?
5. Service area and hours for launch: which hubs, and when.

## Sources

- Create Propulsion thruster API: throttle cleared when the computer detaches (memory `dronenet-server-computer-stops`, from the mod wiki)
- [Aeronautic Additions and ChunkLoader](https://www.curseforge.com/minecraft/mc-mods/aeronautic-additions-and-chunkloader): "not recommended" on very fast aircraft
- [Create Power Loader #78](https://github.com/hlysine/create_power_loader/issues/78): chunk leak, and no loading beyond simulation distance with Sable (NeoForge 1.21.1)
- [Sable #1582](https://github.com/ryanhcode/sable/issues/1582): sub-level desync under server tick lag
- [Create Aeronautics server guide](https://modready.gg/guides/create-aeronautics-server): physics cost per craft, chunk generation and TPS
- [CC:Tweaked #951](https://github.com/cc-tweaked/CC-Tweaked/issues/951): computers and chunk reloads; programs restart from startup
- [ccryptolib](https://github.com/migeyel/ccryptolib) and [CCSecureBoot](https://modrinth.com/mod/ccsecureboot): ed25519 signatures in CC
- [Open Parties and Claims](https://modrinth.com/mod/open-parties-and-claims): offline forceload is a server config option
- [Drone delivery in 2026](https://dronexl.co/guides/drone-delivery/) and [Zipline vs Amazon design](https://dronexl.co/2026/08/22/amazon-pool-drop-zipline-drone-delivery-design/): precision at the delivery point is what separates operators; weather and obstacle incidents
- [On-demand failure: density and utilisation](https://medium.com/@adampricenyc/the-unit-economics-of-on-demand-delivery-startups-explained-acdff869fec5), [cold start](https://www.softwareseni.com/the-platform-trap-why-most-platforms-fail-before-reaching-critical-mass-and-how-to-overcome-the-cold-start-problem/)
- [SMP economies](https://guildorder.com/games/minecraft/guides/smp-frameworks): money sinks, and "people left" as the most common failure
