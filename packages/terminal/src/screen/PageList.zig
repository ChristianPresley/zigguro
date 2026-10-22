//! The page list: a doubly linked list of hot pages holding scrollback plus
//! the active area (the last `rows` rows), with tracked pins that survive
//! scrolling and eviction, and above them the cold scrollback.
//!
//! Rows are appended at the bottom (`grow`), so scrolling the full screen is
//! O(1) per line with no row memmove. With `Options.hot_rows` set, hot
//! scrollback beyond that many rows is compacted, whole logical lines at a
//! time, into cold pages (`cold.zig`, E06.F03.S02.T01) holding about a byte
//! per character; scrolling the viewport back into them decodes them into
//! hot pages again at the current width. Cold pages are evicted first when
//! the byte cap is exceeded, then whole hot pages from the top; pins into
//! evicted or compacted rows become `garbage`.
//!
//! Row indices (`rowIndex`, `screenRow`, `totalRows`, `scrollbackRows`)
//! count cold rows first, so they stay stable across compaction and
//! decoding; `screenRow` is null for a row that is cold. `resize` copies
//! hot rows as they are and `reflow.zig` re-wraps them; cold pages keep
//! their lines and only recount their rows at the new width.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Page = @import("Page.zig");
const Cell = Page.Cell;
const Row = Page.Row;
const cold = @import("cold.zig");

const PageList = @This();

/// A node of the list.
pub const Node = struct {
    prev: ?*Node = null,
    next: ?*Node = null,
    page: Page,
};

/// A row position: a node and a row slot in its page.
pub const Pin = struct {
    node: *Node,
    y: u16,
    x: u16 = 0,

    /// The row.
    pub fn row(p: Pin) *Row {
        return p.node.page.row(p.y);
    }

    /// The row's cells.
    pub fn cells(p: Pin) []Cell {
        return p.node.page.cells(p.row());
    }
};

/// A pin kept up to date by the list.
pub const TrackedPin = struct {
    pin: Pin,
    /// The pinned row was evicted or erased; the pin no longer points at it.
    garbage: bool = false,
};

/// List options.
pub const Options = struct {
    /// Byte cap for all pages (scrollback included).
    max_bytes: usize = 64 << 20,
    /// Whether rows scrolled off the top are kept (false for the alternate screen).
    scrollback: bool = true,
    /// Scrollback rows kept hot; older whole lines move to cold pages.
    /// 0 keeps everything hot.
    hot_rows: u32 = 0,
    /// Deflate cold pages (kept only when it saves 20%).
    deflate: bool = true,
};

/// A cold page and the rows it takes at the list's width.
pub const ColdNode = struct {
    page: cold.ColdPage,
    rows: u32,
};

gpa: Allocator,
pool: Page.PagePool,
opts: Options,
cols: u16,
rows: u16,
page_bytes: u32,
head: *Node,
tail: *Node,
nodes: usize = 0,
/// Rows in all nodes.
total: u64 = 0,
/// Rows evicted from the top since creation (absolute row of `head` row 0).
evicted: u64 = 0,
pins: std.ArrayList(*TrackedPin) = .empty,
/// Top of the viewport when scrolled back; null follows the active area.
viewport: ?*TrackedPin = null,
/// Bumped on every mutation, for cheap change detection by the view.
dirty_generation: u64 = 0,
/// Cold scrollback above `head`, oldest first.
cold_nodes: std.ArrayList(ColdNode) = .empty,
/// Rows of every cold node at `cols`.
cold_rows: u64 = 0,
cold_bytes: usize = 0,

/// Creates a list with an active area of `cols` x `rows` blank rows.
pub fn init(gpa: Allocator, cols: u16, rows: u16, o: Options) !PageList {
    std.debug.assert(cols > 0 and rows > 0);
    var pool: Page.PagePool = .init(gpa);
    errdefer pool.deinit();
    const page_bytes = Page.bytesFor(cols);
    const first = try newNode(gpa, &pool, cols, page_bytes);
    var pl: PageList = .{ .gpa = gpa, .pool = pool, .opts = o, .cols = cols, .rows = rows, .page_bytes = page_bytes, .head = first, .tail = first, .nodes = 1 };
    errdefer pl.deinit();
    for (0..rows) |_| _ = try pl.appendRow();
    return pl;
}

