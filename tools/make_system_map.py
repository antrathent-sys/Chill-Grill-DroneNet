import html, io, os

"""Write SYSTEM.md, the repo's system map, and - with a path argument - the same
diagrams as a standalone HTML page:

    python tools/make_system_map.py [page.html]

Edit the diagrams here, never in SYSTEM.md: that file is generated."""
import subprocess, sys
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCR = os.path.dirname(os.path.abspath(sys.argv[1])) if len(sys.argv) > 1 else None
PAGE = os.path.basename(sys.argv[1]) if len(sys.argv) > 1 else "system-map.html"
REV = subprocess.check_output(["git", "-C", REPO, "rev-parse", "--short", "HEAD"]).decode().strip()

MAP = r'''flowchart LR
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
  FC --- ST'''

RIDE = r'''stateDiagram-v2
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
  failed --> [*]'''

DELIVERY = r'''sequenceDiagram
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
  Note over OPS: cargo.csv · delivered rows'''

LOAD = r'''stateDiagram-v2
  [*] --> queued: ops load send
  queued --> sent: unit free · ferry to the dock
  sent --> loading: unit latched there · depot awake
  sent --> failed: 15 min without both
  loading --> done: load.done · liftoff sent
  loading --> failed: depot calls it off · goes quiet · restarted
  done --> [*]
  failed --> [*]'''

DEPOT = r'''stateDiagram-v2
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
  awake --> asleep: chunk unloads'''

UNITSTATE = r'''stateDiagram-v2
  [*] --> standby: beacon · docked or idle telemetry
  standby --> flying: ops.fly · job.assign · F
  flying --> standby: flight done · drops reported
  flying --> holding: pickup obstructed · climb 12 and hold
  holding --> flying: new spot · or 2 min, home
  flying --> sos: flight failed
  sos --> flying: next order from the base
  standby --> standby: unit.stick · docked only'''

DELIVERLEGS = r'''flowchart LR
  A["check payload<br/>a sticker out per drop"] --> B["undock<br/>cruise to A"]
  B --> C["hover at drop height"]
  C --> D["retract sticker<br/>record the drop"]
  D --> E{"another drop?"}
  E -- "yes" --> F["cruise to B"]
  F --> C
  E -- "no" --> G["dock home"]
  A -. "no payload · refused on the ground" .-> X["stays docked"]'''

RECORDS = [
    ("ledger.csv", "base", "ops", "every credit and fare; a balance is the sum"),
    ("joblog.csv", "base", "ops", "every finished ride: who, where, blocks, wait, ride time"),
    ("cargo.csv", "base", "ops load · the board", "what went into each silo, and where each was dropped"),
    ("incidents.csv", "base", "ops", "every unit that went down or silent, with its position"),
    ("loads.queue", "base", "ops load send", "loads waiting for the board to pick them up"),
    (".fleetkeys · .custkeys", "base", "seckey · provision", "keys for every unit, depot and pass"),
    ("pads.lua", "base · units", "ops place · fly pad", "docks and pads, by name"),
    ("station.lua", "each depot", "by hand", "the loading station: relay faces, silos, stickers, waits"),
    (".depotstate", "each depot", "depot", "the step of a load under way, for after a restart"),
    (".drops · .drops.log", "each unit", "fly · beacon", "silos let go of; reported to the base, a copy kept"),
    (".dronekey", "units · depots", "seckey", "this computer's own key"),
]

LINKS = [
    ("Orders", "base to unit or depot", "sealed with that computer's key; only the base holds them"),
    ("Telemetry and reports", "unit or depot to base", "sealed; the counter only rises, so a copy is refused"),
    ("Hails", "pass to base", "sealed with the pass's own key; a pass can only ask"),
    ("Quotes and job states", "base to pass", "plain radio; they tell, they never command"),
    ("Wake", "unit to depot", "no message: the unit's chunk loader loads the depot's chunk"),
]

SECTIONS = [
    ("map", "Who talks to whom", "Map",
     "One authority. The ops computer holds every order key and decides everything; the screens only listen, "
     "depots only work their machines, passes only ask.", MAP),
    ("rides", "A ride", "Rides",
     "The job a pass follows from hail to home. Holding is the queue when every unit is busy.", RIDE),
    ("deliveries", "A delivery from a depot", "Deliveries",
     "Queued at the base; the unit's arrival wakes the depot; the base passes every message between depot and unit.",
     DELIVERY),
    ("legs", "The delivery flight", "Flight",
     "What fly deliver does once it lifts off. One silo per drop, the first sticker by name at the first drop.",
     DELIVERLEGS),
    ("load-states", "A load, as the board sees it", "States",
     "One load per depot at a time. Nothing waits: the board looks every second and each message moves it on.", LOAD),
    ("depot-states", "A depot", None,
     "Asleep until its chunk loads. A restart part way through a load lowers the lift and the board calls it off.",
     DEPOT),
    ("unit-states", "A unit", None,
     "beacon runs while the unit is not flying and starts every flight; fly is never started on boot.", UNITSTATE),
]

