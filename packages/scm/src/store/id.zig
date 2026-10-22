//! Object kinds, BLAKE3 object IDs and change IDs.
//!
//! An object's ID is BLAKE3-256 over `"zg1 <kind> <len>\x00" ++ payload`.
//! The header mirrors git's `"<type> <len>\x00"` and separates the kinds, so
//! two objects of different kinds never share an ID.

const std = @import("std");
const Blake3 = std.crypto.hash.Blake3;

/// Every kind of object in the store. The numeric values are stored in
/// segment records and indexes, so they never change.
pub const Kind = enum(u8) {
    blob = 1,
    chunked_blob = 2,
    tree = 3,
    change = 4,
    operation = 5,
    view = 6,
    attribution = 7,
    prov_record = 8,
    text = 9,

    /// The kind with numeric value `v`, or null.
    pub fn fromInt(v: u8) ?Kind {
        return std.enums.fromInt(Kind, v);
    }
};

const hex_chars = "0123456789abcdef";

fn hexNibble(c: u8) ?u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => null,
    };
}

/// A BLAKE3-256 object ID.
pub const ObjectId = struct {
    bytes: [32]u8,

    /// Encoded as its 32 raw bytes (see encode.zig).
    pub const encoding = .fixed_bytes;

    /// All zeros; never the ID of a real object.
    pub const zero: ObjectId = .{ .bytes = @splat(0) };

    /// Writes the 64-char lowercase hex form into `buf`.
    pub fn hex(self: ObjectId, buf: *[64]u8) []const u8 {
        for (self.bytes, 0..) |b, i| {
            buf[2 * i] = hex_chars[b >> 4];
            buf[2 * i + 1] = hex_chars[b & 15];
        }
        return buf;
    }

    /// The first `n` hex digits (at most 64) of the ID, written into `buf`.
    pub fn short(self: ObjectId, buf: *[64]u8, n: u8) []const u8 {
        return self.hex(buf)[0..@min(n, 64)];
    }

    /// Parses exactly 64 hex digits (either case).
    pub fn parseHex(s: []const u8) error{InvalidObjectId}!ObjectId {
        if (s.len != 64) return error.InvalidObjectId;
        var id: ObjectId = undefined;
        for (&id.bytes, 0..) |*b, i| {
            const hi = hexNibble(s[2 * i]) orelse return error.InvalidObjectId;
            const lo = hexNibble(s[2 * i + 1]) orelse return error.InvalidObjectId;
            b.* = @as(u8, hi) << 4 | lo;
        }
        return id;
    }

    pub fn eql(a: ObjectId, b: ObjectId) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }

    /// Byte order, the order of segment indexes.
    pub fn order(a: ObjectId, b: ObjectId) std.math.Order {
        return std.mem.order(u8, &a.bytes, &b.bytes);
    }

    pub fn lessThan(_: void, a: ObjectId, b: ObjectId) bool {
        return a.order(b) == .lt;
    }

    /// `{f}` prints the full hex form.
    pub fn format(self: ObjectId, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var buf: [64]u8 = undefined;
        try w.writeAll(self.hex(&buf));
    }

    pub fn jsonStringify(self: ObjectId, jw: anytype) !void {
        var buf: [64]u8 = undefined;
        try jw.write(self.hex(&buf));
    }

    pub fn jsonParse(gpa: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !ObjectId {
        const s = try std.json.innerParse([]const u8, gpa, source, options);
        return parseHex(s) catch error.UnexpectedToken;
    }
};

/// A random, stable identity for a change that survives rewrites (amend,
/// rebase). Shown in "reverse hex" so it never looks like a commit hash.
pub const ChangeId = struct {
    bytes: [16]u8,

    pub const encoding = .fixed_bytes;

    /// A fresh random change ID.
    pub fn generate(io: std.Io) ChangeId {
        var id: ChangeId = undefined;
        io.random(&id.bytes);
        return id;
    }

    /// Jujutsu-style reverse hex: nibble 0 is 'z', 1 is 'y', ..., 15 is 'k'.
    pub fn reverseHex(self: ChangeId, buf: *[32]u8) []const u8 {
        for (self.bytes, 0..) |b, i| {
            buf[2 * i] = 'z' - (b >> 4);
            buf[2 * i + 1] = 'z' - (b & 15);
        }
        return buf;
    }

    /// Parses exactly 32 reverse-hex digits ('k'..'z').
    pub fn parseReverseHex(s: []const u8) error{InvalidChangeId}!ChangeId {
        if (s.len != 32) return error.InvalidChangeId;
        var id: ChangeId = undefined;
        for (&id.bytes, 0..) |*b, i| {
            const hi = s[2 * i];
            const lo = s[2 * i + 1];
            if (hi < 'k' or hi > 'z' or lo < 'k' or lo > 'z') return error.InvalidChangeId;
            b.* = ('z' - hi) << 4 | ('z' - lo);
        }
        return id;
    }

    pub fn eql(a: ChangeId, b: ChangeId) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }

    pub fn format(self: ChangeId, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var buf: [32]u8 = undefined;
        try w.writeAll(self.reverseHex(&buf));
    }

    pub fn jsonStringify(self: ChangeId, jw: anytype) !void {
        var buf: [32]u8 = undefined;
        try jw.write(self.reverseHex(&buf));
    }

    pub fn jsonParse(gpa: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !ChangeId {
        const s = try std.json.innerParse([]const u8, gpa, source, options);
        return parseReverseHex(s) catch error.UnexpectedToken;
    }
};

