//! The flight recorder (E14.F02.S02.T01): keeps a rolling window of recent
//! trace events and dumps it to a Perfetto file when something goes wrong
//! (a slow frame, a UI stall, a slow startup, a budget violation, a crash,
//! or on demand), rate limited and capped in file count.
//!
//! It is a consumer of the shared trace `Drain`, so it costs nothing at
//! idle: the drain parks without activity and the dump worker sleeps on a
//! futex until a trigger arrives. The drain runs every 100 ms while frames
//! are produced and whenever a ring reaches a quarter full (16 384 events),
//! which keeps the default 65 536-event rings from overflowing at the UI
//! thread's typical rate of at most 5 000 events per frame.

const std = @import("std");
const builtin = @import("builtin");
const zg_core = @import("zg_core");
const Store = @import("store.zig").Store;
const Drain = @import("drain.zig").Drain;
const perfetto = @import("../export/perfetto.zig");
const session = @import("session.zig");
const Redact = @import("../export/redact.zig").Redact;
const timeline = @import("../frame/timeline.zig");
const FrameRecord = @import("../frame/record.zig").FrameRecord;
const StallReport = @import("../runtime/watchdog.zig").StallReport;
const budget = @import("../budget.zig");

const Event = zg_core.trace.Event;
const Kind = zg_core.trace.Kind;
const Site = zg_core.trace.Site;
const log = std.log.scoped(.perf_trace);

/// Why a dump was taken.
pub const Trigger = enum { manual, slow_frame, ui_stall, slow_startup, budget_violation, crash };

/// Recorder counters.
pub const Stats = struct {
    dumps: u32,
    /// Triggers dropped by the rate limit or a full mailbox.
    suppressed: u32,
    bytes_held: u64,
    last_dump_path: ?[]const u8,
};

/// Options; the defaults match the `perf.flightRecorder.*` settings.
pub const Options = struct {
    /// `perf.flightRecorder.enabled`: on in `zones` builds.
    enabled: bool = zg_core.trace.enabled,
    /// `perf.flightRecorder.windowSeconds`.
    window_ns: u64 = 10 * std.time.ns_per_s,
    /// `perf.flightRecorder.maxMB`.
    max_bytes: u64 = 32 << 20,
    min_interval_between_dumps_ns: u64 = 60 * std.time.ns_per_s,
    /// Context kept after the trigger before dumping.
    post_context_ns: u64 = std.time.ns_per_s,
    /// Dump folder (created if missing); see `session.defaultTraceDir`.
    dir: []const u8,
    /// Older `flight-*.pftrace` files beyond this many are deleted.
    max_files: u32 = 20,
    pid: i32 = 1,
    process_name: []const u8 = "zigguro",
    redact: Redact = .none,
    /// Run the dump worker. Without it, `processTriggers` dumps on the
    /// calling thread (tests, single-threaded `Io`).
    worker: bool = true,
    /// Called on the worker after each dump with the file path.
    on_dump: ?*const fn (ctx: ?*anyopaque, path: []const u8, why: Trigger) void = null,
    context: ?*anyopaque = null,
    /// `.awake` ns clock override (tests).
    clock: ?*const fn () u64 = null,
    /// Annotated on the dump marker.
    app_version: []const u8 = "dev",
};

const Pending = struct {
    /// 0 free, 1 being written, 2 ready.
    state: std.atomic.Value(u8) = .init(0),
    why: Trigger = .manual,
    ts: u64 = 0,
    note_len: u8 = 0,
    note: [96]u8 = undefined,
};

const marker_site: Site = .{ .name = "perf.flight_recorder", .file = "", .line = 0 };

/// Size of the crash path's preallocated export memory.
pub const crash_scratch_bytes = 1 << 20;

