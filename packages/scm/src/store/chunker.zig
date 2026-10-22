//! FastCDC content-defined chunking (Xia et al., USENIX ATC '16) for large
//! blobs, plus streaming blob writes and reads over plain or chunked blobs.
//!
//! A gear rolling hash picks cut points from content alone, so inserting or
//! deleting bytes moves only the boundaries next to the edit: the other
//! chunks keep their IDs and dedupe. Each chunk is stored as an ordinary
//! `.blob`, and the file as a `.chunked_blob` listing them.

const std = @import("std");
const id_mod = @import("id.zig");
const object = @import("object.zig");
const enc = @import("encode.zig");
const store_mod = @import("store.zig");
const ObjectId = id_mod.ObjectId;
const Store = store_mod.Store;
const Allocator = std.mem.Allocator;

/// Chunk size bounds and the size from which blobs are chunked.
pub const ChunkParams = struct {
    min: u32 = 512 << 10,
    avg: u32 = 1 << 20,
    max: u32 = 4 << 20,
    /// Blobs at least this large are chunked.
    threshold: u64 = 4 << 20,
};

/// 256 random u64s from SplitMix64 with a fixed seed. Changing the seed
/// or generator changes every chunk boundary, and so every chunk ID.
const gear: [256]u64 = blk: {
    @setEvalBranchQuota(10_000);
    var t: [256]u64 = undefined;
    var s: u64 = 0x7a6775726f636463; // "zgurocdc"
    for (&t) |*g| {
        s +%= 0x9e3779b97f4a7c15;
        var z = s;
        z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
        z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
        g.* = z ^ (z >> 31);
    }
    break :blk t;
};

/// A mask of the `bits` highest bits; the gear hash mixes its newest
/// bytes into the high bits last, so those decide cut points.
fn topMask(bits: u6) u64 {
    return ~@as(u64, 0) << @intCast(64 - @as(u7, bits));
}

/// Streaming cut-point finder. Feed consecutive data with `next`.
pub const Chunker = struct {
    p: ChunkParams,
    /// Bytes in the current (unfinished) chunk.
    len: u64 = 0,
    h: u64 = 0,
    mask_s: u64,
    mask_l: u64,

    pub fn init(p: ChunkParams) Chunker {
        std.debug.assert(p.min >= 64 and p.min <= p.avg and p.avg <= p.max);
        const bits: u6 = @intCast(std.math.log2_int(u32, p.avg));
        // Normalized chunking, level 2: harder to cut before `avg`,
        // easier after, which narrows the size distribution.
        return .{ .p = p, .mask_s = topMask(bits + 2), .mask_l = topMask(bits - 2) };
    }

    /// The length of the first chunk ending inside `data` (counted from
    /// the start of `data`), or null when all of `data` belongs to the
    /// current chunk and more input is needed. After a cut, call again with
    /// the bytes after it.
    pub fn next(c: *Chunker, data: []const u8) ?usize {
        var i: usize = 0;
        // No cut can happen before `min`, and only the last 64 bytes
        // affect the hash, so skip straight to `min - 64`.
        const skip_to: u64 = c.p.min - 64;
        if (c.len < skip_to) {
            const n: usize = @intCast(@min(data.len, skip_to - c.len));
            c.len += n;
            i = n;
        }
        var h = c.h;
        // Each phase runs to a fixed chunk length with one test per byte.
        const phases = [_]struct { until: u64, mask: ?u64 }{
            .{ .until = c.p.min, .mask = null },
            .{ .until = c.p.avg, .mask = c.mask_s },
            .{ .until = c.p.max, .mask = c.mask_l },
        };
        for (phases) |ph| {
            if (c.len >= ph.until) continue;
            const room: usize = @intCast(@min(data.len - i, ph.until - c.len));
            const stop = i + room;
            if (ph.mask) |mask| {
                while (i < stop) {
                    h = (h << 1) +% gear[data[i]];
                    i += 1;
                    if (h & mask == 0) {
                        c.h = 0;
                        c.len = 0;
                        return i;
                    }
                }
            } else {
                while (i < stop) : (i += 1) h = (h << 1) +% gear[data[i]];
            }
            c.len += room;
            if (i == data.len and c.len < c.p.max) {
                c.h = h;
                return null;
            }
        }
        // Forced cut at `max`.
        c.h = 0;
        c.len = 0;
        return i;
    }

    /// Ends the input: the current chunk (possibly empty) is the last.
    pub fn reset(c: *Chunker) void {
        c.h = 0;
        c.len = 0;
    }
};

