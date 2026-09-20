#!/usr/bin/env python3
"""Draw candidate emblems for the pocket header, blown up and at actual size.

    python tools/preview_badges.py

Nine sub-pixels is all the header has, and at that size an emblem lives or
dies on its silhouette: the one in lib/hailmap.lua (B) keeps a toothed rim and
a hollow middle and drops the spokes, because spokes fill the hole and the
whole thing turns to porridge. Edit CANDIDATES, run this, pick one, paste it
into M.BADGE.
"""
import os
from PIL import Image, ImageDraw, ImageFont

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "badges.png")

# Every candidate is a sub-pixel bitmap. Nine rows is three character rows,
# which is what the header has. Width is free: cells are 2 sub-pixels wide.
CANDIDATES = [
    ("A cog, 6 spokes", [
        "..XXXXX..",
        ".X.X.X.X.",
        "XX.XXX.XX",
        "XXXX.XXXX",
        "X..X.X..X",
        "XXXX.XXXX",
        "XX.XXX.XX",
        ".X.X.X.X.",
        "..XXXXX..",
    ]),
    ("B cog, toothed ring", [
        "..X.X.X..",
        ".XXXXXXX.",
        "XXX...XXX",
        ".XX...XX.",
        "XX.....XX",
        ".XX...XX.",
        "XXX...XXX",
        ".XXXXXXX.",
        "..X.X.X..",
    ]),
    ("C eight-point star", [
        "....X....",
        "X...X...X",
        ".X..X..X.",
        "..XXXXX..",
        "XXXX.XXXX",
        "..XXXXX..",
        ".X..X..X.",
        "X...X...X",
        "....X....",
    ]),
    ("D wings", [
        ".........",
        "XX.....XX",
        ".XXX.XXX.",
        "..XXXXX..",
        "...XXX...",
        "..XXXXX..",
        ".XXX.XXX.",
        "XX.....XX",
        ".........",
    ]),
    ("E hex sigil", [
        "..XXXXX..",
        ".X.....X.",
        "X...X...X",
        "X..XXX..X",
        "X.XX.XX.X",
        "X..XXX..X",
        "X...X...X",
        ".X.....X.",
        "..XXXXX..",
    ]),
    ("F rotor disc", [
        ".XX...XX.",
        "XXX...XXX",
        ".XX.X.XX.",
        "...XXX...",
        "..XXXXX..",
        "...XXX...",
        ".XX.X.XX.",
        "XXX...XXX",
        ".XX...XX.",
    ]),
    ("G cog, wide 13", [
        "...XX.XX...",
        ".XXXXXXXXX.",
        ".XX..X..XX.",
        "XX...X...XX",
        "XXXXXXXXXXX",
        "XX...X...XX",
        ".XX..X..XX.",
        ".XXXXXXXXX.",
        "...XX.XX...",
    ]),
    ("H chevron stack", [
        "....X....",
        "...XXX...",
        "..XX.XX..",
        ".XX...XX.",
        ".........",
        ".XX...XX.",
        "..XX.XX..",
        "...XXX...",
        "....X....",
    ]),
]

BONE = 0xDDE1E5
PAPER = 0x050607
DIM = 0x6F757D


def draw(bitmap, px):
    h = len(bitmap)
    w = max(len(r) for r in bitmap)
    img = Image.new("RGB", (w * px, h * px), PAPER)
    d = ImageDraw.Draw(img)
    for y, row in enumerate(bitmap):
        for x, ch in enumerate(row):
            if ch == "X":
                d.rectangle([x * px, y * px, (x + 1) * px - 1, (y + 1) * px - 1], fill=BONE)
    return img


def main():
    try:
        font = ImageFont.truetype("consola.ttf", 13)
    except Exception:
        font = ImageFont.load_default()
    cell_w, pad = 230, 14
    cols = 4
    rows = (len(CANDIDATES) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * cell_w, rows * 170), 0x000000)
    d = ImageDraw.Draw(sheet)
    for i, (name, bm) in enumerate(CANDIDATES):
        cx = (i % cols) * cell_w
        cy = (i // cols) * 170
        big = draw(bm, 12)
        sheet.paste(big, (cx + pad, cy + pad))
        # and the size it really is on a pocket screen: sub-pixels are about
        # 3 real pixels square at default GUI scale
        small = draw(bm, 3)
        sheet.paste(small, (cx + pad + big.width + 20, cy + pad + 4))
        d.text((cx + pad, cy + pad + big.height + 6), name, font=font, fill=0xDDE1E5)
        d.text((cx + pad + big.width + 20, cy + pad + small.height + 10), "actual", font=font, fill=DIM)
    sheet.save(OUT)
    print("wrote " + OUT)


if __name__ == "__main__":
    main()
