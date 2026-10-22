#!/usr/bin/env python3
"""Fills the `--- after` sections of Vim conformance files by running real Vim.

Usage: python3 -I oracle.py FILE...   (needs `vim` 9.x on PATH)

Each scenario's `before` text marks the cursor with `¦`; `keys` are Vim key
notation. Vim runs with `-u NONE` and the options in OPTIONS, the keys are fed
with feedkeys() followed by a <Cmd> that records the state, and the result is written back in the format the Zig tests
render: the text with `¦` for the cursor (normal, insert, replace mode; an
operator still pending counts as normal) or
`«…»` around the Visual area, then `[mode]` on its own line unless the mode is
normal, then `[reg TYPE] "TEXT"` when the scenario name ends in `+reg`, or
`[reg:X TYPE] "TEXT"` for each register X when it ends in `+reg:XYZ`.
Scenarios whose name starts with `mc:` (several cursors) are written by hand
and left alone.
"""

import json
import os
import subprocess
import sys
import tempfile

CARET = "¦"
OPTIONS = (
    "set nocompatible noswapfile shiftwidth=4 softtabstop=4 tabstop=4 expandtab "
    "autoindent backspace=indent,eol,start nojoinspaces whichwrap=b,s "
    "selection=inclusive virtualedit= nofoldenable nohlsearch noincsearch"
)
MODES = {"i": "insert", "R": "replace", "v": "visual", "V": "visual_line", "\x16": "visual_block"}


def parse(text):
    """Scenarios as (name, {section: body}) in file order."""
    out = []
    for chunk in ("\n" + text).split("\n=== ")[1:]:
        name, _, rest = chunk.partition("\n")
        secs = {}
        cur = None
        for line in rest.split("\n"):
            if line.startswith("--- "):
                cur = line[4:]
                secs[cur] = []
            elif cur is not None:
                secs[cur].append(line)
        out.append((name, {k: "\n".join(v).rstrip("\n") for k, v in secs.items()}))
    return out


def vim_string(keys):
    """Vim key notation as a double-quoted Vim string."""
    out = []
    i = 0
    while i < len(keys):
        c = keys[i]
        if c == "<":
            j = keys.find(">", i)
            if j > i + 1 and " " not in keys[i:j]:
                out.append("\\" + keys[i : j + 1])
                i = j + 1
                continue
        out.append("\\\\" if c == "\\" else '\\"' if c == '"' else c)
        i += 1
    return '"' + "".join(out) + '"'


def run(before, keys, regs=""):
    off = before.index(CARET)
    text = before.replace(CARET, "", 1)
    lines = text.split("\n")
    line = text[:off].count("\n")
    col = off - (text.rfind("\n", 0, off) + 1)
    with tempfile.TemporaryDirectory() as d:
        script = os.path.join(d, "t.vim")
        out = os.path.join(d, "out.json")
        with open(script, "w", encoding="utf-8") as f:
            f.write(OPTIONS + "\n")
            # The starting text is not a change "u" can undo.
            f.write("set undolevels=-1\n")
            f.write("call setline(1, " + json.dumps(lines, ensure_ascii=False) + ")\n")
            f.write("set undolevels=1000\n")
            f.write("call cursor(%d, %d)\n" % (line + 1, col + 1))
            # <Cmd> runs in whatever mode the keys left Vim in, without leaving it.
            f.write(
                "function Dump()\n  call writefile([json_encode({'m': mode(1), 'l': getline(1, '$'), "
                "'c': getcurpos(), 'v': getpos('v'), 'r': getreg('\"'), 't': getregtype('\"'), "
                "'x': map(split('" + regs + "', '\\zs'), {_, n -> [getreg(n), getregtype(n)]})})], '" + out + "')\nendfunction\n"
            )
            f.write("call feedkeys(" + vim_string(keys)[:-1] + "\\<Cmd>call Dump()\\<CR>\", 'tx')\n")
            f.write("qa!\n")
        subprocess.run(["vim", "-u", "NONE", "-i", "NONE", "-N", "-n", "-es", "-S", script],
                       stdin=subprocess.DEVNULL, timeout=20, check=False)
        with open(out, encoding="utf-8") as f:
            return json.load(f)


def offset(lines, lnum, col):
    """Byte offset of 1-based (lnum, col); col past the end clamps to the line end."""
    b = [len(l.encode()) for l in lines]
    base = sum(x + 1 for x in b[: lnum - 1])
    return base + min(col - 1, b[lnum - 1])


def render(r):
    lines = r["l"]
    data = "\n".join(lines).encode()
    m = r["m"]
    mode = MODES.get(m[0], "normal")
    cur = r["c"]
    marks = []
    if mode.startswith("visual"):
        (al, ac), (cl, cc) = (r["v"][1], r["v"][2]), (cur[1], cur[2])
        if mode == "visual_line":
            lo, hi = min(al, cl), max(al, cl)
            s = offset(lines, lo, 1)
            e = offset(lines, hi + 1, 1) if hi < len(lines) else len(data)
            marks = [(s, "«"), (e, "»")]
        elif mode == "visual_block":
            left, right = min(ac, cc) - 1, max(ac, cc) - 1
            to_eol = cur[4] >= 2147483647
            for ln in range(min(al, cl), max(al, cl) + 1):
                n = len(lines[ln - 1].encode())
                s = offset(lines, ln, left + 1)
                e = offset(lines, ln, n + 1) if to_eol else offset(lines, ln, right + 2)
                marks += [(s, "«"), (max(s, e), "»")]
        else:
            a = offset(lines, al, ac)
            c = offset(lines, cl, cc)
            lo, hi = min(a, c), max(a, c)
            hl = (al, ac) if a == hi else (cl, cc)
            n = len(lines[hl[0] - 1].encode())
            if hl[1] - 1 >= n:
                e = offset(lines, hl[0] + 1, 1) if hl[0] < len(lines) else len(data)
            else:
                ch = lines[hl[0] - 1].encode()[hl[1] - 1 :].decode(errors="ignore")[:1]
                e = hi + len(ch.encode())
            marks = [(lo, "«"), (e, "»")]
    else:
        marks = [(offset(lines, cur[1], cur[2]), CARET)]
    out = b""
    prev = 0
    for at, s in sorted(marks, key=lambda x: x[0]):
        out += data[prev:at] + s.encode()
        prev = at
    out += data[prev:]
    res = out.decode()
    if mode != "normal":
        res += "\n[" + mode + "]"
    return res


def main():
    for path in sys.argv[1:]:
        with open(path, encoding="utf-8") as f:
            scenarios = parse(f.read())
        parts = []
        for name, secs in scenarios:
            after = secs.get("after", "")
            if not name.startswith("mc:"):
                regs = name.rsplit("+reg:", 1)[1] if "+reg:" in name else ""
                r = run(secs["before"], secs["keys"], regs)
                after = render(r)
                if name.endswith("+reg"):
                    after += "\n[reg %s] %s" % (r["t"] if r["t"] in ("v", "V") else "b", json.dumps(r["r"], ensure_ascii=False))
                for n, (text, t) in zip(regs, r["x"]):
                    after += "\n[reg:%s %s] %s" % (n, t if t in ("v", "V") else "-" if t == "" else "b", json.dumps(text, ensure_ascii=False))
            parts.append("=== %s\n--- before\n%s\n--- keys\n%s\n--- after\n%s\n" % (name, secs["before"], secs["keys"], after))
        with open(path, "w", encoding="utf-8") as f:
            f.write("\n".join(parts))
        print("%s: %d scenarios" % (path, len(scenarios)))


if __name__ == "__main__":
    main()
