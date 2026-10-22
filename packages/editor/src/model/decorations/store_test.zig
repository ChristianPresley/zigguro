//! Tests for the decoration store: queries and edit tracking against a
//! naive list, stick-mode semantics, owners and version mapping.

const std = @import("std");
const store_mod = @import("store.zig");
const pt = @import("../buffer/piece_tree.zig");
const ChangeSet = @import("../edit/change_set.zig").ChangeSet;
const Document = @import("../document.zig").Document;

const testing = std.testing;
const Range = pt.Range;
const DecorationStore = store_mod.DecorationStore;
const Decoration = store_mod.Decoration;
const DecorationId = store_mod.DecorationId;
const DecoRef = store_mod.DecoRef;
const KindMask = store_mod.KindMask;
const StickMode = store_mod.StickMode;

fn edit(doc: *Document, edits: []const pt.Edit) !void {
    var cs = try ChangeSet.fromEdits(testing.allocator, doc.len(), edits);
    defer cs.deinit();
    try doc.applyChangeSet(&cs, .{ .user = 0 });
}

fn style(n: u32) store_mod.StyleRef {
    return @enumFromInt(n);
}

test "decorations: stick modes at edges, inside and over deletions" {
    const R = Range;
    const Case = struct { stick: StickMode, range: R, a: u64, b: u64, n: u64, want: ?R };
    const cases = [_]Case{
        // Insert at the start.
        .{ .stick = .shrink, .range = .{ .start = 5, .end = 10 }, .a = 5, .b = 5, .n = 2, .want = .{ .start = 7, .end = 12 } },
        .{ .stick = .grow_both, .range = .{ .start = 5, .end = 10 }, .a = 5, .b = 5, .n = 2, .want = .{ .start = 5, .end = 12 } },
        .{ .stick = .grow_start, .range = .{ .start = 5, .end = 10 }, .a = 5, .b = 5, .n = 2, .want = .{ .start = 5, .end = 12 } },
        .{ .stick = .grow_end, .range = .{ .start = 5, .end = 10 }, .a = 5, .b = 5, .n = 2, .want = .{ .start = 7, .end = 12 } },
        // Insert at the end.
        .{ .stick = .shrink, .range = .{ .start = 5, .end = 10 }, .a = 10, .b = 10, .n = 2, .want = .{ .start = 5, .end = 10 } },
        .{ .stick = .grow_both, .range = .{ .start = 5, .end = 10 }, .a = 10, .b = 10, .n = 2, .want = .{ .start = 5, .end = 12 } },
        .{ .stick = .grow_start, .range = .{ .start = 5, .end = 10 }, .a = 10, .b = 10, .n = 2, .want = .{ .start = 5, .end = 10 } },
        .{ .stick = .grow_end, .range = .{ .start = 5, .end = 10 }, .a = 10, .b = 10, .n = 2, .want = .{ .start = 5, .end = 12 } },
        // Insert inside, delete inside, delete across the start.
        .{ .stick = .shrink, .range = .{ .start = 5, .end = 10 }, .a = 7, .b = 7, .n = 3, .want = .{ .start = 5, .end = 13 } },
        .{ .stick = .shrink, .range = .{ .start = 5, .end = 10 }, .a = 6, .b = 8, .n = 0, .want = .{ .start = 5, .end = 8 } },
        .{ .stick = .shrink, .range = .{ .start = 5, .end = 10 }, .a = 3, .b = 7, .n = 0, .want = .{ .start = 3, .end = 6 } },
        // Deleting all of a shrinking range removes it; others collapse.
        .{ .stick = .shrink, .range = .{ .start = 5, .end = 10 }, .a = 4, .b = 11, .n = 0, .want = null },
        .{ .stick = .shrink, .range = .{ .start = 5, .end = 10 }, .a = 5, .b = 10, .n = 4, .want = null },
        .{ .stick = .grow_both, .range = .{ .start = 5, .end = 10 }, .a = 4, .b = 11, .n = 0, .want = .{ .start = 4, .end = 4 } },
        .{ .stick = .grow_both, .range = .{ .start = 5, .end = 10 }, .a = 5, .b = 10, .n = 4, .want = .{ .start = 5, .end = 9 } },
        // Zero-width ranges and points.
        .{ .stick = .shrink, .range = .{ .start = 5, .end = 5 }, .a = 5, .b = 5, .n = 2, .want = .{ .start = 7, .end = 7 } },
        .{ .stick = .point_left, .range = .{ .start = 5, .end = 5 }, .a = 5, .b = 5, .n = 2, .want = .{ .start = 5, .end = 5 } },
        .{ .stick = .point_right, .range = .{ .start = 5, .end = 5 }, .a = 5, .b = 5, .n = 2, .want = .{ .start = 7, .end = 7 } },
        .{ .stick = .point_right, .range = .{ .start = 5, .end = 5 }, .a = 3, .b = 8, .n = 1, .want = .{ .start = 4, .end = 4 } },
        // Before and after the edit.
        .{ .stick = .shrink, .range = .{ .start = 1, .end = 3 }, .a = 4, .b = 6, .n = 9, .want = .{ .start = 1, .end = 3 } },
        .{ .stick = .shrink, .range = .{ .start = 8, .end = 9 }, .a = 4, .b = 6, .n = 9, .want = .{ .start = 15, .end = 16 } },
    };
    for (cases, 0..) |c, i| {
        const got = store_mod.mapRange(c.range, c.stick, c.a, c.b, c.n);
        testing.expectEqual(c.want, got) catch |e| {
            std.debug.print("case {d}\n", .{i});
            return e;
        };
    }
}

