//! The project store over a temporary workspace: create and update by
//! the user and by agents, load problems, the active project, and
//! `instructions.md` with imports.

const std = @import("std");
const runs = @import("../runs/root.zig");
const ProjectStore = @import("store.zig");
const project = @import("project.zig");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;

pub const FakeChanges = struct {
    reqs: std.ArrayList(struct { path: []u8, after: []u8 }) = .empty,

    pub fn propose(ctx: *anyopaque, r: ProjectStore.ChangeRequest) anyerror!u64 {
        const c: *FakeChanges = @ptrCast(@alignCast(ctx));
        try c.reqs.append(gpa, .{ .path = try gpa.dupe(u8, r.path), .after = try gpa.dupe(u8, r.after.?) });
        return 100 + c.reqs.items.len;
    }

    pub fn deinit(c: *FakeChanges) void {
        for (c.reqs.items) |r| {
            gpa.free(r.path);
            gpa.free(r.after);
        }
        c.reqs.deinit(gpa);
    }
};

pub const FakeState = struct {
    value: ?[]u8 = null,

    fn get(ctx: *anyopaque, arena: std.mem.Allocator, key: []const u8) ?[]const u8 {
        const s: *FakeState = @ptrCast(@alignCast(ctx));
        std.debug.assert(std.mem.eql(u8, key, ProjectStore.active_key));
        return if (s.value) |v| arena.dupe(u8, v) catch null else null;
    }

    fn put(ctx: *anyopaque, key: []const u8, value: ?[]const u8) anyerror!void {
        const s: *FakeState = @ptrCast(@alignCast(ctx));
        std.debug.assert(std.mem.eql(u8, key, ProjectStore.active_key));
        if (s.value) |v| gpa.free(v);
        s.value = if (value) |v| try gpa.dupe(u8, v) else null;
    }

    pub fn port(s: *FakeState) ProjectStore.StatePort {
        return .{ .ctx = s, .get = get, .put = put };
    }
};

fn write(dir: std.Io.Dir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirnamePosix(path)) |d| try dir.createDirPath(io, d);
    try dir.writeFile(io, .{ .sub_path = path, .data = data });
}

test "create, list, update by the user" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const s = try ProjectStore.open(gpa, io, tmp.dir, .{});
    defer s.deinit();
    {
        const v = s.view();
        defer s.release(v);
        try testing.expectEqual(@as(usize, 0), v.projects.len);
    }
    _ = try s.create(.{ .slug = "zeta", .title = "Zeta" }, .user);
    _ = try s.create(.{ .slug = "alpha", .title = "alpha", .instructions = "Be brief." }, .user);
    _ = try s.create(.{ .slug = "pinned", .title = "Pinned", .pinned = true }, .user);
    try testing.expectError(error.Exists, s.create(.{ .slug = "zeta", .title = "Again" }, .user));
    try testing.expectError(error.InvalidSlug, s.create(.{ .slug = "Bad Slug", .title = "x" }, .user));
    try testing.expectError(error.Invalid, s.create(.{ .slug = "empty", .title = " " }, .user));
    {
        const v = s.view();
        defer s.release(v);
        try testing.expectEqual(@as(usize, 3), v.projects.len);
        try testing.expectEqualStrings("pinned", v.projects[0].slug);
        try testing.expectEqualStrings("alpha", v.projects[1].slug);
        try testing.expectEqualStrings("zeta", v.projects[2].slug);
    }
    const ins = try tmp.dir.readFileAlloc(io, ".zigguro/projects/zeta/instructions.md", gpa, .limited(1024));
    defer gpa.free(ins);
    try testing.expectEqualStrings("", ins);

    _ = try s.update("zeta", .{ .description = "The last one.", .instructions = "Use tables." }, .user);
    const v = s.view();
    defer s.release(v);
    try testing.expectEqualStrings("The last one.", v.get("zeta").?.description);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try testing.expectEqualStrings("Use tables.", (try s.instructions(arena.allocator(), "zeta")).text);
    try testing.expectError(error.UnknownProject, s.update("nope", .{ .pinned = true }, .user));
}

