//! Persistent undo files: round trips, mismatches, corruption, size caps
//! and a reader fuzz target.

const std = @import("std");
const undo_file = @import("undo_file.zig");
const undo_mod = @import("undo.zig");
const Document = @import("../document.zig").Document;
const ChangeSet = @import("change_set.zig").ChangeSet;
const Selection = @import("selection.zig").Selection;

const gpa = std.testing.allocator;
const io = std.testing.io;
const UndoTree = undo_mod.UndoTree;

/// A document and its undo tree, edited with one group per edit.
const History = struct {
    doc: *Document,
    undo: UndoTree,
    t: i96 = 0,

    fn init(text: []const u8) !History {
        return .{ .doc = try Document.initBytes(gpa, @enumFromInt(1), text), .undo = .init(gpa, .{}) };
    }

    fn deinit(h: *History) void {
        h.doc.deinit();
        h.undo.deinit();
    }

    fn edit(h: *History, start: u64, end: u64, text: []const u8, label: []const u8) !void {
        var cs = try ChangeSet.fromEdits(gpa, h.doc.len(), &.{.{ .range = .{ .start = start, .end = end }, .text = text }});
        errdefer cs.deinit();
        var inv = try cs.invert(h.doc.tree, gpa);
        errdefer inv.deinit();
        try h.doc.applyChangeSet(&cs, .{ .agent = 7 });
        h.t += std.time.ns_per_s * 5;
        const before = [_]Selection{.caret(start)};
        const after = [_]Selection{.{ .anchor = start, .head = start + text.len, .id = 3 }};
        try h.undo.record(cs, inv, &before, &after, .{ .label = label, .origin = .{ .agent = 7 }, .timestamp = .{ .nanoseconds = h.t }, .coalesce_key = .typing_word });
        h.undo.breakGroup();
    }

    fn back(h: *History) !void {
        const step = h.undo.undo().?;
        try h.doc.applyChangeSet(step.changes, .undo);
    }

    fn content(h: *History) ![]u8 {
        return h.doc.tree.copyRange(gpa, .{ .start = 0, .end = h.doc.len() });
    }
};

fn expectSameTree(a: *const UndoTree, b: *const UndoTree) !void {
    try std.testing.expectEqual(a.current, b.current);
    try std.testing.expectEqual(a.saved, b.saved);
    try std.testing.expectEqual(a.nodes().len, b.nodes().len);
    for (a.nodes(), b.nodes()) |x, y| {
        try std.testing.expectEqual(x.parent, y.parent);
        try std.testing.expectEqual(x.first_child, y.first_child);
        try std.testing.expectEqual(x.next_sibling, y.next_sibling);
        try std.testing.expectEqual(x.redo_child, y.redo_child);
        try std.testing.expectEqual(x.seq, y.seq);
        try std.testing.expectEqual(x.timestamp.nanoseconds, y.timestamp.nanoseconds);
        try std.testing.expectEqual(x.origin, y.origin);
        try std.testing.expectEqual(x.coalesce_key, y.coalesce_key);
        try std.testing.expectEqualStrings(x.label, y.label);
        inline for (.{ "forward", "inverse" }) |f| {
            const cx = @field(x, f);
            const cy = @field(y, f);
            try std.testing.expectEqual(cx.base_len, cy.base_len);
            try std.testing.expectEqual(cx.replaces.len, cy.replaces.len);
            for (cx.replaces, cy.replaces) |rx, ry| {
                try std.testing.expectEqual(rx.range, ry.range);
                try std.testing.expectEqualStrings(rx.text, ry.text);
            }
        }
        try std.testing.expectEqualSlices(Selection, x.sel_before, y.sel_before);
        try std.testing.expectEqualSlices(Selection, x.sel_after, y.sel_after);
    }
}