const Naive = struct {
    id: DecorationId,
    range: Range,
    stick: StickMode,
    z: i16,
    owner: u32,
    kind: store_mod.KindTag,
};

fn naiveQuery(gpa: std.mem.Allocator, items: []const Naive, r: Range, filter: KindMask) ![]Naive {
    var out: std.ArrayList(Naive) = .empty;
    for (items) |it| if (it.range.start <= r.end and it.range.end >= r.start and filter.contains(it.kind)) try out.append(gpa, it);
    std.sort.pdq(Naive, out.items, {}, struct {
        fn lt(_: void, a: Naive, b: Naive) bool {
            if (a.range.start != b.range.start) return a.range.start < b.range.start;
            if (a.z != b.z) return a.z < b.z;
            if (a.owner != b.owner) return a.owner < b.owner;
            return @intFromEnum(a.id) < @intFromEnum(b.id);
        }
    }.lt);
    return out.toOwnedSlice(gpa);
}

fn Source(comptime T: type) type {
    return struct {
        inner: T,
        fn pick(s: *@This(), n: u64) u64 {
            if (n <= 1) return 0;
            if (T == std.Random) return s.inner.uintLessThan(u64, n);
            return s.inner.index(n);
        }
        fn uintLessThan(s: *@This(), comptime I: type, n: I) I {
            return @intCast(s.pick(n));
        }
        fn uintAtMost(s: *@This(), comptime I: type, n: I) I {
            return @intCast(s.pick(n + 1));
        }
        fn intRangeAtMost(s: *@This(), comptime I: type, lo: I, hi: I) I {
            const span: u64 = @intCast(@as(i128, hi) - lo + 1);
            return @intCast(@as(i128, lo) + s.pick(span));
        }
        fn boolean(s: *@This()) bool {
            return s.pick(2) == 1;
        }
    };
}

