//! The RFC 6455 frame codec: headers, masking and the handshake accept key.
//! Pure functions, no I/O.

const std = @import("std");

pub const Opcode = enum(u4) {
    continuation = 0,
    text = 1,
    binary = 2,
    close = 8,
    ping = 9,
    pong = 10,
    _,

    pub fn isControl(op: Opcode) bool {
        return @intFromEnum(op) >= 8;
    }

    pub fn isKnown(op: Opcode) bool {
        return switch (op) {
            .continuation, .text, .binary, .close, .ping, .pong => true,
            _ => false,
        };
    }
};

pub const Header = struct {
    fin: bool,
    rsv: u3 = 0,
    opcode: Opcode,
    masked: bool,
    len: u64,
    mask: [4]u8 = .{ 0, 0, 0, 0 },
};

/// Encodes `h` with the minimal length form (7, 7+16 or 7+64 bits).
pub fn encodeHeader(buf: *[14]u8, h: Header) []const u8 {
    buf[0] = (@as(u8, @intFromBool(h.fin)) << 7) | (@as(u8, h.rsv) << 4) | @intFromEnum(h.opcode);
    const m: u8 = @as(u8, @intFromBool(h.masked)) << 7;
    var n: usize = 2;
    if (h.len < 126) {
        buf[1] = m | @as(u8, @intCast(h.len));
    } else if (h.len <= 0xffff) {
        buf[1] = m | 126;
        std.mem.writeInt(u16, buf[2..4], @intCast(h.len), .big);
        n = 4;
    } else {
        buf[1] = m | 127;
        std.mem.writeInt(u64, buf[2..10], h.len, .big);
        n = 10;
    }
    if (h.masked) {
        buf[n..][0..4].* = h.mask;
        n += 4;
    }
    return buf[0..n];
}

pub const DecodeError = error{ Incomplete, Protocol };

/// Decodes a header from the start of `bytes`. Non-minimal lengths and a
/// 64-bit length with the top bit set are protocol errors.
pub fn decodeHeader(bytes: []const u8) DecodeError!struct { header: Header, size: usize } {
    if (bytes.len < 2) return error.Incomplete;
    const b0 = bytes[0];
    const b1 = bytes[1];
    var h: Header = .{
        .fin = b0 & 0x80 != 0,
        .rsv = @intCast((b0 >> 4) & 7),
        .opcode = @enumFromInt(@as(u4, @intCast(b0 & 0x0f))),
        .masked = b1 & 0x80 != 0,
        .len = b1 & 0x7f,
    };
    var n: usize = 2;
    if (h.len == 126) {
        if (bytes.len < 4) return error.Incomplete;
        h.len = std.mem.readInt(u16, bytes[2..4], .big);
        if (h.len < 126) return error.Protocol;
        n = 4;
    } else if (h.len == 127) {
        if (bytes.len < 10) return error.Incomplete;
        h.len = std.mem.readInt(u64, bytes[2..10], .big);
        if (h.len >> 63 != 0 or h.len <= 0xffff) return error.Protocol;
        n = 10;
    }
    if (h.masked) {
        if (bytes.len < n + 4) return error.Incomplete;
        h.mask = bytes[n..][0..4].*;
        n += 4;
    }
    return .{ .header = h, .size = n };
}

/// The number of header bytes implied by the first two bytes.
pub fn headerSize(b0b1: [2]u8) usize {
    _ = b0b1[0];
    const len7 = b0b1[1] & 0x7f;
    const ext: usize = if (len7 == 126) 2 else if (len7 == 127) 8 else 0;
    return 2 + ext + @as(usize, if (b0b1[1] & 0x80 != 0) 4 else 0);
}

/// XORs `data` with `mask`, where `data[0]` is payload byte `offset`.
pub fn applyMask(mask: [4]u8, offset: usize, data: []u8) void {
    const V = @Vector(16, u8);
    var pattern: [16]u8 = undefined;
    for (&pattern, 0..) |*p, i| p.* = mask[(offset + i) % 4];
    const pv: V = pattern;
    var i: usize = 0;
    while (i + 16 <= data.len) : (i += 16) {
        const v: V = data[i..][0..16].*;
        data[i..][0..16].* = v ^ pv;
    }
    while (i < data.len) : (i += 1) data[i] ^= mask[(offset + i) % 4];
}

pub const magic_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// `base64(sha1(key ++ GUID))`, the `Sec-WebSocket-Accept` value.
pub fn acceptKey(key: []const u8, out: *[28]u8) []const u8 {
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(key);
    sha.update(magic_guid);
    var digest: [20]u8 = undefined;
    sha.final(&digest);
    return std.base64.standard.Encoder.encode(out, &digest);
}

test "ws_frame: length boundaries round trip" {
    for ([_]u64{ 0, 1, 125, 126, 127, 65535, 65536, 1 << 40 }) |len| {
        for ([_]bool{ false, true }) |masked| {
            var buf: [14]u8 = undefined;
            const h: Header = .{ .fin = true, .opcode = .binary, .masked = masked, .len = len, .mask = .{ 1, 2, 3, 4 } };
            const enc = encodeHeader(&buf, h);
            const want: usize = @as(usize, if (len < 126) 2 else if (len <= 0xffff) 4 else 10) + @as(usize, if (masked) 4 else 0);
            try std.testing.expectEqual(want, enc.len);
            try std.testing.expectEqual(want, headerSize(enc[0..2].*));
            const d = try decodeHeader(enc);
            try std.testing.expectEqual(enc.len, d.size);
            try std.testing.expectEqual(len, d.header.len);
            try std.testing.expectEqual(masked, d.header.masked);
            if (masked) try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, &d.header.mask);
            try std.testing.expectError(error.Incomplete, decodeHeader(enc[0 .. enc.len - 1]));
        }
    }
}

test "ws_frame: non-minimal lengths rejected" {
    try std.testing.expectError(error.Protocol, decodeHeader(&.{ 0x82, 126, 0, 125 }));
    try std.testing.expectError(error.Protocol, decodeHeader(&.{ 0x82, 127, 0, 0, 0, 0, 0, 0, 0xff, 0xff }));
    try std.testing.expectError(error.Protocol, decodeHeader(&.{ 0x82, 127, 0x80, 0, 0, 0, 0, 1, 0, 0 }));
}

test "ws_frame: mask round trip at every offset" {
    var data: [100]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast(i);
    const orig = data;
    const mask = [4]u8{ 0x37, 0xfa, 0x21, 0x3d };
    applyMask(mask, 0, data[0..37]);
    applyMask(mask, 37, data[37..]);
    for (data, 0..) |b, i| try std.testing.expectEqual(orig[i] ^ mask[i % 4], b);
    applyMask(mask, 0, &data);
    try std.testing.expectEqualSlices(u8, &orig, &data);
}

test "ws_frame: RFC 6455 accept key example" {
    var out: [28]u8 = undefined;
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", acceptKey("dGhlIHNhbXBsZSBub25jZQ==", &out));
}

test "fuzz: ws decodeHeader" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var buf: [16]u8 = undefined;
            const input = buf[0..s.slice(&buf)];
            const d = decodeHeader(input) catch return;
            try std.testing.expect(d.size <= input.len);
            if (input.len >= 2) try std.testing.expectEqual(headerSize(input[0..2].*), d.size);
            var enc: [14]u8 = undefined;
            const again = encodeHeader(&enc, d.header);
            try std.testing.expectEqualSlices(u8, input[0..d.size], again);
        }
    }.one, .{});
}
