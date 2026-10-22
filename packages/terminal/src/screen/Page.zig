//! A page: one contiguous, offset-addressed buffer holding a header, rows,
//! cells, the style set, the grapheme map and arena, and the hyperlink map,
//! table and arena. Nothing in the buffer is a pointer, so `cloneInto` is a
//! single `@memcpy` of `layout.total` bytes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const cell_mod = @import("cell.zig");
const style_mod = @import("style.zig");
const cellmap = @import("cellmap.zig");
const graph = @import("grapheme.zig");
const hyperlink = @import("hyperlink.zig");

pub const Cell = cell_mod.Cell;
pub const Row = cell_mod.Row;
pub const Style = style_mod.Style;
pub const Link = hyperlink.Link;

const Page = @This();

/// Alignment of page buffers.
pub const buf_align: std.mem.Alignment = .fromByteUnits(std.heap.page_size_min);
/// A page buffer.
pub const Buffer = []align(std.heap.page_size_min) u8;

/// Default page size.
pub const default_bytes: u32 = 256 * 1024;
/// Page size used when a row does not fit the default size.
pub const large_bytes: u32 = 1024 * 1024;

/// Mutable page state at offset 0 of the buffer.
pub const Header = extern struct {
    cols: u16,
    rows_cap: u16,
    /// Rows in use (0..rows_cap).
    rows: u16 = 0,
    _pad: u16 = 0,
    styles: style_mod.StyleSet.State = .{},
    gmap: cellmap.CellMap.State = .{},
    garena: graph.Arena.State = .{},
    lmap: cellmap.CellMap.State = .{},
    links: hyperlink.Table.State = .{},
};

/// Offsets and capacities of every table in a page buffer.
pub const Layout = struct {
    rows_cap: u16,
    cols: u16,
    rows_off: u32,
    cells_off: u32,
    styles_off: u32,
    styles_cap: u16,
    style_index_off: u32,
    graph_map_off: u32,
    graph_map_cap: u32,
    graph_arena_off: u32,
    graph_arena_len: u32,
    link_map_off: u32,
    link_map_cap: u32,
    link_entries_off: u32,
    link_cap: u16,
    link_arena_off: u32,
    link_arena_len: u32,
    total: u32,
};

fn alignUp(x: u32, a: u32) u32 {
    return (x + a - 1) / a * a;
}

fn layoutRows(cols: u16, rows_cap: u16) Layout {
    const ncells: u32 = @as(u32, cols) * rows_cap;
    var l: Layout = undefined;
    l.cols = cols;
    l.rows_cap = rows_cap;
    var off: u32 = alignUp(@sizeOf(Header), 8);
    l.rows_off = off;
    off += @as(u32, rows_cap) * @sizeOf(Row);
    l.cells_off = off;
    off += ncells * @sizeOf(Cell);
    l.styles_cap = @intCast(std.math.clamp(ncells / 64, 16, 1024));
    l.styles_off = off;
    off += @as(u32, l.styles_cap) * @sizeOf(style_mod.Entry);
    l.style_index_off = off;
    off += style_mod.indexCap(l.styles_cap) * 2;
    off = alignUp(off, 8);
    l.graph_map_cap = std.math.ceilPowerOfTwoAssert(u32, @max(16, ncells / 32));
    l.graph_map_off = off;
    off += cellmap.CellMap.bytes(l.graph_map_cap);
    l.graph_arena_len = @max(64, ncells / 8);
    l.graph_arena_off = off;
    off += l.graph_arena_len * @sizeOf(u21);
    off = alignUp(off, 8);
    l.link_map_cap = std.math.ceilPowerOfTwoAssert(u32, @max(16, ncells / 32));
    l.link_map_off = off;
    off += cellmap.CellMap.bytes(l.link_map_cap);
    l.link_cap = 64;
    l.link_entries_off = off;
    off += @as(u32, l.link_cap) * @sizeOf(hyperlink.Entry);
    l.link_arena_len = 8 * 1024;
    l.link_arena_off = off;
    off += l.link_arena_len;
    l.total = alignUp(off, 8);
    return l;
}

