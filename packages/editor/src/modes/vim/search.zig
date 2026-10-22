//! The last search pattern (`/`, `?`, `*`, `#`), compiled once and used
//! by `n`, `N`, `:s` and `:g`, with its offset (`/pat/e+1`). Searches wrap
//! around the end of the buffer ('wrapscan'), and like Vim (cpoptions
//! `c`) a forward search continues at the end of a match that covers the
//! cursor rather than one character after it.

const std = @import("std");
const zg_regex = @import("zg_regex");
const pattern = @import("pattern.zig");
const find = @import("../../model/search/find.zig");
const pt = @import("../../model/buffer/piece_tree.zig");

const Allocator = std.mem.Allocator;
const PieceTree = pt.PieceTree;

/// A search offset (search-offset): lines below or above the match
/// (`+2`), or characters from its start (`s-1`, `b+1`) or end (`e`).
pub const Offset = struct {
    pub const Kind = enum { none, line, start, end };
    kind: Kind = .none,
    n: i64 = 0,

    /// Parses the text after the closing delimiter; null when it is not
    /// an offset.
    pub fn parse(s: []const u8) ?Offset {
        if (s.len == 0) return .{};
        var o: Offset = .{ .kind = .line };
        var rest = s;
        switch (s[0]) {
            'e' => o.kind = .end,
            's', 'b' => o.kind = .start,
            else => {},
        }
        if (o.kind != .line) rest = s[1..];
        if (rest.len == 0) return o;
        var sign: i64 = 1;
        if (rest[0] == '+' or rest[0] == '-') {
            if (rest[0] == '-') sign = -1;
            rest = rest[1..];
            if (rest.len == 0) {
                o.n = sign;
                return o;
            }
        } else if (o.kind != .line) return null;
        const v = std.fmt.parseInt(i64, rest, 10) catch return null;
        o.n = sign * v;
        return o;
    }
};

pub const Match = struct { start: u64, end: u64 };