/// The flight recorder.
pub const FlightRecorder = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    drain: *Drain,
    opts: Options,
    dir: std.Io.Dir,
    /// Guards `store`, `newest_ts` and `effective_window_ns`.
    mutex: std.Io.Mutex = .init,
    store: Store,
    newest_ts: u64 = 0,
    effective_window_ns: u64,
    pending: [4]Pending = @splat(.{}),
    /// Futex word bumped by triggers and stop.
    signal: std.atomic.Value(u32) = .init(0),
    stopping: std.atomic.Value(bool) = .init(false),
    group: std.Io.Group = .init,
    running: bool = false,
    last_dump_ns: ?u64 = null,
    dumps: std.atomic.Value(u32) = .init(0),
    suppressed: std.atomic.Value(u32) = .init(0),
    /// Worker wakeups (tests).
    wakeups: std.atomic.Value(u64) = .init(0),
    last_path_buf: [512]u8 = undefined,
    last_path_len: usize = 0,
    crash_scratch: []u8,

    /// Starts recording; null when `opts.enabled` is false (no worker, no
    /// drain consumer, no memory).
    pub fn init(gpa: std.mem.Allocator, io: std.Io, drain: *Drain, opts: Options) !?*FlightRecorder {
        if (!opts.enabled) return null;
        const dir = try std.Io.Dir.cwd().createDirPathOpen(io, opts.dir, .{ .open_options = .{ .iterate = true } });
        errdefer dir.close(io);
        const fr = try gpa.create(FlightRecorder);
        errdefer gpa.destroy(fr);
        const scratch = try gpa.alloc(u8, crash_scratch_bytes);
        errdefer gpa.free(scratch);
        fr.* = .{
            .gpa = gpa,
            .io = io,
            .drain = drain,
            .opts = opts,
            .dir = dir,
            .store = .init(gpa, opts.max_bytes),
            .effective_window_ns = opts.window_ns,
            .crash_scratch = scratch,
        };
        try drain.add(.{ .ctx = fr, .consume = consume });
        errdefer drain.remove(fr);
        if (opts.worker) {
            if (fr.group.concurrent(io, loop, .{fr})) |_| {
                fr.running = true;
            } else |_| log.info("flight recorder: no concurrency, dumping on demand only", .{});
        }
        return fr;
    }

    /// Stops the worker (pending triggers are dropped) and frees.
    pub fn deinit(fr: *FlightRecorder) void {
        fr.drain.remove(fr);
        fr.stopping.store(true, .release);
        fr.wake();
        if (fr.running) fr.group.cancel(fr.io);
        fr.store.deinit();
        fr.dir.close(fr.io);
        fr.gpa.free(fr.crash_scratch);
        fr.gpa.destroy(fr);
    }

    fn now(fr: *const FlightRecorder) u64 {
        if (fr.opts.clock) |c| return c();
        return zg_core.time.nowNs(fr.io);
    }

    fn wake(fr: *FlightRecorder) void {
        _ = fr.signal.fetchAdd(1, .release);
        fr.io.futexWake(u32, &fr.signal.raw, 1);
    }

    /// UI thread, once per frame: forwards to the drain (a relaxed store,
    /// plus a kick when the drain parked).
    pub fn noteActivity(fr: *FlightRecorder) void {
        fr.drain.noteActivity(fr.now());
    }

    /// Requests a dump (any thread; never blocks or allocates). Dropped
    /// and counted as suppressed when four triggers are already pending.
    pub fn trigger(fr: *FlightRecorder, why: Trigger, note: []const u8) void {
        const ts = fr.now();
        for (&fr.pending) |*p| {
            if (p.state.cmpxchgStrong(0, 1, .acquire, .monotonic) != null) continue;
            p.why = why;
            p.ts = ts;
            const n = @min(note.len, p.note.len);
            @memcpy(p.note[0..n], note[0..n]);
            p.note_len = @intCast(n);
            p.state.store(2, .release);
            fr.wake();
            return;
        }
        _ = fr.suppressed.fetchAdd(1, .monotonic);
    }

    /// A `FrameTimeline` slow-frame hook that triggers `slow_frame`.
    pub fn slowFrameHook(fr: *FlightRecorder) timeline.SlowFrameHook {
        return .{ .ctx = fr, .f = onSlowFrame };
    }

    fn onSlowFrame(ctx: *anyopaque, rec: *const FrameRecord, reason: timeline.SlowReason) void {
        const fr: *FlightRecorder = @ptrCast(@alignCast(ctx));
        var buf: [96]u8 = undefined;
        fr.trigger(.slow_frame, std.fmt.bufPrint(&buf, "frame {d}: {t}", .{ rec.seq, reason }) catch @tagName(reason));
    }

    /// For `StallWatchdog.Options.on_stall` with `context = fr`: the first
    /// report of each stall triggers `ui_stall`.
    pub fn onStall(ctx: ?*anyopaque, report: StallReport) void {
        const fr: *FlightRecorder = @ptrCast(@alignCast(ctx.?));
        if (report.sequence != 0) return;
        var buf: [96]u8 = undefined;
        const top = if (report.depth != 0) report.zone_stack[report.depth - 1].?.name else "?";
        fr.trigger(.ui_stall, std.fmt.bufPrint(&buf, "{d} ms in {s}", .{ report.duration_ns / std.time.ns_per_ms, top }) catch "stall");
    }

    /// The generic budget hook: triggers `budget_violation` when
    /// `evaluation` failed a gating or warning budget.
    pub fn onBudget(fr: *FlightRecorder, evaluation: budget.check.Evaluation) void {
        if (evaluation.verdict == .pass) return;
        fr.trigger(.budget_violation, evaluation.budget.id);
    }

    /// Counters.
    pub fn stats(fr: *const FlightRecorder) Stats {
        return .{
            .dumps = fr.dumps.load(.monotonic),
            .suppressed = fr.suppressed.load(.monotonic),
            .bytes_held = fr.store.bytes(),
            .last_dump_path = if (fr.last_path_len == 0) null else fr.last_path_buf[0..fr.last_path_len],
        };
    }

    fn consume(ctx: *anyopaque, evs: []const Event) void {
        const fr: *FlightRecorder = @ptrCast(@alignCast(ctx));
        fr.mutex.lockUncancelable(fr.io);
        defer fr.mutex.unlock(fr.io);
        fr.add(evs);
    }

    /// Appends under the mutex, trimming to the window and the byte cap.
    fn add(fr: *FlightRecorder, evs: []const Event) void {
        for (evs) |e| if (e.kind != @intFromEnum(Kind.thread_name)) {
            fr.newest_ts = @max(fr.newest_ts, e.ts);
        };
        fr.store.appendSlice(evs) catch {
            fr.store.trimToBytes(fr.opts.max_bytes * 3 / 4);
            fr.store.appendSlice(evs) catch {};
        };
        fr.store.dropOlderThan(fr.newest_ts -| fr.opts.window_ns);
        // An event storm: keep the newest 75 % and a shorter window.
        if (fr.store.bytes() * 10 > fr.opts.max_bytes * 9) fr.store.trimToBytes(fr.opts.max_bytes * 3 / 4);
        const oldest = fr.store.oldestTs() orelse fr.newest_ts;
        fr.effective_window_ns = @min(fr.opts.window_ns, fr.newest_ts -| oldest);
    }

    fn loop(fr: *FlightRecorder) std.Io.Cancelable!void {
        while (!fr.stopping.load(.acquire)) {
            const seen = fr.signal.load(.acquire);
            if (!fr.hasPending()) {
                try fr.io.futexWait(u32, &fr.signal.raw, seen);
                _ = fr.wakeups.fetchAdd(1, .monotonic);
                continue;
            }
            // Post-trigger context.
            const ts = fr.oldestPendingTs();
            const until = ts + fr.opts.post_context_ns;
            if (fr.now() < until) {
                const deadline: std.Io.Clock.Timestamp = .{ .raw = .fromNanoseconds(@intCast(zg_core.time.nowNs(fr.io) + (until - fr.now()))), .clock = .awake };
                fr.io.futexWaitTimeout(u32, &fr.signal.raw, seen, .{ .deadline = deadline }) catch |err| return err;
                if (fr.now() < until) continue;
            }
            fr.drain.drainNow();
            fr.processTriggers();
        }
    }

    fn hasPending(fr: *const FlightRecorder) bool {
        for (&fr.pending) |*p| if (p.state.load(.acquire) == 2) return true;
        return false;
    }

    fn oldestPendingTs(fr: *const FlightRecorder) u64 {
        var ts: u64 = std.math.maxInt(u64);
        for (&fr.pending) |*p| if (p.state.load(.acquire) == 2) {
            ts = @min(ts, p.ts);
        };
        return ts;
    }

    /// Dumps (or suppresses) every pending trigger, on the calling thread.
    /// The worker calls it after the post-trigger context; without a
    /// worker, call it yourself.
    pub fn processTriggers(fr: *FlightRecorder) void {
        for (&fr.pending) |*p| {
            if (p.state.load(.acquire) != 2) continue;
            const why = p.why;
            const ts = p.ts;
            var note_buf: [96]u8 = undefined;
            const note = note_buf[0..p.note_len];
            @memcpy(note, p.note[0..p.note_len]);
            p.state.store(0, .release);
            if (fr.last_dump_ns) |last| if (ts -| last < fr.opts.min_interval_between_dumps_ns) {
                _ = fr.suppressed.fetchAdd(1, .monotonic);
                continue;
            };
            fr.last_dump_ns = ts;
            fr.dump(why, ts, note) catch |err| {
                log.info("flight recorder dump failed: {t}", .{err});
            };
        }
    }

    fn dumpName(buf: []u8, unix_ms: i64, why: Trigger) []const u8 {
        return std.fmt.bufPrint(buf, "flight-{d}-{t}.pftrace", .{ unix_ms, why }) catch unreachable;
    }

    fn rememberPath(fr: *FlightRecorder, name: []const u8) []const u8 {
        const sep: []const u8 = if (builtin.os.tag == .windows) "\\" else "/";
        const p = std.fmt.bufPrint(&fr.last_path_buf, "{s}{s}{s}", .{ fr.opts.dir, sep, name }) catch name;
        fr.last_path_len = p.len;
        return p;
    }

    fn marker(fr: *FlightRecorder, w: *perfetto.Writer, why: Trigger, ts: u64, note: []const u8) !void {
        const track = try w.defineThread(0, "");
        const ann = [_]perfetto.Writer.Annotation{
            .{ .name = "why", .value = .{ .string = @tagName(why) } },
            .{ .name = "note", .value = .{ .string = note } },
            .{ .name = "app_version", .value = .{ .string = fr.opts.app_version } },
            .{ .name = "build_mode", .value = .{ .string = @tagName(builtin.mode) } },
            .{ .name = "tracing", .value = .{ .string = if (zg_core.trace.enabled) "zones" else "off" } },
            .{ .name = "dropped_events", .value = .{ .int = @intCast(zg_core.trace.droppedCount()) } },
            .{ .name = "effective_window_ns", .value = .{ .int = @intCast(fr.effective_window_ns) } },
        };
        try w.writeTrackEvent(.{ .ts = ts, .type = .instant, .track = track, .name = marker_site.name, .annotations = &ann });
    }

    fn dump(fr: *FlightRecorder, why: Trigger, ts: u64, note: []const u8) !void {
        const lo = ts -| fr.opts.window_ns;
        const hi = ts + fr.opts.post_context_ns;
        var events: std.ArrayList(Event) = .empty;
        defer events.deinit(fr.gpa);
        {
            fr.mutex.lockUncancelable(fr.io);
            defer fr.mutex.unlock(fr.io);
            var it = fr.store.iterator();
            while (it.next()) |run| for (run) |e| {
                const end = if (e.kind == @intFromEnum(Kind.zone)) e.ts +| @as(u64, @intCast(@max(0, e.value))) else e.ts;
                if (e.kind == @intFromEnum(Kind.thread_name) or (end >= lo and e.ts <= hi)) try events.append(fr.gpa, e);
            };
        }
        var out: std.Io.Writer.Allocating = .init(fr.gpa);
        defer out.deinit();
        var w = perfetto.Writer.init(fr.gpa, &out.writer, .{ .pid = fr.opts.pid, .process_name = fr.opts.process_name, .redact = fr.opts.redact });
        defer w.deinit();
        try w.writeEvents(events.items);
        try fr.marker(&w, why, ts, note);
        try w.finish();

        fr.pruneFiles();
        var name_buf: [96]u8 = undefined;
        const name = dumpName(&name_buf, std.Io.Clock.real.now(fr.io).toMilliseconds(), why);
        var af = try fr.dir.createFileAtomic(fr.io, name, .{ .replace = true });
        defer af.deinit(fr.io);
        try af.file.writeStreamingAll(fr.io, out.written());
        try af.replace(fr.io);
        const path = fr.rememberPath(name);
        _ = fr.dumps.fetchAdd(1, .monotonic);
        log.info("flight recorder: {t} dump written to {s}", .{ why, path });
        if (fr.opts.on_dump) |cb| cb(fr.opts.context, path, why);
    }

    /// Deletes the oldest `flight-*.pftrace` files so that, with the next
    /// dump, at most `max_files` remain.
    fn pruneFiles(fr: *FlightRecorder) void {
        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |n| fr.gpa.free(n);
            names.deinit(fr.gpa);
        }
        var it = fr.dir.iterate();
        while (it.next(fr.io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.startsWith(u8, entry.name, "flight-") or !std.mem.endsWith(u8, entry.name, ".pftrace")) continue;
            const n = fr.gpa.dupe(u8, entry.name) catch return;
            names.append(fr.gpa, n) catch {
                fr.gpa.free(n);
                return;
            };
        }
        if (names.items.len < fr.opts.max_files) return;
        std.mem.sort([]u8, names.items, {}, olderName);
        const excess = names.items.len - (fr.opts.max_files -| 1);
        for (names.items[0..excess]) |n| fr.dir.deleteFile(fr.io, n) catch {};
    }

    /// Orders `flight-<unix_ms>-...` names by time.
    fn olderName(_: void, a: []u8, b: []u8) bool {
        const ta = std.fmt.parseInt(u64, nameMs(a), 10) catch 0;
        const tb = std.fmt.parseInt(u64, nameMs(b), 10) catch 0;
        if (ta != tb) return ta < tb;
        return std.mem.lessThan(u8, a, b);
    }

    fn nameMs(n: []const u8) []const u8 {
        const rest = n["flight-".len..];
        return rest[0 .. std.mem.indexOfScalar(u8, rest, '-') orelse rest.len];
    }

    /// Crash path (E17's crash handler thread): writes the window
    /// synchronously into the preopened folder without touching the GPA,
    /// exporting chunk by chunk from the preallocated scratch. Returns the
    /// path, or null when the store is busy (its mutex is held) or the
    /// write fails. Stops early, keeping what was written, at `deadline_ns`
    /// (`.awake` ns) or when the scratch runs out.
    pub fn dumpNowBlocking(fr: *FlightRecorder, deadline_ns: u64) ?[]const u8 {
        if (!fr.mutex.tryLock()) return null;
        defer fr.mutex.unlock(fr.io);
        const ts = fr.now();
        var name_buf: [96]u8 = undefined;
        const name = dumpName(&name_buf, std.Io.Clock.real.now(fr.io).toMilliseconds(), .crash);
        var file = fr.dir.createFile(fr.io, name, .{}) catch return null;
        defer file.close(fr.io);

        // Scratch: 64 KiB file buffer, 256 KiB writer tables, the rest for
        // per-chunk temporaries (reset after each chunk).
        const s = fr.crash_scratch;
        var fw = file.writerStreaming(fr.io, s[0 .. 64 << 10]);
        var tables: std.heap.FixedBufferAllocator = .init(s[64 << 10 .. 320 << 10]);
        var temps: std.heap.FixedBufferAllocator = .init(s[320 << 10 ..]);
        var w = perfetto.Writer.init(tables.allocator(), &fw.interface, .{
            .pid = fr.opts.pid,
            .process_name = fr.opts.process_name,
            .redact = fr.opts.redact,
            .temp = temps.allocator(),
        });
        // No deinit: the tables live in the scratch.
        var it = fr.store.iterator();
        while (it.next()) |run| {
            if (zg_core.time.nowNs(fr.io) >= deadline_ns) break;
            w.writeEvents(run) catch break;
            temps.reset();
        }
        fr.marker(&w, .crash, ts, "crash") catch {};
        fw.interface.flush() catch return null;
        _ = fr.dumps.fetchAdd(1, .monotonic);
        return fr.rememberPath(name);
    }
};

