//! OS trace bridges (E14.F02.S03.T01): mirror selected zigguro zones,
//! frames and instants into ftrace (Linux) or ETW (Windows) so system
//! profilers show them next to CPU samples and kernel events.
//!
//! Off by default (`ZG_OS_TRACE=ftrace|etw` or the `perf.osTrace` setting
//! turns it on). Zones reach the bridge through the per-thread
//! `zg_core.trace.zone_hook`, so with the bridge off no hook is installed
//! and zones cost nothing extra; `enableForCurrentThread` installs it on a
//! thread, chaining any hook already there (the stall watchdog's shadow
//! stack). Only zones in `categories` (default gui, render, startup, perf)
//! are mirrored, synchronously on the emitting thread.

const std = @import("std");
const builtin = @import("builtin");
const zg_core = @import("zg_core");
const categories = @import("../trace/categories.zig");
const ftrace = @import("linux_trace_marker.zig");
const etw = @import("etw.zig");

const Site = zg_core.trace.Site;
const log = std.log.scoped(.perf_os_trace);

/// The bridge.
pub const OsTrace = struct {
    kind: Kind = .none,
    io: ?std.Io = null,
    marker: ?ftrace.TraceMarker = null,
    provider: etw.Provider = .{},
    categories: categories.Set = default_categories,

    /// Bridge kinds.
    pub const Kind = enum {
        none,
        ftrace,
        etw,

        /// `ZG_OS_TRACE` / `perf.osTrace` values (`off` is `none`).
        pub fn parse(s: []const u8) ?Kind {
            if (std.mem.eql(u8, s, "off") or s.len == 0) return .none;
            return std.meta.stringToEnum(Kind, s);
        }
    };

    /// Zones mirrored by default.
    pub const default_categories: categories.Set = .initMany(&.{ .gui, .render, .startup, .perf });

    /// The bridge zone hooks and `frame`/`instant` feed; set by `init`.
    pub var global: std.atomic.Value(?*OsTrace) = .init(null);

    /// Opens the backend into `t` (which must not move) and makes it
    /// global. Falls back to `.none` (logged) when the backend is not
    /// available on this OS or cannot open.
    pub fn init(t: *OsTrace, kind: Kind, io: std.Io) void {
        t.* = .{ .io = io };
        switch (kind) {
            .none => return,
            .ftrace => {
                t.marker = ftrace.TraceMarker.open(io, &ftrace.default_paths) orelse {
                    log.warn("ftrace markers unavailable (try as root, or mount tracefs); OS tracing is off", .{});
                    return;
                };
            },
            .etw => {
                if (!t.provider.register()) {
                    log.warn("ETW provider unavailable on this system; OS tracing is off", .{});
                    return;
                }
            },
        }
        t.kind = kind;
        zg_core.time.setFallbackIo(io);
        global.store(t, .release);
    }

    /// Closes the backend. Threads keep their hooks, which then see no
    /// global bridge and only chain.
    pub fn deinit(t: *OsTrace) void {
        if (global.load(.acquire) == t) global.store(null, .release);
        if (t.marker) |m| m.close();
        t.provider.unregister();
        t.kind = .none;
    }

    fn tid() u32 {
        return @truncate(@as(u64, @intCast(std.Thread.getCurrentId())));
    }

    /// A frame was presented.
    pub fn frame(t: *OsTrace, seq: u64) void {
        switch (t.kind) {
            .none => {},
            .ftrace => {
                var buf: [ftrace.max_record]u8 = undefined;
                t.marker.?.write(ftrace.formatFrame(&buf, seq));
            },
            .etw => t.provider.frame(seq),
        }
    }

    /// A zone opened on this thread.
    pub fn zoneBegin(t: *OsTrace, name: []const u8) void {
        switch (t.kind) {
            .none => {},
            .ftrace => {
                var buf: [ftrace.max_record]u8 = undefined;
                t.marker.?.write(ftrace.formatBegin(&buf, tid(), name));
            },
            .etw => t.provider.zoneBegin(name, tid()),
        }
    }

    /// The zone opened last on this thread closed after `dur_ns`.
    pub fn zoneEnd(t: *OsTrace, name: []const u8, dur_ns: u64) void {
        switch (t.kind) {
            .none => {},
            .ftrace => {
                var buf: [ftrace.max_record]u8 = undefined;
                t.marker.?.write(ftrace.formatEnd(&buf, tid(), name, dur_ns));
            },
            .etw => t.provider.zone(name, dur_ns),
        }
    }

    /// A point event.
    pub fn instant(t: *OsTrace, name: []const u8, value: i64) void {
        switch (t.kind) {
            .none => {},
            .ftrace => {
                var buf: [ftrace.max_record]u8 = undefined;
                t.marker.?.write(ftrace.formatInstant(&buf, name, value));
            },
            .etw => t.provider.instant(name, value),
        }
    }
};

