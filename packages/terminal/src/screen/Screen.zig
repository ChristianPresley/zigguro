//! A screen: a page list plus cursor, saved cursor, charsets, margins and
//! the region operations the control functions use (scroll, erase,
//! insert/delete cells, lines and columns). The terminal owns two screens
//! (primary with scrollback, alternate without) and switches between them.
//!
//! All coordinates are active-area coordinates, 0-based. Every operation
//! keeps the page invariants (`checkInvariants`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Page = @import("Page.zig");
const PageList = @import("PageList.zig");
const reflow = @import("reflow.zig");
const style_mod = @import("style.zig");
const cell_mod = @import("cell.zig");
const unicode = @import("unicode.zig");
const print_mod = @import("print.zig");
const fill = @import("fill.zig");

pub const Cell = cell_mod.Cell;
pub const Row = cell_mod.Row;
pub const Style = style_mod.Style;
pub const Color = style_mod.Color;
pub const Pin = PageList.Pin;
pub const Link = Page.Link;

const Screen = @This();

/// A rectangle of rows and columns (inclusive bounds).
pub const Region = struct {
    top: u16,
    bottom: u16,
    left: u16,
    right: u16,

    /// Whether the region spans every column.
    pub fn fullWidth(r: Region, cols: u16) bool {
        return r.left == 0 and r.right == cols - 1;
    }
};

/// The character sets designatable into G0-G3.
pub const Charset = enum { ascii, dec_special, uk };

/// Designated character sets and shift state.
pub const Charsets = struct {
    g: [4]Charset = @splat(.ascii),
    /// The set invoked into GL (SI/SO, LS2/LS3).
    gl: u2 = 0,
    /// The set invoked into GR (LS1R/LS2R/LS3R; used only with 8-bit input).
    gr: u2 = 2,
    /// A single shift (SS2/SS3) for the next printed character.
    single: ?u2 = null,
};

/// The kitty keyboard protocol flag stack (one per screen).
pub const KittyStack = struct {
    flags: [16]u5 = @splat(0),
    len: u5 = 0,

    /// The current flags (0 when the stack is empty).
    pub fn current(k: *const KittyStack) u5 {
        return if (k.len == 0) 0 else k.flags[k.len - 1];
    }
    /// Pushes flags; the oldest entry is dropped when full.
    pub fn push(k: *KittyStack, f: u5) void {
        if (k.len == k.flags.len) {
            std.mem.copyForwards(u5, k.flags[0 .. k.flags.len - 1], k.flags[1..]);
            k.len -= 1;
        }
        k.flags[k.len] = f;
        k.len += 1;
    }
    /// Pops `n` entries.
    pub fn pop(k: *KittyStack, n: u16) void {
        k.len -= @intCast(@min(n, k.len));
    }
    /// Replaces the current flags (mode 1 set, 2 or, 3 and-not).
    pub fn set(k: *KittyStack, f: u5, mode: u8) void {
        if (k.len == 0) k.push(0);
        const c = &k.flags[k.len - 1];
        c.* = switch (mode) {
            2 => c.* | f,
            3 => c.* & ~f,
            else => f,
        };
    }
};

/// An OSC 8 hyperlink held by the cursor (strings owned by the screen).
pub const CursorLink = struct { uri: []u8, id: []u8 };

/// The cursor and the attributes it applies to printed cells.
pub const Cursor = struct {
    x: u16 = 0,
    y: u16 = 0,
    /// The last column was written and autowrap is on: the next printable
    /// character wraps first (DEC "last column flag").
    pending_wrap: bool = false,
    style: Style = .{},
    /// DECSCA: printed cells are protected from selective erase.
    protected: bool = false,
    semantic: cell_mod.Semantic = .output,
    link: ?CursorLink = null,
    /// Cache of `style` interned in one page.
    cache_node: ?*PageList.Node = null,
    cache_id: u16 = 0,
};