/// Frees every page, node and tracked pin.
pub fn deinit(pl: *PageList) void {
    var n: ?*Node = pl.head;
    while (n) |node| {
        n = node.next;
        pl.pool.free(node.page.buf);
        pl.gpa.destroy(node);
    }
    for (pl.pins.items) |t| pl.gpa.destroy(t);
    pl.pins.deinit(pl.gpa);
    for (pl.cold_nodes.items) |*c| c.page.deinit(pl.gpa);
    pl.cold_nodes.deinit(pl.gpa);
    pl.pool.deinit();
    pl.* = undefined;
}

/// A fresh node with an empty page (for `reflow.zig`).
pub fn newNode(gpa: Allocator, pool: *Page.PagePool, cols: u16, page_bytes: u32) !*Node {
    const buf = try pool.alloc(page_bytes);
    errdefer pool.free(buf);
    const node = try gpa.create(Node);
    node.* = .{ .page = .init(buf, cols) };
    return node;
}

/// Appends a blank row without scrolling bookkeeping (for building lists).
pub fn appendRow(pl: *PageList) !Pin {
    var t = pl.tail;
    if (t.page.rowCount() == t.page.layout.rows_cap) {
        // At the byte cap, the head page is evicted anyway: reuse its node
        // and buffer so steady-state scrolling never allocates.
        const node = if (pl.canRecycleHead()) pl.recycleHead() else try newNode(pl.gpa, &pl.pool, pl.cols, pl.page_bytes);
        node.prev = t;
        t.next = node;
        pl.tail = node;
        pl.nodes += 1;
        t = node;
    }
    const y = t.page.addRow();
    pl.total += 1;
    return .{ .node = t, .y = y };
}

/// Bytes used by hot and cold pages.
pub fn bytesUsed(pl: *const PageList) usize {
    return pl.nodes * pl.page_bytes + pl.cold_bytes;
}

/// Rows in the list (cold and hot scrollback plus active area).
pub fn totalRows(pl: *const PageList) u64 {
    return pl.cold_rows + pl.total;
}

/// Rows of scrollback above the active area, cold ones included.
pub fn scrollbackRows(pl: *const PageList) u64 {
    return pl.cold_rows + pl.total - pl.rows;
}

/// Rows held in cold pages (they come first in row indices).
pub fn coldRows(pl: *const PageList) u64 {
    return pl.cold_rows;
}

/// The oldest hot row.
pub fn firstHot(pl: *const PageList) Pin {
    return .{ .node = pl.head, .y = 0 };
}

/// The pin of active row `y` (0 = top of the active area).
pub fn activeRow(pl: *const PageList, y: u16) Pin {
    std.debug.assert(y < pl.rows);
    var from_bottom: u32 = pl.rows - 1 - y;
    var n = pl.tail;
    while (from_bottom >= n.page.rowCount()) {
        from_bottom -= n.page.rowCount();
        n = n.prev.?;
    }
    return .{ .node = n, .y = @intCast(n.page.rowCount() - 1 - from_bottom) };
}

/// The pin of absolute row `r` (0 = oldest kept row), or null if out of
/// range or cold.
pub fn screenRow(pl: *const PageList, r: u64) ?Pin {
    if (r < pl.cold_rows) return null;
    if (r - pl.cold_rows >= pl.total) return null;
    var left = r - pl.cold_rows;
    var n: ?*Node = pl.head;
    while (n) |node| : (n = node.next) {
        if (left < node.page.rowCount()) return .{ .node = node, .y = @intCast(left) };
        left -= node.page.rowCount();
    }
    return null;
}

/// The absolute row index (0 = oldest kept row) of `p`.
pub fn rowIndex(pl: *const PageList, p: Pin) u64 {
    var idx: u64 = pl.cold_rows + p.y;
    var n = p.node.prev;
    while (n) |node| : (n = node.prev) idx += node.page.rowCount();
    return idx;
}

/// The next row after `p`, if any.
pub fn next(p: Pin) ?Pin {
    if (p.y + 1 < p.node.page.rowCount()) return .{ .node = p.node, .y = p.y + 1 };
    const n = p.node.next orelse return null;
    return .{ .node = n, .y = 0 };
}

/// The row before `p`, if any.
pub fn prev(p: Pin) ?Pin {
    if (p.y > 0) return .{ .node = p.node, .y = p.y - 1 };
    const n = p.node.prev orelse return null;
    return .{ .node = n, .y = n.page.rowCount() - 1 };
}

