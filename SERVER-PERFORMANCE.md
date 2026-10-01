# Server performance on a Create and Aeronautics server

Written 2026-10-01 for Alex: the Chill and Grill server lags with only one
or two players on, and lowering Sable's tracking range from 320 to 160 made
it stop. This is about **server TPS** - the server falling behind its 20
ticks a second - not about a client's frame rate. It is grounded in the
pack's own configs (5.2) and in Sable's and Aeronautics' source where that
was read; the rest is general Minecraft and Create knowledge and is marked
as such.

## First, read the symptom

A server at 20 TPS has 50 ms per tick. Lag is the tick taking longer. When
and how it happens says more than any single number:

| pattern | points at |
|---|---|
| **always slow**, players or not | something that runs whatever happens: force-loaded chunks with machines, chunk loaders, trains, physics objects that never sleep, Distant Horizons generating, computers in loaded chunks |
| **a spike every 5 minutes** | the autosave - many chunks, and every loaded physics object (Sable logs each save: `sub_level_saving_log_message = true` in this pack) |
| **worse the longer the server is up**, cured by a restart | something piling up: entities, item stacks, chunks that never unload (Sable's own source notes that its plot chunks "do not unload through vanilla means"), a growing queue |
| **spikes when someone travels** | chunks being loaded, or worse generated for the first time - fast aircraft are the worst case |
| **spikes when someone joins** | the join itself: a full world and every nearby physics object sent at once, Distant Horizons starting its work for that player |

Low TPS with **minimal players** means the cost is not players. It is what
keeps running without them, or what one player triggers far beyond where
they stand.

## The tools

| tool | what it tells you | who |
|---|---|---|
| `/neoforge tps` | mean tick time and TPS per dimension, built into NeoForge | operator |
| **spark** (server-side mod, not in the pack) | the real answer. `/spark tps` and `/spark health` (TPS, MSPT, memory, CPU); `/spark profiler start --only-ticks-over 60` ... `/spark profiler stop` records only the slow ticks and gives a link to a call tree you can open down to the exact mod and method; `/spark tickmonitor` reports each long tick as it happens; `/spark gc` for garbage-collection pauses | operator; clients do not need it |
| `/forceload query` | the chunks force-loaded in this dimension (vanilla) | operator |
| `/sable info @e` | every loaded physics object, with name and position; filters like `@e[distance=..320]`, `@e[speed=0.01..]` (moving ones), `@e[mass=1000..]`, `sort=nearest`, `limit=` | operator |
| `/sable forceload query` | physics objects that are force-loaded | operator |
| `/neoforge entity list` | entity counts by type: piles of items, mobs, armour stands | operator |
| `/chunky progress` | whether a pre-generation task is running, and how far | operator |
| the server console | `Can't keep up! ... ticks behind` lines, with times: line them up with the autosave, joins, flights | owner |
| vanilla `/perf start` | a 10-second profile written to the server's debug folder; rougher than spark | operator |

**spark first.** Everything else here is a reasoned guess until a profile
of a slow tick names the mod and the method.

## What makes the tick slow

### Create (general knowledge, with this pack's settings)

Create's machines are block entities that tick, and its moving parts are
entities. Nothing here needs a player nearby once the chunk is loaded.

| cost | why | in this pack |
|---|---|---|
| **big kinetic networks** | every kinetic block ticks; a speed change - a clutch, a gearshift, a sequenced gearshift, a source starting or stopping - propagates through the whole network | `kineticValidationFrequency = 60` ticks between validity checks |
| **belts full of items** | each item on each belt moves and collides every tick; long lines of full belts add up | `maxBeltLength = 20` |
| **funnels, tunnels, chutes, arms** | each looks for work on a timer | funnels every 8 ticks, brass tunnels every 10, arm range 5 |
| **moving contraptions** | bearings, pistons, gantries, windmills and minecart contraptions are entities that collide with blocks and entities every tick; a rotating windmill is one, all the time | `maxBlocksMoved = 2048` for Create contraptions |
| **trains** | navigation, signals and carriages; trains keep travelling the graph with nobody near | Steam 'n' Rails and Railways Navigator are in the pack |
| **logistics** | factory gauges request on a timer, display links read their sources, stock tickers count networks, packages travel as objects | `factoryGaugeTimer = 100` |
| **fluids** | pipe networks propagate flow; a hose pulley on a big body of fluid searches it | `hosePulleyRange = 128`, threshold 10,000 blocks |
| **fans** | each checks its air flow and pushes or processes entities in front of it | `fanBlockCheckRate = 30` |
| **farms** | crushing wheels and deployers killing mobs leave entities and items | item merging helps: Clumps and Get It Together, Drops! are in the pack |

### Aeronautics and Sable (from their source, where read)

| cost | why |
|---|---|
| **physics objects** | every awake object is stepped by the physics engine (2 substeps a tick here) and collides with the world around it. Sleeping ones are cheap; ones that never settle - jittering on terrain, bobbing on water - are not |
| **chunks held for physics** | Sable force-loads world chunk sections around every physics object so it can collide, players or not (`PhysicsChunkTicketManager`). A wreck sliding or bobbing anywhere keeps chunks loaded |
| **size** | this pack lets the Physics Assembler move structures of **128,000 blocks** (`maxBlocksMoved` in `simulated-server.toml`). Big objects cost more to build colliders for, to save and to send |
| **what is on them** | an airship's machines are block entities like any other and tick wherever the ship is loaded |
| **tracking** | every tick, every physics object is checked against every player; one coming within `sub_level_tracking_range` is sent in full, chunks and lighting, built on the server thread; there is no buffer at the edge, so one moving near it is re-sent over and over (`SubLevelTrackingSystem`). Lowering the range from 320 to 160 cut the space by eight |
| **ticking near players** | a physics object any player is tracking has its contents ticked as if the player stood beside it - random ticks and spawning in its chunks (Sable's plot `ChunkMapMixin`). The tracking range is also, in effect, how far away a ship's insides keep running |
| **balloons** | hot air burners and steam vents search for their balloon, up to 80 blocks (`aeronautics-server.toml`) |
| **breaking blocks** | a ship that loses blocks is checked for splitting, 200 steps a tick (`sub_level_splitting_heatmap_steps`) |
| **chunk loaders on craft** | Aeronautic Additions' chunk loader holds the craft's chunks plus `chunkLoadPadding = 2` around them: a 5x5 area. At cruise speed that is a new row of chunks loaded every fraction of a second |

### Minecraft in general, with few players

| cost | why |
|---|---|
| **force-loaded chunks** | farms and factories that run with their owner offline; Open Parties and Claims can force-load claims, including for offline players, if the server allows it |
| **chunk generation** | the most expensive thing a server does. Fast travel into new land - an aircraft at 180 blocks a second - generates chunk after chunk. The pack ships a Chunky task (5,000 blocks round 0,0) that is about 3% done and does not resume on restart |
| **Distant Horizons** | bundled with its **server-side generation on**: `enableServerGeneration`, `enableDistantGeneration` and real-time updates, out to 4,096 blocks and 256 chunks round each player. With one player on, the server can be doing a great deal of work for that one client |
| **entities** | items on the ground, mob farms, villagers, armour stands - checked against each other every tick |
| **memory** | 123 mods and Distant Horizons need room. Too little and the garbage collector pauses the whole server: lag spikes with nobody doing anything (`/spark gc` shows it) |
| **computers** | CC:Tweaked runs every computer on one thread (`computer_threads = 1`) and lets their peripheral calls take up to 10 ms of each 50 ms tick (`max_main_global_time = 10`). A computer polling inventories in a loop spends that |

## What a server owner can do

In the order I would do them on this server:

1. **Measure.** Add spark (server only) and take a profile of slow ticks
   with `--only-ticks-over 60`, once idle with one player on and once
   during a long flight. Everything below is a guess until then.
2. **Settle Distant Horizons.** With one player on and the lag gone at a
   lower tracking range, this is the first suspect: try
   `enableServerGeneration = false` and `enableRealTimeUpdates = false` in
   the server's `DistantHorizons.toml` for a day. Clients still see
   distance from what they have loaded.
3. **Pre-generate and fence the world.** Finish a Chunky task over the area
   people use and set a world border to match, during quiet hours. Every
   flight afterwards loads chunks instead of creating them.
4. **Audit force-loading.** `/forceload query`, Open Parties and Claims'
   force-load settings (offline force-loading especially), chunk loader
   blocks, `/sable forceload query`. Every force-loaded factory runs with
   nobody there.
5. **Keep physics objects tidy.** Count them with `/sable info @e`; find the
   ones that never sleep with `@e[speed=0.01..]`; remove wreckage and
   abandoned craft. Packing a craft into its container removes it as a
   physics object. Consider a lower `maxBlocksMoved` than 128,000.
6. **View and simulation distance.** Simulation distance decides how far
   round each player things tick; 6 to 8 chunks is plenty with Distant
   Horizons drawing the far view.
7. **Memory and restarts.** Enough RAM with a modern collector, checked
   with `/spark health`; a scheduled restart if anything grows with uptime.
8. **Big builds.** Agree what a factory may be - a mega-factory left
   running all day costs the same with its owner online or not - and turn
   machines off with redstone when they are not needed.

## CINDER's own share

| what | cost | what we do |
|---|---|---|
| **LAMBDA-001 in flight** | its chunk loader's 5x5 area moves at up to 187 blocks a second; Sable holds chunks round it too | pre-generation fixes the worst of it; we fly direct, and never loiter |
| **silos** | every assembled silo is a physics object until taken apart, including delivered ones and test silos in the bays | a rule to recycle or take apart silos at their destination |
| **our computers** | drone (10 Hz, Sable and thruster calls), base, depot (reads its silos every second during a fill), screens, tower and every nav unit (Sable twice a second) - all on the one CC thread and its 10 ms | slow down when nothing is happening: depots between fills, nav units when parked |

Being light matters to us twice over: if the admins cut CC's budget to
fight lag, our flights are what degrade first.

## For this server, now

With minimal players and the lag gone at a 160 tracking range, the order I
would test in:

1. `/chunky progress` - a pre-generation task left running is lag on its
   own.
2. With the range back at 320, does the lag come back? If not, a restart
   applied with the change is the likelier fix.
3. If it comes back: Distant Horizons' server generation off, range at 320,
   same place.
4. A spark profile of the slow ticks, whatever the answers above.
