#!/usr/bin/env python3
"""Render the three control room screens to one PNG, as the monitors would show them.

    python tools/preview_screens.py [out.png] [--t 30] [--drone 28x26] [--tactical 60x26] [--order 28x26]

Uses the mock unit from lib/state.lua at --t seconds into its 130 s loop
(0-8 cradled, 8-58 out to the depot, 58-66 drop hover, 66-122 home, then
cradled). A 3x4 advanced monitor at text scale 1 is 28x26 characters and a
6x4 is 60x26. Needs lupa and Pillow.
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

RENDER = b"""
function(D, S, SC, t, sizes)
  local sim = S.mock(D)
  local st = sim.state()
  while sim.t + 0.5 <= t do sim.tick(0.5) st = sim.state() end
  local out = {}
  for _, name in ipairs({ "drone", "tactical", "order" }) do
    local w, h = sizes[name .. "_w"], sizes[name .. "_h"]
    local c = D.canvas(w, h)
    SC.render(name, c, st)
    local rows = {}
    for y = 1, h do
      local s, f, b = c:row(y)
      rows[y] = s .. "\\0" .. f .. "\\0" .. b
    end
    out[#out + 1] = table.concat(rows, "\\n")
  end
  local pal = {}
  for k, v in pairs(SC.PALETTE) do pal[#pal + 1] = k .. "=" .. string.format("%06x", v) end
  return table.concat(out, "\\1"), table.concat(pal, ",")
end
"""

GLYPH = {16: "►", 17: "◄", 30: "▲", 31: "▼", 4: "♦"}


def draw_screen(rows, pal, scale, font):
    rows = rows.split(b"\n")
    h, w = len(rows), len(rows[0].split(b"\0")[0])
    cw, ch = 6 * scale, 9 * scale
    img = Image.new("RGB", (w * cw, h * ch), pal["f"])
    dr = ImageDraw.Draw(img)
    for y, row in enumerate(rows):
        s, f, b = row.split(b"\0")
        f, b = f.decode(), b.decode()
        for x in range(w):
            code, px, py = s[x], x * cw, y * ch
            dr.rectangle([px, py, px + cw - 1, py + ch - 1], fill=pal[b[x]])
            if 128 <= code < 160:
                bits = code - 128
                for k in range(6):
                    if bits & (1 << k):
                        sx, sy = px + (k % 2) * 3 * scale, py + (k // 2) * 3 * scale
                        dr.rectangle([sx, sy, sx + 3 * scale - 1, sy + 3 * scale - 1], fill=pal[f[x]])
            elif code != 32:
                dr.text((px + 1, py + 1), GLYPH.get(code, chr(code)), fill=pal[f[x]], font=font)
    return img


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out", nargs="?", default=os.path.join(HERE, "control_preview.png"))
    ap.add_argument("--t", type=float, default=30.0)
    ap.add_argument("--drone", default="28x26")
    ap.add_argument("--tactical", default="60x26")
    ap.add_argument("--order", default="28x26")
    ap.add_argument("--scale", type=int, default=2)
    a = ap.parse_args()

    L = LuaRuntime(unpack_returned_tuples=True, encoding=None)
    os.chdir(ROOT)
    D = L.execute(open("lib/display.lua", "rb").read())
    S = L.execute(open("lib/state.lua", "rb").read())
    SC = L.execute(open("lib/screens.lua", "rb").read())
    sizes = L.table()
    for name in ("drone", "tactical", "order"):
        w, h = (int(v) for v in getattr(a, name).lower().split("x"))
        sizes[(name + "_w").encode()], sizes[(name + "_h").encode()] = w, h
    screens, pal_s = L.eval(RENDER)(D, S, SC, a.t, sizes)
    pal = {}
    for kv in pal_s.decode().split(","):
        k, v = kv.split("=")
        pal[k] = "#" + v
    try:
        font = ImageFont.truetype("consolab.ttf", int(8.5 * a.scale))
    except Exception:
        font = ImageFont.load_default()
    imgs = [draw_screen(s, pal, a.scale, font) for s in screens.split(b"\1")]
    gap = 12 * a.scale
    total = Image.new("RGB", (sum(i.width for i in imgs) + gap * 4, max(i.height for i in imgs) + gap * 2), "#101214")
    x = gap
    for i in imgs:
        total.paste(i, (x, gap))
        x += i.width + gap
    total.save(a.out)
    print(a.out)


if __name__ == "__main__":
    main()
