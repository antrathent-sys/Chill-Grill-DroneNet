# CINDER NAV and the traffic service

Alex, 2026-10-01: every vehicle on the server - aircraft, land vehicles,
boats and submarines - can carry a CINDER unit: an advanced computer, one
screen and an ender modem, **supplied by CINDER** and registered with it.
CINDER hosts the service and answers every unit's ping. Registration is
**heavily encouraged**, not required, and it is what makes traffic control
possible. It is a consumer product: CINDER's look and voice, a screen anyone
can read at a glance.

**Built 2026-10-01, not yet run in game:** `nav.lua` (the unit),
`tower.lua` (the tower), `lib/nav.lua` (shared), `lib/navui.lua` (the
unit's screen). Tested end to end on the desktop: `tools/run_nav_test.py`,
`tools/run_navnet_test.py`; `tools/preview_nav.py` renders the screen.
Steps 1 to 3 of the traffic control below are in, 6 and 7 in part.

## Setting it up

**The tower** - a computer of its own at CHI with an ender modem, a disk
drive and a monitor:

```
wget run https://raw.githubusercontent.com/antrathent-sys/Chill-Grill-DroneNet/main/startup.lua role tower
label set tower
```

It autoruns `tower` from the next boot. `tower register` in a second tab
registers a unit; `tower list`, `tower show CR-0001`, `tower revoke CR-0001`,
`tower log`.

**A unit** - an advanced computer: put it in the tower's disk drive and run
`tower register`. It asks the owner's player name, the vehicle type (air,
land, sea, sub) and a callsign, then writes the unit's software, its key and
its registration, labels it and ejects it. On the vehicle it needs an
advanced monitor (any size; one block works, a 2x1 strip is the intended
one) and an ender modem beside it. It starts by itself. To update one, put
it back in the drive and run `tower register` again: it keeps its key.

## The pieces

```mermaid
flowchart LR
  subgraph craft [a registered craft]
    U[avionics unit<br/>advanced computer]
    M[screen]
    E[ender modem]
    U --- M
    U --- E
  end
  subgraph base [CHI]
    T[tower<br/>registry + ATC]
    O[ops<br/>the fleet]
    W[flight wall,<br/>admin pocket]
  end
  E -- "ping: where I am (sealed)" --> T
  T -- "pong: traffic, advisories (sealed)" --> E
  O -- read-only feed --> T
  T -- contacts --> W
```

| piece | what it is | holds |
|---|---|---|
| **Avionics unit** | an advanced computer on the craft, with a screen and an ender modem, running `avionics` | its own key, its registration, the program |
| **Tower** | a computer of its own at CHI running `tower`: the registry, the air picture, ATC | every unit's key; **never** a fleet key |
| **Ops** | unchanged | the fleet's keys; gives the tower our units through the read-only feed it already has |

The tower is its own computer for two reasons. It is the public face, so it
must hold nothing that can fly a CINDER unit: if it is compromised, the
fleet is not. And a busy sky should never slow the base that dispatches the
fleet.

## Ping and pong

Every couple of seconds the unit sends one sealed report - its **ping**:

- exact position, height, heading, speed and climb, from Sable
  (`sublevel.getLogicalPose`, `getLinearVelocity`), or GPS off a craft;
- the craft's Sable name and unique id;
- its state: flying, parked, distress.

The tower answers with a sealed **pong**, for that unit only:

- traffic near it: callsign, bearing, distance, height difference, closing
  or not;
- any advisory: traffic to avoid, a zone being entered, a message from
  CINDER;
- whether the tower is hearing it at all, so the screen can say so.

Both directions are sealed with the unit's own key (`lib/seclink.lua`), so
nobody can pose as a registered craft, and nobody can send a pilot a false
warning in CINDER's name.

**The one rule that does not bend:** a pong is information. The avionics
program has no code that touches a thruster, a redstone output or anything
else on the craft, and the owner can read every line of it. Nothing CINDER
sends can ever fly somebody else's craft.

## What the owner sees

The unit is a CINDER product and looks like one (`lib/tui.lua`, the brand
book): cold, capitals, no shell for a casual owner.

- **Instruments:** heading, ground speed, height above sea, climb.
- **Traffic:** a radar circle with contacts by bearing and range, and a
  short list - callsign, distance, height difference, closing.
- **Advisories:** one line, the voice of the brand: `TRAFFIC 2 O'CLOCK 300
  SAME LEVEL`, `ENTERING CHI CONTROL ZONE`.
