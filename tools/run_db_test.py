#!/usr/bin/env python3
"""Run the lib/db.lua test suite outside Minecraft.

    python tools/run_db_test.py

Needs a Lua runtime, via `pip install lupa`. The test stubs CC's `fs` and
`textutils` over real files, so it exercises the actual library code including
seeking, appending, compaction and crash recovery.
"""
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))


def main():
    try:
        from lupa import LuaRuntime
    except ImportError:
        print("needs lupa:  pip install lupa", file=sys.stderr)
        return 2

    workdir = tempfile.mkdtemp(prefix="dronenet-db-")
    L = LuaRuntime(unpack_returned_tuples=True)
    entry = L.eval("function(script, dir) local f = assert(loadfile(script)) return f(dir) end")
    try:
        entry(os.path.join(HERE, "test_db.lua").replace("\\", "/"),
              _stage(workdir).replace("\\", "/"))
    except Exception as exc:
        print(str(exc))
        return 1
    return 0


def _stage(workdir):
    """The test reads ../lib/db.lua relative to the dir it is handed, so give it
    a scratch dir whose parent has the real library."""
    root = os.path.dirname(HERE)
    libsrc = os.path.join(root, "lib", "db.lua")
    dstlib = os.path.join(workdir, "lib")
    os.makedirs(dstlib, exist_ok=True)
    with open(libsrc, encoding="utf-8") as fh:
        body = fh.read()
    with open(os.path.join(dstlib, "db.lua"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write(body)
    scratch = os.path.join(workdir, "run")
    os.makedirs(scratch, exist_ok=True)
    return scratch


if __name__ == "__main__":
    sys.exit(main())
