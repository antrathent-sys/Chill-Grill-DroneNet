#!/usr/bin/env python3
"""Render a depot's two screens as the monitors would show them.

    python tools/preview_depot.py [out.png] [--t 26 --t 38 ...] [--gif out.gif]

Uses lib/depotscreens.lua's demo loop (100 s): standing by, a unit inbound, a
load on side A step by step, a two-sided unload, a load called off. Each --t is
one moment, HERO (3x3 at text scale 0.5, 57x38) beside ORDER (2x3 portrait,
36x38); several are stacked. --gif plays the whole loop at --fps. Needs lupa
and Pillow.
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
function(D, DV, t, hw, hh, ow, oh)
  local st = DV.demo(t)
  local out = {}
  for _, s in ipairs({ { "hero", hw, hh }, { "order", ow, oh } }) do
    local c = D.canvas(s[2], s[3])
    DV.render(s[1], c, st, t)
    local rows = {}
    for y = 1, s[3] do
      local a, f, b = c:row(y)
      rows[y] = a .. "\\0" .. f .. "\\0" .. b
    end
    out[#out + 1] = table.concat(rows, "\\n")
  end
  local pal = {}
  for k, v in pairs(DV.PALETTE) do pal[#pal + 1] = k .. "=" .. string.format("%06x", v) end
  return table.concat(out, "\\1"), table.concat(pal, ",")
end
"""

GLYPH = {16: "►", 17: "◄", 30: "▲", 31: "▼", 4: "♦", 7: "•",
         24: "↑", 25: "↓", 26: "→", 27: "←"}


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
            elif code == 140:
                pass
            elif code != 32:
                dr.text((px + 1, py), GLYPH.get(code, chr(code)), fill=pal[f[x]], font=font)
    return img


def frame(L, D, DV, t, a, pal_cache, font):
    screens, pal_s = L.eval(RENDER)(D, DV, t, a.hw, a.hh, a.ow, a.oh)
    if not pal_cache:
        for kv in pal_s.decode().split(","):
            k, v = kv.split("=")
            pal_cache[k] = "#" + v
    hero, order = [draw_screen(s, pal_cache, a.scale, font) for s in screens.split(b"\1")]
    gap = 10 * a.scale
    img = Image.new("RGB", (hero.width + order.width + gap * 3, max(hero.height, order.height) + gap * 2), "#101214")
    img.paste(hero, (gap, gap))
    img.paste(order, (hero.width + gap * 2, gap))
    return img


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out", nargs="?", default=os.path.join(HERE, "depot_preview.png"))
    ap.add_argument("--t", type=float, action="append")
    ap.add_argument("--gif")
    ap.add_argument("--fps", type=float, default=4.0)
    ap.add_argument("--hero", default="57x38")
    ap.add_argument("--order", default="36x38")
    ap.add_argument("--scale", type=int, default=2)
    a = ap.parse_args()
    a.hw, a.hh = (int(v) for v in a.hero.lower().split("x"))
    a.ow, a.oh = (int(v) for v in a.order.lower().split("x"))

    L = LuaRuntime(unpack_returned_tuples=True, encoding=None)
    os.chdir(ROOT)
    D = L.execute(open("lib/display.lua", "rb").read())
    DV = L.execute(open("lib/depotscreens.lua", "rb").read())
    try:
        font = ImageFont.truetype("consolab.ttf", int(8.5 * a.scale))
    except Exception:
        font = ImageFont.load_default()
    pal = {}
    if a.gif:
        frames, n = [], int(100 * a.fps)
        for i in range(n):
            frames.append(frame(L, D, DV, i / a.fps, a, pal, font).convert("P", palette=Image.ADAPTIVE, colors=64))
        frames[0].save(a.gif, save_all=True, append_images=frames[1:], duration=int(1000 / a.fps), loop=0,
                       optimize=True)
        print(a.gif)
    times = a.t or [26.0]
    imgs = [frame(L, D, DV, t, a, pal, font) for t in times]
    total = Image.new("RGB", (max(i.width for i in imgs), sum(i.height for i in imgs)), "#101214")
    y = 0
    for i in imgs:
        total.paste(i, (0, y))
        y += i.height
    total.save(a.out)
    print(a.out)


if __name__ == "__main__":
    main()