/// State saved by DECSC / mode 1048 and restored by DECRC.
pub const SavedCursor = struct {
    x: u16,
    y: u16,
    pending_wrap: bool,
    style: Style,
    protected: bool,
    charsets: Charsets,
    /// DECOM at save time (owned by the terminal's modes).
    origin: bool,
    autowrap: bool = true,
};

/// Modes the print path and region ops consult (the terminal keeps them in
/// sync with its mode table).
pub const Modes = struct {
    autowrap: bool = true,
    insert: bool = false,
    /// Mode 2027: grapheme clustering with cluster widths.
    grapheme: bool = false,
    ambiguous_wide: bool = false,
};

/// Erase options.
pub const EraseOpts = struct {
    /// The style whose background fills erased cells (BCE).
    bce: Style = .{},
    /// DECSED/DECSEL: keep protected cells.
    selective: bool = false,
};

gpa: Allocator,
pages: PageList,
cursor: Cursor = .{},
saved: ?SavedCursor = null,
charsets: Charsets = .{},
region: Region,
modes: Modes = .{},
kitty_kb: KittyStack = .{},
/// The last printed cluster, for REP.
last_cluster: [17]u21 = undefined,
last_len: u8 = 0,
/// Styles dropped because a page's style table was full (debug stat).
dropped_styles: u32 = 0,

/// Screen options.
pub const Options = struct {
    max_bytes: usize = 64 << 20,
    scrollback: bool = true,
};

/// Creates a blank `cols` x `rows` screen.
pub fn init(gpa: Allocator, cols: u16, rows: u16, o: Options) !Screen {
    return .{
        .gpa = gpa,
        .pages = try .init(gpa, cols, rows, .{ .max_bytes = o.max_bytes, .scrollback = o.scrollback }),
        .region = .{ .top = 0, .bottom = rows - 1, .left = 0, .right = cols - 1 },
    };
}

/// Frees the pages and the cursor's hyperlink.
pub fn deinit(s: *Screen) void {
    s.setLink(null) catch unreachable;
    s.pages.deinit();
    s.* = undefined;
}

/// Columns.
pub inline fn width(s: *const Screen) u16 {
    return s.pages.cols;
}

/// Rows of the active area.
pub inline fn height(s: *const Screen) u16 {
    return s.pages.rows;
}

/// The whole screen as a region.
pub fn fullRegion(s: *const Screen) Region {
    return .{ .top = 0, .bottom = s.height() - 1, .left = 0, .right = s.width() - 1 };
}

/// The pin of active row `y`.
pub inline fn rowPin(s: *const Screen, y: u16) Pin {
    return s.pages.activeRow(y);
}

/// Sets (or clears) the cursor hyperlink; the strings are copied.
pub fn setLink(s: *Screen, l: ?Link) Allocator.Error!void {
    if (s.cursor.link) |old| {
        s.gpa.free(old.uri);
        s.gpa.free(old.id);
        s.cursor.link = null;
    }
    const nl = l orelse return;
    const uri = try s.gpa.dupe(u8, nl.uri);
    errdefer s.gpa.free(uri);
    s.cursor.link = .{ .uri = uri, .id = try s.gpa.dupe(u8, nl.id) };
}

/// The cursor style interned in `node` with `n` new references.
pub fn styleIn(s: *Screen, node: *PageList.Node, n: u32) u16 {
    const st = s.cursor.style;
    if (st.isDefault()) return 0;
    const p = &node.page;
    if (s.cursor.cache_node == node and s.cursor.cache_id != 0 and
        p.styleRefs(s.cursor.cache_id) > 0 and p.styleById(s.cursor.cache_id).eql(st))
    {
        p.retainStyle(s.cursor.cache_id, n);
        return s.cursor.cache_id;
    }
    const id = p.internStyle(st, n) catch {
        // Page splitting on a full style table lands with compaction
        // (E06.F03.S02.T01); until then the cell keeps the default style.
        s.dropped_styles += 1;
        return 0;
    };
    s.cursor.cache_node = node;
    s.cursor.cache_id = id;
    return id;
}

