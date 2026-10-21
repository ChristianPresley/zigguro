# 0005. Error handling and diagnostics

Status: Accepted
Date: 2026-10-21

## Context

Zig errors are values without payloads. Users need rich messages (file, offset, reason) while code needs precise error sets. Crashes must be captured for reports (E17) without the panic path itself failing.

## Decision

- `pub` functions return specific error sets; `anyerror` appears only in callbacks.
- A function that can fail with user-facing detail takes `diag: ?*zg_core.report.Diagnostics` and records messages there; `Diagnostics.add` never fails (it drops and counts on OOM).
- Apps install `pub const panic = std.debug.FullPanic(zg_core.report.panicHandler)`; the handler runs the crash hook (E17 sets it with `setCrashHook`) once, guarded against recursion, then the default panic.
- Never `catch unreachable` on I/O: I/O can always fail. `catch unreachable` is only for provably impossible errors.
- Code that swallows I/O errors on a cancellable task blocks cancellation around them (`io.swapCancelProtection(.blocked)`) so a cancel request is not consumed silently.

## Consequences

- Error sets stay small and testable; UIs and the CLI render `Diagnostics` uniformly.
- E17 plugs in crash dumps without touching packages.

## References

- [Zig 0.16.0 standard library docs](https://ziglang.org/documentation/0.16.0/std/)
- `packages/core/src/report.zig`
