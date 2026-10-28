# Threading model

zigguro's hardest performance rule is that **the UI thread never blocks**. Every keystroke has an 8 ms budget from the OS event to the photon (`input.key_to_photon`, see [budgets.md](budgets.md)), and a UI thread that waits on a disk, a socket, a lock or a big parse blows it. This guide explains who runs what, the rules every package follows, the patterns that keep latency low and the tools that catch violations.

The code samples below are compiled and tested in [`packages/perf/src/docs_examples.zig`](../../packages/perf/src/docs_examples.zig) (`zig build test-perf`).

## 1. Thread roles

| Thread | Owner | Does | Never does |
|---|---|---|---|
| UI thread | E04 `Host.run` | input dispatch, view build, layout, paint, draining the mailbox | blocking I/O, process spawn, long locks, big parses |
| Render thread | E02 `RenderThread` (one per window) | encode and submit draw lists, present pacing | touch GUI state |
| Platform thread | E01 (where the OS needs one) | read OS events into the `EventRing` | run app code |
| `Io.Threaded` workers | `zg_core.Runtime` | short CPU and I/O jobs started with `io.async` / `Subsystem.spawn` | loop forever |
| Long-lived loops | each subsystem | LSP/DAP readers, SSE streams, PTY readers, file watchers, started with `io.concurrent` / `Subsystem.spawnLoop` | run inline |
| Stall watchdog | zg_perf | watch the UI heartbeat | wake while the UI is idle |

## 2. The rules

These are the E00.F04 rules (`packages/core/src/runtime/Runtime.zig`):

- **(a)** The UI thread owns all GUI state and never performs blocking `Io`. Blocking helpers call `assertNotUi()`, which panics in Debug.
- **(b)** Short CPU work goes through `io.async` / `Subsystem.spawn`, which **may run inline**. Long-lived loops use `io.concurrent` / `Subsystem.spawnLoop`, which never runs inline and can fail with `error.ConcurrencyUnavailable`. Never start a loop with `spawn`: inline execution would deadlock it.
- **(c)** Each subsystem owns one `std.Io.Group` (a `zg_core.runtime.Subsystem`) and cancels it in `deinit`, so shutdown is structured.
- **(d)** Results reach the UI thread only through `Runtime.post` (a bounded, allocation-free mailbox) plus the platform waker. The UI drains on wake and repaints damaged regions only.
- **(e)** Cancellation surfaces as `error.Canceled` from any `Io` call. Propagate it.

A subsystem (`example_subsystem`):

```zig
pub const Indexer = struct {
    sub: zg_core.runtime.Subsystem,
    pub fn init(io: std.Io) Indexer { return .{ .sub = .init(io) }; }
    pub fn index(ix: *Indexer, data: []const u8) void { ix.sub.spawn(job, .{ ix, data }); }
    pub fn deinit(ix: *Indexer) void { ix.sub.shutdown(); } // cancel + join
};
```

## 3. Never on the UI thread

- file or network I/O of any size, including `stat` and directory reads;
- process spawn;
- an `Io.Mutex` that a worker may hold for more than 50 µs (prefer immutable snapshots: persistent data structures the worker publishes with one atomic swap);
- JSON parsing of more than 100 KB;
- a regex over more than 1 MB;
- allocation-heavy loops (arena per frame instead).

## 4. Latency patterns

**Post results, don't wait for them** (`example_post_result`). The anti-pattern is a click handler that calls `readFileAlloc`. The fix spawns the read and posts the result:

```zig
pub fn loadFile(rt: *zg_core.Runtime, path: []const u8) std.Io.Cancelable!void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, path, rt.gpa, .limited(64 << 20)) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => { rt.post(.{ .kind = msg_file_loaded, .a = 0, .b = 1 }) catch {}; return; },
    };
    defer rt.gpa.free(bytes);
    rt.post(.{ .kind = msg_file_loaded, .a = bytes.len }) catch {};
}
```

**Chunk background work and yield** (`example_chunked`). Call `zg_perf.runtime.activity.yieldPoint(io)` about every millisecond of work (per file in the indexer, per 64 KiB in search). It returns `error.Canceled` when the task is canceled and waits up to 4 ms while the UI builds a frame:

```zig
while (i < data.len) {
    const end = @min(data.len, i + 64 * 1024);
    lines += std.mem.count(u8, data[i..end], "\n");
    i = end;
    try activity.yieldPoint(io);
}
```

**Latest wins** (`example_latest_wins`). Typing supersedes stale requests: the UI bumps a generation, the worker drops work whose generation is no longer current, and in-flight requests are canceled rather than awaited.

**Coalesce per frame.** Many events in one frame produce one update (E05 coalesces `didChange` per frame; E04 rebuilds dirty views once).

**Deadlines.** Anything the UI waits for at all (a clipboard read, a completion) has a deadline and a fallback.

### The activity signal