/// Appends a blank row at the bottom, scrolling the active area up by one;
/// the old top active row becomes scrollback. Evicts whole pages from the
/// top beyond `max_bytes`. Only valid with scrollback enabled.
pub fn grow(pl: *PageList) !Pin {
    std.debug.assert(pl.opts.scrollback);
    const p = try pl.appendRow();
    pl.dirty_generation +%= 1;
    // Out of memory while encoding only keeps the rows hot a while longer.
    if (pl.opts.hot_rows > 0) pl.compact() catch {};
    while (pl.bytesUsed() > pl.opts.max_bytes) {
        if (pl.cold_nodes.items.len > 0) {
            pl.evictCold();
        } else if (pl.head != pl.tail and pl.total - pl.head.page.rowCount() >= pl.rows) {
            pl.evictHead();
        } else break;
    }
    return p;
}

fn evictHead(pl: *PageList) void {
    const h = pl.detachHead();
    pl.pool.free(h.page.buf);
    pl.gpa.destroy(h);
}

/// Unlinks the head page, marking its pins garbage.
fn detachHead(pl: *PageList) *Node {
    const n = pl.head.page.rowCount();
    const h = pl.unlinkHead();
    pl.evicted += n;
    if (pl.viewport) |v| if (v.garbage) {
        v.garbage = false;
        v.pin = .{ .node = pl.head, .y = 0 };
    };
    return h;
}

/// Unlinks the head page from the hot list, marking its pins garbage.
fn unlinkHead(pl: *PageList) *Node {
    const h = pl.head;
    for (pl.pins.items) |t| {
        if (!t.garbage and t.pin.node == h) t.garbage = true;
    }
    pl.head = h.next.?;
    pl.head.prev = null;
    pl.total -= h.page.rowCount();
    pl.nodes -= 1;
    return h;
}

/// Drops the oldest cold page.
fn evictCold(pl: *PageList) void {
    var c = pl.cold_nodes.orderedRemove(0);
    pl.cold_rows -= c.rows;
    pl.evicted += c.rows;
    pl.cold_bytes -= c.page.bytesUsed();
    c.page.deinit(pl.gpa);
}

/// While hot scrollback exceeds `hot_rows`, encodes the head pages (up to
/// the end of a logical line) into a cold page and frees them. Stops at
/// the viewport, which keeps what it shows hot.
pub fn compact(pl: *PageList) !void {
    while (true) {
        const hot_sb = pl.total - pl.rows;
        if (hot_sb <= pl.opts.hot_rows) return;
        // The head pages through the first whose last row ends a line.
        var last = pl.head;
        var n: u64 = last.page.rowCount();
        var count: usize = 1;
        while (last.page.row(last.page.rowCount() - 1).wrap) {
            last = last.next orelse return;
            n += last.page.rowCount();
            count += 1;
        }
        if (last == pl.tail or hot_sb < n + pl.opts.hot_rows) return;
        if (pl.viewport) |v| if (!v.garbage) {
            var it: ?*Node = pl.head;
            for (0..count) |_| {
                if (it.? == v.pin.node) return;
                it = it.?.next;
            }
        };
        var cp = try cold.encode(pl.gpa, pl.firstHot(), n, .{ .deflate = pl.opts.deflate });
        errdefer cp.deinit(pl.gpa);
        // Same width: the rows are exactly the ones encoded.
        cp.cached_cols = pl.cols;
        cp.cached_rows = @intCast(n);
        try pl.cold_nodes.append(pl.gpa, .{ .page = cp, .rows = @intCast(n) });
        pl.cold_rows += n;
        pl.cold_bytes += cp.bytesUsed();
        for (0..count) |_| {
            const h = pl.unlinkHead();
            pl.pool.free(h.page.buf);
            pl.gpa.destroy(h);
        }
        pl.dirty_generation +%= 1;
    }
}

