//! Terminal selection (E06.F05.S02.T01, first cut): stream, word, line and
//! rectangle selections over the page list, and copying them as text.
//!
//! Points address absolute rows (`PageList.evicted` plus the row index),
//! so a selection stays on its text while output scrolls the screen. It
//! does not follow reflow: the view clears it on resize, and when its
//! first row is evicted.
//!
//! Words use VS Code's default `terminal.integrated.wordSeparators`, so
//! paths, URLs and `file.zig:12:5` select whole. Word and line bounds
//! follow soft wraps. Copying joins soft-wrapped rows, trims trailing
//! blanks per line, skips wide-character spacers and keeps graphemes
//! whole; rectangle rows each end with a newline.
//!
//! Open: semantic (command block) selection, ANSI and HTML copy, cold rows
//! (skipped when copying), and pins that survive reflow.

const std = @import("std");
const zg_terminal = @import("zg_terminal");

const Allocator = std.mem.Allocator;
const PageList = zg_terminal.screen.PageList;
const Pin = zg_terminal.screen.Pin;
const Cell = zg_terminal.screen.Cell;

/// A cell: absolute row and column.
pub const Point = struct {
    row: u64,
    col: u16,

    pub fn before(a: Point, b: Point) bool {
        return a.row < b.row or (a.row == b.row and a.col < b.col);
    }
};

/// How the selection grows from its anchor.
pub const Kind = enum { stream, word, line, rect };

/// VS Code's default word separators.
pub const default_separators = " ()[]{}',\"`─‘’“”|";

/// A selection: the anchor's unit (a cell, a word or a line) and the
/// resolved range, `lo` to `hi` inclusive. For `rect`, `lo` and `hi` are
/// the top-left and bottom-right corners.
pub const Selection = struct {
    kind: Kind,
    anchor_lo: Point,
    anchor_hi: Point,
    lo: Point,
    hi: Point,

    /// The columns of `row` it covers, end exclusive, or null.
    pub fn rowSpan(s: *const Selection, row: u64, cols: u16) ?[2]u16 {
        if (row < s.lo.row or row > s.hi.row) return null;
        if (s.kind == .rect) return .{ @min(s.lo.col, cols), @min(s.hi.col + 1, cols) };
        const a: u16 = if (row == s.lo.row) @min(s.lo.col, cols) else 0;
        const b: u16 = if (row == s.hi.row) @min(s.hi.col + 1, cols) else cols;
        return if (a < b) .{ a, b } else null;
    }

    /// Whether it covers cell `p`.
    pub fn contains(s: *const Selection, p: Point, cols: u16) bool {
        const span = s.rowSpan(p.row, cols) orelse return false;
        return p.col >= span[0] and p.col < span[1];
    }
};

/// The pin of absolute row `row`, or null when evicted or cold.
pub fn rowPin(pl: *const PageList, row: u64) ?Pin {
    if (row < pl.evicted) return null;
    return pl.screenRow(row - pl.evicted);
}

/// The absolute row of `p`.
pub fn absRow(pl: *const PageList, p: Pin) u64 {
    return pl.evicted + pl.rowIndex(p);
}

/// A selection of `kind` started at `at`.
pub fn begin(pl: *const PageList, at: Point, kind: Kind) Selection {
    const unit: [2]Point = switch (kind) {
        .stream, .rect => .{ at, at },
        .word => wordBounds(pl, at, default_separators),
        .line => lineBounds(pl, at),
    };
    return .{ .kind = kind, .anchor_lo = unit[0], .anchor_hi = unit[1], .lo = unit[0], .hi = unit[1] };
}

/// Moves the selection's free end to `to`, keeping the anchor's unit.
pub fn extend(pl: *const PageList, s: *Selection, to: Point) void {
    switch (s.kind) {
        .rect => {
            const a = s.anchor_lo;
            s.lo = .{ .row = @min(a.row, to.row), .col = @min(a.col, to.col) };
            s.hi = .{ .row = @max(a.row, to.row), .col = @max(a.col, to.col) };
        },
        .stream, .word, .line => {
            const unit: [2]Point = switch (s.kind) {
                .word => wordBounds(pl, to, default_separators),
                .line => lineBounds(pl, to),
                else => .{ to, to },
            };
            if (unit[0].before(s.anchor_lo)) {
                s.lo = unit[0];
                s.hi = s.anchor_hi;
            } else {
                s.lo = s.anchor_lo;
                s.hi = if (s.anchor_hi.before(unit[1])) unit[1] else s.anchor_hi;
            }
        },
    }
}