`zg_perf.runtime.activity.global` is the UI's published activity: `idle`, `interactive` or `frame_busy`. `Host.run` publishes `frame_busy` around each pump and `interactive` after it; `idle` is derived lazily (no input for 2 s), so no timer runs. Reads are wait-free (one atomic load). Schedulers use `level()`, `waitUntilNot` and `recommendedWorkers(cpu_count)` (all cores but one when idle, half otherwise).

### Idle

Idle means 0 wakeups per second (`idle.wakeups`). Every blocking wait notes why it returned, right after it returns:

```zig
h.platform.waitEvents(deadline_ns);
zg_perf.idle.noteWake("gui.host.wait", if (timer) .timer else .input);
```

The reasons are `input`, `timer`, `mailbox`, `io_completion`, `frame`, `present`, `signal` and `unknown`. `noteWake` costs about 1 ns (`idle.note_wake`): each thread counts into its own record, and with tracing on it also records the instant `perf.wake` at the site, with the reason as its value. Name threads with `zg_perf.idle.wake_count.nameThread`, and `wakeSnapshot` lists each thread's count, reasons and last site.

`zg_perf.idle.IdleMonitor` turns the counts into wakeups per second and process CPU percent (`processCpuTimes`/`threadCpuTimes`: `getrusage` on Linux, `GetProcessTimes`/`GetThreadTimes` on Windows). It samples once a second, only while something observes it (the HUD's "wakeups" row in the app), and leaves its own wakes (`perf.idle_monitor`) out.

Annotated sites today:

| Site | Wait | Reason |
|---|---|---|
| `gui.host.wait` | the UI thread's `waitEvents` | `timer` past the earliest window deadline, else `input` |
| `perf.drain` | the trace drain worker | `timer` or `signal` |
| `perf.flight_recorder` | the flight recorder's dump worker | `signal` or `timer` |
| `perf.watchdog` | the stall watchdog | `timer` or `signal` |
| `perf.activity_wait` | `activity.waitUntilNot` | `signal` |
| `perf.mem_sampler` | the memory sampler worker | `timer` or `signal` |
| `perf.pressure` | the memory pressure worker | `signal` |
| `perf.idle_monitor` | the idle monitor itself (not counted) | `timer` or `signal` |

`zig build test-wake-sites` (part of `zig build test`) scans `packages/` outside tests for `waitEvents(`, `.wait(io`, `futexWait`, `io.sleep(`, `Event.wait`, `Condition.wait` and `Futex.wait`, and fails when one has no `noteWake(` on its line or within 5 lines after it. Waits that predate the check are counted per file in `tools/wake-sites/baseline.txt`; a file may not go over its count. Owners annotate their waits and lower the count (`zig build wake-sites-baseline` rewrites the file). The idle scenario that measures `idle.wakeups` comes with the scenario runner (E14.F06).

## 5. Measuring

- **Trace zones**: `const z = zg_core.trace.zone(@src(), "editor.view.paint"); defer z.end();`. Name zones `<pkg>.<area>.<op>`. Build with `-Dtracing=zones`.
- **Counters**: `zg_core.trace.counter("workspace.index.queue", n)`.
- **Stall watchdog**: `zg_perf.StallWatchdog.start(gpa, io, .{ .stack = zg_perf.runtime.shadow_stack.enableForCurrentThread() })` on the UI thread, passed to `Host` as `.watchdog`. A UI-thread interval of 50 ms or more without reaching the event wait logs `ui stall 83 ms in [gui.layout > editor.view.paint > text.shape]` with the open zones, and reports again at 2× and 4× the threshold, then every second. While the UI waits for events the watchdog sleeps with no timeout.
- **HUD and flight recorder** (E14.F02, E14.F03): live frame phases, and an automatic trace dump on slow frames and stalls.
- **Benchmarks**: `zig build bench` and `zg_perf.budget.expectWithin` in tests.

## 6. Budgets

| Budget | Limit |
|---|---|
| `input.key_to_photon` | < 8 ms p99 |
| `ui.frame_cpu_keystroke` | < 2 ms p99 |
| `ui.thread_stall` | < 16 ms max (the watchdog warns at 50 ms) |
| `ui.view_switch` | < 16 ms p99 |
| `idle.wakeups` | 0/s |

The full, generated list is [budgets.md](budgets.md).

## 7. Anti-patterns and fixes

| Anti-pattern | Fix |
|---|---|
| `readFileAlloc` in a click handler | spawn the read, `post` the result |
| a worker holding a mutex the UI takes while it parses | parse into a new snapshot, swap a pointer |
| a polling timer that checks for changes | a watcher or a futex/`Io.Event`; idle means 0 wakeups |
| a long loop started with `spawn` | `spawnLoop` (`io.concurrent`) |
| awaiting a stale request after a keystroke | latest-wins generation plus cancel |
| an indexer that saturates every core while the user types | `yieldPoint` and `recommendedWorkers` |