/// Decodes the newest cold page back into hot pages above `head`, at the
/// current width. Row indices do not change.
pub fn thawNewest(pl: *PageList) !void {
    const c = &pl.cold_nodes.items[pl.cold_nodes.items.len - 1];
    var fresh: PageList = .{ .gpa = pl.gpa, .pool = pl.pool, .opts = pl.opts, .cols = pl.cols, .rows = pl.rows, .page_bytes = pl.page_bytes, .head = undefined, .tail = undefined };
    const first = try newNode(pl.gpa, &fresh.pool, pl.cols, pl.page_bytes);
    fresh.head = first;
    fresh.tail = first;
    fresh.nodes = 1;
    c.page.decode(pl.gpa, &fresh) catch |err| {
        pl.pool = fresh.pool;
        freeNodes(pl.gpa, &pl.pool, fresh.head);
        return err;
    };
    pl.pool = fresh.pool;
    if (fresh.total == 0) {
        freeNodes(pl.gpa, &pl.pool, fresh.head);
    } else {
        fresh.tail.next = pl.head;
        pl.head.prev = fresh.tail;
        pl.head = fresh.head;
        pl.nodes += fresh.nodes;
        pl.total += fresh.total;
    }
    pl.cold_rows -= c.rows;
    pl.cold_bytes -= c.page.bytesUsed();
    var gone = pl.cold_nodes.pop().?;
    gone.page.deinit(pl.gpa);
    pl.dirty_generation +%= 1;
}

/// Recounts cold rows at the current width (after a resize; the lines
/// themselves re-wrap when decoded).
fn recountCold(pl: *PageList) void {
    pl.cold_rows = 0;
    for (pl.cold_nodes.items) |*c| {
        c.rows = c.page.rowsAt(pl.gpa, pl.cols) catch c.rows;
        pl.cold_rows += c.rows;
    }
}

/// Whether adding a page would exceed the byte cap and the head page can
/// be evicted to make room (it is a standard page entirely in scrollback).
fn canRecycleHead(pl: *const PageList) bool {
    const h = pl.head;
    return pl.opts.scrollback and h != pl.tail and h.page.buf.len == pl.page_bytes and
        (pl.nodes + 1) * pl.page_bytes > pl.opts.max_bytes and
        pl.total - h.page.rowCount() >= pl.rows;
}

/// Evicts the head page and returns its node, reformatted, for reuse.
fn recycleHead(pl: *PageList) *Node {
    const h = pl.detachHead();
    const buf = h.page.buf;
    h.* = .{ .page = .init(buf, pl.cols) };
    return h;
}

/// Tracks `p`; the returned pin is updated as rows move.
pub fn track(pl: *PageList, p: Pin) !*TrackedPin {
    const t = try pl.gpa.create(TrackedPin);
    errdefer pl.gpa.destroy(t);
    t.* = .{ .pin = p };
    try pl.pins.append(pl.gpa, t);
    return t;
}

/// Stops tracking and frees `t`.
pub fn untrack(pl: *PageList, t: *TrackedPin) void {
    for (pl.pins.items, 0..) |x, i| if (x == t) {
        _ = pl.pins.swapRemove(i);
        break;
    };
    if (pl.viewport == t) pl.viewport = null;
    pl.gpa.destroy(t);
}

/// Pins on row `p` (exact row) move to row `to` (content moved there).
pub fn movePins(pl: *PageList, from: Pin, to: Pin) void {
    for (pl.pins.items) |t| {
        if (!t.garbage and t.pin.node == from.node and t.pin.y == from.y) {
            t.pin.node = to.node;
            t.pin.y = to.y;
        }
    }
}

/// Marks pins on row `p` as garbage (its content was destroyed).
pub fn invalidatePins(pl: *PageList, p: Pin) void {
    for (pl.pins.items) |t| {
        if (!t.garbage and t.pin.node == p.node and t.pin.y == p.y) t.garbage = true;
    }
}

/// Scrolls the viewport back by `delta` rows (negative = towards the active
/// area). Reaching the active area resumes following output.
pub fn scrollViewport(pl: *PageList, delta: i64) !void {
    const sb = pl.scrollbackRows();
    const cur: u64 = if (pl.viewport) |v| pl.rowIndex(v.pin) else sb;
    const want: u64 = @intCast(std.math.clamp(@as(i64, @intCast(cur)) - delta, 0, @as(i64, @intCast(sb))));
    if (want >= sb) {
        if (pl.viewport) |v| pl.untrack(v);
        pl.viewport = null;
        return;
    }
    while (want < pl.cold_rows) try pl.thawNewest();
    const p = pl.screenRow(want).?;
    if (pl.viewport) |v| {
        v.pin = p;
        v.garbage = false;
    } else pl.viewport = try pl.track(p);
}

