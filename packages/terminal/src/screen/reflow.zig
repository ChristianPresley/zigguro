//! Reflow on resize: re-wraps the page list's logical lines at a new width
//! into fresh pages, moving tracked pins (cursor, saved cursor, viewport,
//! selection) to the same logical position.
//!
//! A logical line is a run of rows where every row but the last has `wrap`
//! set. Its cells are copied in order (re-interning styles, graphemes and
//! links); trailing default blanks of the last row are not carried, cells
//! with a background are. A wide character that would straddle the new
//! right edge leaves a `spacer_head` and moves to the next row; old spacer
//! heads are dropped. Blank rows below the cursor are not re-wrapped: they
//! absorb the growth of the content above when narrowing, and content only
//! scrolls into scrollback once they are used up. When the content shrinks,
//! rows come back from scrollback (bottom anchoring).
//!
//! Cold pages (E06.F03.S02.T01) do not exist yet; every page is hot.

const std = @import("std");
const Allocator = std.mem.Allocator;
const PageList = @import("PageList.zig");
const Page = @import("Page.zig");
const Cell = Page.Cell;
const Row = Page.Row;
const Pin = PageList.Pin;
const Node = PageList.Node;
const TrackedPin = PageList.TrackedPin;

/// Where a source cell landed: a destination row (index into the line's
/// destination rows) and column.
const Pos = struct { row: u32, x: u16 };

/// A pin's new place, applied once every copy succeeded.
const Move = struct { t: *TrackedPin, pin: Pin, clamped: bool = false };

/// Re-wraps `pl` at `cols` columns with an active area of `rows` rows.
/// Pins on reflowed rows keep their logical position; a pin past the end
/// of its line keeps its offset, clamped to the last column. Returns
/// whether `cursor` was clamped that way (the caller sets a pending wrap).
/// On error the list is unchanged.
pub fn reflow(pl: *PageList, cols: u16, rows: u16, cursor: ?*const TrackedPin) !bool {
    std.debug.assert(cols > 0 and rows > 0);
    const page_bytes = Page.bytesFor(cols);
    var fresh: PageList = .{ .gpa = pl.gpa, .pool = pl.pool, .opts = pl.opts, .cols = cols, .rows = rows, .page_bytes = page_bytes, .head = undefined, .tail = undefined };
    const first = try PageList.newNode(pl.gpa, &fresh.pool, cols, page_bytes);
    fresh.head = first;
    fresh.tail = first;
    fresh.nodes = 1;
    var moves: std.ArrayList(Move) = .empty;
    defer moves.deinit(pl.gpa);
    var w: Writer = .{ .gpa = pl.gpa, .dst = &fresh };
    defer w.deinit();
    errdefer {
        pl.pool = fresh.pool;
        PageList.freeNodes(pl.gpa, &pl.pool, fresh.head);
    }

    // Blank rows at the bottom, below every pin's row, stay rows.
    const keep_blank = trailingBlankRows(pl);
    const reflow_rows = pl.total - keep_blank;
    // Where the active area starts, to decide how many blank rows to keep.
    const top = try pl.track(pl.activeRow(0));
    defer pl.untrack(top);

    var r: u64 = 0;
    var p: ?Pin = if (reflow_rows > 0) pl.screenRow(0) else null;
    while (r < reflow_rows) {
        // One logical line: rows until one without `wrap`.
        const start = p.?;
        var n_rows: u64 = 1;
        var last = start;
        while (last.row().wrap and r + n_rows < reflow_rows) {
            last = PageList.next(last).?;
            n_rows += 1;
        }
        try w.line(pl, start, n_rows, &moves);
        r += n_rows;
        p = PageList.next(last);
    }
    // Blank rows below the content absorb growth: keep only as many as fit
    // under the content from the old active top, so narrowing does not
    // scroll while there is room.
    const top_row: u64 = for (moves.items) |m| {
        if (m.t == top) break fresh.rowIndex(m.pin);
    } else 0;
    const below = fresh.total - top_row;
    var keep: u64 = @min(keep_blank, if (below < rows) rows - below else 0);
    while (p) |src| : (p = PageList.next(src)) {
        if (keep == 0) break;
        keep -= 1;
        const dst = try fresh.appendRow();
        PageList.copyRow(dst, src);
        try pinsOnRow(pl, src, &moves, dst, cols);
    }
    while (fresh.total < rows) _ = try fresh.appendRow();

    // Commit: move pins, drop the old pages.
    var clamped = false;
    for (moves.items) |m| if (m.t == cursor) {
        clamped = m.clamped;
    };
    for (pl.pins.items) |t| {
        if (t.garbage) continue;
        t.garbage = true;
        for (moves.items) |m| if (m.t == t) {
            t.pin = m.pin;
            t.garbage = false;
            break;
        };
    }
    pl.pool = fresh.pool;
    PageList.freeNodes(pl.gpa, &pl.pool, pl.head);
    pl.head = fresh.head;
    pl.tail = fresh.tail;
    pl.nodes = fresh.nodes;
    pl.total = fresh.total;
    pl.cols = cols;
    pl.rows = rows;
    pl.page_bytes = page_bytes;
    if (pl.viewport) |v| {
        if (v.garbage or pl.rowIndex(v.pin) >= pl.scrollbackRows()) pl.untrack(v);
    }
    pl.dirty_generation +%= 1;
    return clamped;
}

