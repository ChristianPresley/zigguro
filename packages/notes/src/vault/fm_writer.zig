//! The byte-preserving property writer (E08.F06.S01.T03): applies `set`,
//! `remove` and `rename` edits to a note's frontmatter by rewriting only
//! the affected bytes. Unknown keys, comments, ordering, quoting and
//! formatting of everything else survive byte for byte.
//!
//! - `set` on an existing key replaces only the value's bytes, in a style
//!   matching the original: a block list stays a block list (with the
//!   same item indentation), a flow list stays a flow list, a scalar is
//!   quoted only when it must be.
//! - `set` on a new key appends `name: value` before the closing fence;
//!   lists are written as block lists, Obsidian's style.
//! - `remove` deletes the key's lines, block children included.
//! - Without frontmatter, `---`/`---` is created at byte 0 (after a BOM).
//! - New line breaks follow the note's dominant EOL.

const std = @import("std");
const fm = @import("frontmatter.zig");

const Allocator = std.mem.Allocator;
const Value = fm.Value;
const Style = fm.Style;
const Node = fm.Node;

pub const PropEdit = union(enum) {
    set: struct { name: []const u8, value: Value },
    remove: []const u8,
    rename: struct { from: []const u8, to: []const u8 },
};

/// Returns the note with `edits` applied in order (owned by `gpa`). Edits
/// naming an absent key (`remove`, `rename`) do nothing.
pub fn applyPropEdits(gpa: Allocator, note_bytes: []const u8, edits: []const PropEdit) ![]u8 {
    var cur: std.ArrayList(u8) = .empty;
    errdefer cur.deinit(gpa);
    try cur.appendSlice(gpa, note_bytes);
    for (edits) |e| try applyOne(gpa, &cur, e);
    return cur.toOwnedSlice(gpa);
}

/// `\r\n` when most line breaks of `bytes` are CRLF, else `\n`.
pub fn dominantEol(bytes: []const u8) []const u8 {
    var lf: usize = 0;
    var crlf: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, bytes, i, '\n')) |n| : (i = n + 1) {
        if (n > 0 and bytes[n - 1] == '\r') crlf += 1 else lf += 1;
    }
    return if (crlf > lf) "\r\n" else "\n";
}

fn applyOne(gpa: Allocator, cur: *std.ArrayList(u8), e: PropEdit) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const note = cur.items;
    const eol = dominantEol(note);
    const loc = fm.findFrontmatter(note) orelse {
        const set = switch (e) {
            .set => |s| s,
            else => return,
        };
        var w: std.Io.Writer.Allocating = .init(arena);
        try w.writer.print("---{s}", .{eol});
        try writeEntry(&w.writer, set.name, set.value, 0, eol);
        try w.writer.print("---{s}", .{eol});
        const at: usize = if (std.mem.startsWith(u8, note, "\xEF\xBB\xBF")) 3 else 0;
        try cur.insertSlice(gpa, at, w.written());
        return;
    };
    const root = try fm.parseRange(arena, note, loc.body, null);
    const pairs = switch (root.value) {
        .map => |m| m,
        else => return, // too large to edit
    };
    switch (e) {
        .remove => |name| {
            const p = find(pairs, name) orelse return;
            try cur.replaceRange(gpa, p.span[0], p.span[1] - p.span[0], "");
        },
        .rename => |r| {
            const p = find(pairs, r.from) orelse return;
            var w: std.Io.Writer.Allocating = .init(arena);
            try writeKey(&w.writer, r.to);
            try cur.replaceRange(gpa, p.key_src[0], p.key_src[1] - p.key_src[0], w.written());
        },
        .set => |s| {
            var w: std.Io.Writer.Allocating = .init(arena);
            const p = find(pairs, s.name) orelse {
                // Before the closing fence; make sure the last entry ends
                // with a line break.
                const at = loc.body[1];
                try writeEntry(&w.writer, s.name, s.value, 0, eol);
                try cur.insertSlice(gpa, at, w.written());
                return;
            };
            const range = try replacement(&w.writer, note, p, s.value, eol);
            try cur.replaceRange(gpa, range[0], range[1] - range[0], w.written());
        },
    }
}

fn find(pairs: []const fm.Pair, name: []const u8) ?*const fm.Pair {
    for (pairs) |*p| if (std.mem.eql(u8, p.key, name)) return p;
    return null;
}

