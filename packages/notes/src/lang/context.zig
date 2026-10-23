//! Completion trigger contexts in a note (E08.F06.S02.T02), found from the
//! text before the cursor without a full parse: `[[` note, `[[x#` heading,
//! `[[x#^` block, `![[` embed, `#` tag at a boundary, and property names
//! and values inside the frontmatter.

const std = @import("std");

pub const Trigger = union(enum) {
    none,
    note: struct { query: []const u8, start: u32, embed: bool, closed: bool },
    heading: struct { target: []const u8, query: []const u8, start: u32, closed: bool },
    block: struct { target: []const u8, query: []const u8, start: u32, closed: bool },
    tag: struct { query: []const u8, start: u32 },
    prop_key: struct { query: []const u8, start: u32 },
    prop_value: struct { key: []const u8, query: []const u8, start: u32 },
};

/// The frontmatter block's body range (between the fences), or null.
pub fn frontmatterBody(text: []const u8) ?[2]u32 {
    if (!std.mem.startsWith(u8, text, "---")) return null;
    const first_eol = std.mem.indexOfScalar(u8, text, '\n') orelse return null;
    if (std.mem.trimEnd(u8, text[0..first_eol], " \r").len != 3) return null;
    var i = first_eol + 1;
    while (i <= text.len) {
        const eol = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
        const line = std.mem.trimEnd(u8, text[i..eol], " \r");
        if (std.mem.eql(u8, line, "---") or std.mem.eql(u8, line, "...")) return .{ @intCast(first_eol + 1), @intCast(i) };
        if (eol == text.len) break;
        i = eol + 1;
    }
    // Unclosed: the frontmatter is still being typed.
    return .{ @intCast(first_eol + 1), @intCast(text.len) };
}

pub fn detect(text: []const u8, cursor: u32) Trigger {
    const cur = @min(cursor, text.len);
    const line_start: u32 = if (std.mem.lastIndexOfScalar(u8, text[0..cur], '\n')) |i| @intCast(i + 1) else 0;
    const prefix = text[line_start..cur];
    if (frontmatterBody(text)) |fm| if (cur >= fm[0] and line_start < fm[1] and line_start >= fm[0]) return inFrontmatter(text, fm[0], line_start, prefix);

    if (std.mem.lastIndexOf(u8, prefix, "[[")) |open| {
        const inner = prefix[open + 2 ..];
        if (std.mem.indexOf(u8, inner, "]]") == null and std.mem.indexOfScalar(u8, inner, '|') == null) {
            const closed = std.mem.startsWith(u8, text[cur..], "]]");
            const base: u32 = line_start + @as(u32, @intCast(open + 2));
            if (std.mem.indexOf(u8, inner, "#^")) |h| return .{ .block = .{ .target = inner[0..h], .query = inner[h + 2 ..], .start = base + @as(u32, @intCast(h + 2)), .closed = closed } };
            if (std.mem.lastIndexOfScalar(u8, inner, '#')) |h| {
                const target = inner[0..std.mem.indexOfScalar(u8, inner, '#').?];
                return .{ .heading = .{ .target = target, .query = inner[h + 1 ..], .start = base + @as(u32, @intCast(h + 1)), .closed = closed } };
            }
            return .{ .note = .{ .query = inner, .start = base, .embed = open > 0 and prefix[open - 1] == '!', .closed = closed } };
        }
    }

    // `#tag`: tag characters back to a `#` that follows a boundary.
    var i = prefix.len;
    while (i > 0 and isTagChar(prefix[i - 1])) i -= 1;
    if (i > 0 and prefix[i - 1] == '#') {
        const before: u8 = if (i >= 2) prefix[i - 2] else ' ';
        const q = prefix[i..];
        const all_digits = q.len > 0 and for (q) |c| {
            if (!std.ascii.isDigit(c)) break false;
        } else true;
        if (isTagBoundary(before) and !all_digits and !inCode(text, line_start, cur))
            return .{ .tag = .{ .query = q, .start = line_start + @as(u32, @intCast(i)) } };
    }
    return .none;
}

fn inFrontmatter(text: []const u8, fm_start: u32, line_start: u32, prefix: []const u8) Trigger {
    const lead = prefix.len - std.mem.trimStart(u8, prefix, " \t").len;
    const body = prefix[lead..];
    // A list item: the value of the key above.
    if (std.mem.startsWith(u8, body, "- ")) {
        const key = keyAbove(text, fm_start, line_start) orelse return .none;
        return .{ .prop_value = .{ .key = key, .query = std.mem.trimStart(u8, body[2..], " "), .start = line_start + @as(u32, @intCast(lead + 2 + (body.len - 2 - std.mem.trimStart(u8, body[2..], " ").len))) } };
    }
    if (std.mem.indexOfScalar(u8, body, ':')) |colon| {
        if (lead > 0) return .none;
        const after = body[colon + 1 ..];
        const value = std.mem.trimStart(u8, after, " ");
        if (value.len > 0 and (value[0] == '[' or value[0] == '"' or value[0] == '\'')) return .none;
        return .{ .prop_value = .{ .key = std.mem.trim(u8, body[0..colon], " "), .query = value, .start = line_start + @as(u32, @intCast(colon + 1 + after.len - value.len)) } };
    }
    if (lead > 0) return .none;
    return .{ .prop_key = .{ .query = body, .start = line_start } };
}