// ---- tests ----

var fake_now: u64 = 0;
fn fakeClock() u64 {
    return fake_now;
}

fn testDir(buf: []u8, tmp: *std.testing.TmpDir) ![]const u8 {
    return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}/traces", .{&tmp.sub_path});
}

fn zoneAt(site: *const Site, ts: u64, dur: i64) Event {
    return .{ .ts = ts, .site_or_name = @intFromPtr(site), .kind = @intFromEnum(Kind.zone), .tid = 1, .value = dur };
}

const TestRig = struct {
    tmp: std.testing.TmpDir,
    drain: Drain,
    fr: *FlightRecorder,
    dir_buf: [256]u8 = undefined,

    fn init(r: *TestRig, opts: Options) !void {
        r.tmp = std.testing.tmpDir(.{});
        r.drain = .init(std.testing.allocator, std.testing.io);
        var o = opts;
        o.dir = try testDir(&r.dir_buf, &r.tmp);
        o.enabled = true;
        o.clock = fakeClock;
        r.fr = (try FlightRecorder.init(std.testing.allocator, std.testing.io, &r.drain, o)).?;
    }

    fn deinit(r: *TestRig) void {
        r.fr.deinit();
        r.drain.deinit();
        r.tmp.cleanup();
    }

    fn files(r: *TestRig) !usize {
        var d = try r.tmp.dir.openDir(std.testing.io, "traces", .{ .iterate = true });
        defer d.close(std.testing.io);
        var it = d.iterate();
        var n: usize = 0;
        while (try it.next(std.testing.io)) |_| n += 1;
        return n;
    }
};

