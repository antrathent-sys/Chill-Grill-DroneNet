#!/usr/bin/env python3
"""Summarise a flightlog CSV written by fly.lua.

Usage:
    python logs/flightlog_summary.py path/to/flightlog [--rows N] [--phase NAME]

Prints one block per flight phase (climb / dash / brake / hold / fly / find)
with duration, altitude band, power, tilt, GPS fix ratio and energy drain,
then a table of N evenly spaced rows (default 25) so you can eyeball the trend
without opening the whole file.
"""
import argparse
import csv
import math
import statistics
import sys

# Columns parsed as numbers. Everything else stays a string.
NUM = ["t", "height", "err", "pwr", "gps", "x", "z", "ex", "ez", "vxw", "vzw",
       "hdg", "rawhdg", "mothdg", "tp", "tr", "p", "r", "vx", "vy", "sched",
       "fwdRaw", "latRaw", "vrtRaw", "fwdH", "latH", "energy"]

SAMPLE_COLS = ["t", "phase", "height", "err", "pwr", "gps", "x", "z",
               "hdg", "mothdg", "tp", "tr", "p", "r", "fwdH", "latH", "energy"]


def load(path):
    with open(path, newline="") as fh:
        rows = []
        for row in csv.DictReader(fh):
            for k in NUM:
                if k in row:
                    try:
                        row[k] = float(row[k])
                    except (TypeError, ValueError):
                        row[k] = math.nan
            rows.append(row)
    return rows


def phases_in_order(rows):
    """Contiguous phase segments in flight order. A phase name can recur."""
    segs = []
    for row in rows:
        if not segs or segs[-1][0] != row["phase"]:
            segs.append((row["phase"], []))
        segs[-1][1].append(row)
    return segs


def fmt(v, spec=".2f"):
    if v is None or (isinstance(v, float) and math.isnan(v)):
        return "-"
    return format(v, spec)


def summarise(name, seg):
    t0, t1 = seg[0]["t"], seg[-1]["t"]
    heights = [r["height"] for r in seg]
    pwr = [r["pwr"] for r in seg]
    tilt = [max(abs(r["p"]), abs(r["r"])) for r in seg]
    tilt_err = [abs(r["p"] - r["tp"]) + abs(r["r"] - r["tr"]) for r in seg]
    gps_ok = sum(1 for r in seg if r["gps"] == 1)
    fwd = [r["fwdH"] for r in seg]
    e0, e1 = seg[0].get("energy"), seg[-1].get("energy")

    print(f"== {name:<6} {t0:7.2f}s -> {t1:7.2f}s  ({t1 - t0:6.2f}s, {len(seg)} rows)")
    print(f"   height  min {fmt(min(heights))}  max {fmt(max(heights))}  "
          f"mean {fmt(statistics.fmean(heights))}  "
          f"start {fmt(heights[0])}  end {fmt(heights[-1])}")
    print(f"   alt err mean {fmt(statistics.fmean(r['err'] for r in seg))}  "
          f"worst {fmt(max(abs(r['err']) for r in seg))}")
    print(f"   power   mean {fmt(statistics.fmean(pwr), '.3f')}  "
          f"min {fmt(min(pwr), '.3f')}  max {fmt(max(pwr), '.3f')}")
    print(f"   tilt    max {fmt(max(tilt), '.1f')} deg  "
          f"mean |p-tp|+|r-tr| {fmt(statistics.fmean(tilt_err), '.1f')} deg")
    print(f"   fwd spd mean {fmt(statistics.fmean(fwd))}  "
          f"max {fmt(max(fwd))}  min {fmt(min(fwd))} b/s")
    print(f"   gps fix {gps_ok}/{len(seg)} rows ({100 * gps_ok / len(seg):.0f}%)")
    if e0 is not None and not math.isnan(e0) and e0 >= 0:
        print(f"   energy  {fmt(e0, '.0f')}% -> {fmt(e1, '.0f')}%  "
              f"({fmt(e1 - e0, '+.0f')}%)")
    print()


def print_samples(rows, n):
    if not rows:
        print("no rows to sample")
        return
    step = max(1, len(rows) // n)
    sample = rows[::step]
    if sample[-1] is not rows[-1]:
        sample.append(rows[-1])
    cols = [c for c in SAMPLE_COLS if c in rows[0]]
    widths = {c: max(len(c), 7) for c in cols}
    print(f"-- sampled rows (every {step} of {len(rows)}) --")
    print("  ".join(c.rjust(widths[c]) for c in cols))
    for r in sample:
        cells = []
        for c in cols:
            v = r[c]
            if isinstance(v, float):
                cells.append(fmt(v, ".1f").rjust(widths[c]))
            else:
                cells.append(str(v).rjust(widths[c]))
        print("  ".join(cells))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("path", help="flightlog CSV copied off the CC computer")
    ap.add_argument("--rows", type=int, default=25,
                    help="approximate number of sampled rows to print")
    ap.add_argument("--phase", help="only sample rows from this phase")
    args = ap.parse_args(argv)

    rows = load(args.path)
    if not rows:
        print("empty flightlog", file=sys.stderr)
        return 1

    print(f"flightlog: {args.path}")
    print(f"total {rows[-1]['t']:.2f}s, {len(rows)} rows, "
          f"phases: {' -> '.join(p for p, _ in phases_in_order(rows))}")
    print()
    for name, seg in phases_in_order(rows):
        summarise(name, seg)

    sample_rows = rows if not args.phase else [r for r in rows if r["phase"] == args.phase]
    print_samples(sample_rows, args.rows)
    return 0


if __name__ == "__main__":
    sys.exit(main())