/// Streaming object hasher: `init` with the kind and the exact payload
/// length, feed the payload with `update`, then `final`.
pub const Hasher = struct {
    h: Blake3,

    pub fn init(kind: Kind, len: u64) Hasher {
        var h = Blake3.init(.{});
        var buf: [64]u8 = undefined;
        h.update(header(&buf, kind, len));
        return .{ .h = h };
    }

    pub fn update(self: *Hasher, bytes: []const u8) void {
        self.h.update(bytes);
    }

    pub fn final(self: *Hasher) ObjectId {
        var id: ObjectId = undefined;
        self.h.final(&id.bytes);
        return id;
    }
};

/// The hash header `"zg1 <kind> <len>\x00"`, written into `buf`.
pub fn header(buf: *[64]u8, kind: Kind, len: u64) []const u8 {
    return std.fmt.bufPrint(buf, "zg1 {s} {d}\x00", .{ @tagName(kind), len }) catch unreachable;
}

/// The ID of an object of `kind` whose canonical encoding is `payload`.
pub fn hashObject(kind: Kind, payload: []const u8) ObjectId {
    var h = Hasher.init(kind, payload.len);
    h.update(payload);
    return h.final();
}

/// Payloads at least this large are worth hashing on several threads.
pub const parallel_threshold = 8 << 20;

/// `hashObject` for large in-memory payloads; the result always equals
/// `hashObject`.
///
/// This hashes sequentially for now. Zig 0.16.0's `Blake3.hashParallel`
/// reduces chunk chaining values pairwise level by level, which is not
/// BLAKE3's left-full tree, so it returns wrong digests for many lengths
/// (e.g. 8 MiB + 12345 bytes). The `gpa`/`io` parameters keep the signature
/// stable for a correct parallel version.
pub fn hashObjectParallel(gpa: std.mem.Allocator, io: std.Io, kind: Kind, payload: []const u8) error{ OutOfMemory, Canceled }!ObjectId {
    _ = gpa;
    _ = io;
    return hashObject(kind, payload);
}

test "id: hex roundtrip, short and order" {
    const t = std.testing;
    const id = hashObject(.blob, "hello\n");
    var buf: [64]u8 = undefined;
    const h = id.hex(&buf);
    try t.expect(id.eql(try ObjectId.parseHex(h)));
    var upper: [64]u8 = undefined;
    _ = std.ascii.upperString(&upper, h);
    try t.expect(id.eql(try ObjectId.parseHex(&upper)));
    try t.expectEqualStrings(h[0..12], id.short(&buf, 12));
    try t.expectError(error.InvalidObjectId, ObjectId.parseHex(h[0..63]));
    try t.expectError(error.InvalidObjectId, ObjectId.parseHex("g" ** 64));
    try t.expectEqual(std.math.Order.lt, ObjectId.zero.order(id));
}

test "id: kinds are domain-separated" {
    const t = std.testing;
    try t.expect(!hashObject(.blob, "x").eql(hashObject(.text, "x")));
    var hb: [64]u8 = undefined;
    try t.expectEqualStrings("zg1 tree 12\x00", header(&hb, .tree, 12));
    var expect: ObjectId = undefined;
    Blake3.hash("zg1 blob 1\x00x", &expect.bytes, .{});
    try t.expect(expect.eql(hashObject(.blob, "x")));
    var h = Hasher.init(.blob, 3);
    h.update("a");
    h.update("bc");
    try t.expect(h.final().eql(hashObject(.blob, "abc")));
}

test "id: parallel hash equals sequential" {
    const t = std.testing;
    const data = try t.allocator.alloc(u8, parallel_threshold + 12345);
    defer t.allocator.free(data);
    for (data, 0..) |*b, i| b.* = @truncate(i *% 2654435761 >> 13);
    const seq = hashObject(.blob, data);
    const par = try hashObjectParallel(t.allocator, t.io, .blob, data);
    try t.expect(seq.eql(par));
}

test "changeid: reverse-hex roundtrip and alphabet" {
    const t = std.testing;
    const z: ChangeId = .{ .bytes = @splat(0) };
    var buf: [32]u8 = undefined;
    try t.expectEqualStrings("z" ** 32, z.reverseHex(&buf));
    const f: ChangeId = .{ .bytes = @splat(0xff) };
    try t.expectEqualStrings("k" ** 32, f.reverseHex(&buf));
    for (0..64) |_| {
        const id = ChangeId.generate(t.io);
        const s = id.reverseHex(&buf);
        for (s) |c| try t.expect(c >= 'k' and c <= 'z');
        try t.expect(id.eql(try ChangeId.parseReverseHex(s)));
    }
    try t.expectError(error.InvalidChangeId, ChangeId.parseReverseHex("a" ** 32));
    try t.expectError(error.InvalidChangeId, ChangeId.parseReverseHex("z" ** 31));
}
