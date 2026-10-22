//! Undo tree tests: grouping, branches, chronological traversal, selective
//! undo, pruning, the saved marker and the random-walk fuzz target.

const std = @import("std");
const cs_mod = @import("change_set.zig");
const undo = @import("undo.zig");
const sel_mod = @import("selection.zig");
const snapshot_mod = @import("../snapshot.zig");
const Document = @import("../document.zig").Document;

const ChangeSet = cs_mod.ChangeSet;
const Replace = cs_mod.Replace;
const Selection = sel_mod.Selection;
const UndoTree = undo.UndoTree;
const gpa = std.testing.allocator;

/// The inverse of `cs` over a plain string.
fn invertSlice(cs: *const ChangeSet, before: []const u8) !ChangeSet {
    const reps = try gpa.alloc(Replace, cs.replaces.len);
    defer gpa.free(reps);
    for (cs.replaces, cs.new_starts, reps) |r, ns, *o| {
        o.* = .{ .range = .{ .start = ns, .end = ns + r.text.len }, .text = before[@intCast(r.range.start)..@intCast(r.range.end)] };
    }
    return ChangeSet.fromEdits(gpa, cs.newLen(), reps);
}

fn ms(t: i64) std.Io.Timestamp {
    return .{ .nanoseconds = @as(i96, t) * std.time.ns_per_ms };
}

/// A string document with one caret and an undo tree.
const Ed = struct {
    text: std.ArrayList(u8) = .empty,
    sels: std.ArrayList(Selection) = .empty,
    tree: UndoTree,
    now: i64 = 0,

    fn init(initial: []const u8, limits: undo.Limits) !Ed {
        var e: Ed = .{ .tree = .init(gpa, limits) };
        try e.text.appendSlice(gpa, initial);
        try e.sels.append(gpa, .caret(0));
        return e;
    }

    fn deinit(e: *Ed) void {
        e.text.deinit(gpa);
        e.sels.deinit(gpa);
        e.tree.deinit();
    }

    fn setText(e: *Ed, cs: *const ChangeSet) !void {
        const next = try cs.applyToSlice(gpa, e.text.items);
        defer gpa.free(next);
        e.text.clearRetainingCapacity();
        try e.text.appendSlice(gpa, next);
    }

    fn setSels(e: *Ed, s: []const Selection) !void {
        e.sels.clearRetainingCapacity();
        try e.sels.appendSlice(gpa, s);
    }

    /// Replaces `[start, end)` with `ins` at time `e.now`, caret after it.
    fn editMeta(e: *Ed, start: u64, end: u64, ins: []const u8, meta: undo.GroupMeta) !void {
        var cs = try ChangeSet.fromEdits(gpa, e.text.items.len, &.{.{ .range = .{ .start = start, .end = end }, .text = ins }});
        errdefer cs.deinit();
        var inv = try invertSlice(&cs, e.text.items);
        errdefer inv.deinit();
        const before = try gpa.dupe(Selection, e.sels.items);
        defer gpa.free(before);
        try e.setText(&cs);
        try e.setSels(&.{.caret(start + ins.len)});
        try e.tree.record(cs, inv, before, e.sels.items, meta);
    }

    fn edit(e: *Ed, start: u64, end: u64, ins: []const u8, key: ?undo.CoalesceKey) !void {
        return e.editMeta(start, end, ins, .{ .origin = .{ .user = 1 }, .timestamp = ms(e.now), .coalesce_key = key });
    }

    /// Types `s` at the caret one byte at a time, 50 ms apart.
    fn typeText(e: *Ed, s: []const u8) !void {
        for (0..s.len) |i| {
            const at = e.sels.items[0].head;
            const key: undo.CoalesceKey = if (s[i] == ' ') .typing_space else .typing_word;
            try e.edit(at, at, s[i .. i + 1], key);
            e.now += 50;
        }
    }

    fn step(e: *Ed, st: undo.Step) !void {
        try e.setText(st.changes);
        try e.setSels(st.selections);
    }

    fn steps(e: *Ed, sts: []const undo.Step) !void {
        for (sts) |st| try e.step(st);
    }

    fn undo1(e: *Ed) !bool {
        const st = e.tree.undo() orelse return false;
        try e.step(st);
        return true;
    }

    fn redo1(e: *Ed) !bool {
        const st = e.tree.redo() orelse return false;
        try e.step(st);
        return true;
    }
};

