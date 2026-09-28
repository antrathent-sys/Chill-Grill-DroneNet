#!/usr/bin/env python3
"""A bill of materials from a Create schematic (.nbt), and the order for our part.

    python tools/schematic.py build.nbt
    python tools/schematic.py build.nbt --supply machines/base/supply.txt
    python tools/schematic.py build.nbt --supply supply.txt --who steve --to 1200 70 340
    python tools/schematic.py --selftest

A customer sends the schematic of what they want to build; this says every
item it takes, which of those Cinder supplies, and prints the `ops order add`
line for that part, ready to paste. What we do not make is listed as such, so
the customer knows what to source elsewhere.

A schematic is gzipped NBT: a palette of block states and every block placed.
Turning blocks into items is not one-to-one, and the rules for it are below in
ITEM_RULES and item_for(): a door is two blocks and one item, a double slab one
block and two items, a wall torch is a torch, water is nothing. Copycats are two
things - the copycat, and the block it is disguised as - and the schematic
keeps what each consumed: `Item` on Create's own, `material_data[*].consumedItem`
on Copycats+ multi-state ones. What is inside a block (a chest's contents, an
engine's fuel) is not part of building it and is not counted.

No third-party packages: the NBT reader is the dozen lines it takes.
"""
import argparse
import collections
import gzip
import io
import math
import os
import struct
import sys


# ---------------------------------------------------------------- NBT ------
def read_nbt(data):
    f = io.BytesIO(data)
    rd = f.read

    def tag(t):
        if t == 1: return struct.unpack(">b", rd(1))[0]
        if t == 2: return struct.unpack(">h", rd(2))[0]
        if t == 3: return struct.unpack(">i", rd(4))[0]
        if t == 4: return struct.unpack(">q", rd(8))[0]
        if t == 5: return struct.unpack(">f", rd(4))[0]
        if t == 6: return struct.unpack(">d", rd(8))[0]
        if t == 7: return rd(struct.unpack(">i", rd(4))[0])
        if t == 8: return rd(struct.unpack(">H", rd(2))[0]).decode("utf-8", "replace")
        if t == 9:
            et, n = rd(1)[0], struct.unpack(">i", rd(4))[0]
            return [tag(et) for _ in range(n)]
        if t == 10:
            out = {}
            while True:
                tt = rd(1)[0]
                if tt == 0: return out
                name = rd(struct.unpack(">H", rd(2))[0]).decode("utf-8", "replace")
                out[name] = tag(tt)
        if t == 11:
            n = struct.unpack(">i", rd(4))[0]; return list(struct.unpack(">%di" % n, rd(4 * n)))
        if t == 12:
            n = struct.unpack(">i", rd(4))[0]; return list(struct.unpack(">%dq" % n, rd(8 * n)))
        raise ValueError("unknown NBT tag %d" % t)

    t = rd(1)[0]
    rd(struct.unpack(">H", rd(2))[0])
    return tag(t)


def load(path):
    raw = open(path, "rb").read()
    try:
        raw = gzip.decompress(raw)
    except OSError:
        pass
    return read_nbt(raw)


# ------------------------------------------------------- blocks to items ---
# Blocks that are nothing to buy: air, fluids (a bucket is not a building
# material), and the pieces a machine makes of itself.
NOTHING = {
    "minecraft:air", "minecraft:cave_air", "minecraft:void_air", "minecraft:water",
    "minecraft:lava", "minecraft:bubble_column", "minecraft:fire", "minecraft:soul_fire",
    "minecraft:piston_head", "minecraft:moving_piston", "minecraft:nether_portal",
    "minecraft:end_portal", "minecraft:end_gateway", "minecraft:frosted_ice",
    "create:shaft_casing_part", "structure_void",
}

# A block whose item has another name.
ITEM_RULES = {
    "minecraft:wall_torch": "minecraft:torch",
    "minecraft:soul_wall_torch": "minecraft:soul_torch",
    "minecraft:redstone_wall_torch": "minecraft:redstone_torch",
    "minecraft:redstone_wire": "minecraft:redstone",
    "minecraft:tripwire": "minecraft:string",
    "minecraft:cocoa": "minecraft:cocoa_beans",
    "minecraft:tall_seagrass": "minecraft:seagrass",
    "minecraft:big_dripleaf_stem": None,        # part of a big dripleaf
    "minecraft:powder_snow": "minecraft:powder_snow_bucket",
}