/// The largest layout of `cols` columns that fits `page_bytes`. `rows_cap`
/// is 0 when not even one row fits (use `large_bytes`).
pub fn layoutFor(cols: u16, page_bytes: u32) Layout {
    std.debug.assert(cols >= 1);
    const per_row: u32 = @as(u32, cols) * @sizeOf(Cell) + @sizeOf(Row);
    var rows: u32 = @min(std.math.maxInt(u16), page_bytes / per_row + 1);
    while (rows > 0) : (rows -= 1) {
        const l = layoutRows(cols, @intCast(rows));
        if (l.total <= page_bytes) return l;
    }
    var l = layoutRows(cols, 1);
    l.rows_cap = 0;
    return l;
}

/// The page buffer size to use for `cols` columns.
pub fn bytesFor(cols: u16) u32 {
    return if (layoutFor(cols, default_bytes).rows_cap >= 2) default_bytes else large_bytes;
}

buf: Buffer,
layout: Layout,

/// Formats `buf` as an empty page of `cols` columns.
pub fn init(buf: Buffer, cols: u16) Page {
    const l = layoutFor(cols, @intCast(buf.len));
    std.debug.assert(l.rows_cap >= 1);
    var p: Page = .{ .buf = buf, .layout = l };
    p.header().* = .{ .cols = cols, .rows_cap = l.rows_cap };
    const rows = p.rowSlice();
    for (rows, 0..) |*r, y| r.* = .{ .cells_off = l.cells_off + @as(u32, @intCast(y)) * cols * @sizeOf(Cell) };
    // Cells of unused rows are garbage; `PageList` blanks a row when it
    // comes into use, so formatting a recycled page costs no full memset.
    p.styles().clear(p.base(), &p.header().styles);
    p.gmap().clear(p.base(), &p.header().gmap);
    p.lmap().clear(p.base(), &p.header().lmap);
    return p;
}

/// The buffer base pointer.
pub inline fn base(p: *const Page) [*]u8 {
    return p.buf.ptr;
}

/// The page header.
pub inline fn header(p: *const Page) *Header {
    return @ptrCast(@alignCast(p.buf.ptr));
}

/// Columns of every row.
pub inline fn width(p: *const Page) u16 {
    return p.layout.cols;
}

/// Rows in use.
pub inline fn rowCount(p: *const Page) u16 {
    return p.header().rows;
}

fn rowSlice(p: *const Page) []Row {
    const r: [*]Row = @ptrCast(@alignCast(p.buf.ptr + p.layout.rows_off));
    return r[0..p.layout.rows_cap];
}

fn allCells(p: *const Page) []Cell {
    const c: [*]Cell = @ptrCast(@alignCast(p.buf.ptr + p.layout.cells_off));
    return c[0 .. @as(usize, p.layout.rows_cap) * p.layout.cols];
}

/// Brings the next unused row into use as a blank row; returns its index.
pub fn addRow(p: *Page) u16 {
    const h = p.header();
    std.debug.assert(h.rows < p.layout.rows_cap);
    const y = h.rows;
    h.rows += 1;
    const r = p.row(y);
    r.* = .{ .cells_off = r.cells_off, .dirty = true };
    @memset(std.mem.sliceAsBytes(p.cells(r)), 0);
    return y;
}

/// Row `y` (0 ≤ y < rows_cap).
pub inline fn row(p: *const Page, y: u16) *Row {
    std.debug.assert(y < p.layout.rows_cap);
    return &p.rowSlice()[y];
}

/// The cells of `r`.
pub inline fn cells(p: *const Page, r: *const Row) []Cell {
    const c: [*]Cell = @ptrCast(@alignCast(p.buf.ptr + r.cells_off));
    return c[0..p.layout.cols];
}

/// The storage index of a cell in this page (key of the side maps).
pub inline fn cellIndex(p: *const Page, c: *const Cell) u32 {
    return @intCast((@intFromPtr(c) - @intFromPtr(p.buf.ptr) - p.layout.cells_off) / @sizeOf(Cell));
}

fn styles(p: *const Page) style_mod.StyleSet {
    return .{ .entries_off = p.layout.styles_off, .index_off = p.layout.style_index_off, .cap = p.layout.styles_cap };
}

fn gmap(p: *const Page) cellmap.CellMap {
    return .{ .off = p.layout.graph_map_off, .cap = p.layout.graph_map_cap };
}

