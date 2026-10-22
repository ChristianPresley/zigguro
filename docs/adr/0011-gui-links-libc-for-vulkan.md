# 0011. The zigguro binary links libc on glibc Linux for Vulkan

Status: Accepted
Date: 2026-10-22

(Spec reference: ADR-E02-001, epic E02.F01.)

## Context

ADR 0001 lets us load the system Vulkan loader at runtime and keeps libc
out of every package. On Linux the loader (`libvulkan.so.1`) and every
installable client driver are shared objects linked against the system
libc. A static, libc-free executable cannot `dlopen` them: there is no
dynamic linker, no TLS setup for them and no libc for them to bind to.
Until this decision zigguro built that way, so on Linux `Loader.open`
returned `error.Unsupported` and only the software renderer could draw.

Options considered:

- Write our own ELF loader for libvulkan and its drivers. They expect a
  real glibc (TLS, `pthread`, `dlopen` of further drivers), so this
  amounts to reimplementing ld.so.
- Talk to the kernel driver directly (DRM ioctls). That is a per-vendor
  GPU driver, far outside the project.
- Link the system libc dynamically into the GUI executable only.

## Decision

- The `zigguro` executable sets `link_libc` when the target is Linux with
  a GNU ABI. It is then a dynamically linked executable whose only
  shared-library dependency is the system libc; libvulkan is opened at
  runtime with `dlopen`, as before.
- Packages still never link libc (`zg_build.addPackage` asserts it), and
  none of our code calls libc beyond the loader's `dlopen`/`dlsym`.
- Other binaries (`zg`, tools) and other targets are unchanged. Windows
  loads `vulkan-1.dll` with `LoadLibraryW` and needs no libc. musl Linux
  stays libc-free and uses the software renderer.
- The `test-vulkan-gpu` step builds its own libc-linked test binary for
  the same reason.

## Consequences

- Vulkan works in the app on Linux (`ZG_RENDERER=vulkan`, `zigguro
  --doctor-gpu`).
- The Linux GUI binary needs a glibc at runtime, so a release built on a
  newer glibc does not start on an older one. Release builds (E17) should
  target the oldest glibc we support (`x86_64-linux-gnu.2.31` style
  triples).
- Startup pays for the dynamic linker (well under a millisecond).

## References

- [Vulkan loader architecture](https://github.com/KhronosGroup/Vulkan-Loader/blob/main/docs/LoaderInterfaceArchitecture.md)
- [ADR 0001](0001-zig-std-only.md)
