"""Drag and disturbance versus relative yaw, from a cruise flown with YAW_SWEEP.

    python tools/yaw_sweep.py logs/flights/<log>.csv [bin_deg]

For every dash-phase sample the relative yaw is (course - heading): the angle
between where the craft is going and where its nose points. Samples are
binned by that angle and each bin reports mean speed, mean lean, speed per
degree of lean (higher = less drag), mean |yaw rate| and mean |yaw demand|
(disturbance the loop had to fight). The fin plane is where speed/lean peaks
and the yaw loop is quietest; the worst bins are the compound angles.
"""
import csv, math, sys
from collections import defaultdict


def main(path, binDeg=15):
    rows = [r for r in csv.DictReader(open(path, encoding="utf-8")) if r["phase"] == "dash"]
    bins = defaultdict(list)
    for r in rows:
        vx, vz = float(r["vxw"]), float(r["vzw"])
        sp = math.hypot(vx, vz)
        if sp < 10:
            continue
        course = math.degrees(math.atan2(vx, -vz)) % 360
        rel = (course - float(r["hdg"]) + 180) % 360 - 180
        lean = math.hypot(float(r["p"]), float(r["r"]))
        b = int(math.floor((rel + 180) / binDeg))
        bins[b].append((sp, lean, abs(float(r["yrate"])), abs(float(r["ydem"]))))
    print("%s  (%d cruise samples above 10 b/s)" % (path, sum(len(v) for v in bins.values())))
    print("rel yaw    n   speed  lean  speed/lean  |yrate|  |ydem|")
    best = None
    for b in sorted(bins):
        v = bins[b]
        n = len(v)
        sp = sum(x[0] for x in v) / n
        ln = sum(x[1] for x in v) / n
        yr = sum(x[2] for x in v) / n
        yd = sum(x[3] for x in v) / n
        ratio = sp / ln if ln > 1 else 0
        lo = -180 + b * binDeg
        print("%+4d..%+4d %4d  %5.1f  %5.1f   %6.2f     %5.1f   %5.2f" % (lo, lo + binDeg, n, sp, ln, ratio, yr, yd))
        if n >= 10 and (best is None or ratio > best[1]):
            best = (lo + binDeg / 2, ratio)
    if best:
        print("\nleast drag around relative yaw %+.0f deg (speed/lean %.2f). Set YAW_OFFSET so the nose sits there,"
              " or pick the axis for CRUISE_LEAN_AXIS: 0/180 -> pitch, +-90 -> roll, +-45/135 -> diagonal fins" % best)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    main(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 15)
