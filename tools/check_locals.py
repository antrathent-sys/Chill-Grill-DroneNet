#!/usr/bin/env python3
"""Fail if any function in the deployed Lua files declares too many locals.

    python tools/check_locals.py [--limit N]

CC:Tweaked's Lua (Cobalt) refuses to compile a function with more than 200
local variables, and it counts them differently from the desktop Luas the
harness runs: those count only locals in scope at once (fly.lua's flight loop
peaks at ~103), while Cobalt tripped on 2026-09-13 at the running total of
every local DECLARED in the function - including the three hidden slots each
`for` loop takes - which had reached ~202. The craft printed "function at
line 1313 has more than 200 local variables" and would not start, although
every desktop Lua compiled the file.

This counts, for every function (and each file's main chunk): parameters,
every name in every `local` statement, every `local function`, and every
for-loop variable plus 3 hidden slots. Nested function bodies count toward
their own function, not their parent. The default limit leaves a margin,
because this count is an approximation of Cobalt's.
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
KW = {"and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if",
      "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while"}


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
        m = re.match(r"0[xX][0-9a-fA-F]+|\d+\.?\d*(?:[eE][+-]?\d+)?", src[i:])
        if m:
            out.append(("num", None, line)); i += len(m.group(0)); continue
        out.append(("op", c, line)); i += 1
    return out


def scan(T, k, results, label, line):
    """Count one function body starting at token k (just after its ')').
    Returns the index after its closing 'end' (or len(T) for a main chunk)."""
    count = 0
    depth = 1
    main = label == "main chunk"
    while k < len(T):
        typ, w, ln = T[k]
        if typ == "kw":
            if w == "function":
                k = open_function(T, k, results)
                continue
            if w == "local":
                if T[k + 1][1] == "function":
                    count += 1
                    k = open_function(T, k + 1, results)
                    continue
                j = k + 1
                while T[j][0] == "name":
                    count += 1; j += 1
                    if T[j][1] == ",":
                        j += 1
                    else:
                        break
                k = j; continue
            if w == "for":
                j = k + 1
                while not (T[j][0] == "kw" and T[j][1] == "in") and T[j][1] != "=":
                    if T[j][0] == "name":
                        count += 1
                    j += 1
                count += 3
                while not (T[j][0] == "kw" and T[j][1] == "do"):
                    j += 1
                depth += 1; k = j + 1; continue
            if w == "while":
                j = k + 1
                while not (T[j][0] == "kw" and T[j][1] == "do"):
                    j += 1
                depth += 1; k = j + 1; continue
            if w in ("do", "repeat", "then"):
                depth += 1; k += 1; continue
            if w == "elseif":
                depth -= 1; k += 1; continue
            if w in ("end", "until"):
                depth -= 1
                if depth == 0 and not main:
                    results.append((count, label, line))
                    return k + 1
                k += 1; continue
        k += 1
    results.append((count, label, line))
    return k


def open_function(T, k, results):
    """T[k] is 'function'. Count its parameters, then its body."""
    line = T[k][2]
    j = k + 1
    name = []
    while T[j][1] != "(":
        if T[j][0] == "name":
            name.append(T[j][1])
        j += 1
    j += 1
    params = 0
    while T[j][1] != ")":
        if T[j][0] == "name":
            params += 1
        j += 1
    before = len(results)
    end = scan(T, j + 1, results, "function " + (".".join(name) or "(anonymous)"), line)
    # scan appended this function last; add its parameters
    c, lab, ln = results[-1]
    results[-1] = (c + params, lab, ln)
    return end


def deployed_files():
    src = open(os.path.join(ROOT, "startup.lua"), encoding="utf-8").read()
    m = re.search(r"local FILES\s*=\s*\{(.*?)\}", src, re.S)
    return re.findall(r'"([^"]+\.lua)"', m.group(1))


def main(argv):
    limit = 180
    if "--limit" in argv:
        limit = int(argv[argv.index("--limit") + 1])
    worst = []
    for rel in deployed_files():
        path = os.path.join(ROOT, rel)
        if not os.path.exists(path):
            continue
        T = tokens(open(path, encoding="utf-8").read())
        results = []
        scan(T, 0, results, "main chunk", 1)
        for c, lab, ln in results:
            worst.append((c, rel, lab, ln))
    worst.sort(reverse=True)
    print("most locals declared per function (limit %d; Cobalt refuses past 200):" % limit)
    for c, rel, lab, ln in worst[:6]:
        print("  %4d  %s:%d  %s" % (c, rel, ln, lab))
    over = [w for w in worst if w[0] > limit]
    if over:
        print("FAIL: %d function(s) over %d" % (len(over), limit))
        return 1
    print("ok")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
