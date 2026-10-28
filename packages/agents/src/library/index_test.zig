const std = @import("std");
const zg_ai = @import("zg_ai");
const PromptLibrary = @import("index.zig");
const tools = @import("tools.zig");

const testing = std.testing;
const io = testing.io;
const gpa = testing.allocator;

const Fixture = struct {
    tmp: testing.TmpDir,
    project: std.Io.Dir,
    user: std.Io.Dir,
    state: std.Io.Dir,

    fn init(f: *Fixture) !void {
        f.tmp = testing.tmpDir(.{ .iterate = true });
        f.project = try f.tmp.dir.createDirPathOpen(io, "ws/.zigguro/prompts", .{ .open_options = .{ .iterate = true } });
        f.user = try f.tmp.dir.createDirPathOpen(io, "config/prompts", .{ .open_options = .{ .iterate = true } });
        f.state = try f.tmp.dir.createDirPathOpen(io, "ws/.zigguro/state", .{});
    }

    fn deinit(f: *Fixture) void {
        f.project.close(io);
        f.user.close(io);
        f.state.close(io);
        f.tmp.cleanup();
    }

    fn dirs(f: *Fixture) PromptLibrary.Dirs {
        return .{ .project = f.project, .user = f.user, .state = f.state };
    }
};

fn write(dir: std.Io.Dir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try dir.createDirPath(io, d);
    try dir.writeFile(io, .{ .sub_path = path, .data = data });
}

const lead_md =
    \\---
    \\title: Research lead planner
    \\description: Decompose a research question into non-overlapping sub-questions
    \\tags: [research, planning]
    \\variables:
    \\  - {name: question, type: text, required: true}
    \\  - {name: effort, type: choice, options: [quick, standard, deep], default: standard}
    \\---
    \\Project lead: {{question}} ({{effort}})
    \\
;

test "precedence_project_over_user_over_builtin" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try write(f.project, "research/lead.md", lead_md);
    try write(f.user, "research/lead.md", "---\ntitle: User lead\n---\nuser\n");
    try write(f.user, "doc/shorten.md", "---\ntitle: My shorten\n---\nCut {{selection}} by a third.\n");
    try write(f.user, "notes/standup.md", "Standup for {{date}}: {{done}}\n");
    try write(f.user, "notes/readme.txt", "not a prompt");

    const lib = try PromptLibrary.open(gpa, io, f.dirs(), null);
    defer lib.deinit();

    const lead = lib.get("research/lead").?;
    try testing.expectEqual(PromptLibrary.EntrySource.project, lead.source);
    try testing.expectEqualStrings("Research lead planner", lead.title);
    try testing.expectEqual(@as(usize, 2), lead.variables.len);
    try testing.expectEqualStrings("effort", lead.variables[1].name);
    try testing.expectEqual(@as(usize, 3), lead.variables[1].options.len);
    try testing.expectEqual(PromptLibrary.EntrySource.user, lib.get("doc/shorten").?.source);
    try testing.expectEqual(PromptLibrary.EntrySource.builtin, lib.get("doc/polish").?.source);
    try testing.expectEqualStrings("Standup", lib.get("notes/standup").?.title);
    try testing.expect(lib.get("notes/readme") == null);
    // Every built-in is present unless shadowed.
    try testing.expect(lib.get("research/researcher") != null);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("Project lead: {{question}} ({{effort}})\n", try lib.body("research/lead", a));
    const ins = try lib.insertion(a, "research/lead", &.{.{ .name = "question", .value = "Why?" }}, .{}, "");
    try testing.expectEqualStrings("Project lead: Why? (standard)\n", ins.text.text);
    try testing.expect(ins.text.ok());

    // The document-mode lookup sees the user's override only.
    try testing.expectEqualStrings("Cut {{selection}} by a third.\n", lib.overrideBody("doc/shorten").?);
    try testing.expect(lib.overrideBody("doc/polish") == null);
}