/// Rows at the bottom that are blank, unwrapped and below every tracked
/// pin (so below the cursor).
fn trailingBlankRows(pl: *const PageList) u64 {
    var lowest: u64 = 0;
    for (pl.pins.items) |t| {
        if (!t.garbage) lowest = @max(lowest, pl.rowIndex(t.pin) + 1);
    }
    var n: u64 = 0;
    var p: ?Pin = .{ .node = pl.tail, .y = pl.tail.page.rowCount() - 1 };
    while (p) |row| : (p = PageList.prev(row)) {
        if (pl.total - n <= lowest) break;
        const rw = row.row();
        if (rw.wrap or rw.wrap_continuation or !blank(row.cells())) break;
        n += 1;
    }
    return n;
}

fn blank(cs: []const Cell) bool {
    for (cs) |c| if (@as(u64, @bitCast(c)) != 0) return false;
    return true;
}

/// Pins on source row `src` move to `dst`, columns clamped to `cols`.
fn pinsOnRow(pl: *const PageList, src: Pin, moves: *std.ArrayList(Move), dst: Pin, cols: u16) !void {
    for (pl.pins.items) |t| {
        if (t.garbage or t.pin.node != src.node or t.pin.y != src.y) continue;
        try moves.append(pl.gpa, .{ .t = t, .pin = .{ .node = dst.node, .y = dst.y, .x = @min(t.pin.x, cols - 1) } });
    }
}

