//! Git object identity: the repository hash function (SHA-1 or SHA-256,
//! per `extensions.objectFormat`) and the `Oid` value that names objects.
//!
//! SHA-1 here is plain `std.crypto.hash.Sha1`, without collision detection.
//! A SHA-1DC port is the P1 follow-up behind `scm.git.sha1dc`; until then a
//! crafted SHAttered-style collision is accepted like any other object.

const std = @import("std");

/// The hash function of a repository.
pub const ObjectFormat = enum {
    sha1,
    sha256,

    /// Raw digest length in bytes.
    pub fn len(f: ObjectFormat) usize {
        return switch (f) {
            .sha1 => 20,
            .sha256 => 32,
        };
    }

    /// Hex digest length in characters.
    pub fn hexLen(f: ObjectFormat) usize {
        return f.len() * 2;
    }

    /// The hash version number used in `.rev`, commit-graph and midx headers.
    pub fn hashVersion(f: ObjectFormat) u8 {
        return switch (f) {
            .sha1 => 1,
            .sha256 => 2,
        };
    }

    /// Inverse of `hashVersion`.
    pub fn fromHashVersion(v: u32) ?ObjectFormat {
        return switch (v) {
            1 => .sha1,
            2 => .sha256,
            else => null,
        };
    }

    /// The `extensions.objectFormat` config value.
    pub fn name(f: ObjectFormat) []const u8 {
        return @tagName(f);
    }

    /// Parses an `extensions.objectFormat` config value.
    pub fn fromName(s: []const u8) ?ObjectFormat {
        return std.meta.stringToEnum(ObjectFormat, s);
    }
};

/// An object ID. Bytes past `format.len()` are always zero, so `Oid`s
/// compare and hash correctly with `std.meta.eql` and `std.hash.autoHash`.
pub const Oid = struct {
    /// Hash function that produced `bytes`.
    format: ObjectFormat,
    /// Digest, zero-padded to 32 bytes.
    bytes: [32]u8,

    /// Error for malformed hex.
    pub const ParseError = error{InvalidOid};

    /// The all-zero ID of `format` (git's "null oid").
    pub fn zero(format: ObjectFormat) Oid {
        return .{ .format = format, .bytes = @splat(0) };
    }

    /// Builds an Oid from a raw digest of exactly `format.len()` bytes.
    pub fn fromBytes(format: ObjectFormat, raw: []const u8) Oid {
        std.debug.assert(raw.len == format.len());
        var o = zero(format);
        @memcpy(o.bytes[0..raw.len], raw);
        return o;
    }

    /// Parses a full-length lowercase or uppercase hex ID.
    pub fn parseHex(format: ObjectFormat, text: []const u8) ParseError!Oid {
        if (text.len != format.hexLen()) return error.InvalidOid;
        var o = zero(format);
        _ = std.fmt.hexToBytes(o.bytes[0..format.len()], text) catch return error.InvalidOid;
        return o;
    }

    /// The raw digest.
    pub fn slice(o: *const Oid) []const u8 {
        return o.bytes[0..o.format.len()];
    }

    /// Writes lowercase hex into `buf` and returns the used prefix.
    pub fn hex(o: Oid, buf: *[64]u8) []const u8 {
        const n = o.format.len();
        const digits = "0123456789abcdef";
        for (o.bytes[0..n], 0..) |b, i| {
            buf[i * 2] = digits[b >> 4];
            buf[i * 2 + 1] = digits[b & 15];
        }
        return buf[0 .. n * 2];
    }

    /// Whether this is the all-zero ID.
    pub fn isZero(o: Oid) bool {
        return std.mem.allEqual(u8, &o.bytes, 0);
    }

    /// Equality, including the format.
    pub fn eql(a: Oid, b: Oid) bool {
        return a.format == b.format and std.mem.eql(u8, &a.bytes, &b.bytes);
    }

    /// Byte order of the digests, as git sorts them.
    pub fn order(a: Oid, b: Oid) std.math.Order {
        return std.mem.order(u8, &a.bytes, &b.bytes);
    }

    /// Formatter printing the full hex ID: `w.print("{f}", .{id.fmtHex()})`.
    pub fn fmtHex(o: Oid) std.fmt.Alt(Oid, writeHex) {
        return .{ .data = o };
    }

    fn writeHex(o: Oid, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var buf: [64]u8 = undefined;
        try w.writeAll(o.hex(&buf));
    }
};

/// Incremental hasher for either object format.
pub const Hasher = union(ObjectFormat) {
    /// SHA-1 state.
    sha1: std.crypto.hash.Sha1,
    /// SHA-256 state.
    sha256: std.crypto.hash.sha2.Sha256,

    /// A fresh hasher for `format`.
    pub fn init(format: ObjectFormat) Hasher {
        return switch (format) {
            .sha1 => .{ .sha1 = .init(.{}) },
            .sha256 => .{ .sha256 = .init(.{}) },
        };
    }

    /// Absorbs bytes.
    pub fn update(h: *Hasher, bytes: []const u8) void {
        switch (h.*) {
            inline else => |*s| s.update(bytes),
        }
    }

    /// Finishes and returns the digest as an Oid.
    pub fn final(h: *Hasher) Oid {
        var o = Oid.zero(h.*);
        switch (h.*) {
            .sha1 => |*s| s.final(o.bytes[0..20]),
            .sha256 => |*s| s.final(o.bytes[0..32]),
        }
        return o;
    }
};

/// Hashes a whole byte string with `format` (used for file trailers).
pub fn hashBytes(format: ObjectFormat, bytes: []const u8) Oid {
    var h = Hasher.init(format);
    h.update(bytes);
    return h.final();
}

test "oid: sha1/sha256 known vectors" {
    const t = std.testing;
    const a = hashBytes(.sha1, "abc");
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("a9993e364706816aba3e25717850c26c9cd0d89d", a.hex(&buf));
    const b = hashBytes(.sha256, "abc");
    try t.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", b.hex(&buf));
    try t.expect(a.eql(try Oid.parseHex(.sha1, "A9993E364706816ABA3E25717850C26C9CD0D89D")));
    try t.expectError(error.InvalidOid, Oid.parseHex(.sha1, "a9993e"));
    try t.expectError(error.InvalidOid, Oid.parseHex(.sha1, "z9993e364706816aba3e25717850c26c9cd0d89d"));
    try t.expect(Oid.zero(.sha256).isZero());
    try t.expectEqual(ObjectFormat.sha256, ObjectFormat.fromHashVersion(2).?);
}
