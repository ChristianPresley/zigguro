//! The slider (indent) heuristic. A run of only-inserted or only-deleted
//! lines between equal runs can slide up or down while the line it leaves
//! equals the line it takes in. Among the valid positions, the one with
//! the lowest score wins (ties go to the lowest position, git's default):
//! - the line after the run indented deeper than the run's first line: +3;
//! - each boundary that splits a line from its deeper-indented successor:
//!   +2;
//! - a blank first line: +1; a blank last line: -1.
//! So inserted functions come out as whole functions with their trailing
//! blank line, as git's indent heuristic aims for.

const std = @import("std");
const script = @import("script.zig");
const line_ids = @import("line_ids.zig");

const Edit = script.Edit;
const LineSource = line_ids.LineSource;

/// Shifts the boundaries of pure insert/delete runs in place and returns
/// the script's new length (runs that shrank to nothing are removed and
/// neighbours merged). `ids_*` are the interned lines the script was
/// computed on; scoring reads the lines themselves.
pub fn slideHunks(edits: []Edit, ids_a: []const u32, ids_b: []const u32, a: *const LineSource, b: *const LineSource) usize {
    slide(edits, ids_a, ids_b, a, b);
    var w: usize = 0;
    for (edits) |e| {
        if (e.len == 0) continue;
        if (w > 0 and edits[w - 1].kind == e.kind) {
            edits[w - 1].len += e.len;
            continue;
        }
        edits[w] = e;
        w += 1;
    }
    return w;
}

fn slide(edits: []Edit, ids_a: []const u32, ids_b: []const u32, a: *const LineSource, b: *const LineSource) void {
    var i: usize = 1;
    while (i + 1 < edits.len) : (i += 1) {
        const g = edits[i];
        if (g.kind == .equal or edits[i - 1].kind != .equal or edits[i + 1].kind != .equal) continue;
        const ids = if (g.kind == .delete) ids_a else ids_b;
        const src = if (g.kind == .delete) a else b;
        const start: usize = if (g.kind == .delete) g.a_start else g.b_start;
        const len: usize = g.len;
        // How far the run can move up (into the equal run before) and down.
        var up: usize = 0;
        while (up < edits[i - 1].len and ids[start - up - 1] == ids[start + len - up - 1]) up += 1;
        var down: usize = 0;
        while (down < edits[i + 1].len and ids[start + down] == ids[start + len + down]) down += 1;
        if (up == 0 and down == 0) continue;
        var best: usize = start - up;
        var best_score: i32 = std.math.maxInt(i32);
        var s = start - up;
        while (s <= start + down) : (s += 1) {
            const sc = score(src, s, len);
            if (sc < best_score) {
                best_score = sc;
                best = s;
            }
        }
        if (best == start) continue;
        // Move by `best - start`, shrinking one equal run and growing the
        // other.
        if (best < start) {
            const d: u32 = @intCast(start - best);
            edits[i - 1].len -= d;
            edits[i].a_start -= d;
            edits[i].b_start -= d;
            edits[i + 1].a_start -= d;
            edits[i + 1].b_start -= d;
            edits[i + 1].len += d;
        } else {
            const d: u32 = @intCast(best - start);
            edits[i - 1].len += d;
            edits[i].a_start += d;
            edits[i].b_start += d;
            edits[i + 1].a_start += d;
            edits[i + 1].b_start += d;
            edits[i + 1].len -= d;
        }
    }
}

/// Indentation in columns (tab = 4); null for a blank line.
fn indent(src: *const LineSource, i: usize) ?u32 {
    const l = src.line(i);
    var n: u32 = 0;
    for (l) |c| switch (c) {
        ' ' => n += 1,
        '\t' => n += 4,
        else => return n,
    };
    return null;
}

/// Indent of line `i`, or of the nearest non-blank line after it.
fn indentAfter(src: *const LineSource, i_in: usize) u32 {
    var i = i_in;
    while (i < src.count()) : (i += 1) if (indent(src, i)) |n| return n;
    return 0;
}

fn score(src: *const LineSource, s: usize, len: usize) i32 {
    var sc: i32 = 0;
    const e = s + len;
    const first = indentAfter(src, s);
    if (e < src.count()) {
        if (indentAfter(src, e) > first) sc += 3;
    }
    // Boundaries: between s-1 and s, and between e-1 and e.
    if (s > 0) if (indent(src, s - 1)) |p| if (indent(src, s)) |q| if (q > p) {
        sc += 2;
    };
    if (e < src.count()) if (indent(src, e - 1)) |p| if (indent(src, e)) |q| if (q > p) {
        sc += 2;
    };
    if (indent(src, s) == null) sc += 1;
    if (indent(src, e - 1) == null) sc -= 1;
    return sc;
}
