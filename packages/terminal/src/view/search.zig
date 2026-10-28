//! Terminal scrollback search (E06.F05.S03.T01, first cut): literal or
//! regex (zg_regex), smart, sensitive or insensitive case, whole words,
//! across soft-wrapped rows.
//!
//! A search copies the hot rows' text as logical lines (soft-wrapped rows
//! joined, trailing blanks trimmed, one `\n` per line) with the byte
//! offset of every row, runs the regex over it once, and maps match
//! offsets back to cells. Matches hold absolute points (see
//! `selection.zig`), so they stay on their text while output scrolls;
//! `prune` drops the ones whose rows were evicted. Output that arrives
//! after a search is found by the next one (Enter searches again).
//!
//! It runs on the calling thread: the hot rows are capped
//! (`hot_scrollback_rows`, 10 000 by default), which bounds the work.
//! Open: cold scrollback, a worker with incremental viewport-first
//! results and cancellation, live updates as output arrives.

const std = @import("std");
const zg_terminal = @import("zg_terminal");
const zg_regex = @import("zg_regex");
const sel = @import("selection.zig");

const Allocator = std.mem.Allocator;
const PageList = zg_terminal.screen.PageList;
const Pin = zg_terminal.screen.Pin;
const Point = sel.Point;

/// Case handling: smart is insensitive unless the pattern has an
/// uppercase letter.
pub const Case = enum { smart, sensitive, insensitive };

/// What to look for.
pub const Query = struct {
    pattern: []const u8,
    regex: bool = false,
    case: Case = .smart,
    whole_word: bool = false,
};

/// A match: first and last cell, inclusive (a wide last character's
/// second column included).
pub const Match = struct { lo: Point, hi: Point };

/// Which way `step` moves: towards older output (up) or newer (down).
pub const Direction = enum { older, newer };

/// More matches than this are not kept.
pub const max_matches = 20_000;

