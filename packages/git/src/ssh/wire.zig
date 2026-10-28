//! SSH wire encodings (RFC 4251 §5): bytes, uint32, string, mpint,
//! boolean and name-list, for building and parsing packets.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Appends SSH-encoded values to a growing buffer.
pub const Builder = struct {
    gpa: Allocator,
    list: std.ArrayList(u8) = .empty,

    pub fn init(gpa: Allocator) Builder {
        return .{ .gpa = gpa };
    }

    pub fn deinit(b: *Builder) void {
        std.crypto.secureZero(u8, b.list.items);
        b.list.deinit(b.gpa);
    }

    pub fn bytes(b: *Builder) []const u8 {
        return b.list.items;
    }

    pub fn toOwned(b: *Builder) ![]u8 {
        return b.list.toOwnedSlice(b.gpa);
    }

    pub fn byte(b: *Builder, v: u8) !void {
        try b.list.append(b.gpa, v);
    }

    pub fn boolean(b: *Builder, v: bool) !void {
        try b.byte(@intFromBool(v));
    }

    pub fn int(b: *Builder, v: u32) !void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, v, .big);
        try b.list.appendSlice(b.gpa, &buf);
    }

    pub fn raw(b: *Builder, s: []const u8) !void {
        try b.list.appendSlice(b.gpa, s);
    }

    pub fn string(b: *Builder, s: []const u8) !void {
        try b.int(@intCast(s.len));
        try b.raw(s);
    }

    /// An mpint from an unsigned big-endian magnitude.
    pub fn mpint(b: *Builder, magnitude: []const u8) !void {
        var m = magnitude;
        while (m.len > 0 and m[0] == 0) m = m[1..];
        const pad = m.len > 0 and m[0] & 0x80 != 0;
        try b.int(@intCast(m.len + @intFromBool(pad)));
        if (pad) try b.byte(0);
        try b.raw(m);
    }

    pub fn nameList(b: *Builder, list: []const []const u8) !void {
        var len: usize = 0;
        for (list, 0..) |n, i| len += n.len + @intFromBool(i > 0);
        try b.int(@intCast(len));
        for (list, 0..) |n, i| {
            if (i > 0) try b.byte(',');
            try b.raw(n);
        }
    }
};

pub const Error = error{Truncated};

/// Reads SSH-encoded values from a byte slice.
pub const Parser = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn init(buf: []const u8) Parser {
        return .{ .buf = buf };
    }

    pub fn rest(p: *Parser) []const u8 {
        const r = p.buf[p.pos..];
        p.pos = p.buf.len;
        return r;
    }

    pub fn done(p: Parser) bool {
        return p.pos == p.buf.len;
    }

    pub fn take(p: *Parser, n: usize) Error![]const u8 {
        if (p.buf.len - p.pos < n) return error.Truncated;
        defer p.pos += n;
        return p.buf[p.pos..][0..n];
    }

    pub fn byte(p: *Parser) Error!u8 {
        return (try p.take(1))[0];
    }

    pub fn boolean(p: *Parser) Error!bool {
        return try p.byte() != 0;
    }

    pub fn int(p: *Parser) Error!u32 {
        return std.mem.readInt(u32, (try p.take(4))[0..4], .big);
    }

    pub fn string(p: *Parser) Error![]const u8 {
        return p.take(try p.int());
    }

    /// An mpint's unsigned magnitude without leading zero bytes.
    pub fn mpint(p: *Parser) Error![]const u8 {
        var m = try p.string();
        while (m.len > 0 and m[0] == 0) m = m[1..];
        return m;
    }
};

/// Iterates a comma-separated name-list.
pub fn names(list: []const u8) std.mem.SplitIterator(u8, .scalar) {
    return std.mem.splitScalar(u8, list, ',');
}

/// Whether `list` contains `name`.
pub fn hasName(list: []const u8, name: []const u8) bool {
    var it = names(list);
    while (it.next()) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// The first of the client's names the server also lists (RFC 4253 §7.1).
pub fn negotiate(client: []const u8, server: []const u8) ?[]const u8 {
    var it = names(client);
    while (it.next()) |n| if (n.len > 0 and hasName(server, n)) return n;
    return null;
}

test "mpint encoding" {
    var b: Builder = .init(std.testing.allocator);
    defer b.deinit();
    try b.mpint(&.{ 0, 0x80, 1 });
    try b.mpint(&.{0});
    try b.mpint(&.{ 0x7f, 2 });
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 3, 0, 0x80, 1, 0, 0, 0, 0, 0, 0, 0, 2, 0x7f, 2 }, b.bytes());
    var p: Parser = .init(b.bytes());
    try std.testing.expectEqualSlices(u8, &.{ 0x80, 1 }, try p.mpint());
    try std.testing.expectEqualSlices(u8, &.{}, try p.mpint());
    try std.testing.expectEqualSlices(u8, &.{ 0x7f, 2 }, try p.mpint());
    try std.testing.expect(p.done());
}

test "negotiate picks the client's first common name" {
    try std.testing.expectEqualStrings("b", negotiate("x,b,a", "a,b").?);
    try std.testing.expect(negotiate("x", "a,b") == null);
}
