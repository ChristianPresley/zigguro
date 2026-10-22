const std = @import("std");
const proto = @import("zg_ai_proto");
const sched = @import("scheduler.zig");

const testing = std.testing;
const io = testing.io;
const Io = std.Io;
const ToolOutput = proto.ToolOutput;

fn noop(_: *anyopaque, _: *proto.ToolCall) proto.ToolError!ToolOutput {
    return error.Failed;
}
var dummy: u8 = 0;
const read_spec: proto.ToolSpec = .{ .name = "read", .description = "", .input_schema_json = "{}", .read_only = true, .handler = .{ .ctx = &dummy, .call = noop } };
const write_spec: proto.ToolSpec = .{ .name = "write", .description = "", .input_schema_json = "{}", .read_only = false, .effects = .{ .writes_workspace = true }, .handler = .{ .ctx = &dummy, .call = noop } };
const cmd_spec: proto.ToolSpec = .{ .name = "run", .description = "", .input_schema_json = "{}", .read_only = false, .effects = .{ .executes = true }, .handler = .{ .ctx = &dummy, .call = noop } };

/// Records a logical start/end tick per call; optionally sleeps or fails.
const Recorder = struct {
    tick: std.atomic.Value(u64) = .init(0),
    start: [64]u64 = undefined,
    end: [64]u64 = undefined,
    sleep_ms: u32 = 0,
    fail: ?usize = null,
    arena: std.mem.Allocator,

    fn invoke(r: *Recorder) sched.Invoke {
        return .{ .ctx = r, .call = call };
    }

    fn call(ctx: *anyopaque, io_: Io, i: usize, c: *const sched.Call) ToolOutput {
        const r: *Recorder = @ptrCast(@alignCast(ctx));
        r.start[i] = r.tick.fetchAdd(1, .acq_rel);
        defer r.end[i] = r.tick.fetchAdd(1, .acq_rel);
        if (r.sleep_ms > 0) io_.sleep(.fromMilliseconds(r.sleep_ms), .awake) catch return .{ .parts = &.{}, .is_error = true };
        if (r.fail == i) return ToolOutput.text(r.arena, "boom", true) catch unreachable;
        return ToolOutput.text(r.arena, c.id, false) catch unreachable;
    }
};

fn path(p: []const u8) []const sched.Resource {
    return switch (p[0]) {
        'a' => &.{.{ .path = "a" }},
        'b' => &.{.{ .path = "b" }},
        else => &.{.{ .path = "c" }},
    };
}

test "reads_parallel" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var rec: Recorder = .{ .sleep_ms = 20, .arena = arena.allocator() };
    var calls: [8]sched.Call = undefined;
    for (&calls, 0..) |*c, i| c.* = .{ .id = try std.fmt.allocPrint(arena.allocator(), "r{d}", .{i}), .spec = &read_spec };
    var out: [8]ToolOutput = undefined;
    var st: [8]sched.Outcome = undefined;
    const t0 = Io.Timestamp.now(io, .awake);
    try sched.run(io, arena.allocator(), .{}, &calls, rec.invoke(), &out, &st);
    const ms = t0.durationTo(Io.Timestamp.now(io, .awake)).toMilliseconds();
    try testing.expect(ms < 80); // 8 × 20 ms sequentially would be 160 ms
    for (out, 0..) |o, i| try testing.expectEqualStrings(calls[i].id, o.parts[0].text);
}

test "same_path_writes_serialized and read_after_write waits" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var rec: Recorder = .{ .sleep_ms = 2, .arena = arena.allocator() };
    const calls = [_]sched.Call{
        .{ .id = "w1", .spec = &write_spec, .resources = path("a") },
        .{ .id = "w2", .spec = &write_spec, .resources = path("a") },
        .{ .id = "r1", .spec = &read_spec, .resources = path("a") },
        .{ .id = "w3", .spec = &write_spec, .resources = path("b") },
        .{ .id = "r2", .spec = &read_spec, .resources = path("c") },
    };
    var out: [5]ToolOutput = undefined;
    var st: [5]sched.Outcome = undefined;
    try sched.run(io, arena.allocator(), .{}, &calls, rec.invoke(), &out, &st);
    try testing.expect(rec.end[0] < rec.start[1]);
    try testing.expect(rec.end[1] < rec.start[2]);
    // w3 (other path) and r2 didn't wait for the a-chain.
    try testing.expect(rec.start[3] < rec.end[0]);
    try testing.expect(rec.start[4] < rec.end[0]);
    for (st) |s| try testing.expectEqual(sched.Outcome.done, s);
}

