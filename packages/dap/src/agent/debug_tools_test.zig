//! The debugger agent tools against `fake_dap_adapter` scripts
//! (testdata/sessions/agent_tools.txt) and a breakpoint manager without
//! sessions.

const std = @import("std");
const debug_tools = @import("debug_tools.zig");
const DebugSession = @import("../session/DebugSession.zig");
const BreakpointManager = @import("../breakpoints/BreakpointManager.zig");
const test_harness = @import("../session/test_harness.zig");

const testing = std.testing;
const gpa = testing.allocator;
const Io = std.Io;
const Harness = test_harness.Harness;

const Fixture = struct {
    session: ?*DebugSession = null,
    bps: BreakpointManager,
    started: ?[]const u8 = null,
    h: ?*Harness = null,

    fn configs(_: *anyopaque, arena: std.mem.Allocator) anyerror![]const debug_tools.ConfigInfo {
        return arena.dupe(debug_tools.ConfigInfo, &.{
            .{ .name = "Debug app", .type = "lldb", .request = "launch" },
            .{ .name = "Attach", .type = "gdb", .request = "attach", .disabled = "gdb is not installed" },
        });
    }
    fn start(ctx: *anyopaque, name: []const u8) anyerror!*DebugSession {
        const f: *Fixture = @ptrCast(@alignCast(ctx));
        f.started = name;
        const h = f.h orelse return error.NoAdapter;
        const c = try h.config(.launch);
        f.session = try h.m.start(&c, .{ .controller = .agent });
        return f.session.?;
    }
    fn acquire(ctx: *anyopaque) ?*DebugSession {
        const f: *Fixture = @ptrCast(@alignCast(ctx));
        return f.session;
    }
    fn release(_: *anyopaque, _: *DebugSession) void {}

    fn host(f: *Fixture) debug_tools.Host {
        return .{ .ctx = f, .configs = configs, .start = start, .acquire = acquire, .release = release, .breakpoints = &f.bps, .root = "/w", .io = testing.io };
    }
};

const Ran = struct { text: []const u8, out: debug_tools.Outcome };

fn run(a: std.mem.Allocator, h: debug_tools.Host, tool: []const u8, input: []const u8) !Ran {
    var w: Io.Writer.Allocating = .init(a);
    const out = try debug_tools.runTool(h, a, tool, input, &w.writer);
    return .{ .text = w.written(), .out = out };
}

test "debug_tools: specs carry a class, a valid schema and are unique" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for (debug_tools.specs, 0..) |s, i| {
        _ = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), s.input_schema_json, .{});
        for (debug_tools.specs[i + 1 ..]) |o| try testing.expect(!std.mem.eql(u8, s.name, o.name));
    }
    try testing.expectEqual(debug_tools.PermissionClass.execute, debug_tools.specOf("debug_start").?.permission);
    try testing.expectEqual(debug_tools.PermissionClass.execute, debug_tools.specOf("debug_evaluate").?.permission);
    try testing.expectEqual(debug_tools.PermissionClass.control, debug_tools.specOf("debug_step").?.permission);
    try testing.expectEqual(debug_tools.PermissionClass.read, debug_tools.specOf("debug_wait_for_stop").?.permission);
    try testing.expectEqual(@as(usize, 15), debug_tools.specs.len);
}

