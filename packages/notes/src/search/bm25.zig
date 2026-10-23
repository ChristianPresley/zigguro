//! BM25F scoring (E08.F06.S03.T01). Per query term t:
//!   idf = ln(1 + (N − n_t + 0.5) / (n_t + 0.5))
//!   tf~ = Σ_f boost_f · tf_{t,f} / (1 − b + b · len_f / avglen_f)
//!   score += idf · tf~ / (k1 + tf~)

const std = @import("std");
const postings = @import("postings.zig");

const Postings = postings.Postings;
const n_fields = postings.n_fields;

pub const Bm25Params = struct {
    k1: f32 = 1.2,
    b: f32 = 0.75,
    /// title, aliases, headings, tags, body.
    boosts: [n_fields]f32 = .{ 3.0, 3.0, 2.0, 2.0, 1.0 },
};

pub fn idf(n_docs: u32, df: u32) f32 {
    const n: f32 = @floatFromInt(n_docs);
    const d: f32 = @floatFromInt(df);
    return @log(1.0 + (n - d + 0.5) / (d + 0.5));
}

/// One field's contribution to tf~.
pub fn fieldTf(params: *const Bm25Params, field: postings.Field, tf: u16, len: u32, avg: f32) f32 {
    const fi = @intFromEnum(field);
    const ratio: f32 = if (avg > 0) @as(f32, @floatFromInt(len)) / avg else 1;
    return params.boosts[fi] * @as(f32, @floatFromInt(tf)) / (1 - params.b + params.b * ratio);
}

pub fn saturate(params: *const Bm25Params, term_idf: f32, wtf: f32) f32 {
    return term_idf * wtf / (params.k1 + wtf);
}

/// Field averages, computed once per query.
pub fn averages(p: *const Postings) [n_fields]f32 {
    var out: [n_fields]f32 = undefined;
    for (&out, 0..) |*o, fi| o.* = p.avgLen(@enumFromInt(fi));
    return out;
}

/// Adds the BM25F score of `term` to `scores` (indexed by doc slot) for
/// every doc holding it. `acc` is scratch of the same length, all zero
/// on entry and on return.
pub fn accumulate(p: *const Postings, params: *const Bm25Params, avg: *const [n_fields]f32, term: u32, acc: []f32, scores: []f32, touched: *std.ArrayList(u32), gpa: std.mem.Allocator) !void {
    const term_idf = idf(p.live, p.df.items[term]);
    touched.clearRetainingCapacity();
    for (p.lists.items[term].items) |post| {
        const d = &p.docs.items[post.doc];
        if (acc[post.doc] == 0) try touched.append(gpa, post.doc);
        acc[post.doc] += fieldTf(params, post.field, post.tf, d.len[@intFromEnum(post.field)], avg[@intFromEnum(post.field)]);
    }
    for (touched.items) |doc| {
        scores[doc] += saturate(params, term_idf, acc[doc]);
        acc[doc] = 0;
    }
}

/// The BM25F score of `doc` for `terms` (folded), or 0.
pub fn scoreDoc(p: *const Postings, params: *const Bm25Params, terms: []const []const u8, doc: u32) f32 {
    const avg = averages(p);
    const d = &p.docs.items[doc];
    var total: f32 = 0;
    for (terms) |text| {
        const t = p.termId(text) orelse continue;
        var wtf: f32 = 0;
        for (p.lists.items[t].items) |post| if (post.doc == doc) {
            wtf += fieldTf(params, post.field, post.tf, d.len[@intFromEnum(post.field)], avg[@intFromEnum(post.field)]);
        };
        if (wtf > 0) total += saturate(params, idf(p.live, p.df.items[t]), wtf);
    }
    return total;
}

test "bm25: hand-computed scores for a 5-document corpus" {
    var p: Postings = .init(std.testing.allocator);
    defer p.deinit();
    const docs = [_][2][]const u8{
        .{ "Zig", "zig is a language zig zig" },
        .{ "Rust", "rust is a language" },
        .{ "Notes", "notes about zig and rust" },
        .{ "", "the quick brown fox" },
        .{ "Zig tips", "tips" },
    };
    for (docs, 0..) |d, i| {
        const title: []const []const u8 = if (d[0].len > 0) &.{d[0]} else &.{};
        try p.setDoc(.{ .index = @intCast(i), .gen = 0 }, .{ title, &.{}, &.{}, &.{}, &.{d[1]} });
    }
    const params: Bm25Params = .{};
    // Expected values from the formulas above, computed independently
    // (body avglen 4.0, title avglen 1.0).
    const cases = [_]struct { terms: []const []const u8, doc: u32, want: f32 }{
        .{ .terms = &.{"zig"}, .doc = 0, .want = 0.43765 },
        .{ .terms = &.{"zig"}, .doc = 2, .want = 0.22227 },
        .{ .terms = &.{"zig"}, .doc = 4, .want = 0.31706 },
        .{ .terms = &.{"zig"}, .doc = 1, .want = 0 },
        .{ .terms = &.{"rust"}, .doc = 1, .want = 0.67344 },
        .{ .terms = &.{ "zig", "language" }, .doc = 0, .want = 0.76801 },
        .{ .terms = &.{"fox"}, .doc = 3, .want = 0.63013 },
        .{ .terms = &.{"tips"}, .doc = 4, .want = 1.06638 },
    };
    for (cases) |c| try std.testing.expectApproxEqAbs(c.want, scoreDoc(&p, &params, c.terms, c.doc), 1e-4);
}