/// Writes the new value of pair `p` and returns the byte range it
/// replaces.
fn replacement(w: *std.Io.Writer, note: []const u8, p: *const fm.Pair, v: Value, eol: []const u8) ![2]u32 {
    const colon: u32 = @intCast(std.mem.indexOfScalarPos(u8, note, p.key_src[1], ':').? + 1);
    const key_indent = p.key_src[0] - lineStart(note, p.key_src[0]);
    const old = p.node;
    const new_is_list = v == .list;
    const empty_old = old.src[0] == old.src[1];
    if (new_is_list and v.list.len > 0 and old.style != .flow_seq) {
        if (old.style == .block_seq and !empty_old) {
            // Same item indentation and dash spacing as the first item.
            var item_indent: usize = 0;
            while (note[old.src[0] + item_indent] == ' ') item_indent += 1;
            for (v.list, 0..) |item, i| {
                if (i > 0) try w.writeAll(eol);
                try w.splatByteAll(' ', item_indent);
                try w.writeAll("- ");
                try serializeValue(w, item.value, .plain, 0);
            }
            return old.src;
        }
        // Scalar (or empty) to block list: Obsidian's two-space items.
        for (v.list) |item| {
            try w.writeAll(eol);
            try w.splatByteAll(' ', key_indent + 2);
            try w.writeAll("- ");
            try serializeValue(w, item.value, .plain, 0);
        }
        return .{ colon, if (empty_old) colon else old.src[1] };
    }
    const inline_style: Style = switch (old.style) {
        .flow_seq, .flow_map, .single_quoted, .double_quoted, .plain => old.style,
        else => .plain,
    };
    if (old.style == .block_seq or old.style == .block_map or old.style == .literal or old.style == .folded or empty_old) {
        // The value moves onto the key line.
        try w.writeByte(' ');
        try serializeValue(w, v, inline_style, 0);
        return .{ colon, if (empty_old) colon else old.src[1] };
    }
    try serializeValue(w, v, inline_style, 0);
    return old.src;
}

fn lineStart(s: []const u8, at: u32) u32 {
    var i = at;
    while (i > 0 and s[i - 1] != '\n') i -= 1;
    return i;
}

/// `name: value` (or `name:` and block items) with a trailing EOL.
fn writeEntry(w: *std.Io.Writer, name: []const u8, v: Value, indent: u16, eol: []const u8) !void {
    try w.splatByteAll(' ', indent);
    try writeKey(w, name);
    try w.writeByte(':');
    switch (v) {
        .list => |items| if (items.len == 0) {
            try w.writeAll(" []");
        } else for (items) |item| {
            try w.writeAll(eol);
            try w.splatByteAll(' ', indent + 2);
            try w.writeAll("- ");
            try serializeValue(w, item.value, .plain, 0);
        },
        .null => {},
        else => {
            try w.writeByte(' ');
            try serializeValue(w, v, .plain, 0);
        },
    }
    try w.writeAll(eol);
}

fn writeKey(w: *std.Io.Writer, name: []const u8) !void {
    if (needsQuoteText(name, false) or std.mem.indexOfScalar(u8, name, ':') != null) {
        try writeQuoted(w, name);
    } else try w.writeAll(name);
}

/// Writes `v` on one line in a style matching `style_hint`: lists and maps
/// in flow style, strings plain when unambiguous (quoted otherwise, with
/// the hint's quote kind when it was quoted). Block styles are never
/// produced here; `applyPropEdits` writes block lists itself. `indent` is
/// accepted for symmetry with block output and unused for flow values.
pub fn serializeValue(w: *std.Io.Writer, v: Value, style_hint: Style, indent: u16) std.Io.Writer.Error!void {
    _ = indent;
    try writeScalarOrFlow(w, v, style_hint, false);
}