/// Emits logical lines into the destination list.
const Writer = struct {
    gpa: Allocator,
    dst: *PageList,
    /// Destination rows of the current line.
    rows: std.ArrayList(Pin) = .empty,
    /// Destination of each source cell offset of the current line.
    pos: std.ArrayList(Pos) = .empty,
    /// Offset of each source row's first cell in the current line.
    row_off: std.ArrayList(u32) = .empty,
    x: u16 = 0,

    fn deinit(w: *Writer) void {
        w.rows.deinit(w.gpa);
        w.pos.deinit(w.gpa);
        w.row_off.deinit(w.gpa);
    }

    fn cur(w: *const Writer) Pin {
        return w.rows.items[w.rows.items.len - 1];
    }

    fn newRow(w: *Writer, continuation: bool) !void {
        if (continuation) w.cur().row().wrap = true;
        const p = try w.dst.appendRow();
        const r = p.row();
        r.wrap_continuation = continuation;
        r.dirty = true;
        try w.rows.append(w.gpa, p);
        w.x = 0;
    }

    /// Copies source cell `s` to the current position.
    fn put(w: *Writer, sp: *const Page, s: *const Cell) void {
        const d = w.cur();
        const cs = d.cells();
        d.node.page.copyCellFrom(&cs[w.x], sp, s);
        markRow(d.row(), cs[w.x]);
        w.x += 1;
    }

    fn line(w: *Writer, pl: *const PageList, start: Pin, n_rows: u64, moves: *std.ArrayList(Move)) !void {
        const cols = w.dst.cols;
        w.rows.clearRetainingCapacity();
        w.pos.clearRetainingCapacity();
        w.row_off.clearRetainingCapacity();
        try w.newRow(false);
        {
            // Row-level marks travel with the line's first row.
            const sr = start.row().*;
            const dr = w.cur().row();
            dr.mark = sr.mark;
            dr.synthetic = sr.synthetic;
        }
        var src = start;
        var off: u32 = 0;
        for (0..n_rows) |i| {
            if (i > 0) src = PageList.next(src).?;
            try w.row_off.append(w.gpa, off);
            const sp = &src.node.page;
            const cs = src.cells();
            const end = if (i + 1 == n_rows) contentEnd(cs) else cs.len;
            if (i > 0 and src.row().mark != .none) {
                // A mark on a later row lands where that row's text starts.
                if (w.x == cols) try w.newRow(true);
                w.cur().row().mark = src.row().mark;
            }
            var k: usize = 0;
            while (k < end) : (k += 1) {
                const c = cs[k];
                switch (c.wide) {
                    .spacer_head => continue,
                    .spacer_tail => {
                        // An orphan tail (its head was cut off): a blank.
                        if (w.x == cols) try w.newRow(true);
                        try w.pos.append(w.gpa, .{ .row = @intCast(w.rows.items.len - 1), .x = w.x });
                        w.x += 1;
                        off += 1;
                    },
                    .wide => {
                        const has_tail = k + 1 < cs.len and cs[k + 1].wide == .spacer_tail;
                        if (cols < 2) {
                            // Nothing wide fits a one-column grid.
                            if (w.x == cols) try w.newRow(true);
                            const at: Pos = .{ .row = @intCast(w.rows.items.len - 1), .x = w.x };
                            try w.pos.append(w.gpa, at);
                            if (has_tail) try w.pos.append(w.gpa, at);
                            w.x += 1;
                        } else {
                            if (w.x + 2 > cols) {
                                if (w.x < cols) {
                                    w.cur().cells()[w.x] = .{ .wide = .spacer_head };
                                }
                                try w.newRow(true);
                            }
                            const at: Pos = .{ .row = @intCast(w.rows.items.len - 1), .x = w.x };
                            w.put(sp, &cs[k]);
                            try w.pos.append(w.gpa, at);
                            if (has_tail) {
                                w.put(sp, &cs[k + 1]);
                            } else {
                                w.cur().cells()[w.x] = .{ .wide = .spacer_tail };
                                w.x += 1;
                            }
                            try w.pos.append(w.gpa, .{ .row = at.row, .x = at.x + 1 });
                        }
                        if (has_tail) k += 1;
                        off += if (has_tail) 2 else 1;
                    },
                    .narrow => {
                        if (w.x == cols) try w.newRow(true);
                        try w.pos.append(w.gpa, .{ .row = @intCast(w.rows.items.len - 1), .x = w.x });
                        w.put(sp, &cs[k]);
                        off += 1;
                    },
                }
            }
            // Cells up to the row's width count for pins, wrapped or not.
            if (i + 1 < n_rows) off = @max(off, w.row_off.items[i] + spanOf(cs));
        }
        // Rows created by re-wrapping were not written by the application.
        for (w.rows.items[1..]) |rp| rp.row().synthetic = true;

        // Pins on the line's source rows.
        src = start;
        for (0..n_rows) |i| {
            if (i > 0) src = PageList.next(src).?;
            for (pl.pins.items) |t| {
                if (t.garbage or t.pin.node != src.node or t.pin.y != src.y) continue;
                const o = w.row_off.items[i] + t.pin.x;
                const at = w.pinAt(o);
                try moves.append(w.gpa, .{ .t = t, .pin = at.pin, .clamped = at.clamped });
            }
        }
    }

    /// The destination of line offset `o`; offsets past the text continue
    /// on the last row, clamped to the last column.
    fn pinAt(w: *const Writer, o: u32) struct { pin: Pin, clamped: bool } {
        const cols = w.dst.cols;
        if (o < w.pos.items.len) {
            const p = w.pos.items[o];
            const rp = w.rows.items[p.row];
            return .{ .pin = .{ .node = rp.node, .y = rp.y, .x = p.x }, .clamped = false };
        }
        const extra = o - @as(u32, @intCast(w.pos.items.len));
        const last = w.cur();
        const x: u32 = @as(u32, w.x) + extra;
        return .{ .pin = .{ .node = last.node, .y = last.y, .x = @intCast(@min(x, cols - 1)) }, .clamped = x >= cols };
    }
};

/// Index after the last cell to carry from a line's last row: trailing
/// cells that are entirely default (no text, style or flags) are dropped.
fn contentEnd(cs: []const Cell) usize {
    var n = cs.len;
    while (n > 0 and @as(u64, @bitCast(cs[n - 1])) == 0) n -= 1;
    return n;
}

/// Source cells of a wrapped row that count as line offsets (all but a
/// trailing spacer head).
fn spanOf(cs: []const Cell) u32 {
    var n: u32 = @intCast(cs.len);
    if (n > 0 and cs[n - 1].wide == .spacer_head) n -= 1;
    return n;
}

fn markRow(r: *Row, c: Cell) void {
    if (c.style != 0) r.styled = true;
    if (c.tag == .grapheme) r.has_grapheme = true;
    if (c.hyperlink) r.has_hyperlink = true;
}

test {
    _ = @import("reflow_test.zig");
}