const Class = enum { space, sep, word };

fn classAt(pl: *const PageList, p: Point, seps: []const u8) Class {
    const pin = rowPin(pl, p.row) orelse return .space;
    const cells = pin.cells();
    if (p.col >= cells.len) return .space;
    var c = cells[p.col];
    // The second column of a wide character is part of it.
    if (c.wide == .spacer_tail and p.col > 0) c = cells[p.col - 1];
    if (c.wide == .spacer_head) return .space;
    const cp = c.codepoint();
    if (cp == 0 or cp == ' ') return .space;
    var it = std.unicode.Utf8View.initUnchecked(seps).iterator();
    while (it.nextCodepoint()) |s| if (s == cp) return .sep;
    return .word;
}

/// The cell after `p` in reading order, following soft wraps only.
fn nextCell(pl: *const PageList, p: Point) ?Point {
    if (p.col + 1 < pl.cols) return .{ .row = p.row, .col = p.col + 1 };
    const pin = rowPin(pl, p.row) orelse return null;
    if (!pin.row().wrap) return null;
    return .{ .row = p.row + 1, .col = 0 };
}

/// The cell before `p` in reading order, following soft wraps only.
fn prevCell(pl: *const PageList, p: Point) ?Point {
    if (p.col > 0) return .{ .row = p.row, .col = p.col - 1 };
    if (p.row == 0) return null;
    const pin = rowPin(pl, p.row - 1) orelse return null;
    if (!pin.row().wrap) return null;
    return .{ .row = p.row - 1, .col = pl.cols - 1 };
}

/// The run of cells of the same class as `at` (word characters, or
/// blanks, or a single separator), across soft wraps.
pub fn wordBounds(pl: *const PageList, at: Point, seps: []const u8) [2]Point {
    const cls = classAt(pl, at, seps);
    if (cls == .sep) return .{ at, at };
    var lo = at;
    while (prevCell(pl, lo)) |p| {
        if (classAt(pl, p, seps) != cls) break;
        lo = p;
    }
    var hi = at;
    while (nextCell(pl, hi)) |p| {
        if (classAt(pl, p, seps) != cls) break;
        hi = p;
    }
    return .{ lo, hi };
}

/// The logical line (soft-wrapped rows joined) holding `at`.
pub fn lineBounds(pl: *const PageList, at: Point) [2]Point {
    var first = at.row;
    while (first > 0) {
        const p = rowPin(pl, first - 1) orelse break;
        if (!p.row().wrap) break;
        first -= 1;
    }
    var last = at.row;
    while (rowPin(pl, last)) |p| {
        if (!p.row().wrap or rowPin(pl, last + 1) == null) break;
        last += 1;
    }
    return .{ .{ .row = first, .col = 0 }, .{ .row = last, .col = pl.cols - 1 } };
}

/// Appends the selected text to `out`.
pub fn copyText(pl: *const PageList, s: *const Selection, out: *std.ArrayList(u8), gpa: Allocator) !void {
    var line_start = out.items.len;
    var row = s.lo.row;
    while (row <= s.hi.row) : (row += 1) {
        const pin = rowPin(pl, row);
        if (pin) |p| if (s.rowSpan(row, pl.cols)) |span| {
            const cells = p.cells();
            const end = @min(span[1], cells.len);
            for (cells[@min(span[0], end)..end]) |c| {
                if (c.wide == .spacer_tail or c.wide == .spacer_head) continue;
                try appendCell(out, gpa, &p.node.page, c);
            }
        };
        if (row == s.hi.row) break;
        // A soft wrap joins the rows (unless only a column band is copied).
        const joined = s.kind != .rect and pin != null and pin.?.row().wrap;
        if (joined) continue;
        trimLine(out, line_start);
        try out.append(gpa, '\n');
        line_start = out.items.len;
    }
    trimLine(out, line_start);
}