/// Changes the cursor style.
pub fn setStyle(s: *Screen, st: Style) void {
    s.cursor.style = st;
    s.cursor.cache_id = 0;
}

/// The blank cell an erase with `bce` writes.
pub fn bceCell(bce: Style) Cell {
    return switch (bce.bg.tag) {
        .default => .blank,
        .palette => .{ .tag = .bg_palette, .content = bce.bg.r },
        .rgb => .{ .tag = .bg_rgb, .content = (@as(u24, bce.bg.r) << 16) | (@as(u24, bce.bg.g) << 8) | bce.bg.b },
    };
}

fn markDirty(s: *Screen, r: *Row) void {
    r.dirty = true;
    s.pages.dirty_generation +%= 1;
}

/// Blanks the wide character that column `x` of `p` is part of, if any.
pub fn splitWide(s: *Screen, p: Pin, x: u16) void {
    _ = s;
    const cs = p.cells();
    const page = &p.node.page;
    switch (cs[x].wide) {
        .wide => {
            page.clearCell(&cs[x], .blank);
            if (x + 1 < cs.len) page.clearCell(&cs[x + 1], .blank);
        },
        .spacer_tail => {
            page.clearCell(&cs[x], .blank);
            if (x > 0) page.clearCell(&cs[x - 1], .blank);
        },
        .spacer_head, .narrow => {},
    }
}

/// Clears cells `[x0, x1)` of active row `y`.
pub fn eraseCells(s: *Screen, y: u16, x0: u16, x1: u16, o: EraseOpts) void {
    if (x0 >= x1) return;
    const p = s.rowPin(y);
    const r = p.row();
    const cs = p.cells();
    const page = &p.node.page;
    if (cs[x0].wide == .spacer_tail) s.splitWide(p, x0);
    if (x1 < cs.len and cs[x1 - 1].wide == .wide) s.splitWide(p, x1 - 1);
    const blank = bceCell(o.bce);
    if (o.selective) {
        for (cs[x0..x1]) |*c| if (!c.protected) page.clearCell(c, blank);
    } else {
        page.clearCells(r, cs[x0..x1], blank);
    }
    if (x1 == cs.len) r.wrap = false;
    s.markDirty(r);
}

/// Clears a whole row, resetting its flags.
fn clearRow(s: *Screen, p: Pin, o: EraseOpts) void {
    const r = p.row();
    const page = &p.node.page;
    const blank = bceCell(o.bce);
    const cs = p.cells();
    if (o.selective) {
        for (cs) |*c| if (!c.protected) page.clearCell(c, blank);
        r.wrap = false;
    } else {
        page.clearCells(r, cs, blank);
        r.* = .{ .cells_off = r.cells_off };
    }
    s.markDirty(r);
}

/// ED: erases part of the display.
pub fn eraseDisplay(s: *Screen, mode: enum { below, above, all, scrollback }, o: EraseOpts) !void {
    const c = s.cursor;
    switch (mode) {
        .below => {
            s.eraseCells(c.y, c.x, s.width(), o);
            var y = c.y + 1;
            while (y < s.height()) : (y += 1) s.clearRow(s.rowPin(y), o);
        },
        .above => {
            for (0..c.y) |y| s.clearRow(s.rowPin(@intCast(y)), o);
            s.eraseCells(c.y, 0, c.x + 1, o);
        },
        .all => for (0..s.height()) |y| s.clearRow(s.rowPin(@intCast(y)), o),
        .scrollback => try s.pages.eraseScrollback(),
    }
    s.cursor.pending_wrap = false;
}

/// Moves the content of row `src` into row `dst` (full width). Afterwards
/// `src` holds valid but unspecified content (the caller clears it).
fn moveRow(s: *Screen, dst: Pin, src: Pin) void {
    if (dst.node == src.node) {
        const a = dst.row();
        const b = src.row();
        std.mem.swap(Row, a, b);
    } else {
        s.clearRow(dst, .{});
        PageList.copyRow(dst, src);
    }
    dst.row().dirty = true;
    src.row().dirty = true;
    s.pages.movePins(src, dst);
}

