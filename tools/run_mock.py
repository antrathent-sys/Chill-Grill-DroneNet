#!/usr/bin/env python3
"""Run fly.lua against the mock CC:Tweaked harness, without Minecraft.

    python tools/run_mock.py dock 100 50 70 90
    python tools/run_mock.py go 100 50
    python tools/run_mock.py --selftest

Environment switches the harness honours:
    GPS_QUANT=1    quantise gps.locate to whole blocks, as real CC does
    NOVEL=1        fit no velocity sensors, as the four-thruster airframe has
    DRIFT=1        make station keeping wander instead of parking exactly
    NODOCK=1       never let the magnet catch, to exercise the abort path
    START_DOCKED=1 begin the run already docked
    TMAX=<secs>    simulated-time budget

Needs a Lua runtime, via `pip install lupa`. This exercises the phase machine,
argument handling and the monitoring coroutine, and writes a real flightlog to
tools/mock_flightlog that logs/flightlog_summary.py can read.

It proves nothing about tuning: the drone model is a crude stand-in, not the
mod's physics.
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
HARNESS = os.path.join(HERE, "mock_cc.lua")

# fly.lua ships with DOCK_SIDE unset, so docking tests need a copy that has one
TEST_COPY = os.path.join(HERE, "_fly_under_test.lua")

SELFTEST = [
    ("fly hold", ["90"], {"TMAX": "40"}, ["fly"]),
    ("fly to xz", ["90", "20", "20"], {"TMAX": "40"}, ["fly"]),
    ("find", ["find", "0.55"], {"TMAX": "20"}, ["find"]),
    ("dash", ["dash", "90", "30", "4"], {"TMAX": "60"},
     ["climb", "dash", "brake", "hold"]),
    # go/dock: the continuous approach decelerates inside dash; no brake phase
    ("go", ["go", "100", "50", "90"], {"TMAX": "90"},
     ["climb", "dash", "hold"]),
    ("dock", ["dock", "100", "50", "70", "90"], {"TMAX": "120"},
     ["climb", "dash", "align", "descend", "capture", "docked"]),
    # DOCK_TRIES = 3, so capture is attempted three times before it gives up
    ("dock abort", ["dock", "100", "50", "70", "90"], {"TMAX": "300", "NODOCK": "1"},
     ["climb", "dash"] + ["align", "descend", "capture"] * 3 + ["hold"]),
    ("undock", ["undock", "80"], {"TMAX": "40", "START_DOCKED": "1"}, ["fly"]),
    # the four-thruster airframe carries no velocity sensors: body speed comes
    # from Sable world velocity rotated by the nav-table heading instead
    ("dock, no vel sensors", ["dock", "100", "50", "70", "90"], {"TMAX": "120", "NOVEL": "1"},
     ["climb", "dash", "align", "descend", "capture", "docked"]),
    # four thrusters: fly.lua must pick up lib/mixer.lua and hold attitude by
    # differential thrust (the mock's mixmap-free path uses CFG.MIX_MAP)
    ("quad dock", ["dock", "100", "50", "70", "90"], {"TMAX": "120", "NOVEL": "1", "QUAD": "1"},
     ["climb", "dash", "align", "descend", "capture", "docked"]),
    ("quad fly", ["50"], {"TMAX": "40", "QUAD": "1"}, ["fly"]),
    # the mock never yaws, so this only checks the spin schedule runs
    ("quad spin", ["spin", "80"], {"TMAX": "30", "QUAD": "1"}, ["fly"]),
]


def make_test_copy():
    src = open(os.path.join(ROOT, "fly.lua"), encoding="utf-8").read()
    out = src.replace("DOCK_SIDE = nil,", 'DOCK_SIDE = "bottom",')
    open(TEST_COPY, "w", encoding="utf-8", newline="\n").write(out)
    return TEST_COPY


def run(args, env, logpath):
    from lupa import LuaRuntime
    for k in ("NODOCK", "START_DOCKED", "TMAX", "NOVEL", "QUAD", "SPEAKER", "GPS_QUANT", "DRIFT", "UPLOAD_BOOM"):
        os.environ.pop(k, None)
    os.environ.update(env)
    os.environ["HARNESS_LOG"] = logpath
    L = LuaRuntime(unpack_returned_tuples=True)
    entry = L.eval("function(h, s, a) local f = assert(loadfile(h)) return f(s, a) end")
    lua_args = L.eval("{" + ",".join('"%s"' % a for a in args) + "}")
    entry(HARNESS, make_test_copy(), lua_args)


def phases_from(logpath):
    seen, order = None, []
    with open(logpath, encoding="utf-8") as fh:
        next(fh, None)
        for line in fh:
            parts = line.split(",")
            if len(parts) > 1 and parts[1] != seen:
                seen = parts[1]
                order.append(seen)
    return order


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--selftest", action="store_true",
                    help="run every mode and check the phase sequence")
    ap.add_argument("mode", nargs="*", help="arguments to pass to fly.lua")
    args = ap.parse_args(argv)

    if args.selftest:
        failures = 0
        for name, a, env, expect in SELFTEST:
            logpath = os.path.join(HERE, "mock_%s" % name.replace(" ", "_"))
            try:
                run(a, env, logpath)
                got = phases_from(logpath)
            except Exception as exc:
                print("FAIL  %-12s %s" % (name, str(exc)[:120]))
                failures += 1
                continue
            ok = got == expect
            failures += 0 if ok else 1
            print("%-5s %-12s %s" % ("ok" if ok else "FAIL", name, " -> ".join(got)))
            if not ok:
                print("      expected: %s" % " -> ".join(expect))
        print("\n%s" % ("all passed" if not failures else "%d failed" % failures))
        return 1 if failures else 0

    if not args.mode:
        ap.error("give fly.lua arguments, or --selftest")
    logpath = os.path.join(HERE, "mock_flightlog")
    run(args.mode, {"TMAX": "300"}, logpath)
    print("\nflightlog: %s" % logpath)
    print("phases: %s" % " -> ".join(phases_from(logpath)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
