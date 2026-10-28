# Memory accounting

How zigguro knows where its memory goes. Budgets live in [budgets.md](budgets.md) (`mem.idle_private` is 150 MB, `mem.gpu_device_local` 96 MiB). The code is `zg_perf.mem` (`packages/perf/src/mem/`).

## Tags

Every allocation is charged to a `MemTag`, the subsystem that made it. The list in `packages/perf/src/mem/tags.zig` is closed on purpose: a package cannot invent a tag without editing that file.

For each tag, zg_perf keeps live bytes, peak bytes, the allocation count and the free count. `zg_perf.mem.tagStats(tag)` and `allTagStats(&out)` read them from any thread.

| Tag | Charged by |
|---|---|
| `core` | zg_core runtime, mailboxes, pools |
| `platform` | E01 platform backends, event arenas |
| `gpu_host` | E02 host-side renderer memory (CPU copies, staging bookkeeping) |
| `text` | E03 glyph atlases (CPU side) and shaping caches |
| `gui` | E04 nodes, layout and paint lists |
| `editor` | E05 text buffers and undo history |
| `syntax` | E05 highlighting and syntax trees |
| `terminal` | E06 terminal grids and scrollback |
| `lsp` | E07 language server clients and their caches |
| `workspace` | E08 path store and index |
| `notes` | E08 notes |
| `scm` | E09 source control |
| `ai` | E10 transcripts and contexts |
| `mcp` | E11 MCP clients and servers |
| `review` | E12 review and inline edits |
| `perf` | E14 traces, timelines, the HUD |
| `config` | E15 settings, commands, themes |
| `other` | Anything else; it should stay small |

## Charging allocations

Give each subsystem a tracked allocator instead of the raw gpa:

```zig
const zg_perf = @import("zg_perf");

// One static wrapper per tag around the process gpa.
const gpa = zg_perf.mem.tracked(.editor, rt.gpa);
```

- `tracked(tag, child)` uses one static `TrackedAllocator` per tag. The first call for a tag fixes its child, normally the process gpa.
- `trackedWith(&storage, tag, child)` wraps any other child with caller-owned storage.
- For an arena, wrap the arena's backing allocator, not the arena itself: `std.heap.ArenaAllocator.init(zg_perf.mem.tracked(.syntax, gpa))`. Arena growth is then charged chunk by chunk, which is the right granularity.

The wrapper forwards to the child. It charges `len` on `alloc`, the size change on a successful `resize` or `remap`, and the whole buffer on `free`. Each thread charges its own counters with plain stores (no locked instructions) and flushes them to the tag's shared live count once they hold 64 KiB; the peak is updated at those flushes, so it can miss up to 64 KiB per thread. Readers sum every thread's counters. The bench `perf.tracked_alloc_overhead` measures it against `perf.smp_alloc_free` (budget: < 5 ns difference; about 1.5 ns in the cloud ReleaseFast run).

Not tracked: leaks (the E00 DebugAllocator finds them in Debug builds) and full heap profiles with stacks (use heaptrack or WPR heap tracing; see [profiling.md](profiling.md)).

## GPU memory

The renderer (E02) reports GPU memory in two ways:

- `zg_perf.mem.gpu.gpuChargeTag(tag, delta)` on every `vkAllocateMemory` (positive delta) and `vkFreeMemory` (negative delta). It charges blocks, not sub-allocations. The tags are `atlas`, `layers`, `instance_rings`, `images`, `swapchain`, `staging` and `other`.
- `setGpuSource(.{ .ctx, .query })` with a query that reads `VK_EXT_memory_budget` (`heapUsage` and `heapBudget`, summed over DEVICE_LOCAL heaps, or the shared heap on UMA GPUs).

`gpu.query()` merges the two: the driver's used and budget numbers, plus the per-tag charges. Without a source, the tag sum stands in for the used number. The budget `mem.gpu_device_local` is checked against the tag sum; the driver's `heapUsage` is shown next to it. The query runs only when the memory sampler does.

## Sampler

`zg_perf.mem.Sampler` combines process memory from the OS, the tag counters and GPU memory into a `Snapshot`:

- Linux: `/proc/self/smaps_rollup` (private = `Private_Clean` + `Private_Dirty`, plus `Rss`, `Pss` and `Anonymous`) and `/proc/self/status` for the peak (`VmHWM`). Kernels before 4.14 fall back to `/proc/self/statm`.
- Windows: `K32GetProcessMemoryInfo` with `PROCESS_MEMORY_COUNTERS_EX2` (private = `PrivateUsage`), falling back to `_EX`.

The budget `mem.idle_private` uses the private number. Some GPU drivers count their allocations as private memory, so reports show the GPU numbers next to it.

The sampler has no thread until someone asks: `observe()` returns an `Observation` that keeps it sampling every 500 ms until `release()`, and `sampleNow()` asks for one sample. With no observation the worker sleeps on a futex with no timeout (zero idle wakeups). `latest()` reads the newest snapshot from any thread under a seqlock. One sample costs about 19 µs in the cloud run (`perf.mem_sample`, budget 200 µs).

Each sample emits the trace counters `mem.private_bytes`, `mem.rss_bytes`, `mem.gpu_device_local_bytes` and `mem.tag.<name>` for tags with more than 1 MiB live.

In the app, the HUD's memory row observes the sampler while the HUD is visible.

## Reports

- `zigguro --mem-report` prints the table to stdout after the first idle period (2 s without input once the workspace is loaded) and keeps running. `--mem-report=now` prints it at once; `--mem-report-exit` exits after printing.
- The command `perf.memory.report` (Show Memory Report) prints the same table and shows it in a toast.
- `zg_perf.mem.writeReportJson` writes the snapshot as JSON for scenarios.

```
tag             live        peak      allocs
text         1.5 MiB     2.0 MiB          90
editor      12.0 MiB    13.0 MiB        4200
tagged      13.5 MiB

process   private 64.0 MiB, rss 96.0 MiB, pss 80.0 MiB, peak rss 100.0 MiB
gpu       used 40.0 MiB of 6.0 GiB, tagged 28.0 MiB
untracked 50.5 MiB (private - tagged)
```

`untracked` is private memory no tag accounts for: untracked packages, allocator overhead, thread stacks, and driver allocations counted as private.