/// Writes everything from `r` as a blob and returns its ID: a plain blob
/// below `p.threshold`, otherwise chunks plus a chunked blob. Memory stays
/// around `threshold + max` however large the input is. The objects are
/// published in one segment.
pub fn writeBlobStreaming(s: *Store, r: *std.Io.Reader, p: ChunkParams) !ObjectId {
    const gpa = s.gpa;
    const cap: usize = @intCast(p.threshold + p.max);
    const buf = try gpa.alloc(u8, cap);
    defer gpa.free(buf);
    var end: usize = 0;
    var eof = false;
    while (end < p.threshold and !eof) {
        const n = try r.readSliceShort(buf[end..@intCast(p.threshold)]);
        end += n;
        if (n == 0) eof = true;
    }
    var b = s.batch();
    errdefer b.abort();
    if (eof and end < p.threshold) {
        const id = try b.put(.blob, buf[0..end]);
        try b.commit();
        return id;
    }

    var chunks: std.ArrayList(object.Chunk) = .empty;
    defer chunks.deinit(gpa);
    var total: u64 = 0;
    var ch: Chunker = .init(p);
    var start: usize = 0;
    var scanned: usize = 0;
    while (true) {
        while (ch.next(buf[scanned..end])) |cut| {
            const chunk = buf[start .. scanned + cut];
            try chunks.append(gpa, .{ .id = try b.put(.blob, chunk), .size = @intCast(chunk.len) });
            total += chunk.len;
            start = scanned + cut;
            scanned = start;
        }
        scanned = end;
        if (eof) break;
        // Keep the unfinished chunk (< max) and refill behind it.
        std.mem.copyForwards(u8, buf, buf[start..end]);
        end -= start;
        scanned -= start;
        start = 0;
        const n = try r.readSliceShort(buf[end..]);
        if (n == 0) eof = true;
        end += n;
    }
    if (end > start) {
        const chunk = buf[start..end];
        try chunks.append(gpa, .{ .id = try b.put(.blob, chunk), .size = @intCast(chunk.len) });
        total += chunk.len;
    }
    const cb: object.ChunkedBlob = .{ .total_size = total, .chunks = chunks.items };
    const bytes = try enc.encodeAlloc(gpa, object.ChunkedBlob, cb);
    defer gpa.free(bytes);
    const id = try b.put(.chunked_blob, bytes);
    try b.commit();
    return id;
}

/// An `std.Io.Reader` over the bytes of a plain or chunked blob, holding
/// at most one chunk at a time.
pub const BlobReader = struct {
    store: *Store,
    arena: std.heap.ArenaAllocator,
    /// The chunk list, or one entry for a plain blob.
    chunks: []const object.Chunk,
    next_chunk: usize = 0,
    current: ?store_mod.ObjectRef = null,
    pos: usize = 0,
    /// Total length in bytes.
    size: u64,
    interface: std.Io.Reader,

    /// Releases the current chunk.
    pub fn deinit(br: *BlobReader) void {
        if (br.current) |c| c.release();
        br.arena.deinit();
        br.* = undefined;
    }

    fn advance(br: *BlobReader) !bool {
        if (br.current) |c| c.release();
        br.current = null;
        br.pos = 0;
        if (br.next_chunk >= br.chunks.len) return false;
        const want = br.chunks[br.next_chunk];
        br.next_chunk += 1;
        const ref = try br.store.read(want.id);
        if (ref.kind != .blob or ref.bytes.len != want.size) {
            ref.release();
            return error.CorruptObject;
        }
        br.current = ref;
        return true;
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const br: *BlobReader = @fieldParentPtr("interface", r);
        while (br.current == null or br.pos == br.current.?.bytes.len) {
            const more = br.advance() catch return error.ReadFailed;
            if (!more) return error.EndOfStream;
        }
        const rest = limit.sliceConst(br.current.?.bytes[br.pos..]);
        const n = try w.write(rest);
        br.pos += n;
        return n;
    }
};

