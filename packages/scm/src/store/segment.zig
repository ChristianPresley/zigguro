//! Segment files: the on-disk unit of the object store.
//!
//! `<stem>.zgs` holds records:
//!   magic "ZGSG", u32 version = 1, 16-byte segment UID, then per object
//!   [kind u8][flags u8][stored_len varint][raw_len varint, deflated only][payload]
//!
//! `<stem>.zgi` indexes it:
//!   magic "ZGSI", u32 version = 1, u32 count N,
//!   fanout[256] u32, ids[N][32], kinds[N] u8, offsets[N] u64,
//!   segment UID[16], BLAKE3-256 of every preceding byte.
//!
//! All integers are little-endian. IDs are sorted bytewise; `fanout[b]`
//! counts IDs whose first byte is <= b. A segment is published when its
//! `.zgi` appears (it is written to a temporary name and linked into
//! place), so readers ignore any `.zgs` without one.

const std = @import("std");
const id_mod = @import("id.zig");
const enc = @import("encode.zig");
const ObjectId = id_mod.ObjectId;
const Kind = id_mod.Kind;
const Blake3 = std.crypto.hash.Blake3;
const Allocator = std.mem.Allocator;

pub const segment_magic = "ZGSG";
pub const index_magic = "ZGSI";
pub const format_version: u32 = 1;
/// Bytes before the first record of a `.zgs`.
pub const segment_header_len = 4 + 4 + 16;
const index_header_len = 4 + 4 + 4;
const fanout_len = 256 * 4;
const index_trailer_len = 16 + 32;

/// Record flag: the payload is raw-deflate compressed.
pub const flag_deflate: u8 = 1;

/// A segment file or index that does not parse.
pub const FormatError = error{CorruptSegment};

/// Writes a `.zgs` header.
pub fn writeSegmentHeader(w: *std.Io.Writer, uid: [16]u8) std.Io.Writer.Error!void {
    try w.writeAll(segment_magic);
    try w.writeInt(u32, format_version, .little);
    try w.writeAll(&uid);
}

/// The UID in a `.zgs` header.
pub fn parseSegmentHeader(bytes: []const u8) FormatError![16]u8 {
    if (bytes.len < segment_header_len or !std.mem.eql(u8, bytes[0..4], segment_magic)) return error.CorruptSegment;
    if (std.mem.readInt(u32, bytes[4..8], .little) != format_version) return error.CorruptSegment;
    return bytes[8..24].*;
}

/// Writes one record header (the payload follows).
pub fn writeRecordHeader(w: *std.Io.Writer, kind: Kind, flags: u8, stored_len: usize, raw_len: usize) std.Io.Writer.Error!void {
    try w.writeByte(@intFromEnum(kind));
    try w.writeByte(flags);
    try enc.writeVarint(w, stored_len);
    if (flags & flag_deflate != 0) try enc.writeVarint(w, raw_len);
}

/// A record read from segment bytes.
pub const Record = struct {
    kind: Kind,
    flags: u8,
    /// Stored bytes (compressed when `flags` has `flag_deflate`).
    payload: []const u8,
    /// Length after decompression.
    raw_len: usize,
    /// Offset just past the record.
    end: usize,

    pub fn deflated(r: Record) bool {
        return r.flags & flag_deflate != 0;
    }
};

/// Parses the record at `off` in `bytes`.
pub fn readRecord(bytes: []const u8, off: u64) FormatError!Record {
    if (off < segment_header_len or off >= bytes.len) return error.CorruptSegment;
    const o: usize = @intCast(off);
    if (bytes.len - o < 3) return error.CorruptSegment;
    const kind = Kind.fromInt(bytes[o]) orelse return error.CorruptSegment;
    const flags = bytes[o + 1];
    if (flags & ~flag_deflate != 0) return error.CorruptSegment;
    var r: enc.Reader = .{ .bytes = bytes, .pos = o + 2 };
    const stored = r.varint() catch return error.CorruptSegment;
    const raw = if (flags & flag_deflate != 0) r.varint() catch return error.CorruptSegment else stored;
    if (stored > bytes.len - r.pos or raw > std.math.maxInt(usize)) return error.CorruptSegment;
    const start = r.pos;
    const end = start + @as(usize, @intCast(stored));
    return .{ .kind = kind, .flags = flags, .payload = bytes[start..end], .raw_len = @intCast(raw), .end = end };
}

/// One object in an index being written.
pub const IndexEntry = struct {
    id: ObjectId,
    kind: Kind,
    offset: u64,

    fn lessThan(_: void, a: IndexEntry, b: IndexEntry) bool {
        return a.id.order(b.id) == .lt;
    }
};

