//! Breakpoints on real editor documents: anchors through edits (and a
//! fuzz against a naive line-tracking reference), frozen and re-tracked
//! lines, and the gutter marks.

const std = @import("std");
const zg_editor = @import("zg_editor");
const zg_dap = @import("zg_dap");
const BreakpointGutter = @import("BreakpointGutter.zig");

const testing = std.testing;
const gpa = testing.allocator;
const Document = zg_editor.model.document.Document;
const DecorationStore = zg_editor.model.decorations.store.DecorationStore;
const ChangeSet = zg_editor.model.edit.change_set.ChangeSet;
const pt = zg_editor.model.buffer.piece_tree;
const BreakpointManager = zg_dap.breakpoints.BreakpointManager;
const decorate = zg_dap.breakpoints.decorate;

fn styles() BreakpointGutter.Styles {
    return .{
        .enabled = @enumFromInt(1),
        .disabled = @enumFromInt(2),
        .unverified = @enumFromInt(3),
        .warning = @enumFromInt(4),
        .anchor = @enumFromInt(5),
        .exec_top = @enumFromInt(6),
        .exec_selected = @enumFromInt(7),
    };
}

const Fixture = struct {
    doc: *Document,
    store: DecorationStore,
    g: BreakpointGutter,
    m: BreakpointManager,

    fn init(f: *Fixture, text: []const u8) !void {
        f.doc = try Document.initBytes(gpa, @enumFromInt(1), text);
        f.store = .init(gpa, f.doc);
        _ = try f.doc.subscribe(f.store.listener());
        f.g = .init(gpa, testing.io, styles());
        f.m = .init(gpa, testing.io, .{ .host = f.g.host() });
        try f.g.bind(&f.m);
        try f.g.attach("/w/a.zig", f.doc, &f.store);
        f.m.docOpened("/w/a.zig");
    }

    fn deinit(f: *Fixture) void {
        f.m.deinit();
        f.g.deinit();
        f.store.deinit();
        f.doc.deinit();
    }

    fn edit(f: *Fixture, a: u64, b: u64, text: []const u8) !void {
        var cs = try ChangeSet.fromEdits(gpa, f.doc.len(), &.{pt.Edit{ .range = .{ .start = a, .end = b }, .text = text }});
        defer cs.deinit();
        try f.doc.applyChangeSet(&cs, .{ .user = 0 });
        f.g.flush();
    }

    fn lineOf(f: *Fixture, id: BreakpointManager.BpId) !u32 {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        return ((try f.m.get(arena.allocator(), id)) orelse return error.Missing).bp.kind.source.line;
    }

    fn offsetOfLine(f: *Fixture, line: u32) u64 {
        return f.doc.tree.lineStart(line - 1);
    }
};

fn numbered(a: std.mem.Allocator, n: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (0..n) |i| try out.print(a, "line {d}\n", .{i + 1});
    return out.items;
}

test "bp gutter: anchors follow edits; a deleted line merges" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var f: Fixture = undefined;
    try f.init(try numbered(arena.allocator(), 30));
    defer f.deinit();
    const b10 = try f.m.add(.{ .kind = .{ .source = .{ .path = "/w/a.zig", .line = 10 } } });
    const b20 = try f.m.add(.{ .kind = .{ .source = .{ .path = "/w/a.zig", .line = 20 } } });
    f.g.flush();
    // Two lines above: both move down.
    try f.edit(0, 0, "x\ny\n");
    try testing.expectEqual(@as(u32, 12), try f.lineOf(b10));
    try testing.expectEqual(@as(u32, 22), try f.lineOf(b20));
    // A line inserted at the very start of line 12 pushes it down too.
    const at12 = f.offsetOfLine(12);
    try f.edit(at12, at12, "new\n");
    try testing.expectEqual(@as(u32, 13), try f.lineOf(b10));
    // Typing inside the line does not move it.
    try f.edit(at12 + 6, at12 + 6, "abc");
    try testing.expectEqual(@as(u32, 13), try f.lineOf(b10));
    // Deleting lines 12..14 (b10's line among them) merges onto line 12.
    try f.edit(f.offsetOfLine(12), f.offsetOfLine(15), "");
    try testing.expectEqual(@as(u32, 12), try f.lineOf(b10));
    try testing.expectEqual(@as(u32, 20), try f.lineOf(b20));
    // The gutter shows both, at their lines.
    var out: std.ArrayList(zg_editor.model.decorations.store.DecoRef) = .empty;
    defer out.deinit(gpa);
    var mask: zg_editor.model.decorations.store.KindMask = .initEmpty();
    mask.insert(.gutter);
    try f.store.query(.{ .start = 0, .end = f.doc.len() }, mask, gpa, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqual(f.offsetOfLine(12), out.items[0].range.start);
    try testing.expectEqual(@as(u32, 0x25CF), out.items[0].deco.kind.gutter.icon);
}

