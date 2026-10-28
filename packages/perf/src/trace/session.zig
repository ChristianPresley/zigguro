//! `TraceSession` (E14.F02.S01.T02): start/stop capture into the chunked
//! store with a category filter and a size cap, then export to Perfetto or
//! Chrome JSON and write the file atomically. Also parses `ZG_TRACE` and
//! names the default trace folder.
//!
//! `start` and `stop`'s signal are cheap; the final drain, export and file
//! write in `stop` run on the calling thread, so the UI calls `stop` from a
//! worker (`io.async`/`io.concurrent`) and posts the `Summary` back.

const std = @import("std");
const builtin = @import("builtin");
const zg_core = @import("zg_core");
const categories = @import("categories.zig");
const Store = @import("store.zig").Store;
const Drain = @import("drain.zig").Drain;
const perfetto = @import("../export/perfetto.zig");
const chrome = @import("../export/chrome.zig");
const Redact = @import("../export/redact.zig").Redact;

const Category = categories.Category;
const Event = zg_core.trace.Event;
const Kind = zg_core.trace.Kind;
const Site = zg_core.trace.Site;
const log = std.log.scoped(.perf_trace);

/// Output formats.
pub const Format = enum {
    perfetto,
    chrome,

    /// `--trace-format=` values.
    pub fn parse(s: []const u8) ?Format {
        return std.meta.stringToEnum(Format, s);
    }

    /// The file extension for the format.
    pub fn extension(f: Format) []const u8 {
        return switch (f) {
            .perfetto => ".pftrace",
            .chrome => ".json",
        };
    }
};

/// Session options.
pub const SessionOptions = struct {
    categories: categories.Set = .initFull(),
    max_bytes: u64 = 256 << 20,
    format: Format = .perfetto,
    redact: Redact = .none,
    /// Keep `gpu.*` zones (the GPU track).
    include_gpu: bool = true,
    pid: i32 = 1,
    process_name: []const u8 = "zigguro",
};

/// What a stopped session wrote.
pub const Summary = struct {
    /// The file written (owned by the session).
    path: []const u8,
    events: u64,
    /// Ring overflows during the session (events lost before the drain).
    dropped: u64,
    /// File size.
    bytes: u64,
    duration_ns: u64,
    /// The size cap was hit; later events were discarded.
    truncated: bool,
};

var active_session: std.atomic.Value(bool) = .init(false);

const truncated_site: Site = .{ .name = "perf.trace_truncated", .file = "", .line = 0 };

