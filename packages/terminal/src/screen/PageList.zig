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
//! evicted rows become `garbage`. Pins into compacted rows are garbage
//! too while cold, but keep their logical position (`TrackedPin.cold`) and
//! come back when their page is decoded, at whatever width it has then.
//!
//! With `Options.background_compact`, `grow` only flags compaction as due;
//! the owner calls `beginCompact` (a cheap copy of the pages), runs the
//! returned job's encoder on any thread, and hands it back to
//! `finishCompact`, which swaps the rows out only if the hot list's layout
//! did not change meanwhile (resize, reflow, ED 3, eviction).
//!
//! Decoded cold pages keep their encoding in a small decode cache (the
//! last `thaw_cache` pages): when the viewport leaves them and they are
//! compacted again unchanged, the cached encoding is reused instead of
//! encoding the rows again. A resize, reflow or ED 3 empties the cache.
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
    /// The pinned row was evicted or erased, or is cold; the pin no
    /// longer points at it.
    garbage: bool = false,
    /// While the row is cold: where it is in the cold page's lines, so
    /// `thawNewest` can restore the pin. Null once that page is evicted.
    cold: ?ColdPos = null,
};

/// A position in cold scrollback: cold page `seq`, logical line `line`
/// of it, and cell `offset` from the start of that line.
pub const ColdPos = struct {
    seq: u64,
    line: u32,
    offset: u32,
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
    /// `grow` sets `compact_due` instead of encoding; the owner runs
    /// `beginCompact`/`CompactJob.run`/`finishCompact`, the encoding off
    /// its thread or lock.
    background_compact: bool = false,
};

/// Decoded cold pages whose encoding is kept for reuse.
pub const thaw_cache = 8;

/// A decoded cold page in the decode cache: its encoding and the hot
/// nodes it became.
const Thawed = struct {
    page: cold.ColdPage,
    first: *Node,
    count: usize,
    rows: u64,
};

/// The head rows the next compaction takes: `count` nodes holding `n`
/// rows of whole lines, already encoded when `cached` (a decode cache
/// index).
const Range = struct {
    count: usize,
    n: u64,
    cached: ?usize = null,
};

/// A background compaction: private copies of the head pages, encoded by
/// `run` on any thread, then handed to `finishCompact`.
pub const CompactJob = struct {
    gpa: Allocator,
    /// `layout_gen` when the copies were taken.
    gen: u64,
    first: *Node,
    range: Range,
    /// The copied pages, linked like the originals.
    copies: *Node,
    deflate: bool,
    /// The encoding, once `run` succeeded.
    result: ?cold.ColdPage = null,

    /// Encodes the copies. Touches nothing but the job.
    pub fn run(job: *CompactJob) void {
        job.result = cold.encode(job.gpa, .{ .node = job.copies, .y = 0 }, job.range.n, .{ .deflate = job.deflate }) catch null;
    }
};