/// The pin of viewport row `y`.
pub fn viewportRow(pl: *const PageList, y: u16) Pin {
    const v = pl.viewport orelse return pl.activeRow(y);
    var p = v.pin;
    for (0..y) |_| p = next(p) orelse break;
    return p;
}

/// Drops all scrollback (ED 3), keeping the active area. Pins into dropped
/// rows become garbage.
pub fn eraseScrollback(pl: *PageList) !void {
    if (pl.scrollbackRows() == 0) return;
    while (pl.cold_nodes.items.len > 0) pl.evictCold();
    // Move the active rows into fresh pages, then free the old list.
    var fresh: PageList = .{ .gpa = pl.gpa, .pool = pl.pool, .opts = pl.opts, .cols = pl.cols, .rows = pl.rows, .page_bytes = pl.page_bytes, .head = undefined, .tail = undefined };
    const first = try newNode(pl.gpa, &fresh.pool, pl.cols, pl.page_bytes);
    fresh.head = first;
    fresh.tail = first;
    fresh.nodes = 1;
    for (0..pl.rows) |y| {
        const src = pl.activeRow(@intCast(y));
        const dst = fresh.appendRow() catch |e| {
            pl.pool = fresh.pool;
            freeNodes(pl.gpa, &pl.pool, fresh.head);
            return e;
        };
        copyRow(dst, src);
    }
    pl.remapPins(pl.activeRow(0), .{ .node = fresh.head, .y = 0 }, fresh.head);
    pl.pool = fresh.pool;
    freeNodes(pl.gpa, &pl.pool, pl.head);
    pl.evicted += pl.total - pl.rows;
    pl.head = fresh.head;
    pl.tail = fresh.tail;
    pl.nodes = fresh.nodes;
    pl.total = fresh.total;
    if (pl.viewport) |v| pl.untrack(v);
    pl.dirty_generation +%= 1;
}

/// After rows from `src` onward were copied in order to rows from `dst`
/// onward (a new list starting at `new_head`), moves pins along; pins not in
/// the copied range become garbage. Pins are only touched once all copies
/// succeeded, so a failed copy leaves them valid.
fn remapPins(pl: *PageList, src: Pin, dst: Pin, new_head: *Node) void {
    var s: ?Pin = src;
    var d: ?Pin = dst;
    while (s) |sp| : ({
        s = next(sp);
        d = if (d) |dp| next(dp) else null;
    }) {
        const dp = d orelse break;
        for (pl.pins.items) |t| {
            if (!t.garbage and t.pin.node == sp.node and t.pin.y == sp.y) {
                t.pin.node = dp.node;
                t.pin.y = dp.y;
                t.garbage = false;
            }
        }
    }
    for (pl.pins.items) |t| {
        if (!t.garbage and !nodeIn(new_head, t.pin.node)) t.garbage = true;
    }
}

fn nodeIn(head: *Node, n: *Node) bool {
    var it: ?*Node = head;
    while (it) |x| : (it = x.next) if (x == n) return true;
    return false;
}

/// Frees `head` and every node after it.
pub fn freeNodes(gpa: Allocator, pool: *Page.PagePool, head: *Node) void {
    var n: ?*Node = head;
    while (n) |node| {
        n = node.next;
        pool.free(node.page.buf);
        gpa.destroy(node);
    }
}

/// Copies row `src` into blank row `dst` (possibly another page), cell by
/// cell up to the narrower width, including row flags.
pub fn copyRow(dst: Pin, src: Pin) void {
    const sr = src.row();
    const dr = dst.row();
    const off = dr.cells_off;
    dr.* = sr.*;
    dr.cells_off = off;
    dr.dirty = true;
    const sc = src.cells();
    const dc = dst.cells();
    const n = @min(sc.len, dc.len);
    for (dc[0..n], sc[0..n]) |*d, *s| dst.node.page.copyCellFrom(d, &src.node.page, s);
    // A wide char cut by a narrower destination loses its tail: blank it.
    if (n > 0 and n < sc.len and dc[n - 1].wide == .wide) dst.node.page.clearCell(&dc[n - 1], .blank);
}