/// Random adds, removes, multi-replace edits and queries, checked
/// against a naive list.
fn decoFuzz(r: anytype, steps: usize) !void {
    const gpa = testing.allocator;
    const doc = try Document.initBytes(gpa, @enumFromInt(1), "x" ** 400);
    defer doc.deinit();
    var s: DecorationStore = .init(gpa, doc);
    defer s.deinit();
    _ = try doc.subscribe(s.listener());
    const owners = [_]store_mod.OwnerId{ try s.registerOwner("a", 0), try s.registerOwner("b", 5) };
    var naive: std.ArrayList(Naive) = .empty;
    defer naive.deinit(gpa);
    const sticks = std.enums.values(StickMode);
    const pieces = [_][]const u8{ "", "a", "bcd", "\n", "efghijkl" };
    for (0..steps) |step| {
        const len = doc.len();
        switch (r.uintLessThan(u64, 10)) {
            0...3 => {
                const a = r.uintAtMost(u64, len);
                const b = @min(len, a + r.uintLessThan(u64, 12));
                const stick = sticks[r.uintLessThan(usize, sticks.len)];
                const oi = r.uintLessThan(u32, 2);
                const kind: store_mod.Kind = if (r.boolean()) .{ .highlight = style(1) } else .{ .underline = .{ .style = style(2) } };
                const z: i16 = if (r.boolean()) 0 else r.intRangeAtMost(i16, -2, 2);
                const id = try s.add(.{ .range = .{ .start = a, .end = b }, .owner = owners[oi], .stick = stick, .kind = kind, .z = z });
                const eff_z = if (z == 0) s.owners.items[oi].z else z;
                const end = if (stick == .point_left or stick == .point_right) a else b;
                try naive.append(gpa, .{ .id = id, .range = .{ .start = a, .end = end }, .stick = stick, .z = eff_z, .owner = oi, .kind = std.meta.activeTag(kind) });
            },
            4 => if (naive.items.len > 0) {
                const i = r.uintLessThan(usize, naive.items.len);
                s.remove(naive.items[i].id);
                _ = naive.swapRemove(i);
            },
            5...7 => {
                // A ChangeSet of up to three replaces (multi-cursor).
                var edits: [3]pt.Edit = undefined;
                var count: usize = 0;
                var pos: u64 = 0;
                for (0..r.intRangeAtMost(usize, 1, 3)) |_| {
                    if (pos > len) break;
                    const a = r.intRangeAtMost(u64, pos, len);
                    const b = @min(len, a + r.uintLessThan(u64, 8));
                    edits[count] = .{ .range = .{ .start = a, .end = b }, .text = pieces[r.uintLessThan(usize, pieces.len)] };
                    count += 1;
                    pos = b + 1;
                }
                var cs = try ChangeSet.fromEdits(gpa, len, edits[0..count]);
                defer cs.deinit();
                // The naive model: every range through each replace, back
                // to front.
                var i: usize = 0;
                while (i < naive.items.len) {
                    var keep = true;
                    var k = cs.replaces.len;
                    while (k > 0) {
                        k -= 1;
                        const rep = cs.replaces[k];
                        const it = &naive.items[i];
                        if (it.range.start <= rep.range.end and it.range.end >= rep.range.start) {
                            if (store_mod.mapRange(it.range, it.stick, rep.range.start, rep.range.end, rep.text.len)) |m| {
                                it.range = m;
                            } else {
                                keep = false;
                                break;
                            }
                        } else if (it.range.start > rep.range.end) {
                            it.range.start = it.range.start - rep.range.len() + rep.text.len;
                            it.range.end = it.range.end - rep.range.len() + rep.text.len;
                        }
                    }
                    if (keep) i += 1 else _ = naive.swapRemove(i);
                }
                try doc.applyChangeSet(&cs, .{ .user = 0 });
            },
            else => {
                const a = r.uintAtMost(u64, doc.len());
                const b = @min(doc.len(), a + r.uintLessThan(u64, 60));
                var filter: KindMask = .initEmpty();
                if (r.boolean()) filter.insert(.highlight);
                if (r.boolean()) filter.insert(.underline);
                var got: std.ArrayList(DecoRef) = .empty;
                defer got.deinit(gpa);
                try s.query(.{ .start = a, .end = b }, filter, gpa, &got);
                const want = try naiveQuery(gpa, naive.items, .{ .start = a, .end = b }, filter);
                defer gpa.free(want);
                try testing.expectEqual(want.len, got.items.len);
                for (want, got.items) |w, g| {
                    try testing.expectEqual(w.id, g.id);
                    try testing.expectEqual(w.range, g.range);
                }
            },
        }
        if (step % 100 == 0) {
            try s.tree.check();
            try testing.expectEqual(naive.items.len, s.count());
            for (naive.items) |n| try testing.expectEqual(n.range, s.get(n.id).?.range);
        }
    }
}

