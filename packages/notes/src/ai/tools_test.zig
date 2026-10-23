const std = @import("std");
const tools = @import("tools.zig");
const resources = @import("resources.zig");
const commands = @import("../daily/commands.zig");
const localtime = @import("../daily/localtime.zig");
const ni = @import("../index/note_index.zig");
const search_index = @import("../search/search_index.zig");
const vault_mod = @import("../vault/vault.zig");

const testing = std.testing;
const Io = std.Io;
const FileId = @import("../vault/note.zig").FileId;

const FakeForeign = struct {
    pub const Kind = enum { lsp, debug, tasks, workspace, notes, scm, mcp };
    pub const ForeignTool = struct {
        name: []const u8,
        description: []const u8,
        input_schema_json: []const u8,
        read_only: bool = false,
        mutates: bool = false,
    };
    pub const Result = struct { json: []const u8, changeset: ?u64 = null };
    pub const Exporter = struct {
        name: []const u8,
        kind: Kind,
        ctx: *anyopaque,
        list: *const fn (ctx: *anyopaque, arena: std.mem.Allocator) anyerror![]const ForeignTool,
        call: *const fn (ctx: *anyopaque, io: Io, arena: std.mem.Allocator, tool: []const u8, input_json: []const u8) anyerror!Result,
    };
};

/// Records proposed changes; nothing reaches the files.
const Changes = struct {
    arena: std.heap.ArenaAllocator,
    calls: u32 = 0,
    last: []tools.FileChange = &.{},
    label: []const u8 = "",

    fn propose(ctx: *anyopaque, label: []const u8, tool: []const u8, changes: []const tools.FileChange) anyerror!u64 {
        _ = tool;
        const c: *Changes = @ptrCast(@alignCast(ctx));
        const a = c.arena.allocator();
        c.calls += 1;
        c.label = try a.dupe(u8, label);
        c.last = try a.alloc(tools.FileChange, changes.len);
        for (changes, c.last) |x, *o| o.* = .{ .path = try a.dupe(u8, x.path), .base = if (x.base) |b| try a.dupe(u8, b) else null, .new = try a.dupe(u8, x.new) };
        return 100 + c.calls;
    }
};

/// Refuses anything under `private/`.
fn denyPrivate(_: *anyopaque, path: []const u8, write: bool) ?[]const u8 {
    _ = write;
    return if (std.mem.startsWith(u8, path, "private/")) "private notes are excluded by policy" else null;
}

/// Reads the temp dir; `create` fails so the tools cannot write.
const ReadOnlyFiles = struct {
    inner: commands.DirFiles,

    fn port(f: *ReadOnlyFiles) commands.FilePort {
        return .{ .ctx = f, .read = read, .create = create };
    }

    fn read(ctx: *anyopaque, gpa: std.mem.Allocator, path: []const u8) anyerror!?[]u8 {
        const f: *ReadOnlyFiles = @ptrCast(@alignCast(ctx));
        var p = f.inner.port();
        return p.read(p.ctx, gpa, path);
    }

    fn create(_: *anyopaque, _: []const u8, _: []const u8) anyerror!void {
        return error.WriteAttempted;
    }
};

