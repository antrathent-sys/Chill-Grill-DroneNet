#!/usr/bin/env python3
"""A stat report over every flightlog in logs/flights.

    python tools/fleetstats.py                 everything, with a per-day table
    python tools/fleetstats.py --since 2026-09-26   only from that date
    python tools/fleetstats.py --split 2026-09-26   before and after, compared

logs/flightlog_summary.py reads ONE flight in detail. This reads all of them
and answers the fleet questions: how often a flight ends badly, how close
landings come, how hard they touch down, whether docking takes one try, and
what a change to the controller actually did to those numbers.

Landing accuracy is measured against the goal the log itself carries (x + ex,
z + ez on the last landing row), so it needs no knowledge of the job. Touchdown
speed comes from the ALTITUDE over the rows before contact, not from the
velocity column: a stale pose reads zero, and the altimeter is what the
controller itself trusts at that moment.
"""
import argparse
import collections
import csv
import glob
import math
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PADS_FILE = os.path.join(ROOT, "machines", "base", "pads.lua")
NEAR_PAD = 6          # blocks: a touchdown this close counts as at that pad
CRUISED = 50          # b/s: below this it was a hop, not a transit
# fly only started writing an END row on 2026-09-20 (33f31d1). Before that a
# log without one says nothing, so those are not counted as a computer stop.
END_ROW_SINCE = "2026-09-20"


def pads():
    """The base's places, so a landing can be named and its rest gap measured."""
    out = {"home": (1892, 91, 365)}
    try:
        for line in open(PADS_FILE, encoding="utf-8"):
            m = re.search(r'name = "(\w+)".*?x = (-?\d+), y = (-?\d+), z = (-?\d+)', line)
            if m:
                out[m.group(1)] = (int(m.group(2)), int(m.group(3)), int(m.group(4)))
    except OSError:
        pass
    return out


def num(row, key):
    v = row.get(key)
    try:
        return float(v)
    except (TypeError, ValueError):
        return 0.0


def read(path, places):
    rows = list(csv.DictReader(open(path, encoding="utf-8", errors="replace")))
    if not rows or "phase" not in rows[0]:
        return None
    body = [r for r in rows if not (r.get("phase") or "").startswith("end")]
    if not body:
        return None
    base = os.path.basename(path)
    f = {"file": base, "date": base[:10], "time": base[11:19], "rows": len(body)}

    # how it ended. No end row at all means the computer stopped: a chunk
    # unload, a server restart, a crash - the thrusters lose their throttle.
    ends = [r for r in rows if (r.get("phase") or "").startswith("end")]
    end = ends[-1]["phase"] if ends else None
    if end is None:
        f["end"] = "NO END ROW"
    elif end.startswith("end:ok"):
        f["end"] = "ok"
    elif "tumbled" in end:
        f["end"] = "tumbled"
    elif "Terminated" in end:
        f["end"] = "stopped by hand"
    else:
        f["end"] = re.sub(r"\s*\[.*$", "", end)[:50]
    f["endfull"] = end or ""
    # a flight that kept going after the log stopped: the budget ran out
    f["logged_to"] = num(body[-1], "t")
    f["ran_to"] = num(ends[-1], "t") if ends else f["logged_to"]

    f["phases"] = []
    for r in body:
        if not f["phases"] or f["phases"][-1] != r["phase"]:
            f["phases"].append(r["phase"])
    f["dist"] = math.hypot(num(body[-1], "x") - num(body[0], "x"),
                           num(body[-1], "z") - num(body[0], "z"))
    f["vmax"] = max(math.hypot(num(r, "vxw"), num(r, "vzw")) for r in body)
    f["tilt0"] = math.hypot(num(body[0], "p"), num(body[0], "r"))
    f["rose"] = max(num(r, "height") for r in body) - num(body[0], "height")
    f["full_power_s"] = sum(1 for r in body if num(r, "pwr") > 0.95) * 0.1
    es = [num(r, "energy") for r in body if num(r, "energy") > 0]
    f["batt"] = (es[0], min(es), es[-1]) if es else None
    f["captures"] = sum(1 for p in f["phases"] if p == "capture")
    f["docked"] = "docked" in f["phases"]

    land = [r for r in body if r["phase"] == "land"]
    touch = [r for r in body if r["phase"] == "touchdown"]
    if land and touch:
        gx = num(land[-1], "x") + num(land[-1], "ex")
        gz = num(land[-1], "z") + num(land[-1], "ez")
        f["miss"] = math.hypot(num(touch[0], "x") - gx, num(touch[0], "z") - gz)
        f["landsecs"] = num(body[-1], "t") - num(land[0], "t")
        # contact: the sink rate over the rows just before the altitude settles
        rest = num(body[-1], "height")
        k0 = next(k for k, r in enumerate(body) if r["phase"] == "land")
        i = next((k for k, r in enumerate(body)
                  if k >= k0 and abs(num(r, "height") - rest) < 0.3), len(body) - 1)
        j = max(k0, i - 4)
        dt = num(body[i], "t") - num(body[j], "t")
        f["contact"] = -((num(body[i], "height") - num(body[j], "height")) / dt) if dt > 0 else 0.0
        f["pad"] = None
        for name, (px, py, pz) in places.items():
            if math.hypot(num(touch[0], "x") - px - 0.5, num(touch[0], "z") - pz - 0.5) <= NEAR_PAD:
                f["pad"], f["restgap"] = name, rest - py
                break
    return f