fn trimLine(out: *std.ArrayList(u8), start: usize) void {
    while (out.items.len > start and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
}

fn appendCell(out: *std.ArrayList(u8), gpa: Allocator, page: *const zg_terminal.screen.Page, c: Cell) !void {
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

const testing = std.testing;

fn termWith(cols: u16, rows: u16, text: []const u8) !zg_terminal.Terminal {
    var t: zg_terminal.Terminal = try .init(testing.allocator, .{ .cols = cols, .rows = rows });
    t.feed(text);
    return t;
}

fn copied(pl: *const PageList, s: *const Selection) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    try copyText(pl, s, &out, testing.allocator);
    return out.toOwnedSlice(testing.allocator);
}

test "word bounds: paths and file:line:col stay whole, separators stop" {
    var t = try termWith(40, 3, "see (src/a.zig:12:5) and https://x.io/q");
    defer t.deinit();
    const pl = &t.screen().pages;
    const r = absRow(pl, pl.activeRow(0));
    var s = begin(pl, .{ .row = r, .col = 8 }, .word);
    var text = try copied(pl, &s);
    try testing.expectEqualStrings("src/a.zig:12:5", text);
    testing.allocator.free(text);
    s = begin(pl, .{ .row = r, .col = 30 }, .word);
    text = try copied(pl, &s);
    try testing.expectEqualStrings("https://x.io/q", text);
    testing.allocator.free(text);
    // A separator selects alone.
    s = begin(pl, .{ .row = r, .col = 4 }, .word);
    try testing.expectEqual(s.lo, s.hi);
}

test "line selection joins soft wraps; copy trims and ends lines" {
    // 10 columns: the first line wraps once.
    var t = try termWith(10, 4, "abcdefghijklm\r\nxy   \r\nz");
    defer t.deinit();
    const pl = &t.screen().pages;
    const r0 = absRow(pl, pl.activeRow(0));
    var s = begin(pl, .{ .row = r0 + 1, .col = 1 }, .line);
    try testing.expectEqual(r0, s.lo.row);
    try testing.expectEqual(r0 + 1, s.hi.row);
    var text = try copied(pl, &s);
    try testing.expectEqualStrings("abcdefghijklm", text);
    testing.allocator.free(text);

    // A stream over all three lines: the wrap joins, trailing blanks go.
    s = begin(pl, .{ .row = r0, .col = 2 }, .stream);
    extend(pl, &s, .{ .row = r0 + 3, .col = 0 });
    text = try copied(pl, &s);
    try testing.expectEqualStrings("cdefghijklm\nxy\nz", text);
    testing.allocator.free(text);

    // Extending backwards keeps the anchor cell.
    s = begin(pl, .{ .row = r0 + 2, .col = 1 }, .stream);
    extend(pl, &s, .{ .row = r0, .col = 8 });
    text = try copied(pl, &s);
    try testing.expectEqualStrings("ijklm\nxy", text);
    testing.allocator.free(text);
}

test "rect selection copies a column band per row" {
    var t = try termWith(10, 3, "abcdef\r\n123456\r\nuvwxyz");
    defer t.deinit();
    const pl = &t.screen().pages;
    const r0 = absRow(pl, pl.activeRow(0));
    var s = begin(pl, .{ .row = r0 + 2, .col = 4 }, .rect);
    extend(pl, &s, .{ .row = r0, .col = 1 });
    const text = try copied(pl, &s);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("bcde\n2345\nvwxy", text);
    try testing.expect(s.contains(.{ .row = r0 + 1, .col = 3 }, 10));
    try testing.expect(!s.contains(.{ .row = r0 + 1, .col = 5 }, 10));
}

test "wide characters copy once and select whole as words" {
    var t = try termWith(10, 2, "a 日本 b");
    defer t.deinit();
    const pl = &t.screen().pages;
    const r0 = absRow(pl, pl.activeRow(0));
    // Column 3 is the spacer of 日.
    const s = begin(pl, .{ .row = r0, .col = 3 }, .word);
    const text = try copied(pl, &s);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("日本", text);
}

test "absolute rows survive scrolling" {
    var t = try termWith(10, 2, "one\r\ntwo");
    defer t.deinit();
    const pl = &t.screen().pages;
    const s = begin(pl, .{ .row = absRow(pl, pl.activeRow(0)), .col = 0 }, .line);
    t.feed("\r\nthree\r\nfour");
    const text = try copied(pl, &s);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("one", text);
}