/// Moves cells `[left, right]` of `src` into the same columns of `dst`.
fn moveRange(s: *Screen, dst: Pin, src: Pin, left: u16, right: u16) void {
    const dc = dst.cells();
    const sc = src.cells();
    const dpage = &dst.node.page;
    const spage = &src.node.page;
    dpage.clearCells(dst.row(), dc[left .. right + 1], .blank);
    const sr = src.row().*;
    const dr = dst.row();
    dr.styled = dr.styled or sr.styled;
    dr.has_grapheme = dr.has_grapheme or sr.has_grapheme;
    dr.has_hyperlink = dr.has_hyperlink or sr.has_hyperlink;
    for (left..right + 1) |x| {
        if (dst.node == src.node) {
            dpage.moveCell(&dc[x], &sc[x]);
        } else {
            dpage.copyCellFrom(&dc[x], spage, &sc[x]);
            spage.clearCell(&sc[x], .blank);
        }
    }
    dr.wrap = false;
    src.row().wrap = false;
    s.markDirty(dr);
}

/// Blanks wide characters straddling the left or right edge of `r`.
fn splitEdges(s: *Screen, r: Region) void {
    if (r.fullWidth(s.width())) return;
    var y = r.top;
    while (y <= r.bottom) : (y += 1) {
        const p = s.rowPin(y);
        const cs = p.cells();
        if (cs[r.left].wide == .spacer_tail) s.splitWide(p, r.left);
        if (cs[r.right].wide == .wide) s.splitWide(p, r.right);
    }
}

/// Scrolls region `r` up by `n` rows, filling with blanks (BCE). A full
/// screen scroll on a screen with scrollback pushes rows into scrollback in
/// O(1) per row; anything else rotates rows within the region.
pub fn scrollUp(s: *Screen, r: Region, n_in: u16, o: EraseOpts) !void {
    return s.scrollUpImpl(r, n_in, o, true);
}

fn scrollUpImpl(s: *Screen, r: Region, n_in: u16, o: EraseOpts, into_scrollback: bool) !void {
    const h = r.bottom - r.top + 1;
    const n = @min(n_in, h);
    if (n == 0) return;
    if (into_scrollback and s.pages.opts.scrollback and r.top == 0 and r.bottom == s.height() - 1 and r.fullWidth(s.width())) {
        const blank = bceCell(o.bce);
        for (0..n) |_| {
            const p = try s.pages.grow();
            if (@as(u64, @bitCast(blank)) != 0) fill.fill(Cell, p.cells(), blank);
        }
        return;
    }
    s.splitEdges(r);
    // Content of the top n rows is destroyed.
    for (0..n) |i| s.pages.invalidatePins(s.rowPin(r.top + @as(u16, @intCast(i))));
    var y = r.top;
    while (y + n <= r.bottom) : (y += 1) {
        if (r.fullWidth(s.width())) {
            s.moveRow(s.rowPin(y), s.rowPin(y + n));
        } else {
            s.moveRange(s.rowPin(y), s.rowPin(y + n), r.left, r.right);
        }
    }
    while (y <= r.bottom) : (y += 1) {
        if (r.fullWidth(s.width())) s.clearRow(s.rowPin(y), o) else s.eraseRange(y, r.left, r.right, o);
    }
}

/// Scrolls region `r` down by `n` rows, filling with blanks (BCE).
pub fn scrollDown(s: *Screen, r: Region, n_in: u16, o: EraseOpts) !void {
    const h = r.bottom - r.top + 1;
    const n = @min(n_in, h);
    if (n == 0) return;
    s.splitEdges(r);
    for (0..n) |i| s.pages.invalidatePins(s.rowPin(r.bottom - @as(u16, @intCast(i))));
    var y = r.bottom;
    while (y >= r.top + n) : (y -= 1) {
        if (r.fullWidth(s.width())) {
            s.moveRow(s.rowPin(y), s.rowPin(y - n));
        } else {
            s.moveRange(s.rowPin(y), s.rowPin(y - n), r.left, r.right);
        }
    }
    y = r.top;
    while (y < r.top + n) : (y += 1) {
        if (r.fullWidth(s.width())) s.clearRow(s.rowPin(y), o) else s.eraseRange(y, r.left, r.right, o);
    }
}