def load(since=None):
    places = pads()
    out = []
    for path in sorted(set(glob.glob(os.path.join(ROOT, "logs", "flights", "*.csv")))):
        if not os.path.basename(path)[:4].isdigit():
            continue
        if since and os.path.basename(path)[:10] < since:
            continue
        f = read(path, places)
        if f:
            out.append(f)
    return out


def median(xs):
    xs = sorted(xs)
    return xs[len(xs) // 2] if xs else float("nan")


def landings(fs):
    """Landings that followed a real transit - a hop proves nothing about aim."""
    return [f for f in fs if "miss" in f and f["vmax"] > CRUISED]


def report(fs, title):
    print("== %s: %d flights, %.1f hours, %.0f km travelled" % (
        title, len(fs), sum(f["logged_to"] for f in fs) / 3600, sum(f["dist"] for f in fs) / 1000))
    c = collections.Counter(f["end"] for f in fs)
    print("   ended:   " + ", ".join("%s %d" % kv for kv in c.most_common()))
    docks = [f for f in fs if f["captures"]]
    if docks:
        made = [f for f in docks if f["docked"]]
        print("   docking: %d attempts, %d latched, %.2f captures each" % (
            len(docks), len(made), sum(f["captures"] for f in made) / max(1, len(made))))
    ls = landings(fs)
    if ls:
        ms = [f["miss"] for f in ls]
        cs = [f["contact"] for f in ls]
        print("   landing: %d after a transit, miss median %.1f worst %.1f (%d within 5)" % (
            len(ls), median(ms), max(ms), sum(1 for m in ms if m <= 5)))
        print("            touchdown median %.1f b/s worst %.1f (%d under 5)" % (
            median(cs), max(cs), sum(1 for v in cs if v <= 5)))
    cru = [f["vmax"] for f in fs if f["vmax"] > CRUISED]
    if cru:
        print("   cruise:  %d transits, peak median %.0f b/s, best %.0f" % (
            len(cru), median(cru), max(cru)))
    per = [(f["batt"][0] - f["batt"][1]) / (f["dist"] / 1000)
           for f in fs if f["batt"] and f["dist"] > 1000]
    if per:
        print("   energy:  %.1f%% of a battery per 1000 blocks (median of %d legs)" % (
            median(per), len(per)))


def concerns(fs):
    print("== worth a look")
    for f in fs:
        why = []
        if f["end"] == "NO END ROW" and f["date"] >= END_ROW_SINCE:
            why.append("NO END ROW - the computer stopped: " + " -> ".join(f["phases"][-3:]))
        elif f["end"] not in ("ok", "stopped by hand", "NO END ROW"):
            why.append(f["end"] + ": " + " -> ".join(f["phases"][-3:]))
        if f["tilt0"] > 20:
            why.append("started tilted %.0f deg" % f["tilt0"])
        if f["rose"] < 3 and f["full_power_s"] > 20:
            why.append("never left the ground, %.0f s at full power" % f["full_power_s"])
        if f["ran_to"] - f["logged_to"] > 5:
            why.append("flew %.0f s past the end of its log" % (f["ran_to"] - f["logged_to"]))
        if f.get("miss", 0) > 10:
            why.append("landed %.0f blocks out" % f["miss"])
        if f.get("contact", 0) > 6:
            why.append("touched down at %.0f b/s" % f["contact"])
        if why:
            print("   %s %s  %s" % (f["date"], f["time"], "; ".join(why)))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--since", help="only flights from this date (YYYY-MM-DD)")
    ap.add_argument("--split", help="compare everything before this date with everything after")
    ap.add_argument("--days", action="store_true", help="a line per day")
    a = ap.parse_args(argv)

    fs = load(a.since)
    if not fs:
        print("no flightlogs found")
        return 1
    look = fs
    if a.split:
        report([f for f in fs if f["date"] < a.split], "before " + a.split)
        print()
        look = [f for f in fs if f["date"] >= a.split]
        report(look, a.split + " on")
    else:
        report(fs, "all flights" if not a.since else "since " + a.since)
    if a.days:
        print()
        byday = collections.defaultdict(list)
        for f in fs:
            byday[f["date"]].append(f)
        print("%-12s %4s %6s %7s  %s" % ("date", "n", "hours", "blocks", "ended"))
        for d in sorted(byday):
            g = byday[d]
            c = collections.Counter(f["end"] for f in g)
            print("%-12s %4d %6.1f %7.0f  %s" % (
                d, len(g), sum(f["logged_to"] for f in g) / 3600, sum(f["dist"] for f in g),
                ", ".join("%s %d" % kv for kv in c.most_common())))
    print()
    concerns(look)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
