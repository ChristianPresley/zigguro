//! The app-wide `std.options.logFn`: formats into a fixed record without
//! allocating, stores it in an in-memory ring (for the UI log view and crash
//! reports) and lets a background flusher write it to the sinks (stderr,
//! a rotating file, custom sinks).
//!
//! Apps set:
//! ```zig
//! pub const std_options: std.Options = .{ .logFn = zg_core.log.logFn, .log_level = .debug };
//! ```
//!
//! Before `install`, `logFn` forwards to `std.log.defaultLog` so early errors
//! stay visible. Level filtering by `std_options.log_level` is comptime (a
//! filtered call costs nothing); `setLevel` adds a runtime override on top.
//!
//! Ring implementation: a `std.Io.Mutex`-protected overwrite ring (the
//! simple first version allowed by E00.F04.S03.T01). The critical section is
//! a 512-byte copy; sinks run on the flusher, never in `logFn`.

const std = @import("std");
const Runtime = @import("runtime/Runtime.zig");
const Subsystem = @import("runtime/task.zig").Subsystem;

/// Maximum message bytes per record; longer messages end in "…".
pub const max_msg = 480;

/// One log record (plain data, copied by value).
pub const Record = struct {
    /// `.real` clock nanoseconds since the Unix epoch.
    ts_ns: i96,
    thread: u32,
    level: std.log.Level,
    scope_len: u8,
    scope: [16]u8,
    msg_len: u16,
    msg: [max_msg]u8,

    /// The scope name.
    pub fn scopeName(r: *const Record) []const u8 {
        return r.scope[0..r.scope_len];
    }

    /// The formatted message.
    pub fn message(r: *const Record) []const u8 {
        return r.msg[0..r.msg_len];
    }
};

/// A log destination. `writeFn` runs on the flusher task, never in `logFn`.
pub const Sink = struct {
    ctx: ?*anyopaque,
    writeFn: *const fn (?*anyopaque, *const Record) void,
};

/// Options for `install`.
pub const InstallOptions = struct {
    /// Directory for `zigguro.log` (resolved by E01/E15); null disables the file sink.
    file_dir: ?std.Io.Dir = null,
    /// Also write to stderr.
    stderr: bool = true,
    /// Ring capacity in records (power of two).
    ring_capacity: u32 = 8192,
    /// Rotate the log file at this size; keeps `file_keep` older files.
    file_max_bytes: u64 = 8 << 20,
    file_keep: u8 = 2,
    /// Flusher period.
    flush_interval: std.Io.Duration = .fromMilliseconds(50),
};

const max_sinks = 8;
const max_overrides = 16;
const flush_batch = 256;

const Override = struct {
    used: std.atomic.Value(bool) = .init(false),
    scope_len: u8 = 0,
    scope: [16]u8 = @splat(0),
    level: std.atomic.Value(u8) = .init(0),
};

const State = struct {
    rt: *Runtime,
    mutex: std.Io.Mutex = .init,
    ring: []Record,
    /// Total records ever written (monotonic); ring slot = seq & (len - 1).
    seq: u64 = 0,
    flushed: u64 = 0,
    dropped: u64 = 0,
    batch: []Record,
    wake: std.Io.Event = .unset,
    sub: Subsystem,
    file: ?FileSink = null,
    stderr: bool,
    interval: std.Io.Duration,
};

var state: ?*State = null;
var sinks: [max_sinks]Sink = undefined;
var sink_count: std.atomic.Value(u32) = .init(0);
var overrides: [max_overrides]Override = @splat(.{});

/// Routes `std.log` through zg_core. Never allocates; never calls sinks.
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const st = state orelse return std.log.defaultLog(level, scope, format, args);
    if (!runtimeEnabled(@tagName(scope), level)) return;
    var rec: Record = undefined;
    fillRecord(&rec, st.rt.io, level, @tagName(scope), format, args);
    push(st, &rec);
}

fn fillRecord(rec: *Record, io: std.Io, level: std.log.Level, scope: []const u8, comptime format: []const u8, args: anytype) void {
    rec.ts_ns = std.Io.Timestamp.now(io, .real).nanoseconds;
    rec.thread = @truncate(@as(u64, @intCast(std.Thread.getCurrentId())));
    rec.level = level;
    const sl = @min(scope.len, rec.scope.len);
    @memcpy(rec.scope[0..sl], scope[0..sl]);
    rec.scope_len = @intCast(sl);
    var w: std.Io.Writer = .fixed(&rec.msg);
    w.print(format, args) catch {
        const ellipsis = "\u{2026}";
        var end = rec.msg.len - ellipsis.len;
        // Do not cut a UTF-8 sequence in half.
        while (end > 0 and (rec.msg[end] & 0xC0) == 0x80) end -= 1;
        @memcpy(rec.msg[end..][0..ellipsis.len], ellipsis);
        rec.msg_len = @intCast(end + ellipsis.len);
        return;
    };
    rec.msg_len = @intCast(w.end);
}

