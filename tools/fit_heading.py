"""Fit the craft's true heading from a flightlog: which way does it move
when it pitches, and which way when it rolls?

    python tools/fit_heading.py logs/flights/<log>.csv [more logs]

For each log a 2x2 least-squares map from (pitch, roll) to Sable world
velocity a little later gives the world bearing the craft travels for
pitch+ and for roll+. Across logs, the pitch+ bearing must move by the same
amount as the nav table's raw angle (HDG_SIGN +1) or by the negative of it
(HDG_SIGN -1), and HDG_OFFSET is whatever makes heading = HDG_SIGN*raw +
OFFSET equal the flight-derived heading in every log.

Heading convention (fly.lua): 0 = north (-z), 90 = east (+x). With
PITCH_DIR = -1 and ROLL_DIR = 1 as tuned, the controller's "heading" is the
bearing OPPOSITE the pitch+ travel direction, and roll+ must move the craft
to starboard of that; the script prints both so a wrong DIR shows up.

2026-09-10, quad frame: two flights gave pitch+ bearings 164 and 295 while
the raw table moved 285 -> 154, i.e. mirrored; offset 269 from both.
"""
import csv, math, sys
import numpy as np


def load(path):
    with open(path, encoding="utf-8") as fh:
        return list(csv.DictReader(fh))


def bearing(v):
    return math.degrees(math.atan2(v[0], -v[1])) % 360


def fit(rows, lag=15, skip=120):
    X, Y = [], []
    for i in range(skip, len(rows) - lag):
        r0, r1 = rows[i], rows[i + lag]
        X.append([float(r0["p"]), float(r0["r"])])
        Y.append([float(r1["vxw"]), float(r1["vzw"])])
    M = np.linalg.lstsq(np.array(X), np.array(Y), rcond=None)[0].T
    return bearing(M[:, 0]), bearing(M[:, 1]), np.linalg.norm(M[:, 0]), np.linalg.norm(M[:, 1])


def main(paths):
    results = []
    for p in paths:
        rows = load(p)
        pb, rb, kp, kr = fit(rows)
        # the log's rawhdg column already has HDG_SIGN/HDG_OFFSET applied; the
        # raw table angle itself is not logged, so ask for what the run used
        print("%s" % p)
        print("  pitch+ travels toward bearing %5.0f  (%.2f b/s per deg)" % (pb, kp))
        print("  roll+  travels toward bearing %5.0f  (%.2f b/s per deg)" % (rb, kr))
        side = (rb - pb) % 360
        print("  roll+ is %s of pitch+ (%.0f)" % ("starboard" if 45 < side < 135 else "port" if 225 < side < 315 else "??", side))
        print("  controller heading (PITCH_DIR -1, ROLL_DIR 1 convention): %5.0f" % ((pb + 180) % 360))
        results.append((p, (pb + 180) % 360))
    if len(results) > 1:
        print("\nacross logs the controller heading moved by:")
        for (pa, ha), (pb_, hb) in zip(results, results[1:]):
            print("  %+.0f deg  (%s -> %s); compare with the raw nav table change - same sign: HDG_SIGN +1, opposite: -1"
                  % (((hb - ha + 180) % 360) - 180, pa, pb_))


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    main(sys.argv[1:])
