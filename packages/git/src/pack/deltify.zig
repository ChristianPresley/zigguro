//! Delta compression: encode a target as copy/insert instructions against a
//! base. The base is indexed in 16-byte blocks by a Rabin-Karp hash; the
//! target is scanned with the same rolling hash, matches are verified and
//! extended both ways, and unmatched bytes become inserts.

const std = @import("std");
const delta = @import("delta.zig");
const Allocator = std.mem.Allocator;

/// Block size of the base index, and the minimum copy length.
pub const block = 16;
const prime: u32 = 0x01000193;
const max_bucket = 64;
/// Largest base handled (copy offsets are 32-bit).
pub const max_base = std.math.maxInt(u32);

fn pow(comptime n: usize) u32 {
    var p: u32 = 1;
    for (0..n) |_| p *%= prime;
    return p;
}
const out_factor = pow(block - 1);

fn hashBlock(b: []const u8) u32 {
    var h: u32 = 0;
    for (b[0..block]) |c| h = h *% prime +% c;
    return h;
}

/// A reusable index of one base object.
pub const Index = struct {
    base: []const u8,
    mask: u32,
    /// heads[h & mask] is the first slot of the bucket in `slots`, or
    /// `empty`; each slot links to the next.
    heads: []u32,
    slots: []Slot,

    const empty = std.math.maxInt(u32);
    const Slot = struct { offset: u32, next: u32 };

    /// Indexes `base` (kept borrowed).
    pub fn init(gpa: Allocator, base: []const u8) Allocator.Error!Index {
        const blocks = base.len / block;
        var size: u32 = 16;
        while (size < blocks and size < (1 << 24)) size *= 2;
        const heads = try gpa.alloc(u32, size);
        errdefer gpa.free(heads);
        @memset(heads, empty);
        const slots = try gpa.alloc(Slot, blocks);
        errdefer gpa.free(slots);
        const counts = try gpa.alloc(u8, size);
        defer gpa.free(counts);
        @memset(counts, 0);
        var n: u32 = 0;
        // Later blocks first, so buckets list earlier offsets first.
        var i = blocks;
        while (i > 0) {
            i -= 1;
            const off: u32 = @intCast(i * block);
            const b = hashBlock(base[off..]) & (size - 1);
            if (counts[b] >= max_bucket) continue;
            counts[b] += 1;
            slots[n] = .{ .offset = off, .next = heads[b] };
            heads[b] = n;
            n += 1;
        }
        return .{ .base = base, .mask = size - 1, .heads = heads, .slots = slots };
    }

    /// Frees the tables.
    pub fn deinit(ix: *Index, gpa: Allocator) void {
        gpa.free(ix.heads);
        gpa.free(ix.slots);
        ix.* = undefined;
    }
};

/// Encodes `target` against the indexed base into `out`. Returns false (with
/// `out` in an unspecified state) when the delta would exceed `max_size`.
pub fn encode(ix: *const Index, target: []const u8, out: *std.Io.Writer, max_size: usize) std.Io.Writer.Error!bool {
    const start = out.end;
    const base = ix.base;
    try delta.writeVarint(out, base.len);
    try delta.writeVarint(out, target.len);
    var pending: usize = 0; // start of not yet emitted literal bytes
    var p: usize = 0;
    if (target.len < block or base.len < block) {
        try delta.writeInsert(out, target);
        return out.end - start <= max_size;
    }
    var h = hashBlock(target);
    while (p + block <= target.len) {
        var best_off: usize = 0;
        var best_len: usize = 0;
        var slot = ix.heads[h & ix.mask];
        while (slot != Index.empty) : (slot = ix.slots[slot].next) {
            const off = ix.slots[slot].offset;
            const limit = @min(base.len - off, target.len - p);
            var l: usize = 0;
            while (l < limit and base[off + l] == target[p + l]) l += 1;
            if (l > best_len) {
                best_len = l;
                best_off = off;
                if (l >= 4096) break;
            }
        }
        if (best_len >= block) {
            // Extend backwards over pending literals.
            var back: usize = 0;
            while (back < p - pending and back < best_off and base[best_off - back - 1] == target[p - back - 1]) back += 1;
            try delta.writeInsert(out, target[pending .. p - back]);
            try delta.writeCopy(out, best_off - back, best_len + back);
            p += best_len;
            pending = p;
            if (out.end - start > max_size) return false;
            if (p + block <= target.len) h = hashBlock(target[p..]);
            continue;
        }
        if (p + block < target.len) {
            h = (h -% target[p] *% out_factor) *% prime +% target[p + block];
        }
        p += 1;
        if (p - pending >= 4096 and out.end - start + (p - pending) > max_size) return false;
    }
    try delta.writeInsert(out, target[pending..]);
    return out.end - start <= max_size;
}

/// Convenience: index `base`, encode `target`, return an owned delta or
/// null when it would exceed `max_size`.
pub fn diff(gpa: Allocator, base: []const u8, target: []const u8, max_size: usize) Allocator.Error!?[]u8 {
    if (base.len > max_base) return null;
    var ix = try Index.init(gpa, base);
    defer ix.deinit(gpa);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const ok = encode(&ix, target, &aw.writer, max_size) catch return error.OutOfMemory;
    if (!ok) return null;
    return try aw.toOwnedSlice();
}

test "deltify: roundtrip and compression" {
    const t = std.testing;
    const gpa = t.allocator;
    var prng: std.Random.DefaultPrng = .init(42);
    const r = prng.random();
    const base = try gpa.alloc(u8, 100_000);
    defer gpa.free(base);
    r.bytes(base);
    // Target: base with an insertion, a deletion and an edit.
    var tw: std.Io.Writer.Allocating = .init(gpa);
    defer tw.deinit();
    try tw.writer.writeAll(base[0..30_000]);
    try tw.writer.writeAll("INSERTED TEXT");
    try tw.writer.writeAll(base[40_000..70_000]);
    try tw.writer.writeByte(base[70_000] ^ 0xff);
    try tw.writer.writeAll(base[70_001..]);
    const target = tw.written();

    const d = (try diff(gpa, base, target, target.len)).?;
    defer gpa.free(d);
    try t.expect(d.len < 200);
    const out = try gpa.alloc(u8, target.len);
    defer gpa.free(out);
    try delta.applyDelta(base, d, out);
    try t.expectEqualSlices(u8, target, out);

    // Unrelated data does not delta under a tight limit.
    const other = try gpa.alloc(u8, 10_000);
    defer gpa.free(other);
    r.bytes(other);
    try t.expect((try diff(gpa, base, other, other.len / 2)) == null);
    // Tiny inputs still produce valid deltas.
    const small = (try diff(gpa, "abc", "abd", 100)).?;
    defer gpa.free(small);
    var so: [3]u8 = undefined;
    try delta.applyDelta("abc", small, &so);
    try t.expectEqualStrings("abd", &so);
}