test "lazy_body_loading" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var name: [64]u8 = undefined;
    for (0..300) |i| {
        const p = try std.fmt.bufPrint(&name, "gen/p{d}.md", .{i});
        try write(f.project, p, "---\ntitle: Generated\ntags: [gen]\n---\nBody {{x}}\n");
    }
    const lib = try PromptLibrary.open(gpa, io, f.dirs(), null);
    defer lib.deinit();
    try testing.expectEqual(@as(u32, 0), lib.body_reads);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    _ = try lib.body("gen/p7", arena.allocator());
    _ = try lib.body("gen/p7", arena.allocator());
    try testing.expectEqual(@as(u32, 1), lib.body_reads);
    try testing.expect(lib.get("gen/p7").?.body_hash != 0);
}

test "skills_listed_and_inserted_as_command" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.tmp.dir.createDirPath(io, "skills/deploy");
    try f.tmp.dir.writeFile(io, .{ .sub_path = "skills/deploy/SKILL.md", .data = "---\ndescription: Deploy the app\nargument-hint: [env]\ndisable-model-invocation: true\n---\nDeploy to $ARGUMENTS.\n" });
    var buf: [96]u8 = undefined;
    const dir = try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}/skills", .{&f.tmp.sub_path});
    var ix = try zg_ai.ext.SkillIndex.load(gpa, io, &.{.{ .dir = dir, .source = .project }});
    defer ix.deinit();

    const lib = try PromptLibrary.open(gpa, io, f.dirs(), &ix);
    defer lib.deinit();
    const e = lib.get("/deploy").?;
    try testing.expectEqual(PromptLibrary.EntrySource.skill, e.source);
    try testing.expect(e.disable_model_invocation);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const ins = try lib.insertion(arena.allocator(), "/deploy", &.{}, .{}, "staging");
    try testing.expectEqualStrings("/deploy staging", ins.command);
    try testing.expectEqualStrings("Deploy to $ARGUMENTS.", try lib.body("/deploy", arena.allocator()));
}

test "search_ranking_and_recency" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try write(f.project, "writing/release-notes.md", "---\ntitle: Release notes\ntags: [writing]\n---\nx\n");
    try write(f.project, "writing/review.md", "---\ntitle: Review a draft\ntags: [writing]\n---\nx\n");
    {
        const lib = try PromptLibrary.open(gpa, io, f.dirs(), null);
        defer lib.deinit();
        var hits: std.ArrayList(PromptLibrary.Hit) = .empty;
        defer hits.deinit(gpa);
        try lib.search("relnotes", 5, &hits, gpa);
        try testing.expectEqualStrings("writing/release-notes", hits.items[0].entry.id);
        try lib.search("rev", 5, &hits, gpa);
        try testing.expectEqualStrings("writing/review", hits.items[0].entry.id);
        try lib.search("zzzzqqq", 5, &hits, gpa);
        try testing.expectEqual(@as(usize, 0), hits.items.len);
        // Using "release notes" a few times lifts it for a query both match.
        try lib.search("writing", 5, &hits, gpa);
        const before = hits.items[0].entry.id;
        const other = if (std.mem.eql(u8, before, "writing/review")) "writing/release-notes" else "writing/review";
        for (0..5) |_| lib.noteUse(other);
        try lib.search("writing", 5, &hits, gpa);
        try testing.expectEqualStrings(other, hits.items[0].entry.id);
    }
    // Counts persist in the state folder.
    const lib = try PromptLibrary.open(gpa, io, f.dirs(), null);
    defer lib.deinit();
    var n: u32 = 0;
    var it = lib.usage.valueIterator();
    while (it.next()) |v| n += v.*;
    try testing.expectEqual(@as(u32, 5), n);
}

