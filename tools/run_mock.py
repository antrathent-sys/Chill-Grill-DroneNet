#!/usr/bin/env python3
"""Run fly.lua against the mock CC:Tweaked harness, without Minecraft.

    python tools/run_mock.py dock 100 50 70 90
    python tools/run_mock.py go 100 50
    python tools/run_mock.py --selftest

Environment switches the harness honours:
    GPS_QUANT=1    quantise gps.locate to whole blocks, as real CC does
    NOVEL=1        fit no velocity sensors, as the four-thruster airframe has
    DRIFT=1        make station keeping wander instead of parking exactly
    LEGS=x,z;x,z   places to fly to in turn, for a multi-leg mission
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
import re
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
    ("go", ["go", "100", "50", "90"], {"TMAX": "90"},
     ["climb", "dash", "brake", "hold"]),
    # from 120 the descent is staged: fall to pad+15, settle tight, then the
    # final 15. The other dock cases cruise at 90, below the staging height,
    # so they go straight down - both paths are covered.
    ("dock", ["dock", "100", "70", "50", "120"], {"TMAX": "150"},
     ["climb", "dash", "brake", "align", "descend", "align", "descend", "capture", "docked"]),
    # DOCK_TRIES = 3, so capture is attempted three times before it gives up
    ("dock abort", ["dock", "100", "70", "50", "90"], {"TMAX": "300", "NODOCK": "1"},
     ["climb", "dash", "brake"] + ["align", "descend", "capture"] * 3 + ["hold"]),
    ("undock", ["undock", "80"], {"TMAX": "40", "START_DOCKED": "1"}, ["fly"]),
    # the four-thruster airframe carries no velocity sensors: body speed comes
    # from Sable world velocity rotated by the nav-table heading instead
    ("dock, no vel sensors", ["dock", "100", "70", "50", "90"], {"TMAX": "120", "NOVEL": "1"},
     ["climb", "dash", "brake", "align", "descend", "capture", "docked"]),
    # four thrusters: fly.lua must pick up lib/mixer.lua and hold attitude by
    # differential thrust (the mock's mixmap-free path uses CFG.MIX_MAP)
    ("quad dock", ["dock", "100", "70", "50", "90"], {"TMAX": "120", "NOVEL": "1", "QUAD": "1"},
     ["climb", "dash", "brake", "align", "descend", "capture", "docked"]),
    # the magnet can take hold at any point once the connector is out, and
    # that ends the flight wherever we happen to be
    ("dock grabs early", ["dock", "100", "70", "50", "90"], {"TMAX": "120", "DOCK_EARLY": "1"},
     ["climb", "dash", "brake", "align", "docked"]),
    # the park height is typed 6 too low and the pad is solid: the descent can
    # only end by noticing it has stopped descending
    ("dock with a wrong pad height", ["dock", "100", "64", "50", "90"],
     {"TMAX": "150", "PAD_SOLID": "1"},
     ["climb", "dash", "brake", "align", "descend", "capture", "docked"]),
    # the real pad: latched, but getConnectedName reads "". Only the network
    # bridge gives it away, and the flight must still end.
    ("dock to an unnamed pad", ["dock", "100", "70", "50", "90"],
     {"TMAX": "150", "UNNAMED_PAD": "1"},
     ["climb", "dash", "brake", "align", "descend", "capture", "docked"]),
    # the worst case the real pad presents: the name reads "" AND the network
    # count never changes. Only the charge tells us, and the flight must end.
    ("dock to a silent pad", ["dock", "100", "70", "50", "90"],
     {"TMAX": "150", "UNNAMED_PAD": "1", "NO_BRIDGE": "1"},
     ["climb", "dash", "brake", "align", "descend", "capture", "docked"]),
    # the round trip: undock, cruise out, drop down to the release height,
    # release nothing, then cruise home and dock. Every leg is an ordinary
    # flight; the only new code is what decides the next one.
    ("deliver", ["deliver", "100", "80", "50", "90"],
     {"TMAX": "300", "START_DOCKED": "1", "LEGS": "100.5,50.5;0.5,0.5"},
     # it comes home from the drop height, so the approach passes down through
     # the lock window and the magnet takes hold during align - the same
     # ending as "dock grabs early", reached honestly
     ["climb", "dash", "brake", "hold", "fly",
      "climb", "dash", "brake", "align", "docked"]),
    ("quad fly", ["50"], {"TMAX": "40", "QUAD": "1"}, ["fly"]),
    # the mock never yaws, so this only checks the spin schedule runs
    ("quad spin", ["spin", "80"], {"TMAX": "30", "QUAD": "1"}, ["fly"]),
    # land: descend at a fixed rate, detect the ground, cut thrust
    ("land", ["land"], {"TMAX": "120"}, ["land", "touchdown"]),
    # the one that matters: land requested mid-flight, no restart
    ("land from cruise", ["go", "1000", "1000", "300"], {"TMAX": "150", "CMD_AT": "20:l"},
     ["climb", "dash", "land", "touchdown"]),
    ("hold from cruise", ["go", "1000", "1000", "300"], {"TMAX": "90", "CMD_AT": "20:h"},
     ["climb", "dash", "hold"]),
    ("quad land", ["land"], {"TMAX": "120", "QUAD": "1"}, ["land", "touchdown"]),
    # fly there, then land: the go machinery with a different ending
    # x y z, y being the ground at the far end. 100,50 is where the mock's
    # physics actually cruises to.
    ("land at xyz", ["land", "100", "64", "50"], {"TMAX": "200"},
     ["climb", "dash", "brake", "land", "touchdown"]),
]


def make_test_copy():
    src = open(os.path.join(ROOT, "fly.lua"), encoding="utf-8").read()
    # The mock's pad only watches the "bottom" side, so whatever DOCK_SIDE is
    # set to for the real airframe is rewritten here. This used to match the
    # literal `nil` and silently stopped matching when the real value became
    # "back", leaving START_DOCKED unable to report a dock at all.
    out, nsub = re.subn(r'DOCK_SIDE = (?:nil|"[a-z]+"),', 'DOCK_SIDE = "bottom",', src, count=1)
    if nsub != 1:
        raise SystemExit("run_mock: could not find DOCK_SIDE in fly.lua to rewrite")
    # the model's pad is at Y 70; the real home pad in CFG is wherever it is
    out, nsub = re.subn(r'HOME_X = -?\d+, HOME_Y = -?\d+, HOME_Z = -?\d+,', 'HOME_X = 0, HOME_Y = 70, HOME_Z = 0,', out, count=1)
    if nsub != 1:
        raise SystemExit("run_mock: could not find HOME_X/Y/Z in fly.lua to rewrite")
    open(TEST_COPY, "w", encoding="utf-8", newline="\n").write(out)
    return TEST_COPY


def run(args, env, logpath):
    from lupa import LuaRuntime
    for k in ("NODOCK", "START_DOCKED", "TMAX", "NOVEL", "QUAD", "SPEAKER", "GPS_QUANT", "DRIFT",
              "UPLOAD_BOOM", "LOSE_THRUSTER", "CMD_AT", "DOCK_EARLY", "PAD_SOLID",
              "UNNAMED_PAD", "NO_BRIDGE", "LEGS"):
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
    env = {"TMAX": os.environ.get("TMAX", "300")}
    # A delivery visits two places. The model has to be told both, because it
    # steers to a target rather than integrating the lean it is given.
    if args.mode[0] == "deliver" and len(args.mode) >= 4:
        env["LEGS"] = "%s,%s;0.5,0.5" % (float(args.mode[1]) + 0.5, float(args.mode[3]) + 0.5)
    run(args.mode, env, logpath)
    print("\nflightlog: %s" % logpath)
    print("phases: %s" % " -> ".join(phases_from(logpath)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
