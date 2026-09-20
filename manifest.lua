-- manifest: which files each kind of computer pulls from this repo.
--
-- Give a computer its role once:   startup role <name>
-- From then on every boot (or `startup`) pulls `common` plus that role's list
-- from the newest commit, and removes files startup itself installed that the
-- list no longer has. Files startup never installed - keys, pads.lua,
-- .autorun, flight logs, your own programs - are never touched. A computer
-- with no role pulls every file, exactly as before roles existed.
--
-- Adding a program: put it in the right list here, and every computer with
-- that role picks it up on its next startup. tools/run_startup_test.py checks
-- that every file named here exists, that the lists together cover startup's
-- fallback list, and that each role carries everything its programs dofile or
-- shell.run.
return {
  -- every computer: the updater, uploads, keys and the sealed link
  common = {
    "startup.lua", "upload.lua", "paste.lua", "seckey.lua", "radiotest.lua",
    "lib/seclink.lua", "lib/link.lua", "lib/pads.lua", "lib/fleet.lua",
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
    "lib/mission.lua", "lib/db.lua",
  },

  -- the redstone slave computer on an airframe (startup autorun rsio)
  rs = { "rsio.lua" },

  -- the base server: the control room screens, and the older single wall
  base = {
    "control.lua", "console.lua",
    "lib/display.lua", "lib/state.lua", "lib/screens.lua",
    "lib/db.lua", "stickers.lua",
    "lib/devices.lua", "basectl.lua", "devices.example.lua",
    "ops.lua",
  },

  -- a customer terminal standing at a pad: it calls a taxi and counts its own use
  pad = { "taxipad.lua" },

  -- the portable terminal (an advanced wireless pocket computer)
  -- the portable terminal: hail, plus the canvas it draws its map with
  pocket = { "hail.lua", "lib/display.lua", "lib/hailui.lua", "lib/tui.lua" },
}
