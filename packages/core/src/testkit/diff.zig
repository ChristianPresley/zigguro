//! Line diffs for golden tests: Myers' O(ND) algorithm (Myers 1986; no code
//! copied) and unified-diff output.

const std = @import("std");

/// One step of an edit script over lines.
pub const Edit = struct {
    op: Op,
    /// Line index in `a` (for `.equal`/`.delete`) or `b` (for `.insert`).
    a: u32,
    b: u32,

    /// Edit operation.
    pub const Op = enum { equal, delete, insert };
};

/// Splits `text` into lines (terminators excluded; a trailing newline does
/// not create an empty last line). Caller frees the slice.
pub fn splitLines(gpa: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(gpa);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| try lines.append(gpa, l);
    if (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0) _ = lines.pop();
    return lines.toOwnedSlice(gpa);
}

/// Inputs above this many lines in total skip Myers and diff only the
/// common prefix/suffix (keeps memory bounded for huge golden files).
pub const myers_limit = 20_000;

/// Computes a shortest edit script from `a` to `b`. Caller frees.
pub fn diffLines(gpa: std.mem.Allocator, a: []const []const u8, b: []const []const u8) ![]Edit {
    var out: std.ArrayList(Edit) = .empty;
    errdefer out.deinit(gpa);
    // Trim the common prefix and suffix first.
    var pre: usize = 0;
    while (pre < a.len and pre < b.len and std.mem.eql(u8, a[pre], b[pre])) pre += 1;
    var suf: usize = 0;
    while (suf < a.len - pre and suf < b.len - pre and std.mem.eql(u8, a[a.len - 1 - suf], b[b.len - 1 - suf])) suf += 1;
    for (0..pre) |i| try out.append(gpa, .{ .op = .equal, .a = @intCast(i), .b = @intCast(i) });
    const ma = a[pre .. a.len - suf];
    const mb = b[pre .. b.len - suf];
    if (ma.len + mb.len > myers_limit) {
        for (0..ma.len) |i| try out.append(gpa, .{ .op = .delete, .a = @intCast(pre + i), .b = @intCast(pre) });
        for (0..mb.len) |j| try out.append(gpa, .{ .op = .insert, .a = @intCast(pre + ma.len), .b = @intCast(pre + j) });
    } else {
        try myers(gpa, ma, mb, pre, &out);
    }
    for (0..suf) |i| try out.append(gpa, .{ .op = .equal, .a = @intCast(a.len - suf + i), .b = @intCast(b.len - suf + i) });
    return out.toOwnedSlice(gpa);
}

