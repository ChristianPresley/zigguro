//! Gutter lanes (E05.F05.S03.T01, first lane): the SCM bar, from a
//! `DiffModel`'s hunks (the dirty diff against the file on disk or a
//! revision).
//!
//! Per visible line the bar says whether the line was added or modified;
//! a deletion has no line of its own and shows as a mark on the boundary
//! above the line that follows it (below the last line when nothing
//! follows). Hunks are sorted by their new-side start, so the visible
//! rows' marks come from a binary search plus a walk over the hunks that
//! overlap them.

const std = @import("std");
const diff_model = @import("../model/diff/diff_model.zig");
const hunks_mod = @import("../model/diff/hunks.zig");

const LineHunk = hunks_mod.LineHunk;

/// The lanes the gutter can show, in default order.
pub const GutterLane = enum { breakpoints, line_numbers, glyphs, scm, folding };

/// Where the SCM bar reads its hunks.
pub const ScmGutterSource = struct {
    ctx: *const anyopaque,
    hunksFn: *const fn (ctx: *const anyopaque) []const LineHunk,
    /// Bumped when the hunks change (part of the editor's paint hash).
    versionFn: *const fn (ctx: *const anyopaque) u64,

    pub fn hunks(s: *const ScmGutterSource) []const LineHunk {
        return s.hunksFn(s.ctx);
    }

    pub fn version(s: *const ScmGutterSource) u64 {
        return s.versionFn(s.ctx);
    }

    /// The hunks of `m`.
    pub fn of(m: *const diff_model.DiffModel) ScmGutterSource {
        const F = struct {
            fn h(ctx: *const anyopaque) []const LineHunk {
                const dm: *const diff_model.DiffModel = @ptrCast(@alignCast(ctx));
                return dm.hunks();
            }
            fn v(ctx: *const anyopaque) u64 {
                const dm: *const diff_model.DiffModel = @ptrCast(@alignCast(ctx));
                return dm.version() *% 2 +% @intFromBool(dm.fullPending());
            }
        };
        return .{ .ctx = m, .hunksFn = F.h, .versionFn = F.v };
    }
};

/// The bar beside one line.
pub const ScmBar = enum(u2) { none, added, modified };

/// One line's SCM marks.
pub const ScmRow = struct {
    bar: ScmBar = .none,
    /// Lines were deleted between this line and the one above it.
    deleted_above: bool = false,
    /// Lines were deleted after this line, the last.
    deleted_below: bool = false,
};

/// Fills `out[i]` with the marks of line `first + i`, for a text of
/// `line_count` lines.
pub fn scmRows(hunks: []const LineHunk, first: u64, line_count: u64, out: []ScmRow) void {
    @memset(out, .{});
    if (out.len == 0) return;
    const end = first + out.len;
    // First hunk whose new span (a deletion counts as its start line)
    // reaches `first`.
    var lo: usize = 0;
    var hi: usize = hunks.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const h = hunks[mid].new;
        if (h.start + @max(h.count, 1) <= first) lo = mid + 1 else hi = mid;
    }
    for (hunks[lo..]) |h| {
        // A deletion after the last line marks the last line.
        if (h.new.start > end or (h.new.start == end and end < line_count)) break;
        if (h.new.count == 0) {
            if (h.new.start < line_count) {
                if (h.new.start >= first) out[h.new.start - first].deleted_above = true;
            } else if (line_count > 0 and line_count - 1 >= first and line_count - 1 < end) {
                out[line_count - 1 - first].deleted_below = true;
            }
            continue;
        }
        const bar: ScmBar = if (h.old.count == 0) .added else .modified;
        var l = @max(h.new.start, first);
        while (l < @min(h.new.start + h.new.count, end)) : (l += 1) out[l - first].bar = bar;
    }
}

const testing = std.testing;

fn hunk(old_start: u64, old_count: u64, new_start: u64, new_count: u64) LineHunk {
    return .{ .old = .{ .start = old_start, .count = old_count }, .new = .{ .start = new_start, .count = new_count } };
}

test "gutter: scm markers from hunks" {
    const hs = [_]LineHunk{
        hunk(0, 0, 1, 2), // lines 1-2 added
        hunk(3, 1, 5, 1), // line 5 modified
        hunk(6, 2, 7, 0), // deleted above line 7
        hunk(9, 1, 9, 0), // deleted at the end (9 lines)
    };
    var rows: [9]ScmRow = undefined;
    scmRows(&hs, 0, 9, &rows);
    var got: [9][]const u8 = undefined;
    for (rows, 0..) |r, i| got[i] = switch (r.bar) {
        .none => if (r.deleted_above) "^" else if (r.deleted_below) "v" else ".",
        .added => "+",
        .modified => "~",
    };
    const want = [_][]const u8{ ".", "+", "+", ".", ".", "~", ".", "^", "v" };
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);

    // A window in the middle sees only its own lines.
    var mid: [3]ScmRow = undefined;
    scmRows(&hs, 2, 9, &mid);
    try testing.expectEqual(ScmBar.added, mid[0].bar);
    try testing.expectEqual(ScmBar.none, mid[1].bar);
    try testing.expectEqual(ScmBar.none, mid[2].bar);
    scmRows(&hs, 6, 9, &mid);
    try testing.expect(!mid[0].deleted_above);
    try testing.expect(mid[1].deleted_above);
    try testing.expect(mid[2].deleted_below);
}

test "gutter: scm source over a DiffModel" {
    const gpa = testing.allocator;
    const Document = @import("../model/document.zig").Document;
    const base = try Document.initBytes(gpa, @enumFromInt(1), "a\nb\nc\n");
    defer base.deinit();
    const doc = try Document.initBytes(gpa, @enumFromInt(2), "a\nB\nc\nd\n");
    defer doc.deinit();
    const m = try diff_model.DiffModel.init(gpa, null, base.snapshot(), doc, .{});
    defer m.deinit();
    try m.completeFull();
    const src = ScmGutterSource.of(m);
    var rows: [4]ScmRow = undefined;
    scmRows(src.hunks(), 0, 4, &rows);
    try testing.expectEqual(ScmBar.none, rows[0].bar);
    try testing.expectEqual(ScmBar.modified, rows[1].bar);
    try testing.expectEqual(ScmBar.none, rows[2].bar);
    try testing.expectEqual(ScmBar.added, rows[3].bar);
}
