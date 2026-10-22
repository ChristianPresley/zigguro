//! Integration tests: the command tools over real child processes
//! (E10.F06.S03.T02, E10.F05.S03.T01 process-tree stop).

const std = @import("std");
const builtin = @import("builtin");
const proto = @import("zg_ai_proto");
const run = @import("run.zig");
const process_host = @import("process_host.zig");
const host_mod = @import("terminal_host.zig");

const testing = std.testing;
const io = testing.io;

fn call(r: *run.RunTools, a: std.mem.Allocator, name: []const u8, input: []const u8) !proto.ToolOutput {
    const spec = for (r.specs()) |*s| {
        if (std.mem.eql(u8, s.name, name)) break s;
    } else unreachable;
    var c: proto.ToolCall = .{
        .id = "toolu_1",
        .name = name,
        .input_json = input,
        .input = try std.json.parseFromSliceLeaky(std.json.Value, a, input, .{}),
        .arena = a,
        .io = io,
        .agent = .{ .session = 1 },
    };
    return spec.handler.call(spec.handler.ctx, &c);
}

test "echo hello && exit 3" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var ph: process_host.ProcessHost = .init(testing.allocator, io);
    defer ph.deinit();
    var r: run.RunTools = .init(testing.allocator, io, ph.host(), .{});
    defer r.deinit();
    const o = try call(&r, arena.allocator(), "run_command", "{\"command\":\"echo hello && exit 3\"}");
    try testing.expect(!o.is_error);
    try testing.expectEqualStrings("hello\nExit code: 3\n", o.parts[0].text);
}

test "stderr is captured" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var ph: process_host.ProcessHost = .init(testing.allocator, io);
    defer ph.deinit();
    var r: run.RunTools = .init(testing.allocator, io, ph.host(), .{});
    defer r.deinit();
    const o = try call(&r, arena.allocator(), "run_command", "{\"command\":\"echo oops 1>&2\"}");
    try testing.expectEqualStrings("oops\nExit code: 0\n", o.parts[0].text);
}

test "timeout, background and kill over a real process" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ph: process_host.ProcessHost = .init(testing.allocator, io);
    ph.grace_ms = 100;
    defer ph.deinit();
    var r: run.RunTools = .init(testing.allocator, io, ph.host(), .{});
    defer r.deinit();
    const o = try call(&r, a, "run_command", "{\"command\":\"echo started; while :; do sleep 1; done\",\"timeout_ms\":1000}");
    try testing.expect(std.mem.startsWith(u8, o.parts[0].text, "Command did not complete within its 1s timeout and was moved to the background. Handle: cmd_1. Output so far:\nstarted\n"));
    const k = try call(&r, a, "kill_command", "{\"handle\":\"cmd_1\"}");
    try testing.expectEqualStrings("Stopped cmd_1.", k.parts[0].text);
}

/// True while `pid` exists and is not a zombie.
fn alive(pid: std.posix.pid_t) bool {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/stat", .{pid}) catch return false;
    var buf: [512]u8 = undefined;
    const stat = std.Io.Dir.cwd().readFile(io, path, &buf) catch return false;
    const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return false;
    return stat.len > close + 2 and stat[close + 2] != 'Z';
}

test "interrupt stops the whole process tree" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ph: process_host.ProcessHost = .init(testing.allocator, io);
    ph.grace_ms = 100;
    defer ph.deinit();
    const h = ph.host();
    const s = try h.create(io, .{ .session = 1 }, true);
    // A background grandchild ignores SIGINT (non-interactive sh), so this
    // needs the SIGTERM step and the process group.
    const job = try h.start(io, s, "sleep 60 & echo $!; wait", null);
    var st = try h.wait(io, job, 200, null);
    try testing.expectEqual(host_mod.Status.running, st);
    const out = try h.lines(a, job, 0);
    const pid = try std.fmt.parseInt(std.posix.pid_t, out[0], 10);
    try testing.expect(alive(pid));
    h.interrupt(io, job);
    st = try h.wait(io, job, 5000, null);
    try testing.expectEqual(host_mod.Status.killed, st);
    var tries: u32 = 0;
    while (alive(pid) and tries < 100) : (tries += 1) try io.sleep(.fromMilliseconds(20), .awake);
    try testing.expect(!alive(pid));
}

test "canceling run_command stops the command" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var ph: process_host.ProcessHost = .init(testing.allocator, io);
    ph.grace_ms = 100;
    defer ph.deinit();
    var r: run.RunTools = .init(testing.allocator, io, ph.host(), .{});
    defer r.deinit();
    const Task = struct {
        fn go(rr: *run.RunTools, a: std.mem.Allocator) proto.ToolError!proto.ToolOutput {
            return call(rr, a, "run_command", "{\"command\":\"echo go; sleep 60\"}") catch |e| switch (e) {
                error.Canceled => error.Canceled,
                else => error.Failed,
            };
        }
    };
    var fut = try io.concurrent(Task.go, .{ &r, arena.allocator() });
    // Wait for the command to print, then cancel the call.
    while (true) {
        try io.sleep(.fromMilliseconds(10), .awake);
        ph.mutex.lockUncancelable(io);
        const n = if (ph.jobs.items.len > 0) ph.jobs.items[0].lines.items.len else 0;
        ph.mutex.unlock(io);
        if (n > 0) break;
    }
    try testing.expectError(error.Canceled, fut.cancel(io));
    const st = try ph.host().wait(io, 0, 5000, null);
    try testing.expectEqual(host_mod.Status.killed, st);
}

test "line cleaner" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var got: std.ArrayList([]const u8) = .empty;
    const Ctx = struct {
        list: *std.ArrayList([]const u8),
        a: std.mem.Allocator,
        fn emit(c: @This(), l: []const u8) std.mem.Allocator.Error!void {
            try c.list.append(c.a, try c.a.dupe(u8, l));
        }
    };
    var c: host_mod.LineCleaner = .{};
    defer c.deinit(testing.allocator);
    const ctx: Ctx = .{ .list = &got, .a = a };
    try c.feed(testing.allocator, "\x1b[1;32mok\x1b[0m done\n 10%\r 50%\r100%  \nti", ctx, Ctx.emit);
    try c.feed(testing.allocator, "tle\x1b]0;window\x07 x\r\n", ctx, Ctx.emit);
    try c.feed(testing.allocator, "tail", ctx, Ctx.emit);
    try c.finish(ctx, Ctx.emit);
    try testing.expectEqual(@as(usize, 4), got.items.len);
    try testing.expectEqualStrings("ok done", got.items[0]);
    try testing.expectEqualStrings("100%", got.items[1]);
    try testing.expectEqualStrings("title x", got.items[2]);
    try testing.expectEqualStrings("tail", got.items[3]);
}