fn myers(gpa: std.mem.Allocator, a: []const []const u8, b: []const []const u8, base: usize, out: *std.ArrayList(Edit)) !void {
    const n: isize = @intCast(a.len);
    const m: isize = @intCast(b.len);
    const max: isize = n + m;
    if (max == 0) return;
    const off: isize = max;
    var v = try gpa.alloc(isize, @intCast(2 * max + 2));
    defer gpa.free(v);
    @memset(v, 0);
    var trace: std.ArrayList([]isize) = .empty;
    defer {
        for (trace.items) |t| gpa.free(t);
        trace.deinit(gpa);
    }
    var d: isize = 0;
    outer: while (d <= max) : (d += 1) {
        try trace.append(gpa, try gpa.dupe(isize, v));
        var k: isize = -d;
        while (k <= d) : (k += 2) {
            var x: isize = if (k == -d or (k != d and v[@intCast(off + k - 1)] < v[@intCast(off + k + 1)]))
                v[@intCast(off + k + 1)]
            else
                v[@intCast(off + k - 1)] + 1;
            var y = x - k;
            while (x < n and y < m and std.mem.eql(u8, a[@intCast(x)], b[@intCast(y)])) {
                x += 1;
                y += 1;
            }
            v[@intCast(off + k)] = x;
            if (x >= n and y >= m) break :outer;
        }
    }
    // Backtrack through the saved V arrays.
    var rev: std.ArrayList(Edit) = .empty;
    defer rev.deinit(gpa);
    var x = n;
    var y = m;
    var dd: isize = @as(isize, @intCast(trace.items.len)) - 1;
    while (dd >= 0) : (dd -= 1) {
        const vd = trace.items[@intCast(dd)];
        const k = x - y;
        const prev_k = if (k == -dd or (k != dd and vd[@intCast(off + k - 1)] < vd[@intCast(off + k + 1)])) k + 1 else k - 1;
        const prev_x = vd[@intCast(off + prev_k)];
        const prev_y = prev_x - prev_k;
        while (x > prev_x and y > prev_y) {
            x -= 1;
            y -= 1;
            try rev.append(gpa, .{ .op = .equal, .a = @intCast(base + @as(usize, @intCast(x))), .b = @intCast(base + @as(usize, @intCast(y))) });
        }
        if (dd > 0) {
            if (x == prev_x) {
                y -= 1;
                try rev.append(gpa, .{ .op = .insert, .a = @intCast(base + @as(usize, @intCast(x))), .b = @intCast(base + @as(usize, @intCast(y))) });
            } else {
                x -= 1;
                try rev.append(gpa, .{ .op = .delete, .a = @intCast(base + @as(usize, @intCast(x))), .b = @intCast(base + @as(usize, @intCast(y))) });
            }
        }
    }
    std.mem.reverse(Edit, rev.items);
    try out.appendSlice(gpa, rev.items);
}

/// Number of non-equal edits (the edit distance).
pub fn distance(edits: []const Edit) usize {
    var d: usize = 0;
    for (edits) |e| if (e.op != .equal) {
        d += 1;
    };
    return d;
}

/// Maximum output lines before `unifiedDiff` truncates.
pub const max_output_lines = 200;

/// Writes a unified diff (`@@ -a,b +c,d @@` hunks with `context` lines)
/// from text `a` to text `b`, truncated after 200 lines with a note.
pub fn unifiedDiff(gpa: std.mem.Allocator, a: []const u8, b: []const u8, context: u32, w: *std.Io.Writer) !void {
    const la = try splitLines(gpa, a);
    defer gpa.free(la);
    const lb = try splitLines(gpa, b);
    defer gpa.free(lb);
    const edits = try diffLines(gpa, la, lb);
    defer gpa.free(edits);
    var lines_out: usize = 0;
    var i: usize = 0;
    while (i < edits.len) {
        // Find the next change.
        while (i < edits.len and edits[i].op == .equal) i += 1;
        if (i >= edits.len) break;
        var start = i -| context;
        // Extend the hunk while changes are within 2*context of each other.
        var end = i;
        var j = i;
        while (j < edits.len) {
            if (edits[j].op != .equal) {
                end = j + 1;
                j += 1;
                continue;
            }
            var run: usize = 0;
            while (j + run < edits.len and edits[j + run].op == .equal) run += 1;
            if (j + run >= edits.len or run > 2 * context) break;
            j += run;
        }
        const stop = @min(edits.len, end + context);
        if (start > 0 and start < i and edits[start].op != .equal) start = i;
        // Hunk header.
        var a_start: usize = 0;
        var b_start: usize = 0;
        var a_len: usize = 0;
        var b_len: usize = 0;
        var first = true;
        for (edits[start..stop]) |e| {
            if (first) {
                a_start = e.a;
                b_start = e.b;
                first = false;
            }
            switch (e.op) {
                .equal => {
                    a_len += 1;
                    b_len += 1;
                },
                .delete => a_len += 1,
                .insert => b_len += 1,
            }
        }
        try w.print("@@ -{d},{d} +{d},{d} @@\n", .{ if (a_len == 0) a_start else a_start + 1, a_len, if (b_len == 0) b_start else b_start + 1, b_len });
        lines_out += 1;
        for (edits[start..stop]) |e| {
            if (lines_out >= max_output_lines) {
                try w.writeAll("... diff truncated ...\n");
                return;
            }
            switch (e.op) {
                .equal => try w.print(" {s}\n", .{la[e.a]}),
                .delete => try w.print("-{s}\n", .{la[e.a]}),
                .insert => try w.print("+{s}\n", .{lb[e.b]}),
            }
            lines_out += 1;
        }
        i = stop;
    }
}