test "decorations: query and edit shifting equal naive" {
    var prng: std.Random.DefaultPrng = .init(0xdec0);
    var src: Source(std.Random) = .{ .inner = prng.random() };
    try decoFuzz(&src, 4000);
}

test "fuzz: decoration store vs naive" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var src: Source(*std.testing.Smith) = .{ .inner = smith };
            try decoFuzz(&src, 200);
        }
    }.one, .{});
}

test "decorations: owner replace with stale version maps" {
    const gpa = testing.allocator;
    const doc = try Document.initBytes(gpa, @enumFromInt(1), "let a = 1;\nlet b = 2;\n");
    defer doc.deinit();
    var s: DecorationStore = .init(gpa, doc);
    defer s.deinit();
    _ = try doc.subscribe(s.listener());
    const diag = try s.registerOwner("lsp.diagnostics", 10);
    const find = try s.registerOwner("find", 0);
    _ = try s.add(.{ .range = .{ .start = 0, .end = 3 }, .owner = find, .kind = .{ .highlight = style(9) } });
    const v0 = doc.version;
    // The user types while the server computes diagnostics against v0.
    try edit(doc, &.{.{ .range = .{ .start = 0, .end = 0 }, .text = "// hi\n" }});
    try edit(doc, &.{.{ .range = .{ .start = 10, .end = 11 }, .text = "" }}); // deletes "a" of v0
    try s.setOwnerDecorations(diag, v0, &.{
        .{ .range = .{ .start = 4, .end = 5 }, .owner = diag, .kind = .{ .underline = .{ .style = style(1) } } }, // "a": deleted since
        .{ .range = .{ .start = 15, .end = 16 }, .owner = diag, .kind = .{ .underline = .{ .style = style(1) } } }, // "b"
    });
    try testing.expectEqual(@as(usize, 1), s.ownerCount(diag));
    var got: std.ArrayList(DecoRef) = .empty;
    defer got.deinit(gpa);
    try s.query(.{ .start = 0, .end = doc.len() }, .initFull(), gpa, &got);
    try testing.expectEqual(@as(usize, 2), got.items.len);
    try testing.expectEqual(Range{ .start = 6, .end = 9 }, got.items[0].range);
    try testing.expectEqual(Range{ .start = 20, .end = 21 }, got.items[1].range);
    try testing.expectEqual(@as(i16, 10), got.items[1].deco.z);
    // Replacing again drops the old set.
    try s.setOwnerDecorations(diag, doc.version, &.{});
    try testing.expectEqual(@as(usize, 0), s.ownerCount(diag));
    s.clearOwner(find);
    try testing.expectEqual(@as(usize, 0), s.count());
    try testing.expectEqual(find, s.ownerByName("find").?);
}

test "decorations: point decorations at insertion point respect left/right" {
    const gpa = testing.allocator;
    const doc = try Document.initBytes(gpa, @enumFromInt(1), "abc");
    defer doc.deinit();
    var s: DecorationStore = .init(gpa, doc);
    defer s.deinit();
    _ = try doc.subscribe(s.listener());
    const o = try s.registerOwner("ai.ghost", 0);
    const gen0 = s.inline_generation;
    const l = try s.add(.{ .range = .{ .start = 1, .end = 2 }, .owner = o, .stick = .point_left, .kind = .{ .inline_after = .{ .text = "ghost", .style = style(3) } } });
    const rr = try s.add(.{ .range = .{ .start = 1, .end = 1 }, .owner = o, .stick = .point_right, .kind = .{ .gutter = .{ .icon = 1, .style = style(3) } } });
    try testing.expect(s.inline_generation > gen0);
    // Points are zero-width.
    try testing.expectEqual(Range{ .start = 1, .end = 1 }, s.get(l).?.range);
    try edit(doc, &.{.{ .range = .{ .start = 1, .end = 1 }, .text = "XY" }});
    try testing.expectEqual(Range{ .start = 1, .end = 1 }, s.get(l).?.range);
    try testing.expectEqual(Range{ .start = 3, .end = 3 }, s.get(rr).?.range);
    // The inline text was copied.
    try testing.expectEqualStrings("ghost", s.get(l).?.deco.kind.inline_after.text);
    s.remove(l);
    try testing.expect(s.get(l) == null);
    s.remove(l); // stale: ignored
    // A reused slot gets a new id.
    const again = try s.add(.{ .range = .{ .start = 0, .end = 0 }, .owner = o, .kind = .strike });
    try testing.expect(again != l);
    try testing.expect(s.get(l) == null);
}

