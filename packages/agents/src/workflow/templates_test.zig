//! Each bundled template validates and runs end to end offline: scripted
//! workers answer every agent, fake ports stand in for the workspace,
//! the SCM, artifacts and commands.

const std = @import("std");
const t = @import("test_env.zig");
const run = @import("../runs/run.zig");
const WorkflowEngine = @import("exec.zig");
const templates = @import("templates.zig");
const parse = @import("parse.zig");
const PromptLibrary = @import("../library/index.zig");
const BuiltinRegistry = @import("builtins.zig");

const testing = std.testing;
const gpa = t.gpa;
const io = t.io;
const Env = t.Env;
const Fake = t.Fake;
const Job = t.Job;
const Reply = t.Reply;
const Allocator = std.mem.Allocator;

const builtin_names = [_][]const u8{ "files.glob", "scm.changed_files", "lanes.collect", "artifact.write_table" };

fn allowAll(_: ?*anyopaque, _: []const u8) bool {
    return true;
}

test "templates validate" {
    const lib = try PromptLibrary.open(gpa, io, .{}, null);
    defer lib.deinit();
    for (templates.all) |tpl| {
        var diags: parse.Diagnostics = .init(gpa);
        defer diags.deinit();
        var p = parse.parseDef(gpa, tpl.source, .{ .library = lib, .builtins = &builtin_names, .commands_allowed = allowAll }, &diags) catch |e| {
            var w: std.Io.Writer.Allocating = .init(gpa);
            defer w.deinit();
            try diags.format(tpl.name, &w.writer);
            std.debug.print("{s}", .{w.written()});
            return e;
        };
        defer p.deinit();
        try testing.expectEqualStrings(tpl.name, p.def.name);
    }
}

const Ports = struct {
    table_rows: usize = 0,
    commands: u32 = 0,

    fn glob(_: *anyopaque, a: Allocator, _: []const u8) anyerror![]const []const u8 {
        return a.dupe([]const u8, &.{ "src/a.zig", "src/bad.zig", "src/c.zig" });
    }
    fn changed(_: *anyopaque, a: Allocator, _: []const u8) anyerror![]const []const u8 {
        return a.dupe([]const u8, &.{ "src/a.zig", "src/bad.zig" });
    }
    fn table(ctx: *anyopaque, _: Allocator, _: []const u8, rows: std.json.Value) anyerror![]const u8 {
        const p: *Ports = @ptrCast(@alignCast(ctx));
        p.table_rows = rows.array.items.len;
        return "artifact-1";
    }
    fn exec(ctx: *anyopaque, _: Allocator, req: WorkflowEngine.CommandRequest) anyerror!WorkflowEngine.CommandResult {
        const p: *Ports = @ptrCast(@alignCast(ctx));
        p.commands += 1;
        std.debug.assert(req.shell);
        // Fails twice, then passes.
        return if (p.commands < 3) .{ .exit_code = 1, .output = if (p.commands == 1) "2 tests failed" else "1 test failed" } else .{ .exit_code = 0, .output = "all passed" };
    }
    fn builtinPorts(p: *Ports) BuiltinRegistry.Ports {
        return .{ .glob = .{ .ctx = p, .glob = glob }, .scm = .{ .ctx = p, .changed_files = changed }, .artifacts = .{ .ctx = p, .write_table = table } };
    }
};

const finding = "{\"file\":\"src/bad.zig\",\"line\":3,\"severity\":\"high\",\"description\":\"overflow\"}";

