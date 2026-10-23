//! Inline `#tags` (E08.F06.S01.T01), Obsidian's rules: a `#` at the start
//! of a line or after whitespace or punctuation, then a run of Unicode
//! letters, marks and numbers, `_`, `-`, `/` and emoji. A tag must contain
//! one non-digit (`#1984` is not a tag); `a/b/c` nests. Keys are
//! case-folded (full folding, UAX #44), displays keep the original.

const std = @import("std");
const zg_text = @import("zg_text");

const Allocator = std.mem.Allocator;
const uni = zg_text.unicode;

/// Whether code point `cp` may appear in a tag body.
pub fn isTagChar(cp: u21) bool {
    if (cp < 0x80) {
        const c: u8 = @intCast(cp);
        return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '/';
    }
    if (cp == 0x200D or cp == 0xFE0F) return true; // ZWJ and VS16 in emoji sequences
    const p = uni.props(cp);
    if (p.ext_pict) return true;
    return switch (p.gc) {
        .Ll, .Lm, .Lo, .Lt, .Lu, .Mc, .Me, .Mn, .Nd, .Nl, .No => true,
        // Skin-tone modifiers.
        .Sk => cp >= 0x1F3FB and cp <= 0x1F3FF,
        else => false,
    };
}

/// Whether a `#` after `prev` (the previous code point, or null at the
/// line start) can start a tag.
pub fn canStartAfter(prev: ?u21) bool {
    const c = prev orelse return true;
    if (c < 0x80) {
        const b: u8 = @intCast(c);
        if (std.ascii.isWhitespace(b)) return true;
        // Not inside words, `&#38;` entities, `##` or URLs/paths.
        return switch (b) {
            '(', '[', '{', ',', ';', '!', '?', '"', '\'', '*', '_', '~', '=', '<', '>', '|', ')', ']', '}', '.' => true,
            else => false,
        };
    }
    const gc = uni.props(c).gc;
    return switch (gc) {
        .Zs, .Zl, .Zp, .Ps, .Pe, .Pi, .Pf, .Po, .Pd => true,
        else => false,
    };
}

/// The end of the tag body that starts at `start` (just after `#`), or
/// null when there is no valid tag there. A trailing `/` is not part of
/// the tag.
pub fn scanBody(s: []const u8, start: usize) ?usize {
    var i = start;
    var has_non_digit = false;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch break;
        if (i + n > s.len) break;
        const cp = std.unicode.utf8Decode(s[i .. i + n]) catch break;
        if (!isTagChar(cp)) break;
        if (!(cp >= '0' and cp <= '9') and cp != '/') has_non_digit = true;
        i += n;
    }
    while (i > start and s[i - 1] == '/') i -= 1;
    if (i == start or !has_non_digit) return null;
    return i;
}

/// The previous code point before byte `i` (null at `i == 0`).
pub fn prevCodepoint(s: []const u8, i: usize) ?u21 {
    if (i == 0) return null;
    var j = i - 1;
    while (j > 0 and (s[j] & 0xC0) == 0x80) j -= 1;
    return std.unicode.utf8Decode(s[j..i]) catch 0xFFFD;
}

/// The case-folded key of `display` (a tag without `#`), in `gpa`.
pub fn foldKey(gpa: Allocator, display: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try uni.casefold.foldAppend(&out, gpa, display, .full);
    return out.toOwnedSlice(gpa);
}

/// Case-folds `s` into `out` (cleared first). For name maps and search.
pub fn foldInto(out: *std.ArrayList(u8), gpa: Allocator, s: []const u8) !void {
    out.clearRetainingCapacity();
    try uni.casefold.foldAppend(out, gpa, s, .full);
}

/// Normalizes a frontmatter tag value: drops a leading `#` and spaces.
pub fn fromProperty(s: []const u8) []const u8 {
    var t = std.mem.trim(u8, s, " \t");
    if (t.len > 0 and t[0] == '#') t = t[1..];
    return t;
}

test "tags: body rules" {
    const T = std.testing;
    try T.expectEqual(@as(?usize, 4), scanBody("#abc def", 1));
    try T.expectEqual(@as(?usize, null), scanBody("#1984", 1));
    try T.expectEqual(@as(?usize, 6), scanBody("#y1984", 1));
    try T.expectEqual(@as(?usize, 4), scanBody("#a/b/", 1));
    try T.expectEqual(@as(?usize, null), scanBody("#/", 1));
    try T.expectEqual(@as(?usize, 10), scanBody("#caf\u{e9}-x_1.", 1));
    try T.expectEqual(@as(?usize, 5), scanBody("#\u{1F680}!", 1));
    try T.expect(canStartAfter(null));
    try T.expect(canStartAfter(' '));
    try T.expect(canStartAfter('('));
    try T.expect(!canStartAfter('a'));
    try T.expect(!canStartAfter('&'));
    try T.expect(!canStartAfter('#'));
    try T.expect(!canStartAfter('/'));
    const k = try foldKey(T.allocator, "Stra\u{df}e/ABC");
    defer T.allocator.free(k);
    try T.expectEqualStrings("strasse/abc", k);
}