test "flight: window trimming" {
    var r: TestRig = undefined;
    try r.init(.{ .dir = "", .worker = false, .window_ns = 1_000_000 });
    defer r.deinit();
    const site = zg_core.trace.siteFor(@src(), "gui.frame");
    var batch: [4096]Event = undefined;
    var ts: u64 = 0;
    for (0..8) |_| {
        for (&batch) |*e| {
            e.* = zoneAt(site, ts, 10);
            ts += 100;
        }
        r.fr.add(&batch);
    }
    // 8 chunks of 409.6 us each; a 1 ms window keeps the last 3 or 4.
    try std.testing.expect(r.fr.store.live_chunks <= 4);
    try std.testing.expect(r.fr.store.oldestTs().? >= ts - 1_000_000 - 4096 * 100);
}

test "flight: storm drops oldest and records effective window" {
    var r: TestRig = undefined;
    try r.init(.{ .dir = "", .worker = false, .window_ns = 1_000_000_000, .max_bytes = 4 * @sizeOf(@import("store.zig").Chunk) });
    defer r.deinit();
    const site = zg_core.trace.siteFor(@src(), "gui.frame");
    var batch: [4096]Event = undefined;
    var ts: u64 = 0;
    for (0..10) |_| {
        for (&batch) |*e| {
            e.* = zoneAt(site, ts, 1);
            ts += 10;
        }
        r.fr.add(&batch);
    }
    try std.testing.expect(r.fr.store.bytes() <= r.fr.opts.max_bytes * 9 / 10);
    try std.testing.expect(r.fr.effective_window_ns < r.fr.opts.window_ns);
    try std.testing.expect(r.fr.effective_window_ns > 0);
}