/// A cold page and the rows it takes at the list's width.
pub const ColdNode = struct {
    page: cold.ColdPage,
    rows: u32,
    /// Unique per list, for pins into this page.
    seq: u64 = 0,
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
/// The next `ColdNode.seq`.
cold_seq: u64 = 0,
/// Bumped whenever hot nodes are unlinked or replaced, so a background
/// compaction can tell that its copies went stale.
layout_gen: u64 = 0,
/// Compaction is due (`Options.background_compact`).
compact_due: bool = false,
/// A `CompactJob` is out.
job_out: bool = false,
/// The decode cache, oldest first.
thawed: std.ArrayList(Thawed) = .empty,
thawed_bytes: usize = 0,

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
    for (pl.thawed.items) |*e| e.page.deinit(pl.gpa);
    pl.thawed.deinit(pl.gpa);
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

/// Bytes used by hot and cold pages and the decode cache.
pub fn bytesUsed(pl: *const PageList) usize {
    return pl.nodes * pl.page_bytes + pl.cold_bytes + pl.thawed_bytes;
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
    if (pl.opts.hot_rows > 0) {
        if (pl.opts.background_compact) {
            pl.compactCached() catch {};
            if (!pl.compact_due) pl.compact_due = pl.nextRange() != null;
        } else pl.compact() catch {};
    }
    while (pl.bytesUsed() > pl.opts.max_bytes) {
        if (pl.thawed.items.len > 0) {
            pl.dropThawed(0);
        } else if (pl.cold_nodes.items.len > 0) {
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
    for (pl.thawed.items, 0..) |e, i| if (e.first == h) {
        pl.dropThawed(i);
        break;
    };
    pl.layout_gen +%= 1;
    pl.head = h.next.?;
    pl.head.prev = null;
    pl.total -= h.page.rowCount();
    pl.nodes -= 1;
    return h;
}

/// Drops the oldest cold page.
fn evictCold(pl: *PageList) void {
    var c = pl.cold_nodes.orderedRemove(0);
    for (pl.pins.items) |t| if (t.cold) |cp| if (cp.seq == c.seq) {
        t.cold = null;
    };
    pl.cold_rows -= c.rows;
    pl.evicted += c.rows;
    pl.cold_bytes -= c.page.bytesUsed();
    c.page.deinit(pl.gpa);
}

/// While hot scrollback exceeds `hot_rows`, encodes the head pages (up to
/// the end of a logical line) into a cold page and frees them. Stops at
/// the viewport, which keeps what it shows hot.
pub fn compact(pl: *PageList) !void {
    while (pl.nextRange()) |r| {
        const cp = if (r.cached) |i| pl.takeThawed(i) else try cold.encode(pl.gpa, pl.firstHot(), r.n, .{ .deflate = pl.opts.deflate });
        try pl.retire(r, cp);
    }
}

/// Compacts the head ranges the decode cache already holds encoded.
fn compactCached(pl: *PageList) !void {
    while (pl.nextRange()) |r| {
        const i = r.cached orelse return;
        try pl.retire(r, pl.takeThawed(i));
    }
}

/// The head range due for compaction, or null when hot scrollback is
/// within `hot_rows` or the range would reach the active area or the
/// viewport.
fn nextRange(pl: *const PageList) ?Range {
    const hot_sb = pl.total - pl.rows;
    if (hot_sb <= pl.opts.hot_rows) return null;
    var r: Range = undefined;
    if (pl.thawedAt(pl.head)) |i| {
        const e = pl.thawed.items[i];
        r = .{ .count = e.count, .n = e.rows, .cached = i };
    } else {
        // The head pages through the first whose last row ends a line.
        var last = pl.head;
        r = .{ .count = 1, .n = last.page.rowCount() };
        while (last.page.row(last.page.rowCount() - 1).wrap) {
            last = last.next orelse return null;
            r.n += last.page.rowCount();
            r.count += 1;
        }
    }
    if (hot_sb < r.n + pl.opts.hot_rows) return null;
    const v: ?*Node = if (pl.viewport) |t| (if (t.garbage) null else t.pin.node) else null;
    var it: ?*Node = pl.head;
    for (0..r.count) |_| {
        const node = it orelse return null;
        if (node == pl.tail or node == v) return null;
        it = node.next;
    }
    return r;
}

/// Moves the `r` head rows, encoded as `cp`, into a cold page. Frees `cp`
/// on failure.
fn retire(pl: *PageList, r: Range, cp: cold.ColdPage) !void {
    var page = cp;
    errdefer page.deinit(pl.gpa);
    // Same width: the rows are exactly the ones encoded.
    page.cached_cols = pl.cols;
    page.cached_rows = @intCast(r.n);
    try pl.cold_nodes.append(pl.gpa, .{ .page = page, .rows = @intCast(r.n), .seq = pl.cold_seq });
    pl.freezePins(r.n, pl.cold_seq);
    pl.cold_seq += 1;
    pl.cold_rows += r.n;
    pl.cold_bytes += page.bytesUsed();
    for (0..r.count) |_| {
        const h = pl.unlinkHead();
        pl.pool.free(h.page.buf);
        pl.gpa.destroy(h);
    }
    pl.dirty_generation +%= 1;
}

/// Starts a background compaction: compacts what the decode cache holds,
/// then copies the next due range for `CompactJob.run`. Null when nothing
/// is due or a job is already out. Clears `compact_due`.
pub fn beginCompact(pl: *PageList) !?*CompactJob {
    pl.compact_due = false;
    if (pl.job_out) return null;
    try pl.compactCached();
    const r = pl.nextRange() orelse return null;
    const job = try pl.gpa.create(CompactJob);
    errdefer pl.gpa.destroy(job);
    job.* = .{ .gpa = pl.gpa, .gen = pl.layout_gen, .first = pl.head, .range = r, .copies = undefined, .deflate = pl.opts.deflate };
    var first: ?*Node = null;
    errdefer if (first) |f| freeNodes(pl.gpa, &pl.pool, f);
    var last: ?*Node = null;
    var src: ?*Node = pl.head;
    for (0..r.count) |_| {
        const s = src.?;
        const buf = try pl.pool.alloc(@intCast(s.page.buf.len));
        const node = pl.gpa.create(Node) catch |e| {
            pl.pool.free(buf);
            return e;
        };
        node.* = .{ .prev = last, .page = .{ .buf = buf, .layout = s.page.layout } };
        s.page.cloneInto(&node.page);
        if (last) |l| l.next = node else first = node;
        last = node;
        src = s.next;
    }
    job.copies = first.?;
    pl.job_out = true;
    return job;
}

/// Ends a background compaction: swaps the encoded rows out if the hot
/// list still holds them unchanged, else drops the result. Frees the job
/// and sets `compact_due` if more is due.
pub fn finishCompact(pl: *PageList, job: *CompactJob) !void {
    const result = job.result;
    job.result = null;
    const r = job.range;
    const fresh = job.gen == pl.layout_gen and job.first == pl.head;
    pl.cancelCompact(job);
    var cp = result orelse return;
    const now = if (fresh) pl.nextRange() else null;
    if (now == null or now.?.cached != null or now.?.count != r.count or now.?.n != r.n) {
        cp.deinit(pl.gpa);
        return;
    }
    try pl.retire(r, cp);
    pl.compact_due = pl.nextRange() != null;
}

/// Frees a job without using its result (shutdown, or a stale job).
pub fn cancelCompact(pl: *PageList, job: *CompactJob) void {
    if (job.result) |*cp| cp.deinit(pl.gpa);
    freeNodes(pl.gpa, &pl.pool, job.copies);
    pl.gpa.destroy(job);
    pl.job_out = false;
}

/// The decode cache entry whose nodes start at `n`.
fn thawedAt(pl: *const PageList, n: *Node) ?usize {
    for (pl.thawed.items, 0..) |e, i| if (e.first == n) return i;
    return null;
}

/// Removes decode cache entry `i` and returns its encoding.
fn takeThawed(pl: *PageList, i: usize) cold.ColdPage {
    const e = pl.thawed.orderedRemove(i);
    pl.thawed_bytes -= e.page.bytesUsed();
    return e.page;
}

/// Drops decode cache entry `i`.
fn dropThawed(pl: *PageList, i: usize) void {
    var cp = pl.takeThawed(i);
    cp.deinit(pl.gpa);
}

/// Empties the decode cache (the hot rows changed shape).
fn clearThawed(pl: *PageList) void {
    while (pl.thawed.items.len > 0) pl.dropThawed(pl.thawed.items.len - 1);
}

/// Keeps `e` in the decode cache, dropping the oldest entry when full;
/// frees its page if it cannot be kept.
fn cacheThawed(pl: *PageList, e: Thawed) void {
    if (pl.thawed.items.len == thaw_cache) pl.dropThawed(0);
    pl.thawed.append(pl.gpa, e) catch {
        var cp = e.page;
        cp.deinit(pl.gpa);
        return;
    };
    pl.thawed_bytes += e.page.bytesUsed();
}

/// Gives pins in the first `n` hot rows (being compacted into cold page
/// `seq`) their logical position, and marks them garbage.
fn freezePins(pl: *PageList, n: u64, seq: u64) void {
    var line: u32 = 0;
    var row_in_line: u32 = 0;
    var p: Pin = pl.firstHot();
    for (0..n) |i| {
        for (pl.pins.items) |t| if (!t.garbage and t.pin.node == p.node and t.pin.y == p.y) {
            t.cold = .{ .seq = seq, .line = line, .offset = row_in_line * pl.cols + t.pin.x };
            t.garbage = true;
        };
        if (p.row().wrap) row_in_line += 1 else {
            line += 1;
            row_in_line = 0;
        }
        if (i + 1 < n) p = next(p).?;
    }
}

/// Restores pins into cold page `seq`, just decoded into `fresh` at width
/// `cols`. Wide characters can wrap a column early at another width, so
/// the column is approximate there; it never leaves its logical line.
fn thawPins(pl: *PageList, fresh: *const PageList, seq: u64) void {
    for (pl.pins.items) |t| {
        const cp = t.cold orelse continue;
        if (cp.seq != seq) continue;
        t.cold = null;
        if (fresh.total == 0) continue;
        var p: Pin = .{ .node = fresh.head, .y = 0 };
        var line: u32 = 0;
        const found = while (line < cp.line) {
            if (!p.row().wrap) line += 1;
            p = next(p) orelse break false;
        } else true;
        if (!found) continue;
        var off = cp.offset;
        while (off >= fresh.cols and p.row().wrap) {
            p = next(p) orelse break;
            off -= fresh.cols;
        }
        p.x = @intCast(@min(off, fresh.cols - 1));
        t.pin = p;
        t.garbage = false;
    }
}

/// Decodes the newest cold page back into hot pages above `head`, at the
/// current width. Row indices do not change; pins into the page return.
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
    pl.thawPins(&fresh, c.seq);
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
    if (fresh.total > 0) {
        pl.cacheThawed(.{ .page = gone.page, .first = fresh.head, .count = fresh.nodes, .rows = fresh.total });
    } else gone.page.deinit(pl.gpa);
    pl.layout_gen +%= 1;
    pl.dirty_generation +%= 1;
}

/// Recounts cold rows at the current width (after a resize; the lines
/// themselves re-wrap when decoded).
fn recountCold(pl: *PageList) void {
    pl.clearThawed();
    pl.layout_gen +%= 1;
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
    pl.clearThawed();
    pl.layout_gen +%= 1;
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
    var thawed_bytes: usize = 0;
    for (pl.thawed.items) |e| {
        thawed_bytes += e.page.bytesUsed();
        if (!nodeIn(pl.head, e.first)) return error.StaleDecodeCache;
    }
    if (thawed_bytes != pl.thawed_bytes) return error.BadColdCounts;
    if (pl.total < pl.rows) return error.TooFewRows;
}

test {
    _ = @import("PageList_test.zig");
    _ = @import("cold_scrollback_test.zig");
}
