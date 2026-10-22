//! Cold pages: a compact encoding of whole logical lines that left the hot
//! window. A cold page keeps about one byte per printed character plus the
//! runs and tables needed to rebuild the exact cells, optionally deflated.
//! `decode` materialises the lines as rows at any width; `text` reads the
//! plain text without touching styles (search and capture); `rowsAt`
//! counts rows at a width without decoding (scrollbar, viewport math).
//!
//! Raw format (version 1, varints unless noted):
//! - magic `ZGCP` (4 bytes), version (1 byte), line count;
//! - styles: count, then each `Style` as 16 raw bytes (padding zeroed);
//! - links: count, then each `uri_len uri id_len id`;
//! - per line: width in cells, flags (bits 0-2 row mark, bit 3 synthetic),
//!   text length and UTF-8 text, then four lists, each a count followed by
//!   entries whose cell index is a delta from the previous entry:
//!   runs `(cells, style index + 1 or 0, attrs)` with attrs bit 0
//!   protected and bits 1-2 semantic; wide cells `(cell)`; graphemes
//!   `(cell, extra code points)`; backgrounds `(cell, len, tag, content)`;
//!   links `(cell, len, link index)`.
//!
//! The text holds one code point per non-spacer cell (0 for an empty or
//! background cell) followed by a grapheme's extra code points. Spacer
//! tails are implied by the wide list; spacer heads are not stored, they
//! are re-created wherever a wide character meets the right edge. Wide
//! positions are stored rather than re-measured, so decoding never depends
//! on the width tables in force when the line was printed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;
const Page = @import("Page.zig");
const PageList = @import("PageList.zig");
const cell_mod = @import("cell.zig");
const Cell = cell_mod.Cell;
const Row = cell_mod.Row;
const Style = Page.Style;
const Link = Page.Link;
const Pin = PageList.Pin;

pub const magic = "ZGCP";
pub const version: u8 = 1;

/// Encoding options.
pub const EncodeOptions = struct {
    /// Deflate the blob (kept only when it saves at least 20%).
    deflate: bool = true,
};

/// A cold page: whole logical lines in compact form.
pub const ColdPage = struct {
    line_count: u32,
    /// The raw or deflated encoding.
    blob: []u8,
    compressed: bool,
    raw_len: u32,
    /// Cell width of each logical line, for row counting without decoding.
    line_widths: []u32,
    /// Lines holding wide characters (their row count needs an exact scan).
    has_wide: std.DynamicBitSetUnmanaged,
    /// `rowsAt` cache: the width and its row count (cols 0 = empty).
    cached_cols: u16 = 0,
    cached_rows: u32 = 0,

    /// Frees the page.
    pub fn deinit(cp: *ColdPage, gpa: Allocator) void {
        gpa.free(cp.blob);
        gpa.free(cp.line_widths);
        cp.has_wide.deinit(gpa);
        cp.* = undefined;
    }

    /// Bytes held, for the scrollback cap.
    pub fn bytesUsed(cp: *const ColdPage) usize {
        return cp.blob.len + cp.line_widths.len * @sizeOf(u32) + (cp.has_wide.bit_length + 7) / 8 + @sizeOf(ColdPage);
    }

    /// Rows the lines take at `cols` columns, cached per width.
    pub fn rowsAt(cp: *ColdPage, gpa: Allocator, cols: u16) !u32 {
        if (cp.cached_cols == cols) return cp.cached_rows;
        var rows: u32 = 0;
        var wide_lines = false;
        for (cp.line_widths, 0..) |w, i| {
            if (cp.has_wide.isSet(i)) {
                wide_lines = true;
                continue;
            }
            rows += @max(1, (w + cols - 1) / cols);
        }
        if (wide_lines) {
            // Exact scan of the lines with wide characters.
            const raw = try cp.rawBytes(gpa);
            defer if (cp.compressed) gpa.free(raw);
            var r: Decoder = try .init(gpa, raw);
            defer r.deinit(gpa);
            for (0..cp.line_count) |i| {
                const line = try r.line(gpa);
                defer line.deinit(gpa);
                if (cp.has_wide.isSet(i)) rows += wrappedRows(line, cols);
            }
        }
        cp.cached_cols = cols;
        cp.cached_rows = rows;
        return rows;
    }

    /// Appends every logical line's text, `\n`-joined, with empty cells as
    /// spaces and no trailing newline.
    pub fn text(cp: *const ColdPage, gpa: Allocator, out: *std.ArrayList(u8)) !void {
        const raw = try cp.rawBytes(gpa);
        defer if (cp.compressed) gpa.free(raw);
        var r: Decoder = try .init(gpa, raw);
        defer r.deinit(gpa);
        for (0..cp.line_count) |i| {
            if (i > 0) try out.append(gpa, '\n');
            const line = try r.line(gpa);
            defer line.deinit(gpa);
            var it = std.unicode.Utf8View.initUnchecked(line.text).iterator();
            while (it.nextCodepointSlice()) |s| {
                if (s.len == 1 and s[0] == 0) try out.append(gpa, ' ') else try out.appendSlice(gpa, s);
            }
        }
    }

    /// Appends the lines as rows of `dst` (at its width) at its tail.
    pub fn decode(cp: *const ColdPage, gpa: Allocator, dst: *PageList) !void {
        const raw = try cp.rawBytes(gpa);
        defer if (cp.compressed) gpa.free(raw);
        var r: Decoder = try .init(gpa, raw);
        defer r.deinit(gpa);
        for (0..cp.line_count) |_| {
            const line = try r.line(gpa);
            defer line.deinit(gpa);
            try emitLine(dst, &r, line);
        }
    }

    fn rawBytes(cp: *const ColdPage, gpa: Allocator) ![]u8 {
        if (!cp.compressed) return cp.blob;
        const out = try gpa.alloc(u8, cp.raw_len);
        errdefer gpa.free(out);
        const window = try gpa.alloc(u8, flate.max_window_len);
        defer gpa.free(window);
        var in: std.Io.Reader = .fixed(cp.blob);
        var d: flate.Decompress = .init(&in, .raw, window);
        d.reader.readSliceAll(out) catch return error.CorruptColdPage;
        return out;
    }
};

