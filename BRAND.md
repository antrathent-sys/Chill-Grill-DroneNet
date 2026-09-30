# CINDER

The brand book. What is decided is marked **decided**, with the date and
commit; everything else is **proposed** and waits on Alex. Written
2026-10-01, pulling together decisions scattered through the code, the
backlog and the design critique of 2026-09-21.

## What CINDER is

The server's transit authority. It moves people and goods anywhere on the
map, on its own, around the clock, and writes down everything it does.

The joke and the promise are the same thing: an Imperial bureaucracy that
nobody likes but everybody uses, because it is the one thing on the server
that always turns up. Cold in voice, dependable in fact.

**Proposed line:** *Anywhere. On time.* Alternatives in the same voice:
*Compliance appreciated.* (already on the pass), *The network provides.*,
*Stand clear.*

## Name and structure — decided

| | | |
|---|---|---|
| Parent brand | **CINDER** | Alex, 2026-09-21, from an ISB-style shortlist |
| Branches | **Directorates** | TRANSIT DIRECTORATE on the pass today; LOGISTICS for freight, HEAVY INDUSTRY for depots and supply later |
| Passenger craft | **LAMBDA-001**, class and three digits | 2026-09-30, `lib/names.lua`, 4510d8a |
| Freight craft | **ZETA-001** | same scheme, one line in `N.CLASS_OF` per freighter |
| Places | a code per place: **CHI** the base, **CHID 1** and **CHID 2** its depots | 2026-09-29 |
| Orders | **C-0042** an order, **C-0042.1** its first flight, **C-0042-2** its second shipment | 2026-09-30, ORDERS.md |

**Proposed:** every place customers use gets a three-letter code like CHI,
shown on screens, signs and receipts the way an airport code is. Depots add
D and a number. The code is the place's name everywhere a person reads it,
the way LAMBDA-001 is the craft's.

## Voice — decided

Terse Imperial officialese with a wink. Capitals on screens. One word per
concept, always the same word:

| say | never |
|---|---|
| unit | drone, taxi, ship |
| transit | ride, trip, flight (to a customer) |
| fare | price, cost |
| balance, credit | money, coins |
| pass | pocket, terminal, device |
| place | pad, dock, location (to a customer) |
| stand by | please wait, loading |

Lines in use: *SERVICE SUSPENDED / STAND BY*, *COMPLIANCE APPRECIATED*.
Refunds are not a thing (decided 2026-09-28: own risk, no refunds); the
voice never apologises, it states.

**Proposed** lines, for the places they would go:

| moment | line |
|---|---|
| unit assigned | UNIT LAMBDA-001 ASSIGNED |
| unit arriving | STAND CLEAR OF THE PLATFORM |
| boarding | BOARDING. KEEP HANDS INSIDE THE UNIT. |
| arrival | ARRIVED CHI. YOUR PATRONAGE IS NOTED. |
| delivery dropped | CONSIGNMENT C-0042-1 DELIVERED |
| nothing free | ALL UNITS COMMITTED. STAND BY. |
| refusal | REQUEST DENIED. |

## Colour — decided on screens

`lib/tui.lua`, 2026-09-21. Near black ground, light grey type, one dark red
for anything live, rust for attention, muted green for done. No yellow
(Alex, 2026-09-30).

| role | hex | on screens |
|---|---|---|
| ground | `#0b0c0e` | background |
| panel | `#25282d` | bands, bar tracks |
| rule | `#5b6169` | labels, rules |
| type | `#d8dbdf` | primary text |
| secondary | `#8d939b` | secondary text |
| live | `#8e2420` | selection, progress, anything happening now |
| attention | `#b8542c` | warnings: rust, never yellow |
| done | `#6f8f5f` | complete |

Open from the critique: red text on the ground is about 2.3:1, too faint
to read at a glance. **Proposed:** a brighter ember, around `#d2452e`, for
red *text* only, keeping `#8e2420` for fills.

## In the world — proposed

The same palette in blocks, so a CINDER place is recognisable from the air
before its sign is readable:

| role | blocks |
|---|---|
| ground | blackstone, polished blackstone, deepslate tiles |
| panel | smooth basalt, gray concrete |
| live | red nether bricks, crimson planks, red concrete for markings |
| attention | copper (let it weather to rust), orange terracotta |
| light | redstone lamps, shroomlights behind glass |

- **The mark.** An ember: a diamond standing on its point, notched at the top
  like a flame. It works at 5x5 blocks on a landing pad, 3x3 on a hull, in
  CC's teletext on the boot screen, and as a printed glyph on invoices.
- **Livery.** Blackstone hull, one red stripe, copper trim. Every unit
  carries an Aeronautics **name plate**, which a computer can set
  (`name_plate.setName`), so the beacon writes LAMBDA-001 on its own hull at
  every boot. No painting by hand, and a unit renumbered is renamed at once.
- **Places.** Every pad and dock gets the same kit: the mark on the deck, a
  red stand-clear line one block out, a lamp that is lit while a unit is
  inbound, and a sign with the place code. Depots add an A and a B on their
  sides, since the craft now always meets them facing the same way.
- **Sound.** The chimes (`lib/chime.lua`) become the audio mark: one short
  three-note phrase for "unit arriving", heard the same everywhere.
- **Paper.** Everything printed looks alike: the invoices already carry the
  order number; a boarding pass at walk-up stations and a receipt on
  arrival would follow the same layout.

## Making life on the server better

What CINDER does for people is the brand. Ideas, cheapest first, each built
on something that already exists:

| idea | what it does for a player | what it needs |
|---|---|---|
| **Name plates** | every unit is identifiable in the sky | a name plate per craft, a few lines in beacon |
| **Departure boards at hubs** | at spawn or a market, see which units are coming and going, and call one | the flight wall and `lib/watch.lua` exist; a board is a watcher at a public place |
| **Recovery transit** | died far from home: a unit takes you back to your death point before your items despawn | a transit to typed coordinates, which the pass already does; a priority and a name |
| **First transit free** | a new player's first ride costs nothing, so everyone tries it once | a flag on the pass |
| **Courier** | move your own goods between your bases without the trip | the delivery work in ROADMAP.md |
| **Supply** | order common goods from CINDER stock, delivered | sales, ROADMAP.md |
| **Public record** | a board of transits flown, blocks covered, goods moved | the journal, once rides are on it |
| **Network map** | every place customers can use, on a map wall and a page | the place list, published without customers' private places |

Two cautions. Anything public reads the journal, so it waits for the prune
in ROADMAP.md. And customer places must stay out of the public repo
(decided 2026-09-24): a published map shows public places only.