test "undo_file: round trip tree with branches" {
    var h = try History.init("hello world\n");
    defer h.deinit();
    try h.edit(0, 5, "HELLO", "upper");
    try h.edit(6, 11, "there", "word");
    h.undo.markSaved(h.undo.current);
    try h.back();
    try h.edit(12, 12, "and more\n", "branch");
    try h.edit(0, 0, "", "noop");
    const content = try h.content();
    defer gpa.free(content);
    const hash = undo_file.contentHash(content);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const key = undo_file.pathKey("/work/hello.txt");
    try undo_file.write(io, tmp.dir, key, &h.undo, hash, content.len, gpa);
    var back = (try undo_file.read(io, tmp.dir, key, hash, content.len, gpa)).?;
    defer back.deinit();
    try expectSameTree(&h.undo, &back);

    // The restored tree drives the document: travel to the saved branch.
    const steps = try back.travel(back.saved);
    for (steps) |s| try h.doc.applyChangeSet(s.changes, .undo);
    const t = try h.content();
    defer gpa.free(t);
    try std.testing.expectEqualStrings("HELLO there\n", t);
    try std.testing.expect(back.isAtSaved());
}

test "undo_file: empty tree round trips" {
    var u: UndoTree = .init(gpa, .{});
    defer u.deinit();
    const bytes = try undo_file.encode(gpa, &u, @splat(0), 0, undo_file.default_max_bytes);
    defer gpa.free(bytes);
    var back = (try undo_file.decode(gpa, bytes, @splat(0), 0, .{})).?;
    defer back.deinit();
    try std.testing.expectEqual(@as(usize, 0), back.nodes().len);
}

test "undo_file: hash mismatch ignored" {
    var h = try History.init("abc");
    defer h.deinit();
    try h.edit(0, 1, "A", "a");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const key = undo_file.pathKey("/work/abc.txt");
    try undo_file.write(io, tmp.dir, key, &h.undo, undo_file.contentHash("Abc"), 3, gpa);
    try std.testing.expectEqual(@as(?UndoTree, null), try undo_file.read(io, tmp.dir, key, undo_file.contentHash("Xbc"), 3, gpa));
    try std.testing.expectEqual(@as(?UndoTree, null), try undo_file.read(io, tmp.dir, key, undo_file.contentHash("Abc"), 4, gpa));
    // The file stays for the content it belongs to.
    var back = (try undo_file.read(io, tmp.dir, key, undo_file.contentHash("Abc"), 3, gpa)).?;
    back.deinit();
    // No file at all.
    try std.testing.expectEqual(@as(?UndoTree, null), try undo_file.read(io, tmp.dir, undo_file.pathKey("/nope"), @splat(0), 0, gpa));
}

test "undo_file: corrupted trailer ignored and moved aside" {
    var h = try History.init("abc");
    defer h.deinit();
    try h.edit(0, 1, "A", "a");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const key = undo_file.pathKey("/work/abc.txt");
    const hash = undo_file.contentHash("Abc");
    try undo_file.write(io, tmp.dir, key, &h.undo, hash, 3, gpa);
    const name = undo_file.fileName(key);
    const bytes = try tmp.dir.readFileAlloc(io, &name, gpa, .limited(1 << 20));
    defer gpa.free(bytes);
    bytes[bytes.len - 1] ^= 0xFF;
    try tmp.dir.writeFile(io, .{ .sub_path = &name, .data = bytes });
    try std.testing.expectEqual(@as(?UndoTree, null), try undo_file.read(io, tmp.dir, key, hash, 3, gpa));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, &name, .{}));
    _ = try tmp.dir.statFile(io, &(name ++ ".corrupt".*), .{});
}

