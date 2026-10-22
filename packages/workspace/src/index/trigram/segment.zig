//! Trigram segments: an immutable, checksummed file of documents and their
//! trigram posting lists, built in memory by `Builder` and read in place by
//! `Segment`. std only, so E09's history index can reuse it.
//!
//! Layout (little-endian):
//!   header   magic "ZGTR", version u32, doc_count u32, trigram_count u32,
//!            postings_len u64                                   (24 bytes)
//!   docs     [doc_count] { path_hash u64, hint u32 }            (12 bytes each)
//!   trigrams [trigram_count] { trigram u32, offset u64, count u32 }  (16 each)
//!   postings delta-coded doc ids, unsigned LEB128
//!   footer   xxhash3 u64 of everything before it

const std = @import("std");
const Allocator = std.mem.Allocator;
const varint = @import("varint.zig");

/// A trigram: three bytes, ASCII-lowercased, as `b0 << 16 | b1 << 8 | b2`.
pub const Trigram = u32;

/// File magic.
pub const magic = "ZGTR";
/// Format version.
pub const version: u32 = 1;
const header_len = 24;
const doc_len = 12;
const tri_len = 16;
const footer_len = 8;

/// ASCII lowercase of one byte.
pub inline fn fold(b: u8) u8 {
    return std.ascii.toLower(b);
}

/// The trigram at `bytes[i..i+3]`, folded.
pub inline fn trigramAt(bytes: []const u8, i: usize) Trigram {
    return @as(u32, fold(bytes[i])) << 16 | @as(u32, fold(bytes[i + 1])) << 8 | fold(bytes[i + 2]);
}

/// Extracts the distinct trigrams of a document using a 2^24-bit set
/// (2 MiB) that is cleared through a touched list, so it is reused per file.
pub const Extractor = struct {
    bits: []u64,
    touched: std.ArrayList(Trigram) = .empty,

    /// Allocates the bit set.
    pub fn init(gpa: Allocator) !Extractor {
        const bits = try gpa.alloc(u64, (1 << 24) / 64);
        @memset(bits, 0);
        return .{ .bits = bits };
    }

    /// Frees the bit set.
    pub fn deinit(e: *Extractor, gpa: Allocator) void {
        gpa.free(e.bits);
        e.touched.deinit(gpa);
    }

    /// The distinct trigrams of `bytes`, in first-seen order. Valid until
    /// the next call.
    pub fn extract(e: *Extractor, gpa: Allocator, bytes: []const u8) ![]const Trigram {
        for (e.touched.items) |t| e.bits[t >> 6] = 0;
        e.touched.clearRetainingCapacity();
        if (bytes.len < 3) return &.{};
        var t: u32 = @as(u32, fold(bytes[0])) << 8 | fold(bytes[1]);
        for (bytes[2..]) |b| {
            t = (t << 8 | fold(b)) & 0xFF_FFFF;
            const w = &e.bits[t >> 6];
            const m = @as(u64, 1) << @as(u6, @truncate(t));
            if (w.* & m == 0) {
                w.* |= m;
                try e.touched.append(gpa, t);
            }
        }
        return e.touched.items;
    }
};

/// One document of a segment.
pub const Doc = struct {
    /// Hash of the document's path (the stable key across sessions).
    path_hash: u64,
    /// The owner's id hint (for zg_workspace, `FileId.index`).
    hint: u32,
};