test "undo: typing coalesces into words" {
    var e = try Ed.init("", .{});
    defer e.deinit();
    try e.typeText("hello world");
    try std.testing.expectEqual(@as(usize, 3), e.tree.nodes().len); // root, "hello ", "world"
    try std.testing.expect(try e.undo1());
    try std.testing.expectEqualStrings("hello ", e.text.items);
    try std.testing.expect(try e.undo1());
    try std.testing.expectEqualStrings("", e.text.items);
    try std.testing.expect(!try e.undo1());
    // A pause of one second starts a new group too.
    try e.typeText("ab");
    e.now += 1000;
    try e.typeText("cd");
    try std.testing.expect(try e.undo1());
    try std.testing.expectEqualStrings("ab", e.text.items);
}

test "undo: cursor jump breaks group" {
    var e = try Ed.init("", .{});
    defer e.deinit();
    try e.typeText("abc");
    try e.setSels(&.{.caret(1)});
    try e.typeText("x");
    try std.testing.expectEqualStrings("axbc", e.text.items);
    try std.testing.expect(try e.undo1());
    try std.testing.expectEqualStrings("abc", e.text.items);
    try std.testing.expectEqual(@as(u64, 1), e.sels.items[0].head);
    e.tree.breakGroup();
    try std.testing.expect(try e.redo1());
    try e.typeText("y");
    try e.typeText("z");
    try std.testing.expect(try e.undo1());
    try std.testing.expectEqualStrings("axbc", e.text.items);
}

test "undo: redo follows newest branch" {
    var e = try Ed.init("", .{});
    defer e.deinit();
    try e.edit(0, 0, "a", null);
    try e.edit(1, 1, "b", null);
    try e.edit(2, 2, "c", null);
    _ = try e.undo1();
    _ = try e.undo1();
    try e.edit(1, 1, "X", null);
    try std.testing.expectEqualStrings("aX", e.text.items);
    _ = try e.undo1();
    try std.testing.expect(try e.redo1());
    try std.testing.expectEqualStrings("aX", e.text.items);
    try std.testing.expect(!try e.redo1());
}

test "undo: older/newer reaches abandoned branch" {
    var e = try Ed.init("", .{});
    defer e.deinit();
    try e.edit(0, 0, "a", null); // 1
    try e.edit(1, 1, "b", null); // 2
    try e.edit(2, 2, "c", null); // 3
    _ = try e.undo1();
    _ = try e.undo1();
    try e.edit(1, 1, "X", null); // 4: "aX"
    // g- walks back in creation order: abc, ab, a, "".
    const want = [_][]const u8{ "abc", "ab", "a", "" };
    for (want) |w| {
        try e.steps((try e.tree.older()).?);
        try std.testing.expectEqualStrings(w, e.text.items);
    }
    try std.testing.expect(try e.tree.older() == null);
    const fwd = [_][]const u8{ "a", "ab", "abc", "aX" };
    for (fwd) |w| {
        try e.steps((try e.tree.newer()).?);
        try std.testing.expectEqualStrings(w, e.text.items);
    }
    try std.testing.expect(try e.tree.newer() == null);
}

test "undo: selections restored exactly" {
    var e = try Ed.init("one two three", .{});
    defer e.deinit();
    try e.setSels(&.{ .{ .anchor = 0, .head = 3 }, .{ .anchor = 8, .head = 4 } });
    const before = try gpa.dupe(Selection, e.sels.items);
    defer gpa.free(before);
    try e.edit(0, 3, "1", null);
    try std.testing.expect(try e.undo1());
    try std.testing.expectEqualStrings("one two three", e.text.items);
    try std.testing.expect(sel_mod.eql(before, e.sels.items));
    try std.testing.expect(try e.redo1());
    try std.testing.expect(sel_mod.eql(&.{.caret(1)}, e.sels.items));
}

test "undo: agent group never coalesces" {
    var e = try Ed.init("", .{});
    defer e.deinit();
    try e.typeText("ab");
    const at = e.sels.items[0].head;
    try e.editMeta(at, at, "c", .{ .label = "Agent: edit_file (session 3)", .origin = .{ .agent = 3 }, .timestamp = ms(e.now), .coalesce_key = .typing_word });
    try e.editMeta(at + 1, at + 1, "d", .{ .origin = .{ .agent = 3 }, .timestamp = ms(e.now), .coalesce_key = .typing_word });
    try e.typeText("e");
    const ns = e.tree.nodes();
    try std.testing.expectEqual(@as(usize, 5), ns.len);
    try std.testing.expectEqualStrings("Agent: edit_file (session 3)", ns[2].label);
}

