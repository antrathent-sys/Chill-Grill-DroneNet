# Server performance on a Create and Aeronautics server

Written 2026-10-01 for Alex: the Chill and Grill server lags with only one
or two players on, and lowering Sable's tracking range from 320 to 160 made
it stop. This is about **server TPS** - the server falling behind its 20
ticks a second - not about a client's frame rate. It is grounded in the
pack's own configs (5.2) and in Sable's and Aeronautics' source where that
was read; the rest is general Minecraft and Create knowledge and is marked
as such.

## What spark showed, 2026-10-02

One profile (`uiqBYjrju8.sparkprofile`, taken by zombiehead_tw): the main
server thread, sampled every 4 ms for 31 minutes, 3 then 4 players on,
NeoForge 21.1.250, 147 mods, a 12-core EPYC, a 10 GB heap. Read with a
protobuf decoder here, so these are the numbers in the file, not a reading
of the web view.

- **The server has no headroom.** TPS 15.8 over the profile (15.8 / 15.9 /
  15.7 over 1, 5 and 15 minutes); a tick takes 58 ms at the median, 78 ms at
  the 95th percentile, 1,244 ms at worst. In the calm minutes it ran at 19
  to 20 TPS on 46 to 50 ms a tick: right at the 50 ms limit, so anything
  extra drops it.
- **Sable's physics is the biggest single cost: about 22 ms of every tick**,
  44% of the calm minutes and 38.5% of the whole profile. The "lambda" in
  the call tree is `SubLevelContainer.lambda$tick$0` - Java's name for the
  unnamed function inside Sable's tick that runs once per physics object.
  It has nothing to do with LAMBDA-001. Under it, `Rapier3D.step` (the
  physics engine, a native library) is 30.7% of the thread, and **28% is the
  server thread sitting in a system call inside that library** - waiting,
  most likely for Rapier's own worker threads to finish the step. Sable's
  other costs are small: tracking 0.7%, its chunk tickets 0.7%, plot ticking
  0.2%. So it is not tracking or chunk churn; it is **how much there is to
  simulate**: how many physics objects are loaded and awake.
- **Create is about a quarter of the tick** (block entities, 15 ms a tick in
  the calm minutes). Two odd hot spots: a Create Tweaked Controllers mixin on
  every kinetic block entity (1.5% on its own) and Immersive Furniture
  hashing item stacks (0.95%).
- **The bad stretch** (minutes 16 to 22: a fourth player, entities up from
  2,200 to 3,000) added 28 ms a tick: **11 ms of mob AI** (animals,
  villagers) and **8 ms of block entities**, mostly Create. Sable rose only
  2.6 ms. That is somebody's base - farm animals, a trading hall, machines -
  coming into range.
- **Far more of the world is held loaded than three players need**: spark
  counts 22,000 to 26,000 chunks all through. Spark's count includes the
  part-loaded ring round every loaded area, so the true number of full
  chunks is lower, but three players at view distance 8 account for perhaps
  5,000. The rest is islands held by force-loads: chunk loaders, `/forceload`,
  claims, and **Sable's own tickets round every physics object**, wherever
  it is. Each of those islands is also a physics object being simulated.
- **Not the cause**: CC:Tweaked, all of everyone's computers together, is
  0.16% of the server thread. Garbage collection is 119 young collections in
  7 hours at about 73 ms each - a few hitches, not the lag. **Distant
  Horizons is not installed on this server** (it is not among the 147 mods),
  so the Distant Horizons section further down does not apply here.

**What it means.** The baseline is physics objects plus Create, with no
room left; players' bases push it over. The one number nobody has yet is
**how many physics objects are loaded**, and where: `/sable info @e` lists
them, `@e[speed=0.01..]` the ones that never come to rest, and `/sable
forceload query` and `/forceload query` what holds them loaded.

### The second profile, same day (`RAAAHuGeTT`, codyrules987)

Ten minutes, 6 players. TPS 9 to 10; a tick takes 90 ms at the median.

| ms per tick | first (3-4 players) | second (6 players) |
|---|---|---|
| Sable physics | 22.4 | 23.3 |
| machines (block entities) | 17.9 | 28.7 (Create 19.6) |
| entities (mobs mostly) | 7.7 | 23.2 |
| chunk ticking | 3.0 | 7.5 |
| whole tick | 55.4 | 92.1 |

