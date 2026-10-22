//! Benchmarks for zg_editor; run with `zig build bench` at the repo root.
//! Inputs are generated (seeded), so runs are reproducible.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_editor = @import("zg_editor");
const bench = zg_core.bench;

const buffer = zg_editor.model.buffer;
const PieceTree = buffer.piece_tree.PieceTree;
const NodePool = buffer.node_pool.NodePool;
const BufferTable = buffer.buffers.BufferTable;

pub fn main(min: std.process.Init.Minimal) !u8 {
    return bench.mainFromArgs(min, register);
}

/// Budgeted bench names that have no body yet.
pub const pending = [_][]const u8{
    "editor.open.1gb_first_screen",
    "editor.open.10mb_full",
};

/// A source-like file of `lines` lines (20-120 columns).
fn genLines(gpa: std.mem.Allocator, lines: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var rng: std.Random.DefaultPrng = .init(0x2605);
    const r = rng.random();
    for (0..lines) |_| {
        const n = 20 + r.uintLessThan(usize, 100);
        for (0..n) |_| try out.append(gpa, "abcdefghijklmnopqrstuvwxyz (){};=+"[r.uintLessThan(usize, 34)]);
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

const Doc = struct {
    pool: NodePool,
    bt: *BufferTable,
    tree: PieceTree,

    fn init(gpa: std.mem.Allocator, text: []const u8) !*Doc {
        const d = try gpa.create(Doc);
        d.pool = .init(gpa);
        d.bt = try BufferTable.create(gpa, try gpa.dupe(u8, text), true);
        d.tree = try PieceTree.fromOriginal(&d.pool, d.bt);
        return d;
    }

    fn deinit(d: *Doc, gpa: std.mem.Allocator) void {
        d.tree.deinit(&d.pool);
        d.pool.deinit();
        d.bt.release();
        gpa.destroy(d);
    }
};

/// One-character inserts at scattered offsets (each a new version).
fn insertChar(d: *Doc, s: *bench.State) void {
    var rng: std.Random.DefaultPrng = .init(1);
    const r = rng.random();
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        const at = r.uintLessThan(u64, d.tree.len());
        const next = d.tree.insert(&d.pool, at, "x") catch unreachable;
        d.tree.deinit(&d.pool);
        d.tree = next;
    }
}

/// Typing: consecutive inserts at one point (the fast path).
fn typeChar(d: *Doc, s: *bench.State) void {
    var at: u64 = d.tree.len() / 2;
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        const next = d.tree.insert(&d.pool, at, "x") catch unreachable;
        d.tree.deinit(&d.pool);
        d.tree = next;
        at += 1;
    }
}

fn offsetToPoint(d: *Doc, s: *bench.State) void {
    var rng: std.Random.DefaultPrng = .init(2);
    const r = rng.random();
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        bench.doNotOptimizeAway(d.tree.offsetToPoint(r.uintLessThan(u64, d.tree.len())));
    }
}

fn offsetToUtf16(d: *Doc, s: *bench.State) void {
    var rng: std.Random.DefaultPrng = .init(3);
    const r = rng.random();
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        bench.doNotOptimizeAway(d.tree.offsetToUtf16(r.uintLessThan(u64, d.tree.len())));
    }
}

/// 1,000 single-character replacements in one pass.
fn replace1k(d: *Doc, s: *bench.State) void {
    var edits: [1000]buffer.piece_tree.Edit = undefined;
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        const step = d.tree.len() / edits.len;
        for (&edits, 0..) |*e, k| e.* = .{ .range = .{ .start = k * step, .end = k * step }, .text = "y" };
        const next = d.tree.replace(&d.pool, &edits) catch unreachable;
        d.tree.deinit(&d.pool);
        d.tree = next;
    }
}

fn retainRelease(d: *Doc, s: *bench.State) void {
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        var c = d.tree.clone();
        c.deinit(&d.pool);
    }
}