pub const Search = struct {
    gpa: Allocator,
    offset: Offset = .{},
    /// The pattern as typed (Vim syntax); empty when none was used yet.
    pattern: std.ArrayList(u8) = .empty,
    backward: bool = false,
    re: ?zg_regex.Regex = null,
    cache: ?zg_regex.Cache = null,
    /// Captures for patterns with `\zs`/`\ze` (`matchGroup`).
    caps: ?zg_regex.Captures = null,
    /// The case flags `re` was compiled with.
    case: struct { ignorecase: bool, smartcase: bool } = .{ .ignorecase = false, .smartcase = false },

    pub fn init(gpa: Allocator) Search {
        return .{ .gpa = gpa };
    }

    pub fn deinit(s: *Search) void {
        s.drop();
        s.pattern.deinit(s.gpa);
    }

    fn drop(s: *Search) void {
        if (s.caps) |*c| c.deinit(s.gpa);
        s.caps = null;
        if (s.cache) |*c| c.deinit();
        if (s.re) |*r| r.deinit(s.gpa);
        s.cache = null;
        s.re = null;
    }

    /// The capture index of `\zs`/`\ze`'s group, or null.
    pub fn matchGroup(re: *const zg_regex.Regex) ?usize {
        for (re.captureNames(), 0..) |n, i| if (n) |name| if (std.mem.eql(u8, name, pattern.match_group)) return i;
        return null;
    }

    /// Compiles Vim pattern `vim_pat` (without changing the last search).
    pub fn compile(gpa: Allocator, vim_pat: []const u8, flags: pattern.Flags) !zg_regex.Regex {
        const re_src = try pattern.translatePattern(gpa, vim_pat, flags);
        defer gpa.free(re_src);
        var diag: zg_regex.Error = undefined;
        return zg_regex.Regex.compile(gpa, re_src, .{ .multi_line = true, .crlf = true, .diag = &diag }) catch |e| switch (e) {
            error.Syntax => {
                if (flags.diag) |d| d.* = .{ .start = 0, .end = vim_pat.len, .msg = "invalid pattern" };
                return error.Syntax;
            },
            else => return e,
        };
    }

    /// Makes `vim_pat` the last search pattern.
    pub fn set(s: *Search, vim_pat: []const u8, backward: bool, flags: pattern.Flags) !void {
        // The same pattern again (`:g/pat/s//x/` runs :s per line) keeps
        // the compiled regex.
        if (s.re != null and std.mem.eql(u8, vim_pat, s.pattern.items) and
            s.case.ignorecase == flags.ignorecase and s.case.smartcase == flags.smartcase)
        {
            s.backward = backward;
            s.offset = .{};
            return;
        }
        var re = try compile(s.gpa, vim_pat, flags);
        errdefer re.deinit(s.gpa);
        var cache = try re.newCache(s.gpa);
        errdefer cache.deinit();
        const caps: ?zg_regex.Captures = if (matchGroup(&re) != null) try re.newCaptures(s.gpa) else null;
        s.drop();
        s.re = re;
        s.cache = cache;
        s.caps = caps;
        s.case = .{ .ignorecase = flags.ignorecase, .smartcase = flags.smartcase };
        s.backward = backward;
        s.offset = .{};
        if (vim_pat.ptr != s.pattern.items.ptr) {
            s.pattern.clearRetainingCapacity();
            try s.pattern.appendSlice(s.gpa, vim_pat);
        }
    }

    /// The start of the next match after `pos` (or the last one before it),
    /// wrapping around; null when the pattern does not match at all.
    pub fn next(s: *Search, t: *const PieceTree, pos: u64, backward: bool) ?u64 {
        const m = s.nextMatch(t, pos, backward) orelse return null;
        return m.start;
    }

    /// The next match itself (see `next`).
    pub fn nextMatch(s: *Search, t: *const PieceTree, pos: u64, backward: bool) ?Match {
        const re = &(s.re orelse return null);
        const cache = &s.cache.?;
        const len = t.len();
        const in = find.treeInput(t);
        const group = matchGroup(re);
        if (!backward) {
            // Matches from the start of the cursor's line, each search
            // going on at the end of the one before, the first that
            // starts after the cursor.
            const from = t.lineStart(t.lineOf(@min(pos, len)));
            var it = re.findIter(cache, in.withSpan(.{ .start = from, .end = len }));
            while (it.next()) |m| {
                const em = s.effective(group, in, m);
                if (em.start > pos) return em;
            }
            var it2 = re.findIter(cache, in);
            const m = it2.next() orelse return null;
            return s.effective(group, in, m);
        }
        // Backward: the last match starting before `pos`, else the last
        // match in the buffer.
        var it = re.findIter(cache, in);
        var before: ?Match = null;
        var last: ?Match = null;
        while (it.next()) |m| {
            const em = s.effective(group, in, m);
            if (em.start < pos) before = em;
            last = em;
        }
        return before orelse last;
    }

    /// The part of match `m` between `\zs` and `\ze` (all of it without).
    fn effective(s: *Search, group: ?usize, in: zg_regex.Input, m: zg_regex.Match) Match {
        const g = group orelse return .{ .start = m.start, .end = m.end };
        const caps = &s.caps.?;
        if (!s.re.?.captures(&s.cache.?, in.withSpan(.{ .start = m.start, .end = m.end }).withAnchored(true), caps)) return .{ .start = m.start, .end = m.end };
        const z = caps.get(g) orelse return .{ .start = m.start, .end = m.end };
        return .{ .start = z.start, .end = z.end };
    }

    /// Where the cursor goes for match `m` with the search offset.
    pub fn place(s: *const Search, t: *const PieceTree, m: Match) u64 {
        const len = t.len();
        switch (s.offset.kind) {
            .none => return m.start,
            .line => {
                const l: i64 = @intCast(t.lineOf(m.start));
                const last: i64 = @intCast(t.lineCount() - 1);
                return t.lineStart(@intCast(std.math.clamp(l + s.offset.n, 0, last)));
            },
            .start, .end => {
                var p = if (s.offset.kind == .start) m.start else if (m.end > m.start) prevChar(t, m.end) else m.start;
                var n = s.offset.n;
                while (n > 0 and p < len) : (n -= 1) p = nextChar(t, p);
                while (n < 0 and p > 0) : (n += 1) p = prevChar(t, p);
                return @min(p, len);
            },
        }
    }
};

fn prevChar(t: *const PieceTree, p: u64) u64 {
    var q = p - 1;
    while (q > 0 and t.byteAt(q) & 0xC0 == 0x80) q -= 1;
    return q;
}

fn nextChar(t: *const PieceTree, p: u64) u64 {
    var q = p + 1;
    while (q < t.len() and t.byteAt(q) & 0xC0 == 0x80) q += 1;
    return q;
}

test "vim: search wraps both ways" {
    const gpa = std.testing.allocator;
    const document = @import("../../model/document.zig");
    var doc = try document.Document.initBytes(gpa, @enumFromInt(1), "foo bar\nbaz foo\nqux");
    defer doc.deinit();
    var s: Search = .init(gpa);
    defer s.deinit();
    try std.testing.expectEqual(@as(?u64, null), s.next(&doc.tree, 0, false));
    try s.set("foo", false, .{});
    try std.testing.expectEqual(@as(?u64, 12), s.next(&doc.tree, 0, false));
    try std.testing.expectEqual(@as(?u64, 0), s.next(&doc.tree, 12, false));
    try std.testing.expectEqual(@as(?u64, 0), s.next(&doc.tree, 12, true));
    try std.testing.expectEqual(@as(?u64, 12), s.next(&doc.tree, 0, true));
    try s.set("\\<ba", false, .{});
    try std.testing.expectEqual(@as(?u64, 8), s.next(&doc.tree, 4, false));
    var d: pattern.Diag = .{};
    try std.testing.expectError(error.Unsupported, s.set("a\\@=b", false, .{ .diag = &d }));
    // A failed pattern keeps the last one.
    try std.testing.expectEqualStrings("\\<ba", s.pattern.items);
}
