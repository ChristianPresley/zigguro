//! A minimal protobuf wire-format writer (and a test-only reader) for the
//! Perfetto exporter. Std only; no schema compiler.

const std = @import("std");

const Writer = std.Io.Writer;

/// Protobuf wire types.
pub const WireType = enum(u3) { varint = 0, i64 = 1, len = 2, i32 = 5 };

/// Writes `v` as a base-128 varint.
pub fn writeVarint(w: *Writer, v: u64) Writer.Error!void {
    var x = v;
    while (x >= 0x80) : (x >>= 7) try w.writeByte(@as(u8, @truncate(x)) | 0x80);
    try w.writeByte(@truncate(x));
}

/// Writes a field tag.
pub fn writeTag(w: *Writer, field: u29, wt: WireType) Writer.Error!void {
    try writeVarint(w, (@as(u64, field) << 3) | @intFromEnum(wt));
}

/// Writes a uint32/uint64/bool/enum field.
pub fn writeUint(w: *Writer, field: u29, v: u64) Writer.Error!void {
    try writeTag(w, field, .varint);
    try writeVarint(w, v);
}

/// Writes a sint64 field (zigzag).
pub fn writeSint(w: *Writer, field: u29, v: i64) Writer.Error!void {
    try writeTag(w, field, .varint);
    try writeVarint(w, zigzag(v));
}

/// Zigzag-encodes `v`.
pub fn zigzag(v: i64) u64 {
    return @bitCast((v << 1) ^ (v >> 63));
}

/// Writes an int32/int64 field (two's complement; 10 bytes if negative).
pub fn writeInt(w: *Writer, field: u29, v: i64) Writer.Error!void {
    try writeTag(w, field, .varint);
    try writeVarint(w, @bitCast(v));
}

/// Writes a double field.
pub fn writeDouble(w: *Writer, field: u29, v: f64) Writer.Error!void {
    try writeFixed64(w, field, @bitCast(v));
}

/// Writes a fixed64 field (wire type i64, little-endian).
pub fn writeFixed64(w: *Writer, field: u29, v: u64) Writer.Error!void {
    try writeTag(w, field, .i64);
    try w.writeInt(u64, v, .little);
}

/// Writes a bytes/string field.
pub fn writeBytes(w: *Writer, field: u29, b: []const u8) Writer.Error!void {
    try writeTag(w, field, .len);
    try writeVarint(w, b.len);
    try w.writeAll(b);
}

/// Writes an embedded message already encoded in `body`.
pub fn writeMessage(w: *Writer, field: u29, body: []const u8) Writer.Error!void {
    try writeBytes(w, field, body);
}

/// A nested message encoded into a scratch buffer, then written with its
/// length prefix (no backpatching).
pub const Nested = struct {
    scratch: *std.Io.Writer.Allocating,
    start: usize,

    /// Starts a nested message in `scratch` (which may hold outer data).
    pub fn begin(scratch: *std.Io.Writer.Allocating) Nested {
        return .{ .scratch = scratch, .start = scratch.written().len };
    }

    /// The nested message's writer.
    pub fn writer(n: Nested) *Writer {
        return &n.scratch.writer;
    }

    /// Writes the message as field `field` of `w` and drops it from the
    /// scratch buffer.
    pub fn end(n: Nested, w: *Writer, field: u29) Writer.Error!void {
        const body = n.scratch.written()[n.start..];
        try writeMessage(w, field, body);
        n.scratch.shrinkRetainingCapacity(n.start);
    }
};

