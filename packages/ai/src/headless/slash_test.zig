//! Slash commands and skills in `zg agent` (E10.F09.S04.T01).

const std = @import("std");
const skills = @import("../ext/skills.zig");
const fake_host = @import("../tools/builtin/fake_host.zig");
const repl = @import("repl.zig");
const ts = @import("test_support.zig");
const stack = @import("../context/stack.zig");
const store_mod = @import("../session/store.zig");
const index_mod = @import("../session/index.zig");
const hooks_mod = @import("../ext/hooks.zig");
const agent_defs = @import("../subagent/defs.zig");

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
    try testing.expect(std.mem.indexOf(u8, out, "No subagents.") != null);
    try testing.expect(std.mem.indexOf(u8, err, "conversation cleared") != null);
    try testing.expect(std.mem.indexOf(u8, out, "  /build [target]  Builds\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "  /exit  Leave the REPL\n") != null);
}

test "repl /memory, /context and /compact with a context stack" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "ZIGGURO.md", .data = "Use tabs.\n" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];

    var h: Harness = undefined;
    // A turn, the summary, then a turn after the compaction.
    try h.init(&.{ script.text("Hi."), script.text("SUMMARY: said hello."), script.text("Again.") });
    defer h.deinit();
    var ctx: stack.ContextStack = undefined;
    try ctx.init(testing.allocator, io, .{
        .sources = .{ .workspace_roots = &.{root}, .cwd = root },
        .env = .{ .cwd = root, .now_ms = 0 },
        .compaction = .{ .provider = h.provider, .model = h.registry.resolve("m").? },
    });
    defer ctx.deinit();
    ctx.install(&h.manager.deps);

    var o = try h.options(&.{});
    o.env.context = &ctx;
    var in: std.Io.Reader = .fixed("/memory\nhello\n/context\n/compact the greeting\nagain\n");
    try testing.expectEqual(.ok, try repl.runRepl(io, testing.allocator, h.manager, o, &h.out.writer, &in));
    const out = h.stdout();
    const err = h.stderr();
    try testing.expect(std.mem.indexOf(u8, out, "ZIGGURO.md  (project, ") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Context: ") != null);
    try testing.expect(std.mem.indexOf(u8, out, "ZIGGURO.md  ") != null);
    try testing.expect(std.mem.indexOf(u8, out, "  messages  ") != null);
    try testing.expect(std.mem.indexOf(u8, err, "conversation compacted (") != null);

    const reqs = h.sp.requests();
    try testing.expectEqual(@as(usize, 3), reqs.len);
    // The memory file is in the system prompt.
    var found = false;
    for (reqs[0].system) |p| found = found or std.mem.indexOf(u8, p.text, "Use tabs.") != null;
    try testing.expect(found);
    // The summary request carries the focus; the next turn starts from the summary.
    try testing.expect(std.mem.indexOf(u8, h.lastUserText(1), "Focus the summary on: the greeting") != null);
    const after = reqs[2].messages;
    try testing.expect(std.mem.indexOf(u8, after[0].content[1].text.text, "SUMMARY: said hello.") != null);
    try testing.expectEqualStrings("again", h.lastUserText(2));
}

test "/compact without a compactor" {
    var h: Harness = undefined;
    try h.init(&.{script.text("Hi.")});
    defer h.deinit();
    const o = try h.options(&.{});
    var in: std.Io.Reader = .fixed("/compact\nhello\n/compact\n/memory\n/context\n");
    try testing.expectEqual(.ok, try repl.runRepl(io, testing.allocator, h.manager, o, &h.out.writer, &in));
    try testing.expect(std.mem.indexOf(u8, h.stderr(), "nothing to compact yet") != null);
    try testing.expect(std.mem.indexOf(u8, h.stderr(), "this run cannot compact the conversation") != null);
    try testing.expect(std.mem.indexOf(u8, h.stdout(), "No memory files are loaded.") != null);
    try testing.expect(std.mem.indexOf(u8, h.stdout(), "Context: about ") != null);
}

