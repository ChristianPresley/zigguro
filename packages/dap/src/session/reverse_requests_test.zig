//! Reverse requests against `fake_dap_adapter` scripts
//! (testdata/sessions/): `runInTerminal` with a fake `TerminalLauncher`
//! (process ids, shell joining, `env` unsets, trust) and `startDebugging`
//! child sessions over stdio and TCP.

const std = @import("std");
const builtin = @import("builtin");
const DebugManager = @import("DebugManager.zig");
const DebugSession = @import("DebugSession.zig");
const run_in_terminal = @import("run_in_terminal.zig");
const child_sessions = @import("child_sessions.zig");
const LaunchConfig = @import("../config/LaunchConfig.zig");
const test_harness = @import("test_harness.zig");

const testing = std.testing;
const gpa = testing.allocator;
const Io = std.Io;
const Harness = test_harness.Harness;

/// Records what it was asked to start.
const FakeTerminal = struct {
    mutex: Io.Mutex = .init,
    arena: std.heap.ArenaAllocator,
    calls: u32 = 0,
    kind: run_in_terminal.Kind = .integrated,
    argv: []const []const u8 = &.{},
    env: []const run_in_terminal.EnvEntry = &.{},
    cwd: []const u8 = "",
    title: ?[]const u8 = null,

    fn init() FakeTerminal {
        return .{ .arena = .init(gpa) };
    }

    fn deinit(f: *FakeTerminal) void {
        f.arena.deinit();
    }

    fn launcher(f: *FakeTerminal) DebugManager.TerminalLauncher {
        return .{ .ctx = f, .launch = launch };
    }

    fn launch(ctx: ?*anyopaque, spec: *const run_in_terminal.RunInTerminalSpec) anyerror!run_in_terminal.LaunchResult {
        const f: *FakeTerminal = @ptrCast(@alignCast(ctx.?));
        f.mutex.lockUncancelable(testing.io);
        defer f.mutex.unlock(testing.io);
        const a = f.arena.allocator();
        f.calls += 1;
        f.kind = spec.kind;
        const argv = try a.alloc([]const u8, spec.argv.len);
        for (argv, spec.argv) |*o, s| o.* = try a.dupe(u8, s);
        f.argv = argv;
        const env = try a.alloc(run_in_terminal.EnvEntry, spec.env.len);
        for (env, spec.env) |*o, e| o.* = .{ .name = try a.dupe(u8, e.name), .value = if (e.value) |v| try a.dupe(u8, v) else null };
        f.env = env;
        f.cwd = try a.dupe(u8, spec.cwd);
        f.title = if (spec.title) |t| try a.dupe(u8, t) else null;
        return .{ .process_id = 4242, .shell_process_id = 17 };
    }
};

fn running(_: *Harness, s: *DebugSession) bool {
    return s.state() == .running;
}

test "reverse: runInTerminal integrated responds with process ids" {
    var term: FakeTerminal = .init();
    defer term.deinit();
    var h: Harness = undefined;
    try h.init(&.{"rit_integrated.txt"}, .{ .terminal = term.launcher() });
    defer h.deinit();
    const s = try h.start(.launch);
    try h.waitFor(s, running);
    s.stop();
    try h.waitFor(s, Harness.ended);
    try h.expectScriptPassed(s);
    try testing.expectEqual(@as(u32, 1), term.calls);
    try testing.expectEqual(.integrated, term.kind);
    // No shell: the args are the argv.
    try testing.expectEqual(@as(usize, 2), term.argv.len);
    try testing.expectEqualStrings("/w/app", term.argv[0]);
    try testing.expectEqualStrings("a b", term.argv[1]);
    try testing.expectEqualStrings("/w", term.cwd);
    try testing.expectEqualStrings("app", term.title.?);
}

test "reverse: external without a configured terminal runs integrated in the shell" {
    var term: FakeTerminal = .init();
    defer term.deinit();
    var h: Harness = undefined;
    try h.init(&.{"rit_external.txt"}, .{ .terminal = term.launcher() });
    defer h.deinit();
    const s = try h.start(.launch);
    try h.waitFor(s, running);
    s.stop();
    try h.waitFor(s, Harness.ended);
    try h.expectScriptPassed(s);
    try testing.expectEqual(.integrated, term.kind);
    try testing.expect(h.m.external_fallback_logged.load(.acquire));
    const line = term.argv[term.argv.len - 1];
    if (builtin.os.tag == .windows) {
        try testing.expectEqualStrings("cmd.exe", term.argv[0]);
    } else {
        try testing.expectEqualStrings("/bin/sh", term.argv[0]);
        try testing.expectEqualStrings("-c", term.argv[1]);
    }
    try testing.expectEqualStrings("/w/app \"a b\"", line);
}

