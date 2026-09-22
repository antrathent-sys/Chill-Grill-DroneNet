# System map

How the pieces of the service fit together: the computers, what each sends to whom, and the states a ride, a load, a depot and a unit go through. The diagrams are Mermaid, so GitHub draws them.

Generated at 4fe8d06 by `python tools/make_system_map.py`: edit the diagrams there, not here.

## Who talks to whom

One authority. The ops computer holds every order key and decides everything; the screens only listen, depots only work their machines, passes only ask.

```mermaid
flowchart LR
  subgraph BASE["BASE"]
    OPS["ops computer<br/>board · dispatch · order keys<br/>ledger · jobs · cargo · incidents"]
    SCR["screens computer<br/>control room · wall<br/>listens only"]
    TILL["till<br/>seat · depositor"]
  end
  subgraph UNIT["UNIT · LAMBDA-n"]
    FC["flight computer<br/>beacon, runs fly"]
    RS["rsio<br/>dock latch"]
    ST["stickers<br/>left · right"]
    CL["chunk loader"]
  end
  subgraph DOCK["REMOTE DOCK"]
    DEP["depot computer<br/>depot.lua"]
    MAC["relays · silos<br/>intake · lifter"]
  end
  POCKET["pass<br/>hail, kiosk"]
  PAD["pad terminal<br/>taxipad"]
  OPS -- "orders, sealed" --> FC
  FC -- "telemetry · states · drops, sealed" --> OPS
  FC -. "telemetry" .-> SCR
  OPS -- "load · stuck, sealed" --> DEP
  DEP -- "hello · steps · lifted · counts, sealed" --> OPS
  DEP --- MAC
  CL -. "wakes it on arrival" .-> DEP
  POCKET -- "hails, sealed per pass" --> OPS
  OPS -- "quotes · job states" --> POCKET
  PAD -- "requests" --> OPS
  TILL --- OPS
  FC --- RS
  FC --- ST
```

## A ride

The job a pass follows from hail to home. Holding is the queue when every unit is busy.

```mermaid
stateDiagram-v2
  [*] --> quote: hail · fare.ask
  quote --> holding: confirm · no unit free
  quote --> assigned: confirm · unit free
  holding --> assigned: a unit comes free
  assigned --> enroute: unit flies to the pickup
  assigned --> waiting: unit already on station within 24
  enroute --> waiting: landed or docked
  enroute --> relocate: landing zone obstructed
  relocate --> enroute: customer sends a new spot
  relocate --> failed: no spot in 2 min · fare charged
  waiting --> riding: G · job.go
  riding --> done: landed at the destination
  enroute --> failed: flight failed · DISTRESS
  riding --> failed: flight failed · DISTRESS
  done --> [*]: unit flies home
  failed --> [*]
```

## A delivery from a depot

Queued at the base; the unit's arrival wakes the depot; the base passes every message between depot and unit.

```mermaid
sequenceDiagram
  actor OP as Operator
  participant OPS as Base · ops board
  participant U as Unit
  participant DEP as Depot
  OP->>OPS: ops load send drone-1 pier 3000 deliver A and B
  OPS->>U: ferry pier
  U-->>DEP: docks · its chunk loader wakes the depot
  DEP->>OPS: depot.hello, every 10 s
  OPS->>DEP: load.start · unit latched there, depot awake
  Note over DEP: place · fill · count · assemble · lift
  DEP->>OPS: load.lifted · silos up
  OPS->>U: unit.stick
  U->>OPS: unit.stuck
  OPS->>DEP: load.stuck
  Note over DEP: lower the lifter
  DEP->>OPS: load.done · what each silo holds
  Note over OPS: cargo.csv · loaded rows
  OPS->>U: deliver A and B
  Note over U: silo 1 dropped at A · silo 2 at B · dock home
  U->>OPS: unit.dropped, one per silo
  Note over OPS: cargo.csv · delivered rows
```

## The delivery flight

What fly deliver does once it lifts off. One silo per drop, the first sticker by name at the first drop.

```mermaid
flowchart LR
  A["check payload<br/>a sticker out per drop"] --> B["undock<br/>cruise to A"]
  B --> C["hover at drop height"]
  C --> D["retract sticker<br/>record the drop"]
  D --> E{"another drop?"}
  E -- "yes" --> F["cruise to B"]
  F --> C
  E -- "no" --> G["dock home"]
  A -. "no payload · refused on the ground" .-> X["stays docked"]
```

## A load, as the board sees it

One load per depot at a time. Nothing waits: the board looks every second and each message moves it on.

```mermaid
stateDiagram-v2
  [*] --> queued: ops load send
  queued --> sent: unit free · ferry to the dock
  sent --> loading: unit latched there · depot awake
  sent --> failed: 15 min without both
  loading --> done: load.done · liftoff sent
  loading --> failed: depot calls it off · goes quiet · restarted
  done --> [*]
  failed --> [*]
```

## A depot

Asleep until its chunk loads. A restart part way through a load lowers the lift and the board calls it off.

```mermaid
stateDiagram-v2
  [*] --> asleep
  asleep --> awake: chunk loads · unit or player arrives
  awake --> loading: load.start
  state loading {
    [*] --> place
    place --> fill
    fill --> assemble: counted · not empty
    assemble --> dock
    dock --> lift
    lift --> stick: base says stuck
    stick --> retract
    retract --> [*]
  }
  loading --> awake: load.done · or called off, lift lowered
  awake --> asleep: chunk unloads
```

## A unit

beacon runs while the unit is not flying and starts every flight; fly is never started on boot.

```mermaid
stateDiagram-v2
  [*] --> standby: beacon · docked or idle telemetry
  standby --> flying: ops.fly · job.assign · F
  flying --> standby: flight done · drops reported
  flying --> holding: pickup obstructed · climb 12 and hold
  holding --> flying: new spot · or 2 min, home
  flying --> sos: flight failed
  sos --> flying: next order from the base
  standby --> standby: unit.stick · docked only
```

## The links

| Link | Between | How |
|---|---|---|
| Orders | base to unit or depot | sealed with that computer's key; only the base holds them |
| Telemetry and reports | unit or depot to base | sealed; the counter only rises, so a copy is refused |
| Hails | pass to base | sealed with the pass's own key; a pass can only ask |
| Quotes and job states | base to pass | plain radio; they tell, they never command |
| Wake | unit to depot | no message: the unit's chunk loader loads the depot's chunk |

## The records

| File | On | Written by | What |
|---|---|---|---|
| `ledger.csv` | base | ops | every credit and fare; a balance is the sum |
| `joblog.csv` | base | ops | every finished ride: who, where, blocks, wait, ride time |
| `cargo.csv` | base | ops load · the board | what went into each silo, and where each was dropped |
| `incidents.csv` | base | ops | every unit that went down or silent, with its position |
| `loads.queue` | base | ops load send | loads waiting for the board to pick them up |
| `.fleetkeys · .custkeys` | base | seckey · provision | keys for every unit, depot and pass |
| `pads.lua` | base · units | ops place · fly pad | docks and pads, by name |
| `station.lua` | each depot | by hand | the loading station: relay faces, silos, stickers, waits |
| `.depotstate` | each depot | depot | the step of a load under way, for after a restart |
| `.drops · .drops.log` | each unit | fly · beacon | silos let go of; reported to the base, a copy kept |
| `.dronekey` | units · depots | seckey | this computer's own key |
