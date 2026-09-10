#!/usr/bin/env python3
"""Run the upload.lua test suite against a mocked GitHub API.

    python tools/run_upload_test.py

Needs `pip install lupa`. Covers request shape, base64 round trip, sha handling
for new versus existing files, downsampling, sync mode and the failure paths.
It does not touch the network, so it cannot prove the token or the real API
accepts the request; that needs one live run in game.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def main():
    try:
        from lupa import LuaRuntime
    except ImportError:
        print("needs lupa:  pip install lupa", file=sys.stderr)
        return 2
    L = LuaRuntime(unpack_returned_tuples=True)
    entry = L.eval("function(s, d) local f = assert(loadfile(s)) return f(d) end")
    try:
        entry(os.path.join(HERE, "test_upload.lua").replace("\\", "/"),
              HERE.replace("\\", "/"))
    except Exception as exc:
        print(str(exc))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
