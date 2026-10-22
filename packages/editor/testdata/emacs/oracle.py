#!/usr/bin/env python3
"""Fills the `.after` of Emacs scenario files from real GNU Emacs.

Usage: python3 -I oracle.py motion.zon kill.zon ...

Each case runs in its own `emacs --batch -Q` as a keyboard macro over a
fundamental-mode buffer with transient-mark-mode on, no clipboard, an empty
kill ring and no undo history for the starting text. The keys are Vim
notation as zg_editor's key parser reads it (`<C-f>`, `<M-gt>`, `<CR>`) and
are turned into `kbd` syntax. An error or quit ends the macro there, as it
does in Emacs. The result is the text with `¦` at point and `«` at the mark
when it is active, then `[kill] "..."` (`+kill`), `[ring] [...]` (`+ring`)
or `[mark N]` (`+mark`, a byte offset or `-`), the strings written as
Python's json.dumps(ensure_ascii=False) writes them.

Each case is one line of the file:
    .{ .name = "...", .before = "...", .keys = "...", .after = "..." },
"""

import json
import os
import re
import subprocess
import sys
import tempfile

LINE = re.compile(r'^(\s*)\.\{ \.name = (".*?(?<!\\)"), \.before = (".*?(?<!\\)"), \.keys = (".*?(?<!\\)"), \.after = (".*?(?<!\\)") \},\s*$')

NAMES = {"cr": "RET", "enter": "RET", "return": "RET", "bs": "DEL", "esc": "ESC", "tab": "TAB",
         "space": "SPC", "del": "<deletechar>", "lt": "<", "gt": ">", "left": "<left>", "right": "<right>",
         "up": "<up>", "down": "<down>", "home": "<home>", "end": "<end>"}


def zig_decode(lit):
    """A Zig string literal's value."""
    s = lit[1:-1]
    out = []
    i = 0
    while i < len(s):
        c = s[i]
        if c != "\\":
            out.append(c)
            i += 1
            continue
        e = s[i + 1]
        if e == "n":
            out.append("\n")
            i += 2
        elif e == "t":
            out.append("\t")
            i += 2
        elif e == "r":
            out.append("\r")
            i += 2
        elif e == "x":
            out.append(chr(int(s[i + 2:i + 4], 16)))
            i += 4
        elif e == "u":
            j = s.index("}", i)
            out.append(chr(int(s[i + 3:j], 16)))
            i = j + 1
        else:
            out.append(e)
            i += 2
    return "".join(out)


def zig_encode(s):
    out = ['"']
    for c in s:
        if c == "\\":
            out.append("\\\\")
        elif c == '"':
            out.append('\\"')
        elif c == "\n":
            out.append("\\n")
        elif c == "\t":
            out.append("\\t")
        elif c == "\r":
            out.append("\\r")
        elif ord(c) < 0x20 or ord(c) == 0x7F:
            out.append("\\x%02x" % ord(c))
        else:
            out.append(c)
    out.append('"')
    return "".join(out)


def kbd(keys):
    """Vim key notation as an Emacs `kbd` string."""
    toks = []
    i = 0
    while i < len(keys):
        c = keys[i]
        if c == "<":
            j = keys.find(">", i + 1)
            body = keys[i + 1:j] if j > 0 else ""
            mods = ""
            rest = body
            while len(rest) > 2 and rest[1] == "-" and rest[0].lower() in "cmas":
                mods += {"c": "C-", "m": "M-", "a": "M-", "s": "S-"}[rest[0].lower()]
                rest = rest[2:]
            name = NAMES.get(rest.lower())
            if name is None and len(rest) == 1 and mods:
                name = rest.lower() if "C-" in mods else rest
            if name is not None and (mods or len(rest) > 1):
                if name.startswith("<") and len(name) > 1:
                    toks.append("<" + mods + name[1:])
                else:
                    toks.append(mods + name)
                i = j + 1
                continue
        toks.append({" ": "SPC", "\t": "TAB", "\n": "C-j"}.get(c, c))
        i += 1
    return " ".join(toks)


def elisp_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


