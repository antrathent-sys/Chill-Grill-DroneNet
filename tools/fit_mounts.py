#!/usr/bin/env python3
"""Fit each nav table's mounting, and the gimbal's sign bits, from a tumble log.

    python tools/fit_mounts.py data/probelog-run8-sixtables-tumble.csv

The solver in lib/attitude.lua needs to know each table's plane normal and
forward direction in the body frame. Peripheral names carry none of that, so
it has to be measured. This searches over the discrete possibilities using one
physical fact: NORTH IS HORIZONTAL, so the north vector recovered from the
tables must be perpendicular to gravity from the gimbal at every sample. A
wrong mounting, or a flipped gimbal sign, breaks that. With three tables the
tables' own agreement residual is a second, independent check.

Runs the real Lua solver through lupa, so the fit and the flight code cannot
disagree.
"""
import csv, itertools, math, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

try:
    from lupa import LuaRuntime
except ImportError:
    print("needs lupa:  pip install lupa", file=sys.stderr); sys.exit(2)

L = LuaRuntime(unpack_returned_tuples=True)
L.execute("math.atan2 = math.atan2 or function(y, x) return math.atan(y, x) end")
A = L.eval("dofile([[%s]])" % os.path.join(ROOT, "lib", "attitude.lua").replace("\\", "/"))
vec = lambda x, y, z: L.table(x=x, y=y, z=z)

AXES = {"+x": (1, 0, 0), "-x": (-1, 0, 0), "+y": (0, 1, 0), "-y": (0, -1, 0),
        "+z": (0, 0, 1), "-z": (0, 0, -1)}


def perp_axes(normal):
    n = AXES[normal]
    return [k for k, a in AXES.items() if abs(sum(i * j for i, j in zip(a, n))) < 1e-9]


def mount(normal, forward):
    return L.table(normal=vec(*AXES[normal]), forward=vec(*AXES[forward]))


def load(path):
    rows = list(csv.DictReader(open(path)))
    navs = [c for c in rows[0].keys() if c.startswith("nav")]
    out = []
    for r in rows:
        gp, gr = float(r["gp"]), float(r["gr"])
        tilt = max(abs(gp), abs(gr))
        out.append({"gp": gp, "gr": gr, "tilt": tilt,
                    "nav": {n: float(r[n]) for n in navs}})
    return out, navs


def score(samples, assign, gsign):
    """Mean |north_body . gravity_body| over tilted samples, plus mean table
    residual. Lower is better on both."""
    perp, resid, n = 0.0, 0.0, 0
    tabs = L.table()
    for i, (name, (nm, fw)) in enumerate(assign.items()):
        tabs[i + 1] = L.table(mount=mount(nm, fw), angle=0.0)
    for s in samples:
        if s["tilt"] < 20:              # level samples cannot discriminate
            continue
        for i, name in enumerate(assign.keys()):
            tabs[i + 1].angle = s["nav"][name]
        d, r, used = A.targetFromTables(tabs)
        if d is None:
            return 999.0, 999.0
        g = A.gravityFromGimbal(s["gp"], s["gr"], L.table(pitch=gsign[0], roll=gsign[1]))
        perp += abs(d.x * g.x + d.y * g.y + d.z * g.z)
        resid += (r or 0.0)
        n += 1
    if n == 0:
        return 999.0, 999.0
    return perp / n, resid / n


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "data", "probelog-run8-sixtables-tumble.csv")
    samples, navs = load(path)
    tilted = sum(1 for s in samples if s["tilt"] >= 20)
    print("%d samples, %d tilted enough to use, tables: %s" % (len(samples), tilted, " ".join(navs)))

    # nav6 duplicates nav5; drop it. nav4 is the flat one (established).
    navs = [n for n in navs if n != "nav6"]
    flat = "nav4"
    verticals = [n for n in navs if n != flat]

    gsigns = [(1, 1), (1, -1), (-1, 1), (-1, -1)]
    flat_opts = [(nm, fw) for nm in ("+y", "-y") for fw in perp_axes(nm)]
    vert_opts = [(nm, fw) for nm in ("+x", "-x", "+z", "-z") for fw in perp_axes(nm)]

    # Stage 1: gimbal signs + flat table + ONE vertical table, jointly.
    print("\nstage 1: gimbal signs, %s, and one vertical table, jointly" % flat)
    best = None
    for vt in verticals:
        for gs in gsigns:
            for fo in flat_opts:
                for vo in vert_opts:
                    p, r = score(samples, {flat: fo, vt: vo}, gs)
                    key = (p, r)
                    if best is None or key < best[0]:
                        best = (key, gs, {flat: fo, vt: vo}, vt)
    (p, r), gs, assign, vt = best
    print("  best: gimbal signs pitch=%+d roll=%+d" % gs)
    for k, (nm, fw) in assign.items():
        print("        %-5s normal %s forward %s" % (k, nm, fw))
    print("        mean |north.gravity| = %.4f   (perfect is 0; 1.0 would be north pointing straight down)" % p)

    # Stage 2: add each remaining vertical table, holding the rest fixed.
    print("\nstage 2: remaining vertical tables, one at a time")
    for extra in [v for v in verticals if v != vt]:
        bestE = None
        for vo in vert_opts:
            trial = dict(assign); trial[extra] = vo
            p2, r2 = score(samples, trial, gs)
            if bestE is None or (r2, p2) < bestE[0]:
                bestE = ((r2, p2), vo)
        (r2, p2), vo = bestE
        assign[extra] = vo
        print("  %-5s normal %s forward %s   perp %.4f   agreement residual %.2f deg" % (extra, vo[0], vo[1], p2, r2))

    # Final: everything together
    p, r = score(samples, assign, gs)
    print("\nfinal, all tables:")
    print("  mean |north.gravity| = %.4f" % p)
    print("  mean agreement residual = %.2f deg  (how much the tables disagree with each other)" % r)

    # Emit as Lua config
    print("\n-- paste into fly.lua CFG / attitude config:")
    print("ATT_GIMBAL_SIGNS = { pitch = %d, roll = %d }," % gs)
    print("ATT_TABLES = {")
    for k, (nm, fw) in assign.items():
        num = k.replace("nav", "")
        print('  { name = "navigation_table_%s", normal = "%s", forward = "%s" },' % (num, nm, fw))
    print("},")

    # Sanity: what does the fitted setup say the heading was at rest, start vs end?
    print("\nheading at the two rest states (should differ by the ~79 deg yaw seen in nav4):")
    tabs = L.table()
    for i, (name, (nm, fw)) in enumerate(assign.items()):
        tabs[i + 1] = L.table(mount=mount(nm, fw), angle=0.0)
    for label, s in (("start", samples[0]), ("end", samples[-1])):
        for i, name in enumerate(assign.keys()):
            tabs[i + 1].angle = s["nav"][name]
        q, diag = A.estimate(tabs, L.table(pitch=s["gp"], roll=s["gr"], signs=L.table(pitch=gs[0], roll=gs[1])), vec(0, 0, -1))
        if q is not None:
            print("  %-5s heading %6.1f deg   residual %.2f" % (label, A.heading(q), diag.residual or 0))
        else:
            print("  %-5s no solution: %s" % (label, diag.reason))


if __name__ == "__main__":
    main()
