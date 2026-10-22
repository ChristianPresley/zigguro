# Vendored data

| File | Source | Version | License |
|------|--------|---------|---------|
| `keysymdef.h` | xorgproto, `include/X11/keysymdef.h` | 2023.2 | The Open Group / DEC permissive notice (MIT-style), reproduced at the top of the file |
| `XF86keysym.h` | xorgproto, `include/X11/XF86keysym.h` | 2023.2 | xorgproto `COPYING` (MIT-style X11 licenses) |

Both headers are copied unmodified. They are data only: `tools/keysym_gen`
reads them and writes `packages/platform/src/xkb/keysym_data.zig`. To update,
replace the headers with a newer xorgproto release and run
`zig build keysym-gen`; `zig build keysym-gen -- --check` fails when the
generated table is stale.