/// The key of the nearest unindented `key:` line above `line_start`.
fn keyAbove(text: []const u8, fm_start: u32, line_start: u32) ?[]const u8 {
    var end: usize = line_start;
    while (end > fm_start) {
        const prev_end = end - 1;
        const s = if (std.mem.lastIndexOfScalar(u8, text[0..prev_end], '\n')) |k| k + 1 else 0;
        if (s < fm_start) return null;
        const line = text[s..prev_end];
        if (line.len > 0 and line[0] != ' ' and line[0] != '\t' and line[0] != '-') {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
            return std.mem.trim(u8, line[0..colon], " ");
        }
        end = s;
    }
    return null;
}

pub fn isTagChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '/' or c >= 0x80;
}

fn isTagBoundary(c: u8) bool {
    return c == ' ' or c == '\t' or c == '(' or c == ',' or c == ';' or c == '"' or c == '\'';
}

/// Inside inline code on this line (an odd number of backticks before).
fn inCode(text: []const u8, line_start: u32, cur: usize) bool {
    return std.mem.count(u8, text[line_start..cur], "`") % 2 == 1;
}

const testing = std.testing;

fn at(s: []const u8) struct { text: []const u8, cur: u32 } {
    const i = std.mem.indexOfScalar(u8, s, '@').?;
    // `@` marks the cursor; it is removed from a copy kept in a static.
    const S = struct {
        var buf: [256]u8 = undefined;
    };
    @memcpy(S.buf[0..i], s[0..i]);
    @memcpy(S.buf[i .. s.len - 1], s[i + 1 ..]);
    return .{ .text = S.buf[0 .. s.len - 1], .cur = @intCast(i) };
}

test "context: links, headings, blocks and embeds" {
    var x = at("see [[Pro@");
    var t = detect(x.text, x.cur);
    try testing.expectEqualStrings("Pro", t.note.query);
    try testing.expectEqual(@as(u32, 6), t.note.start);
    try testing.expect(!t.note.embed and !t.note.closed);
    x = at("![[img@]]");
    t = detect(x.text, x.cur);
    try testing.expect(t.note.embed and t.note.closed);
    x = at("[[Alpha#Sec@");
    t = detect(x.text, x.cur);
    try testing.expectEqualStrings("Alpha", t.heading.target);
    try testing.expectEqualStrings("Sec", t.heading.query);
    x = at("[[Alpha#A#B@");
    t = detect(x.text, x.cur);
    try testing.expectEqualStrings("Alpha", t.heading.target);
    try testing.expectEqualStrings("B", t.heading.query);
    x = at("[[#^ab@");
    t = detect(x.text, x.cur);
    try testing.expectEqualStrings("", t.block.target);
    try testing.expectEqualStrings("ab", t.block.query);
    x = at("[[A]] then @");
    try testing.expect(detect(x.text, x.cur) == .none);
    x = at("[[A|alias@");
    try testing.expect(detect(x.text, x.cur) == .none);
}

test "context: tags need a boundary" {
    var x = at("text #pro@");
    try testing.expectEqualStrings("pro", detect(x.text, x.cur).tag.query);
    x = at("#@");
    try testing.expectEqualStrings("", detect(x.text, x.cur).tag.query);
    x = at("a#b@");
    try testing.expect(detect(x.text, x.cur) == .none);
    x = at("issue #123@");
    try testing.expect(detect(x.text, x.cur) == .none);
    x = at("`#code@");
    try testing.expect(detect(x.text, x.cur) == .none);
    x = at("x #area/su@");
    try testing.expectEqualStrings("area/su", detect(x.text, x.cur).tag.query);
}

test "context: frontmatter keys and values" {
    var x = at("---\nsta@\n---\nbody");
    try testing.expectEqualStrings("sta", detect(x.text, x.cur).prop_key.query);
    x = at("---\nstatus: do@\n---\n");
    var t = detect(x.text, x.cur);
    try testing.expectEqualStrings("status", t.prop_value.key);
    try testing.expectEqualStrings("do", t.prop_value.query);
    try testing.expectEqual(@as(u32, 12), t.prop_value.start);
    x = at("---\ntags:\n  - pr@\n---\n");
    t = detect(x.text, x.cur);
    try testing.expectEqualStrings("tags", t.prop_value.key);
    try testing.expectEqualStrings("pr", t.prop_value.query);
    x = at("---\na: 1\n---\n#ta@");
    try testing.expectEqualStrings("ta", detect(x.text, x.cur).tag.query);
}
