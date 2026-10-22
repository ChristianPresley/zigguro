//! Node identity: generational `NodeId`s, identity-path `Key`s and widget
//! `KindId`s (ADR 0009).

const std = @import("std");

/// A generational index into the `NodeStore`. Index 0 is never allocated,
/// so the all-zero value is `none`.
pub const NodeId = packed struct(u32) {
    index: u24,
    gen: u8,

    /// No node.
    pub const none: NodeId = @bitCast(@as(u32, 0));

    /// True for `none`.
    pub fn isNone(id: NodeId) bool {
        return @as(u32, @bitCast(id)) == 0;
    }

    /// Equality, generation included.
    pub fn eql(a: NodeId, b: NodeId) bool {
        return @as(u32, @bitCast(a)) == @as(u32, @bitCast(b));
    }

    /// The id as one integer (for hash maps and logs).
    pub fn raw(id: NodeId) u32 {
        return @bitCast(id);
    }
};

/// A node's identity: the Wyhash of its path from the root, mixing each
/// level's widget kind and discriminator (explicit id or ordinal).
pub const Key = u64;

/// The widget type of a node; an index into the kind registry.
pub const KindId = enum(u16) {
    root = 0,
    box = 1,
    text = 2,
    view = 3,
    _,
};

/// The key of a child of `parent` with widget kind tag `kind` and
/// discriminator `discr`.
pub fn childKey(parent: Key, kind: u64, discr: u64) Key {
    var buf: [16]u8 = undefined;
    std.mem.writeInt(u64, buf[0..8], kind, .little);
    std.mem.writeInt(u64, buf[8..16], discr, .little);
    return std.hash.Wyhash.hash(parent, &buf);
}

/// The discriminator for an explicit id given to `Ui.id`: integers and
/// enums hash their value, slices and arrays their bytes.
pub fn explicitDiscr(v: anytype) u64 {
    const T = @TypeOf(v);
    switch (@typeInfo(T)) {
        .int, .comptime_int => return std.hash.Wyhash.hash(0x1d, std.mem.asBytes(&@as(u64, @truncate(@as(u128, @bitCast(@as(i128, v))))))),
        .@"enum" => return explicitDiscr(@intFromEnum(v)),
        .pointer => |p| {
            if (p.size == .slice) return std.hash.Wyhash.hash(0x2e, std.mem.sliceAsBytes(v));
            if (p.size == .one and @typeInfo(p.child) == .array) return std.hash.Wyhash.hash(0x2e, std.mem.sliceAsBytes(v[0..]));
            @compileError("Ui.id: pass an integer, enum or slice, not " ++ @typeName(T));
        },
        .array => return std.hash.Wyhash.hash(0x2e, std.mem.sliceAsBytes(&v)),
        else => @compileError("Ui.id: pass an integer, enum or slice, not " ++ @typeName(T)),
    }
}

/// The comptime kind tag of a widget type: the hash of its type name, so
/// keys are identical from run to run.
pub fn kindTag(comptime W: type) u64 {
    return comptime std.hash.Wyhash.hash(0x4704, @typeName(W));
}

test "none is zero and distinct" {
    try std.testing.expect(NodeId.none.isNone());
    const a: NodeId = .{ .index = 1, .gen = 1 };
    try std.testing.expect(!a.isNone());
    try std.testing.expect(!a.eql(.{ .index = 1, .gen = 2 }));
}

test "childKey depends on every input" {
    const k = childKey(1, 2, 3);
    try std.testing.expect(k != childKey(0, 2, 3));
    try std.testing.expect(k != childKey(1, 0, 3));
    try std.testing.expect(k != childKey(1, 2, 0));
    try std.testing.expectEqual(k, childKey(1, 2, 3));
}

test "explicit discriminators" {
    try std.testing.expectEqual(explicitDiscr(@as(u32, 7)), explicitDiscr(@as(u64, 7)));
    try std.testing.expect(explicitDiscr("a") != explicitDiscr("b"));
    const s: []const u8 = "abc";
    try std.testing.expectEqual(explicitDiscr(s), explicitDiscr("abc"));
}