/// A capture session. One at a time per process.
pub const TraceSession = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    drain: *Drain,
    path: []u8,
    opts: SessionOptions,
    store: Store,
    /// Site address -> category, computed once per site.
    cat_cache: std.AutoHashMapUnmanaged(usize, Category) = .empty,
    truncated: bool = false,
    dropped_at_start: u64,
    start_ns: u64,
    summary: ?Summary = null,

    /// Starts capturing into a session that will write `out_path`.
    /// `error.SessionActive` while another session runs.
    pub fn start(gpa: std.mem.Allocator, io: std.Io, drain: *Drain, out_path: []const u8, opts: SessionOptions) !*TraceSession {
        if (active_session.swap(true, .acq_rel)) return error.SessionActive;
        errdefer active_session.store(false, .release);
        // Events recorded before the session belong to nobody.
        drain.drainNow();
        const s = try gpa.create(TraceSession);
        errdefer gpa.destroy(s);
        const path = try gpa.dupe(u8, out_path);
        errdefer gpa.free(path);
        s.* = .{
            .gpa = gpa,
            .io = io,
            .drain = drain,
            .path = path,
            .opts = opts,
            .store = .init(gpa, opts.max_bytes),
            .dropped_at_start = zg_core.trace.droppedCount(),
            .start_ns = zg_core.time.nowNs(io),
        };
        try drain.add(.{ .ctx = s, .consume = consume });
        return s;
    }

    fn category(s: *TraceSession, e: Event) Category {
        const gop = s.cat_cache.getOrPut(s.gpa, e.site_or_name) catch return .other;
        if (!gop.found_existing) {
            const site: *const Site = @ptrFromInt(e.site_or_name);
            gop.value_ptr.* = categories.categoryOf(site.name);
        }
        return gop.value_ptr.*;
    }

    fn keep(s: *TraceSession, e: Event) bool {
        if (e.kind == @intFromEnum(Kind.thread_name)) return true;
        const c = s.category(e);
        if (c == .gpu and !s.opts.include_gpu) return false;
        // `perf.trace_truncated` and frame marks always pass.
        if (c == .other and e.site_or_name == @intFromPtr(&truncated_site)) return true;
        return s.opts.categories.contains(c);
    }

    fn consume(ctx: *anyopaque, evs: []const Event) void {
        const s: *TraceSession = @ptrCast(@alignCast(ctx));
        if (s.truncated) return;
        var run: usize = 0;
        for (evs, 0..) |e, i| {
            if (s.keep(e)) continue;
            s.append(evs[run..i]) catch return;
            run = i + 1;
        }
        s.append(evs[run..]) catch return;
    }

    fn append(s: *TraceSession, evs: []const Event) error{Full}!void {
        s.store.appendSlice(evs) catch |err| {
            s.truncated = true;
            // Lands in the ring; the store keeps it only if it fits, the
            // summary reports the truncation regardless.
            zg_core.trace.recordRaw(.instant, &truncated_site, 0);
            log.info("trace session hit its {d} byte cap; stopped collecting", .{s.opts.max_bytes});
            return err;
        };
    }

    /// Final drain, export and atomic write. Blocking: call from a worker.
    /// The session stays allocated (for `summary.path`) until `destroy`.
    pub fn stop(s: *TraceSession) !Summary {
        if (s.summary) |sum| return sum;
        s.drain.drainNow();
        s.drain.remove(s);
        active_session.store(false, .release);
        const end_ns = zg_core.time.nowNs(s.io);

        var events: std.ArrayList(Event) = .empty;
        defer events.deinit(s.gpa);
        try s.store.copyAll(s.gpa, &events);
        var out: std.Io.Writer.Allocating = .init(s.gpa);
        defer out.deinit();
        switch (s.opts.format) {
            .perfetto => {
                var w = perfetto.Writer.init(s.gpa, &out.writer, .{ .pid = s.opts.pid, .process_name = s.opts.process_name, .redact = s.opts.redact });
                defer w.deinit();
                try w.writeEvents(events.items);
                try w.finish();
            },
            .chrome => try chrome.writeChrome(s.gpa, events.items, .{ .pid = s.opts.pid, .process_name = s.opts.process_name, .redact = s.opts.redact }, &out.writer),
        }
        try writeFileAtomic(s.io, s.path, out.written());
        s.summary = .{
            .path = s.path,
            .events = s.store.events,
            .dropped = zg_core.trace.droppedCount() -| s.dropped_at_start,
            .bytes = out.written().len,
            .duration_ns = end_ns -| s.start_ns,
            .truncated = s.truncated,
        };
        return s.summary.?;
    }

    /// Frees the session (stops capture first if `stop` was not called;
    /// nothing is written then).
    pub fn destroy(s: *TraceSession) void {
        if (s.summary == null) {
            s.drain.remove(s);
            active_session.store(false, .release);
        }
        s.store.deinit();
        s.cat_cache.deinit(s.gpa);
        s.gpa.free(s.path);
        s.gpa.destroy(s);
    }
};

/// Writes `bytes` to `path` through a temp file renamed into place, so a
/// half-written trace never appears under `path`. Creates parent folders.
pub fn writeFileAtomic(io: std.Io, path: []const u8, bytes: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    var af = try cwd.createFileAtomic(io, path, .{ .replace = true, .make_path = true });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, bytes);
    try af.replace(io);
}

