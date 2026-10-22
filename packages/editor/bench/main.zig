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
    }) |entry| {
        const d = try Doc.init(b.gpa, text);
        defer d.deinit(b.gpa);
        try b.run(entry[0], d, entry[1]);
    }
}