/// Builds a segment in memory. Postings are collected as (trigram, doc)
/// pairs and grouped at `finish` by a stable two-pass radix sort, which is
/// several times faster than a hash map of lists.
pub const Builder = struct {
    gpa: Allocator,
    docs: std.ArrayList(Doc) = .empty,
    /// `trigram << 32 | doc`, in insertion order until `finish`.
    pairs: std.ArrayList(u64) = .empty,
    /// Bytes of text added (for flush thresholds).
    text_bytes: u64 = 0,

    /// An empty builder.
    pub fn init(gpa: Allocator) Builder {
        return .{ .gpa = gpa };
    }

    /// Frees the builder.
    pub fn deinit(b: *Builder) void {
        b.pairs.deinit(b.gpa);
        b.docs.deinit(b.gpa);
    }

    /// Adds a document with its distinct trigrams; returns its local id.
    pub fn add(b: *Builder, doc: Doc, trigrams: []const Trigram, text_len: u64) !u32 {
        const id: u32 = @intCast(b.docs.items.len);
        try b.docs.append(b.gpa, doc);
        try b.pairs.ensureUnusedCapacity(b.gpa, trigrams.len);
        for (trigrams) |t| b.pairs.appendAssumeCapacity(@as(u64, t) << 32 | id);
        b.text_bytes += text_len;
        return id;
    }

    /// Adds a document without postings (for `merge`, which appends
    /// postings itself with `addPosting`).
    pub fn addDoc(b: *Builder, doc: Doc) !u32 {
        const id: u32 = @intCast(b.docs.items.len);
        try b.docs.append(b.gpa, doc);
        return id;
    }

    /// Appends `doc` to the postings of `t`. For each trigram, docs must
    /// arrive in ascending order.
    pub fn addPosting(b: *Builder, t: Trigram, doc: u32) !void {
        try b.pairs.append(b.gpa, @as(u64, t) << 32 | doc);
    }

    /// Number of documents added.
    pub fn docCount(b: *const Builder) u32 {
        return @intCast(b.docs.items.len);
    }

    /// Serializes the segment. Caller owns the bytes.
    pub fn finish(b: *Builder, gpa: Allocator) ![]u8 {
        const n = b.pairs.items.len;
        // Stable LSD radix sort by trigram (12 low bits, then 12 high
        // bits); insertion order, so ascending docs, survives.
        const keys_buf = try gpa.alloc(u64, n);
        defer gpa.free(keys_buf);
        const counts = try gpa.alloc(u32, 4097);
        defer gpa.free(counts);
        var src = b.pairs.items;
        var dst = keys_buf;
        inline for (.{ 32, 44 }) |shift| {
            @memset(counts, 0);
            for (src) |k| counts[@as(usize, @intCast((k >> shift) & 0xFFF)) + 1] += 1;
            for (1..4097) |d| counts[d] += counts[d - 1];
            for (src) |k| {
                const d: usize = @intCast((k >> shift) & 0xFFF);
                dst[counts[d]] = k;
                counts[d] += 1;
            }
            std.mem.swap([]u64, &src, &dst);
        }
        const sorted = src; // two passes: back in `pairs`

        var post: std.ArrayList(u8) = .empty;
        defer post.deinit(gpa);
        try post.ensureTotalCapacity(gpa, n + n / 4);
        var table: std.ArrayList(u8) = .empty;
        defer table.deinit(gpa);
        var keys: usize = 0;
        var i: usize = 0;
        while (i < n) {
            const t: Trigram = @intCast(sorted[i] >> 32);
            var j = i;
            var prev: u32 = 0;
            const off = post.items.len;
            while (j < n and sorted[j] >> 32 == t) : (j += 1) {
                const d: u32 = @truncate(sorted[j]);
                std.debug.assert(j == i or d > prev);
                try varint.put(&post, gpa, d - prev);
                prev = d;
            }
            var rec: [tri_len]u8 = undefined;
            std.mem.writeInt(u32, rec[0..4], t, .little);
            std.mem.writeInt(u64, rec[4..12], off, .little);
            std.mem.writeInt(u32, rec[12..16], @intCast(j - i), .little);
            try table.appendSlice(gpa, &rec);
            keys += 1;
            i = j;
        }

        const total = header_len + b.docs.items.len * doc_len + table.items.len + post.items.len + footer_len;
        const out = try gpa.alloc(u8, total);
        errdefer gpa.free(out);
        @memcpy(out[0..4], magic);
        std.mem.writeInt(u32, out[4..8], version, .little);
        std.mem.writeInt(u32, out[8..12], @intCast(b.docs.items.len), .little);
        std.mem.writeInt(u32, out[12..16], @intCast(keys), .little);
        std.mem.writeInt(u64, out[16..24], post.items.len, .little);
        var p: usize = header_len;
        for (b.docs.items) |d| {
            std.mem.writeInt(u64, out[p..][0..8], d.path_hash, .little);
            std.mem.writeInt(u32, out[p + 8 ..][0..4], d.hint, .little);
            p += doc_len;
        }
        @memcpy(out[p..][0..table.items.len], table.items);
        p += table.items.len;
        @memcpy(out[p..][0..post.items.len], post.items);
        p += post.items.len;
        std.mem.writeInt(u64, out[p..][0..8], std.hash.XxHash3.hash(0, out[0..p]), .little);
        return out;
    }
};

/// Errors of `Segment.parse`.
pub const ParseError = error{ BadMagic, UnsupportedVersion, Truncated, ChecksumMismatch };