test "undo_file: size cap prunes oldest" {
    var h = try History.init("");
    defer h.deinit();
    const chunk = "x" ** 1000;
    for (0..50) |k| {
        var label: [8]u8 = undefined;
        try h.edit(h.doc.len(), h.doc.len(), chunk, std.fmt.bufPrint(&label, "e{d}", .{k}) catch unreachable);
    }
    const content = try h.content();
    defer gpa.free(content);
    const hash = undo_file.contentHash(content);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const key = undo_file.pathKey("/work/big.txt");
    const cap = 20_000;
    try undo_file.writeCapped(io, tmp.dir, key, &h.undo, hash, content.len, gpa, cap);
    const st = try tmp.dir.statFile(io, &undo_file.fileName(key), .{});
    try std.testing.expect(st.size <= cap);
    var back = (try undo_file.read(io, tmp.dir, key, hash, content.len, gpa)).?;
    defer back.deinit();
    const nodes = back.nodes();
    try std.testing.expect(nodes.len > 5 and nodes.len < 51);
    // The newest groups survive; the oldest kept state is the new root.
    try std.testing.expectEqualStrings("e49", nodes[nodes.len - 1].label);
    try std.testing.expectEqual(back.current, @as(undo_mod.NodeId, @enumFromInt(nodes.len - 1)));
    try std.testing.expectEqual(@as(usize, 0), nodes[0].forward.replaces.len);
    // Undo works all the way back to the new root.
    var undone: usize = 0;
    while (back.undo()) |step| : (undone += 1) try h.doc.applyChangeSet(step.changes, .undo);
    try std.testing.expectEqual(nodes.len - 1, undone);
    try std.testing.expectEqual(@as(u64, (51 - nodes.len) * chunk.len), h.doc.len());
}

test "undo_file: pruning prefers stale branches" {
    var h = try History.init("base\n");
    defer h.deinit();
    const big = "b" ** 4000;
    try h.edit(0, 0, big, "old branch");
    try h.back();
    try h.edit(0, 0, "keep ", "kept");
    const content = try h.content();
    defer gpa.free(content);
    const hash = undo_file.contentHash(content);
    const bytes = try undo_file.encode(gpa, &h.undo, hash, content.len, 2000);
    defer gpa.free(bytes);
    var back = (try undo_file.decode(gpa, bytes, hash, content.len, .{})).?;
    defer back.deinit();
    try std.testing.expectEqual(@as(usize, 2), back.nodes().len);
    try std.testing.expectEqualStrings("kept", back.nodes()[1].label);
}

test "fuzz: undo_file reader" {
    // A valid file to mutate, so the fuzzer reaches the node parser.
    var h = try History.init("seed text\n");
    defer h.deinit();
    try h.edit(0, 4, "SEED", "a");
    try h.back();
    try h.edit(5, 9, "TEXT", "b");
    const seed = try undo_file.encode(gpa, &h.undo, @splat(0), 0, undo_file.default_max_bytes);
    defer gpa.free(seed);
    try std.testing.fuzz(seed, struct {
        fn one(valid: []const u8, s: *std.testing.Smith) anyerror!void {
            var buf: [1024]u8 = undefined;
            const n = @min(valid.len, buf.len);
            @memcpy(buf[0..n], valid[0..n]);
            // Flip some bytes of the valid file, then fix the trailer so
            // the parser sees the damage instead of the checksum.
            for (0..1 + s.index(8)) |_| buf[s.index(n - 8)] ^= @intCast(1 + s.index(255));
            std.mem.writeInt(u64, buf[n - 8 ..][0..8], std.hash.XxHash3.hash(0, buf[0 .. n - 8]), .little);
            if (undo_file.decode(gpa, buf[0..n], @splat(0), 0, .{})) |r| {
                if (r) |t| {
                    var tree = t;
                    tree.deinit();
                }
            } else |e| switch (e) {
                error.Corrupt => {},
                error.OutOfMemory => return e,
            }
            var raw: [256]u8 = undefined;
            const m = s.slice(&raw);
            if (undo_file.decode(gpa, raw[0..m], @splat(0), 0, .{})) |r| {
                if (r) |t| {
                    var tree = t;
                    tree.deinit();
                }
            } else |_| {}
        }
    }.one, .{});
}
