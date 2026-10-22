//! Tests for run.zig with the scripted FakeHost (E10.F06.S03.T02).

const std = @import("std");
const proto = @import("zg_ai_proto");
const run = @import("run.zig");
const fake = @import("fake_host.zig");
const deps = @import("../../loop/deps.zig");
const ratelimit = @import("../../provider/ratelimit.zig");

const testing = std.testing;
const io = testing.io;

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    host: fake.FakeHost,
    clock: ratelimit.FakeClock = .init(0),
    tools: run.RunTools,
    progress: std.ArrayList(u8) = .empty,

    fn init(f: *Fixture, scripts: []const fake.Script, cfg: run.Config) void {
        f.* = .{ .arena = .init(testing.allocator), .host = .init(testing.allocator, scripts), .tools = undefined };
        var c = cfg;
        c.clock = f.clock.clock();
        f.tools = .init(testing.allocator, io, f.host.host(), c);
    }

    fn deinit(f: *Fixture) void {
        f.tools.deinit();
        f.host.deinit();
        f.arena.deinit();
    }

    fn call(f: *Fixture, name: []const u8, input: []const u8) !proto.ToolOutput {
        return f.callAs(.{ .session = 1 }, name, input);
    }

    fn callAs(f: *Fixture, agent: proto.AgentRef, name: []const u8, input: []const u8) !proto.ToolOutput {
        const a = f.arena.allocator();
        const spec = for (f.tools.specs()) |*s| {
            if (std.mem.eql(u8, s.name, name)) break s;
        } else unreachable;
        var c: proto.ToolCall = .{
            .id = "toolu_1",
            .name = name,
            .input_json = input,
            .input = try std.json.parseFromSliceLeaky(std.json.Value, a, input, .{}),
            .arena = a,
            .io = io,
            .agent = agent,
            .progress = .{ .ctx = f, .emit = emit },
        };
        return spec.handler.call(spec.handler.ctx, &c);
    }

    fn emit(ctx: *anyopaque, chunk: []const u8) void {
        const f: *Fixture = @ptrCast(@alignCast(ctx));
        f.progress.appendSlice(f.arena.allocator(), chunk) catch {};
    }
};

fn text(o: proto.ToolOutput) []const u8 {
    return o.parts[0].text;
}

test "exit code and tail" {
    var f: Fixture = undefined;
    f.init(&.{
        .{ .command = "make", .steps = &.{ .{ .line = "cc a.c" }, .{ .line = "cc b.c" }, .{ .exit = 0 } } },
        .{ .command = "make -j", .steps = &.{ .{ .line = "line one" }, .{ .line = "line two" }, .{ .line = "line three" }, .{ .exit = 0 } } },
    }, .{ .max_output_chars = 25 });
    defer f.deinit();
    const o = try f.call("run_command", "{\"command\":\"make\",\"cwd\":\"/src\"}");
    try testing.expect(!o.is_error);
    try testing.expectEqual(proto.tool.UiHint.terminal, o.ui_hint);
    try testing.expectEqualStrings("cc a.c\ncc b.c\nExit code: 0\n", text(o));
    try testing.expectEqualStrings("/src", f.host.started.items[0].cwd.?);
    // Only the tail that fits is kept; the rest is named.
    const t = try f.call("run_command", "{\"command\":\"make -j\"}");
    try testing.expectEqualStrings("[1 earlier lines omitted; read them with command_output handle cmd_2 since_line 0]\nline two\nline three\nExit code: 0\n", text(t));
    const all = try f.call("command_output", "{\"handle\":\"cmd_2\",\"since_line\":0}");
    try testing.expectEqualStrings("line one\nline two\n[1 more lines follow]\nNext since_line: 2", text(all));
    const rest = try f.call("command_output", "{\"handle\":\"cmd_2\"}");
    try testing.expectEqualStrings("line three\nExit code: 0\nNext since_line: 3", text(rest));
}