test "flight: trigger writes file with pre and post context" {
    var r: TestRig = undefined;
    try r.init(.{ .dir = "", .worker = false, .window_ns = 1000, .post_context_ns = 500 });
    defer r.deinit();
    const before = zg_core.trace.siteFor(@src(), "editor.before");
    const after = zg_core.trace.siteFor(@src(), "editor.after");
    const ancient = zg_core.trace.siteFor(@src(), "editor.ancient");
    const late = zg_core.trace.siteFor(@src(), "editor.too_late");
    r.fr.add(&.{ zoneAt(ancient, 10, 5), zoneAt(before, 9_500, 100) });
    fake_now = 10_000;
    r.fr.trigger(.manual, "test");
    r.fr.add(&.{ zoneAt(after, 10_200, 100), zoneAt(late, 11_000, 10) });
    r.fr.processTriggers();
    const st = r.fr.stats();
    try std.testing.expectEqual(@as(u32, 1), st.dumps);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, st.last_dump_path.?, std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "editor.before") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "editor.after") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "editor.ancient") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "editor.too_late") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "perf.flight_recorder") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "effective_window_ns") != null);
    try std.testing.expect(std.mem.endsWith(u8, st.last_dump_path.?, "-manual.pftrace"));
}

test "flight: rate limit suppresses" {
    var r: TestRig = undefined;
    try r.init(.{ .dir = "", .worker = false, .min_interval_between_dumps_ns = 1000, .max_files = 2 });
    defer r.deinit();
    fake_now = 100_000;
    r.fr.trigger(.slow_frame, "");
    r.fr.processTriggers();
    fake_now += 10;
    r.fr.trigger(.ui_stall, "");
    r.fr.processTriggers();
    try std.testing.expectEqual(@as(u32, 1), r.fr.stats().dumps);
    try std.testing.expectEqual(@as(u32, 1), r.fr.stats().suppressed);
    // Mailbox overflow is suppressed too.
    for (0..5) |_| r.fr.trigger(.manual, "");
    try std.testing.expectEqual(@as(u32, 2), r.fr.stats().suppressed);
    for (&r.fr.pending) |*p| p.state.store(0, .release);
    // File cap: with max_files = 2 never more than 2 dumps on disk.
    for (0..4) |_| {
        fake_now += 2000;
        r.fr.trigger(.manual, "");
        r.fr.processTriggers();
        try std.testing.expect(try r.files() <= 2);
        // Distinct names (the wall clock may not move between dumps).
        try std.testing.expect(std.mem.endsWith(u8, r.fr.stats().last_dump_path.?, ".pftrace"));
        try std.Io.sleep(std.testing.io, .fromMilliseconds(2), .awake);
    }
}

