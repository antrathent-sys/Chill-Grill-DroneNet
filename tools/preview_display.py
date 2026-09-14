#!/usr/bin/env python3
"""Render the flight operations wall to an animated HTML preview.

    python tools/preview_display.py [out.html] [--size 100x66] [--frames 24] [--start 118]

Draws lib/display.lua's demo fleet exactly as a CC monitor would receive it:
the same blit rows, teletext cells decoded to 2x3 blocks, the display palette.
A 5x5 advanced monitor at text scale 0.5 is 100x66.
"""
import argparse, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

try:
    from lupa.lua51 import LuaRuntime
except ImportError:
    print("needs lupa with Lua 5.1:  pip install lupa", file=sys.stderr)
    sys.exit(2)

RENDER = b"""
function(D, w, h, now, theme)
  D.setTheme(theme)
  local c = D.canvas(w, h)
  local m = D.demoModel(now)
  D.render(c, m, now)
  local rows = {}
  for y = 1, h do
    local s, f, b = c:row(y)
    rows[y] = s .. "\\0" .. f .. "\\0" .. b
  end
  return table.concat(rows, "\\n")
end
"""

PALETTE = b"""
function(D, theme)
  D.setTheme(theme)
  local t = {}
  for k, v in pairs(D.PALETTE) do t[#t + 1] = k .. "=" .. string.format("%06x", v) end
  return table.concat(t, ",")
end
"""

PAGE = """<!doctype html>
<meta charset="utf-8">
<title>DroneNet wall preview</title>
<style>
  body { margin: 0; background: #010201; color: #36e063; font: 13px monospace; }
  .wrap { display: flex; flex-direction: column; align-items: center; padding: 16px; gap: 8px; }
  canvas { image-rendering: pixelated; box-shadow: 0 0 40px rgba(54,224,99,.15); border: 6px solid #111; }
  .cap { opacity: .7 }
</style>
<div class="wrap">
  <canvas id="wall"></canvas>
  <div class="cap">__CAPTION__</div>
</div>
<script>
const W = __W__, H = __H__, S = __S__;
const PAL = __PAL__;
const FRAMES = __FRAMES__;
const GLYPH = { 4: "\\u2666", 16:"\\u25BA", 17: "\\u25C4", 30: "\\u25B2", 31: "\\u25BC" };
const cv = document.getElementById("wall");
const CW = 6 * S, CH = 9 * S;
cv.width = W * CW; cv.height = H * CH;
const ctx = cv.getContext("2d");
ctx.textAlign = "center"; ctx.textBaseline = "alphabetic";
ctx.font = "bold " + Math.round(8.2 * S) + "px monospace";
function draw(fr) {
  for (let y = 0; y < H; y++) {
    const [codes, fg, bg] = fr[y];
    for (let x = 0; x < W; x++) {
      const code = codes[x], f = PAL[fg[x]], b = PAL[bg[x]];
      const px = x * CW, py = y * CH;
      ctx.fillStyle = b; ctx.fillRect(px, py, CW, CH);
      if (code >= 128 && code < 160) {
        const bits = code - 128;
        ctx.fillStyle = f;
        for (let k = 0; k < 6; k++) {
          if (bits & (1 << k)) ctx.fillRect(px + (k % 2) * 3 * S, py + Math.floor(k / 2) * 3 * S, 3 * S, 3 * S);
        }
      } else if (code !== 32) {
        ctx.fillStyle = f;
        ctx.fillText(GLYPH[code] || String.fromCharCode(code), px + CW / 2, py + CH * 0.82);
      }
    }
  }
}
let i = 0;
draw(FRAMES[0]);
setInterval(() => { i = (i + 1) % FRAMES.length; draw(FRAMES[i]); }, 250);
</script>
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out", nargs="?", default=os.path.join(HERE, "wall_preview.html"))
    ap.add_argument("--size", default="100x66")
    ap.add_argument("--frames", type=int, default=24)
    ap.add_argument("--start", type=float, default=118.0)
    ap.add_argument("--scale", type=int, default=2)
    ap.add_argument("--theme", default="imperial")
    a = ap.parse_args()
    w, h = (int(v) for v in a.size.lower().split("x"))

    L = LuaRuntime(unpack_returned_tuples=True, encoding=None)
    D = L.execute(open(os.path.join(ROOT, "lib", "display.lua"), "rb").read())
    render, palette = L.eval(RENDER), L.eval(PALETTE)

    pal = {}
    for kv in palette(D, a.theme.encode()).decode().split(","):
        k, v = kv.split("=")
        pal[k] = "#" + v

    frames = []
    for n in range(a.frames):
        now = a.start + n * 0.25
        rows = render(D, w, h, now, a.theme.encode()).split(b"\n")
        frame = []
        for row in rows:
            s, f, b = row.split(b"\0")
            frame.append([list(s), f.decode(), b.decode()])
        frames.append(frame)

    caption = ("DroneNet flight operations wall, %s theme - %dx%d characters (a 5x5 advanced monitor at text "
               "scale 0.5 is 100x66), demo fleet from lib/display.lua, %d frames at 4 fps" % (a.theme, w, h, a.frames))
    html = (PAGE.replace("__W__", str(w)).replace("__H__", str(h)).replace("__S__", str(a.scale))
            .replace("__PAL__", json.dumps(pal)).replace("__FRAMES__", json.dumps(frames, separators=(",", ":")))
            .replace("__CAPTION__", caption))
    with open(a.out, "w", encoding="utf-8") as fh:
        fh.write(html)
    print("wrote %s (%d frames, %.0f KB)" % (a.out, a.frames, os.path.getsize(a.out) / 1024))


if __name__ == "__main__":
    main()
