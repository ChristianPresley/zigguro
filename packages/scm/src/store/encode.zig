//! The canonical binary encoding of zg-scm objects.
//!
//! The encoding is derived from the Zig type, field by field in declaration
//! order:
//! - struct: `u8 version` (currently 1), then its fields. Types declaring
//!   `encoding = .fixed_bytes` (ObjectId, ChangeId) are their raw bytes.
//! - unsigned integer: unsigned LEB128, minimal length.
//! - signed integer: zigzag, then as unsigned.
//! - bool: one byte, 0 or 1.
//! - enum: its integer value as a varint; must be a declared tag.
//! - `[]const u8`: varint length, then the bytes.
//! - other slices: varint count, then the elements.
//! - optional: presence byte 0 or 1, then the value if present.
//!
//! Decoding accepts only the encoding `encode` would produce (minimal
//! varints, 0/1 flags, known tags and versions, no trailing bytes) and runs
//! each struct's `validate`, so a value has exactly one encoding and one ID.
//! Decoded `[]const u8` fields point into the input; other slices are
//! allocated from the arena, never more than the input could describe.
//!
//! New fields go into `extra` (forward compatible, IDs unchanged) or come
//! with a version bump.

const std = @import("std");
const id_mod = @import("id.zig");
const object = @import("object.zig");
const ObjectId = id_mod.ObjectId;
const Kind = id_mod.Kind;
const Allocator = std.mem.Allocator;

/// The version byte every struct encoding starts with.
pub const version: u8 = 1;

/// Why bytes are not a canonical encoding.
pub const DecodeError = error{
    Truncated,
    TrailingBytes,
    NonCanonicalVarint,
    VarintOverflow,
    InvalidBool,
    InvalidTag,
    UnsupportedVersion,
    TooManyElements,
} || object.ValidateError || Allocator.Error;

/// Errors from `encode`.
pub const EncodeError = std.Io.Writer.Error || object.ValidateError;

fn isFixed(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "encoding") and T.encoding == .fixed_bytes;
}

/// Writes `v` as unsigned LEB128.
pub fn writeVarint(w: *std.Io.Writer, v: u64) std.Io.Writer.Error!void {
    if (v < 0x80) return w.writeByte(@intCast(v));
    var buf: [10]u8 = undefined;
    var n: usize = 0;
    var x = v;
    while (x >= 0x80) : (x >>= 7) {
        buf[n] = @as(u8, @truncate(x)) | 0x80;
        n += 1;
    }
    buf[n] = @truncate(x);
    try w.writeAll(buf[0 .. n + 1]);
}

fn zigzag(v: i64) u64 {
    return @bitCast((v << 1) ^ (v >> 63));
}

fn unzigzag(u: u64) i64 {
    return @as(i64, @bitCast(u >> 1)) ^ -@as(i64, @bitCast(u & 1));
}

/// Writes the canonical encoding of `value`.
pub fn encode(comptime T: type, value: T, w: *std.Io.Writer) EncodeError!void {
    switch (@typeInfo(T)) {
        .int => |info| {
            if (info.signedness == .signed) try writeVarint(w, zigzag(value)) else try writeVarint(w, value);
        },
        .bool => try w.writeByte(@intFromBool(value)),
        .@"enum" => try writeVarint(w, @intFromEnum(value)),
        .optional => |o| if (value) |v| {
            try w.writeByte(1);
            try encode(o.child, v, w);
        } else try w.writeByte(0),
        .pointer => |p| {
            comptime std.debug.assert(p.size == .slice);
            try writeVarint(w, value.len);
            if (p.child == u8) {
                try w.writeAll(value);
            } else for (value) |e| try encode(p.child, e, w);
        },
        .@"struct" => |s| {
            if (comptime isFixed(T)) return w.writeAll(&value.bytes);
            if (@hasDecl(T, "validate")) try value.validate();
            try w.writeByte(version);
            inline for (s.fields) |f| try encode(f.type, @field(value, f.name), w);
        },
        else => @compileError("no canonical encoding for " ++ @typeName(T)),
    }
}

/// `encode` into a new allocation.
pub fn encodeAlloc(gpa: Allocator, comptime T: type, value: T) (Allocator.Error || object.ValidateError)![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    encode(T, value, &aw.writer) catch |e| return switch (e) {
        error.WriteFailed => error.OutOfMemory,
        else => |x| x,
    };
    return aw.toOwnedSlice();
}

/// The ID of `value` (whose type declares its `kind`).
pub fn idOf(gpa: Allocator, comptime T: type, value: T) (Allocator.Error || object.ValidateError)!ObjectId {
    const bytes = try encodeAlloc(gpa, T, value);
    defer gpa.free(bytes);
    return id_mod.hashObject(T.kind, bytes);
}

/// The fewest bytes an encoded `T` can take; bounds element counts.
fn minSize(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        .int, .bool, .@"enum", .optional, .pointer => 1,
        .@"struct" => |s| comptime blk: {
            if (isFixed(T)) break :blk @typeInfo(@FieldType(T, "bytes")).array.len;
            var n: usize = 1;
            for (s.fields) |f| n += minSize(f.type);
            break :blk n;
        },
        else => @compileError("no canonical encoding for " ++ @typeName(T)),
    };
}