test "flight: trigger sources" {
    var r: TestRig = undefined;
    try r.init(.{ .dir = "", .worker = false });
    defer r.deinit();
    const hook = r.fr.slowFrameHook();
    hook.f(hook.ctx, &.{ .seq = 7 }, .frame_cpu);
    var rep: StallReport = .{ .duration_ns = 300 * std.time.ns_per_ms, .zone_stack = @splat(null), .depth = 0, .started_ns = 0, .sequence = 0 };
    FlightRecorder.onStall(r.fr, rep);
    rep.sequence = 1;
    FlightRecorder.onStall(r.fr, rep); // follow-ups do not re-trigger
    r.fr.onBudget(budget.evaluate(budget.get("input.key_to_photon"), 1e12, 1.0));
    var whys: [3]Trigger = undefined;
    var n: usize = 0;
    for (&r.fr.pending) |*p| if (p.state.load(.acquire) == 2) {
        whys[n] = p.why;
        n += 1;
    };
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(Trigger.slow_frame, whys[0]);
    try std.testing.expectEqual(Trigger.ui_stall, whys[1]);
    try std.testing.expectEqual(Trigger.budget_violation, whys[2]);
    try std.testing.expectEqualStrings("frame 7: frame_cpu", r.fr.pending[0].note[0..r.fr.pending[0].note_len]);
}