const Recorder = struct {
    path: [128]u8 = undefined,
    path_len: usize = 0,
    bytes: std.ArrayList(u8) = .empty,
    scope: ?PromptLibrary.Scope = null,

    fn port(r: *Recorder) PromptLibrary.WritePort {
        return .{ .ctx = r, .write = write_ };
    }

    fn write_(ctx: *anyopaque, scope: PromptLibrary.Scope, rel: []const u8, bytes: []const u8) anyerror!?u64 {
        const r: *Recorder = @ptrCast(@alignCast(ctx));
        @memcpy(r.path[0..rel.len], rel);
        r.path_len = rel.len;
        r.bytes.clearRetainingCapacity();
        try r.bytes.appendSlice(gpa, bytes);
        r.scope = scope;
        return 42;
    }
};

test "library_tools_search_get_create" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try write(f.project, "research/lead.md", lead_md);
    const lib = try PromptLibrary.open(gpa, io, f.dirs(), null);
    defer lib.deinit();
    var rec: Recorder = .{};
    defer rec.bytes.deinit(gpa);
    lib.writer = rec.port();
    var t: tools.ToolExporter = .{ .lib = lib };
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const s = try tools.run(&t, a, "library_search", "{\"query\":\"lead\"}");
    try testing.expect(!s.is_error);
    try testing.expect(std.mem.indexOf(u8, s.text, "research/lead") != null);

    const g = try tools.run(&t, a, "library_get", "{\"id\":\"research/lead\"}");
    try testing.expect(std.mem.indexOf(u8, g.text, "\"name\":\"effort\"") != null);
    try testing.expect(std.mem.indexOf(u8, g.text, "Project lead") != null);
    const missing = try tools.run(&t, a, "library_get", "{\"id\":\"nope\"}");
    try testing.expect(missing.is_error);

    const c = try tools.run(&t, a, "library_create", "{\"id\":\"writing/tldr\",\"title\":\"TL;DR: short\",\"body\":\"Summarize {{text}} for {{who|choice:execs,devs}}\"}");
    try testing.expect(!c.is_error);
    try testing.expectEqual(@as(?u64, 42), c.changeset);
    try testing.expectEqual(PromptLibrary.Scope.project, rec.scope.?);
    try testing.expectEqualStrings("writing/tldr.md", rec.path[0..rec.path_len]);
    // The written file reads back with the same header.
    try write(f.project, "writing/tldr.md", rec.bytes.items);
    try lib.reload();
    const e = lib.get("writing/tldr").?;
    try testing.expectEqualStrings("TL;DR: short", e.title);
    try testing.expectEqual(@as(usize, 2), e.variables.len);
    try testing.expectEqualStrings("who", e.variables[1].name);
    try testing.expectEqual(@as(usize, 2), e.variables[1].options.len);

    const dup = try tools.run(&t, a, "library_create", "{\"id\":\"writing/tldr\",\"title\":\"x\",\"body\":\"y\"}");
    try testing.expect(dup.is_error);
    const bad = try tools.run(&t, a, "library_create", "{\"id\":\"Bad Id\",\"title\":\"x\",\"body\":\"y\"}");
    try testing.expect(bad.is_error);
}

test "builtins_parse_and_render" {
    const lib = try PromptLibrary.open(gpa, io, .{}, null);
    defer lib.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    for (lib.all()) |e| {
        const b = try lib.body(e.id, a);
        _ = try PromptLibrary.render(a, b, e.variables, &.{}, .{});
    }
    const ins = try lib.insertion(a, "research/lead", &.{ .{ .name = "question", .value = "Q" }, .{ .name = "effort", .value = "deep" } }, .{}, "");
    try testing.expect(std.mem.indexOf(u8, ins.text.text, "up to 12 sub-questions") != null);
    try testing.expect(ins.text.ok());
    const tone = try lib.insertion(a, "doc/change_tone", &.{.{ .name = "section_title", .value = "Intro" }}, .{ .selection = "Hello." }, "");
    try testing.expect(std.mem.indexOf(u8, tone.text.text, "formal tone") != null);
}