// ---------------------------------------------------------------------------
// Encoding.

const Enc = struct {
    gpa: Allocator,
    out: std.ArrayList(u8) = .empty,
    styles: std.ArrayList(Style) = .empty,
    links: std.ArrayList(Link) = .empty,
    /// Per-line lists, reused.
    runs: std.ArrayList(u32) = .empty,
    wides: std.ArrayList(u32) = .empty,
    graphs: std.ArrayList(u32) = .empty,
    bgs: std.ArrayList(u32) = .empty,
    lks: std.ArrayList(u32) = .empty,
    text: std.ArrayList(u8) = .empty,

    fn deinit(e: *Enc) void {
        e.out.deinit(e.gpa);
        e.styles.deinit(e.gpa);
        e.links.deinit(e.gpa);
        e.runs.deinit(e.gpa);
        e.wides.deinit(e.gpa);
        e.graphs.deinit(e.gpa);
        e.bgs.deinit(e.gpa);
        e.lks.deinit(e.gpa);
        e.text.deinit(e.gpa);
    }

    fn styleIndex(e: *Enc, s: Style) !u32 {
        for (e.styles.items, 0..) |x, i| if (x.eql(s)) return @intCast(i);
        try e.styles.append(e.gpa, s);
        return @intCast(e.styles.items.len - 1);
    }

    fn linkIndex(e: *Enc, l: Link) !u32 {
        for (e.links.items, 0..) |x, i| if (std.mem.eql(u8, x.uri, l.uri) and std.mem.eql(u8, x.id, l.id)) return @intCast(i);
        try e.links.append(e.gpa, l);
        return @intCast(e.links.items.len - 1);
    }
};

fn putVarint(gpa: Allocator, out: *std.ArrayList(u8), v: u64) !void {
    var x = v;
    while (x >= 0x80) : (x >>= 7) try out.append(gpa, @as(u8, @truncate(x)) | 0x80);
    try out.append(gpa, @truncate(x));
}

fn putCp(gpa: Allocator, out: *std.ArrayList(u8), cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch {
        try out.appendSlice(gpa, "\u{FFFD}");
        return;
    };
    try out.appendSlice(gpa, buf[0..n]);
}

