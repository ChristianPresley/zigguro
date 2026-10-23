const std = @import("std");
const rename = @import("rename.zig");
const heading_rename = @import("heading_rename.zig");
const ni = @import("../index/note_index.zig");
const mentions = @import("../index/mentions.zig");
const vault_mod = @import("../vault/vault.zig");
const testdata = @import("../testing/testdata.zig");

const testing = std.testing;
const FileId = @import("../vault/note.zig").FileId;
const NoteIndex = ni.NoteIndex;

const whole_root: vault_mod.Vault = .{ .id = .of(0), .root = .of(0), .rel_dir = "", .config = .{} };

fn fid(i: u32) FileId {
    return .{ .index = i, .gen = 0 };
}

/// An in-memory vault fed to an index.
const Fixture = struct {
    ix: *NoteIndex,
    arena: std.heap.ArenaAllocator,
    paths: std.ArrayList([]const u8) = .empty,
    bytes: std.ArrayList([]const u8) = .empty,

    fn init(files: []const [2][]const u8) !Fixture {
        var f: Fixture = .{ .ix = try NoteIndex.init(testing.allocator, testing.io, &.{whole_root}), .arena = .init(testing.allocator) };
        for (files) |x| try f.add(x[0], x[1]);
        try f.ix.commit();
        return f;
    }

    fn deinit(f: *Fixture) void {
        f.ix.deinit();
        f.paths.deinit(testing.allocator);
        f.bytes.deinit(testing.allocator);
        f.arena.deinit();
    }

    fn add(f: *Fixture, path: []const u8, bytes: []const u8) !void {
        const a = f.arena.allocator();
        const id = fid(@intCast(f.paths.items.len));
        try f.paths.append(testing.allocator, try a.dupe(u8, path));
        try f.bytes.append(testing.allocator, try a.dupe(u8, bytes));
        if (vault_mod.isMarkdownName(path)) try f.ix.indexNote(id, .of(0), path, bytes) else try f.ix.setAttachment(id, .of(0), path);
    }

    fn idOf(f: *Fixture, path: []const u8) FileId {
        for (f.paths.items, 0..) |p, i| if (std.mem.eql(u8, p, path)) return fid(@intCast(i));
        std.debug.panic("no note {s}", .{path});
    }

    fn source(f: *Fixture) mentions.ContentSource {
        return .{ .ctx = f, .read = read };
    }

    fn read(ctx: *anyopaque, gpa: std.mem.Allocator, id: FileId, path: []const u8) anyerror!?[]u8 {
        _ = path;
        const f: *Fixture = @ptrCast(@alignCast(ctx));
        return try gpa.dupe(u8, f.bytes.items[id.index]);
    }

    fn plan(f: *Fixture, moves: []const rename.Move) !rename.Plan {
        const v = try f.ix.reader();
        defer v.release();
        return rename.planMoves(testing.allocator, v, &whole_root, moves);
    }

    /// Applies `p`'s edits and moves to the fixture's files and index.
    fn apply(f: *Fixture, p: *const rename.Plan) !void {
        const a = f.arena.allocator();
        var i: usize = 0;
        while (i < p.edits.len) {
            var j = i + 1;
            while (j < p.edits.len and p.edits[j].note.eql(p.edits[i].note)) j += 1;
            const k = p.edits[i].note.index;
            f.bytes.items[k] = try rename.applyEdits(a, f.bytes.items[k], p.edits[i..j]);
            i = j;
        }
        for (p.moved) |m| f.paths.items[m.id.index] = try a.dupe(u8, m.to);
        for (f.paths.items, f.bytes.items, 0..) |path, b, k| {
            if (vault_mod.isMarkdownName(path)) try f.ix.indexNote(fid(@intCast(k)), .of(0), path, b) else try f.ix.setAttachment(fid(@intCast(k)), .of(0), path);
        }
        try f.ix.commit();
    }

    fn text(f: *Fixture, path: []const u8) []const u8 {
        return f.bytes.items[f.idOf(path).index];
    }
};

/// Every link that resolved to a note before resolves to it after.
fn expectSameTargets(before: *const ni.IndexView, after: *const ni.IndexView) !usize {
    var checked: usize = 0;
    for (before.order) |id| {
        const a = before.outgoing(id);
        const b = after.outgoing(id);
        try testing.expectEqual(a.len, b.len);
        for (a, b, 0..) |x, y, i| {
            if (x.kind != .note and x.kind != .attachment) continue;
            errdefer std.debug.print("{s} link {d} '{s}' -> '{s}' now {t}\n", .{ after.pathOf(id).?, i, before.note(id).?.links[i].target, after.note(id).?.links[i].target, y.kind });
            try testing.expectEqual(x.kind, y.kind);
            try testing.expect(x.id.eql(y.id));
            checked += 1;
        }
    }
    return checked;
}

