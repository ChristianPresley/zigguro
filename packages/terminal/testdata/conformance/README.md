# Terminal conformance corpus

Scripted `.vtt` cases that run headlessly against `zg_terminal.Terminal`:

```sh
zig build test-terminal-conformance
```

Every case gets a fresh terminal. After each step the runner checks the terminal's invariants (page tables, refcounts, wide-character pairs, cursor and margin bounds, pending wrap, live pins). A failing case prints its file and line, its cite, the expectation that failed, and the actual screen, cursor and unread replies.

The cases come from reading ctlseqs, the DEC VT510 manual and the Unicode standards, and from the *ideas* behind vttest and esctest. Do not copy code or text from those projects.

## File format

A file is UTF-8 text, one directive per line. `#` starts a comment line. The first directive must be `@cite`, naming the spec section the cases check. `@case <name>` starts a new case; a file without `@case` is one case named after the file.

```
# Erasing to the end of the line.
@cite https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h3-Functions-using-CSI-_-ordered-by-the-final-character_s_

@case EL 0 erases to the end of the line
@size 10x2
@send "abcdef\e[1;4H\e[K"
@expect-screen
|abc·······|
@expect-cursor 1,4
```

### Strings

`@send`, `@expect-reply` and `@expect-title` take a double-quoted string with these escapes:

| Escape | Byte(s) |
|---|---|
| `\e` | ESC (0x1B) |
| `\r` `\n` `\t` `\a` | CR, LF, HT, BEL |
| `\\` `\"` `\^` | a literal backslash, quote or caret |
| `\xHH` | the byte 0xHH (it may be invalid UTF-8 on purpose) |
| `\u{H+}` | the code point, UTF-8 encoded |
| `^X` | control X for X in `@`-`_` (`^[` is ESC, `^H` is BS); `^?` is DEL |

Any other escape, or a caret before anything else, is a syntax error.

### Directives

| Directive | Meaning | Example |
|---|---|---|
| `@size COLSxROWS` | Terminal size. Before the first other step it sets the initial size (default 80x24); later it resizes | `@size 10x3` |
| `@send "..."` | Feed bytes to the terminal | `@send "\e[2J"` |
| `@send-file PATH` | Feed a file from this directory tree (path relative to `testdata/conformance/`) | `@send-file core/data/big.bin` |
| `@resize COLSxROWS` | Resize the terminal | `@resize 5x3` |
| `@mode-2027 on\|off` | Grapheme-cluster width mode (DEC mode 2027) | `@mode-2027 on` |
| `@expect-screen` | The following `\|...\|` lines are the top rows of the screen, every cell written out; rows not listed must be blank | see below |
| `@expect-scrollback` | The following `\|...\|` lines are all the scrollback rows, oldest first; no lines means no scrollback | see below |
| `@expect-cursor ROW,COL` | 1-based cursor position | `@expect-cursor 2,5` |
| `@expect-reply "..."` | The bytes the terminal sent back since the last matching `@expect-reply` | `@expect-reply "\e[0n"` |
| `@expect-cell ROW,COL ATTR...` | Cell attributes, see below | `@expect-cell 1,1 bold fg=1` |
| `@expect-title "..."` | The window title | `@expect-title "vim"` |
| `@expect-mark L at ROW` | The next shell mark with letter L is on 1-based active row ROW | `@expect-mark A at 1` |

Screen rows show exactly one entry per cell: `·` is an empty cell (also the filler left when a wide character wraps), `‹` is the right half of a wide character, and a cell with combining marks shows the whole cluster. For example, `日` followed by `x` on a 5-column row is `|日‹x··|`.

Mark letters follow OSC 133: `A` prompt start, `B` input start, `C` command executed, `D` command finished, `E` command line (OSC 633), `P` property, `W` working directory, `M` bookmark.

### Cell attributes

`@expect-cell` checks only the attributes it lists:

- Flags: `bold`, `faint`, `italic`, `blink`, `inverse`, `invisible`, `strike`, `overline`. Prefix `!` to require one is off (`!bold`).
- `underline` (any style) or `underline=single|double|curly|dotted|dashed|none`.
- Colours `fg=`, `bg=` and `ul=` (underline colour): `default`, a palette index `0`-`255`, or `rgb:rrggbb`. `bg` includes the colour of cells erased with the background colour.
- `plain`: the default style.
- `wide`: the cell is the left half of a wide character.
- `char=X`: the cell's base code point.
- `link=URI` or `nolink`: the OSC 8 hyperlink.

## Categories

The first directory under `testdata/conformance/` is the case's category. Each category has a minimum number of cases. The conformance step warns while a category is short; `-Dterminal_conformance_strict` turns that into a failure (for once the E06 epic closes).

| Category | Minimum cases | Owner |
|---|---|---|
| core | 120 | E06.F02.S02, E06.F02.S03 |
| sgr | 40 | E06.F02.S02.T02 |
| modes | 30 | E06.F02.S02.T01 |
| reports | 25 | E06.F02.S02.T03 |
| osc | 40 | E06.F02.S02.T04 |
| unicode | 40 | E06.F03.S01 |
| reflow | 40 | E06.F03.S02 |
| input | 40 | E06.F04 (with `@key` steps) |
| marks | 25 | E06.F06 |

## Adding cases

1. Pick the category directory and a file named after the area (`core/erase.vtt`).
2. Start the file with `@cite`, then one `@case` per behaviour. Keep terminals small (10x3 is usually enough) so the screens stay readable.
3. Write the expectation from the spec, not from what the terminal does. When the terminal disagrees, fix the terminal or document the difference in `docs/deviations.md` and cite it.
4. Run `zig build test-terminal-conformance`. Files are discovered when the build runs; nothing else needs registering.
