const std = @import("std");
const completion = @import("completion.zig");
const hover = @import("hover.zig");
const link_nav = @import("link_nav.zig");
const diagnostics = @import("diagnostics.zig");
const ni = @import("../index/note_index.zig");
const mentions = @import("../index/mentions.zig");
const vault_mod = @import("../vault/vault.zig");

const testing = std.testing;
const FileId = @import("../vault/note.zig").FileId;

const Env = struct {
    vault: vault_mod.Vault,
    ix: *ni.NoteIndex,
    files: std.StringHashMapUnmanaged([]const u8) = .empty,
    next: u32 = 0,
    arena: std.heap.ArenaAllocator,

    fn init(e: *Env, cfg: vault_mod.VaultConfig) !void {
        e.* = .{ .vault = .{ .id = .of(0), .root = .of(0), .rel_dir = "", .config = cfg }, .ix = undefined, .arena = .init(testing.allocator) };
        e.ix = try ni.NoteIndex.init(testing.allocator, testing.io, &.{e.vault});
    }

    fn deinit(e: *Env) void {
        e.ix.deinit();
        e.arena.deinit();
    }

    fn put(e: *Env, path: []const u8, bytes: []const u8) !FileId {
        const id: FileId = .{ .index = e.next, .gen = 0 };
        e.next += 1;
        try e.files.put(e.arena.allocator(), path, bytes);
        try e.ix.indexNote(id, .of(0), path, bytes);
        try e.ix.commit();
        return id;
    }

    fn attach(e: *Env, path: []const u8) !void {
        try e.ix.setAttachment(.{ .index = e.next, .gen = 0 }, .of(0), path);
        e.next += 1;
        try e.ix.commit();
    }

    fn read(ctx: *anyopaque, gpa: std.mem.Allocator, id: FileId, path: []const u8) anyerror!?[]u8 {
        _ = id;
        const e: *Env = @ptrCast(@alignCast(ctx));
        const b = e.files.get(path) orelse return null;
        return try gpa.dupe(u8, b);
    }

    fn content(e: *Env) mentions.ContentSource {
        return .{ .ctx = e, .read = read };
    }

    /// Completions for `doc` with `|` marking the cursor.
    fn complete(e: *Env, view: *const ni.IndexView, path: []const u8, doc: []const u8, recents: []const FileId) ![]completion.Item {
        const a = e.arena.allocator();
        const cur = std.mem.indexOfScalar(u8, doc, '|').?;
        const text = try std.mem.concat(a, u8, &.{ doc[0..cur], doc[cur + 1 ..] });
        var prng: std.Random.DefaultPrng = .init(7);
        return completion.complete(a, view, .{ .text = text, .cursor = @intCast(cur), .path = path, .vault = &e.vault, .recents = recents, .content = e.content(), .random = prng.random() });
    }
};

fn labels(items: []const completion.Item, buf: [][]const u8) [][]const u8 {
    const n = @min(items.len, buf.len);
    for (items[0..n], buf[0..n]) |it, *b| b.* = it.label;
    return buf[0..n];
}

test "completion: [[ ranks title/alias/path with recents boost" {
    var e: Env = undefined;
    try e.init(.{});
    defer e.deinit();
    _ = try e.put("Projects/Alpha.md", "---\naliases: [First Project]\n---\n# Alpha\nThe alpha project.\n");
    const beta = try e.put("Projects/Beta.md", "# Beta\nbeta body\n");
    _ = try e.put("Archive/Alpha.md", "# Alpha\nold\n");
    _ = try e.put("Daily.md", "today\n");
    const view = try e.ix.reader();
    defer view.release();

    var items = try e.complete(view, "Daily.md", "see [[alp|", &.{});
    try testing.expect(items.len >= 2);
    try testing.expectEqualStrings("Alpha", items[0].label);
    // Duplicate stems get a path; the edit closes the link.
    try testing.expect(std.mem.endsWith(u8, items[0].edit.text, "Alpha]]"));
    try testing.expect(std.mem.indexOfScalar(u8, items[0].edit.text, '/') != null);
    try testing.expectEqual([2]u32{ 6, 9 }, items[0].edit.range);
    try testing.expectEqualStrings("The alpha project.", for (items) |it| {
        if (std.mem.eql(u8, it.detail, "Projects/Alpha.md")) break it.documentation;
    } else "");

    // An alias match inserts Target|Alias.
    items = try e.complete(view, "Daily.md", "[[first|]]", &.{});
    try testing.expectEqual(completion.Kind.alias, items[0].kind);
    try testing.expectEqualStrings("Projects/Alpha|First Project", items[0].edit.text);

    // Recents win for an empty query.
    items = try e.complete(view, "Daily.md", "[[|", &.{beta});
    try testing.expectEqualStrings("Beta", items[0].label);
    try testing.expectEqualStrings("Beta]]", items[0].edit.text);
    // The current note is not offered.
    for (items) |it| try testing.expect(!std.mem.eql(u8, it.detail, "Daily.md"));
}