test "repl session commands: /rename, /branch, /resume, /export, /rewind" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    var store: store_mod.SessionStore = try .init(testing.allocator, path_buf[0..n], "/work");
    defer store.deinit();
    try std.Io.Dir.cwd().createDirPath(io, store.dir);
    var dir = try std.Io.Dir.cwd().openDir(io, store.dir, .{ .iterate = true });
    defer dir.close(io);
    var ix: index_mod.SessionIndex = try .load(testing.allocator, io, dir);
    defer ix.deinit();

    var h: Harness = undefined;
    try h.init(&.{ script.text("A."), script.text("B.") });
    defer h.deinit();
    var o = try h.options(&.{});
    o.env.store = &store;
    o.env.index = &ix;
    var in: std.Io.Reader = .fixed("one\n/rename first\n/branch side\ntwo\n/resume\n/resume first\n/export\n/rewind\n/rewind 1\n/rewind\n");
    try testing.expectEqual(.ok, try repl.runRepl(io, testing.allocator, h.manager, o, &h.out.writer, &in));
    const out = h.stdout();
    const err = h.stderr();
    try testing.expect(std.mem.indexOf(u8, err, "session renamed to first") != null);
    try testing.expect(std.mem.indexOf(u8, err, "branched into ") != null);
    // The branch carried "one" over; "two" went to the branch only.
    const second = h.sp.requests()[1].messages;
    try testing.expectEqual(@as(usize, 3), second.len);
    // Both sessions are listed, the branch marked current.
    try testing.expect(std.mem.indexOf(u8, out, "messages  first\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "messages  side\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "* ") != null);
    try testing.expect(std.mem.indexOf(u8, err, "resumed ") != null);
    // The original session has only the first exchange.
    try testing.expect(std.mem.indexOf(u8, out, "# first\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "A.") != null);
    try testing.expect(std.mem.indexOf(u8, out, "1. one\n") != null);
    try testing.expect(std.mem.indexOf(u8, err, "rewound to before prompt 1") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Nothing to rewind.") != null);
}

test "session commands without a session store" {
    var h: Harness = undefined;
    try h.init(&.{});
    defer h.deinit();
    const o = try h.options(&.{});
    var in: std.Io.Reader = .fixed("/resume\n/branch\n/rename x\n/export\n/rewind 3\n");
    try testing.expectEqual(.ok, try repl.runRepl(io, testing.allocator, h.manager, o, &h.out.writer, &in));
    const err = h.stderr();
    try testing.expect(std.mem.indexOf(u8, err, "nothing to resume") != null);
    try testing.expect(std.mem.indexOf(u8, err, "nothing to branch") != null);
    try testing.expect(std.mem.indexOf(u8, err, "cannot be named") != null);
    try testing.expect(std.mem.indexOf(u8, err, "nothing to export") != null);
    try testing.expect(std.mem.indexOf(u8, err, "/rewind takes a prompt number from 1 to 0") != null);
}

test "repl /init, /agents and /hooks" {
    var h: Harness = undefined;
    try h.init(&.{script.text("Written.")});
    defer h.deinit();
    var hooks: hooks_mod.HookEngine = try .init(testing.allocator, io, .{});
    defer hooks.deinit();
    const parsed = try hooks_mod.parseSettings(h.arena.allocator(), "{\"hooks\":{\"PreToolUse\":[{\"matcher\":\"run\",\"hooks\":[{\"type\":\"command\",\"command\":\"./check.sh\"}]}]}}", .project);
    try hooks.add(parsed.sources);
    var defs: std.ArrayList(agent_defs.AgentDef) = .empty;
    try agent_defs.loadDefs(io, h.arena.allocator(), &.{}, &defs, null);

    var o = try h.options(&.{});
    o.env.agents = defs.items;
    o.env.hooks = &hooks;
    var in: std.Io.Reader = .fixed("/agents\n/hooks\n/init mention the fuzz targets\n");
    try testing.expectEqual(.ok, try repl.runRepl(io, testing.allocator, h.manager, o, &h.out.writer, &in));
    const out = h.stdout();
    try testing.expect(std.mem.indexOf(u8, out, "explore  (builtin)  ") != null);
    try testing.expect(std.mem.indexOf(u8, out, "PreToolUse  [project]  run  ./check.sh\n") != null);
    const sent = h.lastUserText(0);
    try testing.expect(std.mem.startsWith(u8, sent, "Look through this project and write an AGENTS.md"));
    try testing.expect(std.mem.endsWith(u8, sent, "Also: mention the fuzz targets"));
}