/// A `ZG_TRACE` request.
pub const EnvRequest = struct {
    /// Trace from startup to first frame + 2 s.
    startup: bool,
    /// The output path; null means the default trace folder.
    path: ?[]const u8,
};

/// Parses `ZG_TRACE`: `startup`, `<path>` or `startup:<path>`. Null for an
/// empty value. A Windows drive path (`C:\x`) is a path, not a prefix.
pub fn parseEnv(value: []const u8) ?EnvRequest {
    const v = std.mem.trim(u8, value, " \t");
    if (v.len == 0) return null;
    if (std.mem.eql(u8, v, "startup")) return .{ .startup = true, .path = null };
    if (std.mem.startsWith(u8, v, "startup:")) {
        const p = v["startup:".len..];
        return .{ .startup = true, .path = if (p.len == 0) null else p };
    }
    return .{ .startup = false, .path = v };
}

/// The default trace folder: `$XDG_STATE_HOME/zigguro/traces` (default
/// `~/.local/state`) on Linux and other Unixes,
/// `%LOCALAPPDATA%\zigguro\traces` on Windows. Null when the environment
/// names no such directory.
pub fn defaultTraceDir(arena: std.mem.Allocator, env: *const std.process.Environ.Map, os: std.Target.Os.Tag) std.mem.Allocator.Error!?[]const u8 {
    if (os == .windows) {
        const base = env.get("LOCALAPPDATA") orelse return null;
        return try std.mem.concat(arena, u8, &.{ std.mem.trimEnd(u8, base, "\\"), "\\zigguro\\traces" });
    }
    if (env.get("XDG_STATE_HOME")) |x| if (x.len > 0) return try std.mem.concat(arena, u8, &.{ std.mem.trimEnd(u8, x, "/"), "/zigguro/traces" });
    const home = env.get("HOME") orelse return null;
    if (home.len == 0) return null;
    return try std.mem.concat(arena, u8, &.{ std.mem.trimEnd(u8, home, "/"), "/.local/state/zigguro/traces" });
}

/// `<dir>/<prefix>-<unix_ms><ext>`.
pub fn tracePath(arena: std.mem.Allocator, dir: []const u8, prefix: []const u8, unix_ms: i64, format: Format) ![]const u8 {
    const sep: []const u8 = if (builtin.os.tag == .windows) "\\" else "/";
    return std.fmt.allocPrint(arena, "{s}{s}{s}-{d}{s}", .{ dir, sep, prefix, unix_ms, format.extension() });
}

test "env: parse variants" {
    try std.testing.expectEqual(@as(?EnvRequest, null), parseEnv(""));
    try std.testing.expectEqual(@as(?EnvRequest, null), parseEnv("  "));
    const a = parseEnv("startup").?;
    try std.testing.expect(a.startup and a.path == null);
    const b = parseEnv("startup:/tmp/s.pftrace").?;
    try std.testing.expect(b.startup);
    try std.testing.expectEqualStrings("/tmp/s.pftrace", b.path.?);
    const c = parseEnv("C:\\traces\\x.pftrace").?;
    try std.testing.expect(!c.startup);
    try std.testing.expectEqualStrings("C:\\traces\\x.pftrace", c.path.?);
    try std.testing.expect(parseEnv("startup:").?.path == null);
    try std.testing.expectEqual(Format.chrome, Format.parse("chrome").?);
    try std.testing.expectEqual(@as(?Format, null), Format.parse("svg"));
}

test "env: default trace dir" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expect(try defaultTraceDir(arena.allocator(), &env, .linux) == null);
    try env.put("HOME", "/home/u/");
    try std.testing.expectEqualStrings("/home/u/.local/state/zigguro/traces", (try defaultTraceDir(arena.allocator(), &env, .linux)).?);
    try env.put("XDG_STATE_HOME", "/s");
    try std.testing.expectEqualStrings("/s/zigguro/traces", (try defaultTraceDir(arena.allocator(), &env, .linux)).?);
    try env.put("LOCALAPPDATA", "C:\\Users\\u\\AppData\\Local");
    try std.testing.expectEqualStrings("C:\\Users\\u\\AppData\\Local\\zigguro\\traces", (try defaultTraceDir(arena.allocator(), &env, .windows)).?);
}