fn push(st: *State, rec: *const Record) void {
    st.mutex.lockUncancelable(st.rt.io);
    st.ring[@intCast(st.seq & (st.ring.len - 1))] = rec.*;
    st.seq += 1;
    const backlog = st.seq - st.flushed;
    st.mutex.unlock(st.rt.io);
    if (backlog >= flush_batch) st.wake.set(st.rt.io);
}

fn runtimeEnabled(scope: []const u8, level: std.log.Level) bool {
    for (&overrides) |*o| {
        if (!o.used.load(.acquire)) continue;
        if (o.scope_len == 0 or std.mem.eql(u8, o.scope[0..o.scope_len], scope)) {
            return @intFromEnum(level) <= o.level.load(.monotonic);
        }
    }
    return true;
}

/// Sets a runtime level for `scope` (or for every scope when null). Only
/// further restricts what `std_options.log_level` already lets through.
pub fn setLevel(scope: ?[]const u8, level: std.log.Level) void {
    const name = scope orelse "";
    for (&overrides) |*o| {
        if (o.used.load(.acquire) and std.mem.eql(u8, o.scope[0..o.scope_len], name)) {
            o.level.store(@intFromEnum(level), .monotonic);
            return;
        }
    }
    for (&overrides) |*o| {
        if (o.used.load(.acquire)) continue;
        const n = @min(name.len, o.scope.len);
        @memcpy(o.scope[0..n], name[0..n]);
        o.scope_len = @intCast(n);
        o.level.store(@intFromEnum(level), .monotonic);
        o.used.store(true, .release);
        return;
    }
}

/// Removes every runtime level override.
pub fn clearLevels() void {
    for (&overrides) |*o| o.used.store(false, .release);
}

/// Adds a sink (at most 8; extra sinks are ignored). Call before or after
/// `install`; sinks are never removed.
pub fn addSink(s: Sink) void {
    const i = sink_count.load(.acquire);
    if (i >= max_sinks) return;
    sinks[i] = s;
    sink_count.store(i + 1, .release);
}

/// Installs the logger on `rt`: allocates the ring, opens the log file and
/// starts the flusher. Call once, after `Runtime.init`.
pub fn install(rt: *Runtime, opts: InstallOptions) !void {
    std.debug.assert(std.math.isPowerOfTwo(opts.ring_capacity));
    const st = try rt.gpa.create(State);
    errdefer rt.gpa.destroy(st);
    const ring = try rt.gpa.alloc(Record, opts.ring_capacity);
    errdefer rt.gpa.free(ring);
    const batch = try rt.gpa.alloc(Record, flush_batch);
    errdefer rt.gpa.free(batch);
    st.* = .{
        .rt = rt,
        .ring = ring,
        .batch = batch,
        .sub = .init(rt.io),
        .stderr = opts.stderr,
        .interval = opts.flush_interval,
    };
    if (opts.file_dir) |dir| st.file = try FileSink.open(rt.io, dir, opts.file_max_bytes, opts.file_keep);
    state = st;
    st.sub.spawnLoop(flusher, .{st}) catch |err| {
        state = null;
        if (st.file) |*f| f.close();
        return err;
    };
}

/// Stops the flusher, flushes what is left and frees the logger. After
/// this, `logFn` forwards to `std.log.defaultLog` again.
pub fn uninstall() void {
    const st = state orelse return;
    st.sub.shutdown();
    flushOnce(st);
    state = null;
    if (st.file) |*f| f.close();
    const gpa = st.rt.gpa;
    gpa.free(st.ring);
    gpa.free(st.batch);
    gpa.destroy(st);
}

/// Writes pending records to the sinks now (synchronously). Mainly for
/// crash paths and tests.
pub fn flush() void {
    if (state) |st| flushOnce(st);
}

