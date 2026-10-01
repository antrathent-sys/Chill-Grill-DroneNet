#!/usr/bin/env python3
"""Render a CINDER NAV unit's screen as the monitor would show it.

    python tools/preview_nav.py [out.png]

A sheet of the screen at the sizes a unit may be fitted with (text scale 0.5:
one block 15x10, a 2x1 strip 36x10, a 3x1 strip 57x10, a 2x2 panel 36x24),
for each kind of vehicle and the states that matter: in contact with traffic
and an advisory, no tower, distress armed, unregistered. Drawn with
lib/navui.lua and lib/tui.lua's own palette through tools/ccfont.py, the
renderer checked against in-game screenshots. Needs lupa and Pillow.
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import ccfont

try:
    from lupa.lua51 import LuaRuntime
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    print("needs lupa and Pillow:  pip install lupa pillow", file=sys.stderr)
    sys.exit(2)

RENDER = rb"""
function(root)
  local D = dofile(root .. "/lib/display.lua")
  local T = dofile(root .. "/lib/tui.lua")
  local N = dofile(root .. "/lib/nav.lua")
  local UI = dofile(root .. "/lib/navui.lua")
  local hawk = { call = "HAWK", reg = "CR-0002", kind = "air", brg = 20, dist = 310, dy = 3, warn = true }
  local barge = { call = "BARGE", reg = "CR-0007", kind = "sea", brg = 200, dist = 880, dy = -84, warn = false }
  local tug = { call = "SEA WOLF", reg = "CR-0011", kind = "sea", brg = 95, dist = 1400, dy = -84, warn = false }
  local function v(kind, call, pos, vel, extra)
    local view = { me = { reg = "CR-0001", call = call, kind = kind }, r = N.reading(pos, vel),
                   link = "contact", craft = true, traffic = { hawk, barge } }
    for k, x in pairs(extra or {}) do view[k] = x end
    return view
  end
  local air = function(extra) return v("air", "FALCON", { x = 812, y = 214, z = -3300 }, { x = 52, y = 2.4, z = -61 }, extra) end
  local frames = {
    { 36, 10, air({ adv = "TRAFFIC 12 O'CLOCK 310 SAME LEVEL" }), "aircraft, strip 2x1 - advisory" },
    { 36, 10, air({ traffic = { barge } }), "aircraft, strip 2x1 - traffic" },
    { 57, 10, air({ traffic = { barge } }), "aircraft, strip 3x1" },
    { 15, 10, air({ traffic = { barge } }), "aircraft, one block" },
    { 36, 24, air({ traffic = { hawk, barge, tug } }), "aircraft, panel 2x2" },
    { 36, 10, v("sub", "DEEP ONE", { x = 40, y = 22, z = -900 }, { x = 4, y = -0.8, z = 3 }, { traffic = { tug } }), "submarine" },
    { 36, 10, v("sea", "SEA WOLF", { x = 2410, y = 63, z = -3120 }, { x = -9, y = 0, z = 0 }, { traffic = {} }), "vessel" },
    { 36, 10, v("land", "ROVER", { x = 1900, y = 71, z = 360 }, { x = 0, y = 0, z = 12 }, { traffic = {} }), "land vehicle" },
    { 36, 10, air({ link = "none", traffic = {} }), "no tower" },
    { 36, 10, air({ sos = "armed" }), "distress armed" },
    { 36, 10, air({ sos = "heard", traffic = {} }), "distress heard" },
    { 36, 10, { me = { kind = "air" }, unregistered = true }, "unregistered" },
  }
  local out, labels = {}, {}
  for i, f in ipairs(frames) do
    local c = D.canvas(f[1], f[2])
    UI.render(T, c, f[3])
    local rows = {}
    for y = 1, f[2] do
      local a, fg, b = c:row(y)
      rows[y] = a .. "\0" .. fg .. "\0" .. b
    end
    out[i] = table.concat(rows, "\n")
    labels[i] = f[4]
  end
  local pal = {}
  for k, x in pairs(T.PALETTE) do pal[#pal + 1] = k .. "=" .. string.format("%06x", x) end
  return table.concat(out, "\1"), table.concat(labels, "\1"), table.concat(pal, ",")
end
"""


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "nav.png")
    L = LuaRuntime(unpack_returned_tuples=True, encoding=None)
    blob, labels, pal = L.eval(RENDER)(ROOT.replace("\\", "/").encode())
    palette = {"0": 0xF0F0F0, "f": 0x111111}
    for pair in pal.decode().split(","):
        k, v = pair.split("=")
        palette[k] = int(v, 16)
    imgs = [ccfont.draw(rows, palette, px=2, label=lab.decode())
            for rows, lab in zip(blob.split(b"\1"), labels.split(b"\1"))]
    pad, cols = 12, 2
    rows = [imgs[i:i + cols] for i in range(0, len(imgs), cols)]
    width = max(sum(i.width for i in r) + pad * (len(r) + 1) for r in rows)
    height = sum(max(i.height for i in r) + pad for r in rows) + pad
    sheet = Image.new("RGB", (width, height), (0, 0, 0))
    y = pad
    for r in rows:
        x = pad
        for im in r:
            sheet.paste(im, (x, y))
            x += im.width + pad
        y += max(i.height for i in r) + pad
    sheet.save(out)
    print("wrote " + out)


if __name__ == "__main__":
    main()
