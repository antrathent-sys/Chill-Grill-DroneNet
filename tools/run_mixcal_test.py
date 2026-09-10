#!/usr/bin/env python3
"""Check mixcal derives the right corner map.  python tools/run_mixcal_test.py

The harness rig puts four thrusters at known corners of a 3x3 and reports the
tilt they would produce. mixcal is not told any of that, so if the map it
derives matches the rig's layout, the sign logic is right.
"""
import io, os, sys, contextlib
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
try:
    from lupa import LuaRuntime
except ImportError:
    print("needs lupa:  pip install lupa", file=sys.stderr); sys.exit(2)

# ground truth baked into the harness rig (n, s) per thruster
TRUTH = {"vector_thruster_5": (1, 1), "vector_thruster_6": (1, -1),
         "vector_thruster_7": (-1, 1), "vector_thruster_8": (-1, -1)}

for k in ("NODOCK", "START_DOCKED", "GPS_QUANT", "DRIFT", "UPLOAD_BOOM", "SPEAKER"):
    os.environ.pop(k, None)
os.environ.update({"TMAX": "200", "QUAD": "1",
                   "HARNESS_LOG": os.path.join(HERE, "_mixcal_out")})
L = LuaRuntime(unpack_returned_tuples=True)
entry = L.eval("function(h,s,a) local f=assert(loadfile(h)) return f(s,a) end")
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    entry(os.path.join(ROOT, "tools", "mock_cc.lua").replace("\\", "/"),
          os.path.join(ROOT, "mixcal.lua").replace("\\", "/"), L.eval("{}"))

# the csv lands in the harness log buffer
rows = [l.split(",") for l in
        open(os.path.join(HERE, "_mixcal_out"), encoding="utf-8").read().splitlines() if "," in l]
got = {r[0]: (float(r[1]), float(r[2]), r[3]) for r in rows if r[0].startswith("vector_thruster")}

fails = 0
corners = {}
for name, (n, s) in TRUTH.items():
    if name not in got:
        print("FAIL %s not measured" % name); fails += 1; continue
    dp, dr, corner = got[name]
    # lifting a +n corner must pitch one way and a +s corner roll one way;
    # the absolute sense does not matter, only that it is consistent
    ok_p = (dp < 0) == (n > 0)
    ok_r = (dr > 0) == (s > 0)
    corners.setdefault(corner, []).append(name)
    print("%-5s %-20s pitch %+6.2f roll %+6.2f -> %s" %
          ("ok" if (ok_p and ok_r) else "FAIL", name, dp, dr, corner))
    if not (ok_p and ok_r): fails += 1

dupes = {c: v for c, v in corners.items() if len(v) > 1}
print("%-5s four distinct corners" % ("FAIL" if dupes else "ok"))
if dupes:
    fails += 1
    print("      duplicates: %s" % dupes)
os.remove(os.path.join(HERE, "_mixcal_out"))
print("\n%d failed" % fails if fails else "\nall passed")
sys.exit(1 if fails else 0)