def item_for(name, props):
    """The items one placed block stands for: a list of (item, count)."""
    props = props or {}
    if name in NOTHING or name.endswith(":air"):
        return []
    if name in ITEM_RULES:
        it = ITEM_RULES[name]
        return [(it, 1)] if it else []
    ns, _, base = name.partition(":")
    # two-block things count once: the lower half, the foot of a bed
    if props.get("half") == "upper" and ("door" in base or props.get("double_block_half") or
                                         base in ("tall_grass", "large_fern", "sunflower", "lilac",
                                                  "rose_bush", "peony", "pitcher_plant", "tall_seagrass")):
        return []
    if base.endswith("_bed") and props.get("part") == "head":
        return []
    # wall-mounted forms
    for wall, plain in (("_wall_hanging_sign", "_hanging_sign"), ("_wall_sign", "_sign"),
                        ("_wall_banner", "_banner"), ("_wall_head", "_head"), ("_wall_skull", "_skull"),
                        ("_wall_fan", "_fan")):
        if base.endswith(wall):
            return [("%s:%s" % (ns, base[: -len(wall)] + plain), 1)]
    # a double slab is two slabs
    if base.endswith("_slab") and props.get("type") == "double":
        return [(name, 2)]
    # potted plants: the pot and the plant
    if ns == "minecraft" and base.startswith("potted_"):
        return [("minecraft:flower_pot", 1), ("minecraft:" + base[len("potted_"):], 1)]
    # stacked in one block
    for key in ("candles", "pickles", "eggs", "layers", "flower_amount", "segment_amount"):
        if key in props:
            try:
                return [(name, int(props[key]))]
            except ValueError:
                pass
    return [(name, 1)]


def consumed(block_nbt):
    """What a copycat was made of: the items it consumed, as a list of (item, count)."""
    out = []
    n = block_nbt or {}
    it = n.get("Item")
    if isinstance(it, dict) and it.get("id") and it["id"] != "minecraft:air":
        out.append((it["id"], int(it.get("count", it.get("Count", 1)) or 1)))
    md = n.get("material_data")
    if isinstance(md, dict):
        for part in md.values():
            ci = part.get("consumedItem") if isinstance(part, dict) else None
            if isinstance(ci, dict) and ci.get("id") and ci["id"] != "minecraft:air":
                out.append((ci["id"], int(ci.get("count", 1) or 1)))
    return out


def bill(root):
    """(items, notes): items is item -> count; notes are things worth saying."""
    pal = root.get("palette") or (root.get("palettes") or [[]])[0]
    items = collections.Counter()
    unknown = collections.Counter()
    for b in root.get("blocks", []):
        st = pal[b["state"]]
        name = st.get("Name", "?")
        for it, n in item_for(name, st.get("Properties")):
            items[it] += n
        for it, n in consumed(b.get("nbt")):
            items[it] += n
        if name == "create:belt":
            unknown[name] += 1
    notes = []
    if unknown.get("create:belt"):
        notes.append("create:belt is counted per block; a belt is placed from belt items by length, "
                     "so check that line by hand")
    ents = collections.Counter((e.get("nbt") or {}).get("id", "?") for e in root.get("entities", []))
    for eid, n in ents.items():
        notes.append("%d entit%s in the schematic: %s (not counted - glue, seats' riders and the like)"
                     % (n, "y" if n == 1 else "ies", eid))
    return items, notes


def short(item):
    return item.split(":", 1)[1] if item.startswith("minecraft:") else item


def read_supply(path):
    """One item per line; `#` comments; `minecraft:` may be left off."""
    out = set()
    for line in open(path, encoding="utf-8"):
        line = line.split("#", 1)[0].strip()
        if line:
            out.add(line if ":" in line else "minecraft:" + line)
    return out


# ------------------------------------------------------------- output ------
def report(path, items, notes, supply=None, who=None, to=None, stacks=None):
    root_name = os.path.basename(path)
    total = sum(items.values())
    print("%s: %d items of %d kinds" % (root_name, total, len(items)))
    ours = {k: v for k, v in items.items() if supply is not None and k in supply}
    theirs = {k: v for k, v in items.items() if not (supply is not None and k in supply)}

    def table(d, title):
        if not d:
            return
        print()
        print(title)
        for it, n in sorted(d.items(), key=lambda kv: (-kv[1], kv[0])):
            print("   %7d  %s" % (n, short(it)))

    if supply is None:
        table(items, "everything it takes:")
    else:
        table(ours, "we supply (%d items):" % sum(ours.values()))
        table(theirs, "not ours - source elsewhere (%d items):" % sum(theirs.values()))
    for n in notes:
        print()
        print("note: " + n)
    if supply is not None and ours:
        pairs = " ".join("%d %s" % (n, short(it)) for it, n in sorted(ours.items(), key=lambda kv: -kv[1]))
        where = ("to %d %d %d" % tuple(to)) if to else "to <x> <y> <z>"
        print()
        print("the order for our part:")
        print("   ops order add %s %s %s for <price>" % (who or "<who>", pairs, where))
        silos = sum(math.ceil(n / 64) for n in ours.values())
        print("   about %d slot%s: %d silo%s" % (silos, "" if silos == 1 else "s",
              max(1, math.ceil(silos / 59)), "" if math.ceil(silos / 59) <= 1 else "s"))