test "flight: disabled means no worker" {
    var drain = Drain.init(std.testing.allocator, std.testing.io);
    defer drain.deinit();
    const fr = try FlightRecorder.init(std.testing.allocator, std.testing.io, &drain, .{ .enabled = false, .dir = "unused" });
    try std.testing.expect(fr == null);
    for (drain.consumers) |c| try std.testing.expect(c == null);
}

test "flight: idle no wakeups" {
    var r: TestRig = undefined;
    try r.init(.{ .dir = "" });
    defer r.deinit();
    if (!r.fr.running) return error.SkipZigTest;
    try std.Io.sleep(std.testing.io, .fromMilliseconds(300), .awake);
    try std.testing.expectEqual(@as(u64, 0), r.fr.wakeups.load(.acquire));
}

test "flight: crash dump without gpa" {
    var r: TestRig = undefined;
    try r.init(.{ .dir = "", .worker = false });
    defer r.deinit();
    const site = zg_core.trace.siteFor(@src(), "gui.crash_context");
    var batch: [10_000]Event = undefined;
    for (&batch, 0..) |*e, i| e.* = zoneAt(site, i * 10, 5);
    r.fr.add(&batch);
    const gpa = r.fr.gpa;
    r.fr.gpa = std.testing.failing_allocator;
    const path = r.fr.dumpNowBlocking(std.math.maxInt(u64));
    r.fr.gpa = gpa;
    try std.testing.expect(path != null);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path.?, std.testing.allocator, .limited(4 << 20));
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "gui.crash_context") != null);
    try std.testing.expect(std.mem.endsWith(u8, path.?, "-crash.pftrace"));
    // Busy store: skipped.
    r.fr.mutex.lockUncancelable(std.testing.io);
    defer r.fr.mutex.unlock(std.testing.io);
    try std.testing.expect(r.fr.dumpNowBlocking(std.math.maxInt(u64)) == null);
}