/// Sorts `entries` by ID and writes a `.zgi` for them. IDs must be unique.
pub fn writeIndex(w: *std.Io.Writer, entries: []IndexEntry, uid: [16]u8) std.Io.Writer.Error!void {
    std.mem.sort(IndexEntry, entries, {}, IndexEntry.lessThan);
    var h = Blake3.init(.{});
    var hw: HashingWriter = .{ .inner = w, .h = &h };
    const out = &hw;
    var buf: [12]u8 = undefined;
    @memcpy(buf[0..4], index_magic);
    std.mem.writeInt(u32, buf[4..8], format_version, .little);
    std.mem.writeInt(u32, buf[8..12], @intCast(entries.len), .little);
    try out.write(&buf);
    var counts: [256]u32 = @splat(0);
    for (entries) |e| counts[e.id.bytes[0]] += 1;
    var total: u32 = 0;
    for (counts) |c| {
        total += c;
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, total, .little);
        try out.write(&b);
    }
    for (entries) |e| try out.write(&e.id.bytes);
    for (entries) |e| try out.write(&.{@intFromEnum(e.kind)});
    for (entries) |e| {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, e.offset, .little);
        try out.write(&b);
    }
    try out.write(&uid);
    var sum: [32]u8 = undefined;
    h.final(&sum);
    try w.writeAll(&sum);
}

const HashingWriter = struct {
    inner: *std.Io.Writer,
    h: *Blake3,

    fn write(self: *HashingWriter, bytes: []const u8) std.Io.Writer.Error!void {
        self.h.update(bytes);
        try self.inner.writeAll(bytes);
    }
};

/// A read-only view over the bytes of a `.zgi`.
pub const SegmentIndex = struct {
    bytes: []const u8,
    count: u32,

    /// Checks the header and that the size matches the count. Does not
    /// verify the checksum (see `verifyChecksum`), so opening stays O(1).
    pub fn parse(bytes: []const u8) FormatError!SegmentIndex {
        if (bytes.len < index_header_len + fanout_len + index_trailer_len) return error.CorruptSegment;
        if (!std.mem.eql(u8, bytes[0..4], index_magic)) return error.CorruptSegment;
        if (std.mem.readInt(u32, bytes[4..8], .little) != format_version) return error.CorruptSegment;
        const n = std.mem.readInt(u32, bytes[8..12], .little);
        const want = index_header_len + fanout_len + @as(u64, n) * (32 + 1 + 8) + index_trailer_len;
        if (bytes.len != want) return error.CorruptSegment;
        const ix: SegmentIndex = .{ .bytes = bytes, .count = n };
        if (ix.fanout(255) != n) return error.CorruptSegment;
        return ix;
    }

    /// Number of IDs whose first byte is <= `b`.
    pub fn fanout(ix: SegmentIndex, b: u8) u32 {
        return std.mem.readInt(u32, ix.bytes[index_header_len + @as(usize, b) * 4 ..][0..4], .little);
    }

    fn idsStart() usize {
        return index_header_len + fanout_len;
    }

    /// The `i`th ID as raw bytes.
    pub fn idBytes(ix: SegmentIndex, i: u32) *const [32]u8 {
        return ix.bytes[idsStart() + @as(usize, i) * 32 ..][0..32];
    }

    pub fn id(ix: SegmentIndex, i: u32) ObjectId {
        return .{ .bytes = ix.idBytes(i).* };
    }

    /// The stored kind byte of entry `i` (validated by the caller).
    pub fn kindByte(ix: SegmentIndex, i: u32) u8 {
        return ix.bytes[idsStart() + @as(usize, ix.count) * 32 + i];
    }

    pub fn offset(ix: SegmentIndex, i: u32) u64 {
        const base = idsStart() + @as(usize, ix.count) * 33;
        return std.mem.readInt(u64, ix.bytes[base + @as(usize, i) * 8 ..][0..8], .little);
    }

    /// The segment UID recorded in the trailer.
    pub fn uid(ix: SegmentIndex) [16]u8 {
        return ix.bytes[ix.bytes.len - index_trailer_len ..][0..16].*;
    }

    /// Whether the trailing BLAKE3 matches the contents.
    pub fn verifyChecksum(ix: SegmentIndex) bool {
        var sum: [32]u8 = undefined;
        Blake3.hash(ix.bytes[0 .. ix.bytes.len - 32], &sum, .{});
        return std.mem.eql(u8, &sum, ix.bytes[ix.bytes.len - 32 ..]);
    }

    /// The position of `want`, by fanout then binary search over the IDs.
    pub fn find(ix: SegmentIndex, want: ObjectId) ?u32 {
        const first = want.bytes[0];
        var lo: u32 = if (first == 0) 0 else ix.fanout(first - 1);
        var hi: u32 = ix.fanout(first);
        // Compare the first 8 bytes as integers; fall back to the rest.
        const key = std.mem.readInt(u64, want.bytes[0..8], .big);
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const cand = ix.idBytes(mid);
            const ck = std.mem.readInt(u64, cand[0..8], .big);
            const ord = if (ck != key) std.math.order(ck, key) else std.mem.order(u8, cand[8..], want.bytes[8..]);
            switch (ord) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return mid,
            }
        }
        return null;
    }

    /// Whether IDs are strictly increasing and agree with the fanout.
    pub fn verifyOrder(ix: SegmentIndex) bool {
        for (0..ix.count) |k| {
            const i: u32 = @intCast(k);
            const b = ix.idBytes(i);
            if (i > 0 and std.mem.order(u8, ix.idBytes(i - 1), b) != .lt) return false;
            // Every entry before i must be counted by fanout(first byte).
            if (ix.fanout(b[0]) <= i) return false;
            if (b[0] > 0 and ix.fanout(b[0] - 1) > i) return false;
        }
        return true;
    }
};