/// Reports a presented frame to the global bridge (one atomic load when
/// off).
pub fn frame(seq: u64) void {
    if (OsTrace.global.load(.acquire)) |t| t.frame(seq);
}

/// Reports an instant to the global bridge.
pub fn instant(name: []const u8, value: i64) void {
    if (OsTrace.global.load(.acquire)) |t| t.instant(name, value);
}

// ---- the per-thread zone hook ----

const max_depth = 32;

const Open = struct { site: *const Site, start_ns: u64, mirrored: bool };

threadlocal var stack: [max_depth]Open = undefined;
threadlocal var depth: u32 = 0;
/// The hook this thread had before ours (chained).
threadlocal var previous: ?*const zg_core.trace.ZoneHook = null;
threadlocal var installed: bool = false;

const hook: zg_core.trace.ZoneHook = .{ .begin = onBegin, .end = onEnd };

fn onBegin(site: *const Site) void {
    if (previous) |p| p.begin(site);
    const t = OsTrace.global.load(.acquire);
    const mirrored = if (t) |b| b.categories.contains(categories.categoryOf(site.name)) else false;
    if (depth < max_depth) {
        stack[depth] = .{ .site = site, .start_ns = if (mirrored) zg_core.time.nowNs(t.?.io.?) else 0, .mirrored = mirrored };
    }
    depth += 1;
    if (mirrored) t.?.zoneBegin(site.name);
}

fn onEnd() void {
    if (previous) |p| p.end();
    if (depth == 0) return;
    depth -= 1;
    if (depth >= max_depth) return;
    const o = stack[depth];
    if (!o.mirrored) return;
    const t = OsTrace.global.load(.acquire) orelse return;
    t.zoneEnd(o.site.name, zg_core.time.nowNs(t.io.?) -| o.start_ns);
}

/// Installs the bridge's zone hook on the calling thread (idempotent),
/// chaining the hook already there. Call it after the shadow stack's
/// `enableForCurrentThread` on threads that use both.
pub fn enableForCurrentThread() void {
    if (installed) return;
    installed = true;
    previous = zg_core.trace.zone_hook;
    zg_core.trace.zone_hook = &hook;
}

/// Removes the hook from the calling thread, restoring the previous one.
pub fn disableForCurrentThread() void {
    if (!installed) return;
    installed = false;
    zg_core.trace.zone_hook = previous;
    previous = null;
    depth = 0;
}

test "os trace: kind parse and none is inert" {
    try std.testing.expectEqual(OsTrace.Kind.ftrace, OsTrace.Kind.parse("ftrace").?);
    try std.testing.expectEqual(OsTrace.Kind.none, OsTrace.Kind.parse("off").?);
    try std.testing.expectEqual(@as(?OsTrace.Kind, null), OsTrace.Kind.parse("dtrace"));
    var t: OsTrace = undefined;
    t.init(.none, std.testing.io);
    defer t.deinit();
    try std.testing.expect(OsTrace.global.load(.acquire) == null);
    t.frame(1);
    t.zoneBegin("gui.frame");
    t.zoneEnd("gui.frame", 1);
}

test "os trace: hook mirrors selected categories to ftrace and chains" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "marker", .data = "" });
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPathFile(io, "marker", &pbuf);

    var t: OsTrace = .{ .io = io, .kind = .ftrace, .marker = ftrace.TraceMarker.open(io, &.{pbuf[0..n]}).? };
    OsTrace.global.store(&t, .release);
    defer t.deinit();

    // A previous hook (like the shadow stack) keeps working.
    const Prev = struct {
        var begins: usize = 0;
        var ends: usize = 0;
        fn b(_: *const Site) void {
            begins += 1;
        }
        fn e() void {
            ends += 1;
        }
        const h: zg_core.trace.ZoneHook = .{ .begin = b, .end = e };
    };
    zg_core.trace.zone_hook = &Prev.h;
    defer zg_core.trace.zone_hook = null;
    enableForCurrentThread();
    defer disableForCurrentThread();

    const gui: Site = .{ .name = "gui.layout", .file = "", .line = 0 };
    const ed: Site = .{ .name = "editor.paint", .file = "", .line = 0 };
    // Drive the hook directly (zones compile out with tracing off).
    hook.begin(&gui);
    hook.begin(&ed);
    hook.end();
    hook.end();
    frame(5);
    try std.testing.expectEqual(@as(usize, 2), Prev.begins);
    try std.testing.expectEqual(@as(usize, 2), Prev.ends);
    t.marker.?.close();
    t.marker = null;
    const got = try tmp.dir.readFileAlloc(io, "marker", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "zg:B|") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "|gui.layout") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "editor.paint") == null);
    try std.testing.expect(std.mem.indexOf(u8, got, "zg:E|") != null);
    try std.testing.expect(std.mem.endsWith(u8, got, "zg:F|5"));
}
