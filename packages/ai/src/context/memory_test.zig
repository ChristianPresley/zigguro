//! Tests for memory.zig on temp-dir fixtures.

const std = @import("std");
const memory = @import("memory.zig");

const testing = std.testing;
const Io = std.Io;
const sep = std.fs.path.sep_str;

const Fixture = struct {
    tmp: testing.TmpDir,
    root: []const u8,
    arena: std.heap.ArenaAllocator,

    fn init() !Fixture {
        var f: Fixture = .{ .tmp = testing.tmpDir(.{}), .root = undefined, .arena = .init(testing.allocator) };
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try f.tmp.dir.realPath(testing.io, &buf);
        f.root = try f.arena.allocator().dupe(u8, buf[0..n]);
        return f;
    }

    fn deinit(f: *Fixture) void {
        f.tmp.cleanup();
        f.arena.deinit();
    }

    /// Writes `data` at `rel` (with `/` separators), creating directories.
    fn put(f: *Fixture, rel: []const u8, data: []const u8) !void {
        const a = f.arena.allocator();
        const native = try a.dupe(u8, rel);
        for (native) |*c| if (c.* == '/') {
            c.* = std.fs.path.sep;
        };
        if (std.fs.path.dirname(native)) |d| try f.tmp.dir.createDirPath(testing.io, d);
        try f.tmp.dir.writeFile(testing.io, .{ .sub_path = native, .data = data });
    }

    fn abs(f: *Fixture, rel: []const u8) ![]const u8 {
        const a = f.arena.allocator();
        const native = try a.dupe(u8, rel);
        for (native) |*c| if (c.* == '/') {
            c.* = std.fs.path.sep;
        };
        return if (rel.len == 0) f.root else std.fs.path.join(a, &.{ f.root, native });
    }
};

fn names(set: *const memory.MemorySet, root: []const u8, out: *std.ArrayList(u8)) !void {
    for (set.files) |file| {
        const rel = file.path[root.len + 1 ..];
        for (rel) |c| try out.append(testing.allocator, if (c == '\\') '/' else c);
        try out.print(testing.allocator, "({s}) ", .{@tagName(file.scope)});
    }
}

fn expectFiles(set: *const memory.MemorySet, root: []const u8, want: []const u8) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try names(set, root, &out);
    try testing.expectEqualStrings(want, std.mem.trimEnd(u8, out.items, " "));
}

test "load order: user, project, local; nested on demand" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.put("config/ZIGGURO.md", "user prefs\n");
    try f.put("repo/ZIGGURO.md", "project\n");
    try f.put("repo/AGENTS.md", "agents\n");
    try f.put("repo/ZIGGURO.local.md", "local\n");
    try f.put("repo/sub/ZIGGURO.md", "sub\n");
    try f.put("repo/sub/deeper/x.zig", "");
    var m = memory.MemoryLoader.init(testing.allocator);
    defer m.deinit();
    const repo = try f.abs("repo");
    const set = try m.loadInitial(testing.io, .{ .user_dir = try f.abs("config"), .workspace_roots = &.{repo}, .cwd = repo });
    try expectFiles(set, f.root, "config/ZIGGURO.md(user) repo/ZIGGURO.md(project) repo/AGENTS.md(project) repo/ZIGGURO.local.md(project_local)");
    try testing.expectEqual(@as(u64, 3 + 2 + 2 + 2), set.tokens());

    const added = try m.onFileTouched(testing.io, try f.abs("repo/sub/deeper/x.zig"));
    try testing.expectEqual(@as(usize, 1), added.len);
    try testing.expectEqual(memory.Scope.nested, added[0].scope);
    try testing.expectEqualStrings("sub\n", added[0].text);
    // A second touch loads nothing new.
    try testing.expectEqual(@as(usize, 0), (try m.onFileTouched(testing.io, try f.abs("repo/sub/y.zig"))).len);
}

test "cwd below the root loads every level down to it" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.put("repo/ZIGGURO.md", "root\n");
    try f.put("repo/a/CLAUDE.md", "a\n");
    try f.put("repo/a/b/ZIGGURO.md", "b\n");
    try f.put("repo/a/b/c/ZIGGURO.md", "below cwd\n");
    var m = memory.MemoryLoader.init(testing.allocator);
    defer m.deinit();
    const set = try m.loadInitial(testing.io, .{ .workspace_roots = &.{try f.abs("repo")}, .cwd = try f.abs("repo/a/b") });
    try expectFiles(set, f.root, "repo/ZIGGURO.md(project) repo/a/CLAUDE.md(project) repo/a/b/ZIGGURO.md(project)");
}

