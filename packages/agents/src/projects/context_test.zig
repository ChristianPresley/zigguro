//! The knowledge index, the project section of the system prompt and the
//! project tools over a temporary workspace.

const std = @import("std");
const ProjectStore = @import("store.zig");
const knowledge = @import("knowledge.zig");
const Context = @import("context.zig").Context;
const tools = @import("tools.zig");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;

fn write(dir: std.Io.Dir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirnamePosix(path)) |d| try dir.createDirPath(io, d);
    try dir.writeFile(io, .{ .sub_path = path, .data = data });
}

/// Paths agents must not see: anything named `.env` or under `secrets/`.
fn denied(_: *anyopaque, path: []const u8) bool {
    return std.mem.eql(u8, std.fs.path.basenamePosix(path), ".env") or std.mem.startsWith(u8, path, "secrets/") or std.mem.indexOf(u8, path, "/secrets/") != null;
}

fn notesQuery(_: *anyopaque, arena: std.mem.Allocator, q: []const u8) anyerror![]const knowledge.Hit {
    if (!std.mem.eql(u8, q, "tag:#book")) return &.{};
    return arena.dupe(knowledge.Hit, &.{ .{ .path = "notes/idea.md", .title = "An idea" }, .{ .path = "docs/book/ch1.md" } });
}

const book_zon =
    \\.{
    \\    .version = 1,
    \\    .title = "Book",
    \\    .description = "The Zig book.",
    \\    .knowledge = .{
    \\        .{ .folder = .{ .path = "docs/book", .glob = "**/*.md" } },
    \\        .{ .notes_query = "tag:#book" },
    \\        .{ .file = "README.md" },
    \\        .{ .file = "gone.md" },
    \\        .{ .folder = .{ .path = "missing" } },
    \\    },
    \\}
;

const Fx = struct {
    tmp: testing.TmpDir,
    store: *ProjectStore,
    ctx: Context,
    dummy: u8 = 0,

    fn init(f: *Fx) !void {
        f.* = .{ .tmp = testing.tmpDir(.{ .iterate = true }), .store = undefined, .ctx = undefined };
        const d = f.tmp.dir;
        try write(d, ".zigguro/projects/book/project.zon", book_zon);
        try write(d, ".zigguro/projects/book/instructions.md", "Write in British English.\n");
        try write(d, "docs/book/ch1.md", "---\ntitle: Chapter one\n---\nBody.\n");
        try write(d, "docs/book/ch2.md", "# Comptime\n\nText.\n");
        try write(d, "docs/book/part/ch3.md", "no heading");
        try write(d, "docs/book/cover.png", "PNG");
        try write(d, "docs/book/secrets/key.md", "TOKEN=1");
        try write(d, "docs/book/.env", "X=1");
        try write(d, "notes/idea.md", "idea");
        try write(d, "README.md", "# Readme\n");
        try write(d, "other.md", "not knowledge");
        f.store = try ProjectStore.open(gpa, io, d, .{});
        f.ctx = .{ .io = io, .store = f.store, .env = .{
            .root = d,
            .notes = .{ .ctx = &f.dummy, .query = notesQuery },
            .deny = .{ .ctx = &f.dummy, .denied = denied },
        } };
    }

    fn deinit(f: *Fx) void {
        f.store.deinit();
        f.tmp.cleanup();
    }
};

fn paths(idx: knowledge.KnowledgeIndex, a: std.mem.Allocator) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(a);
    for (idx.entries) |e| try w.writer.print("{s}\n", .{e.path});
    return w.written();
}

test "knowledge_index_bounded_and_ordered" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const v = f.store.view();
    defer f.store.release(v);
    const p = v.get("book").?;
    const idx = try knowledge.build(io, a, p, f.ctx.env, .{});
    // Item order; within a folder by path; the note hit already listed by
    // the folder is not repeated; secrets are left out.
    try testing.expectEqualStrings(
        \\docs/book/ch1.md
        \\docs/book/ch2.md
        \\docs/book/part/ch3.md
        \\notes/idea.md
        \\README.md
        \\
    , try paths(idx, a));
    try testing.expectEqualStrings("Chapter one", idx.entries[0].title);
    try testing.expectEqualStrings("Comptime", idx.entries[1].title);
    try testing.expectEqualStrings("ch3.md", idx.entries[2].title);
    try testing.expectEqualStrings("An idea", idx.entries[3].title);
    try testing.expectEqual(@as(u32, 0), idx.more);

    const capped = try knowledge.build(io, a, p, f.ctx.env, .{ .max_entries = 2 });
    try testing.expectEqual(@as(usize, 2), capped.entries.len);
    try testing.expectEqual(@as(u32, 3), capped.more);
    const by_tokens = try knowledge.build(io, a, p, f.ctx.env, .{ .max_tokens = 30 });
    try testing.expect(by_tokens.entries.len < 5);
    try testing.expectEqual(@as(u32, @intCast(5 - by_tokens.entries.len)), by_tokens.more);
}

