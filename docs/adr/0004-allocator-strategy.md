# 0004. Allocator strategy

Status: Accepted
Date: 2026-10-21

## Context

Every package allocates; mistakes show up as leaks, use-after-free or latency spikes in the frame loop. Zig passes allocators explicitly, which lets us choose per use.

## Decision

- Process GPA: `std.heap.DebugAllocator` (leak and safety checks) in Debug and ReleaseSafe, `std.heap.smp_allocator` in ReleaseFast/ReleaseSmall; `-Dgpa=auto|debug|smp` overrides.
- Per frame: `zg_core.alloc.FrameArena`, two arenas swapped each frame; data lives for the current and previous frame. Allocation is thread-safe (0.16 ArenaAllocator is lock-free); `next()` runs on the UI thread with no outstanding borrowers.
- Per request (LSP, HTTP, agent turn): `RequestArena`, reset when the request completes.
- Hot fixed-size objects: `Pool(T)` over std's unmanaged `MemoryPool`.
- `CountingAllocator` measures benchmarks and budgets; `LimitAllocator` caps untrusted input (JSON, agent sandboxes).
- Conventions: `gpa` is the first parameter, `io` the second; returned slices are owned by the caller unless documented; no arena memory is kept past a reset.

## Consequences

- Leaks fail tests (`std.testing.allocator`), and steady-state frames make zero backing allocations.
- Code must document lifetimes when it returns arena memory.

## References

- [Zig 0.16.0 standard library docs](https://ziglang.org/documentation/0.16.0/std/)
- `packages/core/src/alloc.zig`