# ------------------------------------------------------------------ markdown
md = ["# System map", "",
      "How the pieces of the service fit together: the computers, what each sends to whom, and the states a ride, a "
      "load, a depot and a unit go through. The diagrams are Mermaid, so GitHub draws them.", "",
      "Generated at %s by `python tools/make_system_map.py`: edit the diagrams there, not here." % REV, ""]
for sid, title, _, text, src in SECTIONS:
    md += ["## " + title, "", text, "", "```mermaid", src, "```", ""]
md += ["## The links", "", "| Link | Between | How |", "|---|---|---|"]
md += ["| %s | %s | %s |" % l for l in LINKS]
md += ["", "## The records", "", "| File | On | Written by | What |", "|---|---|---|---|"]
md += ["| `%s` | %s | %s | %s |" % r for r in RECORDS]
io.open(os.path.join(REPO, "SYSTEM.md"), "w", encoding="utf-8", newline="\n").write("\n".join(md) + "\n")

# ---------------------------------------------------------------------- html
def esc(s): return html.escape(s, quote=False)

nav = "".join('<a href="#%s">%s</a>' % (sid, nav) for sid, _, nav, _, _ in SECTIONS if nav)
nav += '<a href="#links">Links</a><a href="#records">Records</a>'
body = []
for sid, title, _, text, src in SECTIONS:
    body.append('''<section id="%s">
  <h2>%s</h2>
  <p class="lede">%s</p>
  <figure class="diagram"><pre class="mermaid">%s</pre></figure>
</section>''' % (sid, esc(title), esc(text), esc(src)))
links = "".join("<tr><th>%s</th><td>%s</td><td>%s</td></tr>" % tuple(esc(x) for x in l) for l in LINKS)
recs = "".join("<tr><th><code>%s</code></th><td>%s</td><td>%s</td><td>%s</td></tr>" % tuple(esc(x) for x in r)
               for r in RECORDS)

