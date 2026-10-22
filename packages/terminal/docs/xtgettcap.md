# XTGETTCAP

Generated from `src/term/dcs.zig` by `zig build docs-terminal-modes`; do not edit.

`DCS + q <hex name>[;<hex name>...] ST` is answered per name with
`DCS 1 + r <hex name>=<hex value> ST`, or `DCS 0 + r <hex name> ST` when the
name is unknown. Values follow terminfo conventions (`\E` is ESC); `Smulx`,
`Setulc` and `Sync` match kitty's and foot's terminfo entries, `Ms` is xterm's
OSC 52 capability.

| Name | Value |
|---|---|
| `TN` | `xterm-256color` |
| `name` | `xterm-256color` |
| `Co` | `256` |
| `colors` | `256` |
| `RGB` | `8/8/8` |
| `Smulx` | `\E[4:%p1%dm` |
| `Setulc` | `\E[58:2::%p1%{65536}%/%d:%p1%{256}%/%{255}%&%d:%p1%{255}%&%dm` |
| `Ms` | `\E]52;%p1%s;%p2%s^G` |
| `Sync` | `\E[?2026%?%p1%{1}%-%tl%eh%;` |
| `kbs` | `^?` |
