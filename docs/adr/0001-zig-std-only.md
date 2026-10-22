# 0001. Zig 0.16 standard library only

Status: Accepted
Date: 2026-10-21

## Context

zigguro is an IDE and AI harness that must start in under 150 ms, stay responsive under load and be auditable end to end. Third-party code (C libraries, Zig packages, vendored sources) brings supply-chain risk, build complexity and behaviour we cannot tune. The platform still has to talk to the operating system: windows, input, sockets, processes, the GPU.

## Decision

- All code is Zig 0.16 using only the standard library. No `@cImport`, no C sources, no `.url` dependencies in any `build.zig.zon`, no vendored code, and no code generators other than ones we write in Zig under `tools/`.
- Operating-system interfaces are allowed and necessary: Win32 DLLs (kernel32, user32, ...), Linux syscalls, Wayland and X11 spoken directly over their sockets, and the system Vulkan loader (`vulkan-1.dll` / `libvulkan.so.1`) loaded at runtime. Packages never link libc (`zg_build.addPackage` asserts it).
- macOS needs MoltenVK (third-party) for Vulkan, so it gets a later Metal backend behind the same render interface.

## Consequences

- We write what std lacks: font rasterisation, shaping, regex, terminal emulation, git interop, protocol clients. The spec budgets for this.
- `zig build check-layers` rejects `.url` dependencies; reviews reject `@cImport`.
- Toolchain trust becomes the only external trust decision (ADR 0008).

## References

- [Zig 0.16.0 release notes](https://ziglang.org/download/0.16.0/release-notes.html)
- [Zig 0.16.0 standard library docs](https://ziglang.org/documentation/0.16.0/std/)
