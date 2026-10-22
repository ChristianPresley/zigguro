//! Slash commands and skills in `zg agent` (E10.F09.S04.T01).

const std = @import("std");
const skills = @import("../ext/skills.zig");
const fake_host = @import("../tools/builtin/fake_host.zig");
const repl = @import("repl.zig");
const ts = @import("test_support.zig");

const testing = std.testing;
const io = ts.io;
const Harness = ts.Harness;
const script = ts.script;

/// A skill directory with `build` (pre-approves `run`) and `status`
/// (injects `git status`).
const Skills = struct {
    tmp: testing.TmpDir,
    buf: [96]u8 = undefined,
    ix: skills.SkillIndex,

    fn init(s: *Skills) !void {
        s.tmp = testing.tmpDir(.{});
        try s.tmp.dir.createDirPath(io, "skills/build");
        try s.tmp.dir.createDirPath(io, "skills/status");
        try s.tmp.dir.writeFile(io, .{ .sub_path = "skills/build/SKILL.md", .data = "---\ndescription: Builds\nallowed-tools: run\nargument-hint: [target]\n---\nBuild $ARGUMENTS.\n" });
        try s.tmp.dir.writeFile(io, .{ .sub_path = "skills/status/SKILL.md", .data = "---\ndescription: Status\n---\nStatus: !`git status`\n" });
        const dir = try std.fmt.bufPrint(&s.buf, ".zig-cache/tmp/{s}/skills", .{&s.tmp.sub_path});
        s.ix = try skills.SkillIndex.load(testing.allocator, io, &.{.{ .dir = dir, .source = .project }});
    }

    fn deinit(s: *Skills) void {
        s.ix.deinit();
        s.tmp.cleanup();
    }
};

const run_call = script.tools(&.{.{ "t1", "run", "{\"command\":\"make\"}" }});

test "repl skill expands and grants its tools for one turn" {
    var sk: Skills = undefined;
    try sk.init();
    defer sk.deinit();
    var h: Harness = undefined;
    try h.init(&.{ run_call, script.text("Built."), run_call, script.text("Denied.") });
    defer h.deinit();
    var o = try h.options(&.{});
    o.env.skills = .{ .index = &sk.ix };
    var in: std.Io.Reader = .fixed("/build release\nagain\n");
    try testing.expectEqual(.ok, try repl.runRepl(io, testing.allocator, h.manager, o, &h.out.writer, &in));
    try testing.expectEqualStrings("Build release.", h.lastUserText(0));
    // Granted during the skill's turn only.
    try testing.expectEqual(@as(u32, 1), h.tool.calls.load(.acquire));
}

test "print runs skills; built-ins need the repl" {
    var sk: Skills = undefined;
    try sk.init();
    defer sk.deinit();
    {
        var h: Harness = undefined;
        try h.init(&.{script.text("ok")});
        defer h.deinit();
        var o = try h.options(&.{ "-p", "/build debug" });
        o.env.skills = .{ .index = &sk.ix };
        try testing.expectEqual(.ok, try h.run(o, ""));
        try testing.expectEqualStrings("Build debug.", h.lastUserText(0));
    }
    {
        var h: Harness = undefined;
        try h.init(&.{});
        defer h.deinit();
        var o = try h.options(&.{ "-p", "/cost" });
        o.env.skills = .{ .index = &sk.ix };
        try testing.expectEqual(.usage, try h.run(o, ""));
        try testing.expect(std.mem.indexOf(u8, h.stderr(), "/cost works only in the REPL") != null);
    }
    {
        var h: Harness = undefined;
        try h.init(&.{script.text("ok")});
        defer h.deinit();
        var o = try h.options(&.{ "-p", "/tmp is full" });
        o.env.skills = .{ .index = &sk.ix };
        try testing.expectEqual(.ok, try h.run(o, ""));
        try testing.expectEqualStrings("/tmp is full", h.lastUserText(0));
    }
}

test "skill injections run behind the quiet policy" {
    var sk: Skills = undefined;
    try sk.init();
    defer sk.deinit();
    var host: fake_host.FakeHost = .init(testing.allocator, &.{
        .{ .command = "git status", .steps = &.{ .{ .line = "clean" }, .{ .exit = 0 } } },
    });
    defer host.deinit();
    {
        // Not allowed and nobody to ask: refused before it runs.
        var h: Harness = undefined;
        try h.init(&.{});
        defer h.deinit();
        var o = try h.options(&.{});
        o.env.skills = .{ .index = &sk.ix, .host = host.host() };
        var in: std.Io.Reader = .fixed("/status\n");
        try testing.expectEqual(.ok, try repl.runRepl(io, testing.allocator, h.manager, o, &h.out.writer, &in));
        try testing.expect(std.mem.indexOf(u8, h.stderr(), "/status was not run: `git status` was not run: run_command needs approval") != null);
        try testing.expectEqual(@as(usize, 0), host.started.items.len);
    }
    {
        var h: Harness = undefined;
        try h.init(&.{script.text("ok")});
        defer h.deinit();
        var o = try h.options(&.{ "--allowed-tools", "run_command(git status)" });
        o.env.skills = .{ .index = &sk.ix, .host = host.host() };
        var in: std.Io.Reader = .fixed("/status\n");
        try testing.expectEqual(.ok, try repl.runRepl(io, testing.allocator, h.manager, o, &h.out.writer, &in));
        try testing.expectEqualStrings("Status: clean", h.lastUserText(0));
    }
}

test "repl built-in commands" {
    var sk: Skills = undefined;
    try sk.init();
    defer sk.deinit();
    var h: Harness = undefined;
    try h.init(&.{script.text("Hi.")});
    defer h.deinit();
    var o = try h.options(&.{});
    o.env.skills = .{ .index = &sk.ix };
    var in: std.Io.Reader = .fixed("hello\n/cost\n/model\n/mode accept-edits\n/mode nope\n/skills\n/agents\n/clear\n/help\n");
    try testing.expectEqual(.ok, try repl.runRepl(io, testing.allocator, h.manager, o, &h.out.writer, &in));
    const out = h.stdout();
    const err = h.stderr();
    try testing.expect(std.mem.indexOf(u8, out, "Cost: $") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Model: m\n") != null);
    try testing.expect(std.mem.indexOf(u8, err, "permission mode: acceptEdits") != null);
    try testing.expect(std.mem.indexOf(u8, err, "/mode takes default") != null);
    try testing.expect(std.mem.indexOf(u8, out, "/build [target]  Builds\n/status  Status\n") != null);
    try testing.expect(std.mem.indexOf(u8, err, "/agents is not available in zg agent yet") != null);
    try testing.expect(std.mem.indexOf(u8, err, "conversation cleared") != null);
    try testing.expect(std.mem.indexOf(u8, out, "  /build [target]  Builds\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "  /exit  Leave the REPL\n") != null);
}