test "failure_skips_later_mutations" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var rec: Recorder = .{ .fail = 0, .arena = arena.allocator() };
    const calls = [_]sched.Call{
        .{ .id = "w1", .spec = &write_spec, .resources = path("a") },
        .{ .id = "w2", .spec = &write_spec, .resources = path("a") },
        .{ .id = "r1", .spec = &read_spec, .resources = path("b") },
        .{ .id = "c1", .spec = &cmd_spec },
    };
    var out: [4]ToolOutput = undefined;
    var st: [4]sched.Outcome = undefined;
    try sched.run(io, arena.allocator(), .{}, &calls, rec.invoke(), &out, &st);
    try testing.expectEqual(sched.Outcome.done, st[0]);
    try testing.expectEqual(sched.Outcome.skipped, st[1]);
    try testing.expectEqual(sched.Outcome.done, st[2]);
    try testing.expectEqual(sched.Outcome.skipped, st[3]);
    try testing.expectEqualStrings("Not executed: the preceding write call failed.", out[1].parts[0].text);
    try testing.expect(out[1].is_error and out[3].is_error and !out[2].is_error);
}

test "cancel_produces_results_for_all" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var rec: Recorder = .{ .sleep_ms = 10_000, .arena = arena.allocator() };
    const calls = [_]sched.Call{
        .{ .id = "r1", .spec = &read_spec },
        .{ .id = "w1", .spec = &write_spec },
        .{ .id = "r2", .spec = &read_spec },
    };
    var out: [3]ToolOutput = undefined;
    var st: [3]sched.Outcome = undefined;
    var fut = try io.concurrent(sched.run, .{ io, arena.allocator(), sched.Policy{}, @as([]const sched.Call, &calls), rec.invoke(), @as([]ToolOutput, &out), @as([]sched.Outcome, &st) });
    try io.sleep(.fromMilliseconds(10), .awake);
    const t0 = Io.Timestamp.now(io, .awake);
    try testing.expectError(error.Canceled, fut.cancel(io));
    try testing.expect(t0.durationTo(Io.Timestamp.now(io, .awake)).toMilliseconds() < 50);
    for (out, st) |o, s| {
        try testing.expectEqual(sched.Outcome.canceled, s);
        try testing.expect(o.is_error);
        try testing.expectEqualStrings("Canceled by user", o.parts[0].text);
    }
}

test "commands serialize unless parallel_commands" {
    const a: sched.Call = .{ .id = "1", .spec = &cmd_spec, .resources = &.{.{ .terminal = 1 }} };
    const b: sched.Call = .{ .id = "2", .spec = &cmd_spec, .resources = &.{.{ .terminal = 2 }} };
    const c: sched.Call = .{ .id = "3", .spec = &cmd_spec, .resources = &.{.{ .terminal = 1 }} };
    try testing.expect(sched.conflicts(.{}, &a, &b));
    try testing.expect(!sched.conflicts(.{ .parallel_commands = true }, &a, &b));
    try testing.expect(sched.conflicts(.{ .parallel_commands = true }, &a, &c));
    const r: sched.Call = .{ .id = "4", .spec = &read_spec, .resources = &.{.{ .network = "x" }} };
    const g: sched.Call = .{ .id = "5", .spec = &write_spec };
    try testing.expect(sched.conflicts(.{}, &r, &g));
    try testing.expect(!sched.conflicts(.{}, &r, &r));
}

test "property: no conflicting pair overlaps; conflicts keep model order" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rand = prng.random();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const specs = [_]*const proto.ToolSpec{ &read_spec, &write_spec, &cmd_spec };
    const res_choices = [_][]const sched.Resource{ path("a"), path("b"), path("c"), &.{.scm}, &.{.{ .terminal = 1 }}, &.{} };
    for (0..10_000) |_| {
        _ = arena.reset(.retain_capacity);
        var rec: Recorder = .{ .arena = arena.allocator() };
        const n = 1 + rand.uintLessThan(usize, 8);
        var calls: [8]sched.Call = undefined;
        for (calls[0..n]) |*c| c.* = .{ .id = "x", .spec = specs[rand.uintLessThan(usize, specs.len)], .resources = res_choices[rand.uintLessThan(usize, res_choices.len)] };
        var out: [8]ToolOutput = undefined;
        var st: [8]sched.Outcome = undefined;
        const policy: sched.Policy = .{ .max_parallel = @intCast(1 + rand.uintLessThan(u8, 8)), .sequential_after_failure = false };
        try sched.run(io, arena.allocator(), policy, calls[0..n], rec.invoke(), out[0..n], st[0..n]);
        for (0..n) |i| for (i + 1..n) |j| {
            if (sched.conflicts(policy, &calls[i], &calls[j])) try testing.expect(rec.end[i] < rec.start[j]);
        };
    }
}