test "reverse: argsCanBeInterpretedByShell quoting table (linux/windows)" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { args: []const []const u8, posix: []const u8, cmd: []const u8 };
    const cases = [_]Case{
        .{ .args = &.{ "node", "app.js" }, .posix = "node app.js", .cmd = "node app.js" },
        // Shell syntax is kept: that is what the flag asks for.
        .{ .args = &.{ "echo", "$HOME", ">", "out.txt" }, .posix = "echo $HOME > out.txt", .cmd = "echo $HOME > out.txt" },
        .{ .args = &.{ "a|b", "x&&y" }, .posix = "a|b x&&y", .cmd = "a|b x&&y" },
        // Whitespace and empty arguments are quoted.
        .{ .args = &.{ "/my app/run", "two words", "" }, .posix = "\"/my app/run\" \"two words\" \"\"", .cmd = "\"/my app/run\" \"two words\" \"\"" },
        .{ .args = &.{"say \"hi\" now"}, .posix = "\"say \\\"hi\\\" now\"", .cmd = "\"say \"\"hi\"\" now\"" },
    };
    for (cases) |c| {
        try testing.expectEqualStrings(c.posix, try run_in_terminal.joinForShell(a, c.args, .posix));
        try testing.expectEqualStrings(c.cmd, try run_in_terminal.joinForShell(a, c.args, .cmd));
    }
    const linux = try run_in_terminal.shellArgv(a, &.{ "echo", "a b" }, .linux);
    try testing.expectEqual(@as(usize, 3), linux.len);
    try testing.expectEqualStrings("/bin/sh", linux[0]);
    try testing.expectEqualStrings("echo \"a b\"", linux[2]);
    const windows = try run_in_terminal.shellArgv(a, &.{ "echo", "a b" }, .windows);
    try testing.expectEqual(@as(usize, 5), windows.len);
    try testing.expectEqualStrings("cmd.exe", windows[0]);
    try testing.expectEqualStrings("/c", windows[3]);
    try testing.expectEqualStrings("echo \"a b\"", windows[4]);
    // Without the flag nothing is joined.
    const spec = try run_in_terminal.parse(a, "{\"cwd\": \"/w\", \"args\": [\"a b\", \"$X\"]}", .linux);
    try testing.expectEqual(@as(usize, 2), spec.argv.len);
    try testing.expectEqualStrings("$X", spec.argv[1]);
    try testing.expectError(error.InvalidArguments, run_in_terminal.parse(a, "{\"cwd\": \"/w\", \"args\": []}", .linux));
}

test "reverse: env null unsets variable" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const spec = try run_in_terminal.parse(a,
        \\{"cwd": "/w", "args": ["app"], "env": {"ZG_TEST": "1", "ZG_UNSET": null}}
    , .linux);
    try testing.expectEqual(@as(usize, 2), spec.env.len);
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put("ZG_UNSET", "was set");
    try env.put("PATH", "/bin");
    try run_in_terminal.applyEnv(&env, spec.env);
    try testing.expectEqualStrings("1", env.get("ZG_TEST").?);
    try testing.expectEqual(@as(?[]const u8, null), env.get("ZG_UNSET"));
    try testing.expectEqualStrings("/bin", env.get("PATH").?);
    try testing.expectError(error.InvalidArguments, run_in_terminal.parse(a,
        \\{"cwd": "/w", "args": ["app"], "env": {"N": 1}}
    , .linux));
}

test "reverse: untrusted workspace denies runInTerminal" {
    var term: FakeTerminal = .init();
    defer term.deinit();
    var h: Harness = undefined;
    try h.init(&.{"rit_untrusted.txt"}, .{ .terminal = term.launcher(), .trusted = false });
    defer h.deinit();
    const s = try h.start(.launch);
    try h.waitFor(s, Harness.ended);
    try h.expectScriptPassed(s);
    try testing.expectEqual(.failed, s.state());
    try testing.expectEqual(@as(u32, 0), term.calls);
}

fn childRunning(_: *Harness, s: *DebugSession) bool {
    const ch = s.childAt(0) orelse return false;
    return ch.state() == .running;
}

fn childEnded(_: *Harness, s: *DebugSession) bool {
    const ch = s.childAt(0) orelse return false;
    return ch.ended_event.isSet();
}

test "reverse: startDebugging child lifecycle; parent stop stops children" {
    var h: Harness = undefined;
    try h.init(&.{ "child_parent.txt", "child_child.txt" }, .{});
    defer h.deinit();
    const s = try h.start(.launch);
    try h.waitFor(s, childRunning);
    const child = s.childAt(0).?;
    try testing.expectEqualStrings("worker", child.cfg.name);
    try testing.expectEqualStrings("fake", child.cfg.type);
    try testing.expectEqual(s.controller(), child.controller());
    try testing.expectEqual(@as(usize, 2), h.m.sessions().len);
    s.stop();
    try h.waitFor(s, Harness.ended);
    try testing.expect(child.ended_event.isSet());
    try h.expectScriptPassed(child);
    try h.expectScriptPassed(s);
}

test "reverse: startDebugging over TCP opens a second connection" {
    var h: Harness = undefined;
    try h.init(&.{"tcp_parent.txt"}, .{ .tcp_child = "tcp_child.txt" });
    defer h.deinit();
    const s = try h.start(.launch);
    try h.waitFor(s, childEnded);
    // One adapter process serves both; the child's end leaves the parent
    // running.
    try testing.expectEqual(@as(u32, 1), h.spawns.load(.acquire));
    try testing.expectEqual(.running, s.state());
    try testing.expectEqual(.terminated, s.childAt(0).?.state());
    s.stop();
    try h.waitFor(s, Harness.ended);
    // The adapter's status covers the child connection's script too.
    try h.expectScriptPassed(s);
}

test "reverse: startDebugging child configuration" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const parent: LaunchConfig = .{ .name = "app", .type = "pwa-node", .request = .launch, .args = .empty, .source = .vscode };
    const c = try child_sessions.childConfig(a, &parent,
        \\{"request": "attach", "configuration": {"type": "pwa-node", "__pendingTargetId": "t1"}}
    );
    try testing.expectEqualStrings("app", c.name);
    try testing.expectEqualStrings("pwa-node", c.type);
    try testing.expectEqual(.attach, c.request);
    try testing.expectEqualStrings("t1", c.argString("__pendingTargetId").?);
    try testing.expectError(error.InvalidArguments, child_sessions.childConfig(a, &parent, "{\"request\": \"run\", \"configuration\": {}}"));
}
