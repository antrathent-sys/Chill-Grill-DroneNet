"""Reconstruct the thrust's WORLD direction from a flightlog and compare it
with the velocity, the cruise command and the start->target line.

The log stores the three navigation-table angles (nav4/5/7) and the gimbal
(p, r); lib/attitude.lua turns those into the attitude quaternion and
A.thrustWorld(q) into the thrust direction - the same solve the craft does
in flight. Use it to answer "where was the thrust actually pointing?"
without trusting the flat-table heading (garbage at lean).

  python tools/thrust_azimuth.py <flightlog> [<flightlog> ...]

Per flight: for every cruise row above 100 b/s with an attitude aim, the
azimuth of (a) the cruise law's command as reconstructed here, (b) the
actual thrust, both relative to the velocity; the slope of (b) on (a) is
the cross-steering authority (0.17-0.20 on 2026-09-13: the thrust follows
the velocity, whatever the cross command asks). Then per cruise leg the
off-line distance and per brake the thrust-vs-velocity azimuth at entry.
Needs lupa (Lua 5.1 runtime).
"""
import csv, math, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)


def load_att():
    from lupa.lua51 import LuaRuntime
    L = LuaRuntime(unpack_returned_tuples=True)
    L.execute("math.atan2 = math.atan2 or function(y, x) return math.atan(y, x) end; unpack = unpack or table.unpack")
    A = L.execute(open(os.path.join(REPO, "lib", "attitude.lua"), encoding="utf-8").read())
    pre = A.presets.airframe1
    ents = {str(e.name)[-1]: A.mountFrom(e) for _, e in pre.tables.items()}
    return L, A, ents, pre.gimbalSigns, A.vec.new(0, 0, -1)


def wrap(a):
    return (a + 540) % 360 - 180


def az(x, z):
    return math.degrees(math.atan2(x, -z))


def read(fn):
    rows = []
    with open(fn, encoding="utf-8", errors="replace") as fh:
        rd = csv.reader(fh)
        hdr = next(rd)
        for r in rd:
            if len(r) != len(hdr):
                continue
            try:
                rows.append({k: (float(v) if k != "phase" else v) for k, v in zip(hdr, r)})
            except ValueError:
                pass
    return rows


def main(files):
    L, A, ents, signs, tgt = load_att()

    def thrust(r):
        rd = L.table()
        n = 0
        for name in ("4", "5", "7"):
            v = r.get("nav" + name)
            if v is None or v <= -900:
                continue
            n += 1
            rd[n] = L.table(mount=ents[name], angle=v)
        if n < 2:
            return None
        q, _ = A.estimate(rd, L.table(pitch=r["p"], roll=r["r"], signs=signs), tgt)
        if q is None:
            return None
        t = A.thrustWorld(q)
        return t.x, t.y, t.z

    for fn in files:
        rows = read(fn)
        print("==", os.path.basename(fn))
        law, act = [], []
        prev = None
        legs = []
        for i, r in enumerate(rows):
            if r["phase"] == "cruise" and prev != "cruise":
                sx, sz = r["x"], r["z"]
                tx, tz = r["x"] + r["ex"], r["z"] + r["ez"]
                lx, lz = tx - sx, tz - sz
                ln = math.hypot(lx, lz)
                px, pz = (-lz / ln, lx / ln) if ln > 1 else (0, 0)
                legs.append([r["t"], 0.0])
            if r["phase"] == "cruise" and ln > 1:
                off = (r["x"] - sx) * px + (r["z"] - sz) * pz
                legs[-1][1] = max(legs[-1][1], abs(off))
                if math.hypot(r["vxw"], r["vzw"]) > 100 and r.get("aimq") == 1:
                    T = thrust(r)
                    if T:
                        velaz = az(r["vxw"], r["vzw"])
                        d = math.hypot(tx - r["x"], tz - r["z"])
                        ux, uz = (tx - r["x"]) / d, (tz - r["z"]) / d
                        vC = min(500, max(15, (d / 1.1 - 12) / 3.37))
                        ewx, ewz = vC * ux - r["vxw"], vC * uz - r["vzw"]
                        vl = -max(-25, min(25, 0.1 * off))
                        ewx, ewz = ewx + vl * px, ewz + vl * pz
                        law.append(wrap(az(ewx, ewz) - velaz))
                        act.append(wrap(az(T[0], T[2]) - velaz))
            if r["phase"] == "brake" and prev != "brake" and math.hypot(r["vxw"], r["vzw"]) > 100:
                T = thrust(r)
                if T:
                    print("  brake @ %6.1f  v0 %3.0f  thrust az - velocity az %+.0f deg" % (
                        r["t"], math.hypot(r["vxw"], r["vzw"]), wrap(az(T[0], T[2]) - az(r["vxw"], r["vzw"]))))
            prev = r["phase"]
        for t0, mo in legs:
            if mo > 0:
                print("  cruise @ %6.1f  max off-line %.0f blocks" % (t0, mo))
        if len(law) > 20:
            n = len(law)
            ma, mb = sum(law) / n, sum(act) / n
            cov = sum((a - ma) * (b - mb) for a, b in zip(law, act))
            va = sum((a - ma) ** 2 for a in law)
            vb = sum((b - mb) ** 2 for b in act)
            print("  cruise >100 b/s, %d rows: command az mean %+.1f, thrust az mean %+.1f (rel. velocity); "
                  "slope of thrust on command %+.2f, corr %+.2f" % (n, ma, mb, cov / va, cov / math.sqrt(va * vb)))


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    main(sys.argv[1:])
