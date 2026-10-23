//! The version timeline: the union of providers, collapsing, loading,
//! the word diff, and restore as a changeset.

const std = @import("std");
const builtin = @import("builtin");
const versions = @import("versions.zig");
const words = @import("words.zig");
const doc_session = @import("doc_session.zig");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;
const Version = versions.Version;

/// A provider over a fixed list, with contents by id.
const Fake = struct {
    kind: versions.SourceKind,
    items: []const struct { id: []const u8, at: i64, text: []const u8 },
    fail: bool = false,
    marked: u32 = 0,

    fn list(ctx: *anyopaque, a: std.mem.Allocator, path: []const u8) anyerror![]Version {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        if (f.fail) return error.Unavailable;
        _ = path;
        const out = try a.alloc(Version, f.items.len);
        for (f.items, out) |it, *v| v.* = .{ .id = it.id, .source = f.kind, .at_ms = it.at, .label = it.id, .author = .{ .user = "ann" }, .words = versions.countWords(it.text) };
        return out;
    }

    fn load(ctx: *anyopaque, a: std.mem.Allocator, id: []const u8) anyerror![]const u8 {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        for (f.items) |it| if (std.mem.eql(u8, it.id, id)) return a.dupe(u8, it.text);
        return error.NotFound;
    }

    fn mark(ctx: *anyopaque, _: std.mem.Allocator, _: []const u8, label: []const u8) anyerror!Version {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        f.marked += 1;
        return .{ .id = "mark", .source = .save, .at_ms = 9_000_000, .label = label, .author = .{ .user = "ann" } };
    }

    fn provider(f: *Fake) versions.Provider {
        return .{ .ctx = f, .list = list, .load = load, .mark = if (f.kind == .scm_snapshot) mark else null };
    }
};

test "versions union and collapse" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var cps: Fake = .{ .kind = .checkpoint, .items = &.{
        .{ .id = "cp1", .at = 100_000, .text = "one" },
        .{ .id = "cp2", .at = 500_000, .text = "one two" },
    } };
    var scm: Fake = .{ .kind = .scm_snapshot, .items = &.{
        .{ .id = "s1", .at = 200_000, .text = "a" },
        .{ .id = "s2", .at = 230_000, .text = "a b" },
        .{ .id = "s3", .at = 250_000, .text = "a b c" },
        .{ .id = "s4", .at = 400_000, .text = "a b c d" },
    } };
    var broken: Fake = .{ .kind = .save, .items = &.{}, .fail = true };
    const providers = [_]versions.Provider{ cps.provider(), scm.provider(), broken.provider() };
    const vs = try versions.listVersions(a, "notes/plan.md", &providers);
    var ids: std.ArrayList(u8) = .empty;
    for (vs) |v| try ids.print(a, "{s} ", .{v.id});
    // Newest first; s1 and s2 collapse into s3 (each less than a minute
    // before the next); the failing provider is left out.
    try testing.expectEqualStrings("cp2 s4 s3 cp1 ", ids.items);
    try testing.expectEqual(@as(u32, 3), vs[2].words);
    try testing.expectEqualStrings("a b c", try versions.loadVersion(a, &providers, vs[2]));
    try testing.expectEqualStrings("one two", try versions.loadVersion(a, &providers, vs[0]));
    // Save points go through the provider that can mark.
    const m = (try versions.markVersion(a, &providers, "notes/plan.md", "Draft 1")).?;
    try testing.expectEqualStrings("Draft 1", m.label);
    try testing.expectEqual(@as(u8, 1), m.provider);
    try testing.expectEqual(@as(u32, 1), scm.marked);
}

fn apply(a: std.mem.Allocator, old: []const u8, hs: []const words.Hunk) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    for (hs) |h| {
        try testing.expect(h.start >= at);
        try out.appendSlice(a, old[at..h.start]);
        try out.appendSlice(a, h.new);
        at = h.end;
    }
    try out.appendSlice(a, old[at..]);
    return out.items;
}

test "word diff round-trips and stays small" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][2][]const u8{
        .{ "", "" },
        .{ "", "new text\n" },
        .{ "old text\n", "" },
        .{ "a\nb\nc\n", "a\nb\nc\n" },
        .{ "one two three\nfour five\n", "one 2 three\nfour five\nsix\n" },
        .{ "# T\n\npara one\n\npara two\n\npara three\n", "# T\n\npara two\n\npara one changed\n\npara three\n" },
        .{ "no newline at end", "no newline at the end" },
    };
    for (cases) |c| {
        const hs = try versions.diffWords(a, c[0], c[1]);
        try testing.expectEqualStrings(c[1], try apply(a, c[0], hs));
    }
    const hs = try versions.diffWords(a, "one two three\nfour five\n", "one 2 three\nfour five\n");
    try testing.expectEqual(@as(usize, 1), hs.len);
    try testing.expectEqualStrings("2", hs[0].new);
    try testing.expectEqual(@as(u32, 4), hs[0].start);
}

const Changes = struct {
    last: ?doc_session.DocChange = null,
    fn propose(ctx: *anyopaque, c: doc_session.DocChange) anyerror!u64 {
        const s: *Changes = @ptrCast(@alignCast(ctx));
        s.last = c;
        return 77;
    }
};

test "restore creates a changeset" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var ch: Changes = .{};
    const port: doc_session.ChangePort = .{ .ctx = &ch, .propose = Changes.propose };
    const current = "# Plan\n\nWe launch in May.\n";
    const old = "# Plan\n\nWe launch in spring.\n";
    try testing.expectEqual(@as(?u64, 77), try versions.restore(a, port, "notes/plan.md", current, 3, old, "cp1"));
    const c = ch.last.?;
    try testing.expectEqualStrings("Restore cp1", c.summary);
    try testing.expectEqual(@as(u64, 3), c.base_version);
    try testing.expectEqualStrings(old, try apply(a, current, c.hunks));
    // Nothing to restore when they are the same.
    try testing.expectEqual(@as(?u64, null), try versions.restore(a, port, "notes/plan.md", current, 3, current, "same"));
}

test "diff of a 50k-word document" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var old: std.ArrayList(u8) = .empty;
    var new: std.ArrayList(u8) = .empty;
    var n: usize = 0;
    var p: usize = 0;
    while (n < 50_000) : (p += 1) {
        const line = try std.fmt.allocPrint(a, "Paragraph {d} says the quick brown fox jumps over the lazy dog again and again.\n\n", .{p});
        try old.appendSlice(a, line);
        // Every 25th paragraph changes a word; every 40th is new.
        if (p % 25 == 0) try new.print(a, "Paragraph {d} says the quick red fox jumps over the lazy dog again and again.\n\n", .{p}) else try new.appendSlice(a, line);
        if (p % 40 == 0) try new.print(a, "An added paragraph {d}.\n\n", .{p});
        n += 16;
    }
    const t0 = std.Io.Timestamp.now(io, .awake);
    const hs = try versions.diffWords(a, old.items, new.items);
    const ms = t0.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();
    try testing.expectEqualStrings(new.items, try apply(a, old.items, hs));
    try testing.expect(hs.len >= p / 25);
    if (builtin.mode != .Debug) try testing.expect(ms < 50);
}
