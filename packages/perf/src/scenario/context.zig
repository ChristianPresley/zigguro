//! The scenario context (E14.F06.S01.T02): what a scenario body measures
//! with. Each metric collects one sample per measurement; `writeJson`
//! writes them as E00 bench JSON with the results named
//! `<scenario>.<metric>` and every sample in `samples_ns`, which perfgate
//! compares with Mann–Whitney.

const std = @import("std");
const builtin = @import("builtin");
const zg_core = @import("zg_core");
const Pcts = @import("../startup/bench.zig").Pcts;

/// A start/stop stopwatch on the monotonic clock.
pub const Measurement = struct {
    io: std.Io,
    start_ns: u64 = 0,
    stop_ns: u64 = 0,

    pub fn start(m: *Measurement) void {
        m.start_ns = zg_core.time.nowNs(m.io);
        m.stop_ns = m.start_ns;
    }

    pub fn stop(m: *Measurement) void {
        m.stop_ns = zg_core.time.nowNs(m.io);
    }

    pub fn sampleNs(m: *const Measurement) u64 {
        return m.stop_ns -| m.start_ns;
    }
};

/// Facts written next to the results.
pub const Meta = struct {
    platform: []const u8 = "",
    machine: []const u8 = "",
    quick: bool = false,
    /// `Env` as JSON (written verbatim under "env" when set).
    env_json: ?[]const u8 = null,
};

pub const Context = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// The running scenario's name (the result prefix).
    scenario: []const u8 = "",
    /// Smaller inputs and fewer repeats (CI smoke runs).
    quick: bool = false,
    /// The current repeat, from 0.
    repeat: u32 = 0,
    /// The scenario's own state.
    user: ?*anyopaque = null,
    /// Warm-up: `record` drops samples.
    discard: bool = false,
    metrics: std.StringArrayHashMapUnmanaged(std.ArrayList(u64)) = .empty,
    names: std.heap.ArenaAllocator,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Context {
        return .{ .gpa = gpa, .io = io, .names = .init(gpa) };
    }

    pub fn deinit(c: *Context) void {
        for (c.metrics.values()) |*v| v.deinit(c.gpa);
        c.metrics.deinit(c.gpa);
        c.names.deinit();
    }

    /// The scenario's state as `T`.
    pub fn state(c: *Context, comptime T: type) *T {
        return @ptrCast(@alignCast(c.user.?));
    }

    /// A stopwatch on this context's clock.
    pub fn measurement(c: *Context) Measurement {
        return .{ .io = c.io };
    }

    /// Adds one sample of `metric` (named `<scenario>.<metric>`).
    pub fn record(c: *Context, metric: []const u8, ns: u64) !void {
        if (c.discard) return;
        const full = try std.fmt.allocPrint(c.names.allocator(), "{s}.{s}", .{ c.scenario, metric });
        const gop = try c.metrics.getOrPut(c.gpa, full);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(c.gpa, ns);
    }

    /// Times `f(args)` and records it as `metric`; returns its result.
    pub fn measure(c: *Context, metric: []const u8, f: anytype, args: anytype) !MeasureResult(@TypeOf(f)) {
        var m = c.measurement();
        m.start();
        const r = @call(.auto, f, args);
        m.stop();
        try c.record(metric, m.sampleNs());
        return r;
    }

    fn MeasureResult(comptime F: type) type {
        const R = @typeInfo(F).@"fn".return_type.?;
        return switch (@typeInfo(R)) {
            .error_union => |eu| eu.payload,
            else => R,
        };
    }

    /// The samples of `<scenario>.<metric>` (full name).
    pub fn samples(c: *const Context, full_name: []const u8) ?[]const u64 {
        const v = c.metrics.getPtr(full_name) orelse return null;
        return v.items;
    }

    /// Writes E00 bench JSON (schema 1, package `scenarios`).
    pub fn writeJson(c: *Context, w: *std.Io.Writer, meta: Meta) !void {
        var s: std.json.Stringify = .{ .writer = w, .options = .{ .whitespace = .indent_2 } };
        try s.beginObject();
        try s.objectField("schema");
        try s.write(@as(u32, 1));
        try s.objectField("package");
        try s.write("scenarios");
        try s.objectField("zig");
        try s.write(builtin.zig_version_string);
        try s.objectField("target");
        try s.write(@tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag));
        try s.objectField("optimize");
        try s.write(@tagName(builtin.mode));
        try s.objectField("cpu");
        try s.write(builtin.cpu.model.name);
        try s.objectField("quick");
        try s.write(meta.quick);
        try s.objectField("platform");
        try s.write(meta.platform);
        try s.objectField("machine");
        try s.write(meta.machine);
        if (meta.env_json) |e| {
            try s.objectField("env");
            try s.print("{s}", .{e});
        }
        try s.objectField("results");
        try s.beginArray();
        for (c.metrics.keys(), c.metrics.values()) |name, *v| {
            if (v.items.len == 0) continue;
            const sorted = try c.gpa.dupe(u64, v.items);
            defer c.gpa.free(sorted);
            const p = Pcts.of(sorted);
            try s.beginObject();
            try s.objectField("name");
            try s.write(name);
            try s.objectField("iters");
            try s.write(p.count);
            try s.objectField("ns_per_op");
            try s.write(p.mean_ns);
            try s.objectField("p50_ns");
            try s.write(p.p50_ns);
            try s.objectField("p95_ns");
            try s.write(p.p95_ns);
            try s.objectField("p99_ns");
            try s.write(p.p99_ns);
            try s.objectField("max_ns");
            try s.write(p.max_ns);
            try s.objectField("allocs_per_op");
            try s.write(@as(f64, 0));
            try s.objectField("bytes_alloc_per_op");
            try s.write(@as(f64, 0));
            try s.objectField("samples_ns");
            try s.write(v.items);
            try s.endObject();
        }
        try s.endArray();
        try s.endObject();
        try w.writeAll("\n");
    }
};

fn work(n: u64) u64 {
    var x: u64 = 0;
    for (0..n) |i| x +%= i *% 31;
    return x;
}

fn failing() !u32 {
    return error.Nope;
}

test "scenario: context measure" {
    const gpa = std.testing.allocator;
    var c: Context = .init(gpa, std.testing.io);
    defer c.deinit();
    c.scenario = "demo";
    for (0..3) |_| {
        const r = try c.measure("work", work, .{@as(u64, 1000)});
        try std.testing.expectEqual(work(1000), r);
    }
    try c.record("manual", 1234);
    try std.testing.expectEqual(@as(usize, 3), c.samples("demo.work").?.len);
    try std.testing.expectEqual(@as(u64, 1234), c.samples("demo.manual").?[0]);
    try std.testing.expectError(error.Nope, c.measure("fail", failing, .{}));

    var m = c.measurement();
    m.start();
    m.stop();
    try std.testing.expect(m.sampleNs() < std.time.ns_per_s);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try c.writeJson(&aw.writer, .{ .platform = "headless", .env_json = "{\"os\":\"linux\"}" });
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, aw.written(), .{});
    defer parsed.deinit();
    const results = parsed.value.object.get("results").?.array.items;
    try std.testing.expectEqualStrings("demo.work", results[0].object.get("name").?.string);
    try std.testing.expectEqual(@as(usize, 3), results[0].object.get("samples_ns").?.array.items.len);
    try std.testing.expectEqualStrings("linux", parsed.value.object.get("env").?.object.get("os").?.string);
    // perfgate reads it as a bench file.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    _ = try @import("../budget/bench_bind.zig").parseBenchFile(arena.allocator(), aw.written());
}