page = '''<title>CINDER System Map</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Chakra+Petch:wght@500;600&family=IBM+Plex+Sans:wght@400;500;600&family=IBM+Plex+Mono:wght@400;500&display=swap">
<style>
:root {
  --ground: #eceef0;
  --surface: #f8f9fa;
  --ink: #1c1e21;
  --muted: #5d646c;
  --rule: #c7ccd1;
  --panel: #25282d;
  --panel-ink: #e8eaed;
  --red: #b3261e;
  --amber: #a8701a;
  --display: "Chakra Petch", "Bahnschrift", "Arial Narrow", sans-serif;
  --body: "IBM Plex Sans", "Segoe UI", system-ui, sans-serif;
  --mono: "IBM Plex Mono", "Consolas", ui-monospace, monospace;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --ground: #131518; --surface: #1b1e22; --ink: #e4e7ea; --muted: #99a0a8;
    --rule: #32373d; --panel: #0d0f11; --panel-ink: #e4e7ea; --red: #e5484d; --amber: #e0a33a;
  }
}
:root[data-theme="dark"] {
  --ground: #131518; --surface: #1b1e22; --ink: #e4e7ea; --muted: #99a0a8;
  --rule: #32373d; --panel: #0d0f11; --panel-ink: #e4e7ea; --red: #e5484d; --amber: #e0a33a;
}
body { background: var(--ground); color: var(--ink); font: 15px/1.6 var(--body); }
.wrap { max-width: 1080px; margin: 0 auto; padding-inline: 20px; padding-block: 0 64px; }
header.mast { background: var(--panel); color: var(--panel-ink); padding-block: 28px 20px; margin-bottom: 8px; }
header.mast .wrap { padding-block: 0; }
.brand { font: 600 clamp(28px, 5vw, 40px)/1 var(--display); letter-spacing: 0.32em; margin: 0; }
.rule2 { height: 5px; border-top: 1px solid currentColor; border-bottom: 1px solid currentColor; opacity: 0.5; margin: 12px 0; }
.sub { display: flex; flex-wrap: wrap; justify-content: space-between; gap: 8px 24px;
  font: 500 12px/1.4 var(--display); letter-spacing: 0.22em; text-transform: uppercase; }
.sub .rev { opacity: 0.55; font-family: var(--mono); letter-spacing: 0.08em; }
nav.jump { position: sticky; top: env(safe-area-inset-top, 0px); z-index: 2; background: var(--ground);
  border-bottom: 1px solid var(--rule); }
nav.jump .wrap { display: flex; flex-wrap: wrap; gap: 4px 20px; padding-block: 10px; }
nav.jump a { color: var(--muted); text-decoration: none; font: 500 12px/1.6 var(--display);
  letter-spacing: 0.18em; text-transform: uppercase; }
nav.jump a:hover, nav.jump a:focus-visible { color: var(--ink); }
a:focus-visible { outline: 2px solid var(--amber); outline-offset: 3px; }
.intro { max-width: 68ch; color: var(--muted); margin: 28px 0 8px; }
.intro strong { color: var(--ink); font-weight: 600; }
section { margin-top: 44px; }
h2 { font: 600 18px/1.3 var(--display); letter-spacing: 0.14em; text-transform: uppercase; margin: 0 0 6px;
  text-wrap: balance; display: flex; align-items: center; gap: 12px; }
h2::before { content: ""; width: 10px; height: 10px; background: var(--red); flex: none; }
.lede { max-width: 68ch; margin: 0 0 14px; color: var(--muted); }
figure.diagram { margin: 0; background: var(--surface); border: 1px solid var(--rule); padding: 20px;
  overflow-x: auto; }
figure.diagram pre.mermaid { margin: 0; background: transparent; font-family: var(--mono); font-size: 12px;
  color: var(--muted); white-space: pre; }
.tablebox { overflow-x: auto; border: 1px solid var(--rule); background: var(--surface); }
table { border-collapse: collapse; width: 100%; font-size: 14px; }
th, td { text-align: left; vertical-align: top; padding: 10px 14px; border-bottom: 1px solid var(--rule); }
tr:last-child th, tr:last-child td { border-bottom: 0; }
thead th { font: 600 11px/1.4 var(--display); letter-spacing: 0.18em; text-transform: uppercase; color: var(--muted); }
tbody th { font-weight: 600; white-space: nowrap; }
code { font: 500 13px var(--mono); color: var(--amber); }
.key { display: flex; flex-wrap: wrap; gap: 6px 22px; margin: 10px 0 0; color: var(--muted); font-size: 13px; }
.key span::before { content: ""; display: inline-block; width: 22px; margin-right: 8px; vertical-align: middle;
  border-top: 2px solid var(--muted); }
.key span.dash::before { border-top-style: dashed; }
@media (prefers-reduced-motion: reduce) { html { scroll-behavior: auto; } }
html { scroll-behavior: smooth; }
</style>
<header class="mast"><div class="wrap">
  <p class="brand">CINDER</p>
  <div class="rule2"></div>
  <div class="sub"><span>Transit Directorate &middot; System map</span><span class="rev">REV %(rev)s</span></div>
</div></header>
<nav class="jump" aria-label="Sections"><div class="wrap">%(nav)s</div></nav>
<main class="wrap">
  <p class="intro"><strong>How the service fits together.</strong> The computers and what each sends to whom, then the
  states a ride, a load, a depot and a unit go through. The same diagrams live in the repo as <code>SYSTEM.md</code>.</p>
  <div class="key"><span>sealed message</span><span class="dash">listens, or wakes</span></div>
  %(body)s
  <section id="links">
    <h2>The links</h2>
    <p class="lede">Nothing flies on a message the base did not seal; everything else can only ask.</p>
    <div class="tablebox"><table>
      <thead><tr><th>Link</th><th>Between</th><th>How</th></tr></thead>
      <tbody>%(links)s</tbody>
    </table></div>
  </section>
  <section id="records">
    <h2>The records</h2>
    <p class="lede">Appended, never rewritten, like the ledger. Keys never leave the computers they are on.</p>
    <div class="tablebox"><table>
      <thead><tr><th>File</th><th>On</th><th>Written by</th><th>What</th></tr></thead>
      <tbody>%(recs)s</tbody>
    </table></div>
  </section>
</main>
'''
for k, v in (("%(rev)s", REV), ("%(nav)s", nav), ("%(body)s", "\n  ".join(body)), ("%(links)s", links),
             ("%(recs)s", recs)):
    page = page.replace(k, v)
if SCR:
    io.open(os.path.join(SCR, PAGE), "w", encoding="utf-8", newline="\n").write(page)
print("SYSTEM.md written at rev " + REV + (SCR and (", page " + PAGE) or ""))
