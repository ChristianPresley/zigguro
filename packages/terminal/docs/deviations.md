# Deviations from xterm

zg_terminal follows xterm's ctlseqs and DEC VT510 semantics. Where it differs, the behaviour is listed here with the reason. The reference tables for modes and XTGETTCAP are generated: see [modes.md](modes.md) and [xtgettcap.md](xtgettcap.md).

## Erase and reset

| Behaviour | xterm | zg_terminal | Why |
|---|---|---|---|
| ED 2 (`CSI 2 J`) on the primary screen | Clears the screen; the rows are lost | Scrolls the rows up to the last non-blank row into scrollback, then clears (`terminal.clearPushesToScrollback`, default on) | Matches modern terminals (kitty, WezTerm, Windows Terminal), so `clear` never destroys output the user may want to scroll back to |
| RIS (`ESC c`) | Clears the screen; saved lines stay | Same by default; `terminal.risClearsScrollback` also erases scrollback | Keeps history unless the user opts in |
| DECSTR (`CSI ! p`) | Resets DECAWM according to the `autoWrap` resource | Sets DECAWM on | The spec's soft-reset list; every shell expects autowrap |
| DECCOLM (mode 3) | Resizes the window to 80/132 columns when allowed (mode 40) | Clears the screen, resets the margins and homes the cursor; never resizes | The view owns the window size |

## Cursor and screens

| Behaviour | xterm | zg_terminal | Why |
|---|---|---|---|
| DECSC/DECRC | No OSC 8 support, so nothing to save | The hyperlink is not saved; DECRC keeps the current link | Saving would need an owned copy of the URI per saved cursor for no known use |
| REP (`CSI b`) | Repeats the last graphic character even after intervening controls | No-op unless the previous action was a print | Avoids repeating stale characters after cursor motion (spec choice) |
| Alternate screen | One cursor shared by both screens | Each screen has its own cursor; switching copies position, attributes, charsets and margins | Same visible behaviour; per-screen state keeps the kitty keyboard stack separate, as kitty specifies |
| Resize | Reflows | Copies rows without reflow | Reflow lands with E06.F03.S02.T02 |

## Replies

| Behaviour | xterm | zg_terminal | Why |
|---|---|---|---|
| DA2 (`CSI > c`) | `CSI > 41 ; <patch> ; 0 c` | `CSI > 1 ; 10 ; 0 c` | A low, stable firmware number stops applications from inferring xterm patch-level quirks; use XTVERSION |
| Title reports (XTWINOPS 20/21) | Disabled by default (`allowTitleOps`) | Always ignored | Title injection: the reply would echo host-controlled bytes |
| Window operations (XTWINOPS 1-9) | Move, resize, iconify | Ignored | The view owns the window |
| XTGETTCAP | One reply for all valid names | One `DCS 1 + r` / `DCS 0 + r` reply per name | Simpler to parse; foot does the same |
| Reply volume | Unlimited | At most 64 KiB of replies per 1 MiB of input; excess replies are dropped with one warning | Prevents feedback storms when output is echoed back (for example `cat` of a file full of queries) |

## OSC, DCS and APC

| Behaviour | xterm | zg_terminal | Why |
|---|---|---|---|
| OSC 9 | Not supported | `9;4` progress and `9;9` cwd (ConEmu, Windows Terminal); other numeric ConEmu commands are ignored; any other text is a notification | Numeric commands such as message boxes and sleeps are not wanted from untrusted output |
| OSC 52 | Writes and reads per the `allowWindowOps`/`disallowedWindowOps` resources | Every write and read becomes an effect that the permission engine (E16) decides; reads are answered only after approval | Clipboard access from untrusted output must be policy-controlled |
| OSC 8 | Not supported | Supported with Egmont Koblinger's limits: URI at most 2083 bytes with a scheme, `id` at most 250 bytes | De facto standard |
| tmux passthrough (`DCS tmux; ... ST`) | Not applicable | Rejected | We are not tmux; forwarding would let output reach the outer terminal |
| APC | Ignored | Ignored until kitty graphics (E06.F08) | |
| 8-bit C1 controls | Recognised in 8-bit mode | Not recognised in UTF-8 mode (parser option `c1_8bit`) | In UTF-8, 0x80-0x9F are continuation bytes |