fn flusher(st: *State) std.Io.Cancelable!void {
    while (true) {
        st.wake.waitTimeout(st.rt.io, .{ .duration = .{ .raw = st.interval, .clock = .awake } }) catch |err| switch (err) {
            error.Timeout => {},
            error.Canceled => return error.Canceled,
        };
        st.wake.reset();
        // Sink I/O swallows errors, so it must not consume a cancel request:
        // block cancellation while flushing; the next wait observes it.
        const prev = st.rt.io.swapCancelProtection(.blocked);
        flushOnce(st);
        _ = st.rt.io.swapCancelProtection(prev);
    }
}

var flush_lock: std.Io.Mutex = .init;

fn flushOnce(st: *State) void {
    const io = st.rt.io;
    flush_lock.lockUncancelable(io);
    defer flush_lock.unlock(io);
    while (true) {
        st.mutex.lockUncancelable(io);
        if (st.seq - st.flushed > st.ring.len) {
            st.dropped += st.seq - st.flushed - st.ring.len;
            st.flushed = st.seq - st.ring.len;
        }
        const n: usize = @intCast(@min(st.seq - st.flushed, st.batch.len));
        for (0..n) |i| st.batch[i] = st.ring[@intCast((st.flushed + i) & (st.ring.len - 1))];
        st.flushed += n;
        st.mutex.unlock(io);
        if (n == 0) return;
        for (st.batch[0..n]) |*r| deliver(st, r);
        if (st.file) |*f| f.flushBuffered();
    }
}

fn deliver(st: *State, r: *const Record) void {
    if (st.stderr) {
        var buf: [64]u8 = undefined;
        const stderr = std.debug.lockStderr(&buf).terminal();
        defer std.debug.unlockStderr();
        writeLine(stderr.writer, r) catch {};
    }
    if (st.file) |*f| f.write(r);
    const n = sink_count.load(.acquire);
    for (sinks[0..n]) |s| s.writeFn(s.ctx, r);
}

/// Formats `r` as one text line: `<level>(<scope>): <message>\n`.
pub fn writeLine(w: *std.Io.Writer, r: *const Record) std.Io.Writer.Error!void {
    const text = switch (r.level) {
        .err => "error",
        .warn => "warning",
        .info => "info",
        .debug => "debug",
    };
    try w.print("{s}({s}): {s}\n", .{ text, r.scopeName(), r.message() });
}

/// Copies up to `max` of the most recent records, oldest first. Caller
/// owns the returned slice.
pub fn snapshot(gpa: std.mem.Allocator, max: usize) ![]Record {
    const st = state orelse return gpa.alloc(Record, 0);
    const io = st.rt.io;
    st.mutex.lockUncancelable(io);
    defer st.mutex.unlock(io);
    const avail: usize = @intCast(@min(st.seq, st.ring.len));
    const n = @min(avail, max);
    const out = try gpa.alloc(Record, n);
    const start = st.seq - n;
    for (0..n) |i| out[i] = st.ring[@intCast((start + i) & (st.ring.len - 1))];
    return out;
}

/// Records lost because the flusher fell more than a ring behind.
pub fn droppedCount() u64 {
    const st = state orelse return 0;
    st.mutex.lockUncancelable(st.rt.io);
    defer st.mutex.unlock(st.rt.io);
    return st.dropped;
}

/// Size-rotating file sink: `zigguro.log`, rotated to `zigguro.log.1` ...
/// `zigguro.log.<keep>` when it reaches `max_bytes`.
const FileSink = struct {
    io: std.Io,
    dir: std.Io.Dir,
    file: std.Io.File,
    offset: u64,
    max_bytes: u64,
    keep: u8,
    buf: [8192]u8 = undefined,
    len: usize = 0,

    const name = "zigguro.log";

    fn open(io: std.Io, dir: std.Io.Dir, max_bytes: u64, keep: u8) !FileSink {
        // Readable so `length` works on Windows (a write-only handle can't
        // read attributes, which would restart the log at offset 0).
        const file = try dir.createFile(io, name, .{ .truncate = false, .read = true });
        const len = file.length(io) catch 0;
        return .{ .io = io, .dir = dir, .file = file, .offset = len, .max_bytes = max_bytes, .keep = keep };
    }

    fn write(f: *FileSink, r: *const Record) void {
        var line: [max_msg + 64]u8 = undefined;
        var w: std.Io.Writer = .fixed(&line);
        writeLine(&w, r) catch {};
        const bytes = w.buffered();
        if (f.len + bytes.len > f.buf.len) f.flushBuffered();
        @memcpy(f.buf[f.len..][0..bytes.len], bytes);
        f.len += bytes.len;
    }

    fn flushBuffered(f: *FileSink) void {
        if (f.len == 0) return;
        f.file.writePositionalAll(f.io, f.buf[0..f.len], f.offset) catch {};
        f.offset += f.len;
        f.len = 0;
        if (f.offset >= f.max_bytes) f.rotate();
    }

    fn rotate(f: *FileSink) void {
        f.file.close(f.io);
        var i: u8 = f.keep;
        while (i > 0) : (i -= 1) {
            var from_buf: [32]u8 = undefined;
            var to_buf: [32]u8 = undefined;
            const from = if (i == 1) name else std.fmt.bufPrint(&from_buf, name ++ ".{d}", .{i - 1}) catch unreachable;
            const to = std.fmt.bufPrint(&to_buf, name ++ ".{d}", .{i}) catch unreachable;
            f.dir.rename(from, f.dir, to, f.io) catch {};
        }
        f.file = f.dir.createFile(f.io, name, .{}) catch {
            f.max_bytes = std.math.maxInt(u64);
            return;
        };
        f.offset = 0;
    }

    fn close(f: *FileSink) void {
        f.flushBuffered();
        f.file.close(f.io);
    }
};

