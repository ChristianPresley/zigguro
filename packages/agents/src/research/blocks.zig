//! Passage blocks of a source note (E13.F05.S01.T01): the units a
//! `search_result` carries, so citations
//! (`search_result_location.start_block_index/end_block_index`) point at
//! passages. Headings, paragraphs, list items and table rows each make a
//! block; one longer than 1,200 characters is split at sentence ends (a
//! `.`, `!` or `?` followed by a space and a capital, a digit or a
//! quote), or at a space when a sentence alone is too long. The same text
//! always gives the same blocks.
//!
//! Citations link to blocks with Obsidian block references: ` ^b12` at the
//! end of a paragraph, heading, list item or table row, or on its own line
//! after a code block. A reference is not part of the block's text, so
//! adding one never moves the indices; a split paragraph has one reference
//! (its first block's index) shared by all its blocks.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const max_chars = 1200;

pub const Block = struct {
    index: u32,
    text: []const u8,
    /// Index of the first block of the paragraph (or line) this came from.
    unit: u32 = 0,
    /// The unit's block reference number (`^b<n>`), if it has one.
    ref: ?u32 = null,
    /// Offset in the body where a reference for the unit is inserted.
    insert_at: usize = 0,
    /// The unit is a code block (its reference goes on the next line).
    fence: bool = false,

    /// The text to insert at `insert_at` to give the unit reference `n`.
    pub fn refText(b: Block, a: Allocator, n: u32) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(a, "{s}^b{d}", .{ if (b.fence) "\n" else " ", n });
    }
};

/// The `n` of a trailing ` ^b<n>` (or a whole-line `^b<n>`) and where it
/// starts, if `line` ends with one.
pub fn trailingRef(line: []const u8) ?struct { n: u32, at: usize } {
    const t = std.mem.trimEnd(u8, line, " \t");
    var i = t.len;
    while (i > 0 and std.ascii.isDigit(t[i - 1])) i -= 1;
    if (i == t.len or i < 2 or t[i - 1] != 'b' or t[i - 2] != '^') return null;
    const at = i - 2;
    if (at > 0 and t[at - 1] != ' ' and t[at - 1] != '\t') return null;
    const n = std.fmt.parseInt(u32, t[i..], 10) catch return null;
    return .{ .n = n, .at = at };
}

const Unit = struct { start: ?usize = null, end: usize = 0, ref: ?u32 = null };

fn isListItem(line: []const u8) bool {
    const t = std.mem.trimStart(u8, line, " ");
    if (t.len >= 2 and (t[0] == '-' or t[0] == '*' or t[0] == '+') and t[1] == ' ') return true;
    var i: usize = 0;
    while (i < t.len and std.ascii.isDigit(t[i])) i += 1;
    return i > 0 and i + 1 < t.len and (t[i] == '.' or t[i] == ')') and t[i + 1] == ' ';
}

fn isTableRow(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " ");
    return t.len > 0 and t[0] == '|';
}

fn isTableRule(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " ");
    if (!isTableRow(t)) return false;
    for (t) |c| if (c != '|' and c != '-' and c != ':' and c != ' ') return false;
    return true;
}