test "agent_write_makes_changeset" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var changes: FakeChanges = .{};
    defer changes.deinit();
    const s = try ProjectStore.open(gpa, io, tmp.dir, .{ .changes = .{ .ctx = &changes, .propose = FakeChanges.propose } });
    defer s.deinit();
    const ag: ProjectStore.WriteVia = .{ .agent = .{ .run = runs.RunId.fromInt(7) } };
    const out = try s.create(.{ .slug = "book", .title = "Book" }, ag);
    try testing.expectEqual(@as(?u64, 101), out.changesets.project);
    try testing.expectEqual(@as(?u64, 102), out.changesets.instructions);
    try testing.expectEqualStrings(".zigguro/projects/book/project.zon", changes.reqs.items[0].path);
    try testing.expectEqualStrings(".zigguro/projects/book/instructions.md", changes.reqs.items[1].path);
    // Nothing was written.
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, ".zigguro/projects/book/project.zon", .{}));

    _ = try s.create(.{ .slug = "book", .title = "Book" }, .user);
    const up = try s.update("book", .{ .pinned = true }, ag);
    try testing.expectEqual(@as(?u64, 103), up.changesets.project);
    try testing.expect(up.changesets.instructions == null);
    try testing.expect(std.mem.indexOf(u8, changes.reqs.items[2].after, ".pinned = true") != null);

    const bare = try ProjectStore.open(gpa, io, tmp.dir, .{});
    defer bare.deinit();
    try testing.expectError(error.ReviewUnavailable, bare.update("book", .{ .pinned = true }, ag));
}

test "broken project files are listed as problems" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try write(tmp.dir, ".zigguro/projects/ok/project.zon", ".{ .version = 1, .title = \"Ok\" }");
    try write(tmp.dir, ".zigguro/projects/bad/project.zon", ".{ .version = 1, .title = \"x\", .colour = 1 }");
    try write(tmp.dir, ".zigguro/projects/noconf/notes.md", "x");
    try write(tmp.dir, ".zigguro/projects/Not A Slug/project.zon", ".{ .version = 1, .title = \"y\" }");
    const s = try ProjectStore.open(gpa, io, tmp.dir, .{});
    defer s.deinit();
    const v = s.view();
    defer s.release(v);
    try testing.expectEqual(@as(usize, 1), v.projects.len);
    try testing.expectEqual(@as(usize, 2), v.problems.len);
    for (v.problems) |p| {
        if (std.mem.eql(u8, p.slug, "bad")) try testing.expectEqual(@as(u32, 1), p.problem.line);
        if (std.mem.eql(u8, p.slug, "noconf")) try testing.expect(std.mem.indexOf(u8, p.problem.message, "cannot read") != null);
    }
}

const Counter = struct {
    n: std.atomic.Value(u32) = .init(0),
    fn changed(ctx: *anyopaque) void {
        const c: *Counter = @ptrCast(@alignCast(ctx));
        _ = c.n.fetchAdd(1, .monotonic);
    }
};

test "active_project_persisted" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var state: FakeState = .{};
    defer if (state.value) |x| gpa.free(x);
    {
        const s = try ProjectStore.open(gpa, io, tmp.dir, .{ .state = state.port() });
        defer s.deinit();
        var c: Counter = .{};
        const sub = try s.subscribe(.{ .ctx = &c, .changed = Counter.changed });
        try testing.expect(s.active() == null);
        try s.setActive("book");
        try testing.expectEqual(@as(u32, 1), c.n.load(.monotonic));
        s.unsubscribe(sub);
        try s.setActive("q4");
        try testing.expectEqual(@as(u32, 1), c.n.load(.monotonic));
        try testing.expectError(error.InvalidSlug, s.setActive("../x"));
    }
    try testing.expectEqualStrings("q4", state.value.?);
    const s = try ProjectStore.open(gpa, io, tmp.dir, .{ .state = state.port() });
    defer s.deinit();
    try testing.expectEqualStrings("q4", s.active().?);
    try s.setActive(null);
    try testing.expect(state.value == null);
}

test "instructions expand imports, skip cycles and escapes, and are capped" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try write(tmp.dir, ".zigguro/projects/book/project.zon", ".{ .version = 1, .title = \"Book\" }");
    try write(tmp.dir, ".zigguro/projects/book/instructions.md", "Main.\n@style.md\n@../../../../outside.md\n@missing.md\n");
    try write(tmp.dir, ".zigguro/projects/book/style.md", "Style.\n@instructions.md\n");
    const s = try ProjectStore.open(gpa, io, tmp.dir, .{});
    defer s.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const ins = try s.instructions(a, "book");
    try testing.expect(std.mem.startsWith(u8, ins.text, "Main.\n"));
    try testing.expect(std.mem.indexOf(u8, ins.text, "<!-- @.zigguro/projects/book/style.md -->\nStyle.") != null);
    try testing.expect(!ins.truncated);
    // The cycle back to instructions.md, the path out of the workspace and
    // the missing file.
    try testing.expectEqual(@as(usize, 3), ins.skipped.len);
    try testing.expectEqualStrings("", (try s.instructions(a, "none")).text);

    const big = try a.alloc(u8, project.max_instructions + 100);
    @memset(big, 'x');
    try write(tmp.dir, ".zigguro/projects/book/instructions.md", big);
    const capped = try s.instructions(a, "book");
    try testing.expect(capped.truncated);
    try testing.expectEqual(@as(usize, project.max_instructions), capped.text.len);
}
