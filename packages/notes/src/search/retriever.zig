//! The `Retriever` interface (E08.F06.S03.T01): one ranked-retrieval
//! backend (BM25F today, semantic later) behind a common call, and
//! `hybrid`, which fuses several with weighted reciprocal rank fusion.

const std = @import("std");
const query = @import("query.zig");
const bm25 = @import("bm25.zig");
const search_index = @import("search_index.zig");
const exec = @import("exec.zig");

const Allocator = std.mem.Allocator;
const FileId = @import("../vault/note.zig").FileId;
const QueryAst = query.QueryAst;

pub const max_highlights = 8;

pub const Snippet = struct {
    /// Byte range in the note.
    range: [2]u32 = .{ 0, 0 },
    /// 0-based line of `range[0]`.
    line: u32 = 0,
    /// Matched ranges inside `range`.
    highlights: [max_highlights][2]u32 = undefined,
    n_highlights: u8 = 0,
};

pub const Scored = struct {
    note: FileId,
    score: f32,
    snippets: [3]Snippet = undefined,
    n_snippets: u8 = 0,
};

pub const Retriever = struct {
    ctx: *anyopaque,
    name: []const u8,
    /// Appends the top `k` notes for `q` (`raw` is the query text, for
    /// backends that embed it), best first.
    retrieve: *const fn (ctx: *anyopaque, q: *const QueryAst, raw: []const u8, k: u32, out: *std.ArrayList(Scored)) anyerror!void,
};

/// BM25F over a search index (results allocate in the index's allocator).
pub fn bm25Retriever(s: *search_index.SearchIndex, params: bm25.Bm25Params) Retriever {
    s.params = params;
    return .{ .ctx = s, .name = "bm25", .retrieve = bm25Retrieve };
}

fn bm25Retrieve(ctx: *anyopaque, q: *const QueryAst, raw: []const u8, k: u32, out: *std.ArrayList(Scored)) anyerror!void {
    _ = raw;
    const s: *search_index.SearchIndex = @ptrCast(@alignCast(ctx));
    try exec.search(s, s.gpa, q, k, out);
}

/// The RRF constant.
pub const rrf_k: f32 = 60;

/// Fuses `retrievers` with weighted reciprocal rank fusion:
/// score(d) = Σ_r w_r / (60 + rank_r(d)), ranks from 1. Snippets come
/// from the first retriever that returned the note. `out` must use `gpa`.
pub fn hybrid(gpa: Allocator, retrievers: []const Retriever, weights: []const f32, q: *const QueryAst, raw: []const u8, k: u32, out: *std.ArrayList(Scored)) !void {
    std.debug.assert(retrievers.len == weights.len);
    var fused: std.AutoArrayHashMapUnmanaged(u64, Scored) = .empty;
    defer fused.deinit(gpa);
    var buf: std.ArrayList(Scored) = .empty;
    defer buf.deinit(gpa);
    const depth = @max(k, 50);
    for (retrievers, weights) |r, w| {
        buf.clearRetainingCapacity();
        try r.retrieve(r.ctx, q, raw, depth, &buf);
        for (buf.items, 1..) |hit, rank| {
            const gop = try fused.getOrPut(gpa, @bitCast(hit.note));
            if (!gop.found_existing) {
                gop.value_ptr.* = hit;
                gop.value_ptr.score = 0;
            }
            gop.value_ptr.score += w / (rrf_k + @as(f32, @floatFromInt(rank)));
        }
    }
    const items = fused.values();
    // Stable: equal scores keep first-seen order.
    std.sort.insertion(Scored, items, {}, struct {
        fn lt(_: void, a: Scored, b: Scored) bool {
            return a.score > b.score;
        }
    }.lt);
    try out.appendSlice(gpa, items[0..@min(k, items.len)]);
}

const Fake = struct {
    ids: []const u32,
    fn retrieve(ctx: *anyopaque, q: *const QueryAst, raw: []const u8, k: u32, out: *std.ArrayList(Scored)) anyerror!void {
        _ = q;
        _ = raw;
        const f: *const Fake = @ptrCast(@alignCast(ctx));
        for (f.ids[0..@min(k, f.ids.len)]) |i| try out.append(std.testing.allocator, .{ .note = .{ .index = i, .gen = 0 }, .score = 1 });
    }
    fn retriever(f: *const Fake, name: []const u8) Retriever {
        return .{ .ctx = @constCast(f), .name = name, .retrieve = retrieve };
    }
};

test "hybrid: reciprocal rank fusion ordering" {
    const gpa = std.testing.allocator;
    const a: Fake = .{ .ids = &.{ 1, 2, 3, 4 } };
    const b: Fake = .{ .ids = &.{ 3, 1, 5 } };
    const q: QueryAst = .{ .and_ = &.{} };
    var out: std.ArrayList(Scored) = .empty;
    defer out.deinit(gpa);
    try hybrid(gpa, &.{ a.retriever("a"), b.retriever("b") }, &.{ 1, 1 }, &q, "", 10, &out);
    // 1: 1/61 + 1/62; 3: 1/63 + 1/61; 2: 1/62; 5: 1/63; 4: 1/64.
    const want = [_]u32{ 1, 3, 2, 5, 4 };
    try std.testing.expectEqual(want.len, out.items.len);
    for (want, out.items) |w, got| try std.testing.expectEqual(w, got.note.index);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 61.0 + 1.0 / 62.0), out.items[0].score, 1e-6);
    // Weights shift the order.
    out.clearRetainingCapacity();
    try hybrid(gpa, &.{ a.retriever("a"), b.retriever("b") }, &.{ 0.1, 1 }, &q, "", 2, &out);
    try std.testing.expectEqual(@as(u32, 3), out.items[0].note.index);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
}