fn eraseRange(s: *Screen, y: u16, left: u16, right: u16, o: EraseOpts) void {
    const p = s.rowPin(y);
    p.node.page.clearCells(p.row(), p.cells()[left .. right + 1], bceCell(o.bce));
    p.row().wrap = false;
    s.markDirty(p.row());
}

/// ICH: inserts `n` blank cells at column `x` of row `y`, shifting cells up
/// to `right` (the right margin) right; cells pushed past it are lost.
pub fn insertCells(s: *Screen, y: u16, x: u16, n_in: u16, right: u16, o: EraseOpts) void {
    if (x > right) return;
    const n = @min(n_in, right - x + 1);
    const p = s.rowPin(y);
    const cs = p.cells();
    const page = &p.node.page;
    if (cs[x].wide == .spacer_tail) s.splitWide(p, x);
    if (cs[right].wide == .wide) s.splitWide(p, right);
    // A wide char whose tail would be pushed past `right` loses both halves.
    if (right >= x + n and cs[right - n].wide == .wide) s.splitWide(p, right - n);
    var i: u16 = right;
    while (i >= x + n) : (i -= 1) {
        page.clearCell(&cs[i], .blank);
        page.moveCell(&cs[i], &cs[i - n]);
    }
    page.clearCells(p.row(), cs[x .. x + n], bceCell(o.bce));
    p.row().wrap = false;
    s.markDirty(p.row());
}

/// DCH: deletes `n` cells at column `x` of row `y`, shifting cells up to
/// `right` left and filling the end with blanks (BCE).
pub fn deleteCells(s: *Screen, y: u16, x: u16, n_in: u16, right: u16, o: EraseOpts) void {
    if (x > right) return;
    const n = @min(n_in, right - x + 1);
    const p = s.rowPin(y);
    const cs = p.cells();
    const page = &p.node.page;
    if (cs[x].wide == .spacer_tail) s.splitWide(p, x);
    if (cs[right].wide == .wide) s.splitWide(p, right);
    if (x + n <= right and cs[x + n].wide == .spacer_tail) s.splitWide(p, x + n);
    page.clearCells(p.row(), cs[x .. x + n], .blank);
    var i: u16 = x;
    while (i + n <= right) : (i += 1) page.moveCell(&cs[i], &cs[i + n]);
    page.clearCells(p.row(), cs[right + 1 - n .. right + 1], bceCell(o.bce));
    p.row().wrap = false;
    s.markDirty(p.row());
}

/// IL: inserts `n` blank lines at row `y` within region `r` (no-op when `y`
/// is outside the vertical margins).
pub fn insertLines(s: *Screen, y: u16, n: u16, r: Region, o: EraseOpts) !void {
    if (y < r.top or y > r.bottom) return;
    try s.scrollDown(.{ .top = y, .bottom = r.bottom, .left = r.left, .right = r.right }, n, o);
}

/// DL: deletes `n` lines at row `y` within region `r`.
pub fn deleteLines(s: *Screen, y: u16, n: u16, r: Region, o: EraseOpts) !void {
    if (y < r.top or y > r.bottom) return;
    // DL rotates within the region and never pushes rows into scrollback.
    try s.scrollUpImpl(.{ .top = y, .bottom = r.bottom, .left = r.left, .right = r.right }, n, o, false);
}

/// DECIC: inserts `n` blank columns at column `x` in every row of `r`.
pub fn insertColumns(s: *Screen, x: u16, n: u16, r: Region, o: EraseOpts) void {
    if (x < r.left or x > r.right) return;
    var y = r.top;
    while (y <= r.bottom) : (y += 1) s.insertCells(y, x, n, r.right, o);
}

