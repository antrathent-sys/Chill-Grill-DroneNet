"""Draw a CC:Tweaked screen the way the game does, for the preview tools.

A CC terminal cell is 6x9 pixels. A text glyph is a chunky 5x7 bitmap in the
top-left of it, and a teletext character (128-159) is a 2x3 grid of 3x3
blocks. This is an approximation of CC's own term_font.png, which does not
ship with the repo: the glyph shapes are the classic 5x7 dot-matrix set, and
the geometry was matched against an in-game screenshot of a pocket computer
(26x20 cells). It is what matters for judging a layout: the weight of the
letters and how tightly they pack. The previous preview used a desktop font
with wide spacing and made everything look airier than the game does.
"""
from PIL import Image, ImageDraw, ImageFont

CELL_W, CELL_H = 6, 9
MARGIN = 2          # font pixels of border round the screen, coloured by the edge cells

_G = {
    "A": "01110,10001,10001,11111,10001,10001,10001",
    "B": "11110,10001,10001,11110,10001,10001,11110",
    "C": "01110,10001,10000,10000,10000,10001,01110",
    "D": "11100,10010,10001,10001,10001,10010,11100",
    "E": "11111,10000,10000,11110,10000,10000,11111",
    "F": "11111,10000,10000,11110,10000,10000,10000",
    "G": "01110,10001,10000,10111,10001,10001,01111",
    "H": "10001,10001,10001,11111,10001,10001,10001",
    "I": "01110,00100,00100,00100,00100,00100,01110",
    "J": "00111,00010,00010,00010,00010,10010,01100",
    "K": "10001,10010,10100,11000,10100,10010,10001",
    "L": "10000,10000,10000,10000,10000,10000,11111",
    "M": "10001,11011,10101,10101,10001,10001,10001",
    "N": "10001,10001,11001,10101,10011,10001,10001",
    "O": "01110,10001,10001,10001,10001,10001,01110",
    "P": "11110,10001,10001,11110,10000,10000,10000",
    "Q": "01110,10001,10001,10001,10101,10010,01101",
    "R": "11110,10001,10001,11110,10100,10010,10001",
    "S": "01111,10000,10000,01110,00001,00001,11110",
    "T": "11111,00100,00100,00100,00100,00100,00100",
    "U": "10001,10001,10001,10001,10001,10001,01110",
    "V": "10001,10001,10001,10001,10001,01010,00100",
    "W": "10001,10001,10001,10101,10101,10101,01010",
    "X": "10001,10001,01010,00100,01010,10001,10001",
    "Y": "10001,10001,10001,01010,00100,00100,00100",
    "Z": "11111,00001,00010,00100,01000,10000,11111",
    "0": "01110,10001,10011,10101,11001,10001,01110",
    "1": "00100,01100,00100,00100,00100,00100,01110",
    "2": "01110,10001,00001,00010,00100,01000,11111",
    "3": "11111,00010,00100,00010,00001,10001,01110",
    "4": "00010,00110,01010,10010,11111,00010,00010",
    "5": "11111,10000,11110,00001,00001,10001,01110",
    "6": "00110,01000,10000,11110,10001,10001,01110",
    "7": "11111,00001,00010,00100,01000,01000,01000",
    "8": "01110,10001,10001,01110,10001,10001,01110",
    "9": "01110,10001,10001,01111,00001,00010,01100",
    " ": "00000,00000,00000,00000,00000,00000,00000",
    "-": "00000,00000,00000,11111,00000,00000,00000",
    ".": "00000,00000,00000,00000,00000,01100,01100",
    ",": "00000,00000,00000,00000,01100,00100,01000",
    ":": "00000,01100,01100,00000,01100,01100,00000",
    "/": "00001,00010,00010,00100,01000,01000,10000",
    "\\": "10000,01000,01000,00100,00010,00010,00001",
    "[": "01110,01000,01000,01000,01000,01000,01110",
    "]": "01110,00010,00010,00010,00010,00010,01110",
    "(": "00010,00100,01000,01000,01000,00100,00010",
    ")": "01000,00100,00010,00010,00010,00100,01000",
    "%": "11000,11001,00010,00100,01000,10011,00011",
    "?": "01110,10001,00001,00010,00100,00000,00100",
    "!": "00100,00100,00100,00100,00100,00000,00100",
    "|": "00100,00100,00100,00100,00100,00100,00100",
    ">": "01000,00100,00010,00001,00010,00100,01000",
    "<": "00010,00100,01000,10000,01000,00100,00010",
    "=": "00000,00000,11111,00000,11111,00000,00000",
    "+": "00000,00100,00100,11111,00100,00100,00000",
    "#": "01010,01010,11111,01010,11111,01010,01010",
    "'": "00100,00100,01000,00000,00000,00000,00000",
    "_": "00000,00000,00000,00000,00000,00000,11111",
    "*": "00000,00100,10101,01110,10101,00100,00000",
}
GLYPHS = {k: [row for row in v.split(",")] for k, v in _G.items()}