fn garena(p: *const Page) graph.Arena {
    return .{ .off = p.layout.graph_arena_off, .cap = p.layout.graph_arena_len };
}

fn lmap(p: *const Page) cellmap.CellMap {
    return .{ .off = p.layout.link_map_off, .cap = p.layout.link_map_cap };
}

fn links(p: *const Page) hyperlink.Table {
    return .{ .entries_off = p.layout.link_entries_off, .cap = p.layout.link_cap, .arena_off = p.layout.link_arena_off, .arena_len = p.layout.link_arena_len };
}

/// The style of a cell.
pub fn styleOf(p: *const Page, c: Cell) *const Style {
    return p.styles().get(p.base(), c.style);
}

/// The style for id `id`.
pub fn styleById(p: *const Page, id: u16) *const Style {
    return p.styles().get(p.base(), id);
}

/// The reference count of style `id`.
pub fn styleRefs(p: *const Page, id: u16) u32 {
    return p.styles().refs(p.base(), id);
}

/// Interns `s` with `n` references (one per cell that will use it).
pub fn internStyle(p: *Page, s: Style, n: u32) error{StyleSetFull}!u16 {
    return p.styles().internN(p.base(), &p.header().styles, s, n);
}

/// Adds `n` references to style `id`.
pub fn retainStyle(p: *Page, id: u16, n: u32) void {
    p.styles().retain(p.base(), id, n);
}

/// Drops `n` references to style `id`.
pub fn releaseStyle(p: *Page, id: u16, n: u32) void {
    p.styles().release(p.base(), &p.header().styles, id, n);
}

/// The extra code points of a grapheme cell (after `content`), or null.
pub fn grapheme(p: *const Page, c: *const Cell) ?[]const u21 {
    if (c.tag != .grapheme) return null;
    const slot = p.gmap().get(p.base(), p.cellIndex(c)) orelse return null;
    return p.garena().data(p.base())[slot.a..][0 .. slot.b & 0xFF];
}

/// Appends `cp` to the cluster of `c` (turning it into a grapheme cell).
/// Clusters longer than `graph.max_extra` are truncated.
pub fn appendGrapheme(p: *Page, c: *Cell, cp: u21) error{ GraphemeArenaFull, MapFull }!void {
    const base_ptr = p.base();
    const h = p.header();
    const key = p.cellIndex(c);
    const data = p.garena().data(base_ptr);
    if (c.tag == .grapheme) {
        const slot = p.gmap().get(base_ptr, key).?;
        const len = slot.b & 0xFF;
        const class: u2 = @intCast(slot.b >> 8);
        if (len == graph.max_extra) return;
        if (len < graph.classes[class]) {
            data[slot.a + len] = cp;
            slot.b += 1;
            return;
        }
        const nc = class + 1;
        const off = try p.garena().alloc(base_ptr, &h.garena, nc);
        @memcpy(data[off..][0..len], data[slot.a..][0..len]);
        data[off + len] = cp;
        p.garena().free(base_ptr, &h.garena, slot.a, class);
        slot.a = off;
        slot.b = (len + 1) | (@as(u32, nc) << 8);
        return;
    }
    const off = try p.garena().alloc(base_ptr, &h.garena, 0);
    errdefer p.garena().free(base_ptr, &h.garena, off, 0);
    data[off] = cp;
    try p.gmap().put(base_ptr, &h.gmap, key, off, 1);
    c.tag = .grapheme;
}

/// Removes the grapheme entry of `c` (keeping its base code point).
pub fn clearGrapheme(p: *Page, c: *Cell) void {
    if (c.tag != .grapheme) return;
    const h = p.header();
    if (p.gmap().get(p.base(), p.cellIndex(c))) |slot| {
        p.garena().free(p.base(), &h.garena, slot.a, @intCast(slot.b >> 8));
        p.gmap().remove(p.base(), &h.gmap, p.cellIndex(c));
    }
    c.tag = .codepoint;
}

/// The hyperlink of `c`, or null.
pub fn hyperlinkOf(p: *const Page, c: *const Cell) ?Link {
    if (!c.hyperlink) return null;
    const slot = p.lmap().get(p.base(), p.cellIndex(c)) orelse return null;
    return p.links().get(p.base(), @intCast(slot.a));
}