/// Applies a unified diff produced by `unifiedDiff` to `a` (test helper).
/// Caller frees the result.
pub fn applyUnified(gpa: std.mem.Allocator, a: []const u8, patch: []const u8) ![]u8 {
    const la = try splitLines(gpa, a);
    defer gpa.free(la);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var pos: usize = 0; // next line of `a` to copy
    var it = std.mem.splitScalar(u8, patch, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        switch (line[0]) {
            '@' => {
                const minus = std.mem.indexOfScalar(u8, line, '-').?;
                const comma = std.mem.indexOfScalarPos(u8, line, minus, ',').?;
                const start = try std.fmt.parseInt(usize, line[minus + 1 .. comma], 10);
                const len_end = std.mem.indexOfScalarPos(u8, line, comma, ' ').?;
                const len = try std.fmt.parseInt(usize, line[comma + 1 .. len_end], 10);
                const s0 = if (len == 0) start else start - 1;
                while (pos < s0) : (pos += 1) try appendLine(gpa, &out, la[pos]);
            },
            ' ' => {
                try appendLine(gpa, &out, line[1..]);
                pos += 1;
            },
            '-' => pos += 1,
            '+' => try appendLine(gpa, &out, line[1..]),
            else => return error.BadPatch,
        }
    }
    while (pos < la.len) : (pos += 1) try appendLine(gpa, &out, la[pos]);
    return out.toOwnedSlice(gpa);
}

fn appendLine(gpa: std.mem.Allocator, out: *std.ArrayList(u8), l: []const u8) !void {
    try out.appendSlice(gpa, l);
    try out.append(gpa, '\n');
}

test "diff: known Myers examples" {
    const gpa = std.testing.allocator;
    const a = [_][]const u8{ "A", "B", "C", "A", "B", "B", "A" };
    const b = [_][]const u8{ "C", "B", "A", "B", "A", "C" };
    const edits = try diffLines(gpa, &a, &b);
    defer gpa.free(edits);
    try std.testing.expectEqual(@as(usize, 5), distance(edits));
}

test "diff: unified output" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try unifiedDiff(gpa, "a\nb\nc\nd\n", "a\nB\nc\nd\n", 1, &out.writer);
    try std.testing.expectEqualStrings("@@ -1,3 +1,3 @@\n a\n-b\n+B\n c\n", out.written());
}

test "fuzz: diff hunks reconstruct b" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            const gpa = std.testing.allocator;
            var abuf: [64]u8 = undefined;
            var bbuf: [64]u8 = undefined;
            const an = s.slice(&abuf);
            const bn = s.slice(&bbuf);
            // Map bytes to a small alphabet of lines so matches are common.
            const ta = try toLines(gpa, abuf[0..an]);
            defer gpa.free(ta);
            const tb = try toLines(gpa, bbuf[0..bn]);
            defer gpa.free(tb);
            var out: std.Io.Writer.Allocating = .init(gpa);
            defer out.deinit();
            try unifiedDiff(gpa, ta, tb, 2, &out.writer);
            const rebuilt = try applyUnified(gpa, ta, out.written());
            defer gpa.free(rebuilt);
            try std.testing.expectEqualStrings(tb, rebuilt);
        }
        fn toLines(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
            var t: std.ArrayList(u8) = .empty;
            for (raw) |c| {
                try t.append(gpa, 'a' + c % 4);
                try t.append(gpa, '\n');
            }
            return t.toOwnedSlice(gpa);
        }
    }.one, .{ .corpus = &.{ "abcabba\x00cbabac", "\x01\x02\x03" } });
}
