#!/usr/bin/env python3
"""Fail if any function in the deployed Lua files could hit CC's local limit.

    python tools/check_locals.py [--limit N] [file.lua ...]

CC:Tweaked's Lua compiler (Cobalt) refuses a file with "function at line N has
more than 200 local variables". Its check, in Parser.newLocal, is

    checkLimit(fs, activeVariableSize + 1, LUAI_MAXVARS, "local variables")

and activeVariableSize is a field of the PARSER, shared by every function
being compiled at once: it is not reset per function (Lua 5.2 subtracts the
function's first local; Cobalt does not). So the number that must stay at or
under 200 is: every local in scope in all the ENCLOSING functions at the point
a function is defined, plus that function's own locals in scope at its deepest
point. That is why flyLeg, unchanged, stopped compiling on 2026-09-17 when the
pads feature added five top-level locals above it in fly.lua.

This counts it the same way, scope by scope: parameters (plus `self` for
`function a:b()` and one for `...`), every name in a `local` statement,
`local function` names (in scope inside their own body), each for loop's
variables plus its 3 hidden control slots, all released when their block ends
(do, then/elseif/else, while, for, repeat..until, function). The report
names the function being compiled when the count peaks, as Cobalt would.
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
KW = {"and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if",
      "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while"}
COBALT_MAX = 200


def tokens(src):
    i, n, line, out = 0, len(src), 1, []
    while i < n:
        c = src[i]
        if c == "\n":
            line += 1; i += 1; continue
        if c.isspace():
            i += 1; continue
        if src.startswith("--", i):
            m = re.match(r"--\[(=*)\[", src[i:])
            if m:
                close = "]" + m.group(1) + "]"; j = src.find(close, i)
                j = n if j < 0 else j + len(close); line += src.count("\n", i, j); i = j
            else:
                j = src.find("\n", i); i = n if j < 0 else j
            continue
        m = re.match(r"\[(=*)\[", src[i:])
        if m:
            close = "]" + m.group(1) + "]"; j = src.find(close, i)
            j = n if j < 0 else j + len(close); line += src.count("\n", i, j)
            out.append(("str", None, line)); i = j; continue
        if c in "\"'":
            j = i + 1
            while j < n and src[j] != c:
                if src[j] == "\\":
                    j += 1
                j += 1
            out.append(("str", None, line)); i = j + 1; continue
        m = re.match(r"[A-Za-z_][A-Za-z0-9_]*", src[i:])
        if m:
            w = m.group(0); out.append(("kw" if w in KW else "name", w, line)); i += len(w); continue
        if src.startswith("...", i):
            out.append(("op", "...", line)); i += 3; continue
        m = re.match(r"0[xX][0-9a-fA-F]+|\d+\.?\d*(?:[eE][+-]?\d+)?", src[i:])
        if m:
            out.append(("num", None, line)); i += len(m.group(0)); continue
        out.append(("op", c, line)); i += 1
    return out


class Frame:
    def __init__(self, label, line):
        self.label, self.line, self.scopes, self.peak, self.peakLine = label, line, [], 0, line


def analyse(T):
    """Returns [(peak active locals incl. enclosing functions, label, line, own peak line)]."""
    frames = [Frame("main chunk", 1)]
    frames[0].scopes.append(0)
    results = []
    active = 0

    def add(n, ln):
        nonlocal active
        f = frames[-1]
        f.scopes[-1] += n
        active += n
        if active > f.peak:
            f.peak, f.peakLine = active, ln

    def push():
        frames[-1].scopes.append(0)

    def pop():
        nonlocal active
        f = frames[-1]
        active -= f.scopes.pop()
        if not f.scopes:
            results.append((f.peak, f.label, f.line, f.peakLine))
            frames.pop()

    def open_function(k, local_name):
        # T[k] is 'function'; returns the index after the parameter list
        line = T[k][2]
        j = k + 1
        name, method = [], False
        while T[j][1] != "(":
            if T[j][0] == "name":
                name.append(T[j][1])
            if T[j][1] == ":":
                method = True
            j += 1
        j += 1
        params = 1 if method else 0
        while T[j][1] != ")":
            if T[j][0] == "name" or T[j][1] == "...":
                params += 1
            j += 1
        label = "function " + (local_name or ".".join(name) or "(anonymous)")
        frames.append(Frame(label, line))
        push()
        add(params, line)
        return j + 1

    k = 0
    while k < len(T):
        typ, w, ln = T[k]
        if typ != "kw":
            k += 1; continue
        if w == "function":
            k = open_function(k, None); continue
        if w == "local":
            if T[k + 1][1] == "function":
                add(1, ln)                       # in scope inside its own body
                k = open_function(k + 1, T[k + 2][1]); continue
            j, n = k + 1, 0
            while T[j][0] == "name":
                n += 1; j += 1
                if T[j][1] == ",":
                    j += 1
                else:
                    break
            add(n, ln)
            k = j; continue
        if w == "for":
            j, n = k + 1, 0
            while not (T[j][0] == "kw" and T[j][1] == "in") and T[j][1] != "=":
                if T[j][0] == "name":
                    n += 1
                j += 1
            while not (T[j][0] == "kw" and T[j][1] == "do"):
                j += 1
            push()
            add(n + 3, ln)
            k = j + 1; continue
        if w == "while":
            j = k + 1
            while not (T[j][0] == "kw" and T[j][1] == "do"):
                j += 1
            push()
            k = j + 1; continue
        if w in ("do", "repeat", "then"):
            push(); k += 1; continue
        if w == "elseif":
            pop(); k += 1; continue          # its `then` opens the next block
        if w == "else":
            pop(); push(); k += 1; continue
        if w in ("end", "until"):
            pop(); k += 1; continue
        k += 1
    while frames:
        f = frames[-1]
        active -= sum(f.scopes)
        results.append((f.peak, f.label, f.line, f.peakLine))
        frames.pop()
    return results


def deployed_files():
    src = open(os.path.join(ROOT, "startup.lua"), encoding="utf-8").read()
    m = re.search(r"local FILES\s*=\s*\{(.*?)\}", src, re.S)
    return re.findall(r'"([^"]+\.lua)"', m.group(1))


def check(paths, limit):
    worst = []
    for rel in paths:
        path = rel if os.path.isabs(rel) else os.path.join(ROOT, rel)
        if not os.path.exists(path):
            continue
        for peak, label, line, at in analyse(tokens(open(path, encoding="utf-8").read())):
            worst.append((peak, rel, label, line, at))
    worst.sort(reverse=True)
    return worst


def main(argv):
    limit = 190
    if "--limit" in argv:
        i = argv.index("--limit")
        limit = int(argv[i + 1])
        argv = argv[:i] + argv[i + 2:]
    paths = argv or deployed_files()
    worst = check(paths, limit)
    print("locals in scope when compiling each function, enclosing functions included")
    print("(limit %d; CC's compiler refuses past %d):" % (limit, COBALT_MAX))
    for peak, rel, label, line, at in worst[:6]:
        print("  %4d  %s:%d  %s  (peak at line %d)" % (peak, rel, line, label, at))
    over = [w for w in worst if w[0] > limit]
    if over:
        print("FAIL: %d function(s) over %d" % (len(over), limit))
        return 1
    print("ok")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
