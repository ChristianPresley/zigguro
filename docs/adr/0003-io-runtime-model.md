# 0003. One std.Io runtime per process

Status: Accepted
Date: 2026-10-21

## Context

The UI must never block: keystroke-to-photon is under 8 ms p99 and every view switch under one frame. Zig 0.16 introduced the `std.Io` interface (`Io.Threaded`, `io.async`, `io.concurrent`, `Io.Group`, `Io.Queue`, `Io.Select`, cancellation via `error.Canceled`) and removed `std.Thread.Pool` and `std.Thread.Mutex`.

## Decision

- Apps use `pub fn main(min: std.process.Init.Minimal) !u8` and build one `zg_core.Runtime`, which owns the GPA and one `std.Io.Threaded` with explicit `async_limit` and `concurrent_limit`.
- The UI thread owns GUI state and never performs blocking `Io`; blocking helpers call `Runtime.assertNotUi()` (enforced with `-Dassert_ui_thread`, on by default in Debug).
- Short CPU work uses `io.async` (may run inline); long-lived loops use `io.concurrent` (never inline). Each subsystem owns an `Io.Group` through `zg_core.runtime.Subsystem`, so shutdown cancels and joins structurally.
- Results return through a bounded `Io.Queue(UiMsg)` mailbox plus a platform `Waker` (implemented by E01); wakes are coalesced.
- Nothing uses `std.Thread.Pool` or `std.Thread.Mutex`.

## Consequences

- Every package with background work shares one threading model and one cancellation story (`$/cancelRequest` and `notifications/cancelled` map onto `error.Canceled`).
- `Io.Queue` is mutex-based; if the mailbox misses its < 1 µs budget, producers move to per-producer SPSC rings behind the same API.

## References

- [Zig 0.16.0 release notes](https://ziglang.org/download/0.16.0/release-notes.html)
- `packages/core/src/runtime/Runtime.zig` (threading rules a-e)