/// The page-local link id of `c`, or null.
pub fn linkId(p: *const Page, c: *const Cell) ?u16 {
    if (!c.hyperlink) return null;
    const slot = p.lmap().get(p.base(), p.cellIndex(c)) orelse return null;
    return @intCast(slot.a);
}

/// Interns `l` with one reference and returns its id.
pub fn internLink(p: *Page, l: Link) error{LinkTableFull}!u16 {
    return p.links().intern(p.base(), &p.header().links, l);
}

/// Adds one reference to link `id`.
pub fn retainLink(p: *Page, id: u16) void {
    p.links().retain(p.base(), id);
}

/// Drops one reference to link `id`.
pub fn releaseLink(p: *Page, id: u16) void {
    p.links().release(p.base(), &p.header().links, id);
}

/// Attaches link `id` (with a reference the caller already holds) to `c`.
/// On a full map the reference is dropped and the cell stays unlinked.
pub fn attachLink(p: *Page, c: *Cell, id: u16) void {
    p.lmap().put(p.base(), &p.header().lmap, p.cellIndex(c), id, 0) catch {
        p.releaseLink(id);
        p.header().links.dropped += 1;
        return;
    };
    c.hyperlink = true;
}

/// Removes the hyperlink of `c`.
pub fn clearLink(p: *Page, c: *Cell) void {
    if (!c.hyperlink) return;
    const key = p.cellIndex(c);
    if (p.lmap().get(p.base(), key)) |slot| {
        p.releaseLink(@intCast(slot.a));
        p.lmap().remove(p.base(), &p.header().lmap, key);
    }
    c.hyperlink = false;
}

/// Releases everything `c` references and writes `with` (which must hold no
/// references of its own: style 0, no grapheme, no link).
pub inline fn clearCell(p: *Page, c: *Cell, with: Cell) void {
    if (c.style != 0) p.releaseStyle(c.style, 1);
    if (c.tag == .grapheme) p.clearGrapheme(c);
    if (c.hyperlink) p.clearLink(c);
    c.* = with;
}

/// Clears `cs` (a slice of one row of this page). Rows without styles,
/// graphemes or links take the memset fast path.
pub fn clearCells(p: *Page, r: *Row, cs: []Cell, with: Cell) void {
    if (r.styled or r.has_grapheme or r.has_hyperlink) {
        for (cs) |*c| p.clearCell(c, with);
    } else {
        // Memset as u64 words: a packed-struct memset does not vectorize.
        const words: []u64 = @ptrCast(cs);
        @memset(words, @bitCast(with));
    }
}

/// Moves cell `src` to `dst` within this page; `dst` must hold no references.
/// The grapheme and link entries follow the cell.
pub fn moveCell(p: *Page, dst: *Cell, src: *Cell) void {
    if (dst == src) return;
    const v = src.*;
    const b = p.base();
    const h = p.header();
    if (v.tag == .grapheme) {
        const slot = p.gmap().get(b, p.cellIndex(src)).?.*;
        p.gmap().remove(b, &h.gmap, p.cellIndex(src));
        p.gmap().put(b, &h.gmap, p.cellIndex(dst), slot.a, slot.b) catch unreachable;
    }
    if (v.hyperlink) {
        const slot = p.lmap().get(b, p.cellIndex(src)).?.*;
        p.lmap().remove(b, &h.lmap, p.cellIndex(src));
        p.lmap().put(b, &h.lmap, p.cellIndex(dst), slot.a, slot.b) catch unreachable;
    }
    dst.* = v;
    src.* = .blank;
}

/// Copies cell `src` of page `sp` into `dst` of this page (re-interning its
/// style, grapheme and link); `dst` must hold no references. Attributes that
/// do not fit are dropped rather than failing.
pub fn copyCellFrom(p: *Page, dst: *Cell, sp: *const Page, src: *const Cell) void {
    var v = src.*;
    v.hyperlink = false;
    if (v.style != 0) {
        v.style = p.internStyle(sp.styleOf(v).*, 1) catch 0;
    }
    if (v.tag == .grapheme) v.tag = .codepoint;
    dst.* = v;
    if (sp.grapheme(src)) |extra| {
        for (extra) |cp| p.appendGrapheme(dst, cp) catch break;
    }
    if (sp.hyperlinkOf(src)) |l| {
        if (p.internLink(l)) |id| p.attachLink(dst, id) else |_| {}
    }
}