test "debug_tools: configs, no session, breakpoints without sessions" {
    var f: Fixture = .{ .bps = .init(gpa, testing.io, .{}) };
    defer f.bps.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const h = f.host();
    var r = try run(a, h, "debug_list_configs", "{}");
    try testing.expectEqualStrings("Debug app [lldb, launch]\nAttach [gdb, attach] (cannot start: gdb is not installed)\n", r.text);
    r = try run(a, h, "debug_threads", "{}");
    try testing.expect(!r.out.ok);
    try testing.expectEqualStrings("no_session", r.out.code.?);
    r = try run(a, h, "debug_start", "{\"name\":\"Debug app\"}");
    try testing.expect(!r.out.ok);
    try testing.expectEqualStrings("Debug app", f.started.?);
    // Relative paths resolve under the workspace; a second call replaces
    // the file's breakpoints.
    r = try run(a, h, "debug_set_breakpoints", "{\"path\":\"src/a.zig\",\"lines\":[{\"line\":3},{\"line\":7,\"condition\":\"i > 1\"}]}");
    try testing.expectEqualStrings("src/a.zig:3: set (verified when a session starts)\nsrc/a.zig:7: set (verified when a session starts)\n", r.text);
    r = try run(a, h, "debug_set_breakpoints", "{\"path\":\"src/a.zig\",\"lines\":[{\"line\":9,\"log_message\":\"i={i}\"}]}");
    try testing.expectEqualStrings("src/a.zig:9 (logpoint): set (verified when a session starts)\n", r.text);
    const left = try f.bps.list(a);
    try testing.expectEqual(@as(usize, 1), left.len);
    try testing.expectEqualStrings("/w/src/a.zig", left[0].bp.kind.source.path);
    try testing.expectEqualStrings("i={i}", left[0].bp.kind.source.log_message.?);
    _ = try run(a, h, "debug_set_breakpoints", "{\"path\":\"/w/b.zig\",\"lines\":[{\"line\":1}]}");
    r = try run(a, h, "debug_clear_breakpoints", "{\"path\":\"src/a.zig\"}");
    try testing.expectEqualStrings("Removed 1 breakpoint.\n", r.text);
    r = try run(a, h, "debug_clear_breakpoints", "{}");
    try testing.expectEqualStrings("Removed 1 breakpoint.\n", r.text);
    // Bad arguments are an answer, not a crash.
    r = try run(a, h, "debug_set_breakpoints", "{\"path\":3}");
    try testing.expectEqualStrings("bad_arguments", r.out.code.?);
    try testing.expectError(error.UnknownTool, run(a, h, "debug_frobnicate", "{}"));
}

test "debug_tools: stop, stack, variables, evaluate, output, takeover, end" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var hh: Harness = undefined;
    try hh.init(&.{"agent_tools.txt"}, .{});
    defer hh.deinit();
    var f: Fixture = .{ .bps = .init(gpa, testing.io, .{}), .h = &hh };
    defer f.bps.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const h = f.host();
    var r = try run(a, h, "debug_start", "{\"name\":\"Debug app\"}");
    try testing.expect(r.out.ok);
    const s = f.session.?;

    r = try run(a, h, "debug_wait_for_stop", "{\"timeout_ms\":10000}");
    try testing.expectEqualStrings("Stopped: breakpoint, thread 1 \"main\"\n#0 main at src/main.zig:3 frame=1000\n", r.text);
    r = try run(a, h, "debug_stack", "{}");
    try testing.expectEqualStrings("#0 main (src/main.zig:3) frame=1000\n#1 start (src/start.zig:9) frame=1001\n\u{2026} 3 more frames (raise levels)\n", r.text);
    r = try run(a, h, "debug_variables", "{\"max_children\":2}");
    try testing.expect(r.out.ok);
    try testing.expectEqualStrings("p: Point = {...}\n  x: i32 = 1\n  y: i32 = 2\n  \u{2026} more (raise max_children, or ask for reference=8)\n" ++
        "s: []const u8 = " ++ "x" ** 200 ++ "\u{2026}(len 250)\n\u{2026} more (raise max_children, or ask for reference=7)\n", r.text);
    r = try run(a, h, "debug_evaluate", "{\"expression\":\"a + 1\"}");
    try testing.expectEqualStrings("a + 1: i32 = 2\n", r.text);
    r = try run(a, h, "debug_threads", "{}");
    try testing.expectEqualStrings("Thread 1 \"main\": stopped (breakpoint) [current]\n", r.text);
    r = try run(a, h, "debug_output_tail", "{\"lines\":1}");
    try testing.expectEqualStrings("world\n", r.text);

    // The user took control: control tools are refused, reading works.
    s.setController(.user);
    r = try run(a, h, "debug_continue", "{}");
    try testing.expectEqualStrings("user_took_control", r.out.code.?);
    r = try run(a, h, "debug_threads", "{}");
    try testing.expect(r.out.ok);
    // Handed back: it runs to the end.
    s.setController(.agent);
    r = try run(a, h, "debug_continue", "{}");
    try testing.expectEqualStrings("Continued. Call debug_wait_for_stop.", r.text);
    r = try run(a, h, "debug_wait_for_stop", "{\"timeout_ms\":10000}");
    try testing.expect(std.mem.startsWith(u8, r.text, "The program exited with code 0.\nLast output:\n"));
    try testing.expect(std.mem.indexOf(u8, r.text, "[agent] continue") != null);
    try hh.waitFor(s, Harness.ended);
    try hh.expectScriptPassed(s);
}