PRELUDE = r"""
(require (quote json))
(setq interprogram-cut-function nil interprogram-paste-function nil select-enable-clipboard nil)
(transient-mark-mode 1)
(defun zg-run (text pt mk keys out)
  (switch-to-buffer (get-buffer-create "*zg*"))
  (erase-buffer) (fundamental-mode)
  (buffer-disable-undo) (insert text) (buffer-enable-undo)
  (goto-char pt) (set-marker (mark-marker) nil) (setq mark-ring nil) (deactivate-mark)
  (when mk (set-mark mk) (activate-mark))
  (setq kill-ring nil kill-ring-yank-pointer nil last-command nil
        search-ring nil regexp-search-ring nil query-replace-defaults nil)
  (condition-case nil (execute-kbd-macro (kbd keys)) (error nil) (quit nil))
  (let ((m (mark t)))
    (with-temp-buffer
      (insert (json-encode (list (cons "text" (with-current-buffer "*zg*" (buffer-string)))
                                 (cons "point" (with-current-buffer "*zg*" (1- (position-bytes (point)))))
                                 (cons "mark" (and m (with-current-buffer "*zg*" (1- (position-bytes m)))))
                                 (cons "active" (if (with-current-buffer "*zg*" mark-active) t :json-false))
                                 (cons "kills" (vconcat (mapcar #'substring-no-properties kill-ring))))))
      (insert "\n")
      (append-to-file (point-min) (point-max) out))))
"""


def parse_before(marked):
    text = []
    point = None
    mark = None
    i = 0
    while i < len(marked):
        if marked.startswith("¦", i):
            point = len("".join(text).encode())
            i += 1
        elif marked.startswith("«", i):
            mark = len("".join(text).encode())
            i += 1
        else:
            text.append(marked[i])
            i += 1
    return "".join(text), point, mark


def char_pos(text, byte_off):
    return len(text.encode()[:byte_off].decode()) + 1


def render(name, r):
    raw = r["text"].encode()
    marks = []
    if r["active"] and r["mark"] is not None:
        marks.append((r["mark"], 0, "«"))
    marks.append((r["point"], 1, "¦"))
    marks.sort()
    out = b""
    prev = 0
    for at, _, s in marks:
        out += raw[prev:at] + s.encode()
        prev = at
    out += raw[prev:]
    after = out.decode()
    if name.endswith("+kill"):
        after += "\n[kill] " + (json.dumps(r["kills"][0], ensure_ascii=False) if r["kills"] else "-")
    elif name.endswith("+ring"):
        after += "\n[ring] [" + ", ".join(json.dumps(k, ensure_ascii=False) for k in r["kills"]) + "]"
    elif name.endswith("+mark"):
        after += "\n[mark %s]" % ("-" if r["mark"] is None else r["mark"])
    return after


def main():
    for path in sys.argv[1:]:
        lines = open(path, encoding="utf-8").read().split("\n")
        cases = []
        for n, line in enumerate(lines):
            m = LINE.match(line)
            if m:
                cases.append((n, m))
        results = []
        with tempfile.TemporaryDirectory() as d:
            # One Emacs per case, so no state carries over.
            for _, m in cases:
                out = os.path.join(d, "out.json")
                el = os.path.join(d, "run.el")
                text, point, mark = parse_before(zig_decode(m.group(3)))
                with open(el, "w", encoding="utf-8") as f:
                    f.write(PRELUDE)
                    f.write("(zg-run %s %d %s %s %s)\n" % (
                        elisp_str(text), char_pos(text, point),
                        str(char_pos(text, mark)) if mark is not None else "nil",
                        elisp_str(kbd(zig_decode(m.group(4)))), elisp_str(out)))
                if os.path.exists(out):
                    os.remove(out)
                subprocess.run(["emacs", "--batch", "-Q", "-l", el], check=True, stdin=subprocess.DEVNULL,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                results.append(json.loads(open(out, encoding="utf-8").read()))
        assert len(results) == len(cases), (path, len(results), len(cases))
        for (n, m), r in zip(cases, results):
            name = zig_decode(m.group(2))
            lines[n] = "%s.{ .name = %s, .before = %s, .keys = %s, .after = %s }," % (
                m.group(1), m.group(2), m.group(3), m.group(4), zig_encode(render(name, r)))
        open(path, "w", encoding="utf-8").write("\n".join(lines))
        print("%s: %d cases" % (path, len(cases)))


main()
