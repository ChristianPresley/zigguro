//! Object types, the `Object` value returned by readers, and object hashing
//! (`H("<type> <len>\0" ++ data)`).

const std = @import("std");
const oid_mod = @import("oid.zig");
const Oid = oid_mod.Oid;
const ObjectFormat = oid_mod.ObjectFormat;

/// The four git object types, numbered as in pack entry headers.
pub const ObjectType = enum(u3) {
    commit = 1,
    tree = 2,
    blob = 3,
    tag = 4,

    /// The name used in object headers ("commit", "tree", ...).
    pub fn name(t: ObjectType) []const u8 {
        return @tagName(t);
    }

    /// Parses an object header type name.
    pub fn fromName(s: []const u8) ?ObjectType {
        return std.meta.stringToEnum(ObjectType, s);
    }

    /// Converts a pack entry type number; delta types and 0/5 return null.
    pub fn fromPackType(n: u3) ?ObjectType {
        return switch (n) {
            1, 2, 3, 4 => @enumFromInt(n),
            else => null,
        };
    }
};

/// A fully read object. `data` is owned by the caller's allocator.
pub const Object = struct {
    /// Object type.
    type: ObjectType,
    /// Uncompressed object contents (without the "<type> <len>\0" header).
    data: []u8,

    /// Frees `data`.
    pub fn deinit(o: *Object, gpa: std.mem.Allocator) void {
        gpa.free(o.data);
        o.* = undefined;
    }
};

/// Errors for malformed objects.
pub const ParseError = error{CorruptObject};

/// Writes the object header "<type> <len>\0" into `buf` and returns it.
pub fn header(buf: *[32]u8, t: ObjectType, len: u64) []const u8 {
    return std.fmt.bufPrint(buf, "{s} {d}\x00", .{ t.name(), len }) catch unreachable;
}

/// Parsed object header and the offset of the first data byte.
pub const Header = struct {
    /// Object type.
    type: ObjectType,
    /// Declared data length.
    size: u64,
    /// Length of the header including the NUL.
    len: usize,
};

/// Parses "<type> <len>\0" at the start of `bytes`. The size must be plain
/// decimal without leading zeros, as git writes it.
pub fn parseHeader(bytes: []const u8) ParseError!Header {
    const limit = @min(bytes.len, 32);
    const sp = std.mem.indexOfScalar(u8, bytes[0..limit], ' ') orelse return error.CorruptObject;
    const nul = std.mem.indexOfScalarPos(u8, bytes[0..limit], sp, 0) orelse return error.CorruptObject;
    const t = ObjectType.fromName(bytes[0..sp]) orelse return error.CorruptObject;
    const digits = bytes[sp + 1 .. nul];
    if (digits.len == 0 or (digits.len > 1 and digits[0] == '0')) return error.CorruptObject;
    const size = std.fmt.parseInt(u64, digits, 10) catch return error.CorruptObject;
    return .{ .type = t, .size = size, .len = nul + 1 };
}

/// Hashes an object the way git names it.
pub fn hashObject(fmt: ObjectFormat, t: ObjectType, data: []const u8) Oid {
    var h = oid_mod.Hasher.init(fmt);
    var buf: [32]u8 = undefined;
    h.update(header(&buf, t, data.len));
    h.update(data);
    return h.final();
}

test "object: hash matches git" {
    const t = std.testing;
    var buf: [64]u8 = undefined;
    // `printf 'hello\n' | git hash-object --stdin`
    try t.expectEqualStrings("ce013625030ba8dba906f756967f9e9ca394464a", hashObject(.sha1, .blob, "hello\n").hex(&buf));
    // `git hash-object --stdin -t tree < /dev/null`
    try t.expectEqualStrings("4b825dc642cb6eb9a060e54bf8d69288fbee4904", hashObject(.sha1, .tree, "").hex(&buf));
    // Same empty tree in a SHA-256 repository.
    try t.expectEqualStrings("6ef19b41225c5369f1c104d45d8d85efa9b057b53b14b4b9b939dd74decc5321", hashObject(.sha256, .tree, "").hex(&buf));
}

test "object: header parse" {
    const t = std.testing;
    const h = try parseHeader("blob 12\x00hello");
    try t.expectEqual(ObjectType.blob, h.type);
    try t.expectEqual(@as(u64, 12), h.size);
    try t.expectEqual(@as(usize, 8), h.len);
    try t.expectError(error.CorruptObject, parseHeader("blob 012\x00"));
    try t.expectError(error.CorruptObject, parseHeader("blub 1\x00"));
    try t.expectError(error.CorruptObject, parseHeader("blob 1"));
}