fn writeScalarOrFlow(w: *std.Io.Writer, v: Value, hint: Style, in_flow: bool) std.Io.Writer.Error!void {
    switch (v) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .int => |i| try w.print("{d}", .{i}),
        .float => |f| try writeFloat(w, f),
        .date => |d| try writeDate(w, d),
        .datetime => |dt| try writeDateTime(w, dt),
        .raw => |r| try w.writeAll(r),
        .string => |s| {
            if (hint == .single_quoted and canSingleQuote(s)) {
                try writeSingle(w, s);
            } else if (hint == .double_quoted) {
                try writeDouble(w, s);
            } else if (needsQuote(s, in_flow)) {
                try writeQuoted(w, s);
            } else try w.writeAll(s);
        },
        .list => |items| {
            try w.writeByte('[');
            for (items, 0..) |item, i| {
                if (i > 0) try w.writeAll(", ");
                try writeScalarOrFlow(w, item.value, item.style, true);
            }
            try w.writeByte(']');
        },
        .map => |pairs| {
            try w.writeByte('{');
            for (pairs, 0..) |p, i| {
                if (i > 0) try w.writeAll(", ");
                if (needsQuote(p.key, true)) try writeQuoted(w, p.key) else try w.writeAll(p.key);
                try w.writeAll(": ");
                try writeScalarOrFlow(w, p.node.value, p.node.style, true);
            }
            try w.writeByte('}');
        },
    }
}

fn writeFloat(w: *std.Io.Writer, f: f64) !void {
    if (std.math.isNan(f)) return w.writeAll(".nan");
    if (std.math.isInf(f)) return w.writeAll(if (f < 0) "-.inf" else ".inf");
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{f}) catch unreachable;
    try w.writeAll(s);
    if (std.mem.indexOfAny(u8, s, ".eE") == null) try w.writeAll(".0");
}

pub fn writeDate(w: *std.Io.Writer, d: fm.Date) !void {
    try w.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u32, @intCast(d.y)), d.m, d.d });
}

fn writeDateTime(w: *std.Io.Writer, dt: fm.DateTime) !void {
    try writeDate(w, dt.date);
    try w.print("T{d:0>2}:{d:0>2}:{d:0>2}", .{ dt.h, dt.min, dt.s });
    if (dt.utc_offset_s) |off| {
        if (off == 0) return w.writeByte('Z');
        const a: u32 = @intCast(@abs(off));
        try w.print("{c}{d:0>2}:{d:0>2}", .{ @as(u8, if (off < 0) '-' else '+'), a / 3600, (a / 60) % 60 });
    }
}

/// Whether a string must be quoted to read back as the same string.
pub fn needsQuote(s: []const u8, in_flow: bool) bool {
    if (s.len == 0) return true;
    if (fm.typePlain(s) != .string) return true;
    // YAML 1.1 booleans other tools still read as booleans.
    const yaml11 = [_][]const u8{ "yes", "no", "on", "off", "y", "n" };
    for (yaml11) |b| if (std.ascii.eqlIgnoreCase(s, b)) return true;
    return needsQuoteText(s, in_flow);
}

/// The syntactic part of `needsQuote` (keys are never typed).
fn needsQuoteText(s: []const u8, in_flow: bool) bool {
    if (s.len == 0) return true;
    if (std.mem.indexOfScalar(u8, ":#[]{},&*!|>'\"%@`", s[0]) != null) {
        // `:x` and `#x` are fine only when they cannot start a token; be
        // conservative.
        return true;
    }
    if ((s[0] == '-' or s[0] == '?') and (s.len == 1 or s[1] == ' ')) return true;
    if (s[0] == ' ' or s[s.len - 1] == ' ' or s[0] == '\t' or s[s.len - 1] == '\t') return true;
    if (s[s.len - 1] == ':') return true;
    if (std.mem.indexOf(u8, s, ": ") != null or std.mem.indexOf(u8, s, " #") != null) return true;
    for (s) |c| if (c < 0x20 or c == 0x7f) return true;
    if (in_flow and std.mem.indexOfAny(u8, s, ",[]{}") != null) return true;
    return false;
}

fn canSingleQuote(s: []const u8) bool {
    for (s) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

fn writeQuoted(w: *std.Io.Writer, s: []const u8) !void {
    if (std.mem.indexOfAny(u8, s, "\"\\") != null and canSingleQuote(s)) return writeSingle(w, s);
    return writeDouble(w, s);
}

fn writeSingle(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('\'');
    for (s) |c| {
        if (c == '\'') try w.writeByte('\'');
        try w.writeByte(c);
    }
    try w.writeByte('\'');
}

fn writeDouble(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\t' => try w.writeAll("\\t"),
        '\r' => try w.writeAll("\\r"),
        0...8, 11, 12, 14...0x1f, 0x7f => try w.print("\\x{x:0>2}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}