/// Copies this page into `dst`, whose buffer must be at least as large.
pub fn cloneInto(p: *const Page, dst: *Page) void {
    @memcpy(dst.buf[0..p.layout.total], p.buf[0..p.layout.total]);
    dst.layout = p.layout;
}

/// Checks refcounts, map entries and wide/spacer pairing of every cell.
pub fn verify(p: *const Page, gpa: Allocator) !void {
    const counts = try gpa.alloc(u32, @as(usize, p.layout.styles_cap) + 1);
    defer gpa.free(counts);
    @memset(counts, 0);
    const link_counts = try gpa.alloc(u32, @as(usize, p.layout.link_cap) + 1);
    defer gpa.free(link_counts);
    @memset(link_counts, 0);
    var graphemes: u32 = 0;
    var linked: u32 = 0;
    for (p.rowSlice()[0..p.rowCount()]) |*r| {
        const cs = p.cells(r);
        var styled = false;
        var has_g = false;
        var has_l = false;
        for (cs, 0..) |*c, x| {
            counts[c.style] += 1;
            if (c.style != 0) styled = true;
            if (c.tag == .grapheme) {
                has_g = true;
                graphemes += 1;
                if (p.gmap().get(p.base(), p.cellIndex(c)) == null) return error.GraphemeEntryMissing;
            }
            if (c.hyperlink) {
                has_l = true;
                linked += 1;
                const slot = p.lmap().get(p.base(), p.cellIndex(c)) orelse return error.LinkEntryMissing;
                link_counts[slot.a] += 1;
            }
            switch (c.wide) {
                .wide => if (x + 1 >= cs.len or cs[x + 1].wide != .spacer_tail) return error.WideWithoutTail,
                .spacer_tail => if (x == 0 or cs[x - 1].wide != .wide) return error.TailWithoutWide,
                .spacer_head => if (!c.isEmpty()) return error.HeadWithContent, // at the last column or right margin
                .narrow => {},
            }
        }
        if (styled and !r.styled) return error.RowStyledFlag;
        if (has_g and !r.has_grapheme) return error.RowGraphemeFlag;
        if (has_l and !r.has_hyperlink) return error.RowLinkFlag;
    }
    counts[0] = 0;
    try p.styles().verify(p.base(), &p.header().styles, counts);
    if (graphemes != p.header().gmap.count) return error.GraphemeCount;
    if (linked != p.header().lmap.count) return error.LinkCount;
    const lt = p.links();
    for (1..@as(usize, p.header().links.used) + 1) |id| {
        if (lt.refs(p.base(), @intCast(id)) != link_counts[id]) return error.LinkRefcountMismatch;
    }
}

/// A recycling allocator of page buffers in two size classes.
pub const PagePool = struct {
    gpa: Allocator,
    free_small: std.ArrayList(Buffer) = .empty,
    free_large: std.ArrayList(Buffer) = .empty,
    /// Buffers kept for reuse per class.
    pub const keep = 64;

    /// Creates an empty pool.
    pub fn init(gpa: Allocator) PagePool {
        return .{ .gpa = gpa };
    }

    /// Frees every recycled buffer.
    pub fn deinit(pp: *PagePool) void {
        for (pp.free_small.items) |b| pp.gpa.free(b);
        for (pp.free_large.items) |b| pp.gpa.free(b);
        pp.free_small.deinit(pp.gpa);
        pp.free_large.deinit(pp.gpa);
    }

    /// A buffer of `bytes` (`default_bytes` or `large_bytes`).
    pub fn alloc(pp: *PagePool, bytes: u32) Allocator.Error!Buffer {
        const list = if (bytes == large_bytes) &pp.free_large else &pp.free_small;
        if (list.pop()) |b| return b;
        return pp.gpa.alignedAlloc(u8, buf_align, bytes);
    }

    /// Returns a buffer for reuse.
    pub fn free(pp: *PagePool, b: Buffer) void {
        const list = if (b.len == large_bytes) &pp.free_large else &pp.free_small;
        if (list.items.len < keep) {
            list.append(pp.gpa, b) catch return pp.gpa.free(b);
            return;
        }
        pp.gpa.free(b);
    }
};

test {
    _ = @import("Page_test.zig");
}