/// A read-only view of serialized segment bytes (for example a memory map).
pub const Segment = struct {
    bytes: []const u8,
    doc_count: u32,
    trigram_count: u32,
    docs_off: usize,
    table_off: usize,
    post_off: usize,
    post_len: usize,

    /// Validates `bytes` (including the checksum) and returns a view.
    pub fn parse(bytes: []const u8) ParseError!Segment {
        if (bytes.len < header_len + footer_len) return error.Truncated;
        if (!std.mem.eql(u8, bytes[0..4], magic)) return error.BadMagic;
        if (std.mem.readInt(u32, bytes[4..8], .little) != version) return error.UnsupportedVersion;
        const dc = std.mem.readInt(u32, bytes[8..12], .little);
        const tc = std.mem.readInt(u32, bytes[12..16], .little);
        const pl = std.mem.readInt(u64, bytes[16..24], .little);
        const docs_off: usize = header_len;
        const table_off = docs_off + @as(usize, dc) * doc_len;
        const post_off = table_off + @as(usize, tc) * tri_len;
        const end = std.math.add(usize, post_off, std.math.cast(usize, pl) orelse return error.Truncated) catch return error.Truncated;
        if (end + footer_len != bytes.len) return error.Truncated;
        const want = std.mem.readInt(u64, bytes[end..][0..8], .little);
        if (std.hash.XxHash3.hash(0, bytes[0..end]) != want) return error.ChecksumMismatch;
        return .{ .bytes = bytes, .doc_count = dc, .trigram_count = tc, .docs_off = docs_off, .table_off = table_off, .post_off = post_off, .post_len = @intCast(pl) };
    }

    /// Document `i`.
    pub fn doc(s: *const Segment, i: u32) Doc {
        const p = s.docs_off + @as(usize, i) * doc_len;
        return .{
            .path_hash = std.mem.readInt(u64, s.bytes[p..][0..8], .little),
            .hint = std.mem.readInt(u32, s.bytes[p + 8 ..][0..4], .little),
        };
    }

    /// Entry `i` of the trigram table.
    pub fn entry(s: *const Segment, i: u32) struct { trigram: Trigram, offset: u64, count: u32 } {
        const p = s.table_off + @as(usize, i) * tri_len;
        return .{
            .trigram = std.mem.readInt(u32, s.bytes[p..][0..4], .little),
            .offset = std.mem.readInt(u64, s.bytes[p + 4 ..][0..8], .little),
            .count = std.mem.readInt(u32, s.bytes[p + 12 ..][0..4], .little),
        };
    }

    fn findIndex(s: *const Segment, t: Trigram) ?u32 {
        var lo: u32 = 0;
        var hi: u32 = s.trigram_count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const v = std.mem.readInt(u32, s.bytes[s.table_off + @as(usize, mid) * tri_len ..][0..4], .little);
            if (v < t) lo = mid + 1 else hi = mid;
        }
        if (lo < s.trigram_count and std.mem.readInt(u32, s.bytes[s.table_off + @as(usize, lo) * tri_len ..][0..4], .little) == t) return lo;
        return null;
    }

    /// Posting count of `t` (0 when absent).
    pub fn count(s: *const Segment, t: Trigram) u32 {
        const i = s.findIndex(t) orelse return 0;
        return s.entry(i).count;
    }

    /// Appends the local doc ids of `t`, each plus `base`.
    pub fn postings(s: *const Segment, t: Trigram, base: u32, out: *std.ArrayList(u32), gpa: Allocator) !void {
        const i = s.findIndex(t) orelse return;
        return s.postingsAt(i, base, out, gpa);
    }

    /// Appends the doc ids of table entry `i`, each plus `base`.
    pub fn postingsAt(s: *const Segment, i: u32, base: u32, out: *std.ArrayList(u32), gpa: Allocator) !void {
        const e = s.entry(i);
        const start = s.post_off + @as(usize, @intCast(e.offset));
        if (start > s.post_off + s.post_len) return error.Truncated;
        try varint.getDeltas(s.bytes[start .. s.post_off + s.post_len], e.count, base, out, gpa);
    }
};

test "segment: builder + parse roundtrip" {
    const gpa = std.testing.allocator;
    var ex: Extractor = try .init(gpa);
    defer ex.deinit(gpa);
    var b: Builder = .init(gpa);
    defer b.deinit();
    const texts = [_][]const u8{ "Hello World", "hello there", "world peace" };
    for (texts, 0..) |t, i| _ = try b.add(.{ .path_hash = i * 7, .hint = @intCast(i) }, try ex.extract(gpa, t), t.len);
    const bytes = try b.finish(gpa);
    defer gpa.free(bytes);
    const s = try Segment.parse(bytes);
    try std.testing.expectEqual(@as(u32, 3), s.doc_count);
    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(gpa);
    try s.postings(trigramAt("hel", 0), 0, &out, gpa);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1 }, out.items);
    out.clearRetainingCapacity();
    try s.postings(trigramAt("WOR", 0), 100, &out, gpa);
    try std.testing.expectEqualSlices(u32, &.{ 100, 102 }, out.items);
    try std.testing.expectEqual(@as(u32, 0), s.count(trigramAt("zzz", 0)));
    try std.testing.expectEqual(@as(u64, 14), s.doc(2).path_hash);
    // Corruption anywhere is caught by the checksum.
    const bad = try gpa.dupe(u8, bytes);
    defer gpa.free(bad);
    bad[bad.len / 2] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, Segment.parse(bad));
    try std.testing.expectError(error.Truncated, Segment.parse(bytes[0 .. bytes.len - 1]));
}