const Env = struct {
    tmp: testing.TmpDir,
    files: ReadOnlyFiles,
    vault: vault_mod.Vault,
    ix: *ni.NoteIndex,
    search: *search_index.SearchIndex,
    tz: localtime.LocalTz,
    changes: Changes,
    next_id: u32,
    arena: std.heap.ArenaAllocator,

    fn init(e: *Env, cfg: vault_mod.VaultConfig) !void {
        e.tmp = testing.tmpDir(.{});
        e.files = .{ .inner = .{ .dir = e.tmp.dir, .io = testing.io } };
        e.vault = .{ .id = .of(0), .root = .of(0), .rel_dir = "", .config = cfg };
        e.ix = try ni.NoteIndex.init(testing.allocator, testing.io, &.{e.vault});
        e.search = try search_index.SearchIndex.attach(e.ix, .{});
        e.tz = .utc(testing.allocator);
        e.changes = .{ .arena = .init(testing.allocator) };
        e.next_id = 0;
        e.arena = .init(testing.allocator);
    }

    fn deinit(e: *Env) void {
        e.arena.deinit();
        e.changes.arena.deinit();
        e.search.deinit();
        e.ix.deinit();
        e.tmp.cleanup();
    }

    fn source(e: *Env) tools.Source {
        return .{
            .gpa = testing.allocator,
            .ix = e.ix,
            .search = e.search,
            .vault = &e.vault,
            .files = e.files.port(),
            .changes = .{ .ctx = &e.changes, .propose = Changes.propose },
            .tz = &e.tz,
            .io = testing.io,
            .policy = .{ .ctx = e, .check = denyPrivate },
        };
    }

    fn put(e: *Env, path: []const u8, bytes: []const u8) !void {
        const parent = std.fs.path.dirname(path) orelse "";
        if (parent.len > 0) try e.tmp.dir.createDirPath(testing.io, parent);
        try e.tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = bytes });
        try e.ix.indexNote(.{ .index = e.next_id, .gen = 0 }, .of(0), path, bytes);
        e.next_id += 1;
        try e.ix.commit();
    }

    /// Runs `tool` and returns the text block (asserting `is_error`).
    fn call(e: *Env, src: *tools.Source, tool: []const u8, input: []const u8, want_error: bool) ![]const u8 {
        const a = e.arena.allocator();
        const out = try tools.run(src, a, tool, input);
        const R = struct { content: []const struct { type: []const u8, text: []const u8 }, isError: bool };
        const r = try std.json.parseFromSliceLeaky(R, a, out.json, .{});
        if (r.isError != want_error) {
            std.debug.print("{s} -> {s}\n", .{ tool, r.content[0].text });
            return error.TestUnexpectedResult;
        }
        try testing.expectEqual(want_error, out.is_error);
        return r.content[0].text;
    }

    fn fileText(e: *Env, path: []const u8) ![]u8 {
        return e.tmp.dir.readFileAlloc(testing.io, path, e.arena.allocator(), .limited(1 << 20));
    }
};

fn expectContains(hay: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, hay, needle) == null) {
        std.debug.print("missing {s} in {s}\n", .{ needle, hay });
        return error.TestUnexpectedResult;
    }
}

test "tools: schemas are JSON objects and the exporter lists six tools" {
    inline for (.{ tools.schemas.search_notes, tools.schemas.read_note, tools.schemas.note_links, tools.schemas.create_note, tools.schemas.update_note, tools.schemas.daily_note }) |s| {
        const v = try std.json.parseFromSlice(std.json.Value, testing.allocator, s, .{});
        defer v.deinit();
        try testing.expectEqualStrings("object", v.value.object.get("type").?.string);
    }
    var e: Env = undefined;
    try e.init(.{});
    defer e.deinit();
    var x: tools.ToolExporter(FakeForeign) = .{ .src = e.source() };
    const ex = x.exporter();
    try testing.expectEqual(FakeForeign.Kind.notes, ex.kind);
    const ts = try ex.list(ex.ctx, e.arena.allocator());
    try testing.expectEqual(@as(usize, 6), ts.len);
    var mutating: usize = 0;
    for (ts) |t| {
        try testing.expect(t.read_only != t.mutates);
        mutating += @intFromBool(t.mutates);
    }
    try testing.expectEqual(@as(usize, 3), mutating);
    try testing.expectError(error.UnknownTool, ex.call(ex.ctx, testing.io, e.arena.allocator(), "nope", "{}"));
}