/// A test-only reader over an encoded message.
pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    /// A decoded field.
    pub const Field = struct {
        number: u29,
        wire: WireType,
        /// varint, fixed64 or fixed32 value.
        int: u64 = 0,
        /// len payload.
        bytes: []const u8 = "",
    };

    /// Reads a varint.
    pub fn varint(r: *Reader) error{ Truncated, Overlong }!u64 {
        var v: u64 = 0;
        var shift: u7 = 0;
        while (true) {
            if (r.pos >= r.buf.len) return error.Truncated;
            const b = r.buf[r.pos];
            r.pos += 1;
            if (shift > 63) return error.Overlong;
            v |= @as(u64, b & 0x7f) << @intCast(shift);
            if (b & 0x80 == 0) return v;
            shift += 7;
        }
    }

    /// The next field, or null at the end.
    pub fn next(r: *Reader) error{ Truncated, Overlong, BadWireType }!?Field {
        if (r.pos >= r.buf.len) return null;
        const key = try r.varint();
        const wt = std.enums.fromInt(WireType, @as(u3, @truncate(key))) orelse return error.BadWireType;
        var f: Field = .{ .number = @intCast(key >> 3), .wire = wt };
        switch (wt) {
            .varint => f.int = try r.varint(),
            .i64 => {
                if (r.pos + 8 > r.buf.len) return error.Truncated;
                f.int = std.mem.readInt(u64, r.buf[r.pos..][0..8], .little);
                r.pos += 8;
            },
            .i32 => {
                if (r.pos + 4 > r.buf.len) return error.Truncated;
                f.int = std.mem.readInt(u32, r.buf[r.pos..][0..4], .little);
                r.pos += 4;
            },
            .len => {
                const n = try r.varint();
                if (n > r.buf.len - r.pos) return error.Truncated;
                f.bytes = r.buf[r.pos..][0..@intCast(n)];
                r.pos += @intCast(n);
            },
        }
        return f;
    }
};

fn encodeVarint(v: u64) ![]const u8 {
    const S = struct {
        var buf: [16]u8 = undefined;
    };
    var w: Writer = .fixed(&S.buf);
    try writeVarint(&w, v);
    return w.buffered();
}

test "protobuf: varint golden" {
    try std.testing.expectEqualSlices(u8, &.{0x00}, try encodeVarint(0));
    try std.testing.expectEqualSlices(u8, &.{0x01}, try encodeVarint(1));
    try std.testing.expectEqualSlices(u8, &.{0x7f}, try encodeVarint(127));
    try std.testing.expectEqualSlices(u8, &.{ 0x80, 0x01 }, try encodeVarint(128));
    try std.testing.expectEqualSlices(u8, &.{ 0x96, 0x01 }, try encodeVarint(150));
    try std.testing.expectEqualSlices(u8, &.{ 0xac, 0x02 }, try encodeVarint(300));
    try std.testing.expectEqualSlices(u8, &.{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01 }, try encodeVarint(1 << 63));
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01 }, try encodeVarint(std.math.maxInt(u64)));
    for ([_]u64{ 0, 1, 127, 128, 300, 1 << 63, std.math.maxInt(u64) }) |v| {
        var r: Reader = .{ .buf = try encodeVarint(v) };
        try std.testing.expectEqual(v, try r.varint());
    }
}

test "protobuf: zigzag sint64" {
    try std.testing.expectEqual(@as(u64, 0), zigzag(0));
    try std.testing.expectEqual(@as(u64, 1), zigzag(-1));
    try std.testing.expectEqual(@as(u64, 2), zigzag(1));
    try std.testing.expectEqual(@as(u64, 3), zigzag(-2));
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), zigzag(std.math.minInt(i64)));
}

test "protobuf: nested len prefix" {
    var scratch: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer scratch.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const n = Nested.begin(&scratch);
    try writeUint(n.writer(), 1, 150);
    try writeBytes(n.writer(), 2, "hi");
    try n.end(&out.writer, 3);
    try std.testing.expectEqualSlices(u8, &.{ 0x1a, 0x07, 0x08, 0x96, 0x01, 0x12, 0x02, 'h', 'i' }, out.written());
    try std.testing.expectEqual(@as(usize, 0), scratch.written().len);
    var r: Reader = .{ .buf = out.written() };
    const f = (try r.next()).?;
    try std.testing.expectEqual(@as(u29, 3), f.number);
    var inner: Reader = .{ .buf = f.bytes };
    try std.testing.expectEqual(@as(u64, 150), (try inner.next()).?.int);
    try std.testing.expectEqualStrings("hi", (try inner.next()).?.bytes);
    // Fixed64 and negative int64.
    out.clearRetainingCapacity();
    try writeFixed64(&out.writer, 47, 0x0102030405060708);
    try writeInt(&out.writer, 30, -1);
    r = .{ .buf = out.written() };
    const fx = (try r.next()).?;
    try std.testing.expectEqual(WireType.i64, fx.wire);
    try std.testing.expectEqual(@as(u64, 0x0102030405060708), fx.int);
    try std.testing.expectEqual(@as(i64, -1), @as(i64, @bitCast((try r.next()).?.int)));
}
