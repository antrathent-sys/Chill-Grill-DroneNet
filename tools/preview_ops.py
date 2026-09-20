#!/usr/bin/env python3
"""Render the operator's board to a PNG, as the base computer shows it.

    python tools/preview_ops.py [out.png] [--size 51x19] [--scale 12]

Calls lib/opsui.lua through lib/display.lua's canvas with a made-up fleet, so
what comes out is the real screen rather than an impression of it. A default
advanced computer is 51x19; an advanced monitor at text scale 0.5 is bigger,
and the board lays itself out differently under 46 columns - try --size 39x19
to see that. Needs lupa and Pillow.
"""
import argparse, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

try:
    from lupa.lua51 import LuaRuntime
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    print("needs lupa and Pillow:  pip install lupa pillow", file=sys.stderr)
    sys.exit(2)

PALETTE = {
    "0": 0xF0F0F0, "1": 0xF2B233, "2": 0xE57FD8, "3": 0x99B2F2, "4": 0xDEDE6C,
    "5": 0x7FCC19, "6": 0xF2B2CC, "7": 0x4C4C4C, "8": 0x999999, "9": 0x4C99B2,
    "a": 0xB266E5, "b": 0x3366CC, "c": 0x7F664C, "d": 0x57A64E, "e": 0xCC4C4C,
    "f": 0x111111,
}

RENDER = rb"""
function(root, w, h, sel)
  package = package or {}
  local D = dofile(root .. "/lib/display.lua")
  local T = dofile(root .. "/lib/tui.lua")
  local UI = dofile(root .. "/lib/opsui.lua")
  local c = D.canvas(w, h)
  UI.board(T, c, {
    units = {
      { id = "drone-1", state = "CRUISE", batt = 94, spd = 186, job = "j-1789-d", x = 2418, z = -1190 },
      { id = "drone-2", state = "DOCKED", batt = 100, x = 1892, z = 365 },
      { id = "drone-3", state = "DOCKED", batt = 41, x = 1896, z = 371 },
      { id = "drone-4", state = "LOST", batt = 12, x = -560, z = 3120 },
    },
    sel = sel,
    jobs = 1, refused = 0, clock = "06:12", hails = true,
    log = {
      "0609 hail at 812,-344 from pocket-2: drone-1 j-1789-d",
      "0610 drone-1 enroute - on the way",
      "0611 drone-1 waiting - on station",
      "0612 drone-1 riding",
      "0612 pier: 12 rides today",
    },
  })
  local rows = {}
  for y = 1, h do
    local s, f, b = c:row(y)
    rows[y] = s .. "\0" .. f .. "\0" .. b
  end
  local pal = {}
  for slot, rgb in pairs(T.PALETTE) do pal[#pal + 1] = slot .. "=" .. string.format("%06x", rgb) end
  return table.concat(rows, "\n"), table.concat(pal, ",")
end
"""


def rgb(v):
    return ((v >> 16) & 255, (v >> 8) & 255, v & 255)


def cell_bits(code):
    if code < 128 or code > 159:
        return None
    return code - 128


def draw_frame(rows, scale, font, label):
    rows = rows.split(b"\n")
    h = len(rows)
    w = len(rows[0].split(b"\0")[0])
    cw, ch = scale, scale * 3 // 2
    img = Image.new("RGB", (w * cw, h * ch + 20), rgb(0x111111))
    d = ImageDraw.Draw(img)
    sw, sh = cw / 2.0, ch / 3.0
    for y, row in enumerate(rows):
        text, fg, bg = row.split(b"\0")
        for x in range(w):
            ink, paper = rgb(PALETTE.get(chr(fg[x]), 0xF0F0F0)), rgb(PALETTE.get(chr(bg[x]), 0x111111))
            d.rectangle([x * cw, y * ch, (x + 1) * cw - 1, (y + 1) * ch - 1], fill=paper)
            bits = cell_bits(text[x])
            if bits is not None:
                for i in range(6):
                    if bits & (1 << i):
                        x0, y0 = x * cw + (i % 2) * sw, y * ch + (i // 2) * sh
                        d.rectangle([x0, y0, x0 + sw - 1, y0 + sh - 1], fill=ink)
            elif text[x] != 32:
                d.text((x * cw + 1, y * ch), chr(text[x]), font=font, fill=ink)
    d.text((2, h * ch + 4), label, font=font, fill=rgb(0x999999))
    return img


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out", nargs="?", default=os.path.join(HERE, "ops.png"))
    ap.add_argument("--size", default="51x19")
    ap.add_argument("--scale", type=int, default=12)
    ap.add_argument("--sel", type=int, default=1)
    a = ap.parse_args()
    w, h = (int(v) for v in a.size.lower().split("x"))

    L = LuaRuntime(unpack_returned_tuples=True, encoding=None)
    rows, pal = L.eval(RENDER)(ROOT.replace("\\", "/").encode(), w, h, a.sel)
    for pair in pal.decode().split(","):
        slot, v = pair.split("=")
        PALETTE[slot] = int(v, 16)
    try:
        font = ImageFont.truetype("consola.ttf", a.scale)
    except Exception:
        font = ImageFont.load_default()
    img = draw_frame(rows, a.scale, font, "%dx%d, unit %d selected" % (w, h, a.sel))
    img.save(a.out)
    print("wrote " + a.out)


if __name__ == "__main__":
    main()
