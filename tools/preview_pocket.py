#!/usr/bin/env python3
"""Render the pocket terminal's ride screens to a PNG, as the pocket shows them.

    python tools/preview_pocket.py [out.png] [--size 26x20] [--scale 14]


Four frames of one ride: the taxi a long way off, closing, landed beside the
customer, and carrying them to the destination. It calls lib/hailmap.lua - the
same code hail.lua runs - through lib/display.lua's canvas, so what comes out
is the real screen and not an impression of it. Needs lupa and Pillow.
"""
import argparse, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ccfont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

try:
    from lupa.lua51 import LuaRuntime
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    print("needs lupa and Pillow:  pip install lupa pillow", file=sys.stderr)
    sys.exit(2)

# Filled in from lib/tui.lua's own palette, so the preview cannot drift from
# what the hardware shows. PIL reads a bare integer as 0xBBGGRR, so every
# colour is handed over as a tuple - see rgb() below.
PALETTE = {
    "0": 0xF0F0F0, "1": 0xF2B233, "2": 0xE57FD8, "3": 0x99B2F2, "4": 0xDEDE6C,
    "5": 0x7FCC19, "6": 0xF2B2CC, "7": 0x4C4C4C, "8": 0x999999, "9": 0x4C99B2,
    "a": 0xB266E5, "b": 0x3366CC, "c": 0x7F664C, "d": 0x57A64E, "e": 0xCC4C4C,
    "f": 0x111111,
}

RENDER = rb"""
function(root, w, h, frames)
  package = package or {}
  local D = dofile(root .. "/lib/display.lua")
  local T = dofile(root .. "/lib/tui.lua")
  local UI = dofile(root .. "/lib/hailui.lua")
  local out = {}
  for _, fr in ipairs(frames) do
    local c = D.canvas(w, h)
    if fr.screen == "boot" then
      UI.boot(T, c, { frac = fr.frac, ver = fr.ver })
    elseif fr.screen == "down" then
      UI.down(T, c, {})
    elseif fr.screen == "topup" then
      UI.topup(T, c, { who = "alex", balance = fr.balance, amount = fr.amount,
                       state = fr.state, got = fr.got, spin = fr.spin or 0 })
    elseif fr.screen == "places" then
      UI.places(T, c, { from = { x = 812, z = -344 }, sel = fr.sel, top = 1, balance = fr.balance, places = {
        { name = "home", dist = 1104 }, { name = "pier", dist = 220 },
        { name = "depot", dist = 3480 }, { name = "quarry", dist = 760 },
        { name = "north gate", dist = 2190 }, { name = "market", dist = 940 },
      } })
    else
      local log = { "0612 UNIT REQUESTED", "0613 INBOUND" }
      if fr.state == "waiting" then log[#log + 1] = "0615 ON STATION" end
      if fr.state == "riding" then log[#log + 1] = "0615 BOARDED" end
      UI.ride(T, c, { away = fr.away, state = fr.state, unit = "DRONE-1",
                      spin = fr.spin or 0, start = fr.start, eta = fr.eta, log = log })
    end
    local rows = {}
    for y = 1, h do
      local s, f, b = c:row(y)
      rows[y] = s .. "\0" .. f .. "\0" .. b
    end
    out[#out + 1] = table.concat(rows, "\n")
  end
  local pal = {}
  for slot, rgb in pairs(T.PALETTE) do pal[#pal + 1] = slot .. "=" .. string.format("%06x", rgb) end
  return table.concat(out, "\1"), table.concat(pal, ",")
end
"""

FRAMES = [
    dict(screen="places", sel=2, away=0, state="calling", spin=0, start=1, eta=0, balance=416),
    dict(screen="topup", state="choose", balance=-56, amount=0, spin=1, away=0, start=1, eta=0),
    dict(screen="topup", state="ready", balance=-56, amount=512, spin=2, away=0, start=1, eta=0),
    dict(screen="ride", away=392, state="riding", spin=0, start=1456, eta=38),
]

# what a customer's pass shows before and instead of the service (kiosk.lua)
BOOT_FRAMES = [
    dict(screen="boot", frac=0.4, ver="8f3c2a1"),
    dict(screen="boot", frac=1.0, ver="8f3c2a1"),
    dict(screen="down"),
]

# A teletext cell is a 2x3 grid of sub-pixels: bit 1 top-left, 2 top-right,
# 4 middle-left, 8 middle-right, 16 bottom-left, 32 bottom-right, and a cell
# with the bottom-right lit is stored as its inverse with the colours swapped
# (lib/display.lua:291-325). Drawing the six rectangles is what a CC screen
# does, and it is the only way this preview looks like the real one.
# PIL reads a bare integer fill as 0xBBGGRR, so every colour has to be handed
# over as a tuple or the whole preview comes out with its channels swapped -
# which is exactly what happened: cyan borders rendered gold for three rounds
# of "that does not look right".
def rgb(v):
    return ((v >> 16) & 255, (v >> 8) & 255, v & 255)


def cell_bits(code):
    if code < 128 or code > 159:
        return None
    return code - 128


def draw_frame(rows, scale, font, label):
    # The game's own cell geometry (6x9) and a chunky pixel font, so the
    # preview packs text as tightly as the game does - see tools/ccfont.py.
    # scale and font are kept for the callers and no longer used.
    return ccfont.draw(rows, PALETTE, px=3, label=label)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out", nargs="?", default=os.path.join(HERE, "pocket.png"))
    ap.add_argument("--size", default="26x20")
    ap.add_argument("--scale", type=int, default=14)
    ap.add_argument("--boot", action="store_true",
                    help="the pass starting up and out of service, instead of a ride")
    a = ap.parse_args()
    frames_in = BOOT_FRAMES if a.boot else FRAMES
    w, h = (int(v) for v in a.size.lower().split("x"))

    L = LuaRuntime(unpack_returned_tuples=True, encoding=None)
    # hand the frames over as Lua source: lupa's table conversion with
    # encoding=None turns the keys into bytes and Lua then cannot find them
    lua_frames = "{" + ",".join(
        "{" + ",".join("%s=%s" % (k, ("true" if v is True else "false" if v is False
                                      else repr(v).replace("'", '"')))
                       for k, v in f.items()) + "}" for f in frames_in) + "}"
    blob, pal = L.eval(RENDER)(ROOT.replace("\\", "/").encode(), w, h,
                               L.eval(lua_frames.encode()))
    frames = blob.split(b"\1")
    for pair in pal.decode().split(","):
        slot, rgbv = pair.split("=")
        PALETTE[slot] = int(rgbv, 16)

    try:
        font = ImageFont.truetype("consola.ttf", a.scale)
    except Exception:
        font = ImageFont.load_default()

    labels = (["starting", "started", "out of service"] if a.boot else
              ["choosing a destination", "how much", "till open, pay now", "carrying you"])
    imgs = [draw_frame(f, a.scale, font, labels[i]) for i, f in enumerate(frames)]
    pad = 10
    sheet = Image.new("RGB", (sum(i.width for i in imgs) + pad * (len(imgs) + 1),
                              max(i.height for i in imgs) + pad * 2), (0, 0, 0))
    x = pad
    for im in imgs:
        sheet.paste(im, (x, pad))
        x += im.width + pad
    sheet.save(a.out)
    print("wrote " + a.out)


if __name__ == "__main__":
    main()