/// Changes the grid size by copying rows into fresh pages (no reflow yet).
/// Rows are truncated or padded on the right; the active area keeps its
/// bottom rows when shrinking (they scroll into scrollback) and pulls rows
/// back from scrollback when growing. Pins move with their rows.
pub fn resize(pl: *PageList, cols: u16, rows: u16) !void {
    std.debug.assert(cols > 0 and rows > 0);
    if (cols == pl.cols and rows == pl.rows) return;
    const page_bytes = Page.bytesFor(cols);
    var fresh: PageList = .{ .gpa = pl.gpa, .pool = pl.pool, .opts = pl.opts, .cols = cols, .rows = rows, .page_bytes = page_bytes, .head = undefined, .tail = undefined };
    const first = try newNode(pl.gpa, &fresh.pool, cols, page_bytes);
    fresh.head = first;
    fresh.tail = first;
    fresh.nodes = 1;
    errdefer {
        pl.pool = fresh.pool;
        freeNodes(pl.gpa, &pl.pool, fresh.head);
    }
    // Without scrollback, only the last `rows` rows survive.
    var start: u64 = 0;
    if (!pl.opts.scrollback and pl.total > rows) start = pl.total - rows;
    var p: ?Pin = pl.hotRow(start);
    while (p) |src| : (p = next(src)) {
        const dst = try fresh.appendRow();
        copyRow(dst, src);
    }
    while (fresh.total < rows) _ = try fresh.appendRow();
    pl.remapPins(pl.hotRow(start).?, .{ .node = fresh.head, .y = 0 }, fresh.head);
    for (pl.pins.items) |t| {
        if (t.pin.x >= cols) t.pin.x = cols - 1;
    }
    pl.pool = fresh.pool;
    freeNodes(pl.gpa, &pl.pool, pl.head);
    pl.head = fresh.head;
    pl.tail = fresh.tail;
    pl.nodes = fresh.nodes;
    pl.total = fresh.total;
    pl.cols = cols;
    pl.rows = rows;
    pl.page_bytes = page_bytes;
    pl.recountCold();
    if (pl.viewport) |v| {
        if (v.garbage or pl.rowIndex(v.pin) >= pl.scrollbackRows()) pl.untrack(v);
    }
    pl.dirty_generation +%= 1;
}

/// Hot row `r` (0 = `firstHot`), or null.
pub fn hotRow(pl: *const PageList, r: u64) ?Pin {
    return pl.screenRow(pl.cold_rows + r);
}

/// After `reflow.zig` replaced the hot pages at a new width.
pub fn reflowed(pl: *PageList) void {
    pl.recountCold();
}

/// Removes the bottom `n` rows of the active area (they must be blank),
/// shrinking it to `rows - n`.
pub fn trimBottom(pl: *PageList, n: u16) void {
    std.debug.assert(n < pl.rows);
    for (0..n) |_| {
        const t = pl.tail;
        const y = t.page.rowCount() - 1;
        pl.invalidatePins(.{ .node = t, .y = y });
        const r = t.page.row(y);
        t.page.clearCells(r, t.page.cells(r), .blank);
        r.* = .{ .cells_off = r.cells_off };
        t.page.header().rows -= 1;
        pl.total -= 1;
        if (t.page.rowCount() == 0 and t != pl.head) {
            pl.tail = t.prev.?;
            pl.tail.next = null;
            pl.nodes -= 1;
            pl.pool.free(t.page.buf);
            pl.gpa.destroy(t);
        }
    }
    pl.rows -= n;
    pl.dirty_generation +%= 1;
}

/// Runs `Page.verify` on every page and checks list bookkeeping.
pub fn verify(pl: *const PageList) !void {
    var total: u64 = 0;
    var count: usize = 0;
    var n: ?*Node = pl.head;
    var last: ?*Node = null;
    while (n) |node| : (n = node.next) {
        if (node.prev != last) return error.BrokenLinks;
        try node.page.verify(pl.gpa);
        if (node.page.rowCount() == 0) return error.EmptyNode;
        total += node.page.rowCount();
        count += 1;
        last = node;
    }
    if (last != pl.tail) return error.BrokenTail;
    if (total != pl.total or count != pl.nodes) return error.BadCounts;
    var cold_rows: u64 = 0;
    var cold_bytes: usize = 0;
    for (pl.cold_nodes.items) |c| {
        cold_rows += c.rows;
        cold_bytes += c.page.bytesUsed();
    }
    if (cold_rows != pl.cold_rows or cold_bytes != pl.cold_bytes) return error.BadColdCounts;
    if (pl.total < pl.rows) return error.TooFewRows;
}

test {
    _ = @import("PageList_test.zig");
    _ = @import("cold_scrollback_test.zig");
}
