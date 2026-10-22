//! Moved-block detection: a deleted run and an inserted run with the same
//! whitespace-trimmed lines (at least `min_lines` lines and `min_chars`
//! characters) are reported as one move. Each run is matched at most once,
//! nearest first.

const std = @import("std");
const script = @import("script.zig");
const hunks_mod = @import("hunks.zig");
const line_ids = @import("line_ids.zig");

const Allocator = std.mem.Allocator;
const Edit = script.Edit;
const LineSource = line_ids.LineSource;
const LineSpan = hunks_mod.LineSpan;

/// Detection thresholds.
pub const Options = struct { min_lines: u32 = 3, min_chars: u32 = 60 };

/// A block deleted at `from` (old lines) and inserted at `to` (new lines).
pub const Move = struct { from: LineSpan, to: LineSpan };

/// Moves between the delete and insert runs of `edits`.
pub fn detectMoves(gpa: Allocator, edits: []const Edit, a: *const LineSource, b: *const LineSource, o: Options) Allocator.Error![]Move {
    const Run = struct { start: u32, len: u32, hash: u64, used: bool = false };
    var dels: std.ArrayList(Run) = .empty;
    defer dels.deinit(gpa);
    var inss: std.ArrayList(Run) = .empty;
    defer inss.deinit(gpa);
    for (edits) |e| {
        if (e.kind == .equal or e.len < o.min_lines) continue;
        const src = if (e.kind == .delete) a else b;
        const start: usize = if (e.kind == .delete) e.a_start else e.b_start;
        var chars: usize = 0;
        var h = std.hash.XxHash3.init(0);
        for (start..start + e.len) |k| {
            const t = std.mem.trim(u8, src.line(k), " \t");
            chars += t.len;
            h.update(t);
            h.update("\n");
        }
        if (chars < o.min_chars) continue;
        const r: Run = .{ .start = @intCast(start), .len = e.len, .hash = h.final() };
        if (e.kind == .delete) try dels.append(gpa, r) else try inss.append(gpa, r);
    }
    var out: std.ArrayList(Move) = .empty;
    errdefer out.deinit(gpa);
    for (dels.items) |d| {
        var best: ?usize = null;
        for (inss.items, 0..) |ins, k| {
            if (ins.used or ins.len != d.len or ins.hash != d.hash) continue;
            if (!sameTrimmed(a, d.start, b, ins.start, d.len)) continue;
            const dist = if (ins.start > d.start) ins.start - d.start else d.start - ins.start;
            if (best == null or dist < blk: {
                const bb = inss.items[best.?];
                break :blk if (bb.start > d.start) bb.start - d.start else d.start - bb.start;
            }) best = k;
        }
        if (best) |k| {
            inss.items[k].used = true;
            try out.append(gpa, .{ .from = .{ .start = d.start, .count = d.len }, .to = .{ .start = inss.items[k].start, .count = d.len } });
        }
    }
    return out.toOwnedSlice(gpa);
}

fn sameTrimmed(a: *const LineSource, as: usize, b: *const LineSource, bs: usize, n: usize) bool {
    for (0..n) |k| {
        if (!std.mem.eql(u8, std.mem.trim(u8, a.line(as + k), " \t"), std.mem.trim(u8, b.line(bs + k), " \t"))) return false;
    }
    return true;
}