/// Opens a reader over blob `id` (plain or chunked) using `buf` as its
/// buffer. Call `deinit` when done.
pub fn blobReader(s: *Store, id: ObjectId, buf: []u8) !BlobReader {
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    errdefer arena.deinit();
    const ref = try s.read(id);
    defer ref.release();
    const chunks: []const object.Chunk, const size: u64 = switch (ref.kind) {
        .blob => .{ try arena.allocator().dupe(object.Chunk, &.{.{ .id = id, .size = @intCast(ref.bytes.len) }}), ref.bytes.len },
        .chunked_blob => blk: {
            const copy = try arena.allocator().dupe(u8, ref.bytes);
            const cb = try enc.decode(object.ChunkedBlob, arena.allocator(), copy);
            break :blk .{ cb.chunks, cb.total_size };
        },
        else => return error.NotABlob,
    };
    return .{
        .store = s,
        .arena = arena,
        .chunks = chunks,
        .size = size,
        .interface = .{ .vtable = &.{ .stream = BlobReader.stream }, .buffer = buf, .seek = 0, .end = 0 },
    };
}

test "chunker: respects min/max" {
    const t = std.testing;
    const p: ChunkParams = .{ .min = 4096, .avg = 16384, .max = 65536, .threshold = 65536 };
    var prng: std.Random.DefaultPrng = .init(1);
    const data = try t.allocator.alloc(u8, 4 << 20);
    defer t.allocator.free(data);
    prng.random().bytes(data);
    var c: Chunker = .init(p);
    var rest: []const u8 = data;
    var n: usize = 0;
    var total: usize = 0;
    while (c.next(rest)) |cut| : (n += 1) {
        try t.expect(cut >= p.min and cut <= p.max);
        total += cut;
        rest = rest[cut..];
    }
    try t.expect(rest.len <= p.max);
    // The average lands near `avg`.
    const avg = total / n;
    try t.expect(avg > p.avg / 2 and avg < p.avg * 2);
    // Zeros never match the mask: every chunk is forced at max.
    const zeros = try t.allocator.alloc(u8, 3 * p.max);
    defer t.allocator.free(zeros);
    @memset(zeros, 0);
    c.reset();
    try t.expectEqual(@as(?usize, p.max), c.next(zeros));
}

fn cutPoints(gpa: Allocator, data: []const u8, p: ChunkParams, feed: usize) ![]usize {
    var cuts: std.ArrayList(usize) = .empty;
    var c: Chunker = .init(p);
    var off: usize = 0;
    var chunk_start: usize = 0;
    // Feed in pieces of `feed` bytes to exercise the streaming state.
    while (off < data.len) {
        const piece = data[off..@min(data.len, off + feed)];
        var consumed: usize = 0;
        while (c.next(piece[consumed..])) |cut| {
            consumed += cut;
            chunk_start = off + consumed;
            try cuts.append(gpa, chunk_start);
        }
        off += piece.len;
    }
    return cuts.toOwnedSlice(gpa);
}

test "chunker: boundaries are shift-resistant" {
    const t = std.testing;
    const p: ChunkParams = .{ .min = 2048, .avg = 8192, .max = 32768, .threshold = 32768 };
    var prng: std.Random.DefaultPrng = .init(9);
    const data = try t.allocator.alloc(u8, 2 << 20);
    defer t.allocator.free(data);
    prng.random().bytes(data);
    const a = try cutPoints(t.allocator, data, p, 1 << 30);
    defer t.allocator.free(a);
    // Feeding in odd-sized pieces finds the same cuts.
    const a2 = try cutPoints(t.allocator, data, p, 1000);
    defer t.allocator.free(a2);
    try t.expectEqualSlices(usize, a, a2);
    for ([_]usize{ 0, 12345, 1 << 20, data.len - 100 }) |k| {
        // Insert one byte at k.
        const edited = try std.mem.concat(t.allocator, u8, &.{ data[0..k], "X", data[k..] });
        defer t.allocator.free(edited);
        const b = try cutPoints(t.allocator, edited, p, 1 << 30);
        defer t.allocator.free(b);
        // Chunks are (start, end) pairs; count those of `b` not in `a`
        // after shifting positions past the edit back by one.
        var set: std.AutoHashMapUnmanaged([2]usize, void) = .empty;
        defer set.deinit(t.allocator);
        var prev: usize = 0;
        for (a) |cut| {
            try set.put(t.allocator, .{ prev, cut }, {});
            prev = cut;
        }
        var changed: usize = 0;
        prev = 0;
        for (b) |cut| {
            const s0 = if (prev > k) prev - 1 else prev;
            const s1 = if (cut > k) cut - 1 else cut;
            if (!set.contains(.{ s0, s1 }) or (prev <= k and cut > k)) changed += 1;
            prev = cut;
        }
        try t.expect(changed <= 2);
    }
}