fn attrsOf(c: Cell) u8 {
    return @as(u8, @intFromBool(c.protected)) | (@as(u8, @intFromEnum(c.semantic)) << 1);
}

/// Encodes `n_rows` rows from `first`, which must be whole logical lines
/// (the last row does not wrap).
pub fn encode(gpa: Allocator, first: Pin, n_rows: u64, o: EncodeOptions) !ColdPage {
    var e: Enc = .{ .gpa = gpa };
    defer e.deinit();
    var lines: std.ArrayList(u8) = .empty;
    defer lines.deinit(gpa);
    var widths: std.ArrayList(u32) = .empty;
    defer widths.deinit(gpa);
    var wide_bits: std.ArrayList(bool) = .empty;
    defer wide_bits.deinit(gpa);

    var p: ?Pin = first;
    var r: u64 = 0;
    while (r < n_rows) {
        const start = p.?;
        // The rows of one logical line.
        var last = start;
        var n: u64 = 1;
        while (last.row().wrap and r + n < n_rows) : (n += 1) last = PageList.next(last).?;
        const info = try encodeLine(&e, &lines, start, n);
        try widths.append(gpa, info.width);
        try wide_bits.append(gpa, info.wide);
        r += n;
        p = PageList.next(last);
    }

    // Header and tables, then the lines.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.appendSlice(gpa, magic);
    try out.append(gpa, version);
    try putVarint(gpa, &out, widths.items.len);
    try putVarint(gpa, &out, e.styles.items.len);
    for (e.styles.items) |s| {
        var z = s;
        z._pad = 0;
        z.flags._p = 0;
        try out.appendSlice(gpa, std.mem.asBytes(&z));
    }
    try putVarint(gpa, &out, e.links.items.len);
    for (e.links.items) |l| {
        try putVarint(gpa, &out, l.uri.len);
        try out.appendSlice(gpa, l.uri);
        try putVarint(gpa, &out, l.id.len);
        try out.appendSlice(gpa, l.id);
    }
    try out.appendSlice(gpa, lines.items);

    var cp: ColdPage = .{
        .line_count = @intCast(widths.items.len),
        .blob = undefined,
        .compressed = false,
        .raw_len = @intCast(out.items.len),
        .line_widths = try widths.toOwnedSlice(gpa),
        .has_wide = undefined,
    };
    errdefer gpa.free(cp.line_widths);
    cp.has_wide = try .initEmpty(gpa, wide_bits.items.len);
    errdefer cp.has_wide.deinit(gpa);
    for (wide_bits.items, 0..) |b, i| if (b) cp.has_wide.set(i);

    if (o.deflate) {
        if (try deflate(gpa, out.items)) |z| {
            if (z.len * 5 <= out.items.len * 4) {
                cp.blob = z;
                cp.compressed = true;
                return cp;
            }
            gpa.free(z);
        }
    }
    cp.blob = try out.toOwnedSlice(gpa);
    return cp;
}

fn deflate(gpa: Allocator, raw: []const u8) !?[]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, raw.len / 2 + 64);
    defer out.deinit();
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    const c = try gpa.create(flate.Compress);
    defer gpa.destroy(c);
    c.* = flate.Compress.init(&out.writer, window, .raw, .fastest) catch return null;
    c.writer.writeAll(raw) catch return null;
    c.finish() catch return null;
    return try out.toOwnedSlice();
}