test "rename: table of link forms" {
    const home =
        \\- [[Alpha]]
        \\- [[Projects/Alpha]]
        \\- [[Alpha.md]]
        \\- [[Alpha|shown]]
        \\- [[Alpha#Intro]]
        \\- [[Alpha#^b1]]
        \\- ![[Alpha]]
        \\- [md](Projects/Alpha.md)
        \\- [bare](Projects/Alpha)
        \\- [sub](Projects/Alpha.md#Intro)
        \\- [enc](Projects/Alph%61.md)
        \\- [ang](<Projects/Alpha.md>)
        \\- [abs](/Projects/Alpha.md)
        \\- [[Other]] stays
        \\
    ;
    var f = try Fixture.init(&.{
        .{ "Home.md", home },
        .{ "Projects/Alpha.md", "# Intro\ntext ^b1\n" },
        .{ "Other.md", "x" },
    });
    defer f.deinit();
    var p = try f.plan(&.{.{ .from = "Projects/Alpha.md", .to = "Done/My Omega.md" }});
    defer p.deinit();
    try testing.expectEqual(@as(usize, 13), p.edits.len);
    try f.apply(&p);
    try testing.expectEqualStrings(
        \\- [[My Omega]]
        \\- [[Done/My Omega]]
        \\- [[My Omega.md]]
        \\- [[My Omega|shown]]
        \\- [[My Omega#Intro]]
        \\- [[My Omega#^b1]]
        \\- ![[My Omega]]
        \\- [md](<Done/My Omega.md>)
        \\- [bare](<Done/My Omega>)
        \\- [sub](Done/My%20Omega.md#Intro)
        \\- [enc](Done/My%20Omega.md)
        \\- [ang](<Done/My Omega.md>)
        \\- [abs](</Done/My Omega.md>)
        \\- [[Other]] stays
        \\
    , f.text("Home.md"));
    const v = try f.ix.reader();
    defer v.release();
    for (v.outgoing(f.idOf("Home.md"))[0..13]) |r| try testing.expect(r.id.eql(f.idOf("Done/My Omega.md")));
}

test "rename: shortest form becomes path when move creates ambiguity" {
    var f = try Fixture.init(&.{
        .{ "Home.md", "[[Beta]] and [[Alpha]] and [[c/Gamma]]\n" },
        .{ "a/Alpha.md", "" },
        .{ "b/Beta.md", "" },
        .{ "c/Gamma.md", "" },
    });
    defer f.deinit();
    const before = try f.ix.reader();
    defer before.release();
    var p = try f.plan(&.{.{ .from = "b/Beta.md", .to = "c/Alpha.md" }});
    defer p.deinit();
    try f.apply(&p);
    try testing.expectEqualStrings("[[c/Alpha]] and [[a/Alpha]] and [[c/Gamma]]\n", f.text("Home.md"));
    const after = try f.ix.reader();
    defer after.release();
    _ = try expectSameTargets(before, after);
}

test "rename: moving the source note fixes its relative markdown links" {
    var f = try Fixture.init(&.{
        .{ "notes/src.md", "[x](../other/t.md) [y](t2.md) [[other/t]] [[t2]]\n" },
        .{ "other/t.md", "" },
        .{ "notes/t2.md", "" },
    });
    defer f.deinit();
    const before = try f.ix.reader();
    defer before.release();
    var p = try f.plan(&.{.{ .from = "notes/src.md", .to = "deep/er/src.md" }});
    defer p.deinit();
    try f.apply(&p);
    try testing.expectEqualStrings("[x](../../other/t.md) [y](../../notes/t2.md) [[other/t]] [[t2]]\n", f.text("deep/er/src.md"));
    const after = try f.ix.reader();
    defer after.release();
    _ = try expectSameTargets(before, after);
}

test "rename: folder move updates contained notes and attachments" {
    var f = try Fixture.init(&.{
        .{ "Home.md", "[[Projects/Alpha]] ![[Projects/img.png]] ![[img.png]] [r](Projects/sub/Deep.md) [[Deep]]\n" },
        .{ "Projects/Alpha.md", "[[sub/Deep]] [up](../Home.md)\n" },
        .{ "Projects/img.png", "" },
        .{ "Projects/sub/Deep.md", "[a](../Alpha.md)\n" },
    });
    defer f.deinit();
    const before = try f.ix.reader();
    defer before.release();
    var p = try f.plan(&.{.{ .from = "Projects/", .to = "Archive/Projects" }});
    defer p.deinit();
    try testing.expectEqual(@as(usize, 3), p.moved.len);
    try f.apply(&p);
    try testing.expectEqualStrings("[[Archive/Projects/Alpha]] ![[Archive/Projects/img.png]] ![[img.png]] [r](Archive/Projects/sub/Deep.md) [[Deep]]\n", f.text("Home.md"));
    // `sub/Deep` is relative to the note and still resolves.
    try testing.expectEqualStrings("[[sub/Deep]] [up](../../Home.md)\n", f.text("Archive/Projects/Alpha.md"));
    // Relative links between moved notes still work unchanged.
    try testing.expectEqualStrings("[a](../Alpha.md)\n", f.text("Archive/Projects/sub/Deep.md"));
    const after = try f.ix.reader();
    defer after.release();
    _ = try expectSameTargets(before, after);
}

test "rename: heading rename updates nested subpaths only" {
    var f = try Fixture.init(&.{
        .{ "T.md", "# A\n## B\nsee [[#B]] and [[#A]]\n" },
        .{ "S.md", "[[T#A#B]] [[T#B|b]] [[T#A]] [[T# A # B ]] [m](T.md#B) [[Other#B]]\n" },
        .{ "Other.md", "## B\n" },
    });
    defer f.deinit();
    const v = try f.ix.reader();
    defer v.release();
    var p = try heading_rename.planHeadingRename(testing.allocator, v, f.source(), f.idOf("T.md"), &.{ "A", "B" }, &.{ "A", "New B" });
    defer p.deinit();
    try f.apply(&p);
    try testing.expectEqualStrings("[[T#A#New B]] [[T#New B|b]] [[T#A]] [[T# A # New B ]] [m](T.md#New%20B) [[Other#B]]\n", f.text("S.md"));
    try testing.expectEqualStrings("# A\n## B\nsee [[#New B]] and [[#A]]\n", f.text("T.md"));
}

const FakePort = struct {
    label: []const u8 = "",
    tx: u64 = 0,
    files: usize = 0,
    edits: usize = 0,
    auto: bool = false,
    buf: [128]u8 = undefined,

    fn submit(ctx: *anyopaque, label: []const u8, tx: u64, files: []const rename.PlanFile, auto: bool) anyerror!u64 {
        const p: *FakePort = @ptrCast(@alignCast(ctx));
        @memcpy(p.buf[0..label.len], label);
        p.label = p.buf[0..label.len];
        p.tx = tx;
        p.files = files.len;
        for (files) |fl| p.edits += fl.edits.len;
        p.auto = auto;
        return 77;
    }
};

test "rename: changeset provenance links to TxId" {
    var f = try Fixture.init(&.{
        .{ "a.md", "[[T]] [[T]]\n" },
        .{ "b.md", "[[T]]\n" },
        .{ "T.md", "" },
    });
    defer f.deinit();
    const v = try f.ix.reader();
    defer v.release();
    var p = try rename.planMoves(testing.allocator, v, &whole_root, &.{.{ .from = "T.md", .to = "U.md" }});
    defer p.deinit();
    var port: FakePort = .{};
    const id = try rename.submit(testing.allocator, .{ .ctx = &port, .submit = FakePort.submit }, v, &p, "T", 42, true);
    try testing.expectEqual(@as(?u64, 77), id);
    try testing.expectEqual(@as(u64, 42), port.tx);
    try testing.expectEqual(@as(usize, 2), port.files);
    try testing.expectEqual(@as(usize, 3), port.edits);
    try testing.expect(port.auto);
    try testing.expectEqualStrings("Update 3 links after renaming T", port.label);
    // Nothing to change: no changeset.
    var empty = try rename.planMoves(testing.allocator, v, &whole_root, &.{.{ .from = "nope.md", .to = "x.md" }});
    defer empty.deinit();
    try testing.expectEqual(@as(?u64, null), try rename.submit(testing.allocator, .{ .ctx = &port, .submit = FakePort.submit }, v, &empty, "nope", 1, false));
}

test "rename: compat vault scenarios leave no link broken" {
    const io = testing.io;
    var dir = try testdata.openDir("testdata/vault_compat");
    defer dir.close(io);
    var walker = try dir.walk(testing.allocator);
    defer walker.deinit();
    var files: std.ArrayList([2][]const u8) = .empty;
    defer files.deinit(testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    while (try walker.next(io)) |e| {
        if (e.kind != .file or std.mem.eql(u8, e.path, "expected.txt")) continue;
        const p = try a.dupe(u8, e.path);
        try files.append(testing.allocator, .{ p, try dir.readFileAlloc(io, p, a, .limited(1 << 20)) });
    }
    std.mem.sort([2][]const u8, files.items, {}, struct {
        fn lt(_: void, x: [2][]const u8, y: [2][]const u8) bool {
            return std.mem.lessThan(u8, x[0], y[0]);
        }
    }.lt);
    const scenarios = [_][]const rename.Move{
        &.{.{ .from = "Projects/Alpha.md", .to = "Archive/Projects/Alpha Two.md" }},
        &.{.{ .from = "Projects", .to = "Work/Projects" }},
        &.{.{ .from = "Home.md", .to = "Inbox/Home.md" }},
        &.{.{ .from = "attachments", .to = "media" }},
        &.{ .{ .from = "Topics", .to = "T" }, .{ .from = "People/Jane Doe.md", .to = "Jane.md" } },
    };
    var total: usize = 0;
    for (scenarios) |moves| {
        var f = try Fixture.init(files.items);
        defer f.deinit();
        const before = try f.ix.reader();
        defer before.release();
        var p = try f.plan(moves);
        defer p.deinit();
        try testing.expect(p.moved.len > 0);
        try f.apply(&p);
        const after = try f.ix.reader();
        defer after.release();
        total += try expectSameTargets(before, after);
        // No link became unresolved.
        try testing.expectEqual(before.unresolved().len, after.unresolved().len);
    }
    try testing.expect(total > 100);
}