# ---------------------------------------------------------- self test ------
def _write_nbt(root):
    """Just enough NBT writing to build test schematics in memory."""
    out = io.BytesIO()
    w = out.write

    def s(x):
        b = x.encode("utf-8"); w(struct.pack(">H", len(b))); w(b)

    def kind(v):
        if isinstance(v, dict): return 10
        if isinstance(v, list): return 9
        if isinstance(v, str): return 8
        return 3

    def val(v):
        k = kind(v)
        if k == 10:
            for key, x in v.items():
                w(bytes([kind(x)])); s(key); val(x)
            w(b"\x00")
        elif k == 9:
            w(bytes([kind(v[0]) if v else 0])); w(struct.pack(">i", len(v)))
            for x in v: val(x)
        elif k == 8:
            s(v)
        else:
            w(struct.pack(">i", v))

    w(b"\x0a"); s(""); val(root)
    return gzip.compress(out.getvalue())


def selftest():
    pal = [
        {"Name": "minecraft:oak_door", "Properties": {"half": "lower"}},
        {"Name": "minecraft:oak_door", "Properties": {"half": "upper"}},
        {"Name": "minecraft:stone_slab", "Properties": {"type": "double"}},
        {"Name": "minecraft:wall_torch", "Properties": {}},
        {"Name": "minecraft:water", "Properties": {}},
        {"Name": "create:copycat_step", "Properties": {}},
        {"Name": "copycats:copycat_byte", "Properties": {}},
        {"Name": "minecraft:red_bed", "Properties": {"part": "foot"}},
        {"Name": "minecraft:red_bed", "Properties": {"part": "head"}},
        {"Name": "minecraft:candle", "Properties": {"candles": "3"}},
        {"Name": "minecraft:potted_poppy", "Properties": {}},
        {"Name": "minecraft:oak_wall_sign", "Properties": {}},
    ]
    blocks = [{"pos": [0, 0, 0], "state": i} for i in range(len(pal))]
    blocks[5]["nbt"] = {"id": "create:copycat", "Item": {"id": "minecraft:andesite", "count": 1},
                        "Material": {"Name": "minecraft:andesite"}}
    blocks[6]["nbt"] = {"id": "copycats:multistate_copycat", "material_data": {
        "a": {"material": {"Name": "minecraft:black_wool"}, "consumedItem": {"id": "minecraft:black_wool", "count": 1}},
        "b": {"material": {"Name": "minecraft:black_wool"}, "consumedItem": {}},
        "c": {"material": {"Name": "create:copycat_base"}, "consumedItem": {}},
    }}
    root = {"size": [1, 1, 1], "palette": pal, "blocks": blocks, "entities": []}
    items, _ = bill(read_nbt(gzip.decompress(_write_nbt(root))))
    fails = 0

    def check(name, cond, got=None):
        nonlocal fails
        print(("  ok   " if cond else "  FAIL ") + name + ("" if cond else "  %r" % (got,)))
        fails += 0 if cond else 1

    check("a door is two blocks and one item", items["minecraft:oak_door"] == 1, items["minecraft:oak_door"])
    check("a double slab is two slabs", items["minecraft:stone_slab"] == 2, items["minecraft:stone_slab"])
    check("a wall torch is a torch", items["minecraft:torch"] == 1 and "minecraft:wall_torch" not in items)
    check("water is nothing to buy", "minecraft:water" not in items)
    check("a Create copycat is the copycat and what it consumed",
          items["create:copycat_step"] == 1 and items["minecraft:andesite"] == 1)
    check("a Copycats+ block counts each item consumed once, not each part painted",
          items["copycats:copycat_byte"] == 1 and items["minecraft:black_wool"] == 1,
          items["minecraft:black_wool"])
    check("the bare copycat base is not an item", "create:copycat_base" not in items)
    check("a bed counts at its foot only", items["minecraft:red_bed"] == 1, items["minecraft:red_bed"])
    check("three candles in a block are three candles", items["minecraft:candle"] == 3)
    check("a potted poppy is a pot and a poppy",
          items["minecraft:flower_pot"] == 1 and items["minecraft:poppy"] == 1)
    check("a wall sign is a sign", items["minecraft:oak_sign"] == 1)
    print("")
    print("%d failed" % fails if fails else "all passed")
    return 1 if fails else 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("schematic", nargs="?")
    ap.add_argument("--supply", help="what we supply: one item per line")
    ap.add_argument("--who", help="the customer, for the order line")
    ap.add_argument("--to", nargs=3, type=int, metavar=("X", "Y", "Z"))
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args(argv)
    if a.selftest:
        return selftest()
    if not a.schematic:
        ap.print_help()
        return 2
    items, notes = bill(load(a.schematic))
    supply = read_supply(a.supply) if a.supply else None
    report(a.schematic, items, notes, supply, a.who, a.to)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