test "tools: search, read and links honour the path policy" {
    var e: Env = undefined;
    try e.init(.{});
    defer e.deinit();
    try e.put("Alpha.md", "---\nstatus: open\n---\n# Alpha\nzebra notes here\n## Part\nsee [[Beta]] ^blk1\n");
    try e.put("Beta.md", "# Beta\nzebra again, links [[Gamma]]\n");
    try e.put("Gamma.md", "# Gamma\nplain\n");
    try e.put("private/Secret.md", "zebra secret, [[Alpha]]\n");
    var src = e.source();

    const s = try e.call(&src, "search_notes", "{\"query\": \"zebra\"}", false);
    try expectContains(s, "\"path\":\"Alpha.md\"");
    try expectContains(s, "\"path\":\"Beta.md\"");
    try testing.expect(std.mem.indexOf(u8, s, "Secret") == null);
    _ = try e.call(&src, "search_notes", "{\"query\": \"(zebra\"}", true);
    // A hit's id reads the same note.
    const Hits = struct { items: []const struct { id: u64, path: []const u8 } };
    const hits = try std.json.parseFromSliceLeaky(Hits, e.arena.allocator(), s, .{ .ignore_unknown_fields = true });
    const by_id = try e.call(&src, "read_note", try std.fmt.allocPrint(e.arena.allocator(), "{{\"id\": {d}}}", .{hits.items[0].id}), false);
    try expectContains(by_id, try std.fmt.allocPrint(e.arena.allocator(), "\"path\":\"{s}\"", .{hits.items[0].path}));
    _ = try e.call(&src, "read_note", "{\"id\": 999999}", true);
    _ = try e.call(&src, "read_note", "{}", true);

    const r = try e.call(&src, "read_note", "{\"path\": \"Alpha.md\"}", false);
    try expectContains(r, "\"text\":\"# Alpha\\nzebra notes here");
    try expectContains(r, "\"name\":\"status\"");
    try expectContains(r, "\"backlinks_count\":1");
    try testing.expect(std.mem.indexOf(u8, r, "---") == null);
    const sec = try e.call(&src, "read_note", "{\"path\": \"Alpha.md\", \"section\": \"## part\"}", false);
    try expectContains(sec, "\"text\":\"## Part\\nsee [[Beta]] ^blk1\\n\"");
    try expectContains(try e.call(&src, "read_note", "{\"path\": \"Alpha.md\", \"block\": \"^blk1\"}", false), "see [[Beta]]");
    try expectContains(try e.call(&src, "read_note", "{\"path\": \"Alpha.md\", \"section\": \"Nope\"}", true), "no heading");

    // Denied with the policy's reason; traversal is refused outright.
    const d = try e.call(&src, "read_note", "{\"path\": \"private/Secret.md\"}", true);
    try testing.expectEqualStrings("access to private/Secret.md denied: private notes are excluded by policy", d);
    try expectContains(try e.call(&src, "read_note", "{\"path\": \"../etc/passwd\"}", true), "vault-relative");
    try expectContains(try e.call(&src, "read_note", "{\"nope\": 1}", true), "schema");

    const l = try e.call(&src, "note_links", "{\"path\": \"Beta.md\", \"direction\": \"both\", \"depth\": 2}", false);
    try expectContains(l, "{\"from\":\"Beta.md\",\"to\":\"Gamma.md\",\"depth\":1}");
    try expectContains(l, "{\"from\":\"Alpha.md\",\"to\":\"Beta.md\",\"depth\":1}");
    // Alpha's backlink from the private note is hidden.
    try testing.expect(std.mem.indexOf(u8, l, "Secret") == null);
    _ = try e.call(&src, "note_links", "{\"path\": \"Beta.md\", \"direction\": \"in\", \"depth\": 3}", true);
}

test "tools: output is capped with a truncation hint" {
    var e: Env = undefined;
    try e.init(.{});
    defer e.deinit();
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(testing.allocator);
    try big.appendSlice(testing.allocator, "# Big\n");
    for (0..5000) |i| try big.print(testing.allocator, "line {d} with some words é\n", .{i});
    try e.put("Big.md", big.items);
    for (0..60) |i| {
        var buf: [32]u8 = undefined;
        try e.put(try std.fmt.bufPrint(&buf, "n{d}.md", .{i}), "needle text with filler words to make snippets longer than tiny\n");
    }
    var src = e.source();
    const r = try e.call(&src, "read_note", "{\"path\": \"Big.md\"}", false);
    try testing.expect(r.len <= 32 << 10);
    try expectContains(r, "\"truncated\":true");
    try testing.expect(std.unicode.utf8ValidateSlice(r));
    src.max_output = 2048;
    const s = try e.call(&src, "search_notes", "{\"query\": \"needle\", \"limit\": 50}", false);
    try testing.expect(s.len <= 2048);
    try expectContains(s, "\"truncated\":true");
    try expectContains(s, "lower `limit`");
}

