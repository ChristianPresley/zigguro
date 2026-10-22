//! Visual mode areas: the text a characterwise, linewise or blockwise
//! selection covers, both for operators and for display (the cursor's
//! character is part of the area, unlike an editor selection's end).

const std = @import("std");
const text_mod = @import("text.zig");
const sel_mod = @import("../../model/edit/selection.zig");

const Text = text_mod.Text;
const Selection = sel_mod.Selection;

/// The block's columns (character indexes, inclusive); `to_eol` after `$`.
pub fn blockColumns(x: Text, c: anytype) struct { left: u32, right: u32, to_eol: bool } {
    const a = x.column(c.anchor);
    const b = x.column(c.pos);
    return .{ .left = @min(a, b), .right = @max(a, b), .to_eol = c.want == null };
}

/// The end of the area on the character at `p`: after it, or after the
/// line break when `p` is a line end.
fn inclEnd(x: Text, p: u64) u64 {
    if (!x.atEol(p)) return x.after(p);
    return x.nextLineStart(x.lineOf(p));
}

/// Iterates the ranges of an area: one for characterwise and linewise,
/// one per line for a block.
pub const Ranges = struct {
    x: Text,
    line: u64,
    last: u64,
    block: bool,
    done: bool = false,
    single: struct { u64, u64 } = .{ 0, 0 },
    left: u32 = 0,
    right: u32 = 0,
    to_eol: bool = false,

    pub fn init(x: Text, mode: anytype, c: anytype) Ranges {
        const lo = @min(c.pos, c.anchor);
        const hi = @max(c.pos, c.anchor);
        var r: Ranges = .{ .x = x, .line = x.lineOf(lo), .last = x.lineOf(hi), .block = mode == .visual_block };
        switch (mode) {
            .visual_line => r.single = .{ x.lineStart(r.line), x.lineEnd(r.last) },
            .visual_block => {
                const cols = blockColumns(x, c);
                r.left = cols.left;
                r.right = cols.right;
                r.to_eol = cols.to_eol;
            },
            else => r.single = .{ lo, @min(inclEnd(x, hi), x.len) },
        }
        return r;
    }

    pub fn next(r: *Ranges) ?struct { start: u64, end: u64 } {
        if (r.done) return null;
        if (!r.block) {
            r.done = true;
            return .{ .start = r.single[0], .end = r.single[1] };
        }
        if (r.line > r.last) return null;
        const l = r.line;
        r.line += 1;
        const s = r.x.atColumn(l, r.left, true);
        const e = if (r.to_eol) r.x.lineEnd(l) else r.x.atColumn(l, r.right + 1, true);
        return .{ .start = s, .end = @max(s, e) };
    }
};

/// The selections that show cursor `c`'s area: a range ending after the
/// cursor's character, with the head on the cursor's side.
pub fn display(x: Text, linewise: bool, block: bool, c: anytype, out: *std.ArrayList(Selection), gpa: std.mem.Allocator) !void {
    const forward = c.pos >= c.anchor;
    if (block) {
        var it = Ranges.init(x, @as(enum { visual, visual_line, visual_block }, .visual_block), c);
        while (it.next()) |r| try out.append(gpa, if (forward) .{ .anchor = r.start, .head = r.end } else .{ .anchor = r.end, .head = r.start });
        return;
    }
    const lo = @min(c.pos, c.anchor);
    const hi = @max(c.pos, c.anchor);
    var s = lo;
    var e = @min(inclEnd(x, hi), x.len);
    if (linewise) {
        s = x.lineStart(x.lineOf(lo));
        e = x.nextLineStart(x.lineOf(hi));
    }
    try out.append(gpa, if (forward) .{ .anchor = s, .head = e } else .{ .anchor = e, .head = s });
}