test "missing knowledge items are warnings" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const v = f.store.view();
    defer f.store.release(v);
    var env = f.ctx.env;
    env.notes = null;
    const idx = try knowledge.build(io, arena.allocator(), v.get("book").?, env, .{});
    try testing.expectEqual(@as(usize, 3), idx.warnings.len);
    try testing.expectEqualStrings("notes query \"tag:#book\" skipped: not available here", idx.warnings[0]);
    try testing.expectEqualStrings("missing file gone.md", idx.warnings[1]);
    try testing.expect(std.mem.startsWith(u8, idx.warnings[2], "skipped folder missing: "));
}

test "secret_files_excluded" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const v = f.store.view();
    defer f.store.release(v);
    const p = v.get("book").?;
    try testing.expect(try knowledge.contains(a, p, f.ctx.env, "docs/book/ch2.md"));
    try testing.expect(try knowledge.contains(a, p, f.ctx.env, "notes/idea.md"));
    try testing.expect(!try knowledge.contains(a, p, f.ctx.env, "docs/book/secrets/key.md"));
    try testing.expect(!try knowledge.contains(a, p, f.ctx.env, "docs/book/.env"));
    try testing.expect(!try knowledge.contains(a, p, f.ctx.env, "docs/book/cover.png"));
    try testing.expect(!try knowledge.contains(a, p, f.ctx.env, "other.md"));
    try testing.expect(!try knowledge.contains(a, p, f.ctx.env, "docs/book/../../other.md"));
}

test "context golden, and none outside a project" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // Fixed dates and sizes for the golden text.
    var idx = try knowledge.build(io, a, f.store.view().get("book").?, f.ctx.env, .{});
    f.store.release(f.store.current);
    const entries = try a.dupe(knowledge.Entry, idx.entries);
    for (entries) |*e| e.modified_ms = 1_792_756_800_000;
    entries[0].size = 3000;
    idx.entries = entries;
    var w: std.Io.Writer.Allocating = .init(a);
    const v = f.store.view();
    defer f.store.release(v);
    try @import("context.zig").write(&w.writer, v.get("book").?, try f.store.instructions(a, "book"), &idx);
    try testing.expectEqualStrings(
        \\# Project: Book
        \\
        \\The Zig book.
        \\
        \\## Instructions
        \\
        \\Write in British English.
        \\
        \\## Knowledge
        \\
        \\- docs/book/ch1.md · Chapter one · 3 KB · 2026-10-23
        \\- docs/book/ch2.md · Comptime · 18 B · 2026-10-23
        \\- docs/book/part/ch3.md · ch3.md · 10 B · 2026-10-23
        \\- notes/idea.md · An idea · 4 B · 2026-10-23
        \\- README.md · Readme · 9 B · 2026-10-23
        \\
        \\The contents are not included: read a file with project_knowledge_read, or search notes with search_notes.
        \\
    , w.written());

    const port = f.ctx.port();
    const s = (try port.section(port.ctx, a, "book")).?;
    try testing.expect(std.mem.startsWith(u8, s, "# Project: Book\n"));
    try testing.expect(try port.section(port.ctx, a, "nope") == null);
}

fn call(t: *tools.ToolExporter, a: std.mem.Allocator, tool: []const u8, input: []const u8) !tools.Output {
    return tools.run(t, a, tool, input);
}

test "project tools read only the project's knowledge" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var t: tools.ToolExporter = .{ .ctx = &f.ctx };
    // No active project yet.
    try testing.expect((try call(&t, a, "project_info", "{}")).is_error);
    try f.store.setActive("book");

    const info = try call(&t, a, "project_info", "");
    try testing.expect(!info.is_error);
    try testing.expect(std.mem.indexOf(u8, info.text, "\"title\":\"Book\"") != null);
    try testing.expect(std.mem.indexOf(u8, info.text, "{\"kind\":\"notes_query\",\"value\":\"tag:#book\"}") != null);

    const list = try call(&t, a, "project_knowledge_list", "{\"query\":\"COMPTIME\"}");
    try testing.expect(std.mem.startsWith(u8, list.text, "- docs/book/ch2.md · Comptime · 18 B · "));
    try testing.expect(std.mem.indexOf(u8, list.text, "warning: missing file gone.md") != null);

    const read = try call(&t, a, "project_knowledge_read", "{\"path\":\"docs/book/ch2.md\"}");
    try testing.expectEqualStrings("# Comptime\n\nText.\n", read.text);
    const part = try call(&t, a, "project_knowledge_read", "{\"path\":\"docs/book/ch2.md\",\"offset\":2,\"limit\":8}");
    try testing.expectEqualStrings("Comptime\n\n[bytes 2-10 of 18; read more with offset 10]", part.text);
    const secret = try call(&t, a, "project_knowledge_read", "{\"path\":\"docs/book/secrets/key.md\"}");
    try testing.expect(secret.is_error);
    try testing.expect(std.mem.indexOf(u8, secret.text, "not one of the project's knowledge files") != null);
    try testing.expect((try call(&t, a, "project_knowledge_read", "{\"path\":\"other.md\"}")).is_error);
    try testing.expect((try call(&t, a, "project_knowledge_read", "{\"nope\":1}")).is_error);
    try testing.expectError(error.UnknownTool, call(&t, a, "project_delete", "{}"));

    // A pinned project wins over the active one.
    t.project = "other";
    try testing.expect(std.mem.indexOf(u8, (try call(&t, a, "project_info", "{}")).text, "no project \"other\"") != null);
}
