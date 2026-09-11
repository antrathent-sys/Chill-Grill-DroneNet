#!/usr/bin/env python3
"""Run the lib/rs.lua tests.  python tools/run_rs_test.py"""
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
try:
    from lupa import LuaRuntime
except ImportError:
    print("needs lupa:  pip install lupa", file=sys.stderr); sys.exit(2)
L = LuaRuntime(unpack_returned_tuples=True)
entry = L.eval("function(s,d) local f=assert(loadfile(s)) return f(d) end")
try:
    entry(os.path.join(HERE, "test_rs.lua").replace("\\","/"), HERE.replace("\\","/"))
except Exception as exc:
    print(str(exc)); sys.exit(1)