/// Undo then redo of one 10k-replacement group (the applies dominate).
fn undo10k(d: *Doc, s: *bench.State) void {
    const edit = zg_editor.model.edit;
    const gpa = std.heap.page_allocator;
    var edits: [10_000]buffer.piece_tree.Edit = undefined;
    const step = d.tree.len() / edits.len;
    for (&edits, 0..) |*e, k| e.* = .{ .range = .{ .start = k * step, .end = k * step + 1 }, .text = "zz" };
    const cs = edit.change_set.ChangeSet.fromEdits(gpa, d.tree.len(), &edits) catch unreachable;
    const inv = cs.invert(d.tree, gpa) catch unreachable;
    const next = cs.apply(d.tree, &d.pool) catch unreachable;
    d.tree.deinit(&d.pool);
    d.tree = next;
    var tree: edit.undo.UndoTree = .init(gpa, .{});
    defer tree.deinit();
    tree.record(cs, inv, &.{}, &.{}, .{ .origin = .{ .user = 0 }, .timestamp = .zero }) catch unreachable;
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        inline for (.{ edit.undo.UndoTree.undo, edit.undo.UndoTree.redo }) |f| {
            const st = f(&tree).?;
            const t = st.changes.apply(d.tree, &d.pool) catch unreachable;
            d.tree.deinit(&d.pool);
            d.tree = t;
        }
    }
}

/// A modified copy of `text` with `hunks` scattered single-line changes.
fn mutateLines(gpa: std.mem.Allocator, text: []const u8, hunks: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const lines = std.mem.count(u8, text, "\n");
    const every = lines / hunks;
    var it = std.mem.splitScalar(u8, text, '\n');
    var i: usize = 0;
    while (it.next()) |line| : (i += 1) {
        if (line.len == 0 and it.peek() == null) break;
        if (every > 0 and i % every == every / 2) try out.appendSlice(gpa, "changed line\n");
        try out.appendSlice(gpa, line);
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

const DiffPair = struct {
    a: zg_editor.model.diff.LineSource,
    b: zg_editor.model.diff.LineSource,
};

fn diffPair(p: *DiffPair, s: *bench.State) void {
    const diff = zg_editor.model.diff;
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        var r = diff.diffLines(std.heap.page_allocator, &p.a, &p.b, .{}) catch unreachable;
        bench.doNotOptimizeAway(r.hunks.len);
        r.deinit(std.heap.page_allocator);
    }
}

fn registerDiff(b: *bench.Bench) !void {
    const diff = zg_editor.model.diff;
    inline for (.{
        .{ "editor.diff.10k_100hunks", 10_000, 100, false },
        .{ "editor.diff.100k_1khunks", 100_000, 1000, false },
        .{ "editor.diff.unrelated_100k", 100_000, 0, true },
    }) |c| {
        const a_text = try genLines(b.gpa, c[1]);
        defer b.gpa.free(a_text);
        const b_text = if (c[3]) blk: {
            const t = try b.gpa.dupe(u8, a_text);
            std.mem.reverse(u8, t);
            break :blk t;
        } else try mutateLines(b.gpa, a_text, c[2]);
        defer b.gpa.free(b_text);
        var p: DiffPair = .{ .a = try .fromBytes(b.gpa, a_text), .b = try .fromBytes(b.gpa, b_text) };
        defer p.a.deinit(b.gpa);
        defer p.b.deinit(b.gpa);
        _ = diff;
        try b.run(c[0], &p, diffPair);
    }
}

fn register(b: *bench.Bench) !void {
    for (pending) |name| if (b.opts.filter == null or std.mem.indexOf(u8, name, b.opts.filter.?) != null)
        std.debug.print("{s:<40} skipped (not implemented yet)\n", .{name});

    const text = try genLines(b.gpa, 100_000);
    defer b.gpa.free(text);
    inline for (.{
        .{ "editor.buffer.insert_char_100k", insertChar },
        .{ "editor.buffer.type_char_100k", typeChar },
        .{ "editor.buffer.offset_to_point", offsetToPoint },
        .{ "editor.buffer.offset_to_utf16", offsetToUtf16 },
        .{ "editor.buffer.replace_1k_cursors", replace1k },
        .{ "editor.snapshot.retain_release", retainRelease },
        .{ "editor.undo.10k_group", undo10k },
    }) |entry| {
        const d = try Doc.init(b.gpa, text);
        defer d.deinit(b.gpa);
        try b.run(entry[0], d, entry[1]);
    }
    try registerDiff(b);
}
