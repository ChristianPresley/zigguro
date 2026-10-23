//! A small fuzzy scorer for note names (titles, aliases, paths): an
//! ASCII-case-insensitive subsequence match, rewarding a prefix match,
//! matches at word starts and runs of consecutive characters, and
//! penalising gaps and length. Null when `q` is not a subsequence.

const std = @import("std");

pub fn score(q: []const u8, cand: []const u8) ?i32 {
    if (q.len == 0) return 0;
    if (q.len > cand.len) return null;
    var s: i32 = 0;
    var qi: usize = 0;
    var prev_match: ?usize = null;
    for (cand, 0..) |c, i| {
        if (qi == q.len) break;
        if (std.ascii.toLower(c) != std.ascii.toLower(q[qi])) continue;
        var bonus: i32 = 1;
        if (i == 0) bonus += 10 else if (isBoundary(cand[i - 1], c)) bonus += 6;
        if (prev_match) |p| {
            if (p + 1 == i) bonus += 5 else s -= @intCast(@min(i - p - 1, 5));
        } else s -= @intCast(@min(i, 8));
        s += bonus;
        prev_match = i;
        qi += 1;
    }
    if (qi < q.len) return null;
    if (std.ascii.eqlIgnoreCase(q, cand)) s += 20;
    return s - @divTrunc(@as(i32, @intCast(@min(cand.len - q.len, 20))), 4);
}

fn isBoundary(prev: u8, c: u8) bool {
    if (prev == ' ' or prev == '/' or prev == '-' or prev == '_' or prev == '.') return true;
    return std.ascii.isLower(prev) and std.ascii.isUpper(c);
}

test "fuzzy: ranking" {
    const T = std.testing;
    try T.expect(score("mn", "My Note").? > score("mn", "Command Note").?);
    try T.expect(score("note", "Note").? > score("note", "Some notes").?);
    try T.expect(score("xyz", "Note") == null);
    try T.expectEqual(@as(?i32, 0), score("", "x"));
}