test "segment: index write/parse/find" {
    const t = std.testing;
    var entries: [300]IndexEntry = undefined;
    for (&entries, 0..) |*e, i| e.* = .{ .id = id_mod.hashObject(.blob, std.mem.asBytes(&i)), .kind = .blob, .offset = segment_header_len + i };
    entries[7].kind = .tree;
    const tree_id = entries[7].id;
    var aw: std.Io.Writer.Allocating = .init(t.allocator);
    defer aw.deinit();
    const uid: [16]u8 = @splat(0xab);
    try writeIndex(&aw.writer, &entries, uid);
    const ix = try SegmentIndex.parse(aw.written());
    try t.expectEqual(@as(u32, 300), ix.count);
    try t.expect(ix.verifyChecksum());
    try t.expect(ix.verifyOrder());
    try t.expectEqualSlices(u8, &uid, &ix.uid());
    for (entries) |e| {
        const i = ix.find(e.id).?;
        try t.expect(ix.id(i).eql(e.id));
        try t.expectEqual(e.offset, ix.offset(i));
    }
    try t.expectEqual(@intFromEnum(Kind.tree), ix.kindByte(ix.find(tree_id).?));
    try t.expect(ix.find(id_mod.hashObject(.text, "absent")) == null);
    // A flipped byte breaks the checksum; a short file does not parse.
    const copy = try t.allocator.dupe(u8, aw.written());
    defer t.allocator.free(copy);
    copy[2000] ^= 1;
    try t.expect(!(try SegmentIndex.parse(copy)).verifyChecksum());
    try t.expectError(error.CorruptSegment, SegmentIndex.parse(copy[0 .. copy.len - 1]));
}

test "segment: record header roundtrip" {
    const t = std.testing;
    var aw: std.Io.Writer.Allocating = .init(t.allocator);
    defer aw.deinit();
    try writeSegmentHeader(&aw.writer, @splat(1));
    const off = aw.written().len;
    try writeRecordHeader(&aw.writer, .text, flag_deflate, 3, 300);
    try aw.writer.writeAll("abc");
    const off2 = aw.written().len;
    try writeRecordHeader(&aw.writer, .blob, 0, 2, 2);
    try aw.writer.writeAll("hi");
    const bytes = aw.written();
    try t.expectEqualSlices(u8, &@as([16]u8, @splat(1)), &(try parseSegmentHeader(bytes)));
    const r = try readRecord(bytes, off);
    try t.expectEqual(Kind.text, r.kind);
    try t.expect(r.deflated());
    try t.expectEqual(@as(usize, 300), r.raw_len);
    try t.expectEqualStrings("abc", r.payload);
    try t.expectEqual(off2, r.end);
    const r2 = try readRecord(bytes, off2);
    try t.expectEqualStrings("hi", r2.payload);
    try t.expectError(error.CorruptSegment, readRecord(bytes, bytes.len - 1));
    try t.expectError(error.CorruptSegment, readRecord(bytes, 3));
}

test "fuzz: scm-segment" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var buf: [4096]u8 = undefined;
            const input = buf[0..s.slice(&buf)];
            // Index files: parse, verify, look up every entry.
            if (SegmentIndex.parse(input)) |ix| {
                _ = ix.verifyChecksum();
                _ = ix.verifyOrder();
                for (0..ix.count) |k| _ = ix.find(ix.id(@intCast(k)));
            } else |_| {}
            // Segment files: walk the records from the header on.
            _ = parseSegmentHeader(input) catch return;
            var off: u64 = segment_header_len;
            while (readRecord(input, off)) |r| {
                if (r.end <= off) return error.NoProgress;
                off = r.end;
            } else |_| {}
        }
    }.one, .{ .corpus = @import("zg_core").testkit.fuzz.corpus(@import("zg_corpus"), "scm-segment") });
}