/// The results of the last search and the current match.
pub const Search = struct {
    gpa: Allocator,
    /// Sorted by position.
    matches: std.ArrayList(Match) = .empty,
    current: ?usize = null,
    /// More than `max_matches` matched.
    capped: bool = false,
    /// Why the pattern did not compile (shown instead of a count).
    err_buf: [96]u8 = undefined,
    err_len: usize = 0,

    pub fn init(gpa: Allocator) Search {
        return .{ .gpa = gpa };
    }

    pub fn deinit(s: *Search) void {
        s.matches.deinit(s.gpa);
    }

    /// Forgets the results.
    pub fn clear(s: *Search) void {
        s.matches.clearRetainingCapacity();
        s.current = null;
        s.capped = false;
        s.err_len = 0;
    }

    /// The pattern error, or "".
    pub fn errorText(s: *const Search) []const u8 {
        return s.err_buf[0..s.err_len];
    }

    /// The current match.
    pub fn currentMatch(s: *const Search) ?Match {
        return s.matches.items[s.current orelse return null];
    }

    /// Searches the hot rows of `pl` for `q`. The current match becomes
    /// the newest one at or above row `bottom` (the viewport's last row),
    /// else the oldest below it.
    pub fn run(s: *Search, pl: *const PageList, q: Query, bottom: u64) !void {
        s.clear();
        if (q.pattern.len == 0) return;
        var diag: zg_regex.Error = undefined;
        var re = zg_regex.Regex.compile(s.gpa, q.pattern, .{
            .literal = !q.regex,
            .case_insensitive = switch (q.case) {
                .smart => zg_regex.smartCaseInsensitive(q.pattern),
                .sensitive => false,
                .insensitive => true,
            },
            .whole_word = q.whole_word,
            .multi_line = true,
            .diag = &diag,
        }) catch |e| {
            const msg = switch (e) {
                error.Syntax => zg_regex.errorMessage(diag),
                error.SizeLimitExceeded => "pattern too large",
                error.OutOfMemory => return e,
            };
            s.err_len = @min(msg.len, s.err_buf.len);
            @memcpy(s.err_buf[0..s.err_len], msg[0..s.err_len]);
            return;
        };
        defer re.deinit(s.gpa);
        var cache = try re.newCache(s.gpa);
        defer cache.deinit();

        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(s.gpa);
        var rows: std.ArrayList(RowStart) = .empty;
        defer rows.deinit(s.gpa);
        try buildText(pl, s.gpa, &text, &rows, null, null);

        var it = re.findIter(&cache, zg_regex.Input.fromSlice(text.items));
        while (it.next()) |m| {
            if (m.start == m.end) continue;
            if (s.matches.items.len == max_matches) {
                s.capped = true;
                break;
            }
            const lo = pointAt(pl, rows.items, @intCast(m.start)) orelse continue;
            var hi = pointAt(pl, rows.items, @intCast(m.end - 1)) orelse continue;
            if (sel.rowPin(pl, hi.row)) |p| {
                const cells = p.cells();
                if (hi.col < cells.len and cells[hi.col].wide == .wide) hi.col += 1;
            }
            try s.matches.append(s.gpa, .{ .lo = lo, .hi = hi });
        }
        if (s.matches.items.len == 0) return;
        const after = s.firstFrom(bottom + 1);
        s.current = if (after > 0) after - 1 else 0;
    }

    /// Moves to the next match in `dir` (wrapping) and returns it.
    pub fn step(s: *Search, dir: Direction) ?Match {
        const n = s.matches.items.len;
        if (n == 0) return null;
        const c = s.current orelse n - 1;
        s.current = switch (dir) {
            .older => if (c == 0) n - 1 else c - 1,
            .newer => if (c + 1 == n) 0 else c + 1,
        };
        return s.currentMatch();
    }

    /// The index of the first match ending on or after `row`.
    pub fn firstFrom(s: *const Search, row: u64) usize {
        var lo: usize = 0;
        var hi: usize = s.matches.items.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (s.matches.items[mid].hi.row < row) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    /// Drops matches on rows before `first_row` (evicted).
    pub fn prune(s: *Search, first_row: u64) void {
        const n = s.firstFrom(first_row);
        if (n == 0) return;
        // A match straddling the cut goes too.
        var cut = n;
        while (cut < s.matches.items.len and s.matches.items[cut].lo.row < first_row) cut += 1;
        const removed = cut;
        std.mem.copyForwards(Match, s.matches.items, s.matches.items[removed..]);
        s.matches.items.len -= removed;
        if (s.current) |c| s.current = if (c >= removed) c - removed else if (s.matches.items.len > 0) 0 else null;
    }
};

/// Where a row's text starts in `buildText`'s output.
pub const RowStart = struct { off: u32, row: u64 };

/// The hot rows (or absolute rows `first` to `last`) as logical lines,
/// and where each row starts in them.
pub fn buildText(pl: *const PageList, gpa: Allocator, text: *std.ArrayList(u8), rows: *std.ArrayList(RowStart), first: ?u64, last: ?u64) !void {
    var pin: ?Pin = if (first) |f| sel.rowPin(pl, f) else pl.firstHot();
    var abs = if (pin) |p| sel.absRow(pl, p) else return;
    while (pin) |p| : (abs += 1) {
        if (last) |l| if (abs > l) break;
        const start = text.items.len;
        try rows.append(gpa, .{ .off = @intCast(start), .row = abs });
        for (p.cells()) |c| try appendCell(text, gpa, &p.node.page, c);
        if (!p.row().wrap) {
            while (text.items.len > start and text.items[text.items.len - 1] == ' ') text.items.len -= 1;
            try text.append(gpa, '\n');
        }
        pin = PageList.next(p);
    }
}

fn appendCell(out: *std.ArrayList(u8), gpa: Allocator, page: *const zg_terminal.screen.Page, c: zg_terminal.screen.Cell) !void {
    if (c.wide == .spacer_tail or c.wide == .spacer_head) return;
    const cp = c.codepoint();
    if (cp == 0) return out.append(gpa, ' ');
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch return;
    try out.appendSlice(gpa, buf[0..n]);
    if (page.grapheme(&c)) |extra| for (extra) |x| {
        const k = std.unicode.utf8Encode(x, &buf) catch continue;
        try out.appendSlice(gpa, buf[0..k]);
    };
}

/// The cell holding text byte `off` of `buildText`'s output.
pub fn pointAt(pl: *const PageList, rows: []const RowStart, off: u32) ?Point {
    // The last row starting at or before `off`.
    var lo: usize = 0;
    var hi: usize = rows.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (rows[mid].off <= off) lo = mid + 1 else hi = mid;
    }
    if (lo == 0) return null;
    const r = rows[lo - 1];
    const p = sel.rowPin(pl, r.row) orelse return null;
    // Walk the row's cells to the one whose text holds the byte.
    var at: u32 = r.off;
    var last: u16 = 0;
    for (p.cells(), 0..) |c, x| {
        if (c.wide == .spacer_tail or c.wide == .spacer_head) continue;
        const len = textLen(&p.node.page, c);
        last = @intCast(x);
        if (off < at + len) return .{ .row = r.row, .col = last };
        at += len;
    }
    return .{ .row = r.row, .col = last };
}

