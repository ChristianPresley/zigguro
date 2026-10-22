//! Unified diff output (`diff -u` / `git diff` format): `---`/`+++`
//! headers, `@@ -l,s +l,s @@` hunk headers (1-based; the count is omitted
//! when it is 1, and a zero-length side names the line before it), and
//! `\ No newline at end of file` after a final line without a terminator.
//! Lines keep their original terminators.

const std = @import("std");
const script = @import("script.zig");
const hunks_mod = @import("hunks.zig");
const line_ids = @import("line_ids.zig");

const Edit = script.Edit;
const LineHunk = hunks_mod.LineHunk;
const LineSource = line_ids.LineSource;

/// Writes `hunks` (built with context from `edits`) as a unified diff.
/// `names` are the old and new paths as they should appear after `--- `
/// and `+++ ` (e.g. `a/x.zig`).
pub fn writeUnified(w: *std.Io.Writer, edits: []const Edit, hunks: []const LineHunk, a: *const LineSource, b: *const LineSource, names: [2][]const u8) std.Io.Writer.Error!void {
    if (hunks.len == 0) return;
    try w.print("--- {s}\n+++ {s}\n", .{ names[0], names[1] });
    var ei: usize = 0;
    for (hunks) |h| {
        try w.writeAll("@@ -");
        try span(w, h.old);
        try w.writeAll(" +");
        try span(w, h.new);
        try w.writeAll(" @@\n");
        const a_end = h.old.start + h.old.count;
        const b_end = h.new.start + h.new.count;
        while (ei < edits.len) {
            const e = edits[ei];
            const ea_end = e.a_start + aLen(e);
            const eb_end = e.b_start + bLen(e);
            const before = if (e.kind == .insert) eb_end <= h.new.start else ea_end <= h.old.start;
            if (before) {
                ei += 1;
                continue;
            }
            const after = if (e.kind == .insert) e.b_start >= b_end else e.a_start >= a_end;
            if (after) break;
            switch (e.kind) {
                .equal => {
                    for (@max(e.a_start, h.old.start)..@min(ea_end, a_end)) |k| try lineOut(w, ' ', a, k);
                    // An equal run can hold the next hunk's leading context.
                    if (ea_end > a_end) break;
                },
                .delete => for (e.a_start..ea_end) |k| try lineOut(w, '-', a, k),
                .insert => for (e.b_start..eb_end) |k| try lineOut(w, '+', b, k),
            }
            ei += 1;
        }
    }
}

fn aLen(e: Edit) u64 {
    return if (e.kind == .insert) 0 else e.len;
}

fn bLen(e: Edit) u64 {
    return if (e.kind == .delete) 0 else e.len;
}

fn span(w: *std.Io.Writer, s: hunks_mod.LineSpan) std.Io.Writer.Error!void {
    const start = if (s.count == 0) s.start else s.start + 1;
    if (s.count == 1) return w.print("{d}", .{start});
    try w.print("{d},{d}", .{ start, s.count });
}

fn lineOut(w: *std.Io.Writer, prefix: u8, src: *const LineSource, i: usize) std.Io.Writer.Error!void {
    try w.writeByte(prefix);
    try w.writeAll(src.lineWithEol(i));
    if (src.missingEol(i)) try w.writeAll("\n\\ No newline at end of file\n");
}