test "log: ring receives records from 8 threads" {
    var rt: Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    try install(&rt, .{ .stderr = false, .ring_capacity = 1024 });
    defer uninstall();
    const Worker = struct {
        fn run(id: usize) void {
            for (0..50) |i| logFn(.info, .worker, "thread {d} msg {d}", .{ id, i });
        }
    };
    var threads: [8]std.Thread = undefined;
    for (&threads, 0..) |*t, id| t.* = try std.Thread.spawn(.{}, Worker.run, .{id});
    for (threads) |t| t.join();
    const snap = try snapshot(std.testing.allocator, 1024);
    defer std.testing.allocator.free(snap);
    try std.testing.expectEqual(@as(usize, 400), snap.len);
    try std.testing.expectEqualStrings("worker", snap[0].scopeName());
}

test "log: long message truncated with ellipsis" {
    var rt: Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    try install(&rt, .{ .stderr = false, .ring_capacity = 16 });
    defer uninstall();
    const long = "é" ** 400; // 800 bytes, 2-byte sequences
    logFn(.warn, .t, "{s}", .{long});
    const snap = try snapshot(std.testing.allocator, 1);
    defer std.testing.allocator.free(snap);
    const m = snap[0].message();
    try std.testing.expect(m.len <= max_msg);
    try std.testing.expect(std.mem.endsWith(u8, m, "\u{2026}"));
    try std.testing.expect(std.unicode.utf8ValidateSlice(m));
}

test "log: runtime level override filters" {
    var rt: Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    try install(&rt, .{ .stderr = false, .ring_capacity = 16 });
    defer uninstall();
    defer clearLevels();
    setLevel("noisy", .warn);
    logFn(.info, .noisy, "dropped", .{});
    logFn(.warn, .noisy, "kept", .{});
    logFn(.info, .other, "kept too", .{});
    const snap = try snapshot(std.testing.allocator, 16);
    defer std.testing.allocator.free(snap);
    try std.testing.expectEqual(@as(usize, 2), snap.len);
    try std.testing.expectEqualStrings("kept", snap[0].message());
}

test "log: file sink rotates at limit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var rt: Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    try install(&rt, .{ .stderr = false, .file_dir = tmp.dir, .file_max_bytes = 1024, .file_keep = 2 });
    for (0..100) |i| {
        logFn(.info, .file, "line {d} padding padding padding padding", .{i});
        if (i % 10 == 0) flush();
    }
    uninstall();
    const io = std.testing.io;
    try tmp.dir.access(io, "zigguro.log", .{});
    try tmp.dir.access(io, "zigguro.log.1", .{});
    try tmp.dir.access(io, "zigguro.log.2", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "zigguro.log.3", .{}));
}

test "log: custom sink receives flushed records" {
    var rt: Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    const Counter = struct {
        var n: std.atomic.Value(u32) = .init(0);
        fn write(_: ?*anyopaque, r: *const Record) void {
            if (std.mem.eql(u8, r.scopeName(), "sinktest")) _ = n.fetchAdd(1, .monotonic);
        }
    };
    addSink(.{ .ctx = null, .writeFn = Counter.write });
    try install(&rt, .{ .stderr = false, .ring_capacity = 64 });
    for (0..5) |_| logFn(.info, .sinktest, "x", .{});
    flush();
    uninstall();
    try std.testing.expectEqual(@as(u32, 5), Counter.n.load(.monotonic));
}