/// The blocks of a note's body (frontmatter already removed).
pub fn split(a: Allocator, body: []const u8) Allocator.Error![]Block {
    var out: std.ArrayList(Block) = .empty;
    var para: Unit = .{};
    var in_fence = false;
    var pos: usize = 0;
    while (pos < body.len) {
        const nl = std.mem.indexOfScalarPos(u8, body, pos, '\n');
        const end = nl orelse body.len;
        var line = std.mem.trimEnd(u8, body[pos..end], "\r");
        const next = if (nl) |x| x + 1 else body.len;
        var trimmed = std.mem.trim(u8, line, " \t");
        if (in_fence) {
            para.end = pos + line.len;
            if (std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~")) {
                in_fence = false;
                try flush(a, &out, body, &para, true);
            }
            pos = next;
            continue;
        }
        const ref = trailingRef(line);
        if (ref) |r| if (std.mem.trim(u8, line[0..r.at], " \t").len == 0) {
            // A reference on its own line names the unit before it.
            try flush(a, &out, body, &para, false);
            setRef(out.items, r.n);
            pos = next;
            continue;
        };
        if (ref) |r| {
            line = std.mem.trimEnd(u8, line[0..r.at], " \t");
            trimmed = std.mem.trim(u8, line, " \t");
        }
        if (std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~")) {
            // A code block is one unit, blank lines and all.
            try flush(a, &out, body, &para, false);
            para = .{ .start = pos, .end = pos + line.len };
            in_fence = true;
        } else if (trimmed.len == 0) {
            try flush(a, &out, body, &para, false);
        } else if (trimmed[0] == '#' or isListItem(line) or isTableRow(line)) {
            try flush(a, &out, body, &para, false);
            if (!isTableRule(line)) try emit(a, &out, trimmed, .{ .end = pos + line.len, .ref = if (ref) |r| r.n else null }, false);
        } else {
            if (para.start == null) para.start = pos;
            para.end = pos + line.len;
            if (ref) |r| para.ref = r.n;
        }
        pos = next;
    }
    try flush(a, &out, body, &para, in_fence);
    return out.items;
}

/// Gives the last unit in `bs` reference `n`.
fn setRef(bs: []Block, n: u32) void {
    if (bs.len == 0) return;
    const unit = bs[bs.len - 1].unit;
    for (bs[unit..]) |*b| b.ref = n;
}

fn flush(a: Allocator, out: *std.ArrayList(Block), body: []const u8, u: *Unit, fence: bool) Allocator.Error!void {
    const s = u.start orelse return;
    const unit = u.*;
    u.* = .{};
    try emit(a, out, std.mem.trim(u8, body[s..unit.end], " \t\r\n"), unit, fence);
}

fn emit(a: Allocator, out: *std.ArrayList(Block), text: []const u8, u: Unit, fence: bool) Allocator.Error!void {
    if (text.len == 0) return;
    const unit: u32 = @intCast(out.items.len);
    const proto: Block = .{ .index = 0, .text = "", .unit = unit, .ref = u.ref, .insert_at = u.end, .fence = fence };
    var rest = text;
    while (rest.len > max_chars) {
        const cut = sentenceCut(rest[0..max_chars]) orelse spaceCut(rest[0..max_chars]) orelse charCut(rest);
        var b = proto;
        b.index = @intCast(out.items.len);
        b.text = std.mem.trimEnd(u8, rest[0..cut], " \n");
        try out.append(a, b);
        rest = std.mem.trimStart(u8, rest[cut..], " \n");
    }
    if (rest.len > 0) {
        var b = proto;
        b.index = @intCast(out.items.len);
        b.text = rest;
        try out.append(a, b);
    }
}

/// The last sentence end in `s` (just after its punctuation), if any.
fn sentenceCut(s: []const u8) ?usize {
    var i = s.len;
    while (i > 2) {
        i -= 1;
        const c = s[i - 1];
        if ((c == '.' or c == '!' or c == '?') and (s[i] == ' ' or s[i] == '\n') and i + 1 < s.len) {
            const n = s[i + 1];
            if (std.ascii.isUpper(n) or std.ascii.isDigit(n) or n == '"' or n == '\'' or n >= 0x80) return i;
        }
    }
    return null;
}

fn spaceCut(s: []const u8) ?usize {
    const i = std.mem.lastIndexOfScalar(u8, s, ' ') orelse return null;
    return if (i == 0) null else i;
}

/// `max_chars`, moved back to the start of a UTF-8 sequence.
fn charCut(s: []const u8) usize {
    var c: usize = max_chars;
    while (c > 1 and (s[c] & 0xC0) == 0x80) c -= 1;
    return c;
}
