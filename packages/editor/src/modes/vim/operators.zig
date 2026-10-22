//! Vim operators on one range of text: delete, change, yank, shift,
//! case changes, plus the commands built on the same edits (put, join,
//! replace). Each applies its edit to the document and returns where the
//! cursor goes; the caller runs it once per cursor and groups undo.

const std = @import("std");
const text_mod = @import("text.zig");
const mode_mod = @import("../mode.zig");
const cs_mod = @import("../../model/edit/change_set.zig");
const indent = @import("../../model/edit/indent.zig");

const Allocator = std.mem.Allocator;
const Text = text_mod.Text;
const Host = mode_mod.Host;
const ChangeSet = cs_mod.ChangeSet;
const Replace = cs_mod.Replace;

pub const RegKind = enum { charwise, linewise, blockwise };

/// A register: text, how it was cut, and one piece per cursor (so a
/// put with as many cursors gives each its own piece).
pub const Register = struct {
    kind: RegKind = .charwise,
    text: std.ArrayList(u8) = .empty,
    /// End offsets of the pieces in `text`.
    ends: std.ArrayList(u32) = .empty,

    pub fn deinit(r: *Register, gpa: Allocator) void {
        r.text.deinit(gpa);
        r.ends.deinit(gpa);
    }

    pub fn clear(r: *Register, kind: RegKind) void {
        r.kind = kind;
        r.text.clearRetainingCapacity();
        r.ends.clearRetainingCapacity();
    }

    pub fn pieceCount(r: *const Register) usize {
        return r.ends.items.len;
    }

    pub fn piece(r: *const Register, i: usize) []const u8 {
        const s = if (i == 0) 0 else r.ends.items[i - 1];
        return r.text.items[s..r.ends.items[i]];
    }

    /// Adds a piece before the others (cursors run last to first).
    pub fn prepend(r: *Register, gpa: Allocator, t: []const u8) Allocator.Error!void {
        try r.text.insertSlice(gpa, 0, t);
        for (r.ends.items) |*e| e.* += @intCast(t.len);
        try r.ends.insert(gpa, 0, @intCast(t.len));
    }

    /// All pieces joined (with newlines for charwise pieces).
    pub fn joined(r: *const Register, gpa: Allocator) Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        for (0..r.pieceCount()) |i| {
            if (i > 0 and r.kind != .linewise) try out.append(gpa, '\n');
            try out.appendSlice(gpa, r.piece(i));
        }
        return out.toOwnedSlice(gpa);
    }
};

/// Applies edits (in the current text) as one document change.
pub fn apply(host: *Host, edits: []const Replace) !void {
    var cs = try ChangeSet.fromEdits(host.sels.gpa, host.doc.len(), edits);
    defer cs.deinit();
    if (cs.isIdentity()) return;
    try host.doc.applyChangeSet(&cs, host.edit.origin);
}

pub fn replace(host: *Host, start: u64, end: u64, t: []const u8) !void {
    return apply(host, &.{.{ .range = .{ .start = start, .end = end }, .text = t }});
}

pub fn txt(host: *Host) Text {
    return Text.init(&host.doc.tree);
}

/// Copies `[start, end)` into `out`.
pub fn copyRange(x: Text, start: u64, end: u64, out: *std.ArrayList(u8), gpa: Allocator) Allocator.Error!void {
    var it = x.t.slice(.{ .start = start, .end = end });
    while (it.next()) |chunk| try out.appendSlice(gpa, chunk);
}

/// The byte range of lines `l0..l1` with their line breaks, and the text
/// a linewise register gets (always ending in "\n"). On the last line the
/// line break before them goes instead.
pub fn lineSpan(x: Text, l0: u64, l1: u64) struct { start: u64, end: u64, take_start: u64, take_end: u64 } {
    const take_start = x.lineStart(l0);
    const take_end = x.nextLineStart(l1);
    var start = take_start;
    const end = take_end;
    if (x.isLastLine(l1) and l0 > 0 and (take_end == x.len and !endsWithBreak(x, l1))) start = x.lineEnd(l0 - 1);
    return .{ .start = start, .end = end, .take_start = take_start, .take_end = take_end };
}

fn endsWithBreak(x: Text, line: u64) bool {
    return x.lineEnd(line) < x.nextLineStart(line);
}

/// Yanks lines `l0..l1` into a linewise register piece.
pub fn yankLines(x: Text, l0: u64, l1: u64, out: *std.ArrayList(u8), gpa: Allocator) Allocator.Error!void {
    var l = l0;
    while (l <= l1) : (l += 1) {
        try copyRange(x, x.lineStart(l), x.lineEnd(l), out, gpa);
        try out.append(gpa, '\n');
    }
}

/// Indentation width of `line` in columns.
pub fn indentCols(x: Text, line: u64, tab: u8) u32 {
    var p = x.lineStart(line);
    const e = x.lineEnd(line);
    var cols: u32 = 0;
    while (p < e) : (p += 1) switch (x.byte(p)) {
        ' ' => cols += 1,
        '\t' => cols += tab - cols % tab,
        else => break,
    };
    return cols;
}