test "tools: update_note proposes golden edits and never writes" {
    var e: Env = undefined;
    try e.init(.{});
    defer e.deinit();
    const before = "---\nstatus: open\n---\n# Plan\n## Tasks\n- a\n\n## Log\nold\n";
    try e.put("Plan.md", before);
    var src = e.source();
    var x: tools.ToolExporter(FakeForeign) = .{ .src = src };
    const ex = x.exporter();
    const res = try ex.call(ex.ctx, testing.io, e.arena.allocator(), "update_note",
        \\{"path": "Plan.md", "edits": [
        \\  {"op": "append_section", "heading": "Tasks", "text": "- b"},
        \\  {"op": "replace_section", "heading": "Log", "text": "new"},
        \\  {"op": "set_property", "name": "status", "value": "done"},
        \\  {"op": "add_tag", "tag": "#work"},
        \\  {"op": "str_replace", "old": "# Plan", "new": "# The plan"}
        \\]}
    );
    try testing.expectEqual(@as(?u64, 101), res.changeset);
    try expectContains(res.json, "{\\\"pending_change\\\":101}");
    try testing.expectEqual(@as(usize, 1), e.changes.last.len);
    const ch = e.changes.last[0];
    try testing.expectEqualStrings("Plan.md", ch.path);
    try testing.expectEqualStrings(before, ch.base.?);
    try testing.expectEqualStrings("---\nstatus: done\ntags:\n  - work\n---\n# The plan\n## Tasks\n- a\n- b\n\n## Log\nnew\n", ch.new);
    try testing.expectEqualStrings(before, try e.fileText("Plan.md"));

    // Not unique: the count, and no change proposed.
    try e.put("Dup.md", "x and x\n");
    const dup = try e.call(&src, "update_note", "{\"path\": \"Dup.md\", \"edits\": [{\"op\": \"str_replace\", \"old\": \"x\", \"new\": \"y\"}]}", true);
    try testing.expectEqualStrings("edit 0: old matches 2 times; it must match exactly once (add surrounding text)", dup);
    try testing.expectEqual(@as(u32, 1), e.changes.calls);
    // No-op edits propose nothing.
    const same = try e.call(&src, "update_note", "{\"path\": \"Plan.md\", \"edits\": [{\"op\": \"set_property\", \"name\": \"status\", \"value\": \"open\"}]}", false);
    try expectContains(same, "\"unchanged\":true");
    try testing.expectEqual(@as(u32, 1), e.changes.calls);
    _ = try e.call(&src, "update_note", "{\"path\": \"private/X.md\", \"edits\": [{\"op\": \"append\", \"text\": \"t\"}]}", true);
    _ = try e.call(&src, "update_note", "{\"path\": \"Plan.md\", \"edits\": [{\"op\": \"explode\"}]}", true);
}

test "tools: create_note and daily_note from templates are pending changes" {
    var e: Env = undefined;
    try e.init(.{ .daily_dir = "daily", .daily_template = "templates/Daily", .new_note_dir = .fixed, .new_note_folder = "inbox" });
    defer e.deinit();
    try e.put("templates/Meeting.md", "# {{title}}\n## Agenda\n");
    try e.put("templates/Daily.md", "# {{date:YYYY-MM-DD}}\n");
    try e.put("daily/2026-10-20.md", "# 2026-10-20\n");
    var src = e.source();

    const c = try e.call(&src, "create_note", "{\"title\": \"Sync: Q4\", \"template\": \"Meeting\", \"content\": \"- item\", \"properties\": {\"attendees\": [\"ann\", \"bo\"]}}", false);
    try expectContains(c, "\"path\":\"inbox/Sync- Q4.md\"");
    try expectContains(c, "\"pending_change\":101");
    const ch = e.changes.last[0];
    try testing.expect(ch.base == null);
    try testing.expectEqualStrings("---\nattendees:\n  - ann\n  - bo\n---\n# Sync: Q4\n## Agenda\n- item\n", ch.new);
    try testing.expectError(error.FileNotFound, e.tmp.dir.access(testing.io, "inbox/Sync- Q4.md", .{}));
    _ = try e.call(&src, "create_note", "{\"path\": \"Templates/Meeting\"}", true);
    _ = try e.call(&src, "create_note", "{\"title\": \"X\", \"template\": \"Missing\"}", true);

    const look = try e.call(&src, "daily_note", "{\"date\": \"2026-10-20\"}", false);
    try testing.expectEqualStrings("{\"path\":\"daily/2026-10-20.md\",\"exists\":true}", look);
    _ = try e.call(&src, "daily_note", "{\"date\": \"2026-10-20\", \"append\": \"- done\"}", false);
    try testing.expectEqualStrings("# 2026-10-20\n- done\n", e.changes.last[0].new);
    _ = try e.call(&src, "daily_note", "{\"date\": \"2026-10-21\", \"append\": \"- new\"}", false);
    try testing.expect(e.changes.last[0].base == null);
    try testing.expectEqualStrings("# 2026-10-21\n- new\n", e.changes.last[0].new);
    _ = try e.call(&src, "daily_note", "{\"date\": \"21/10/2026\"}", true);
}

