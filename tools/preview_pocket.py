#!/usr/bin/env python3
"""Render the pocket terminal's ride screens to a PNG, as the pocket shows them.

    python tools/preview_pocket.py [out.png] [--size 26x20] [--scale 14]
                                   [--theme imperial|silo] [--screen gauge|map]

Four frames of one ride: the taxi a long way off, closing, landed beside the
customer, and carrying them to the destination. It calls lib/hailmap.lua - the
same code hail.lua runs - through lib/display.lua's canvas, so what comes out
is the real screen and not an impression of it. Needs lupa and Pillow.
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

# CC's default palette, the colours hailmap names
PALETTE = {
    "0": 0xF0F0F0, "1": 0xF2B233, "2": 0xE57FD8, "3": 0x99B2F2, "4": 0xDEDE6C,
    "5": 0x7FCC19, "6": 0xF2B2CC, "7": 0x4C4C4C, "8": 0x999999, "9": 0x4C99B2,
    "a": 0xB266E5, "b": 0x3366CC, "c": 0x7F664C, "d": 0x57A64E, "e": 0xCC4C4C,
    "f": 0x111111,
}

RENDER = rb"""
function(root, w, h, frames, theme, screen)
  package = package or {}
  local D = dofile(root .. "/lib/display.lua")
  D.setTheme(theme)
  local MAP = dofile(root .. "/lib/hailmap.lua")
  local out = {}
  for _, fr in ipairs(frames) do
    local c = D.canvas(w, h)
    local from = { x = 0, z = 0 }
    local trail = {}
    -- walk the taxi in from its start so the tail is the real one
    local steps = fr.steps or 0
    for i = 0, steps do
      local t = (steps == 0) and 1 or (i / steps)
      MAP.addTrail(trail, fr.x0 + (fr.x - fr.x0) * t, fr.z0 + (fr.z - fr.z0) * t)
    end
    local away = math.sqrt(fr.x * fr.x + fr.z * fr.z)
    local view = { from = from, drone = { x = fr.x, z = fr.z }, trail = trail,
                   away = away, state = fr.state, unit = "drone-1", spin = fr.spin or 0,
                   dest = fr.dest and { x = fr.dx, z = fr.dz } or nil,
                   start = fr.start, eta = fr.eta }
    if screen == "map" then MAP.map(D, c, view) else MAP.gauge(D, c, view) end
    local rows = {}
    for y = 1, h do
      local s, f, b = c:row(y)
      rows[y] = s .. "\0" .. f .. "\0" .. b
    end
    out[#out + 1] = table.concat(rows, "\n")
  end
  local pal = {}
  for slot, rgb in pairs(D.THEMES[theme].palette) do
    pal[#pal + 1] = slot .. "=" .. string.format("%06x", rgb)
  end
  return table.concat(out, "\1"), table.concat(pal, ",")
end
"""

FRAMES = [
    dict(x=1180, z=-620, x0=1400, z0=-900, steps=14, state="enroute", spin=1,
         dest=False, dx=0, dz=0, start=1670, eta=47),
    dict(x=190, z=-95, x0=1400, z0=-900, steps=34, state="enroute", spin=2,
         dest=False, dx=0, dz=0, start=1670, eta=9),
    dict(x=3, z=-2, x0=1400, z0=-900, steps=40, state="waiting", spin=3,
         dest=False, dx=0, dz=0, start=1670, eta=0),
    dict(x=-240, z=310, x0=0, z0=0, steps=12, state="riding", spin=0,
         dest=True, dx=-900, dz=1150, start=1456, eta=38),
]

# A teletext cell is a 2x3 grid of sub-pixels: bit 1 top-left, 2 top-right,
# 4 middle-left, 8 middle-right, 16 bottom-left, 32 bottom-right, and a cell
# with the bottom-right lit is stored as its inverse with the colours swapped
# (lib/display.lua:291-325). Drawing the six rectangles is what a CC screen
# does, and it is the only way this preview looks like the real one.
def cell_bits(code):
    if code < 128 or code > 159:
        return None
    return code - 128


def draw_frame(rows, scale, font, label):
    rows = rows.split(b"\n")
    h = len(rows)
    w = len(rows[0].split(b"\0")[0])
    cw = scale                       # cell width in pixels; 2 sub-pixels across
    ch = scale * 3 // 2              # and 3 down
    img = Image.new("RGB", (w * cw, h * ch + 20), 0x111111)
    d = ImageDraw.Draw(img)
    sw, sh = cw / 2.0, ch / 3.0
    for y, row in enumerate(rows):
        text, fg, bg = row.split(b"\0")
        for x in range(w):
            ink = PALETTE.get(chr(fg[x]), 0xF0F0F0)
            paper = PALETTE.get(chr(bg[x]), 0x111111)
            code = text[x]
            d.rectangle([x * cw, y * ch, (x + 1) * cw - 1, (y + 1) * ch - 1], fill=paper)
            bits = cell_bits(code)
            if bits is not None:
                for i in range(6):
                    if bits & (1 << i):
                        sx, sy = i % 2, i // 2
                        x0 = x * cw + sx * sw
                        y0 = y * ch + sy * sh
                        d.rectangle([x0, y0, x0 + sw - 1, y0 + sh - 1], fill=ink)
            elif code != 32:
                d.text((x * cw + 1, y * ch), chr(code), font=font, fill=ink)
    d.text((2, h * ch + 4), label, font=font, fill=0x999999)
    return img


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out", nargs="?", default=os.path.join(HERE, "pocket.png"))
    ap.add_argument("--size", default="26x20")
    ap.add_argument("--scale", type=int, default=14)
    ap.add_argument("--theme", default="imperial", help="imperial or silo")
    ap.add_argument("--screen", default="gauge", help="gauge or map")
    a = ap.parse_args()
    w, h = (int(v) for v in a.size.lower().split("x"))

    L = LuaRuntime(unpack_returned_tuples=True, encoding=None)
    # hand the frames over as Lua source: lupa's table conversion with
    # encoding=None turns the keys into bytes and Lua then cannot find them
    lua_frames = "{" + ",".join(
        "{" + ",".join("%s=%s" % (k, ("true" if v is True else "false" if v is False
                                      else repr(v).replace("'", '"')))
                       for k, v in f.items()) + "}" for f in FRAMES) + "}"
    blob, pal = L.eval(RENDER)(ROOT.replace("\\", "/").encode(), w, h,
                               L.eval(lua_frames.encode()), a.theme.encode(),
                               a.screen.encode())
    frames = blob.split(b"\1")
    for pair in pal.decode().split(","):
        slot, rgb = pair.split("=")
        PALETTE[slot] = int(rgb, 16)

    try:
        font = ImageFont.truetype("consola.ttf", a.scale)
    except Exception:
        font = ImageFont.load_default()

    labels = ["a long way off", "nearly with you", "landed beside you", "carrying you"]
    imgs = [draw_frame(f, a.scale, font, labels[i]) for i, f in enumerate(frames)]
    pad = 10
    sheet = Image.new("RGB", (sum(i.width for i in imgs) + pad * (len(imgs) + 1),
                              max(i.height for i in imgs) + pad * 2), 0x000000)
    x = pad
    for im in imgs:
        sheet.paste(im, (x, pad))
        x += im.width + pad
    sheet.save(a.out)
    print("wrote " + a.out)


if __name__ == "__main__":
    main()
