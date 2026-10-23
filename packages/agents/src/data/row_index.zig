//! The row index (E13.F06.S01.T01): where every record of a CSV file
//! starts, in about 2.2 bytes a row.
//!
//! Rows come in blocks of 64: each block has its first offset as a u64
//! and every row's distance from it as a u16, or a u32 when the block
//! spans more than 64 KiB. `buildIndex` splits the file into chunks
//! scanned in parallel (scan_simd.zig) before their starting quote state
//! is known, then stitches the states in order; the first chunk's state
//! is known, so its rows are counted (`progress`) as they are found.
//! Files with backslash escapes, or whose quotes don't balance, are
//! indexed with the reader instead. `seekApprox` jumps to a fraction of
//! the file before any index exists.

const std = @import("std");
const csv = @import("csv.zig");
const scan = @import("scan_simd.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const block_rows = 64;

pub const RowIndex = struct {
    gpa: Allocator,
    anchors: std.ArrayList(u64) = .empty,
    /// Per block: index into `narrow` or (high bit set) `wide`.
    slots: std.ArrayList(u32) = .empty,
    narrow: std.ArrayList(u16) = .empty,
    wide: std.ArrayList(u32) = .empty,
    /// The block being filled.
    pending: [block_rows]u64 = undefined,
    pending_len: u8 = 0,
    done: bool = false,

    const wide_bit: u32 = 1 << 31;

    pub fn init(gpa: Allocator) RowIndex {
        return .{ .gpa = gpa };
    }

    pub fn deinit(ix: *RowIndex) void {
        ix.anchors.deinit(ix.gpa);
        ix.slots.deinit(ix.gpa);
        ix.narrow.deinit(ix.gpa);
        ix.wide.deinit(ix.gpa);
        ix.* = undefined;
    }

    pub fn reset(ix: *RowIndex) void {
        ix.anchors.clearRetainingCapacity();
        ix.slots.clearRetainingCapacity();
        ix.narrow.clearRetainingCapacity();
        ix.wide.clearRetainingCapacity();
        ix.pending_len = 0;
        ix.done = false;
    }

    /// Adds the next row's offset (offsets must increase).
    pub fn append(ix: *RowIndex, off: u64) Allocator.Error!void {
        ix.pending[ix.pending_len] = off;
        ix.pending_len += 1;
        if (ix.pending_len == block_rows) try ix.flush();
    }

    fn flush(ix: *RowIndex) Allocator.Error!void {
        const rows = ix.pending[0..ix.pending_len];
        const base = rows[0];
        const span = rows[rows.len - 1] - base;
        try ix.anchors.append(ix.gpa, base);
        if (span <= std.math.maxInt(u16)) {
            try ix.slots.append(ix.gpa, @intCast(ix.narrow.items.len));
            for (rows) |r| try ix.narrow.append(ix.gpa, @intCast(r - base));
        } else {
            if (span > std.math.maxInt(u32)) return error.OutOfMemory;
            try ix.slots.append(ix.gpa, @as(u32, @intCast(ix.wide.items.len)) | wide_bit);
            for (rows) |r| try ix.wide.append(ix.gpa, @intCast(r - base));
        }
        ix.pending_len = 0;
    }

    /// Marks the index complete (the last partial block is kept as is).
    pub fn finish(ix: *RowIndex) Allocator.Error!void {
        if (ix.pending_len > 0) try ix.flush();
        ix.done = true;
    }

    pub fn count(ix: *const RowIndex) u64 {
        return if (ix.done) ix.storedRows() else ix.anchors.items.len * block_rows + ix.pending_len;
    }

    fn storedRows(ix: *const RowIndex) u64 {
        return ix.narrow.items.len + ix.wide.items.len;
    }

    pub fn complete(ix: *const RowIndex) bool {
        return ix.done;
    }

    /// The start offset of `row` (< `count()`).
    pub fn offset(ix: *const RowIndex, row: u64) u64 {
        const blk: usize = @intCast(row / block_rows);
        const k: usize = @intCast(row % block_rows);
        if (blk >= ix.anchors.items.len) return ix.pending[k];
        const slot = ix.slots.items[blk];
        const rel: u64 = if (slot & wide_bit != 0) ix.wide.items[(slot & ~wide_bit) + k] else ix.narrow.items[slot + k];
        return ix.anchors.items[blk] + rel;
    }

    /// Bytes held (for the memory budget).
    pub fn bytesUsed(ix: *const RowIndex) usize {
        return ix.anchors.items.len * 8 + ix.slots.items.len * 4 + ix.narrow.items.len * 2 + ix.wide.items.len * 4;
    }

    pub fn sink(ix: *RowIndex) scan.Sink(*RowIndex) {
        return .{ .ctx = ix, .add = addSink };
    }

    fn addSink(ix: *RowIndex, off: u64) error{OutOfMemory}!void {
        return ix.append(off);
    }
};

pub const min_chunk = 4 << 20;

/// Indexes every record start of `bytes` into `out` (which must be
/// empty). `progress` counts rows found so far for sure; `cancel` stops
/// the work (`error.Canceled`).
pub fn buildIndex(io: Io, bytes: []const u8, d: csv.Dialect, out: *RowIndex, progress: *std.atomic.Value(u64), cancel: *const std.atomic.Value(bool)) !void {
    return buildIndexChunks(io, bytes, d, out, progress, cancel, null);
}

/// `buildIndex` with a chosen chunk count (tests put chunk boundaries
/// everywhere).
pub fn buildIndexChunks(io: Io, bytes: []const u8, d: csv.Dialect, out: *RowIndex, progress: *std.atomic.Value(u64), cancel: *const std.atomic.Value(bool), chunks_opt: ?usize) !void {
    out.reset();
    if (bytes.len > 0 and !csv.isTerminator(bytes[0])) try out.append(0);
    if (d.escape == .backslash) return indexWithReader(bytes, d, out, progress, cancel);

    const cpus = std.Thread.getCpuCount() catch 1;
    const n = chunks_opt orelse @max(1, @min(cpus, bytes.len / min_chunk));
    if (n <= 1) {
        const odd = try scanCounted(bytes, 0, bytes.len, d.quote, out, null, progress, cancel);
        if (odd) return indexWithReader(bytes, d, out, progress, cancel);
        progress.store(out.count(), .release);
        return out.finish();
    }

    const gpa = out.gpa;
    const parts = try gpa.alloc(Part, n);
    defer gpa.free(parts);
    for (parts, 0..) |*p, i| p.* = .{
        .from = bytes.len * i / n,
        .to = bytes.len * (i + 1) / n,
        .s0 = .init(gpa),
        .s1 = .init(gpa),
    };
    defer for (parts) |*p| {
        p.s0.deinit();
        p.s1.deinit();
    };
    var group: Io.Group = .init;
    for (parts, 0..) |*p, i| group.async(io, Part.run, .{ p, bytes, d.quote, if (i == 0) progress else null, cancel });
    try group.await(io);
    for (parts) |p| if (p.err) |e| return e;

    // Stitch: each chunk's state is the previous one's end state.
    var inq = false;
    for (parts) |*p| {
        const rows = if (inq) &p.s1 else &p.s0;
        var r: u64 = 0;
        const c = rows.count();
        while (r < c) : (r += 1) try out.append(rows.offset(r));
        inq = inq != p.odd;
        progress.store(out.count(), .release);
    }
    if (inq) return indexWithReader(bytes, d, out, progress, cancel);
    return out.finish();
}

const Part = struct {
    from: usize,
    to: usize,
    s0: RowIndex,
    s1: RowIndex,
    odd: bool = false,
    err: ?anyerror = null,

    fn run(p: *Part, bytes: []const u8, quote: ?u8, progress: ?*std.atomic.Value(u64), cancel: *const std.atomic.Value(bool)) void {
        p.odd = scanCounted(bytes, p.from, p.to, quote, &p.s0, if (progress == null) &p.s1 else null, progress, cancel) catch |e| {
            p.err = e;
            return;
        };
    }
};

/// Scans in 1 MiB steps, checking `cancel` and publishing progress for
/// `s0` when `progress` is given.
fn scanCounted(bytes: []const u8, from: usize, to: usize, quote: ?u8, s0: *RowIndex, s1: ?*RowIndex, progress: ?*std.atomic.Value(u64), cancel: *const std.atomic.Value(bool)) !bool {
    const step = 1 << 20;
    var odd = false;
    var p = from;
    while (p < to) {
        if (cancel.load(.acquire)) return error.Canceled;
        const end = @min(to, p + step);
        const a = s0.sink();
        const b = if (s1) |x| x.sink() else null;
        // Inside quotes at this step's start: the sinks swap roles.
        const part_odd = if (odd)
            try scan.scanSimd(*RowIndex, bytes, p, end, quote, b, a)
        else
            try scan.scanSimd(*RowIndex, bytes, p, end, quote, a, b);
        odd = odd != part_odd;
        if (progress) |pr| pr.store(s0.count(), .release);
        p = end;
    }
    return odd;
}

/// The reader's record starts (exact for any dialect).
fn indexWithReader(bytes: []const u8, d: csv.Dialect, out: *RowIndex, progress: *std.atomic.Value(u64), cancel: *const std.atomic.Value(bool)) !void {
    out.reset();
    var r: csv.CsvReader = .init(bytes, d);
    var fields: std.ArrayList(csv.Field) = .empty;
    defer fields.deinit(out.gpa);
    var n: u64 = 0;
    while (try r.nextRecord(&fields, out.gpa)) |at| {
        try out.append(at);
        n += 1;
        if (n % 65536 == 0) {
            if (cancel.load(.acquire)) return error.Canceled;
            progress.store(n, .release);
        }
    }
    progress.store(n, .release);
    return out.finish();
}

/// Starts of the records in `bytes[0..limit]` (for the first screen,
/// before the full index), into `out`.
pub fn indexPrefix(bytes: []const u8, d: csv.Dialect, limit: usize, out: *RowIndex) !void {
    out.reset();
    var r: csv.CsvReader = .init(bytes, d);
    var fields: std.ArrayList(csv.Field) = .empty;
    defer fields.deinit(out.gpa);
    while (r.pos < limit) {
        const at = (try r.nextRecord(&fields, out.gpa)) orelse break;
        try out.append(at);
    }
    try out.finish();
}

pub const Seek = struct { offset: u64, approx_row: u64 };

/// A record start near `fraction` of the file, found without an index:
/// from `fraction × size`, scan back up to 64 KiB, pick the quote state
/// at the window's start under which the quotes there look like CSV
/// (opening quotes at field starts, closing ones before a delimiter or a
/// line end), and move to the next unquoted line end. The row number is
/// estimated from the first 64 KiB's average record length.
pub fn seekApprox(bytes: []const u8, d: csv.Dialect, fraction: f64) Seek {
    if (bytes.len == 0) return .{ .offset = 0, .approx_row = 0 };
    const f = std.math.clamp(fraction, 0, 1);
    const target: usize = @intFromFloat(@as(f64, @floatFromInt(bytes.len)) * f);
    if (target == 0) return .{ .offset = 0, .approx_row = 0 };
    const off = resync(bytes, d, @min(target, bytes.len - 1));
    return .{ .offset = off, .approx_row = estimateRow(bytes, d, off) };
}

fn estimateRow(bytes: []const u8, d: csv.Dialect, off: u64) u64 {
    const sample = bytes[0..@min(bytes.len, 64 << 10)];
    var n: u64 = 1;
    _ = scan.scanScalar(*u64, bytes, 0, sample.len, d.quote, .{ .ctx = &n, .add = countStart }, null) catch unreachable;
    const avg = @max(1, sample.len / n);
    return off / avg;
}

fn countStart(n: *u64, _: u64) error{OutOfMemory}!void {
    n.* += 1;
}

/// The first record start at or after `pos`.
pub fn resync(bytes: []const u8, d: csv.Dialect, pos: usize) u64 {
    const q = d.quote orelse return nextStart(bytes, pos, false, null);
    const lo = pos -| (64 << 10);
    // Score both starting states over the window.
    var bad = [2]u32{ 0, 0 };
    var state = [2]bool{ false, true };
    var i = lo;
    if (lo == 0) bad[1] = std.math.maxInt(u32) / 2;
    while (i < pos) : (i += 1) {
        if (bytes[i] != q) continue;
        const before: u8 = if (i == 0) '\n' else bytes[i - 1];
        const after: u8 = if (i + 1 < bytes.len) bytes[i + 1] else '\n';
        for (&state, &bad) |*s, *b| {
            if (!s.*) {
                // Opening: should follow a delimiter, a line end or a space.
                if (!(before == d.delimiter or csv.isTerminator(before) or before == ' ')) b.* += 1;
            } else if (after != q and before != q) {
                // Closing: should precede a delimiter, a line end or a space.
                if (!(after == d.delimiter or csv.isTerminator(after) or after == ' ')) b.* += 1;
            }
            s.* = !s.*;
        }
    }
    const inq = if (bad[0] <= bad[1]) state[0] else state[1];
    return nextStart(bytes, pos, inq, q);
}

fn nextStart(bytes: []const u8, pos: usize, in_quote: bool, quote: ?u8) u64 {
    if (pos == 0 and bytes.len > 0 and !csv.isTerminator(bytes[0])) return 0;
    var inq = in_quote;
    // `pos` itself starts a record when the byte before ends a line.
    var i = pos -| 1;
    if (pos == 0) i = 0;
    while (i < bytes.len) : (i += 1) {
        const c = bytes[i];
        if (quote != null and c == quote.?) {
            if (i >= pos) inq = !inq;
            continue;
        }
        if (inq) continue;
        const end = c == '\n' or (c == '\r' and !(i + 1 < bytes.len and bytes[i + 1] == '\n'));
        if (end and i + 1 < bytes.len and !csv.isTerminator(bytes[i + 1]) and i + 1 >= pos) return i + 1;
    }
    return bytes.len;
}