fn encodeLine(e: *Enc, lines: *std.ArrayList(u8), start: Pin, n: u64) !struct { width: u32, wide: bool } {
    const gpa = e.gpa;
    e.runs.clearRetainingCapacity();
    e.wides.clearRetainingCapacity();
    e.graphs.clearRetainingCapacity();
    e.bgs.clearRetainingCapacity();
    e.lks.clearRetainingCapacity();
    e.text.clearRetainingCapacity();

    var idx: u32 = 0; // cell index in the line
    // Current run.
    var run_len: u32 = 0;
    var run_style: u32 = 0;
    var run_attrs: u8 = 0;
    // Current link run.
    var lk_start: u32 = 0;
    var lk_len: u32 = 0;
    var lk_idx: u32 = 0;
    var last_wide: u32 = 0;
    var last_graph: u32 = 0;
    var last_bg: u32 = 0;
    var last_lk: u32 = 0;

    const first_row = start.row().*;
    var p = start;
    for (0..n) |ri| {
        if (ri > 0) p = PageList.next(p).?;
        const page = &p.node.page;
        const cs = p.cells();
        var end = cs.len;
        if (ri + 1 == n) {
            while (end > 0 and @as(u64, @bitCast(cs[end - 1])) == 0) end -= 1;
        }
        for (cs[0..end]) |*c| {
            if (c.wide == .spacer_head) continue;
            // Style run.
            const sidx: u32 = if (c.style == 0) 0 else 1 + try e.styleIndex(page.styleOf(c.*).*);
            const attrs = attrsOf(c.*);
            if (run_len > 0 and (sidx != run_style or attrs != run_attrs)) {
                try e.runs.appendSlice(gpa, &.{ run_len, run_style, run_attrs });
                run_len = 0;
            }
            run_style = sidx;
            run_attrs = attrs;
            run_len += 1;
            // Link run.
            const link = page.hyperlinkOf(c);
            const lidx: ?u32 = if (link) |l| try e.linkIndex(l) else null;
            if (lk_len > 0 and (lidx == null or lidx.? != lk_idx or lk_start + lk_len != idx)) {
                try e.lks.appendSlice(gpa, &.{ lk_start - last_lk, lk_len, lk_idx });
                last_lk = lk_start;
                lk_len = 0;
            }
            if (lidx) |li| {
                if (lk_len == 0) {
                    lk_start = idx;
                    lk_idx = li;
                }
                lk_len += 1;
            }
            switch (c.wide) {
                .spacer_tail => {}, // implied by the wide entry
                .wide => {
                    try e.wides.append(gpa, idx - last_wide);
                    last_wide = idx;
                },
                else => {},
            }
            if (c.wide != .spacer_tail) switch (c.tag) {
                .codepoint => try putCp(gpa, &e.text, @intCast(c.content)),
                .grapheme => {
                    try putCp(gpa, &e.text, @intCast(c.content));
                    const extra = page.grapheme(c) orelse &.{};
                    for (extra) |x| try putCp(gpa, &e.text, x);
                    try e.graphs.appendSlice(gpa, &.{ idx - last_graph, @intCast(extra.len) });
                    last_graph = idx;
                },
                .bg_palette, .bg_rgb => {
                    try e.text.append(gpa, 0);
                    try e.bgs.appendSlice(gpa, &.{ idx - last_bg, 1, @intFromEnum(c.tag), c.content });
                    last_bg = idx;
                },
            };
            idx += 1;
        }
    }
    if (run_len > 0) try e.runs.appendSlice(gpa, &.{ run_len, run_style, run_attrs });
    if (lk_len > 0) try e.lks.appendSlice(gpa, &.{ lk_start - last_lk, lk_len, lk_idx });

    try putVarint(gpa, lines, idx);
    const flags: u8 = @as(u8, @intFromEnum(first_row.mark)) | (@as(u8, @intFromBool(first_row.synthetic)) << 3);
    try lines.append(gpa, flags);
    try putVarint(gpa, lines, e.text.items.len);
    try lines.appendSlice(gpa, e.text.items);
    for ([_]struct { []const u32, usize }{ .{ e.runs.items, 3 }, .{ e.wides.items, 1 }, .{ e.graphs.items, 2 }, .{ e.bgs.items, 4 }, .{ e.lks.items, 3 } }) |list| {
        try putVarint(gpa, lines, list[0].len / list[1]);
        for (list[0]) |v| try putVarint(gpa, lines, v);
    }
    return .{ .width = idx, .wide = e.wides.items.len > 0 };
}

// ---------------------------------------------------------------------------
// Decoding.