const Seen = struct {
    n: u32 = 0,
    fn on(ctx: *anyopaque, uri: []const u8) void {
        _ = uri;
        const s: *Seen = @ptrCast(@alignCast(ctx));
        s.n += 1;
    }
};

test "resources: list pagination stable; read unknown -> error.NotFound; watch fires on change and stops after unwatch" {
    var e: Env = undefined;
    try e.init(.{});
    defer e.deinit();
    for (0..5) |i| {
        var buf: [32]u8 = undefined;
        try e.put(try std.fmt.bufPrint(&buf, "n {d}.md", .{i}), "# hi\n");
    }
    try e.put("private/p.md", "x");
    var listed: Seen = .{};
    var ra: resources.ResourceAdapter = .{
        .gpa = testing.allocator,
        .io = testing.io,
        .ix = e.ix,
        .vault = &e.vault,
        .files = e.files.port(),
        .policy = .{ .ctx = &e, .check = denyPrivate },
        .page_size = 2,
        .list_changed = .{ .ctx = &listed, .on_event = Seen.on },
    };
    try ra.start();
    defer ra.deinit();
    const a = e.arena.allocator();
    const p1 = try ra.list(null, a);
    try testing.expectEqual(@as(usize, 2), p1.resources.len);
    try testing.expectEqualStrings("note://0/n%200.md", p1.resources[0].uri);
    try testing.expectEqualStrings("n 0.md", p1.resources[0].name);
    // A note added between pages does not shift the next page.
    try e.put("n 9.md", "late");
    try testing.expectEqual(@as(u32, 1), listed.n);
    const p2 = try ra.list(p1.next_cursor, a);
    try testing.expectEqualStrings("note://0/n%202.md", p2.resources[0].uri);
    const p3 = try ra.list(p2.next_cursor, a);
    try testing.expectEqual(@as(usize, 2), p3.resources.len);
    try testing.expectEqualStrings("note://0/n%209.md", p3.resources[1].uri);
    try testing.expect(p3.next_cursor == null);
    try testing.expectError(error.BadCursor, ra.list("garbage!", a));

    const c = try ra.read("note://0/n%201.md", a);
    try testing.expectEqualStrings("# hi\n", c.text);
    try testing.expectEqualStrings("text/markdown", c.mime_type);
    try testing.expectError(error.NotFound, ra.read("note://0/missing.md", a));
    try testing.expectError(error.NotFound, ra.read("note://7/n%201.md", a));
    try testing.expectError(error.NotFound, ra.read("file:///n 1.md", a));
    try testing.expectError(error.Denied, ra.read("note://0/private/p.md", a));
    try testing.expectEqualStrings("note://{vault}/{path}", ra.templates()[0].uri_template);

    var seen: Seen = .{};
    const w = try ra.watch("note://0/n%201.md", .{ .ctx = &seen, .on_event = Seen.on });
    try e.ix.indexNote(.{ .index = 1, .gen = 0 }, .of(0), "n 1.md", "# changed\n");
    try e.ix.commit();
    try testing.expectEqual(@as(u32, 1), seen.n);
    // A change, not an addition.
    try testing.expectEqual(@as(u32, 1), listed.n);
    ra.unwatch(w);
    try e.ix.indexNote(.{ .index = 1, .gen = 0 }, .of(0), "n 1.md", "# again\n");
    try e.ix.commit();
    try testing.expectEqual(@as(u32, 1), seen.n);
    try testing.expectError(error.NotFound, ra.watch("note://0/none.md", .{ .ctx = &seen, .on_event = Seen.on }));
}
