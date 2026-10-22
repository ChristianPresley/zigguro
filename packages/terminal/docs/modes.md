# Terminal modes

Generated from `src/term/modes.zig` by `zig build docs-terminal-modes`; do not edit.

Set with `CSI Pm h` (ANSI) or `CSI ? Pm h` (DEC), reset with `l`, query with DECRQM
(`CSI [?] Pd $ p`, reply `CSI [?] Pd ; Ps $ y`), save and restore DEC modes with
XTSAVE/XTRESTORE (`CSI ? Pm s` / `CSI ? Pm r`).

| Mode | Kind | Name | Default | DECRQM |
|---:|---|---|---|---|
| 4 | ANSI | `insert` | reset | 1 / 2 |
| 20 | ANSI | `linefeed` | reset | 1 / 2 |
| 1 | DEC | `cursor_keys` | reset | 1 / 2 |
| 3 | DEC | `column_132` | reset | 1 / 2 |
| 5 | DEC | `reverse_video` | reset | 1 / 2 |
| 6 | DEC | `origin` | reset | 1 / 2 |
| 7 | DEC | `autowrap` | set | 1 / 2 |
| 8 | DEC | `autorepeat` | set | 3 (permanently set) |
| 9 | DEC | `mouse_x10` | reset | 1 / 2 |
| 12 | DEC | `cursor_blink` | reset | 1 / 2 |
| 25 | DEC | `cursor_visible` | set | 1 / 2 |
| 40 | DEC | `allow_column_132` | reset | 1 / 2 |
| 45 | DEC | `reverse_wrap` | reset | 1 / 2 |
| 47 | DEC | `alt_screen_legacy` | reset | 1 / 2 |
| 66 | DEC | `keypad_numeric` | reset | 1 / 2 |
| 67 | DEC | `backarrow_bs` | reset | 1 / 2 |
| 69 | DEC | `left_right_margins` | reset | 1 / 2 |
| 80 | DEC | `sixel_display` | reset | 1 / 2 |
| 1000 | DEC | `mouse_normal` | reset | 1 / 2 |
| 1002 | DEC | `mouse_button` | reset | 1 / 2 |
| 1003 | DEC | `mouse_any` | reset | 1 / 2 |
| 1004 | DEC | `focus_events` | reset | 1 / 2 |
| 1005 | DEC | `mouse_utf8` | reset | 1 / 2 |
| 1006 | DEC | `mouse_sgr` | reset | 1 / 2 |
| 1007 | DEC | `alternate_scroll` | reset | 1 / 2 |
| 1015 | DEC | `mouse_urxvt` | reset | 1 / 2 |
| 1016 | DEC | `mouse_sgr_pixels` | reset | 1 / 2 |
| 1035 | DEC | `num_lock` | reset | 1 / 2 |
| 1036 | DEC | `meta_sends_escape` | set | 1 / 2 |
| 1039 | DEC | `alt_sends_escape` | reset | 1 / 2 |
| 1047 | DEC | `alt_screen` | reset | 1 / 2 |
| 1048 | DEC | `save_cursor` | reset | 1 / 2 |
| 1049 | DEC | `alt_screen_save` | reset | 1 / 2 |
| 2004 | DEC | `bracketed_paste` | reset | 1 / 2 |
| 2026 | DEC | `synchronized_output` | reset | 1 / 2 |
| 2027 | DEC | `grapheme_cluster` | reset | 1 / 2 |
| 2031 | DEC | `color_scheme_reports` | reset | 4 (permanently reset) |
| 2048 | DEC | `in_band_resize` | reset | 1 / 2 |
| 9001 | DEC | `win32_input` | reset | 1 / 2 |
| 5522 | DEC | `kitty_paste_events` | reset | 4 (permanently reset) |

Any other mode number reports 0 (not recognised).