test "path-scoped rules load when a matching file is touched" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.put("repo/ZIGGURO.md", "root\n");
    try f.put("repo/.zigguro/rules/testing.md", "---\npaths: \"**/*_test.zig\"\n---\nRun zig build test.\n");
    try f.put("repo/.zigguro/rules/style.md", "Use 4 spaces.\n");
    var m = memory.MemoryLoader.init(testing.allocator);
    defer m.deinit();
    const repo = try f.abs("repo");
    const set = try m.loadInitial(testing.io, .{ .workspace_roots = &.{repo}, .cwd = repo });
    try expectFiles(set, f.root, "repo/ZIGGURO.md(project) repo/.zigguro/rules/style.md(rule)");
    try testing.expectEqual(@as(usize, 0), (try m.onFileTouched(testing.io, "src/main.zig")).len);
    const added = try m.onFileTouched(testing.io, "src/main_test.zig");
    try testing.expectEqual(@as(usize, 1), added.len);
    try testing.expectEqualStrings("Run zig build test.\n", added[0].text);
    try testing.expectEqualStrings("**/*_test.zig", added[0].paths_globs[0]);
    try testing.expectEqual(@as(usize, 0), (try m.onFileTouched(testing.io, "src/other_test.zig")).len);
}

test "cursor mdc rule types" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.put("repo/.cursor/rules/always.mdc", "---\ndescription: Always\nglobs:\nalwaysApply: true\n---\nalways body\n");
    try f.put("repo/.cursor/rules/auto.mdc", "---\ndescription:\nglobs: src/**/*.ts\nalwaysApply: false\n---\nts body\n");
    try f.put("repo/.cursor/rules/requested.mdc", "---\ndescription: Database migrations\nglobs:\nalwaysApply: false\n---\ndb body\n");
    try f.put("repo/.cursor/rules/manual.mdc", "---\ndescription:\nglobs:\nalwaysApply: false\n---\nmanual body\n");
    var m = memory.MemoryLoader.init(testing.allocator);
    defer m.deinit();
    const repo = try f.abs("repo");
    const set = try m.loadInitial(testing.io, .{ .workspace_roots = &.{repo}, .cwd = repo });
    try expectFiles(set, f.root, "repo/.cursor/rules/always.mdc(rule)");
    try testing.expectEqual(@as(usize, 1), set.rules_index.len);
    try testing.expectEqualStrings("Database migrations", set.rules_index[0].description);
    try testing.expectEqual(@as(usize, 1), (try m.onFileTouched(testing.io, "src/app/x.ts")).len);

    // Turning the compat switch off ignores .cursor entirely.
    var m2 = memory.MemoryLoader.init(testing.allocator);
    defer m2.deinit();
    const set2 = try m2.loadInitial(testing.io, .{ .workspace_roots = &.{repo}, .cwd = repo, .compat = .{ .cursor_mdc = false } });
    try testing.expectEqual(@as(usize, 0), set2.files.len + set2.rules_index.len);
}

test "imports: relative, depth 4, cycles, code ignored" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.put("repo/ZIGGURO.md", "See @docs/one.md\n```\n@docs/fenced.md\n```\nand `@docs/span.md`\n");
    try f.put("repo/docs/one.md", "one @two.md\n");
    try f.put("repo/docs/two.md", "two @three.md\n");
    try f.put("repo/docs/three.md", "three @four.md @one.md\n");
    try f.put("repo/docs/four.md", "four @five.md\n");
    try f.put("repo/docs/five.md", "five\n");
    try f.put("repo/docs/fenced.md", "x\n");
    try f.put("repo/docs/span.md", "x\n");
    var m = memory.MemoryLoader.init(testing.allocator);
    defer m.deinit();
    const repo = try f.abs("repo");
    const set = try m.loadInitial(testing.io, .{ .workspace_roots = &.{repo}, .cwd = repo });
    try expectFiles(set, f.root, "repo/ZIGGURO.md(project) repo/docs/one.md(project) repo/docs/two.md(project) repo/docs/three.md(project) repo/docs/four.md(project)");
    try testing.expectEqualStrings(set.files[0].path, set.files[1].imported_by.?);
    try testing.expectEqual(@as(usize, 1), set.notes.len);
    try testing.expect(std.mem.indexOf(u8, set.notes[0], "import hops") != null);
}

fn approveAll(_: ?*anyopaque, _: []const u8) bool {
    return true;
}