/// One decoded line: its text and lists (absolute cell indices).
const Line = struct {
    width: u32,
    flags: u8,
    text: []const u8,
    /// (cells, style index + 1 or 0, attrs)
    runs: []u32,
    wides: []u32,
    /// (cell, extra count)
    graphs: []u32,
    /// (cell, len, tag, content)
    bgs: []u32,
    /// (cell, len, link index)
    links: []u32,

    fn deinit(l: Line, gpa: Allocator) void {
        gpa.free(l.runs);
        gpa.free(l.wides);
        gpa.free(l.graphs);
        gpa.free(l.bgs);
        gpa.free(l.links);
    }
};

const Decoder = struct {
    raw: []const u8,
    pos: usize,
    styles: []align(1) const Style,
    /// The link table, as slices into `raw`.
    links: []Link = &.{},

    fn init(gpa: Allocator, raw: []const u8) !Decoder {
        if (raw.len < 5 or !std.mem.eql(u8, raw[0..4], magic) or raw[4] != version) return error.CorruptColdPage;
        var d: Decoder = .{ .raw = raw, .pos = 5, .styles = &.{} };
        _ = try d.varint(); // line count (the page keeps it)
        const ns = try d.varint();
        if (ns > raw.len / @sizeOf(Style)) return error.CorruptColdPage;
        d.styles = std.mem.bytesAsSlice(Style, try d.bytes(ns * @sizeOf(Style)));
        const nl = try d.varint();
        if (nl > raw.len) return error.CorruptColdPage;
        d.links = try gpa.alloc(Link, @intCast(nl));
        errdefer gpa.free(d.links);
        for (d.links) |*l| {
            const uri = try d.bytes(try d.varint());
            l.* = .{ .uri = uri, .id = try d.bytes(try d.varint()) };
        }
        return d;
    }

    fn deinit(d: *Decoder, gpa: Allocator) void {
        gpa.free(d.links);
    }

    fn varint(d: *Decoder) !u64 {
        var v: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            if (d.pos >= d.raw.len) return error.CorruptColdPage;
            const b = d.raw[d.pos];
            d.pos += 1;
            v |= @as(u64, b & 0x7f) << shift;
            if (b < 0x80) return v;
            if (shift >= 56) return error.CorruptColdPage;
            shift += 7;
        }
    }

    fn bytes(d: *Decoder, n: u64) ![]const u8 {
        if (n > d.raw.len - d.pos) return error.CorruptColdPage;
        const s = d.raw[d.pos..][0..@intCast(n)];
        d.pos += @intCast(n);
        return s;
    }

    fn list(d: *Decoder, gpa: Allocator, stride: usize, delta_fields: usize) ![]u32 {
        const n = try d.varint();
        if (n > d.raw.len) return error.CorruptColdPage;
        const out = try gpa.alloc(u32, @intCast(n * stride));
        errdefer gpa.free(out);
        var prev: u32 = 0;
        for (0..@intCast(n)) |i| {
            for (0..stride) |k| {
                const v = try d.varint();
                out[i * stride + k] = std.math.cast(u32, v) orelse return error.CorruptColdPage;
            }
            if (delta_fields > 0) {
                prev += out[i * stride];
                out[i * stride] = prev;
            }
        }
        return out;
    }

    fn line(d: *Decoder, gpa: Allocator) !Line {
        const width = std.math.cast(u32, try d.varint()) orelse return error.CorruptColdPage;
        const flags = (try d.bytes(1))[0];
        const text_bytes = try d.bytes(try d.varint());
        const runs = try d.list(gpa, 3, 0);
        errdefer gpa.free(runs);
        const wides = try d.list(gpa, 1, 1);
        errdefer gpa.free(wides);
        const graphs = try d.list(gpa, 2, 1);
        errdefer gpa.free(graphs);
        const bgs = try d.list(gpa, 4, 1);
        errdefer gpa.free(bgs);
        const links = try d.list(gpa, 3, 1);
        return .{ .width = width, .flags = flags, .text = text_bytes, .runs = runs, .wides = wides, .graphs = graphs, .bgs = bgs, .links = links };
    }
};

