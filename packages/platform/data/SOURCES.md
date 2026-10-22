# Vendored data

| File | Source | Version | License |
|------|--------|---------|---------|
| `keysymdef.h` | xorgproto, `include/X11/keysymdef.h` | 2023.2 | The Open Group / DEC permissive notice (MIT-style), reproduced at the top of the file |
| `XF86keysym.h` | xorgproto, `include/X11/XF86keysym.h` | 2023.2 | xorgproto `COPYING` (MIT-style X11 licenses) |
| `../src/xkb/compose_fallback.Compose` | libX11, `nls/en_US.UTF-8/Compose` (Ubuntu libx11-data 2:1.8.7-1ubuntu0.1) | 1.8.7 | libX11 `COPYING` (X.Org MIT-style) |

Both headers are copied unmodified. They are data only: `tools/keysym_gen`
reads them and writes `packages/platform/src/xkb/keysym_data.zig`. To update,
replace the headers with a newer xorgproto release and run
`zig build keysym-gen`; `zig build keysym-gen -- --check` fails when the
generated table is stale.

`src/xkb/compose_fallback.Compose` (kept beside the code so it can be embedded) is the subset of libX11's en_US.UTF-8 Compose
file whose rules are a dead key followed by a letter or space, selected with
`grep -E '^<dead_[a-z_]+>[[:space:]]+<([a-zA-Z]|space)>[[:space:]]*:'`. It is
embedded as the built-in compose table for systems without Compose files.