fn tmpPath(buf: []u8, tmp: *std.testing.TmpDir, name: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}/{s}", .{ &tmp.sub_path, name });
}

test "session: start/stop writes file and summary" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;
    const path = try tmpPath(&buf, &tmp, "sub/t.pftrace");
    var drain = Drain.init(gpa, io);
    defer drain.deinit();
    const s = try TraceSession.start(gpa, io, &drain, path, .{});
    defer s.destroy();
    zg_core.trace.setThreadName("test-main");
    zg_core.trace.zone(@src(), "perf.session_test").end();
    const sum = try s.stop();
    try std.testing.expectEqualStrings(path, sum.path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
    defer gpa.free(bytes);
    try std.testing.expectEqual(@as(u64, bytes.len), sum.bytes);
    try std.testing.expect(bytes.len > 0);
    if (zg_core.trace.enabled) try std.testing.expect(sum.events >= 1);
    // A second stop returns the same summary.
    try std.testing.expectEqual(sum.bytes, (try s.stop()).bytes);
}

test "session: category filter excludes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var drain = Drain.init(gpa, io);
    defer drain.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;
    const path = try tmpPath(&buf, &tmp, "f.json");
    const s = try TraceSession.start(gpa, io, &drain, path, .{ .categories = .initOne(.editor), .format = .chrome });
    defer s.destroy();
    const ed = zg_core.trace.siteFor(@src(), "editor.paint");
    const gui = zg_core.trace.siteFor(@src(), "gui.layout");
    const evs = [_]Event{
        .{ .ts = 1, .site_or_name = @intFromPtr(ed), .kind = @intFromEnum(Kind.zone), .tid = 1, .value = 5 },
        .{ .ts = 2, .site_or_name = @intFromPtr(gui), .kind = @intFromEnum(Kind.zone), .tid = 1, .value = 5 },
        .{ .ts = 3, .site_or_name = @intFromPtr(ed), .kind = @intFromEnum(Kind.zone), .tid = 1, .value = 5 },
    };
    TraceSession.consume(s, &evs);
    try std.testing.expectEqual(@as(u64, 2), s.store.events);
    const sum = try s.stop();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, sum.path, gpa, .limited(1 << 20));
    defer gpa.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "gui.layout") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "editor.paint") != null);
}

test "session: second start errors" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var drain = Drain.init(gpa, io);
    defer drain.deinit();
    const s = try TraceSession.start(gpa, io, &drain, "unused.pftrace", .{});
    try std.testing.expectError(error.SessionActive, TraceSession.start(gpa, io, &drain, "other.pftrace", .{}));
    s.destroy();
    // Destroyed without stop: a new session may start.
    const s2 = try TraceSession.start(gpa, io, &drain, "unused.pftrace", .{});
    s2.destroy();
}

test "session: size cap truncates" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var drain = Drain.init(gpa, io);
    defer drain.deinit();
    const s = try TraceSession.start(gpa, io, &drain, "unused.pftrace", .{ .max_bytes = 1 });
    defer s.destroy();
    const ed = zg_core.trace.siteFor(@src(), "editor.paint");
    var evs: [5000]Event = undefined;
    for (&evs, 0..) |*e, i| e.* = .{ .ts = i, .site_or_name = @intFromPtr(ed), .kind = @intFromEnum(Kind.instant), .tid = 1, .value = 0 };
    TraceSession.consume(s, &evs);
    try std.testing.expect(s.truncated);
    try std.testing.expectEqual(@as(u64, @import("store.zig").chunk_events), s.store.events);
    // Drain the truncation marker so it does not leak into later tests.
    drain.drainNow();
}
