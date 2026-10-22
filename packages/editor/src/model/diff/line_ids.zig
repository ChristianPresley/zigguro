//! Lines as ids: a `LineSource` splits text into lines (terminators `\n`,
//! `\r\n` or a lone `\r`, as the piece tree counts them), and `intern`
//! gives equal lines equal ids after whitespace normalization.
//!
//! Terminators are not compared, except that a final line without one is
//! distinct from the same line with one (unified diffs mark it "\ No
//! newline at end of file"). Text ending in a terminator has no empty last
//! line here, unlike `PieceTree.lineCount`.

const std = @import("std");
const pt = @import("../buffer/piece_tree.zig");

const Allocator = std.mem.Allocator;

/// How whitespace is compared.
pub const WsMode = enum {
    none,
    /// Ignore whitespace at line end.
    trailing,
    /// Ignore all whitespace.
    all,
    /// Treat runs of whitespace as one space and ignore it at line end.
    amount,
};

/// One line: `len` content bytes from `start`, then `eol` terminator bytes.
pub const Line = struct { start: u64, len: u32, eol: u2 };

/// The lines of a text. Built from bytes (borrowed) or a piece tree
/// (copied once into one buffer).
pub const LineSource = struct {
    text: []const u8,
    lines: []Line,
    owned: bool,

    /// Lines of `text`, which must outlive the source.
    pub fn fromBytes(gpa: Allocator, text: []const u8) Allocator.Error!LineSource {
        return .{ .text = text, .lines = try split(gpa, text), .owned = false };
    }

    /// Lines of a piece-tree version (a snapshot's tree).
    pub fn fromTree(gpa: Allocator, t: pt.PieceTree) Allocator.Error!LineSource {
        const text = try t.copyRange(gpa, .{ .start = 0, .end = t.len() });
        errdefer gpa.free(text);
        return .{ .text = text, .lines = try split(gpa, text), .owned = true };
    }

    /// Frees the line table (and the text when copied).
    pub fn deinit(s: *LineSource, gpa: Allocator) void {
        gpa.free(s.lines);
        if (s.owned) gpa.free(s.text);
        s.* = undefined;
    }

    /// Number of lines.
    pub fn count(s: *const LineSource) usize {
        return s.lines.len;
    }

    /// Line `i` without its terminator.
    pub fn line(s: *const LineSource, i: usize) []const u8 {
        const l = s.lines[i];
        return s.text[@intCast(l.start)..][0..l.len];
    }

    /// Line `i` with its terminator.
    pub fn lineWithEol(s: *const LineSource, i: usize) []const u8 {
        const l = s.lines[i];
        return s.text[@intCast(l.start)..][0 .. l.len + l.eol];
    }

    /// Whether line `i` is the last one and has no terminator.
    pub fn missingEol(s: *const LineSource, i: usize) bool {
        return i + 1 == s.lines.len and s.lines[i].eol == 0;
    }

    /// Byte offset where line `i` starts (`text.len` for `i == count`).
    pub fn offsetOf(s: *const LineSource, i: usize) u64 {
        return if (i < s.lines.len) s.lines[i].start else s.text.len;
    }
};

fn split(gpa: Allocator, text: []const u8) Allocator.Error![]Line {
    var out: std.ArrayList(Line) = .empty;
    errdefer out.deinit(gpa);
    var start: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '\n' or c == '\r') {
            const eol: u2 = if (c == '\r' and i + 1 < text.len and text[i + 1] == '\n') 2 else 1;
            try out.append(gpa, .{ .start = start, .len = @intCast(i - start), .eol = eol });
            i += eol;
            start = i;
        } else {
            i += 1;
        }
    }
    if (start < text.len) try out.append(gpa, .{ .start = start, .len = @intCast(text.len - start), .eol = 0 });
    return out.toOwnedSlice(gpa);
}

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == 0x0B or c == 0x0C or c == '\r';
}

/// `line` normalized for `ws`, into `buf` when it changes.
pub fn normalize(line: []const u8, ws: WsMode, buf: *std.ArrayList(u8), gpa: Allocator) Allocator.Error![]const u8 {
    switch (ws) {
        .none => return line,
        .trailing => {
            var e = line.len;
            while (e > 0 and isWs(line[e - 1])) e -= 1;
            return line[0..e];
        },
        .all => {
            buf.clearRetainingCapacity();
            for (line) |c| if (!isWs(c)) try buf.append(gpa, c);
            return buf.items;
        },
        .amount => {
            buf.clearRetainingCapacity();
            var in_ws = false;
            for (line) |c| {
                if (isWs(c)) {
                    in_ws = true;
                    continue;
                }
                if (in_ws and buf.items.len > 0) try buf.append(gpa, ' ');
                in_ws = false;
                try buf.append(gpa, c);
            }
            return buf.items;
        },
    }
}

/// Gives every line of `a` and `b` an id: equal (normalized) lines get
/// equal ids, and ids are dense from 0.
pub fn intern(gpa: Allocator, a: *const LineSource, b: *const LineSource, ws: WsMode, out_a: *std.ArrayList(u32), out_b: *std.ArrayList(u32)) Allocator.Error!void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const ar = arena.allocator();
    var map: std.StringHashMapUnmanaged(u32) = .empty;
    var no_eol: std.StringHashMapUnmanaged(u32) = .empty;
    try map.ensureTotalCapacity(ar, @intCast(a.count() + b.count()));
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var next: u32 = 0;
    inline for (.{ .{ a, out_a }, .{ b, out_b } }) |side| {
        const src = side[0];
        const out = side[1];
        try out.ensureTotalCapacity(gpa, src.count());
        out.clearRetainingCapacity();
        for (0..src.count()) |i| {
            var key = try normalize(src.line(i), ws, &buf, gpa);
            if (key.ptr == buf.items.ptr) key = try ar.dupe(u8, key);
            const m = if (src.missingEol(i)) &no_eol else &map;
            const g = try m.getOrPut(ar, key);
            if (!g.found_existing) {
                g.value_ptr.* = next;
                next += 1;
            }
            out.appendAssumeCapacity(g.value_ptr.*);
        }
    }
}