/// A cursor over canonical bytes.
pub const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn remaining(r: *const Reader) usize {
        return r.bytes.len - r.pos;
    }

    fn take(r: *Reader, n: usize) DecodeError![]const u8 {
        if (n > r.remaining()) return error.Truncated;
        defer r.pos += n;
        return r.bytes[r.pos..][0..n];
    }

    fn byte(r: *Reader) DecodeError!u8 {
        return (try r.take(1))[0];
    }

    /// A minimal-length unsigned LEB128.
    pub fn varint(r: *Reader) DecodeError!u64 {
        var v: u64 = 0;
        var shift: u7 = 0;
        while (true) {
            const b = try r.byte();
            const bits: u64 = b & 0x7f;
            if (shift == 63 and bits > 1) return error.VarintOverflow;
            v |= bits << @intCast(shift);
            if (b & 0x80 == 0) {
                // A zero final byte after others means a longer-than-needed form.
                if (b == 0 and shift > 0) return error.NonCanonicalVarint;
                return v;
            }
            shift += 7;
            if (shift > 63) return error.VarintOverflow;
        }
    }
};

fn decodeValue(comptime T: type, arena: Allocator, r: *Reader) DecodeError!T {
    switch (@typeInfo(T)) {
        .int => |info| {
            const u = try r.varint();
            if (info.signedness == .signed) {
                return std.math.cast(T, unzigzag(u)) orelse error.VarintOverflow;
            }
            return std.math.cast(T, u) orelse error.VarintOverflow;
        },
        .bool => return switch (try r.byte()) {
            0 => false,
            1 => true,
            else => error.InvalidBool,
        },
        .@"enum" => |e| {
            const v = std.math.cast(e.tag_type, try r.varint()) orelse return error.InvalidTag;
            return std.enums.fromInt(T, v) orelse error.InvalidTag;
        },
        .optional => |o| return switch (try r.byte()) {
            0 => null,
            1 => try decodeValue(o.child, arena, r),
            else => error.InvalidBool,
        },
        .pointer => |p| {
            const n = try r.varint();
            if (p.child == u8) return r.take(std.math.cast(usize, n) orelse return error.Truncated);
            if (n > r.remaining() / minSize(p.child)) return error.TooManyElements;
            const out = try arena.alloc(p.child, @intCast(n));
            for (out) |*e| e.* = try decodeValue(p.child, arena, r);
            return out;
        },
        .@"struct" => |s| {
            var v: T = undefined;
            if (comptime isFixed(T)) {
                @memcpy(&v.bytes, try r.take(v.bytes.len));
                return v;
            }
            if (try r.byte() != version) return error.UnsupportedVersion;
            inline for (s.fields) |f| @field(v, f.name) = try decodeValue(f.type, arena, r);
            if (@hasDecl(T, "validate")) try v.validate();
            return v;
        },
        else => @compileError("no canonical encoding for " ++ @typeName(T)),
    }
}

/// Decodes canonical `bytes` as a `T`. The result borrows `bytes` for its
/// byte strings and `arena` for its other slices.
pub fn decode(comptime T: type, arena: Allocator, bytes: []const u8) DecodeError!T {
    var r: Reader = .{ .bytes = bytes };
    const v = try decodeValue(T, arena, &r);
    if (r.pos != bytes.len) return error.TrailingBytes;
    return v;
}

/// Writes `value` as JSON, for debug dumps and golden files only (never
/// hashed). IDs print as hex, change IDs as reverse hex.
pub fn toJson(comptime T: type, value: T, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, w);
}

/// Parses JSON written by `toJson`; strings and slices live in `arena`.
pub fn fromJson(comptime T: type, arena: Allocator, text: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, arena, text, .{ .allocate = .alloc_always });
}

test "varint: minimal forms only" {
    const t = std.testing;
    var buf: [16]u8 = undefined;
    for ([_]u64{ 0, 1, 127, 128, 300, 1 << 35, std.math.maxInt(u64) }) |v| {
        var w: std.Io.Writer = .fixed(&buf);
        try writeVarint(&w, v);
        var r: Reader = .{ .bytes = w.buffered() };
        try t.expectEqual(v, try r.varint());
        try t.expectEqual(w.end, r.pos);
    }
    var r: Reader = .{ .bytes = &.{ 0x80, 0x00 } };
    try t.expectError(error.NonCanonicalVarint, r.varint());
    r = .{ .bytes = &.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x02 } };
    try t.expectError(error.VarintOverflow, r.varint());
    r = .{ .bytes = &.{0x80} };
    try t.expectError(error.Truncated, r.varint());
    for ([_]i64{ 0, -1, 1, -64, 64, std.math.minInt(i64), std.math.maxInt(i64) }) |v| try t.expectEqual(v, unzigzag(zigzag(v)));
}