/// DECDC: deletes `n` columns at column `x` in every row of `r`.
pub fn deleteColumns(s: *Screen, x: u16, n: u16, r: Region, o: EraseOpts) void {
    if (x < r.left or x > r.right) return;
    var y = r.top;
    while (y <= r.bottom) : (y += 1) s.deleteCells(y, x, n, r.right, o);
}

/// Index (IND/LF): moves down one row, scrolling the region at its bottom.
pub fn index(s: *Screen, o: EraseOpts) !void {
    s.cursor.pending_wrap = false;
    if (s.cursor.y == s.region.bottom and s.cursor.x >= s.region.left and s.cursor.x <= s.region.right) {
        try s.scrollUp(s.region, 1, o);
    } else if (s.cursor.y < s.height() - 1 and s.cursor.y != s.region.bottom) {
        s.cursor.y += 1;
    }
}

/// Reverse index (RI): moves up one row, scrolling the region down at its top.
pub fn reverseIndex(s: *Screen, o: EraseOpts) !void {
    s.cursor.pending_wrap = false;
    if (s.cursor.y == s.region.top and s.cursor.x >= s.region.left and s.cursor.x <= s.region.right) {
        try s.scrollDown(s.region, 1, o);
    } else if (s.cursor.y > 0) {
        s.cursor.y -= 1;
    }
}

/// DECSC.
pub fn saveCursor(s: *Screen, origin: bool) void {
    s.saved = .{ .x = s.cursor.x, .y = s.cursor.y, .pending_wrap = s.cursor.pending_wrap, .style = s.cursor.style, .protected = s.cursor.protected, .charsets = s.charsets, .origin = origin, .autowrap = s.modes.autowrap };
}

/// DECRC; restores autowrap into `modes` and returns the saved origin mode
/// (false when nothing was saved, after homing the cursor and resetting
/// attributes as xterm does).
pub fn restoreCursor(s: *Screen) bool {
    const sv = s.saved orelse {
        s.cursor.x = 0;
        s.cursor.y = 0;
        s.cursor.pending_wrap = false;
        s.setStyle(.{});
        s.cursor.protected = false;
        s.charsets = .{};
        return false;
    };
    s.cursor.x = @min(sv.x, s.width() - 1);
    s.cursor.y = @min(sv.y, s.height() - 1);
    s.cursor.pending_wrap = sv.pending_wrap;
    s.setStyle(sv.style);
    s.cursor.protected = sv.protected;
    s.charsets = sv.charsets;
    s.modes.autowrap = sv.autowrap;
    return sv.origin;
}

/// Resizes the grid (no reflow yet), keeping the cursor on its row content.
pub fn resize(s: *Screen, new_cols: u16, new_rows: u16) !void {
    if (new_cols == s.width() and new_rows == s.height()) return;
    // Shrinking rows: drop blank rows below the cursor first, as xterm does.
    if (new_rows < s.height()) {
        var drop: u16 = s.height() - new_rows;
        var y: u16 = s.height() - 1;
        while (drop > 0 and y > s.cursor.y) : (y -= 1) {
            if (!rowBlank(s.rowPin(y))) break;
            drop -= 1;
        }
        const trimmed = (s.height() - new_rows) - drop;
        if (trimmed > 0) s.pages.trimBottom(trimmed);
    }
    // The primary screen re-wraps at a new width; the alternate screen (and
    // a height-only change) keeps rows as they are.
    const rewrap = new_cols != s.width() and s.pages.opts.scrollback;
    var cp = s.rowPin(s.cursor.y);
    // A pending wrap sits just past the last column.
    cp.x = s.cursor.x + @intFromBool(s.cursor.pending_wrap and rewrap);
    const t = try s.pages.track(cp);
    defer s.pages.untrack(t);
    const st = if (s.saved) |sv| blk: {
        var p = s.rowPin(@min(sv.y, s.height() - 1));
        p.x = sv.x;
        break :blk try s.pages.track(p);
    } else null;
    defer if (st) |x| s.pages.untrack(x);
    var past_edge = false;
    if (rewrap) past_edge = try reflow.reflow(&s.pages, new_cols, new_rows, t) else try s.pages.resize(new_cols, new_rows);
    s.cursor.y, s.cursor.x = s.activePos(t, new_rows, new_cols);
    // A cursor just past a line that now fills the row waits to wrap.
    s.cursor.pending_wrap = past_edge and s.modes.autowrap;
    s.cursor.cache_id = 0;
    s.region = s.fullRegion();
    if (s.saved) |*sv| {
        sv.y, sv.x = s.activePos(st.?, new_rows, new_cols);
    }
}