test "timeout moves to background" {
    var f: Fixture = undefined;
    f.init(&.{
        .{ .command = "npm run dev", .steps = &.{ .{ .line = "listening on :3000" }, .{ .delay_ms = 3_600_000 } } },
        .{ .command = "sleep 600", .steps = &.{.{ .delay_ms = 600_000 }} },
    }, .{});
    defer f.deinit();
    const o = try f.call("run_command", "{\"command\":\"npm run dev\",\"timeout_ms\":5000}");
    try testing.expect(!o.is_error);
    try testing.expectEqualStrings("Command did not complete within its 5s timeout and was moved to the background. Handle: cmd_1. Output so far:\nlistening on :3000\n", text(o));
    try testing.expectEqual(@as(u32, 0), f.host.interrupts);
    // The default timeout is 120 s; sleep is stopped instead.
    const s = try f.call("run_command", "{\"command\":\"sleep 600\"}");
    try testing.expectEqualStrings("Command did not complete within its 120s timeout and was stopped.", text(s));
    try testing.expectEqual(@as(u32, 1), f.host.interrupts);
    // Timeouts are clamped to 1 s .. 600 s.
    const c = try f.call("run_command", "{\"command\":\"sleep 600\",\"timeout_ms\":900000}");
    try testing.expect(std.mem.indexOf(u8, text(c), "600s timeout") != null);
}

test "background then command_output" {
    var f: Fixture = undefined;
    f.init(&.{.{ .command = "zig build --watch", .steps = &.{
        .{ .line = "one" }, .{ .delay_ms = 50 }, .{ .line = "two" }, .{ .delay_ms = 1000 }, .{ .line = "three" }, .{ .exit = 0 },
    } }}, .{});
    defer f.deinit();
    const o = try f.call("run_command", "{\"command\":\"zig build --watch\",\"background\":true}");
    try testing.expectEqualStrings("Started in the background. Handle: cmd_1. Use command_output to read its output and kill_command to stop it.", text(o));
    const a = try f.call("command_output", "{\"handle\":\"cmd_1\",\"wait_ms\":100}");
    try testing.expectEqualStrings("one\ntwo\nStatus: running\nNext since_line: 2", text(a));
    const b = try f.call("command_output", "{\"handle\":\"cmd_1\",\"wait_ms\":2000}");
    try testing.expectEqualStrings("three\nExit code: 0\nNext since_line: 3", text(b));
    const c = try f.call("command_output", "{\"handle\":\"cmd_1\",\"since_line\":1}");
    try testing.expectEqualStrings("two\nthree\nExit code: 0\nNext since_line: 3", text(c));
    // Handles belong to their agent.
    const d = try f.callAs(.{ .session = 2 }, "command_output", "{\"handle\":\"cmd_1\"}");
    try testing.expect(d.is_error);
    try testing.expect((try f.call("command_output", "{\"handle\":\"cmd_9\"}")).is_error);
}

test "kill_command" {
    var f: Fixture = undefined;
    f.init(&.{.{ .command = "tail -f log", .steps = &.{ .{ .line = "x" }, .{ .delay_ms = 3_600_000 } } }}, .{});
    defer f.deinit();
    _ = try f.call("run_command", "{\"command\":\"tail -f log\",\"background\":true}");
    const k = try f.call("kill_command", "{\"handle\":\"cmd_1\"}");
    try testing.expectEqualStrings("Stopped cmd_1.", text(k));
    try testing.expectEqual(@as(u32, 1), f.host.interrupts);
    const again = try f.call("kill_command", "{\"handle\":\"cmd_1\"}");
    try testing.expectEqualStrings("cmd_1 has already finished.", text(again));
    const out = try f.call("command_output", "{\"handle\":\"cmd_1\"}");
    try testing.expectEqualStrings("The command was stopped.\nNext since_line: 0", text(out));
}

test "cancel interrupts" {
    var f: Fixture = undefined;
    f.init(&.{.{ .command = "cargo build", .steps = &.{ .{ .line = "Compiling" }, .hang } }}, .{});
    defer f.deinit();
    const Task = struct {
        fn go(fx: *Fixture) proto.ToolError!proto.ToolOutput {
            return fx.call("run_command", "{\"command\":\"cargo build\"}") catch |e| switch (e) {
                error.Canceled => error.Canceled,
                else => error.Failed,
            };
        }
    };
    var fut = try io.concurrent(Task.go, .{&f});
    while (f.progress.items.len == 0) try io.sleep(.fromMilliseconds(1), .awake);
    try testing.expectError(error.Canceled, fut.cancel(io));
    try testing.expectEqual(@as(u32, 1), f.host.interrupts);
}

