-- manifest: which files each kind of computer pulls from this repo.
--
-- Give a computer its role once:   startup role <name>
-- From then on every boot (or `startup`) pulls `common` plus that role's list
-- from the newest commit, and removes files startup itself installed that the
-- list no longer has. Files startup never installed - keys, pads.lua,
-- .autorun, flight logs, your own programs - are never touched. A computer
-- with no role pulls NOTHING and says how to get one: the whole repo is over
-- 1 MB (2026-09-30), more than a standard computer holds. `startup role all`
-- is the old everything, for a computer with the room. A blank computer is
-- set up with one line:
--   wget run https://raw.githubusercontent.com/antrathent-sys/Chill-Grill-DroneNet/main/startup.lua role <name>
--
-- Adding a program: put it in the right list here, and every computer with
-- that role picks it up on its next startup. tools/run_startup_test.py checks
-- that every file named here exists, that the lists together cover startup's
-- fallback list, and that each role carries everything its programs dofile or
-- shell.run.
return {
  -- every computer: the updater, uploads, keys and the sealed link
  common = {
    "startup.lua", "upload.lua", "paste.lua", "seckey.lua", "radiotest.lua", "gpscheck.lua",
    "machine.lua", "lib/machine.lua",
    "lib/seclink.lua", "lib/link.lua", "lib/pads.lua", "lib/fleet.lua", "lib/names.lua",
    "ccryptolib/aead.lua", "ccryptolib/chacha20.lua", "ccryptolib/poly1305.lua",
    "ccryptolib/random.lua", "ccryptolib/blake3.lua", "ccryptolib/config.lua",
    "ccryptolib/internal/util.lua", "ccryptolib/internal/packing.lua",
    "ccryptolib/internal/hw.lua",
  },

  -- the flight computer on a drone
  drone = {
    "fly.lua", "kill.lua", "preflight.lua", "probe.lua", "mixcal.lua", "docktest.lua",
    "stickers.lua", "chimes.lua", "beacon.lua",
    "lib/attitude.lua", "lib/mixer.lua", "lib/chime.lua", "lib/rs.lua",
    "lib/mission.lua", "lib/db.lua", "lib/deliver.lua",
  },

  -- the redstone slave computer on an airframe (startup autorun rsio)
  rs = { "rsio.lua" },

  -- the base server: the control room screens, and the older single wall
  base = {
    "control.lua", "console.lua",
    "lib/display.lua", "lib/state.lua", "lib/screens.lua", "lib/watch.lua", "lib/trip.lua",
    "lib/db.lua", "stickers.lua",
    "lib/devices.lua", "basectl.lua", "devices.example.lua",
    "lib/loader.lua", "station.example.lua", "lib/cargo.lua", "lib/deliver.lua", "depot.lua", "lib/dockseq.lua", "lib/stock.lua", "lib/depotscreens.lua",
    "ops.lua", "lib/opsui.lua", "lib/tui.lua", "lib/display.lua",
    "lib/ledger.lua", "lib/queue.lua", "lib/invoice.lua", "lib/orders.lua", "lib/catalogue.lua", "tariff.example.lua",
    -- making customers' passes: provision copies these onto each one
    "provision.lua", "lib/provision.lua", "kiosk.lua", "hail.lua", "lib/hailui.lua",
  },

  -- the control room's monitors on a computer of their own, run from the base's
  -- read-only feed (seckey watch set disk, label it, startup autorun control)
  screens = { "control.lua", "lib/display.lua", "lib/state.lua", "lib/screens.lua", "lib/watch.lua" },

  -- the computer at a dock that works its loading station (startup autorun depot)
  depot = { "depot.lua", "lib/loader.lua", "lib/dockseq.lua", "lib/stock.lua", "lib/cargo.lua", "station.example.lua", "stickers.lua",
            "dock.example.lua",
            "lib/display.lua", "lib/depotscreens.lua", "lib/tui.lua", "lib/invoice.lua" },

  -- a customer terminal standing at a pad: it calls a taxi and counts its own use
  pad = { "taxipad.lua" },

  -- Alex's own portable terminal, for trying hail as a developer. Customers'
  -- passes are NOT made from this: `provision` on the base writes them, with
  -- kiosk.lua as their startup and no updater or token on them at all.
  pocket = { "hail.lua", "lib/display.lua", "lib/hailui.lua", "lib/tui.lua" },

  -- the MASTER CINDER traffic tower (AVIONICS.md), inside CINDER's claims:
  -- registers CINDER NAV units through its disk drive, so it carries
  -- everything a unit runs, and answers their pings (startup autorun tower).
  -- The one computer of the traffic service with common, so the one that can
  -- push. Never holds a fleet key.
  tower = { "tower.lua", "lib/nav.lua", "lib/navui.lua", "nav.lua", "lib/display.lua", "lib/tui.lua",
            "lib/towerui.lua" },

  -- BARE roles (startup.lua BARE): nothing from common - no uploads, no
  -- machine folder, no key tools - and startup never touches a thruster or a
  -- redstone output on them. They pull only this, and push nothing.

  -- a display-only traffic centre, anywhere (tower centre add on the master,
  -- startup autorun tower): the master's picture, answering no one
  centre = { "startup.lua", "tower.lua", "lib/nav.lua", "lib/towerui.lua", "lib/display.lua", "lib/tui.lua",
             "lib/seclink.lua",
          "ccryptolib/aead.lua", "ccryptolib/chacha20.lua", "ccryptolib/poly1305.lua",
          "ccryptolib/random.lua", "ccryptolib/blake3.lua", "ccryptolib/config.lua",
          "ccryptolib/internal/util.lua", "ccryptolib/internal/packing.lua", "ccryptolib/internal/hw.lua" },

  -- a registration kiosk (navdesk.lua, startup autorun navdesk), wherever
  -- players are: it asks the master to register units and writes them onto
  -- computers from its stock, so it carries everything a unit runs
  kiosk = { "startup.lua", "navdesk.lua", "lib/navkiosk.lua", "lib/kioskui.lua",
            "nav.lua", "lib/nav.lua", "lib/navui.lua", "lib/display.lua", "lib/tui.lua", "lib/seclink.lua",
            "ccryptolib/aead.lua", "ccryptolib/chacha20.lua", "ccryptolib/poly1305.lua",
            "ccryptolib/random.lua", "ccryptolib/blake3.lua", "ccryptolib/config.lua",
            "ccryptolib/internal/util.lua", "ccryptolib/internal/packing.lua", "ccryptolib/internal/hw.lua" },

  -- a CINDER NAV unit on somebody's vehicle (tower register writes it): pulls
  -- these quietly behind the CINDER NAV boot screen, then runs nav; no shell
  nav = { "startup.lua", "nav.lua", "lib/nav.lua", "lib/navui.lua", "lib/display.lua", "lib/tui.lua",
          "lib/seclink.lua",
          "ccryptolib/aead.lua", "ccryptolib/chacha20.lua", "ccryptolib/poly1305.lua",
          "ccryptolib/random.lua", "ccryptolib/blake3.lua", "ccryptolib/config.lua",
          "ccryptolib/internal/util.lua", "ccryptolib/internal/packing.lua", "ccryptolib/internal/hw.lua" },

  -- Alex's admin pocket: the fleet from the feed, trips of several legs, Go and
  -- Cancel, all asked of the base (seckey admin set disk, label it, run admin)
  admin = { "admin.lua", "lib/watch.lua", "lib/state.lua" },
}