- **Physics did not move**, so substeps were still 2. It is a fixed cost
  whoever is on; everything else grows with players and their bases.
- **Entities**: 11,300 for the first three minutes, then 2,800 - something
  cleared about 8,500. Mob AI alone is 15% of the thread.
- **Full garbage collections**: 18 in 3 hours of uptime, **1.5 seconds
  each**, and every minute of this profile had a 1.6 to 2.3 second tick.
  The first profile had none. Those are the freezes players feel; the
  10 GB heap is under pressure (`/spark gc`, `/spark heapsummary`, the
  server's GC flags).
- Chunks held: 26,000, rising to 41,000 for four minutes.

### Memory, same day (`/spark gc`, heap summary `8xQQLnw4k2`)

- `/spark gc`: 50 full collections at **1.5 s each, one every 3 m 45 s** -
  the freezes. Young collections (37 ms every 7 s) are normal.
- The heap summary (taken after a full collection) shows **4.4 GB live in a
  10.5 GB heap**. Memory is not full and nothing large is leaking, so the
  full collections are not simply "out of room". Likelier: something
  forcing them (`System.gc()` from a server-only mod - BlueMap, ServerCore
  and the like were not in the client pack to scan; none of the 125 pack
  jars does it on the server), or the heap fragmenting on large one-off
  arrays (chunk data, big network packets) that G1 cannot place. The fixes:
  `-XX:+DisableExplicitGC`, a larger `-XX:G1HeapRegionSize` (16M), or
  Generational ZGC; `-Xlog:gc*:file=logs/gc.log:time,uptime` says which.
- **WorldEdit** keeps its own copy of every block state in the pack -
  450,112, one per Minecraft block state - each with a Guava lookup table
  (447,184 of them): roughly **1 GB** of the 4.4. Removing WorldEdit if it
  is rarely used frees it.
- For scale: BlueMap 92 MB, Create 18 MB, Sable 9 MB, CC:Tweaked's Lua
  (every computer, CINDER's included) 4 MB.

### The third profile, after Sable substeps 1 (`Mv1sPs5Da6`, 2026-10-04)

Nine minutes, 3-4 players. Milliseconds a tick, against the first two:

| | first (3-4 players) | second (6) | **third (3-4, substeps 1)** |
|---|---|---|---|
| Sable physics | 22.4 | 23.3 | **17.0** |
| block entities | 17.9 | 28.7 | 29.4 |
| of which Create | 11.8 | 19.6 | 18.5 |
| entities | 7.7 | 23.2 | 15.4 |
| chunk ticking | 3.0 | 7.5 | 7.6 |
| chunk map | 1.5 | 3.9 | 3.1 |
| **whole tick** | 55.4 | 92.1 | **76.3** |

- **Substeps 1 worked: Sable physics is down about a quarter**, 23 to
  17 ms, and stayed there through the whole profile.
- **What dragged the tick down during it was dropped items.** Entities
  went from 3,200 to 9,800 in nine minutes and TPS fell from 14 to 9 with
  them; the whole tick went 64 to 92 ms. At the end 7,600 of the entities
  were `minecraft:item`, in three chunks:
  - chunk 269, -234 - **x 4304 to 4319, z -3744 to -3729**: 3,637 items;
  - chunks -47, 174 and -47, 175 - **x -752 to -737, z 2784 to 2815**:
    3,834 items, with 23 hopper minecarts beside them.
  The items barely cost anything themselves (0.4 ms - they lie still), but
  every entity costs its turn in the entity list (entities 13 to 19 ms over
  the profile) and its tracking for players nearby (chunk map 1 to 7 ms).
  It looks like two farms overflowing onto the ground faster than items
  despawn. Stopping the overflow at those two places is the fix; an op can
  clear what is there now with
  `/kill @e[type=minecraft:item,x=4304,y=-64,z=-3744,dx=15,dy=384,dz=15]`
  (and the same at x=-752, z=2784, dz=31).
- Create grew too, 15.5 to 22 ms, spread across belts, funnels, chutes and
  the rest rather than one machine - more players running more builds.
  Frogports (2.0 ms), belts (2.0), chutes (1.2) and funnels (0.9) lead.
- Mobs are most of the entity time that is not items: about 9 ms of
  hostile-mob AI (zombies, skeletons, creepers, spiders, bats).
- 27,000 to 34,500 chunks loaded, more than the first profile's 22,000.
- **Memory is now nearly full.** The viewer's Metadata -> Memory tab: the
  old generation holds **8.4 GB after a collection, of a 9.8 GB maximum**
  (it was 4.4 GB live on 2026-10-02). Over the 7 hours the server had been
  up, G1 did **244 full collections averaging 1.6 s - one every 1 m 43 s**
  (8 during the profile, 1.9 s each); on 2026-10-02 it was one every
  3 m 45 s. Each is a 1.6-1.9 s freeze.
- **The machine:** JVM flags are `-Xmx10000M -Xms128M` and nothing else -
  default G1, untuned, the heap starting at 128 MB. The container has **4
  CPU threads** (an EPYC 4465P has 24) for the main thread, Sable's physics,
  the collector and the rest; 16.5% of the main thread's samples are spent
  waiting in a system call. The host itself is at 80% of its physical
  memory with **58 GB of swap in use** - a shared node, overcommitted; a
  heap paged out to swap makes every full collection longer.
- `spawnChunkRadius` is 5 (default 2): 121 spawn chunks always loaded and
  ticking instead of 25.

## What other servers do (research, 2026-10-02)

Four parallel searches of GitHub issues, mod pages, modded-server guides
and server rule pages. The headline items were re-checked by hand (marked
checked); the rest is as the sources say, with links.

**Sable: we are on a version with a known regression.** Sable issue
[#1594](https://github.com/ryanhcode/sable/issues/1594) (open, 2026-09-29,
checked): `Rapier3D.step` is "effectively absent" from profiles on Sable
2.0.3, about 6.5% idle on 2.0.4 and about 18% on **2.0.5 - this server's
version** - even with no craft assembled. That fits a 22 ms physics cost that
does not change with players. Issue
[#734](https://github.com/ryanhcode/sable/issues/734) (open, checked) has the
same symptom we see - Rapier time spent in a `syscall`, on Linux - with no
fix posted. Issue [#1398](https://github.com/ryanhcode/sable/issues/1398)
reports the cost vanishing with `/sable paused true`. What to do:
- A spark profile with `/sable paused true` for a minute (every craft
  freezes in place while paused) measures how much is fixed cost.
- Sable 2.0.3, **on a copy of the world first**: one reporter ran it with
  Aeronautics 1.3.2; nobody has reported a world surviving the downgrade.
- 1 substep still halves whatever the step costs.
- Untested: `RAYON_NUM_THREADS` (the Rapier worker pool size, an
  environment variable) - raised in issue #1574 for a server hanging in
  `Rapier3D.step`.
- Sable has no ship caps or idle freezing. Valkyrien Skies servers solved
  the same clutter with ship registration, per-player caps and purges of
  unregistered ships; Sable's equivalents are `/sable storage
  find_all_sub_levels`, `/sable name set` and `/sable remove`.
- Watch: Aeronautics' Redstone Accumulator can drop items endlessly until
  the server runs out of memory (Simulated-Project #1438).

**Create: performance addons exist, and other servers use them** (all for
1.21.1 NeoForge; add one at a time):
- **Create: LazyTick** (about 750,000 downloads, checked): idle and jammed
  belts, funnels, chutes, depots, arms, saws, basins and crafters back off
  and wake on events; recipe caching. Slight animation delay; machines
  driven by very short redstone pulses can miss a wake-up.
  [modrinth](https://modrinth.com/mod/createlazytick)
- **StellarCreateOptimization**: the only one naming our hot spots - fans
  rebuild air currents only when blocks change, chain conveyors stop
  rebuilding shapes, kinetic and pump caches. Tested on Create 6.0.8, not
  confirmed on 6.0.10.
  [curseforge](https://www.curseforge.com/minecraft/mc-mods/stellarcreateoptimization)
- **Create: Advanced Optimization** (pinned to Create 6.0.10): caching
  without slowing machines, and diagnostics - `/cao packages stalled`,
  `/cao belts scan`, `/cao diagnose`.
  [modrinth](https://modrinth.com/mod/create-advanced-optimization)
- **Create: Tick Control**: tick divisors and an emergency throttle above
  55 ms; cuts real throughput, overlaps LazyTick.
- **A Create bug feeding the frogport cost**: a package that meets a full
  frogport circles the chain for ever (Create issue
  [#7680](https://github.com/Creators-of-Create/Create/issues/7680), open,
  due 6.0.11). Fix by emptying or removing full ports; `/cao packages
  stalled` finds them.
- **Create Tweaked Controllers**: confirmed from both sources - Create
  calls `getFlickerScore()` twice a tick on every kinetic block and breaks
  a block whose score passes 128 (its guard against redstone-clocked
  clutches); the addon forces 0 for every block on the server, so the
  guard is off everywhere.

**Server mods others run** (exist for NeoForge 1.21.1):
- Safe: Smooth Chunk Save (spreads out saves - Sable save spikes of up to
  10 s are issue #679), Alternate Current, Async Locator Refined, Let Me
  Despawn (needs Almanac Lib or it crashes at start), AllTheLeaks (memory
  leak fixes), AI Improvements.
- Avoid in this pack: **Moonrise** (crashes with Sable, Moonrise #177),
  **ScalableLux** (crashes with Sable, Sable #22), **C2ME** (alpha;
  crashes reported with physics mods and in Sable hang reports), **Async**
  (lists Open Parties and Claims as incompatible).
- Experimental: "Aeronautics/Sable Optimizer" (AI-written by its author's
  own account, back up first).

**Java.** NeoForge 1.21.1 is Java 21. The All The Mods guide's line is
Generational ZGC: `-XX:+UseZGC -XX:+ZGenerational -XX:+AlwaysPreTouch
-XX:+DisableExplicitGC -XX:+PerfDisableSharedMem`, with no G1 flags mixed
in, and 2 to 4 GB of the container left outside the heap (more for ZGC;
Sable's native physics memory is outside the heap too). On the full GCs:
a steady period fits something calling `System.gc()` better than plain
heap pressure - including Java itself when off-heap (direct) memory, which
the network layer uses, reaches its cap. If that is the cause,
`-XX:+DisableExplicitGC` can turn the freezes into "Direct buffer memory"
crashes; `-XX:+ExplicitGCInvokesConcurrent` is the safe form on G1. The GC
log says which: `-Xlog:gc*,gc+heap=debug,safepoint:file=logs/gc.log:time,uptime,level,tags:filecount=5,filesize=20M`,
then look for `Pause Full (...)`.

**Finding the laggy builds** (built in to NeoForge 1.21.1):
- `/neoforge track start blockentity 30`, then `/neoforge track
  blockentity`: the 10 costliest block entities, with coordinates.
- `/neoforge entity list minecraft:item`: the chunks with the most items
  (overflowing farms, portal loaders).
- Observable (has a 1.21.1 NeoForge build): a per-block cost map with
  teleport links.
- spark: `--only-ticks-over 100` for spikes.

**Rules other servers publish** (no Create server's own rules page was
found; these are from a vanilla technical server, an SMP and hosting
guides): villager caps (32 per trading hall), farms more than simulation
distance apart (no "industrial districts"), chunk loading only to protect a
build and never as a stand-in for a player online, machines off when away,
staff can order a build changed, escalation from warning to removal. Tools
that enforce it: Open Parties and Claims' force-load limits,
Limited Chunkloading (drops a player's loader tickets some minutes after
they log off), Create: Power Loader (loaders players can switch off), and
TabTPS to put TPS in the tab list.

## General advice for a Create and Aeronautics server (2026-10-02)

Broad changes that help whatever the cause, in rough order of payoff.
Mod versions for 1.21.1 NeoForge are to be checked before adding anything.

**Configure what is already installed**
- **ServerCore** (on the server, `config/servercore/`): see "ServerCore
  for this server" below. It has no per-chunk entity limits (an earlier
  version of this note said it did); it has breeding caps, mob cap
  enforcement, activation range, villager lobotomising and dynamic
  scaling.
- **Simulation distance 8 -> 6** in `server.properties`: about 40% fewer
  chunks ticking round each player, so fewer mobs and machines running.
  View distance can stay 8 (that only sends terrain).
- `entity-broadcast-range-percentage` 100 -> 75: fewer entities sent to
  each player.
- Already there and worth keeping: Lithium, FerriteCore, ModernFix, Clumps,
  Get It Together Drops, Packet Fixer, Create Threaded Trains.

**Worth adding**
- **Let Me Despawn**: mobs that picked up an item stop being kept forever.
- **Alternate Current**: much cheaper redstone dust.
- **Async Locator**: `/locate`, explorer maps and dolphins stop freezing
  the tick.
- Not chunk-generation mods (C2ME and the like): the world is
  pre-generated, and they touch the chunk code Sable hooks.

**ServerCore for this server** (from its source, 1.5.19, and its own
example configs in `docs/config/`; edit the generated files rather than
pasting wholesale, since the 1.21.1 build may lack a key or two)

`optimizations.yml` (restart to apply): `fast-biome-lookups: true`,
`cancel-duplicate-fluid-ticks: true`, `optimize-command-blocks: true`;
`reduce-sync-loads` and `cache-ticking-chunks` are already on by default.

`config.yml` (`/servercore reload`):
- **Activation range, made safe for Create.** Every entity without a
  custom type gets the default type, and Create's contraptions (windmills,
  bearings, gantries, minecart contraptions, train carriages), packages,
  glue and the physics mods' entities are not mobs. Left on the default,
  they would tick once a second when no player is within 16 blocks and
  skip every fourth tick even near one - machines slowing and stuttering.
  ServerCore excludes any type whose tick interval is 1, so give the
  default type `tick-interval: 1` and let only the mob types be slowed:

  ```yml
  activation-range:
    enabled: true
    tick-new-entities: true
    use-vertical-range: true
    skip-non-immune: true
    excluded-entity-types:
      - 'minecraft:warden'
      - 'minecraft:hopper_minecart'
      - 'minecraft:ghast'
    default-activation-type:      # everything that is not a mob: untouched
      activation-range: 16
      tick-interval: 1
      wakeup-interval: -1
      extra-height-up: false
      extra-height-down: false
    # custom-activation-types: keep the example's raider, water, villager,
    # zombie, monster-below, flying-monster, monster, animal and creature
    # entries (all typeof:/mob matchers) as they are
  ```
- `dynamic`: enabled, `target-mspt: 45`. Order: `CHUNK_TICK_DISTANCE`
  10 -> 4, `MOBCAP_PERCENTAGE` 100 -> 50, `SIMULATION_DISTANCE` 8 -> 5.
  Not lower than 5, and not view distance: players' factories stop beyond
  the simulation distance, and terrain popping in costs little.
- `breeding-cap`: enabled - villagers 24, animals 32 of a kind within 64
  blocks.
- `mob-spawning`: `enforce-mobcap: true` for spawners, zombie
  reinforcements and nether portal spawns.
- `features`: `lobotomize-villagers` on (trading halls tick once a second);
  `item-merge-radius: 2.0`, `xp-merge-radius: 3.0`, `xp-merge-fraction: 8`;
  `autosave-interval-seconds: 600` if a longer gap between saves is
  acceptable. **Leave `prevent-moving-into-unloaded-chunks` off**: it
  turns back players moving into chunks not yet loaded, which is what a
  player on a fast craft does.

**Create, measured** (both 2026-10-02 profiles, ms per tick, 3-4 then 6
players). Create is 12 to 20 ms a tick in all.
- **Frogports and chain conveyors** (Create 6 package logistics): 2.7 to
  2.8 together - the biggest named Create cost. Then fans 0.4 / 1.9, belts
  1.0 / 1.8, chutes 0.7 / 1.1, funnels 0.5 / 0.8, pumps 0.4 / 0.8.
- **Create Tweaked Controllers costs 0.9 to 1.4 ms a tick on its own**: a
  mixin on every kinetic block's `getFlickerScore` that always answers 0
  (read from its bytecode). That also switches off Create's protection
  against machines flickered on and off by redstone, and allocates on
  every call - more garbage for the collector. Remove it if nobody needs
  it, or take it to its author.
- Settings in `create-server.toml` (the pack's values; the server's may
  differ), each a little less work for a little less speed:
  `fanBlockCheckRate` 30 -> 60, `fanPushDistance` and `fanPullDistance`
  20 -> 12, `defaultExtractionTimer` 8 -> 12, `brassTunnelTimer` 10 -> 15,
  `factoryGaugeTimer` 100 -> 200, `hosePulleyRange` 128 -> 64.
- Already right: Create Threaded Trains moves train navigation off the
  main thread.
- **Create's entities are cheap**: 1.4 ms a tick (first profile), 2.5 ms
  (second) - against 12 to 20 ms for its machines. Moving contraptions
  0.6 / 1.3, packages 0.35, train carriages 0.2; super glue (256 of them)
  and Simulated's honey glue (220) next to nothing. The entity ids are
  `create:contraption`, `stationary_contraption`, `gantry_contraption`,
  `carriage_contraption`, `package`, `seat`, `super_glue`,
  `crafting_blueprint`, `potato_projectile`. What can be done:
  - `create:package` (a dropped box) can take a ServerCore custom
    activation type - say 32 blocks, tick interval 20 - harmlessly. About
    0.3 ms.
  - Contraptions must keep full speed. Fewer of them instead: bearings and
    pistons set to place their blocks when stopped are blocks again, not
    entities, while idle; windmills cannot be. `maxBlocksMoved` (2048)
    caps their size.

**Create specifically**
- Machines and farms run whenever their chunks are loaded: ask players to
  put a clutch or redstone stop on big builds and switch them off when idle.
- Packages (Create 6 frogports and chain conveyors) that cannot be
  delivered become entities: watch `create:package` in `/neoforge entity
  list`; nothing on the server caps them, so it is a player habit.
- `create-server.toml`: a longer `factoryGaugeTimer` if there are many
  factory gauges; contraption size limits (`maxBlocksMoved`, and
  Simulated's 128,000) lower.

**Sable and Aeronautics** (settings from Sable's source, 2026-10-02)
- `sub_level_substeps_per_tick` 2 -> 1 (Sable's server config): the
  physics step is about 22 ms a tick and runs once per substep.
- `sub_level_tracking_range`: keep it at 160 (it was 320).
- `sub_level_remove_min` is -10,000: anything that falls out of the world
  is simulated all the way down - over a minute of falling at the drag
  terminal speed of about 120 blocks a second. About -128 removes it soon
  after it leaves the world.
- `sub_level_saving_log_message = false`: one less line per save.
- Runtime, op only: `/sable debug config solver_iterations` - 18 here
  against Rapier's own default of 4. A second lever after substeps; it is
  what keeps joints stiff, so test it.
- Simulated's `maxBlocksMoved` is 128,000: big craft cost more to collide,
  save and send. 10,000 to 20,000 still allows large ships.
- Aeronautic Additions' `chunkLoadPadding` 2 -> 1: a craft's chunk loader
  holds 3x3 chunks instead of 5x5.
- Habits: a craft resting on the ground with its engines off settles and
  goes to sleep in the physics engine, costing almost nothing; one hovering
  on balloons or bobbing on water never settles. Park craft landed or
  docked, pack the ones not in use into their containers, and clear
  wreckage (splitting leaves fragments): `/sable info @e`, then `/sable
  remove`.

**Chunk loaders** (Alex, 2026-10-02: how many of the 20,000+ are players'
vanilla loaders?)
- The legitimate ones here: Open Parties and Claims force-loads (10 per
  player, only while they or their party are online), Aeronautic Additions'
  loader on craft, Sable's own tickets round physics objects, and an
  admin's `/forceload`.
- Vanilla on 1.21.1 has two: **spawn chunks**, and **portal loaders** -
  anything going through a nether portal loads the chunks round the other
  end for 15 seconds, so a dropper or hopper loop feeding items through a
  portal keeps chunks loaded for ever. (Ender pearls only load chunks from
  1.21.2, not on this server.)
- Counting: `/forceload query` in each dimension, `/sable forceload query`.
  Nothing built in lists portal tickets: look for portals with hoppers,
  droppers or item streams beside farms, in both dimensions.
- Protecting: gamerule `spawnChunkRadius 0` (spawn stops being a free
  loader); a server rule against portal loaders, with OPAC force-loads as
  the sanctioned way to keep a build running; and, worth testing, a KubeJS
  script (KubeJS is on the server) cancelling NeoForge's
  `EntityTravelToDimensionEvent` for item entities, which breaks the loop -
  at the cost of item transport through portals.

**Java and the host**
- Java 21 with tuned flags (Aikar's G1 flags, or Generational ZGC), heap
  `-Xms` = `-Xmx`, `-XX:+DisableExplicitGC`.
- A scheduled restart every 12 to 24 hours.

**Rules for players**
- Caps on mob farms and animal pens, trading halls kept compact, factories
  off when not in use, and a way to report lag spots.

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
| **spark** (server-side mod, on the server since 2026-10-02) | the real answer. `/spark tps` and `/spark health` (TPS, MSPT, memory, CPU); `/spark profiler start --only-ticks-over 60` ... `/spark profiler stop` records only the slow ticks and gives a link to a call tree you can open down to the exact mod and method; `/spark tickmonitor` reports each long tick as it happens; `/spark gc` for garbage-collection pauses | operator; clients do not need it |
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
| **chunk generation** | the most expensive thing a server does. Fast travel into new land generates chunk after chunk. **This server's world is pre-generated** (Alex, 2026-10-01), so travel loads chunks rather than creating them |
| **Distant Horizons** | in the pack for clients, **not on this server** (spark's mod list, 2026-10-02) |
| **entities** | items on the ground, mob farms, villagers, armour stands - checked against each other every tick |
| **memory** | 147 mods need room. Too little and the garbage collector pauses the whole server: lag spikes with nobody doing anything (`/spark gc` shows it) |
| **computers** | CC:Tweaked runs every computer on one thread (`computer_threads = 1`) and lets their peripheral calls take up to 10 ms of each 50 ms tick (`max_main_global_time = 10`). A computer polling inventories in a loop spends that |

## Distant Horizons, where a server runs it

**Not this server**: the 2026-10-02 profile shows it is not installed
there. Written 2026-10-01 from the pack's own `DistantHorizons.toml`, before
the profile, and kept for any server that does run it. How it works, from
that file and its descriptions of each setting:

- Each player's client asks the server for LOD data - simplified terrain -
  for everything out to `lodChunkRenderDistanceRadius = 256` chunks. With
  `enableServerGeneration = true` the server builds what the client lacks,
  out to `maxGenerationRequestDistance = 4096` blocks, taking up to
  `generationRequestRateLimit = 20` requests a second from each client.
  With `enableRealTimeUpdates = true` it also sends changes within 256
  chunks as they happen.
- **How the server builds it is the generator mode, and this pack uses
  `distantGeneratorMode = "INTERNAL_SERVER"`.** DH's own description: *"Ask
  the local server to generate/load each chunk ... may cause
  server/simulation lag ... unlike other modes this option DOES save
  generated chunks to Minecraft's region files."* So every chunk out to
  4,096 blocks round each player is **loaded by the server itself** - a
  pre-generated world only means it is loaded rather than generated. That
  is tens of thousands of chunks, through the same chunk system the game
  runs on, for one player.
- It runs on `numberOfThreads = 9` threads at `threadRunTimeRatio = 1.0`.
  On a host with few cores, nine busy threads starve the main thread that
  runs the ticks, even if none of DH's own work is on it.

**Why it would explain this server's lag, and why the tracking range
helped.** Sable loads every physics object stored in a chunk whenever that
chunk is loaded, by anything (its plot `ChunkMapMixin`), and saves it when the
chunk goes again. With DH loading chunks in a ring around the player, objects
in that ring are loaded, sent to the player in full if they are within the
tracking range, then unloaded and saved, over and over - invisible to the
player, who sees only terrain out there. At a 320 tracking range a ring of
that churn reached the player; at 160, roughly the view distance, it does
not. That fits "nothing in range, lags anyway, fixed at 160". It is the
likeliest explanation, not a proven one: a spark profile would show Sable's
loading and tracking, and DH's chunk requests, by name.

**What to change**, on the server's `DistantHorizons.toml`, least drastic
first:

1. `distantGeneratorMode = "PRE_EXISTING_ONLY"` - *"Only create LOD data for
   already generated chunks."* The world is pre-generated, so players lose
   nothing, and DH stops asking the server to load chunks for it.
2. `numberOfThreads` down to 2 or 3, and `threadRunTimeRatio` below 1.0, so
   DH can never crowd out the main thread.
3. `maxGenerationRequestDistance` and `realTimeUpdateDistanceRadiusInChunks`
   lower, or `enableServerGeneration = false`, if it is still a cost.

## Open Parties and Claims force-loading

From its source (`PlayerConfigOptions`, 1.21 branch) and this pack's server
config:

- A player's force-loaded chunks stay loaded only while they are online -
  or, if they own a party, while **any member of that party** is online -
  unless `claims.forceload.offlineForceload` is on: **default off**, with the
  mod's own warning, *"can significantly affect server performance!"*
  (`ForceLoadTicketManager.ticketsShouldBeEnabled`).
- **Server claims are always force-loaded**, whoever is online. That is the
  way to keep chosen chunks running - a base, a depot - without turning
  offline force-loading on for everyone.
- In this pack players **cannot turn it on themselves**: it is not in
  `playerConfigurablePlayerConfigOptions`, nor in the list operators can set
  per player. Only the server's default player config can, for everybody.
- Each player can force-load at most `maxPlayerClaimForceloads = 10` chunks,
  plus party bonuses.
- There is no timed decay of force-loads as such. They stop when the owner
  logs off (with offline force-loading off), and a player's claims - and so
  their force-loads - expire after `playerClaimsExpirationTime = 8760` hours,
  a year, of inactivity.

So with offline force-loading at its default, OPAC is not what runs with
nobody on. **It also means CINDER's base and depots stop when Alex and their
party are offline**, unless they are server claims, `/forceload`ed by an
admin, or held by a chunk loader - INFRASTRUCTURE.md risk 6. Worth one check: the server's own default player config
(`openpartiesandclaims-default-player-config.toml`, in the world's
`serverconfig`), which the pack does not ship and which decides it.

What does stay loaded with nobody on: vanilla `/forceload` chunks, Sable
force-loads (`/sable forceload query`), and **chunk loaders on craft** -
Aeronautic Additions' loader keeps a craft's chunks plus two all round
loaded wherever it is parked, owner online or not.

## What a server owner can do

In the order I would do them on this server:

1. **Count the physics objects.** The profile's biggest cost (above).
   `/sable info @e`, then `@e[speed=0.01..]` for the restless ones; remove
   wreckage, abandoned craft and stray assembled blocks, and ask owners to
   pack craft they are not using into their containers.
2. **Find what holds the world loaded.** `/forceload query`, `/sable
   forceload query`, chunk loader blocks on craft, Open Parties and Claims
   force-loads. Each loaded island is chunks and a physics object.
3. **Fence the world.** It is pre-generated; a world border to match keeps
   it that way.
4. **Audit force-loading.** `/forceload query`, Open Parties and Claims'
   force-load settings (offline force-loading especially), chunk loader
   blocks, `/sable forceload query`. Every force-loaded factory runs with
   nobody there.
5. **Keep physics objects tidy.** Count them with `/sable info @e`; find the
   ones that never sleep with `@e[speed=0.01..]`; remove wreckage and
   abandoned craft. Packing a craft into its container removes it as a
   physics object. Consider a lower `maxBlocksMoved` than 128,000.
6. **View and simulation distance.** Simulation distance decides how far
   round each player things tick; it is 8 here, which is reasonable. Mob AI
   was 11 ms a tick when one base came into range: entity limits per chunk,
   or fewer animals and villagers in one place, are the lever there.
7. **Memory and restarts.** Enough RAM with a modern collector, checked
   with `/spark health`; a scheduled restart if anything grows with uptime.
8. **Big builds.** Agree what a factory may be - a mega-factory left
   running all day costs the same with its owner online or not - and turn
   machines off with redstone when they are not needed.

## CINDER's own share

| what | cost | what we do |
|---|---|---|
| **LAMBDA-001 in flight** | its chunk loader's 5x5 area moves at up to 187 blocks a second; Sable holds chunks round it too | the world is pre-generated, so it loads rather than generates; we fly direct, and never loiter |
| **LAMBDA-001 parked** | if its chunk loader stays on while docked, it keeps a 5x5 area round its dock loaded all day, and everything in it ticking | to check: whether the loader can be off while parked |
| **silos** | every assembled silo is a physics object until taken apart, including delivered ones and test silos in the bays | a rule to recycle or take apart silos at their destination |
| **our computers** | drone (10 Hz, Sable and thruster calls), base, depot (reads its silos every second during a fill), screens, tower and every nav unit (Sable twice a second) - all on the one CC thread and its 10 ms | slow down when nothing is happening: depots between fills, nav units when parked |

Being light matters to us twice over: if the admins cut CC's budget to
fight lag, our flights are what degrade first.

## For this server, now

After the 2026-10-02 profile, in order:

1. `/sable info @e` - how many physics objects, and where. With 22 ms a tick
   in the physics step, this is the number that matters most.
2. `/sable info @e[speed=0.01..]` - the ones that never sleep: each keeps
   the physics step busy every tick.
3. `/forceload query`, `/sable forceload query` and the chunk loaders - what
   is holding 20,000 chunks with three players on.
4. `/chunky progress` - a pre-generation task left running is lag on its
   own, even on a finished world.
5. A second profile with one player on, idle, to see the floor without
   anyone's base loaded.