test "bp gutter: frozen when closed, tracked again on open" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var f: Fixture = undefined;
    try f.init(try numbered(arena.allocator(), 10));
    defer f.deinit();
    const b = try f.m.add(.{ .kind = .{ .source = .{ .path = "/w/a.zig", .line = 5 } } });
    f.g.flush();
    try f.edit(0, 0, "a\n");
    f.m.docClosed("/w/a.zig");
    f.g.detach("/w/a.zig");
    try testing.expectEqual(@as(u32, 6), try f.lineOf(b));
    try testing.expectEqual(@as(usize, 0), f.store.count());
    // Open again: the frozen line is tracked from now.
    try f.g.attach("/w/a.zig", f.doc, &f.store);
    f.m.docOpened("/w/a.zig");
    f.g.flush();
    try f.edit(0, f.offsetOfLine(3), "");
    try testing.expectEqual(@as(u32, 4), try f.lineOf(b));
}

test "bp gutter: glyphs and the execution pointer" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var f: Fixture = undefined;
    try f.init(try numbered(arena.allocator(), 10));
    defer f.deinit();
    _ = try f.m.add(.{ .kind = .{ .source = .{ .path = "/w/a.zig", .line = 2, .log_message = "x" } } });
    _ = try f.m.add(.{ .enabled = false, .kind = .{ .source = .{ .path = "/w/a.zig", .line = 4 } } });
    try f.g.setExec(.{ .path = "/w/a.zig", .line = 6 }, .{ .path = "/w/a.zig", .line = 8 });
    f.g.flush();
    var out: std.ArrayList(zg_editor.model.decorations.store.DecoRef) = .empty;
    defer out.deinit(gpa);
    try f.store.query(.{ .start = 0, .end = f.doc.len() }, .initFull(), gpa, &out);
    var gutters: [3]u32 = undefined;
    var n: usize = 0;
    var highlights: usize = 0;
    for (out.items) |d| switch (d.deco.kind) {
        .gutter => |gm| {
            gutters[n] = gm.icon;
            n += 1;
        },
        .highlight => highlights += 1,
        else => {},
    };
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(@as(u32, 0x25C6), gutters[0]); // logpoint
    try testing.expectEqual(@as(u32, 0x25CB), gutters[1]); // disabled
    try testing.expectEqual(@as(u32, 0x27A4), gutters[2]); // the arrow
    try testing.expectEqual(@as(usize, 2), highlights);
    const before = f.g.redraws;
    f.g.flush();
    try testing.expectEqual(before, f.g.redraws); // nothing changed
}

/// The naive reference: lines move by the newlines inserted or deleted
/// before them; a line inside a deletion collapses onto its first line;
/// an insertion at a line's very start pushes it down.
const Reference = struct {
    fn insert(lines: []u32, at_line: u32, at_col: u64, newlines: u32) void {
        for (lines) |*l| if (l.* > at_line or (l.* == at_line and at_col == 0)) {
            l.* += newlines;
        };
    }

    fn delete(lines: []u32, from_line: u32, to_line: u32) void {
        for (lines) |*l| {
            if (l.* > to_line) l.* -= to_line - from_line else if (l.* > from_line) l.* = from_line;
        }
    }
};

test "bp gutter: edit fuzz matches the naive line reference" {
    var prng: std.Random.DefaultPrng = .init(0x618);
    const rnd = prng.random();
    for (0..20) |_| {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        var f: Fixture = undefined;
        try f.init(try numbered(arena.allocator(), 60));
        defer f.deinit();
        var ids: [8]BreakpointManager.BpId = undefined;
        var ref: [8]u32 = undefined;
        for (&ids, &ref, 0..) |*id, *r, k| {
            r.* = @intCast(1 + k * 7);
            id.* = try f.m.add(.{ .kind = .{ .source = .{ .path = "/w/a.zig", .line = r.* } } });
        }
        f.g.flush();
        for (0..200) |_| {
            const len = f.doc.len();
            if (rnd.boolean() or len < 40) {
                const at = rnd.uintAtMost(u64, len);
                const nl = rnd.uintAtMost(u32, 3);
                var text: std.ArrayList(u8) = .empty;
                for (0..nl) |_| try text.appendSlice(arena.allocator(), "ins\n");
                if (rnd.boolean()) try text.appendSlice(arena.allocator(), "tail");
                const line0: u32 = @intCast(f.doc.tree.lineOf(at));
                const col = at - f.doc.tree.lineStart(line0);
                Reference.insert(&ref, line0 + 1, col, nl);
                try f.edit(at, at, text.items);
            } else {
                const a = rnd.uintAtMost(u64, len - 1);
                const b = @min(len, a + 1 + rnd.uintAtMost(u64, 30));
                const la: u32 = @intCast(f.doc.tree.lineOf(a));
                const lb: u32 = @intCast(f.doc.tree.lineOf(b));
                // A deletion ending at the very end with no newline after
                // keeps the line count; the reference works in lines.
                Reference.delete(&ref, la + 1, lb + 1);
                try f.edit(a, b, "");
            }
            for (ids, ref) |id, r| try testing.expectEqual(r, try f.lineOf(id));
        }
    }
}
