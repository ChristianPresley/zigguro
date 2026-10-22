//! Encodes message arguments, typed as the generated encoders pass them,
//! into the wire format: native-endian 32-bit words; strings and arrays
//! as a length word then bytes padded to 4. Fds travel separately.
//! Shared by `Connection.send` and the fake compositor.

const std = @import("std");
const builtin = @import("builtin");

/// The 8-byte header plus the largest body libwayland sends or accepts.
pub const max_message = 4096;
/// The size field is 16 bits.
pub const max_wire_message = 0xfffc;

/// Encoding errors.
pub const Error = error{
    /// The message exceeds `max_message`.
    MessageTooLarge,
};

fn padded(n: usize) usize {
    return std.mem.alignForward(usize, n, 4);
}

/// The body size in bytes of `args` (a tuple of argument values).
pub fn bodySize(args: anytype) usize {
    var n: usize = 0;
    inline for (args) |a| n += argSize(@TypeOf(a), a);
    return n;
}

fn argSize(comptime T: type, v: T) usize {
    switch (@typeInfo(T)) {
        .int, .@"enum" => return 4,
        .@"struct" => |s| {
            comptime std.debug.assert(s.layout == .@"packed" and @bitSizeOf(T) == 32);
            return 4;
        },
        .optional => |o| {
            if (v) |x| return argSize(o.child, x);
            return 4;
        },
        .pointer => {
            const sentinel = comptime std.meta.sentinel(T) != null;
            return 4 + padded(v.len + @intFromBool(sentinel));
        },
        else => @compileError("unsupported Wayland argument type " ++ @typeName(T)),
    }
}

/// Writes a message (header and body) for `obj`/`opcode` into `out`,
/// which must hold `8 + bodySize(args)` bytes; returns the size.
pub fn encode(out: []u8, obj: u32, opcode: u16, args: anytype) Error!usize {
    const size = 8 + bodySize(args);
    if (size > max_message) return error.MessageTooLarge;
    std.debug.assert(out.len >= size);
    putWord(out[0..4], obj);
    putWord(out[4..8], @as(u32, @intCast(size)) << 16 | opcode);
    var pos: usize = 8;
    inline for (args) |a| pos = putArg(out, pos, @TypeOf(a), a);
    std.debug.assert(pos == size);
    return size;
}

fn putWord(dst: *[4]u8, v: u32) void {
    std.mem.writeInt(u32, dst, v, builtin.cpu.arch.endian());
}

fn putArg(out: []u8, pos: usize, comptime T: type, v: T) usize {
    switch (@typeInfo(T)) {
        .int => {
            comptime std.debug.assert(@bitSizeOf(T) == 32);
            putWord(out[pos..][0..4], @bitCast(v));
            return pos + 4;
        },
        .@"enum" => |e| {
            const raw: e.tag_type = @intFromEnum(v);
            putWord(out[pos..][0..4], @bitCast(raw));
            return pos + 4;
        },
        .@"struct" => {
            putWord(out[pos..][0..4], @bitCast(v));
            return pos + 4;
        },
        .optional => |o| {
            if (v) |x| return putArg(out, pos, o.child, x);
            putWord(out[pos..][0..4], 0);
            return pos + 4;
        },
        .pointer => {
            const sentinel = comptime std.meta.sentinel(T) != null;
            const len = v.len + @intFromBool(sentinel);
            putWord(out[pos..][0..4], @intCast(len));
            const data = out[pos + 4 ..][0..padded(len)];
            @memcpy(data[0..v.len], v);
            @memset(data[v.len..], 0);
            return pos + 4 + data.len;
        },
        else => unreachable,
    }
}

/// The object id and the size/opcode of a header.
pub const Header = struct {
    obj: u32,
    size: u16,
    opcode: u16,

    /// Reads a header from 8 bytes.
    pub fn read(bytes: *const [8]u8) Header {
        const w1 = std.mem.readInt(u32, bytes[4..8], builtin.cpu.arch.endian());
        return .{ .obj = std.mem.readInt(u32, bytes[0..4], builtin.cpu.arch.endian()), .size = @intCast(w1 >> 16), .opcode = @truncate(w1) };
    }
};

const testing = std.testing;

test "encode every argument kind" {
    const Fixed = enum(i32) { _ };
    const Id = enum(u32) { _ };
    const Bits = packed struct(u32) { a: bool = false, b: bool = false, _pad: u30 = 0 };
    var buf: [128]u8 align(4) = undefined;
    const n = try encode(&buf, 7, 3, .{
        @as(u32, 0xdeadbeef),
        @as(i32, -2),
        @as(Fixed, @enumFromInt(256)),
        @as(Id, @enumFromInt(9)),
        @as(?Id, null),
        Bits{ .b = true },
        @as([:0]const u8, "hey"),
        @as(?[:0]const u8, null),
        @as([]const u8, "12345"),
    });
    const words: []const u32 = @ptrCast(@alignCast(buf[0..n]));
    const want = [_]u32{ 7, @as(u32, @intCast(n)) << 16 | 3, 0xdeadbeef, @bitCast(@as(i32, -2)), 256, 9, 0, 2, 4, 0, 0, 5, 0, 0 };
    try testing.expectEqual(want.len, words.len);
    for (want, words, 0..) |w, g, i| {
        if (i == 9 or i == 12 or i == 13) continue; // string and array bytes, checked below
        try testing.expectEqual(w, g);
    }
    try testing.expectEqualStrings("hey\x00", buf[36..40]);
    try testing.expectEqualStrings("12345\x00\x00\x00", buf[48..56]);
    const h = Header.read(buf[0..8]);
    try testing.expectEqual(7, h.obj);
    try testing.expectEqual(3, h.opcode);
    try testing.expectEqual(n, h.size);
}

test "oversized messages are refused" {
    var buf: [8192]u8 = undefined;
    const big: []const u8 = &(@as([5000]u8, @splat('x')));
    try testing.expectError(error.MessageTooLarge, encode(&buf, 1, 0, .{big}));
}
