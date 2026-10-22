//! Object parser tests over the real fixture repositories, plus the
//! `git-object` fuzz target.

const std = @import("std");
const oid_mod = @import("oid.zig");
const object = @import("object.zig");
const commit = @import("commit.zig");
const tree = @import("tree.zig");
const tag = @import("tag.zig");
const Odb = @import("odb.zig").Odb;
const testdata = @import("testdata.zig");
const ObjectFormat = oid_mod.ObjectFormat;

test "commit: parse/serialize roundtrip of real commits incl gpgsig, encoding" {
    const t = std.testing;
    const gpa = t.allocator;
    for ([_]ObjectFormat{ .sha1, .sha256 }) |fmt| {
        var fx = try testdata.Fixture.open(gpa, t.io, fmt);
        defer fx.close();
        const o = try Odb.open(gpa, t.io, fx.objects, fmt, .{});
        defer o.close();
        var counts = [_]usize{0} ** 5;
        var saw_sig = false;
        var it = fx.expected.iterator();
        while (it.next()) |e| {
            var obj = try o.read(gpa, e.key_ptr.*);
            defer obj.deinit(gpa);
            var arena_state: std.heap.ArenaAllocator = .init(gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            var aw: std.Io.Writer.Allocating = .init(gpa);
            defer aw.deinit();
            switch (obj.type) {
                .commit => {
                    const c = try commit.parseCommit(arena, fmt, obj.data);
                    try commit.serializeCommit(&c, &aw.writer);
                    try t.expectEqualStrings(obj.data, aw.written());
                    if (c.header("gpgsig") != null) {
                        saw_sig = true;
                        try t.expectEqualStrings("ISO-8859-1", c.encoding.?);
                        try t.expectEqualStrings("kxyzzy", c.header("change-id").?);
                    }
                },
                .tag => {
                    const tg = try tag.parseTag(arena, fmt, obj.data);
                    try tag.serializeTag(&tg, &aw.writer);
                    try t.expectEqualStrings(obj.data, aw.written());
                },
                .tree => {
                    var entries: std.ArrayList(tree.TreeEntry) = .empty;
                    var ti = tree.parseTree(fmt, obj.data);
                    while (try ti.next()) |te| try entries.append(arena, te);
                    try tree.serializeTree(entries.items, &aw.writer);
                    try t.expectEqualSlices(u8, obj.data, aw.written());
                },
                .blob => {},
            }
            counts[@intFromEnum(obj.type)] += 1;
        }
        try t.expect(saw_sig);
        try t.expect(counts[@intFromEnum(object.ObjectType.commit)] >= 30);
        try t.expectEqual(@as(usize, 1), counts[@intFromEnum(object.ObjectType.tag)]);
    }
}

test "fuzz: git-object" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            const gpa = std.testing.allocator;
            var buf: [2048]u8 = undefined;
            const input = buf[0..s.slice(&buf)];
            var arena_state: std.heap.ArenaAllocator = .init(gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            var aw: std.Io.Writer.Allocating = .init(gpa);
            defer aw.deinit();
            for ([_]ObjectFormat{ .sha1, .sha256 }) |fmt| {
                if (commit.parseCommit(arena, fmt, input)) |c| {
                    aw.clearRetainingCapacity();
                    try commit.serializeCommit(&c, &aw.writer);
                    try std.testing.expectEqualSlices(u8, input, aw.written());
                } else |_| {}
                if (tag.parseTag(arena, fmt, input)) |tg| {
                    aw.clearRetainingCapacity();
                    try tag.serializeTag(&tg, &aw.writer);
                    try std.testing.expectEqualSlices(u8, input, aw.written());
                } else |_| {}
                var ti = tree.parseTree(fmt, input);
                while (ti.next() catch null) |_| {}
                _ = commit.signedPayload(arena, fmt, input) catch {};
                _ = tag.signatureOffset(input);
            }
            _ = object.parseHeader(input) catch {};
        }
    }.one, .{ .corpus = @import("zg_core").testkit.fuzz.corpus(@import("zg_corpus"), "git-object") });
}