/// The bytes `appendCell` writes for `c`.
fn textLen(page: *const zg_terminal.screen.Page, c: zg_terminal.screen.Cell) u32 {
    const cp = c.codepoint();
    if (cp == 0) return 1;
    var n: u32 = std.unicode.utf8CodepointSequenceLength(cp) catch 1;
    if (page.grapheme(&c)) |extra| for (extra) |x| {
        n += std.unicode.utf8CodepointSequenceLength(x) catch 0;
    };
    return n;
}

const testing = std.testing;

fn termWith(cols: u16, rows: u16, text: []const u8) !zg_terminal.Terminal {
    var t: zg_terminal.Terminal = try .init(testing.allocator, .{ .cols = cols, .rows = rows });
    t.feed(text);
    return t;
}

test "search: literal, smart case, whole word and regex" {
    var t = try termWith(20, 4, "Foo foo food\r\nbar Foo\r\nx1 y22 z333");
    defer t.deinit();
    const pl = &t.screen().pages;
    const r0 = sel.absRow(pl, pl.activeRow(0));
    var s = Search.init(testing.allocator);
    defer s.deinit();
    const bottom = r0 + 3;

    try s.run(pl, .{ .pattern = "foo" }, bottom);
    try testing.expectEqual(@as(usize, 4), s.matches.items.len);
    // The newest match is current.
    try testing.expectEqual(Match{ .lo = .{ .row = r0 + 1, .col = 4 }, .hi = .{ .row = r0 + 1, .col = 6 } }, s.currentMatch().?);

    try s.run(pl, .{ .pattern = "Foo" }, bottom);
    try testing.expectEqual(@as(usize, 2), s.matches.items.len);
    try s.run(pl, .{ .pattern = "foo", .case = .sensitive, .whole_word = true }, bottom);
    try testing.expectEqual(@as(usize, 1), s.matches.items.len);
    try testing.expectEqual(@as(u16, 4), s.matches.items[0].lo.col);

    try s.run(pl, .{ .pattern = "[a-z]\\d{2,}", .regex = true }, bottom);
    try testing.expectEqual(@as(usize, 2), s.matches.items.len);
    try testing.expectEqual(Point{ .row = r0 + 2, .col = 10 }, s.matches.items[1].hi);

    try s.run(pl, .{ .pattern = "(", .regex = true }, bottom);
    try testing.expect(s.errorText().len > 0);
    try testing.expectEqual(@as(usize, 0), s.matches.items.len);
}

test "search: matches span soft wraps; step wraps around" {
    // 8 columns: "hello world" wraps after "hello wo".
    var t = try termWith(8, 4, "hello world\r\nworld");
    defer t.deinit();
    const pl = &t.screen().pages;
    const r0 = sel.absRow(pl, pl.activeRow(0));
    var s = Search.init(testing.allocator);
    defer s.deinit();
    try s.run(pl, .{ .pattern = "world" }, r0 + 3);
    try testing.expectEqual(@as(usize, 2), s.matches.items.len);
    try testing.expectEqual(Match{ .lo = .{ .row = r0, .col = 6 }, .hi = .{ .row = r0 + 1, .col = 2 } }, s.matches.items[0]);
    try testing.expectEqual(@as(?usize, 1), s.current);
    try testing.expectEqual(s.matches.items[0], s.step(.older).?);
    try testing.expectEqual(s.matches.items[1], s.step(.older).?);
    try testing.expectEqual(s.matches.items[0], s.step(.newer).?);
}

test "search: wide characters map to their cells; prune drops evicted rows" {
    var t = try termWith(10, 3, "日本語 ok\r\nok");
    defer t.deinit();
    const pl = &t.screen().pages;
    const r0 = sel.absRow(pl, pl.activeRow(0));
    var s = Search.init(testing.allocator);
    defer s.deinit();
    try s.run(pl, .{ .pattern = "本" }, r0 + 2);
    try testing.expectEqual(Match{ .lo = .{ .row = r0, .col = 2 }, .hi = .{ .row = r0, .col = 3 } }, s.matches.items[0]);
    try s.run(pl, .{ .pattern = "ok" }, r0 + 2);
    try testing.expectEqual(@as(u16, 7), s.matches.items[0].lo.col);
    s.prune(r0 + 1);
    try testing.expectEqual(@as(usize, 1), s.matches.items.len);
    try testing.expectEqual(r0 + 1, s.matches.items[0].lo.row);
    try testing.expectEqual(@as(?usize, 0), s.current);
}