test "completion: embeds list images first" {
    var e: Env = undefined;
    try e.init(.{});
    defer e.deinit();
    _ = try e.put("Diagram notes.md", "# x\n");
    try e.attach("assets/diagram.png");
    try e.attach("assets/diagram.pdf");
    const view = try e.ix.reader();
    defer view.release();
    const items = try e.complete(view, "n.md", "![[diag|", &.{});
    try testing.expectEqualStrings("diagram.png", items[0].label);
    try testing.expectEqualStrings("diagram.png]]", items[0].edit.text);
}

test "completion: heading and block lists; block id generated and appended" {
    var e: Env = undefined;
    try e.init(.{});
    defer e.deinit();
    _ = try e.put("Plan.md", "# Plan\n## Goals\nShip the thing\nby Friday.\n\n- first task ^t1\n- second task\n## Risks\n```\ncode\n```\n");
    const view = try e.ix.reader();
    defer view.release();

    var items = try e.complete(view, "Other.md", "[[Plan#|", &.{});
    var buf: [8][]const u8 = undefined;
    const hs = labels(items, &buf);
    try testing.expectEqual(@as(usize, 3), hs.len);
    try testing.expectEqualStrings("Plan", hs[0]);
    try testing.expectEqualStrings("Goals", hs[1]);
    try testing.expectEqualStrings("Goals]]", items[1].edit.text);
    items = try e.complete(view, "Other.md", "[[Plan#ris|]]", &.{});
    try testing.expectEqualStrings("Risks", items[0].edit.text);

    items = try e.complete(view, "Other.md", "[[Plan#^|", &.{});
    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expectEqualStrings("Ship the thing\nby Friday.", items[0].label);
    try testing.expectEqualStrings("first task ^t1", items[1].label);
    try testing.expectEqualStrings("t1]]", items[1].edit.text);
    try testing.expect(items[1].extra == null);
    // No id yet: a fresh one, appended to the block's last line.
    const ex = items[2].extra.?;
    try testing.expectEqualStrings("Plan.md", ex.path);
    const plan = e.files.get("Plan.md").?;
    try testing.expectEqualStrings("- second task", plan[std.mem.lastIndexOfScalar(u8, plan[0..ex.at], '\n').? + 1 .. ex.at]);
    try testing.expectEqual(@as(usize, 8), ex.text.len);
    try testing.expectEqualStrings(items[2].edit.text[0..6], ex.text[2..]);
    for (ex.text[2..]) |c| try testing.expect(std.ascii.isDigit(c) or std.ascii.isLower(c));
    // Blocks of this note come from the live text.
    items = try e.complete(view, "Plan.md", "para one\n\n[[#^|", &.{});
    try testing.expectEqualStrings("para one", items[0].label);
}

test "completion: tag completion respects boundaries" {
    var e: Env = undefined;
    try e.init(.{});
    defer e.deinit();
    _ = try e.put("a.md", "#project/alpha #project/beta #project/alpha\n");
    _ = try e.put("b.md", "#project/alpha #people\n");
    const view = try e.ix.reader();
    defer view.release();
    var items = try e.complete(view, "c.md", "x #proj|", &.{});
    try testing.expectEqualStrings("project", items[0].label);
    try testing.expectEqualStrings("project/alpha", items[1].label);
    try testing.expectEqual([2]u32{ 3, 7 }, items[0].edit.range);
    items = try e.complete(view, "c.md", "x#proj|", &.{});
    try testing.expectEqual(@as(usize, 0), items.len);
    items = try e.complete(view, "c.md", "#pe|", &.{});
    try testing.expectEqualStrings("people", items[0].label);
}

test "completion: frontmatter key and value completion" {
    var e: Env = undefined;
    try e.init(.{});
    defer e.deinit();
    _ = try e.put("a.md", "---\nstatus: done\ntags: [x]\n---\n");
    _ = try e.put("b.md", "---\nstatus: draft\n---\n");
    _ = try e.put("c.md", "---\nstatus: done\nstage: one\n---\n");
    const view = try e.ix.reader();
    defer view.release();
    var items = try e.complete(view, "d.md", "---\nsta|\n---\n", &.{});
    try testing.expectEqualStrings("status", items[0].label);
    try testing.expectEqualStrings("status: ", items[0].edit.text);
    try testing.expectEqualStrings("stage", items[1].label);
    items = try e.complete(view, "d.md", "---\nstatus: |\n---\n", &.{});
    try testing.expectEqualStrings("done", items[0].label);
    try testing.expectEqualStrings("2", items[0].detail);
    try testing.expectEqualStrings("draft", items[1].label);
    items = try e.complete(view, "d.md", "---\ntags:\n  - |\n---\n", &.{});
    try testing.expectEqualStrings("x", items[0].label);
}