test "nonzero exit is not is_error" {
    var f: Fixture = undefined;
    f.init(&.{.{ .command = "echo hello && exit 3", .steps = &.{ .{ .line = "hello" }, .{ .exit = 3 } } }}, .{});
    defer f.deinit();
    const o = try f.call("run_command", "{\"command\":\"echo hello && exit 3\"}");
    try testing.expect(!o.is_error);
    try testing.expectEqualStrings("hello\nExit code: 3\n", text(o));
    // A command that cannot start is an error.
    const e = try f.call("run_command", "{\"command\":\"nope\"}");
    try testing.expect(e.is_error);
    try testing.expectEqualStrings("Could not start the command: SpawnFailed", text(e));
    try testing.expect((try f.call("run_command", "{\"command\":\"  \"}")).is_error);
    try testing.expect((try f.call("run_command", "{}")).is_error);
}

test "denied by policy" {
    var f: Fixture = undefined;
    f.init(&.{.{ .command = "rm -rf /", .steps = &.{.{ .exit = 0 }} }}, .{});
    defer f.deinit();
    const Policy = struct {
        var seen: ?run.CommandRequest = null;
        fn check(_: *anyopaque, _: std.Io, req: run.CommandRequest) std.Io.Cancelable!deps.Decision {
            seen = req;
            return if (std.mem.startsWith(u8, req.command, "rm ")) .{ .deny = "rm is not allowed" } else .allow;
        }
    };
    var dummy: u8 = 0;
    f.tools.policy = .{ .ctx = &dummy, .check = Policy.check };
    const o = try f.call("run_command", "{\"command\":\"rm -rf /\"}");
    try testing.expect(o.is_error);
    try testing.expectEqualStrings("Permission denied: rm is not allowed", text(o));
    try testing.expectEqual(@as(usize, 0), f.host.started.items.len);
    try testing.expectEqual(@as(u32, 1), Policy.seen.?.session);
}

test "progress lines streamed" {
    var f: Fixture = undefined;
    f.init(&.{.{ .command = "make", .steps = &.{ .{ .line = "a" }, .{ .delay_ms = 10 }, .{ .line = "b" }, .{ .exit = 0 } } }}, .{});
    defer f.deinit();
    _ = try f.call("run_command", "{\"command\":\"make\"}");
    try testing.expectEqualStrings("a\nb\n", f.progress.items);
}

test "visible session per agent, setting honored" {
    var f: Fixture = undefined;
    f.init(&.{.{ .command = "ls", .steps = &.{.{ .exit = 0 }} }}, .{});
    defer f.deinit();
    _ = try f.call("run_command", "{\"command\":\"ls\"}");
    _ = try f.call("run_command", "{\"command\":\"ls\"}");
    _ = try f.callAs(.{ .session = 1, .agent = 2 }, "run_command", "{\"command\":\"ls\"}");
    try testing.expectEqual(@as(usize, 2), f.host.sessions.items.len);
    try testing.expect(f.host.sessions.items[0].visible);
    try testing.expectEqual(@as(u32, 2), f.host.sessions.items[1].owner.agent);

    var g: Fixture = undefined;
    g.init(&.{.{ .command = "ls", .steps = &.{.{ .exit = 0 }} }}, .{ .visible = false });
    defer g.deinit();
    _ = try g.call("run_command", "{\"command\":\"ls\"}");
    try testing.expect(!g.host.sessions.items[0].visible);
}

test "background commands stop after 30 minutes" {
    var f: Fixture = undefined;
    f.init(&.{
        .{ .command = "serve", .steps = &.{.{ .delay_ms = 7_200_000 }} },
        .{ .command = "ls", .steps = &.{.{ .exit = 0 }} },
    }, .{});
    defer f.deinit();
    _ = try f.call("run_command", "{\"command\":\"serve\",\"background\":true}");
    f.clock.advance(29 * std.time.ms_per_min);
    _ = try f.call("run_command", "{\"command\":\"ls\"}");
    try testing.expectEqual(@as(u32, 0), f.host.interrupts);
    f.clock.advance(std.time.ms_per_min);
    _ = try f.call("run_command", "{\"command\":\"ls\"}");
    try testing.expectEqual(@as(u32, 1), f.host.interrupts);
}
