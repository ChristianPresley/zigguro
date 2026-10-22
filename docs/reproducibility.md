# Reproducible release builds

Two builds of the same commit with the same `-Dversion`, `-Dcommit`, `-Dsource-date-epoch`, target and optimize mode should produce byte-identical release trees; `zg-release repro-compare <dirA> <dirB>` checks that (docs/release.md). This page lists what can make two builds differ, and what the release build does about it (E17.F01.S01.T02).

## Inputs that leak into binaries

- **Source paths in DWARF.** Debug info records absolute paths of the source tree and of the Zig standard library (for example `/opt/.../lib/std/process/Args.zig`). The shipped Linux binaries have no DWARF (they are split, docs/release.md "Debug symbols"), so this affects only the `.debug` files. CI builds from the fixed path `/build/zigguro` with the same Zig installation path so the symbol files reproduce too.
- **The GNU build-id** is SHA-1 over the linked output (`build_id = .sha1`), so it is deterministic and changes only when the binary does. The stripped binary keeps the note; the `.gnu_debuglink` CRC is computed over the `.debug` file, which is the unstripped binary, so it is deterministic too.
- **Archive timestamps, owners and modes** come from `SOURCE_DATE_EPOCH` and fixed values, never from the file system (docs/release.md "Archives").

## Windows

Release builds of the apps link through LLD:

- The PE `TimeDateStamp` is a hash of the output, not the wall clock, so it repeats between identical builds.
- The CodeView record's GUID is hash-derived too (its last eight bytes read `LLD PDB.`), so the PDB id in `BUILDINFO.zon` repeats as well.
- The CodeView record carries an empty PDB path, so no build directory leaks. Debuggers have to be pointed at the symbol directory: `.sympath+ <extracted symbols dir>` in WinDbg.
- The optional header `CheckSum` and the Authenticode certificate table are the only fields that differ after signing. `repro-compare` masks exactly those (`tools/release/src/pe_strip_sig.zig`).

No other field is masked. If a new difference shows up, list the field here, mask exactly it in `repro-compare` with a comment linking the upstream Zig issue, and keep the rest of the comparison byte-exact.
