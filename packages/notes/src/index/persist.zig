//! A compact binary codec for plain data (E08.F06.S01.T02): note
//! metadata and the property registry are saved with it on idle and read
//! back at warm start. Encoding is driven by the type: integers, floats,
//! bools and enums as little-endian fixed width, packed structs as their
//! backing integer, slices with a u32 length, optionals with a tag byte,
//! tagged unions with a u16 tag index. Decoding allocates every slice in
//! the given arena.
//!
//! A file is `magic(4) version(u32) payload_len(u64) xxh3(u64) payload`.
//! A bad magic, version, length or checksum reads as `error.Stale`, and
//! callers rebuild from sources.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const magic = "ZGNI".*;

pub const Error = error{ Truncated, Invalid, OutOfMemory };

pub fn encode(comptime T: type, out: *std.ArrayList(u8), gpa: Allocator, v: T) Allocator.Error!void {
    switch (@typeInfo(T)) {
        .int => try out.appendSlice(gpa, std.mem.asBytes(&std.mem.nativeToLittle(T, v))),
        .float => |f| {
            const I = std.meta.Int(.unsigned, f.bits);
            try encode(I, out, gpa, @bitCast(v));
        },
        .bool => try out.append(gpa, @intFromBool(v)),
        .@"enum" => |e| try encode(e.tag_type, out, gpa, @intFromEnum(v)),
        .void => {},
        .optional => |o| if (v) |x| {
            try out.append(gpa, 1);
            try encode(o.child, out, gpa, x);
        } else try out.append(gpa, 0),
        .array => |a| for (v) |x| try encode(a.child, out, gpa, x),
        .pointer => |p| {
            comptime std.debug.assert(p.size == .slice);
            try encode(u32, out, gpa, @intCast(v.len));
            if (p.child == u8) {
                try out.appendSlice(gpa, v);
            } else for (v) |x| try encode(p.child, out, gpa, x);
        },
        .@"struct" => |s| {
            if (s.layout == .@"packed") return encode(s.backing_integer.?, out, gpa, @bitCast(v));
            inline for (s.fields) |f| try encode(f.type, out, gpa, @field(v, f.name));
        },
        .@"union" => |u| {
            const tag = std.meta.activeTag(v);
            try encode(u16, out, gpa, @intFromEnum(tag));
            inline for (u.fields) |f| {
                if (std.mem.eql(u8, f.name, @tagName(tag))) try encode(f.type, out, gpa, @field(v, f.name));
            }
        },
        else => @compileError("persist: unsupported type " ++ @typeName(T)),
    }
}

pub const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn take(r: *Reader, n: usize) Error![]const u8 {
        if (r.bytes.len - r.pos < n) return error.Truncated;
        defer r.pos += n;
        return r.bytes[r.pos..][0..n];
    }

    pub fn atEnd(r: *const Reader) bool {
        return r.pos == r.bytes.len;
    }
};

pub fn decode(comptime T: type, r: *Reader, arena: Allocator) Error!T {
    switch (@typeInfo(T)) {
        .int => {
            const b = try r.take(@sizeOf(T));
            return std.mem.littleToNative(T, std.mem.bytesToValue(T, b));
        },
        .float => |f| {
            const I = std.meta.Int(.unsigned, f.bits);
            return @bitCast(try decode(I, r, arena));
        },
        .bool => return (try r.take(1))[0] != 0,
        .@"enum" => |e| {
            const raw = try decode(e.tag_type, r, arena);
            return std.enums.fromInt(T, raw) orelse error.Invalid;
        },
        .void => return {},
        .optional => |o| return if ((try r.take(1))[0] != 0) try decode(o.child, r, arena) else null,
        .array => |a| {
            var out: T = undefined;
            for (&out) |*x| x.* = try decode(a.child, r, arena);
            return out;
        },
        .pointer => |p| {
            const n = try decode(u32, r, arena);
            if (p.child == u8) return try arena.dupe(u8, try r.take(n));
            if (n > r.bytes.len - r.pos) return error.Truncated;
            const items = try arena.alloc(p.child, n);
            for (items) |*x| x.* = try decode(p.child, r, arena);
            return items;
        },
        .@"struct" => |s| {
            if (s.layout == .@"packed") return @bitCast(try decode(s.backing_integer.?, r, arena));
            var out: T = undefined;
            inline for (s.fields) |f| @field(out, f.name) = try decode(f.type, r, arena);
            return out;
        },
        .@"union" => |u| {
            const Tag = u.tag_type.?;
            const raw = try decode(u16, r, arena);
            const tag = std.enums.fromInt(Tag, raw) orelse return error.Invalid;
            inline for (u.fields) |f| {
                if (std.mem.eql(u8, f.name, @tagName(tag))) return @unionInit(T, f.name, try decode(f.type, r, arena));
            }
            return error.Invalid;
        },
        else => @compileError("persist: unsupported type " ++ @typeName(T)),
    }
}

/// Wraps `payload` in the file header.
pub fn seal(gpa: Allocator, version: u32, payload: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = try .initCapacity(gpa, payload.len + 24);
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, &magic);
    try encode(u32, &out, gpa, version);
    try encode(u64, &out, gpa, payload.len);
    try encode(u64, &out, gpa, std.hash.XxHash3.hash(0, payload));
    try out.appendSlice(gpa, payload);
    return out.toOwnedSlice(gpa);
}

/// The payload of a sealed file, or `error.Stale`.
pub fn unseal(bytes: []const u8, version: u32) error{Stale}![]const u8 {
    if (bytes.len < 24 or !std.mem.eql(u8, bytes[0..4], &magic)) return error.Stale;
    if (std.mem.readInt(u32, bytes[4..8], .little) != version) return error.Stale;
    const len = std.mem.readInt(u64, bytes[8..16], .little);
    if (len != bytes.len - 24) return error.Stale;
    const payload = bytes[24..];
    if (std.mem.readInt(u64, bytes[16..24], .little) != std.hash.XxHash3.hash(0, payload)) return error.Stale;
    return payload;
}

test "persist: roundtrip" {
    const T = struct {
        a: u32,
        b: []const u8,
        c: ?i64,
        d: []const struct { x: f64, y: enum { p, q } },
        e: union(enum) { none, s: []const u8, n: u16 },
        f: packed struct(u16) { lo: u8, hi: u8 },
    };
    const v: T = .{ .a = 7, .b = "hi", .c = -3, .d = &.{ .{ .x = 1.5, .y = .q }, .{ .x = -2, .y = .p } }, .e = .{ .s = "u" }, .f = .{ .lo = 1, .hi = 2 } };
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try encode(T, &buf, gpa, v);
    const sealed = try seal(gpa, 3, buf.items);
    defer gpa.free(sealed);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var r: Reader = .{ .bytes = try unseal(sealed, 3) };
    const back = try decode(T, &r, arena.allocator());
    try std.testing.expect(r.atEnd());
    try std.testing.expectEqualStrings("hi", back.b);
    try std.testing.expectEqual(@as(?i64, -3), back.c);
    try std.testing.expectEqual(@as(f64, -2), back.d[1].x);
    try std.testing.expectEqualStrings("u", back.e.s);
    try std.testing.expectEqual(@as(u8, 2), back.f.hi);
    try std.testing.expectError(error.Stale, unseal(sealed, 4));
    sealed[30] ^= 1;
    try std.testing.expectError(error.Stale, unseal(sealed, 3));
    var short: Reader = .{ .bytes = buf.items[0..5] };
    try std.testing.expectError(error.Truncated, decode(T, &short, arena.allocator()));
}
