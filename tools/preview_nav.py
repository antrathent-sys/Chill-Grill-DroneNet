#!/usr/bin/env python3
"""Render CINDER NAV's screens as the monitors would show them.

    python tools/preview_nav.py [out.png] [--tower out.png]

The unit (lib/navui.lua): every page on a one-block screen (15x10 at text
scale 0.5) - speed, height, heading, radar, status - then the overview on a
2x1 strip and a 2x2 panel, and the states that matter (an advisory, no tower,
distress, unregistered), each kind's gauge, and the boot screen startup draws.
With --kiosk, the registration kiosk's screens (lib/kioskui.lua). With --tower, the tower's own screens
(lib/towerui.lua): the radar on a 3x3 monitor (57x38) and the board. Drawn
with lib/tui.lua's palette through tools/ccfont.py, the renderer checked
against in-game screenshots. Needs lupa and Pillow.
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import ccfont

try:
    from lupa.lua51 import LuaRuntime
    from PIL import Image
except ImportError:
    print("needs lupa and Pillow:  pip install lupa pillow", file=sys.stderr)
    sys.exit(2)

RENDER = rb"""
function(root, which)
  local D = dofile(root .. "/lib/display.lua")
  local T = dofile(root .. "/lib/tui.lua")
  local N = dofile(root .. "/lib/nav.lua")
  local UI = dofile(root .. "/lib/navui.lua")
  local TU = dofile(root .. "/lib/towerui.lua")
  local frames = {}
  local function add(w, h, label, draw) frames[#frames + 1] = { w, h, label, draw } end
  if which == "unit" then
    local hawk = { call = "HAWK", reg = "CR-0002", kind = "air", brg = 20, dist = 310, dy = 3, warn = true }
    local barge = { call = "BARGE", reg = "CR-0007", kind = "sea", brg = 200, dist = 700, dy = -84, warn = false }
    local tug = { call = "SEA WOLF", reg = "CR-0011", kind = "sea", brg = 95, dist = 450, dy = -84, warn = false }
    local function v(kind, call, pos, vel, extra)
      local r = N.reading(pos, vel)
      local view = { me = { reg = "CR-0001", call = call, kind = kind }, r = r, link = "contact", craft = true,
                     traffic = { barge, tug },
                     centres = N.centresFrom(r, { { name = "CHI", x = pos.x + 600, y = 70, z = pos.z + 300 },
                                                  { name = "NORTH", x = pos.x, y = 80, z = pos.z - 4000 } }) }
      for k, x in pairs(extra or {}) do view[k] = x end
      return view
    end
    local air = function(extra) return v("air", "FALCON", { x = 812, y = 214, z = -3300 }, { x = 52, y = 2.4, z = -61 }, extra) end
    local function page(w, h, view, p, label)
      add(w, h, label, function(c) UI.render(T, c, view, p) end)
    end
    page(15, 10, air(), "speed", "1x1 speed")
    page(15, 10, air(), "heading", "1x1 heading")
    page(15, 10, air(), "radar", "1x1 radar")
    page(15, 10, air(), "status", "1x1 status")
    page(15, 10, air(), "altimeter", "1x1 altimeter")
    page(36, 24, air(), "altimeter", "2x2 altimeter")
    local car = v("land", "ROVER", { x = 40, y = 70, z = -900 }, { x = 21, y = 0, z = -14 })
    page(15, 10, car, "speedo", "1x1 speedometer")
    page(36, 24, car, "speedo", "2x2 speedometer")
    local boat = v("sea", "SEA WOLF", { x = 40, y = 63, z = -900 }, { x = 6, y = 0, z = 6 })
    page(15, 10, boat, "compass", "1x1 compass")
    page(36, 24, boat, "compass", "2x2 compass")
    local deep = v("sub", "DEEP ONE", { x = 40, y = 22, z = -900 }, { x = 4, y = -0.8, z = 3 })
    page(15, 10, deep, "depth", "1x1 depth gauge")
    page(15, 10, air({ adv = "TRAFFIC 12 O'CLOCK 310 SAME LEVEL", traffic = { hawk, barge } }), "speed", "1x1 advisory")
    page(15, 10, air({ adv = "TRAFFIC 12 O'CLOCK 310 SAME LEVEL", traffic = { hawk, barge } }), "radar", "1x1 radar, advisory")
    page(15, 10, air({ sos = "armed" }), "speed", "1x1 SOS armed")
    page(15, 10, air({ link = "none", traffic = {} }), "radar", "1x1 no tower")
    page(36, 10, air({ adv = "TRAFFIC 12 O'CLOCK 310 SAME LEVEL", traffic = { hawk, barge } }), "overview", "2x1 overview")
    page(36, 10, air(), "radar", "2x1 radar")
    page(36, 24, air({ traffic = { hawk, barge, tug } }), "overview", "2x2 overview")
    page(36, 24, air({ traffic = { hawk, barge, tug } }), "radar", "2x2 radar")
    page(15, 10, air({ noRadio = true, craft = false, noTouch = true }), "speed", "1x1 set up: all missing")
    page(36, 10, air({ craft = false }), "speed", "2x1 set up: not on a vehicle")
    page(36, 24, air({ noRadio = true }), "speed", "2x2 set up: no ender modem")
    add(15, 10, "1x1 never touched", function(c) UI.render(T, c, air(), "altimeter", { hint = true }) end)
    add(51, 19, "boot, on the computer itself", function(c) UI.boot(T, c, { frac = 0.6, ver = "f6affcc" }) end)
  elseif which == "kiosk" then
    local K = dofile(root .. "/lib/kioskui.lua")
    local function k(label, view, w, h) add(w or 57, h or 24, label, function(c) K.render(T, c, view) end) end
    k("attract", { state = "attract" })
    k("seated: register, or host a centre", { state = "hello", who = "alex_r", stock = 4 })
    k("seated, out of stock, something in the drive", { state = "hello", who = "alex_r", stock = 0, drive = "other" })
    k("their unit in the drive", { state = "mine", who = "alex_r", unit = { reg = "CR-0007", call = "FALCON ONE", kind = "air" } })
    k("vehicle type", { state = "type", who = "alex_r", kind = "air" })
    k("callsign taken", { state = "callsign", who = "alex_r", call = "FALCON ONE", note = "TAKEN BY CR-0007" })
    k("confirm", { state = "confirm", who = "alex_r", kind = "air", call = "KITE", reg = "CR-0012" })
    k("done, with the kit", { state = "done", reg = "CR-0012", call = "KITE", kit = true })
    k("centre: its name", { state = "appname", who = "alex_r", text = "NORTH" })
    k("centre: where", { state = "appwhere", who = "alex_r", text = "1200 -400" })
    k("centre: confirm", { state = "appconfirm", who = "alex_r", appName = "NORTH", x = 1200, z = -400 })
    k("centre: sent", { state = "appdone", who = "alex_r", appName = "NORTH" })
    k("callsign on a 4x3", { state = "callsign", who = "alex_r", call = "FALCON" }, 79, 38)
  else
    local contacts = {
      { n = 1, reg = "CR-0001", call = "FALCON", kind = "air", x = 2497 + 640, y = 214, z = -3297 + 300, spd = 80, hdg = 70, st = "move", t = 99 },
      { n = 2, reg = "CR-0002", call = "HAWK", kind = "air", x = 2497 - 900, y = 150, z = -3297 + 500, spd = 0, st = "sos", t = 98 },
      { n = 7, reg = "CR-0007", call = "BARGE", kind = "sea", x = 2497 + 200, y = 63, z = -3297 - 1200, spd = 9, hdg = 200, st = "move", t = 97 },
      { n = 9, reg = "CR-0009", call = "ROVER", kind = "land", x = 2497 - 300, y = 71, z = -3297 - 400, spd = 14, hdg = 300, st = "move", t = 99 },
      { n = 11, reg = "CR-0011", call = "SEA WOLF", kind = "sea", x = 2497 + 1500, y = 63, z = -3297 + 900, spd = 0, st = "park", t = 99 },
      { n = 4, reg = "CR-0004", call = "PACKED", kind = "land", x = 2500, y = 70, z = -3290, spd = 0, st = "park", t = -400 } }
    local view = { name = "CHI", x = 2497, z = -3297, range = 2000, now = 100, regs = 14, contacts = contacts,
                   centres = { { name = "CHI", x = 2497, z = -3297 }, { name = "NORTH", x = 2497 + 300, z = -3297 - 1600 } },
                   lastEvent = "CR-0002 HAWK SOS" }
    add(57, 38, "tower radar, 3x3", function(c) TU.radar(T, c, view) end)
    add(51, 19, "tower board, its own screen", function(c) TU.board(T, c, view) end)
  end
  local out, labels = {}, {}
  for i, f in ipairs(frames) do
    local c = D.canvas(f[1], f[2])
    f[4](c)
    local rows = {}
    for y = 1, f[2] do
      local a, fg, b = c:row(y)
      rows[y] = a .. "\0" .. fg .. "\0" .. b
    end
    out[i] = table.concat(rows, "\n")
    labels[i] = f[3]
  end
  local pal = {}
  for k, x in pairs(T.PALETTE) do pal[#pal + 1] = k .. "=" .. string.format("%06x", x) end
  return table.concat(out, "\1"), table.concat(labels, "\1"), table.concat(pal, ",")
end
"""


def sheet(L, which, out, cols):
    blob, labels, pal = L.eval(RENDER)(ROOT.replace("\\", "/").encode(), which.encode())
    palette = {"0": 0xF0F0F0, "f": 0x111111}
    for pair in pal.decode().split(","):
        k, v = pair.split("=")
        palette[k] = int(v, 16)
    imgs = [ccfont.draw(rows, palette, px=2, label=lab.decode())
            for rows, lab in zip(blob.split(b"\1"), labels.split(b"\1"))]
    pad = 12
    rows = [imgs[i:i + cols] for i in range(0, len(imgs), cols)]
    width = max(sum(i.width for i in r) + pad * (len(r) + 1) for r in rows)
    height = sum(max(i.height for i in r) + pad for r in rows) + pad
    img = Image.new("RGB", (width, height), (0, 0, 0))
    y = pad
    for r in rows:
        x = pad
        for im in r:
            img.paste(im, (x, y))
            x += im.width + pad
        y += max(i.height for i in r) + pad
    img.save(out)
    print("wrote " + out)


def main():
    args = sys.argv[1:]
    tower = None
    if "--kiosk" in args:
        i = args.index("--kiosk")
        out = args[i + 1] if i + 1 < len(args) else os.path.join(HERE, "nav_kiosk.png")
        sheet(LuaRuntime(unpack_returned_tuples=True, encoding=None), "kiosk", out, 2)
        return
    if "--tower" in args:
        i = args.index("--tower")
        tower = args[i + 1] if i + 1 < len(args) else os.path.join(HERE, "nav_tower.png")
        del args[i:i + 2]
    out = args[0] if args else os.path.join(HERE, "nav.png")
    L = LuaRuntime(unpack_returned_tuples=True, encoding=None)
    sheet(L, "unit", out, 5)
    if tower:
        sheet(L, "tower", tower, 2)


if __name__ == "__main__":
    main()