test "imports outside the workspace need trust" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.put("repo/ZIGGURO.md", "@../shared/notes.md\n");
    try f.put("shared/notes.md", "shared\n");
    const repo = try f.abs("repo");
    var m = memory.MemoryLoader.init(testing.allocator);
    defer m.deinit();
    const set = try m.loadInitial(testing.io, .{ .workspace_roots = &.{repo}, .cwd = repo });
    try testing.expectEqual(@as(usize, 1), set.files.len);
    try testing.expect(std.mem.indexOf(u8, set.notes[0], "until approved") != null);

    var m2 = memory.MemoryLoader.init(testing.allocator);
    defer m2.deinit();
    const set2 = try m2.loadInitial(testing.io, .{ .workspace_roots = &.{repo}, .cwd = repo, .trust = .{ .approved = approveAll } });
    try testing.expectEqual(@as(usize, 2), set2.files.len);
    try testing.expectEqualStrings("shared\n", set2.files[1].text);
}

test "agents and claude compat toggles" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.put("repo/AGENTS.md", "a\n");
    try f.put("repo/CLAUDE.md", "c\n");
    try f.put("repo/.claude/CLAUDE.md", "c2\n");
    try f.put("repo/CLAUDE.local.md", "cl\n");
    try f.put("repo/.claude/rules/r.md", "rule\n");
    const repo = try f.abs("repo");
    var m = memory.MemoryLoader.init(testing.allocator);
    defer m.deinit();
    try expectFiles(try m.loadInitial(testing.io, .{ .workspace_roots = &.{repo}, .cwd = repo }), f.root, "repo/AGENTS.md(project) repo/CLAUDE.md(project) repo/.claude/CLAUDE.md(project) repo/CLAUDE.local.md(project_local) repo/.claude/rules/r.md(rule)");
    var m2 = memory.MemoryLoader.init(testing.allocator);
    defer m2.deinit();
    const set2 = try m2.loadInitial(testing.io, .{ .workspace_roots = &.{repo}, .cwd = repo, .compat = .{ .agents_md = false, .claude_md = false, .claude_rules_dir = false } });
    try testing.expectEqual(@as(usize, 0), set2.files.len);
}

test "size warnings and the hard cap" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const long = try a.alloc(u8, 250 * 4);
    for (0..250) |i| @memcpy(long[i * 4 ..][0..4], "abc\n");
    try f.put("repo/ZIGGURO.md", long);
    const huge = try a.alloc(u8, 120 * 1024);
    @memset(huge, 'x');
    for (0..huge.len / 100) |i| huge[i * 100 + 99] = '\n';
    try f.put("repo/AGENTS.md", huge);
    const repo = try f.abs("repo");
    var m = memory.MemoryLoader.init(testing.allocator);
    defer m.deinit();
    const set = try m.loadInitial(testing.io, .{ .workspace_roots = &.{repo}, .cwd = repo });
    try testing.expectEqual(@as(usize, 2), set.notes.len);
    try testing.expect(std.mem.indexOf(u8, set.notes[0], "250 lines") != null);
    try testing.expect(set.files[1].truncated);
    try testing.expect(set.files[1].text.len <= memory.hard_cap_bytes + 64);
    try testing.expect(std.mem.endsWith(u8, set.files[1].text, "[truncated: file exceeds 100 KiB]\n"));
}

test "reload on change keeps on-demand loads" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.put("repo/ZIGGURO.md", "v1\n");
    try f.put("repo/sub/ZIGGURO.md", "sub\n");
    try f.put("repo/.zigguro/rules/t.md", "---\npaths: [\"**/*.zig\"]\n---\nzig rule\n");
    const repo = try f.abs("repo");
    var m = memory.MemoryLoader.init(testing.allocator);
    defer m.deinit();
    _ = try m.loadInitial(testing.io, .{ .workspace_roots = &.{repo}, .cwd = repo });
    _ = try m.onFileTouched(testing.io, "sub/a.zig");
    try testing.expectEqual(@as(usize, 3), m.current().files.len);
    const h = m.current().hash;
    try testing.expect(!try m.reloadChanged(testing.io, try f.abs("repo/src/main.zig")));
    try testing.expect(!try m.reloadChanged(testing.io, try f.abs("repo/ZIGGURO.md")));
    try f.put("repo/ZIGGURO.md", "v2\n");
    try testing.expect(try m.reloadChanged(testing.io, try f.abs("repo/ZIGGURO.md")));
    try testing.expect(m.current().hash != h);
    try testing.expectEqual(@as(usize, 3), m.current().files.len);
    try testing.expectEqualStrings("v2\n", m.current().files[0].text);
}