test "undo: selective undo with later independent edits" {
    var e = try Ed.init("hello world", .{});
    defer e.deinit();
    try e.editMeta(5, 5, ",", .{ .origin = .{ .agent = 1 }, .timestamp = ms(0) }); // agent: "hello, world"
    const agent: undo.NodeId = @enumFromInt(1);
    try e.edit(12, 12, "!", null); // user: "hello, world!"
    try e.edit(0, 1, "H", null); // user: "Hello, world!"
    var doc = try Document.initBytes(gpa, @enumFromInt(1), e.text.items);
    defer doc.deinit();
    var snap = doc.snapshot();
    defer snap.release();
    var res = try e.tree.selectiveUndo(agent, snap);
    switch (res) {
        .ok => |*cs| {
            defer cs.deinit();
            try e.setText(cs);
            try std.testing.expectEqualStrings("Hello world!", e.text.items);
        },
        .conflict => |*c| {
            c.deinit(gpa);
            return error.TestUnexpectedResult;
        },
    }
}

test "undo: selective undo conflict" {
    var e = try Ed.init("hello world", .{});
    defer e.deinit();
    try e.editMeta(0, 5, "howdy", .{ .origin = .{ .agent = 1 }, .timestamp = ms(0) });
    try e.edit(2, 3, "W", null); // "hoWdy world": rewrites the agent's text
    var doc = try Document.initBytes(gpa, @enumFromInt(1), e.text.items);
    defer doc.deinit();
    var snap = doc.snapshot();
    defer snap.release();
    var res = try e.tree.selectiveUndo(@enumFromInt(1), snap);
    switch (res) {
        .ok => |*cs| {
            cs.deinit();
            return error.TestUnexpectedResult;
        },
        .conflict => |*c| {
            defer c.deinit(gpa);
            try std.testing.expectEqual(@as(usize, 1), c.ranges.len);
            try std.testing.expectEqual(@as(u64, 0), c.ranges[0].start);
            try std.testing.expectEqual(@as(u64, 5), c.ranges[0].end);
        },
    }
}

test "undo: prune keeps current path valid" {
    var e = try Ed.init("", .{ .max_nodes = 20 });
    defer e.deinit();
    // An abandoned branch, then a long current path.
    try e.edit(0, 0, "a", null);
    try e.edit(1, 1, "b", null);
    _ = try e.undo1();
    for (0..40) |i| {
        const at = e.text.items.len;
        try e.edit(at, at, &.{@intCast('0' + i % 10)}, null);
    }
    try std.testing.expect(e.tree.nodes().len <= 20);
    try std.testing.expect(e.tree.truncated);
    const want = try gpa.dupe(u8, e.text.items);
    defer gpa.free(want);
    var n: usize = 0;
    while (try e.undo1()) n += 1;
    try std.testing.expectEqual(e.tree.nodes().len - 1, n);
    while (try e.redo1()) {}
    try std.testing.expectEqualStrings(want, e.text.items);
    for (e.tree.nodes()[1..]) |nd| try std.testing.expect(nd.parent != .none);
}

test "undo: memory cap honoured" {
    const cap: usize = 256 << 10;
    var e = try Ed.init("", .{ .max_bytes = cap });
    defer e.deinit();
    const chunk = [_]u8{'x'} ** 1000;
    for (0..2000) |_| {
        const at = e.text.items.len;
        try e.edit(at, at, &chunk, null);
        try std.testing.expect(e.tree.bytes <= cap + cap / 10);
    }
}

test "undo: saved marker after undo back to save is clean" {
    var e = try Ed.init("", .{});
    defer e.deinit();
    try std.testing.expect(e.tree.isAtSaved());
    try e.edit(0, 0, "a", null);
    e.tree.markSaved(e.tree.current);
    try std.testing.expect(e.tree.isAtSaved());
    try e.edit(1, 1, "b", null);
    try std.testing.expect(!e.tree.isAtSaved());
    _ = try e.undo1();
    try std.testing.expect(e.tree.isAtSaved());
    _ = try e.undo1();
    try std.testing.expect(!e.tree.isAtSaved());
}

