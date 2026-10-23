//! Passage blocks of a source note (E13.F05.S01.T01): the units a
//! `search_result` carries, so citations
//! (`search_result_location.start_block_index/end_block_index`) point at
//! passages. Headings, paragraphs, list items and table rows each make a
//! block; one longer than 1,200 characters is split at sentence ends (a
//! `.`, `!` or `?` followed by a space and a capital, a digit or a
//! quote), or at a space when a sentence alone is too long. The same text
//! always gives the same blocks.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const max_chars = 1200;

pub const Block = struct {
    index: u32,
    text: []const u8,
};

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
    var para_start: ?usize = null;
    var para_end: usize = 0;
    var in_fence = false;
    var pos: usize = 0;
    while (pos < body.len) {
        const nl = std.mem.indexOfScalarPos(u8, body, pos, '\n');
        const end = nl orelse body.len;
        const line = std.mem.trimEnd(u8, body[pos..end], "\r");
        const next = if (nl) |x| x + 1 else body.len;
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~")) {
            // A code block is one paragraph, blank lines and all.
            if (!in_fence) {
                try flush(a, &out, body, &para_start, para_end);
                para_start = pos;
            }
            in_fence = !in_fence;
            para_end = end;
            if (!in_fence) try flush(a, &out, body, &para_start, para_end);
        } else if (in_fence) {
            para_end = end;
        } else if (trimmed.len == 0) {
            try flush(a, &out, body, &para_start, para_end);
        } else if (trimmed[0] == '#' or isListItem(line) or isTableRow(line)) {
            try flush(a, &out, body, &para_start, para_end);
            if (!isTableRule(line)) try emit(a, &out, trimmed);
        } else {
            if (para_start == null) para_start = pos;
            para_end = end;
        }
        pos = next;
    }
    try flush(a, &out, body, &para_start, para_end);
    return out.items;
}

fn flush(a: Allocator, out: *std.ArrayList(Block), body: []const u8, start: *?usize, end: usize) Allocator.Error!void {
    const s = start.* orelse return;
    start.* = null;
    try emit(a, out, std.mem.trim(u8, body[s..end], " \t\r\n"));
}

fn emit(a: Allocator, out: *std.ArrayList(Block), text: []const u8) Allocator.Error!void {
    if (text.len == 0) return;
    var rest = text;
    while (rest.len > max_chars) {
        const cut = sentenceCut(rest[0..max_chars]) orelse spaceCut(rest[0..max_chars]) orelse charCut(rest);
        try out.append(a, .{ .index = @intCast(out.items.len), .text = std.mem.trimEnd(u8, rest[0..cut], " \n") });
        rest = std.mem.trimStart(u8, rest[cut..], " \n");
    }
    if (rest.len > 0) try out.append(a, .{ .index = @intCast(out.items.len), .text = rest });
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
