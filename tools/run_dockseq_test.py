#!/usr/bin/env python3
"""Run the lib/dockseq.lua tests on Lua 5.1.  python tools/run_dockseq_test.py"""
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
try:
    from lupa.lua51 import LuaRuntime
except ImportError:
    print("needs lupa with Lua 5.1:  pip install lupa", file=sys.stderr); sys.exit(2)
L = LuaRuntime(unpack_returned_tuples=True, encoding=None)
entry = L.eval(b"function(s,d) local f=assert(loadfile(s)) return f(d) end")
try:
    entry(os.path.join(HERE, "test_dockseq.lua").replace("\\", "/").encode(), HERE.replace("\\", "/").encode())
except Exception as exc:
    msg = exc.args[0] if exc.args else exc
    print(msg.decode("latin-1") if isinstance(msg, bytes) else str(msg)); sys.exit(1)