test "undo: revert to time as one step" {
    var e = try Ed.init("", .{});
    defer e.deinit();
    try e.edit(0, 0, "a", null);
    e.now = 60_000;
    try e.edit(1, 1, "b", null);
    e.now = 120_000;
    try e.edit(2, 2, "c", null);
    const target = e.tree.nodeAtTime(ms(70_000));
    try std.testing.expectEqual(@as(undo.NodeId, @enumFromInt(2)), target);
    const pc = try e.tree.changesTo(target, e.text.items.len, gpa);
    var fwd = try pc.forward.clone(gpa);
    defer fwd.deinit();
    try e.setText(&fwd);
    try std.testing.expectEqualStrings("ab", e.text.items);
    try e.tree.record(pc.forward, pc.inverse, e.sels.items, e.tree.selectionsAt(target), .{ .origin = .undo, .timestamp = ms(130_000), .label = "Revert to 10 minutes ago" });
    try std.testing.expect(try e.undo1());
    try std.testing.expectEqualStrings("abc", e.text.items);
}

test "undo: 10k-replace group" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendNTimes(gpa, 'a', 20_000);
    var e = try Ed.init(text.items, .{});
    defer e.deinit();
    var edits: [10_000]Replace = undefined;
    for (&edits, 0..) |*ed, i| ed.* = .{ .range = .{ .start = i * 2, .end = i * 2 + 1 }, .text = "bb" };
    const cs = try ChangeSet.fromEdits(gpa, 20_000, &edits);
    const inv = try invertSlice(&cs, e.text.items);
    try e.setText(&cs);
    try e.tree.record(cs, inv, &.{}, &.{}, .{ .origin = .{ .user = 2 }, .timestamp = ms(0) });
    try std.testing.expect(try e.undo1());
    try std.testing.expectEqualStrings(text.items, e.text.items);
}

fn Source(comptime T: type) type {
    return struct {
        inner: T,
        fn pick(s: *@This(), n: usize) usize {
            if (n <= 1) return 0;
            if (T == std.Random) return s.inner.uintLessThan(usize, n);
            return s.inner.index(n);
        }
    };
}

/// Random edits, undos, redos, older/newer and travels; the text always
/// equals the state recorded for the current node.
fn randomWalk(src: anytype, ops: usize) !void {
    var e = try Ed.init("seed text", .{});
    defer e.deinit();
    var states: std.ArrayList([]u8) = .empty;
    defer {
        for (states.items) |s| gpa.free(s);
        states.deinit(gpa);
    }
    try states.append(gpa, try gpa.dupe(u8, e.text.items));
    const alpha = "abc \n";
    for (0..ops) |_| {
        switch (src.pick(6)) {
            0, 1 => {
                const len = e.text.items.len;
                const a = src.pick(len + 1);
                const b = a + src.pick(@min(len - a, 4) + 1);
                var buf: [4]u8 = undefined;
                const n = src.pick(buf.len + 1);
                for (buf[0..n]) |*c| c.* = alpha[src.pick(alpha.len)];
                try e.edit(a, b, buf[0..n], null);
                try states.append(gpa, try gpa.dupe(u8, e.text.items));
            },
            2 => _ = try e.undo1(),
            3 => _ = try e.redo1(),
            4 => if (src.pick(2) == 0) {
                if (try e.tree.older()) |s| try e.steps(s);
            } else {
                if (try e.tree.newer()) |s| try e.steps(s);
            },
            else => {
                const t: undo.NodeId = @enumFromInt(src.pick(e.tree.nodes().len));
                try e.steps(try e.tree.travel(t));
            },
        }
        const cur = @intFromEnum(e.tree.current);
        if (e.tree.nodes().len == 0) continue;
        try std.testing.expectEqualStrings(states.items[cur], e.text.items);
    }
}

test "undo: random walk" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    var src: Source(std.Random) = .{ .inner = prng.random() };
    for (0..50) |_| try randomWalk(&src, 200);
}

test "fuzz: undo/redo random walk" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var src: Source(*std.testing.Smith) = .{ .inner = s };
            try randomWalk(&src, 64);
        }
    }.one, .{});
}
