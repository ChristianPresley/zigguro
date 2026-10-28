//! Top-k ranking over large candidate lists (E04.F05.S04.T01, E14 budget
//! `workspace.fuzzy_find_1m`): what a Go to File provider runs on its
//! worker to score up to millions of paths per keystroke.
//!
//! - `charMask` gives each candidate a 64-bit set of the letters, digits
//!   and separators it holds; computed once per candidate list, it rejects
//!   most non-matches with one AND before the matcher runs.
//! - `topK` splits the candidates into chunks scored concurrently on the
//!   `Io`'s workers (inline on a single-threaded `Io`), each keeping its
//!   own best `out.len` hits, then merges them. Results are deterministic:
//!   best score first, ties to the lower index.

const std = @import("std");
const matcher_mod = @import("matcher.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Matcher = matcher_mod.Matcher;

/// One ranked candidate.
pub const Hit = struct {
    score: i32,
    /// Index into the candidate list.
    idx: u32,
};

/// Whether `a` ranks before `b`.
pub fn better(a: Hit, b: Hit) bool {
    return a.score > b.score or (a.score == b.score and a.idx < b.idx);
}

fn betterCtx(_: void, a: Hit, b: Hit) bool {
    return better(a, b);
}

/// The mask bit for byte `c` (case-insensitive; 0 when `c` is not
/// tracked): ASCII letters (bits 0-25), digits (26-35), and `/`, `.`, `_`,
/// `-`, ` ` (36-40).
pub fn maskBit(c: u8) u64 {
    const l = std.ascii.toLower(c);
    return switch (l) {
        'a'...'z' => @as(u64, 1) << @intCast(l - 'a'),
        '0'...'9' => @as(u64, 1) << @intCast(26 + l - '0'),
        '/' => 1 << 36,
        '.' => 1 << 37,
        '_' => 1 << 38,
        '-' => 1 << 39,
        ' ' => 1 << 40,
        else => 0,
    };
}

/// The set of tracked bytes in `s` (see `maskBit`).
pub fn charMask(s: []const u8) u64 {
    var m: u64 = 0;
    for (s) |c| m |= maskBit(c);
    return m;
}

/// How `topK` runs.
pub const Options = struct {
    /// `charMask` of each candidate (same length as the candidates), or
    /// null to score every candidate.
    masks: ?[]const u64 = null,
    /// Concurrent chunks; 0: one per CPU (at most 16).
    workers: u32 = 0,
    /// Fewer candidates than this per chunk run in fewer chunks.
    min_chunk: usize = 32 * 1024,
};

const max_workers = 16;

const Chunk = struct {
    m: Matcher,
    query: []const u8,
    need: u64,
    items: []const []const u8,
    masks: ?[]const u64,
    first: usize,
    last: usize,
    top: []Hit,
    n: usize = 0,
    failed: bool = false,

    fn run(c: *Chunk, gpa: Allocator) void {
        if (matcher_mod.SubsequenceMatcher.is(c.m)) return c.scan(gpa, true);
        c.scan(gpa, false);
    }

    /// `direct`: the default matcher, called without highlights.
    fn scan(c: *Chunk, gpa: Allocator, comptime direct: bool) void {
        var hl: std.ArrayList([2]u32) = .empty;
        defer hl.deinit(gpa);
        var i = c.first;
        while (i < c.last) : (i += 1) {
            if (c.masks) |ms| if (ms[i] & c.need != c.need) continue;
            const s = if (direct) matcher_mod.scoreOnly(c.query, c.items[i]) orelse continue else blk: {
                hl.clearRetainingCapacity();
                break :blk c.m.score(c.query, c.items[i], &hl, gpa) orelse continue;
            };
            c.n = insert(c.top, c.n, .{ .score = s, .idx = @intCast(i) });
        }
    }
};

/// Adds `h` to the best-first list `top[0..n]` (capacity `top.len`) and
/// returns the new length.
fn insert(top: []Hit, n: usize, h: Hit) usize {
    if (top.len == 0) return 0;
    if (n == top.len and !better(h, top[n - 1])) return n;
    var j = if (n == top.len) n - 1 else n;
    while (j > 0 and better(h, top[j - 1])) : (j -= 1) top[j] = top[j - 1];
    top[j] = h;
    return @min(n + 1, top.len);
}

/// Scores `items` against `query` with `m` and writes the best `out.len`
/// hits, best first, into `out`; returns how many were written. An empty
/// query ranks every candidate with the matcher's empty-query score.
pub fn topK(gpa: Allocator, io: Io, m: Matcher, query: []const u8, items: []const []const u8, out: []Hit, opts: Options) Allocator.Error!usize {
    if (out.len == 0 or items.len == 0) return 0;
    if (opts.masks) |ms| std.debug.assert(ms.len == items.len);
    const need = charMask(query);
    const cpus: u32 = if (opts.workers != 0) opts.workers else @intCast(std.Thread.getCpuCount() catch 1);
    const by_size = @max(1, items.len / @max(opts.min_chunk, 1));
    const n_chunks: usize = @min(@min(cpus, max_workers), by_size);

    var chunks: [max_workers]Chunk = undefined;
    const tops = try gpa.alloc(Hit, out.len * n_chunks);
    defer gpa.free(tops);
    const per = items.len / n_chunks;
    for (chunks[0..n_chunks], 0..) |*c, k| c.* = .{
        .m = m,
        .query = query,
        .need = need,
        .items = items,
        .masks = opts.masks,
        .first = k * per,
        .last = if (k + 1 == n_chunks) items.len else (k + 1) * per,
        .top = tops[k * out.len ..][0..out.len],
    };
    if (n_chunks == 1) {
        chunks[0].run(gpa);
    } else {
        var group: Io.Group = .init;
        for (chunks[1..n_chunks]) |*c| {
            group.concurrent(io, Chunk.run, .{ c, gpa }) catch group.async(io, Chunk.run, .{ c, gpa });
        }
        chunks[0].run(gpa);
        group.await(io) catch {};
    }

    var n: usize = 0;
    for (chunks[0..n_chunks]) |*c| for (c.top[0..c.n]) |h| {
        n = insert(out, n, h);
    };
    return n;
}

test "topK matches a sequential scan, with and without masks" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(7);
    const r = prng.random();
    const words = [_][]const u8{ "render", "src", "third_party", "blink", "core", "test", "util", "frame", "net", "http" };
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const items = try arena.alloc([]const u8, 5000);
    const masks = try arena.alloc(u64, items.len);
    for (items, masks) |*it, *mk| {
        var b: std.ArrayList(u8) = .empty;
        const parts = 1 + r.uintLessThan(usize, 5);
        for (0..parts) |p| {
            if (p > 0) try b.append(arena, '/');
            try b.appendSlice(arena, words[r.uintLessThan(usize, words.len)]);
        }
        try b.appendSlice(arena, ".cc");
        it.* = b.items;
        mk.* = charMask(it.*);
    }
    const m = matcher_mod.SubsequenceMatcher.matcher();
    var hl: std.ArrayList([2]u32) = .empty;
    defer hl.deinit(gpa);
    for ([_][]const u8{ "rndr", "tp/bl", "zz", "net.cc", "" }) |q| {
        // Reference: score everything, sort.
        var all: std.ArrayList(Hit) = .empty;
        defer all.deinit(gpa);
        for (items, 0..) |it, i| {
            hl.clearRetainingCapacity();
            if (m.score(q, it, &hl, gpa)) |s| try all.append(gpa, .{ .score = s, .idx = @intCast(i) });
        }
        std.mem.sort(Hit, all.items, {}, betterCtx);
        const want = all.items[0..@min(all.items.len, 20)];
        for ([_]?[]const u64{ null, masks }) |ms| for ([_]u32{ 1, 3 }) |w| {
            var out: [20]Hit = undefined;
            const n = try topK(gpa, std.testing.io, m, q, items, &out, .{ .masks = ms, .workers = w, .min_chunk = 100 });
            try std.testing.expectEqualSlices(Hit, want, out[0..n]);
        };
    }
}

test "charMask covers every tracked byte, case-insensitively" {
    const m = charMask("Src/Foo_bar-9.ZIG");
    for ("srcfoobar9zig/_-.") |c| try std.testing.expect(m & maskBit(c) != 0);
    try std.testing.expect(m & maskBit('q') == 0);
    try std.testing.expectEqual(@as(u64, 0), maskBit('#'));
}