test "hover: section slicing for heading and block" {
    var e: Env = undefined;
    try e.init(.{});
    defer e.deinit();
    _ = try e.put("Plan.md", "---\na: 1\n---\n# Plan\nintro\n## Goals\nship it\n### Sub\ndeep\n## Risks\nnone\n\nA block. ^b1\n");
    const view = try e.ix.reader();
    defer view.release();
    const a = e.arena.allocator();
    const doc = "x [[Plan#Goals]] y [[Plan#^b1]] z [[Plan]] [[Missing]] [[Plan#Nope]]";
    var p = (try hover.preview(a, view, &e.vault, "x.md", doc, 5, e.content(), 1 << 20)).?;
    try testing.expectEqualStrings("## Goals\nship it\n### Sub\ndeep", p.text);
    try testing.expectEqualStrings("Plan", p.title);
    p = (try hover.preview(a, view, &e.vault, "x.md", doc, 22, e.content(), 1 << 20)).?;
    try testing.expectEqualStrings("A block. ^b1", p.text);
    p = (try hover.preview(a, view, &e.vault, "x.md", doc, 37, e.content(), 1 << 20)).?;
    try testing.expect(std.mem.startsWith(u8, p.text, "# Plan\nintro"));
    p = (try hover.preview(a, view, &e.vault, "x.md", doc, 37, e.content(), 8)).?;
    try testing.expect(p.truncated);
    try testing.expect(try hover.preview(a, view, &e.vault, "x.md", doc, 47, e.content(), 1 << 20) == null);
    try testing.expect(try hover.preview(a, view, &e.vault, "x.md", doc, 60, e.content(), 1 << 20) == null);
    try testing.expect(try hover.preview(a, view, &e.vault, "x.md", doc, 1, e.content(), 1 << 20) == null);
}

test "nav: ctrl+click unresolved creates note in configured dir" {
    var e: Env = undefined;
    try e.init(.{ .new_note_dir = .fixed, .new_note_folder = "inbox/" });
    defer e.deinit();
    _ = try e.put("Plan.md", "# Plan\n## Goals\nship\n");
    const view = try e.ix.reader();
    defer view.release();
    const a = e.arena.allocator();
    const doc = "[[Plan#Goals]] [[New idea]] [[deep/Thing]] [x](sub/y.md) [[pic.png]]";
    const t1 = (try link_nav.definition(a, view, &e.vault, "notes/x.md", doc, 3)).?;
    try testing.expectEqualStrings("Plan.md", t1.open.path);
    try testing.expectEqual([2]u32{ 7, 15 }, t1.open.range.?);
    try testing.expectEqualStrings("inbox/New idea.md", (try link_nav.definition(a, view, &e.vault, "notes/x.md", doc, 17)).?.create.path);
    try testing.expectEqualStrings("deep/Thing.md", (try link_nav.definition(a, view, &e.vault, "notes/x.md", doc, 30)).?.create.path);
    try testing.expectEqualStrings("notes/sub/y.md", (try link_nav.definition(a, view, &e.vault, "notes/x.md", doc, 45)).?.create.path);
    try testing.expect(try link_nav.definition(a, view, &e.vault, "notes/x.md", doc, 62) == null);
    e.vault.config.new_note_dir = .same_as_current;
    try testing.expectEqualStrings("notes/New idea.md", (try link_nav.newNotePath(a, &e.vault.config, "notes/x.md", "New idea", .wiki)).?);
}

test "diagnostics: unresolved and ambiguous flagged with quick fixes" {
    var e: Env = undefined;
    try e.init(.{});
    defer e.deinit();
    _ = try e.put("a/Dup.md", "# Dup\n");
    _ = try e.put("b/Dup.md", "# Dup\n");
    _ = try e.put("Plan.md", "# Plan\n## Goals\n");
    const view = try e.ix.reader();
    defer view.release();
    const a = e.arena.allocator();
    const doc = "[[Dup]] [[Nowhere]] [[Plan#Goals]] [[Plan#Missing]] [[Plan#^nope]] [[a/Dup]]";
    const ds = try diagnostics.diagnose(a, view, &e.vault, "x.md", doc);
    try testing.expectEqual(@as(usize, 4), ds.len);
    try testing.expectEqual(diagnostics.Code.ambiguous, ds[0].code);
    try testing.expectEqual([2]u32{ 2, 5 }, ds[0].fix.?.use_path.range);
    try testing.expect(std.mem.endsWith(u8, ds[0].fix.?.use_path.text, "/Dup"));
    try testing.expectEqual(diagnostics.Code.unresolved, ds[1].code);
    try testing.expectEqualStrings("Nowhere.md", ds[1].fix.?.create_note);
    try testing.expectEqualStrings("No note named \"Nowhere\"", ds[1].message);
    try testing.expectEqual(diagnostics.Code.unknown_heading, ds[2].code);
    try testing.expectEqualStrings("No heading \"Missing\" in Plan", ds[2].message);
    try testing.expectEqual(diagnostics.Code.unknown_block, ds[3].code);
}