/// Rows a line takes at `cols`, wrapping wide characters as reflow does.
fn wrappedRows(l: Line, cols: u16) u32 {
    if (l.width == 0) return 1;
    var rows: u32 = 1;
    var x: u32 = 0;
    var cell: u32 = 0;
    var wi: usize = 0;
    while (cell < l.width) {
        const is_wide = wi < l.wides.len and l.wides[wi] == cell;
        if (is_wide and cols >= 2) {
            wi += 1;
            if (x + 2 > cols) {
                rows += 1;
                x = 0;
            }
            x += 2;
            cell += 2;
        } else {
            if (is_wide) wi += 1;
            if (x == cols) {
                rows += 1;
                x = 0;
            }
            x += 1;
            cell += if (is_wide) 2 else 1;
        }
    }
    return rows;
}

/// Writes one line's cells into new rows at the tail of `dst`.
fn emitLine(dst: *PageList, d: *const Decoder, l: Line) !void {
    const cols = dst.cols;
    var row = try dst.appendRow();
    {
        const r = row.row();
        r.mark = @enumFromInt(@as(u3, @truncate(l.flags & 7)));
        r.synthetic = l.flags & 8 != 0;
        r.dirty = true;
    }
    var x: u16 = 0;
    var it = std.unicode.Utf8View.initUnchecked(l.text).iterator();
    var cell: u32 = 0;
    var run: usize = 0;
    var run_left: u32 = if (l.runs.len > 0) l.runs[0] else 0;
    var wi: usize = 0;
    var gi: usize = 0;
    var bi: usize = 0;
    var li: usize = 0;

    while (cell < l.width) {
        const is_wide = wi < l.wides.len and l.wides[wi] == cell;
        if (is_wide) wi += 1;
        const span: u16 = if (is_wide and cols >= 2) 2 else 1;
        if (x + span > cols) {
            if (span == 2 and x < cols) row.cells()[x] = .{ .wide = .spacer_head };
            row.row().wrap = true;
            row = try dst.appendRow();
            const r = row.row();
            r.wrap_continuation = true;
            r.dirty = true;
            x = 0;
        }
        // Cell attributes from the run.
        while (run_left == 0 and run + 3 < l.runs.len) {
            run += 3;
            run_left = l.runs[run];
        }
        const sidx = if (l.runs.len > 0) l.runs[run + 1] else 0;
        const attrs: u8 = if (l.runs.len > 0) @intCast(l.runs[run + 2] & 0xff) else 0;
        const page = &row.node.page;
        const style_id: u16 = if (sidx == 0 or sidx > d.styles.len) 0 else page.internStyle(d.styles[sidx - 1], span) catch 0;
        var c: Cell = .{
            .style = style_id,
            .protected = attrs & 1 != 0,
            .semantic = @enumFromInt(@as(u2, @truncate(attrs >> 1))),
        };
        const base = it.nextCodepoint() orelse 0;
        c.content = base;
        if (bi < l.bgs.len and l.bgs[bi] == cell) {
            c.tag = @enumFromInt(@as(u2, @truncate(l.bgs[bi + 2])));
            c.content = @truncate(l.bgs[bi + 3]);
            bi += 4;
        }
        if (span == 2) c.wide = .wide;
        const cs = row.cells();
        cs[x] = c;
        if (c.style != 0) row.row().styled = true;
        if (gi < l.graphs.len and l.graphs[gi] == cell) {
            for (0..l.graphs[gi + 1]) |_| {
                const extra = it.nextCodepoint() orelse break;
                page.appendGrapheme(&cs[x], extra) catch {};
            }
            row.row().has_grapheme = true;
            gi += 2;
        }
        if (span == 2) {
            var t = c;
            t.wide = .spacer_tail;
            t.content = 0;
            t.tag = .codepoint;
            cs[x + 1] = t;
        }
        // Links.
        while (li < l.links.len and cell >= l.links[li] + l.links[li + 1]) li += 3;
        if (li < l.links.len and cell >= l.links[li] and cell < l.links[li] + l.links[li + 1]) {
            const idx = l.links[li + 2];
            if (idx < d.links.len) {
                // Only the head cell: print never links a spacer tail.
                if (page.internLink(d.links[idx])) |id| page.attachLink(&cs[x], id) else |_| {}
                row.row().has_hyperlink = true;
            }
        }
        x += span;
        const consumed: u32 = if (is_wide) 2 else 1;
        cell += consumed;
        run_left -|= consumed;
    }
}

test {
    _ = @import("cold_test.zig");
}