/// The active-area row and column of a tracked pin after a resize (row 0
/// when it scrolled into scrollback or was dropped).
fn activePos(s: *const Screen, t: *const PageList.TrackedPin, rows: u16, cols: u16) struct { u16, u16 } {
    const x = @min(t.pin.x, cols - 1);
    if (t.garbage) return .{ 0, x };
    const abs = s.pages.rowIndex(t.pin);
    const sb = s.pages.scrollbackRows();
    if (abs < sb) return .{ 0, x };
    return .{ @intCast(@min(abs - sb, rows - 1)), x };
}

fn rowBlank(p: Pin) bool {
    for (p.cells()) |c| if (@as(u64, @bitCast(c)) != 0) return false;
    return true;
}

/// Prints printable ASCII (0x20-0x7E) at the cursor.
pub fn printAscii(s: *Screen, run: []const u8) void {
    print_mod.printAscii(s, run);
}

/// Prints code points at the cursor.
pub fn print(s: *Screen, cps: []const u21) void {
    print_mod.print(s, cps);
}

/// REP: prints the last printed cluster `n` more times.
pub fn repeat(s: *Screen, n: u16) void {
    print_mod.repeat(s, n);
}

/// Appends the text of active row `y` as UTF-8 (wide spacers skipped, empty
/// cells as spaces, trailing blanks trimmed).
pub fn rowText(s: *const Screen, y: u16, out: *std.ArrayList(u8), gpa: Allocator) !void {
    try pinText(s.rowPin(y), out, gpa);
}

/// Appends the text of the row at `p`, as `rowText`.
pub fn pinText(p: Pin, out: *std.ArrayList(u8), gpa: Allocator) !void {
    const start = out.items.len;
    var buf: [4]u8 = undefined;
    for (p.cells()) |*c| {
        if (c.wide == .spacer_tail or c.wide == .spacer_head) continue;
        const cp = c.codepoint();
        if (cp == 0) {
            try out.append(gpa, ' ');
            continue;
        }
        try out.appendSlice(gpa, buf[0 .. std.unicode.utf8Encode(cp, &buf) catch 0]);
        if (p.node.page.grapheme(c)) |extra| for (extra) |e| {
            try out.appendSlice(gpa, buf[0 .. std.unicode.utf8Encode(e, &buf) catch 0]);
        };
    }
    var end = out.items.len;
    while (end > start and out.items[end - 1] == ' ') end -= 1;
    out.shrinkRetainingCapacity(end);
}

/// The active area as text, one line per row (for tests and captures).
pub fn dump(s: *const Screen, gpa: Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (0..s.height()) |y| {
        try s.rowText(@intCast(y), &out, gpa);
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

/// Checks every page invariant and the cursor bounds.
pub fn checkInvariants(s: *const Screen) !void {
    try s.pages.verify();
    if (s.cursor.x >= s.width() or s.cursor.y >= s.height()) return error.CursorOutOfBounds;
    const r = s.region;
    if (r.top > r.bottom or r.bottom >= s.height() or r.left > r.right or r.right >= s.width()) return error.BadRegion;
}

/// The grapheme-mode / width options for the print path.
pub fn widthOptions(s: *const Screen) unicode.WidthOptions {
    return .{ .ambiguous_wide = s.modes.ambiguous_wide };
}

test {
    _ = @import("Screen_test.zig");
}
