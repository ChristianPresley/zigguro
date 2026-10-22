//! Reads conflict markers back: the text a user or agent edited after
//! `materialize` becomes either resolved content or a whole-file
//! `Merge` (one full text per term) for the content merge to re-run.
//! Regions the user removed are resolved text shared by every term.
//! Malformed markers give `unparseable`; the snapshot then keeps the file
//! as written and warns, so no edit is silently lost.

const std = @import("std");
const merge_mod = @import("merge.zig");
const mat = @import("materialize.zig");
const Merge = merge_mod.Merge;
const Allocator = std.mem.Allocator;

pub const ParseResult = union(enum) {
    /// No markers left: the file's content.
    resolved: []const u8,
    /// One full text per term (side, base, side, ...).
    conflict: Merge([]const u8),
    unparseable,

    pub fn deinit(r: ParseResult, gpa: Allocator) void {
        switch (r) {
            .resolved => |s| gpa.free(s),
            .conflict => |m| {
                for (m.values) |v| gpa.free(v);
                gpa.free(m.values);
            },
            .unparseable => {},
        }
    }
};

/// Whether `line` is a marker of exactly `len` copies of `c`, followed by
/// a space (and a label) or the end of the line.
fn isMarker(line: []const u8, c: u8, len: u8) bool {
    if (line.len < len) return false;
    for (line[0..len]) |x| if (x != c) return false;
    if (line.len == len) return true;
    return line[len] == ' ' or line[len] == '\n' or (line[len] == '\r' and line.len == @as(usize, len) + 2);
}

const Section = struct { c: u8, start: usize, end: usize };

/// Parses `text` written with `o.style` and `o.marker_len` (the length
/// `materialize` chose, kept in the TreeState).
pub fn parseMarkers(gpa: Allocator, text: []const u8, original: Merge(?[]const u8), o: mat.MaterializeOptions) !ParseResult {
    const nterms = original.values.len;
    const sides = original.sides();
    const len = o.marker_len;
    var terms = try gpa.alloc(std.ArrayList(u8), nterms);
    defer gpa.free(terms);
    for (terms) |*b| b.* = .empty;
    var keep = false;
    defer if (!keep) for (terms) |*b| b.deinit(gpa);

    var regions: usize = 0;
    var it = mat.LineIter{ .text = text };
    var sections: std.ArrayList(Section) = .empty;
    defer sections.deinit(gpa);
    while (it.next()) |line| {
        if (!isMarker(line, '<', len)) {
            for (terms) |*b| try b.appendSlice(gpa, line);
            continue;
        }
        regions += 1;
        sections.clearRetainingCapacity();
        try sections.append(gpa, .{ .c = '<', .start = it.pos, .end = it.pos });
        const closed = while (it.next()) |l| {
            const start = it.pos - l.len;
            if (isMarker(l, '>', len)) {
                sections.items[sections.items.len - 1].end = start;
                break true;
            }
            if (isMarker(l, '<', len)) return .unparseable;
            for ("|=%+") |c| {
                if (isMarker(l, c, len)) {
                    sections.items[sections.items.len - 1].end = start;
                    try sections.append(gpa, .{ .c = c, .start = it.pos, .end = it.pos });
                    break;
                }
            }
        } else false;
        if (!closed) return .unparseable;
        const secs = sections.items;
        const body = struct {
            fn of(t: []const u8, s: Section) []const u8 {
                return t[s.start..s.end];
            }
        }.of;
        if (secs.len == 3 and secs[1].c == '|' and secs[2].c == '=') {
            // diff3 / zdiff3.
            if (nterms != 3) return .unparseable;
            try terms[0].appendSlice(gpa, body(text, secs[0]));
            try terms[1].appendSlice(gpa, body(text, secs[1]));
            try terms[2].appendSlice(gpa, body(text, secs[2]));
            continue;
        }
        // zg: nothing before the first section, a diff per base, then a
        // snapshot of the last side.
        if (secs[0].start != secs[0].end or secs.len != sides + 1) return .unparseable;
        for (secs[1 .. secs.len - 1], 0..) |s, i| {
            if (s.c != '%') return .unparseable;
            if (!try splitDiff(gpa, body(text, s), &terms[2 * i + 1], &terms[2 * i])) return .unparseable;
        }
        if (secs[secs.len - 1].c != '+') return .unparseable;
        try terms[nterms - 1].appendSlice(gpa, body(text, secs[secs.len - 1]));
    }
    if (regions == 0) return .{ .resolved = try gpa.dupe(u8, text) };
    const values = try gpa.alloc([]const u8, nterms);
    var done: usize = 0;
    errdefer {
        for (values[0..done]) |v| gpa.free(v);
        gpa.free(values);
    }
    for (terms, values) |*b, *v| {
        v.* = try b.toOwnedSlice(gpa);
        done += 1;
    }
    keep = true;
    return .{ .conflict = .{ .values = values } };
}

/// Splits a `zg` diff section into its from (base) and to (side) texts.
fn splitDiff(gpa: Allocator, section: []const u8, from: *std.ArrayList(u8), to: *std.ArrayList(u8)) !bool {
    var it = mat.LineIter{ .text = section };
    while (it.next()) |line| {
        if (line.len == 1 and line[0] == '\n') {
            try from.appendSlice(gpa, line);
            try to.appendSlice(gpa, line);
            continue;
        }
        const rest = line[1..];
        switch (line[0]) {
            ' ' => {
                try from.appendSlice(gpa, rest);
                try to.appendSlice(gpa, rest);
            },
            '-' => try from.appendSlice(gpa, rest),
            '+' => try to.appendSlice(gpa, rest),
            else => return false,
        }
    }
    return true;
}
