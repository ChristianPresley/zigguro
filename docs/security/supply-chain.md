# Supply-chain posture

Owner: E16. Spec: E16.F01.S02.T01. Threat model: [threat-model.md](threat-model.md).

**zigguro has zero third-party dependencies.** Every package depends only on other zigguro packages (by `.path`) and on the Zig standard library. There is no npm, PyPI or crates tree, no vendored C, no generated bindings and no transitive supply chain to compromise.

## What we depend on

- **The Zig toolchain**, pinned in `.github/zig-toolchain.txt` and verified with minisign before use (E00.F02, `tools/zig-verify`).
- **The operating system**: the Linux kernel ABI (syscalls only, no libc), and on Windows the system DLLs `kernel32`, `user32`, `gdi32`, `advapi32`, `userenv`, `crypt32`, `ntdll`, `ole32`, `oleaut32`, `shell32`, `imm32`, `dwmapi`, `uxtheme`, `shcore` and `ws2_32`.
- **The system Vulkan loader** (`vulkan-1.dll`, `libvulkan.so.1`), loaded at run time by name (E02), never linked.

## What we do not depend on

- Package registries of any kind; `build.zig.zon` files contain only `.path` dependencies.
- Vendored or generated foreign code. The only code generators are our own `tools/*` programs.
- libc. Packages are built with `link_libc = false` and `zg_build.addPackage` refuses otherwise.

## Enforcement

`zig build check-supply-chain` runs `tools/check-supply-chain` over the whole repository and fails on:

| Finding | Where |
|---|---|
| `url_dependency`, `hash_dependency` | a `.url` or `.hash` field in any `build.zig.zon` |
| `cimport` | `@cImport`, `@cInclude`, `@cDefine`, `@cUndef` |
| `link_libc` | `linkLibC` |
| `system_library` | `linkSystemLibrary` with a library outside the list above |
| `c_source`, `object_file`, `translate_c` | `addCSourceFile(s)`, `addObjectFile`, `addTranslateC` |

The scan tokenizes with `std.zig.Tokenizer`, so mentions inside comments and strings are ignored. Findings print as `path:line: kind: detail`. The check runs in the `lint` job of [CI](../../.github/workflows/ci.yml) on every pull request (see [ci.md](../ci.md)).

## Residual risk

- **The Zig toolchain and the OS.** Mitigated by pinning and signature verification; otherwise trusted.
- **User-installed tools.** MCP servers, language servers, debug adapters and shell tools the user installs are third-party code that zigguro runs. They are mitigated, not eliminated: they run under sandbox profiles (E16.F03, E16.F04), only after workspace trust (E16.F07.S01.T01), and MCP tool definitions are pinned (E16.F02.S04.T01).

## Reviewing a pull request for supply-chain impact

1. `zig build check-supply-chain` is green.
2. No new `extern` library names outside the OS list above.
3. No binary blobs, prebuilt objects or downloaded files under `packages/` or `tools/`.
4. Build scripts do not fetch anything at build time (`std.http` in `build.zig` is a red flag).
5. New `extern` declarations are reviewed by E16 (they widen the OS surface).