/// Shifts lines `l0..l1` by `amount` levels right (`>`) or left (`<`);
/// empty lines stay empty.
pub fn shift(host: *Host, l0: u64, l1: u64, right: bool, amount: u32) !void {
    const gpa = host.sels.gpa;
    const x = txt(host);
    const unit = host.indentUnit();
    const tab = host.edit.tab_size;
    var edits: std.ArrayList(Replace) = .empty;
    defer edits.deinit(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var l = l0;
    while (l <= l1) : (l += 1) {
        if (x.lineIsEmpty(l)) continue;
        const cols = indentCols(x, l, tab);
        const delta = unit.size * amount;
        const new = if (right) cols + delta else cols -| delta;
        if (new == cols) continue;
        const buf = try arena.allocator().alloc(u8, new);
        const ws = unit.write(new, buf);
        try edits.append(gpa, .{ .range = .{ .start = x.lineStart(l), .end = x.firstNonBlank(l) }, .text = ws });
    }
    try apply(host, edits.items);
}

pub const Case = enum { lower, upper, toggle };

fn mapCase(cp: u21, c: Case) u21 {
    if (cp >= 0x80) return switch (c) {
        // Latin-1 letters and the basic Greek and Cyrillic blocks.
        .lower => lowerCp(cp),
        .upper => upperCp(cp),
        .toggle => if (lowerCp(cp) != cp) lowerCp(cp) else upperCp(cp),
    };
    const b: u8 = @intCast(cp);
    return switch (c) {
        .lower => std.ascii.toLower(b),
        .upper => std.ascii.toUpper(b),
        .toggle => if (std.ascii.isUpper(b)) std.ascii.toLower(b) else std.ascii.toUpper(b),
    };
}

fn lowerCp(cp: u21) u21 {
    return switch (cp) {
        0xC0...0xD6, 0xD8...0xDE => cp + 0x20,
        0x391...0x3A9 => cp + 0x20,
        0x410...0x42F => cp + 0x20,
        else => cp,
    };
}

fn upperCp(cp: u21) u21 {
    return switch (cp) {
        0xE0...0xF6, 0xF8...0xFE => cp - 0x20,
        0x3B1...0x3C9 => if (cp == 0x3C2) cp else cp - 0x20,
        0x430...0x44F => cp - 0x20,
        else => cp,
    };
}

/// Changes the case of `[start, end)`.
pub fn changeCase(host: *Host, start: u64, end: u64, c: Case) !void {
    const gpa = host.sels.gpa;
    const x = txt(host);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var p = start;
    while (p < end) {
        if (x.atEol(p)) {
            out.append(gpa, x.byte(p)) catch unreachable;
            p += 1;
            continue;
        }
        const ch = x.charAt(p);
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(mapCase(ch.cp, c), &buf) catch blk: {
            buf[0] = x.byte(p);
            break :blk 1;
        };
        try out.appendSlice(gpa, buf[0..n]);
        p += ch.len;
    }
    try replace(host, start, end, out.items);
}

/// Joins `count` lines (at least two) from `line`; `spaces`: Vim's `J`
/// (leading white space of a joined line becomes one space, except
/// after white space or an empty line and before `)`), else `gJ`.
/// Returns the cursor (on the last join), or null when there is no line
/// to join.
pub fn join(host: *Host, line: u64, count: u32, spaces: bool) !?u64 {
    const gpa = host.sels.gpa;
    var x = txt(host);
    if (line + 1 >= x.lineCount()) return null;
    const last = @min(line + @max(count, 2) - 1, x.lineCount() - 1);
    var edits: std.ArrayList(Replace) = .empty;
    defer edits.deinit(gpa);
    // Length of the joined line so far and its last character.
    var acc: u64 = x.lineEnd(line) - x.lineStart(line);
    var end1: u8 = if (acc > 0) x.byte(x.lineEnd(line) - 1) else 0;
    var shrink: u64 = 0;
    var cursor: u64 = 0;
    var l = line;
    while (l < last) : (l += 1) {
        const start = x.lineEnd(l);
        const end = if (spaces) x.firstNonBlank(l + 1) else x.lineStart(l + 1);
        const rest = x.lineEnd(l + 1) - end;
        var ins: []const u8 = "";
        if (spaces and rest > 0 and x.byte(end) != ')' and acc != 0 and end1 != '\t') {
            if (end1 != ' ') ins = " ";
        }
        try edits.append(gpa, .{ .range = .{ .start = start, .end = end }, .text = ins });
        cursor = start - shrink;
        shrink += (end - start) - ins.len;
        acc += ins.len + rest;
        if (rest > 0) end1 = x.byte(x.lineEnd(l + 1) - 1) else if (!spaces) end1 = 0;
    }
    try apply(host, edits.items);
    x = txt(host);
    return x.clampNormal(cursor);
}

/// Replaces `count` characters from `pos` with `ch`; null when the line
/// is too short. Returns the cursor.
pub fn replaceChars(host: *Host, pos: u64, count: u32, ch: u21) !?u64 {
    const gpa = host.sels.gpa;
    var x = txt(host);
    var end = pos;
    for (0..count) |_| {
        if (x.atEol(end)) return null;
        end = x.after(end);
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    if (ch == '\n') {
        try out.append(gpa, '\n');
        try replace(host, pos, end, out.items);
        x = txt(host);
        return x.lineStart(x.lineOf(pos) + 1);
    }
    var buf: [4]u8 = undefined;
    const n = try std.unicode.utf8Encode(ch, &buf);
    for (0..count) |_| try out.appendSlice(gpa, buf[0..n]);
    try replace(host, pos, end, out.items);
    return pos + n * (count - 1);
}