- **Distress:** one key. The tower raises it on every CINDER screen and a
  unit can be sent to the position (the recovery transit in BRAND.md).
- **Link:** `TOWER CONTACT` or `NO CONTACT`, and the registration.

## Registration, and what CINDER collects

Done at the tower, the way passes are made: the unit's computer goes in the
disk drive and comes out with the program, a key of its own and its
registration written to it.

**At registration**, typed by whoever registers it:

| field | |
|---|---|
| registration | `CR-0001` for now - **a placeholder**: the format is still to be agreed with people. Records keep only the sequence number, so changing `N.REG_FORMAT` in `lib/nav.lua` renames every unit at once |
| unit id | `nav-0001`: its label and the name its key is filed under, fixed for life whatever the registration looks like |
| owner | the player's name as given (a computer cannot check who a player is - the registrar can) |
| type | aircraft, land vehicle, vessel or submarine |
| callsign | what traffic calls it, chosen by the owner |
| issued, by | the date, and the tower that issued it |

**From the unit, automatically**, every ping:

| field | |
|---|---|
| position, height, speed, heading, climb | the live picture; the registry keeps the last of each |
| state | moving, standing, distress |
| vehicle | Sable's unique id, its name and its mass. The unit is **bound** to the first vehicle it is heard from, and moving it to another is noticed and logged |
| first and last heard | dates |

**In the log** (`navlog.csv` on the tower, one line per event, rolled at
256 KB): registered, first contact, bound to a vehicle, departed, arrived,
distress and distress over, changed vehicle, updated, revoked - each with
the time, the registration, the callsign and the position. Never one line
per ping. The long record belongs outside the game (SERVICE.md).

The unit's own screen says it reports its position to CINDER. Cold, not
covert.

Revoking a unit (`tower revoke`) deletes its key: a running tower stops
answering it within ten seconds.

## Traffic control, in the order it is built

1. **The picture.** Every registered vehicle on the tower's own screen,
   with last-seen for anything parked or out of range - **built**. CINDER's
   own units, and the picture on the flight wall and the admin pocket - not
   yet.
2. **Traffic on every screen.** Each pong carries what is within 1,000
   blocks of that vehicle - **built**.
3. **Advisories.** Pairs that would pass within 40 blocks inside 30 seconds,
   at about the same height, get a warning each - **built**
   (`TRAFFIC 2 O'CLOCK 300 SAME LEVEL`), and anyone in distress nearby is
   called out.
4. **Flight levels by heading.** Eastbound odd hundreds, westbound even: the
   screen shows the right level for the current heading. Free separation
   for everybody.
5. **Control zones.** A radius round CHI and each depot: registered craft
   are told on entry, and CINDER units have priority there.
6. **Distress to recovery.** The distress key raises it on the tower,
   which acknowledges it on the unit's screen and logs it - **built**.
   Sending a CINDER unit to it - not yet.
7. **Records.** Departures, arrivals, distress and vehicle changes per
   registration, written sparsely - **built** (`navlog.csv`). Where from
   and where to as named places, and the long record outside the game -
   not yet.

## Limits to design round

- **Unregistered craft are invisible.** There is no radar in Sable or
  Aeronautics (checked in their source): the tower sees exactly the craft
  that report. That is why registration matters, and why a control zone
  can only advise.
- **A unit only runs while its chunk is loaded.** A parked craft with
  nobody near goes quiet; the tower shows it last seen, not lost.
- **Positions are self-reported.** The owner controls the computer. The key
  proves which unit is speaking, not that it is telling the truth; the
  tower flags jumps that no craft could fly.
- **Load.** Dozens of units at one ping every two seconds is light work for
  the tower. Pings go on a channel of their own, not the fleet's telemetry
  channel, so a busy sky never crowds the fleet.
- **Disk.** The registry is small; tracks are written only on change, and
  rotated. The tower's computer has 1 MB like every other.

## Decided, 2026-10-01

1. **CINDER supplies the kits.**
2. **Registration is heavily encouraged**, not required.
3. **The registration format** is still to be agreed with people;
   `CR-0001` stands in, and changes in one line.
4. **The tower is its own computer at CHI** (the `tower` role).
5. **Building started now**, as a consumer product under the CINDER brand,
   for every kind of vehicle, not only aircraft.

Still open: CINDER's own units on the tower's picture (through the base's
read-only feed), the tower's picture on the flight wall and the admin
pocket, and steps 3 to 7 of the traffic control.