def rgb(v):
    return ((v >> 16) & 255, (v >> 8) & 255, v & 255)


def draw(rows, palette, px=3, label=None):
    """rows: bytes, one line per terminal row of text \\0 fg \\0 bg, as the
    Lua side of the preview tools produces. palette: blit char -> 0xRRGGBB.
    px: screen pixels per font pixel (3 is roughly the game at 1080p)."""
    rows = rows.split(b"\n")
    h = len(rows)
    w = len(rows[0].split(b"\0")[0])
    cw, ch = CELL_W * px, CELL_H * px
    m = MARGIN * px
    foot = 18 if label else 0
    img = Image.new("RGB", (w * cw + 2 * m, h * ch + 2 * m + foot), rgb(0x111111))
    d = ImageDraw.Draw(img)
    # CC paints the margin round the screen in the background colour of the
    # nearest cell, so an edge cell's background shows along that edge
    bgs = [row.split(b"\0")[2] for row in rows]
    def bgc(x, y):
        return rgb(palette.get(chr(bgs[y][x]), 0x111111))
    for x in range(w):
        d.rectangle([m + x * cw, 0, m + (x + 1) * cw - 1, m - 1], fill=bgc(x, 0))
        d.rectangle([m + x * cw, m + h * ch, m + (x + 1) * cw - 1, 2 * m + h * ch - 1], fill=bgc(x, h - 1))
    for y in range(h):
        d.rectangle([0, m + y * ch, m - 1, m + (y + 1) * ch - 1], fill=bgc(0, y))
        d.rectangle([m + w * cw, m + y * ch, 2 * m + w * cw - 1, m + (y + 1) * ch - 1], fill=bgc(w - 1, y))
    for (cx, cy, x0, y0) in ((0, 0, 0, 0), (w - 1, 0, m + w * cw, 0),
                             (0, h - 1, 0, m + h * ch), (w - 1, h - 1, m + w * cw, m + h * ch)):
        d.rectangle([x0, y0, x0 + m - 1, y0 + m - 1], fill=bgc(cx, cy))
    for y, row in enumerate(rows):
        text, fg, bg = row.split(b"\0")
        for x in range(w):
            ink = rgb(palette.get(chr(fg[x]), 0xF0F0F0))
            paper = rgb(palette.get(chr(bg[x]), 0x111111))
            x0, y0 = m + x * cw, m + y * ch
            d.rectangle([x0, y0, x0 + cw - 1, y0 + ch - 1], fill=paper)
            code = text[x]
            if 128 <= code <= 159:
                bits = code - 128
                for i in range(6):
                    if bits & (1 << i):
                        sx, sy = i % 2, i // 2
                        bx, by = x0 + sx * 3 * px, y0 + sy * 3 * px
                        d.rectangle([bx, by, bx + 3 * px - 1, by + 3 * px - 1], fill=ink)
                continue
            g = GLYPHS.get(chr(code).upper()) if code < 128 else None
            if g is None:
                continue
            for gy, line in enumerate(g):
                for gx, bit in enumerate(line):
                    if bit == "1":
                        bx, by = x0 + gx * px, y0 + (gy + 1) * px
                        d.rectangle([bx, by, bx + px - 1, by + px - 1], fill=ink)
    if label:
        d.text((4, h * ch + 2 * m + 3), label, fill=rgb(0x999999), font=ImageFont.load_default())
    return img
