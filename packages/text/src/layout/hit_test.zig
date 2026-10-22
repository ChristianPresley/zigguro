//! Hit testing, caret positions, selection rectangles and visual caret
//! movement over a laid-out `Line`. Graphemes are sorted by x, so hit
//! testing is a binary search; carets are in logical order.

const std = @import("std");
const Allocator = std.mem.Allocator;
const style = @import("style.zig");
const Line = style.Line;
const Hit = style.Hit;
const Affinity = style.Affinity;
const VisGrapheme = style.VisGrapheme;
const Caret = style.Caret;
const CaretPos = style.CaretPos;

/// The caret stop nearest to `x` (relative to the line's origin). Left of
/// a grapheme's middle maps to its left edge: the start of a left-to-right
/// grapheme or the end of a right-to-left one.
pub fn hitTest(l: *const Line, x: f32) Hit {
    const gs = l.graphemes;
    const inside = x >= 0 and x < l.width;
    if (gs.len == 0) return .{ .offset = l.start, .affinity = .downstream, .inside = inside };
    // First grapheme whose right edge is past x.
    var lo: usize = 0;
    var hi: usize = gs.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (gs[mid].x1 <= x) lo = mid + 1 else hi = mid;
    }
    const g = gs[@min(lo, gs.len - 1)];
    const left = x < (g.x0 + g.x1) / 2;
    // The left edge of an LTR grapheme is its start (leading, downstream);
    // its right edge is its end (trailing, upstream). RTL mirrors that.
    return if (left != g.rtl)
        .{ .offset = g.start, .affinity = .downstream, .inside = inside }
    else
        .{ .offset = g.end, .affinity = .upstream, .inside = inside };
}

/// Index of the caret stop at `offset`, or at the grapheme boundary before
/// it when `offset` falls inside a grapheme.
fn caretIndex(l: *const Line, offset: u32) usize {
    const cs = l.carets;
    var lo: usize = 0;
    var hi: usize = cs.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (cs[mid].offset <= offset) lo = mid + 1 else hi = mid;
    }
    return if (lo == 0) 0 else lo - 1;
}

/// The x of the caret at `offset`. At a direction boundary an offset has
/// two positions: `upstream` is next to the character before it,
/// `downstream` next to the character after it.
pub fn caretX(l: *const Line, offset: u32, affinity: Affinity) f32 {
    if (l.carets.len == 0) return 0;
    const c = l.carets[caretIndex(l, offset)];
    return if (affinity == .upstream) c.x_up else c.x;
}

/// Appends the x ranges covering bytes `[start, end)`, merged and ordered
/// by x. A partly selected grapheme counts as selected.
pub fn selectionRects(l: *const Line, start: u32, end: u32, out: *std.ArrayList([2]f32), gpa: Allocator) !void {
    if (start >= end) return;
    const first = out.items.len;
    for (l.graphemes) |g| {
        if (g.end <= start or g.start >= end) continue;
        if (out.items.len > first) {
            const last = &out.items[out.items.len - 1];
            if (g.x0 <= last[1] + 0.01) {
                last[1] = @max(last[1], g.x1);
                continue;
            }
        }
        try out.append(gpa, .{ g.x0, g.x1 });
    }
}

/// The caret position one grapheme to the left or right of `pos`, or null
/// at the line's edge. The affinity says which of an offset's two places
/// the caret is drawn at (see `caretX`), so walking across a direction
/// boundary visits every visual stop. Zero-width graphemes are stepped
/// over; the result is always a grapheme boundary.
pub fn moveVisual(l: *const Line, pos: CaretPos, dir: enum { left, right }) ?CaretPos {
    const gs = l.graphemes;
    if (gs.len == 0) return null;
    const x = caretX(l, pos.offset, pos.affinity);
    const eps = 0.01;
    switch (dir) {
        .right => {
            // The first grapheme starting at or after x.
            var lo: usize = 0;
            var hi: usize = gs.len;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                if (gs[mid].x0 < x - eps) lo = mid + 1 else hi = mid;
            }
            while (lo < gs.len and gs[lo].x1 <= x + eps) lo += 1;
            if (lo == gs.len) return null;
            const g = gs[lo];
            // Crossing g rightwards ends at its right edge.
            return if (g.rtl) .{ .offset = g.start, .affinity = .downstream } else .{ .offset = g.end, .affinity = .upstream };
        },
        .left => {
            // The last grapheme ending at or before x.
            var lo: usize = 0;
            var hi: usize = gs.len;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                if (gs[mid].x1 <= x + eps) lo = mid + 1 else hi = mid;
            }
            while (lo > 0 and gs[lo - 1].x0 >= x - eps) lo -= 1;
            if (lo == 0) return null;
            const g = gs[lo - 1];
            return if (g.rtl) .{ .offset = g.end, .affinity = .upstream } else .{ .offset = g.start, .affinity = .downstream };
        },
    }
}