test "decorations: bulk owner replace equals one-by-one" {
    const gpa = testing.allocator;
    const doc = try Document.initBytes(gpa, @enumFromInt(1), "y" ** 5000);
    defer doc.deinit();
    var s: DecorationStore = .init(gpa, doc);
    defer s.deinit();
    _ = try doc.subscribe(s.listener());
    const a = try s.registerOwner("a", 1);
    const b = try s.registerOwner("b", 2);
    var prng: std.Random.DefaultPrng = .init(7);
    const r = prng.random();
    var b_ids: std.ArrayList(DecorationId) = .empty;
    defer b_ids.deinit(gpa);
    for (0..500) |_| {
        const st = r.uintLessThan(u64, 4990);
        try b_ids.append(gpa, try s.add(.{ .range = .{ .start = st, .end = st + 5 }, .owner = b, .stick = .grow_both, .kind = .strike }));
    }
    const set = try gpa.alloc(Decoration, 3000);
    defer gpa.free(set);
    for (0..3) |round| {
        const v = doc.version;
        for (set) |*d| {
            const st = r.uintLessThan(u64, 4990);
            d.* = .{ .range = .{ .start = st, .end = st + r.uintLessThan(u64, 9) }, .owner = a, .kind = .{ .inline_after = .{ .text = "hint", .style = style(4) } } };
        }
        // Some edits after `v`, so the set is mapped.
        if (round > 0) try edit(doc, &.{.{ .range = .{ .start = 100, .end = 110 }, .text = "" }});
        try s.setOwnerDecorations(a, v, set);
        try s.tree.check();
        // The same set added one by one into a fresh store must query
        // identically (ids aside).
        var fresh: DecorationStore = .init(gpa, doc);
        defer fresh.deinit();
        _ = try fresh.registerOwner("a", 1);
        _ = try fresh.registerOwner("b", 2);
        for (set) |d_in| {
            var d = d_in;
            if (v != doc.version) d.range = doc.mapForward(v, d.range, .right) orelse continue;
            _ = try fresh.add(d);
        }
        for (b_ids.items) |id| {
            const ref = s.get(id).?;
            _ = try fresh.add(.{ .range = ref.range, .owner = b, .kind = .strike });
        }
        var got: std.ArrayList(DecoRef) = .empty;
        defer got.deinit(gpa);
        var want: std.ArrayList(DecoRef) = .empty;
        defer want.deinit(gpa);
        try s.query(.{ .start = 0, .end = doc.len() }, .initFull(), gpa, &got);
        try fresh.query(.{ .start = 0, .end = doc.len() }, .initFull(), gpa, &want);
        try testing.expectEqual(want.items.len, got.items.len);
        try testing.expectEqual(want.items.len, s.count());
        try testing.expectEqual(s.count() - 500, s.ownerCount(a));
        // Equal multisets of (range, owner); order within equal keys may
        // differ by id.
        var sum_got: u64 = 0;
        var sum_want: u64 = 0;
        for (got.items, want.items) |g, w| {
            try testing.expectEqual(w.range.start, g.range.start);
            sum_got +%= g.range.end *% 31 +% @intFromEnum(g.deco.owner);
            sum_want +%= w.range.end *% 31 +% @intFromEnum(w.deco.owner);
        }
        try testing.expectEqual(sum_want, sum_got);
        // Ids of the other owner survive, and later edits keep working.
        for (b_ids.items) |id| try testing.expect(s.get(id) != null);
        try edit(doc, &.{.{ .range = .{ .start = 0, .end = 0 }, .text = "zz" }});
        try s.tree.check();
    }
    s.clearOwner(a);
    try testing.expectEqual(@as(usize, 500), s.count());
}