fn scripted(_: *Fake, j: Job) Reply {
    if (std.mem.eql(u8, j.step, "audit")) {
        if (std.mem.indexOf(u8, j.prompt, "src/bad.zig") != null) return .{ .text = "{\"findings\":[" ++ finding ++ "]}" };
        return .{ .text = "{\"findings\":[]}" };
    }
    if (std.mem.eql(u8, j.step, "verify")) return .{ .text = "{\"findings\":[" ++ finding ++ "]}" };
    if (std.mem.eql(u8, j.step, "review")) {
        if (std.mem.indexOf(u8, j.prompt, "src/bad.zig") != null) return .{ .text = "{\"comments\":[{\"file\":\"src/bad.zig\",\"line\":3,\"severity\":\"major\",\"comment\":\"unchecked\"}]}" };
        return .{ .text = "{\"comments\":[]}" };
    }
    if (std.mem.eql(u8, j.step, "migrate")) return .{ .lane_then_text = .{ .lane = "run/lane", .text = "migrated" } };
    return .{ .text = "done" };
}

const Setup = struct {
    lib: *PromptLibrary,
    ports: Ports = .{},
    e: Env = undefined,

    fn init(s: *Setup) !void {
        s.lib = try PromptLibrary.open(gpa, io, .{}, null);
        s.ports = .{};
        try s.e.init(scripted, .{
            .library = s.lib,
            .ports = s.ports.builtinPorts(),
            .commands = .{ .ctx = &s.ports, .exec = Ports.exec },
        });
    }

    fn deinit(s: *Setup) void {
        s.e.deinit();
        s.lib.deinit();
    }

    fn start(s: *Setup, name: []const u8, args: []const u8) !t.RunId {
        const d = try s.e.def(templates.find(name).?.source);
        return s.e.eng.start(d, try s.e.json(args), .{});
    }
};

test "audit-files runs offline" {
    var s: Setup = undefined;
    try s.init();
    defer s.deinit();
    const id = try s.start("audit-files", "{\"glob\":\"src/**/*.zig\",\"check\":\"integer overflow\"}");
    try testing.expectEqual(run.RunStatus.completed, try s.e.eng.wait(id));
    // 3 audits, 2 verifiers, a judge and the report.
    try testing.expectEqual(@as(usize, 7), s.e.fake.count(null));
    try testing.expectEqual(@as(usize, 1), s.ports.table_rows);
    // The library prompt was rendered with the bindings.
    var saw = false;
    for (0..s.e.fake.count(null)) |i| {
        const j = s.e.fake.started(i);
        if (std.mem.eql(u8, j.step, "audit") and std.mem.indexOf(u8, j.prompt, "Look for: integer overflow") != null) saw = true;
    }
    try testing.expect(saw);
}

test "migrate-files runs offline and waits for review" {
    var s: Setup = undefined;
    try s.init();
    defer s.deinit();
    const id = try s.start("migrate-files", "{\"glob\":\"src/*.zig\",\"instructions\":\"rename foo to bar\",\"verify_cmd\":\"zig build\"}");
    try s.e.waitStatus(id, .needs_input);
    for (0..3) |i| try testing.expectEqual(run.Isolation.lane, s.e.fake.started(i).isolation);
    try s.e.eng.answerGate(id, "review", true, null);
    try testing.expectEqual(run.RunStatus.completed, try s.e.eng.wait(id));
    try testing.expectEqual(@as(usize, 3), (try s.e.result(id, "lanes")).array.items.len);
}

test "review-changes runs offline" {
    var s: Setup = undefined;
    try s.init();
    defer s.deinit();
    const id = try s.start("review-changes", "{}");
    try testing.expectEqual(run.RunStatus.completed, try s.e.eng.wait(id));
    try testing.expectEqual(@as(usize, 3), s.e.fake.count(null));
    try testing.expectEqual(@as(usize, 1), s.ports.table_rows);
}

test "fix-until-green runs offline" {
    var s: Setup = undefined;
    try s.init();
    defer s.deinit();
    const id = try s.start("fix-until-green", "{}");
    try testing.expectEqual(run.RunStatus.completed, try s.e.eng.wait(id));
    try testing.expectEqual(@as(u32, 3), s.ports.commands);
    try testing.expectEqual(@as(usize, 3), s.e.fake.count(null));
    // Round 2 saw round 1's failure.
    try testing.expect(std.mem.indexOf(u8, s.e.fake.started(1).prompt, "2 tests failed") != null);
}
