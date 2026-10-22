//! Field-wise hashing of props and styles. Unlike `std.hash.autoHash` it
//! accepts floats (hashed by bit pattern) and never reads padding bytes.
//! Slices hash their contents; single-item pointers hash their address, so
//! a widget whose props point at large shared data stays cheap to hash.
//!
//! Scalars are folded in one 64-bit word at a time with a wyhash-style
//! multiply-mix (no buffering), which keeps the hash of a whole `Style`
//! in the tens of nanoseconds; byte slices go through one-shot Wyhash.

const std = @import("std");

/// A streaming word hasher.
pub const Hasher = struct {
    h: u64 = 0x4704_6a5e_a076_1d64,

    /// Folds one word in.
    pub inline fn word(st: *Hasher, x: u64) void {
        st.h = mum(st.h ^ x, 0xe703_7ed1_a0b4_28db);
    }

    /// Folds a byte string in.
    pub fn bytes(st: *Hasher, b: []const u8) void {
        st.word(std.hash.Wyhash.hash(st.h, b));
    }

    /// The final value.
    pub fn final(st: Hasher) u64 {
        return mum(st.h, 0x8ebc_6af0_9c88_c6e3);
    }

    inline fn mum(a: u64, b: u64) u64 {
        const r = @as(u128, a) *% b;
        return @as(u64, @truncate(r)) ^ @as(u64, @truncate(r >> 64));
    }
};

/// The hash of `v`.
pub fn of(v: anytype) u64 {
    var h: Hasher = .{};
    add(&h, v);
    return h.final();
}

/// Feeds `v` into `h`.
pub fn add(h: *Hasher, v: anytype) void {
    const T = @TypeOf(v);
    switch (@typeInfo(T)) {
        .void, .null => {},
        .bool => h.word(@intFromBool(v)),
        .int => |i| if (i.bits <= 64) {
            h.word(@as(u64, @as(std.meta.Int(.unsigned, i.bits), @bitCast(v))));
        } else h.bytes(std.mem.asBytes(&v)),
        .comptime_int => add(h, @as(i64, v)),
        .float => |f| {
            const I = std.meta.Int(.unsigned, f.bits);
            // +0 and -0 compare equal, so hash them equally.
            const bits: I = if (v == 0) 0 else @bitCast(v);
            add(h, bits);
        },
        .comptime_float => add(h, @as(f64, v)),
        .@"enum" => add(h, @intFromEnum(v)),
        .optional => if (v) |x| {
            h.word(1);
            add(h, x);
        } else h.word(0),
        .array => for (v) |x| add(h, x),
        .vector => |vi| {
            var i: usize = 0;
            while (i < vi.len) : (i += 1) add(h, v[i]);
        },
        .@"struct" => |s| {
            if (s.layout == .@"packed") {
                add(h, @as(s.backing_integer.?, @bitCast(v)));
            } else inline for (s.fields) |f| {
                if (!f.is_comptime) add(h, @field(v, f.name));
            }
        },
        .@"union" => |u| {
            if (u.tag_type == null) @compileError("hash: untagged union " ++ @typeName(T));
            add(h, std.meta.activeTag(v));
            switch (v) {
                inline else => |x| add(h, x),
            }
        },
        .pointer => |p| switch (p.size) {
            .slice => {
                add(h, v.len);
                if (comptime isBytes(p.child)) {
                    h.bytes(std.mem.sliceAsBytes(v));
                } else for (v) |x| add(h, x);
            },
            .one => if (@typeInfo(p.child) == .array) add(h, v.*) else add(h, @intFromPtr(v)),
            else => add(h, @intFromPtr(v)),
        },
        .@"fn" => {},
        else => @compileError("hash: unsupported type " ++ @typeName(T)),
    }
}

fn isBytes(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int => |i| i.bits % 8 == 0,
        .bool => true,
        else => false,
    };
}

test "floats, optionals and slices" {
    const P = struct { a: f32, b: ?u8, s: []const u8, e: enum { x, y } };
    const one: P = .{ .a = 1.5, .b = null, .s = "hi", .e = .x };
    var two = one;
    try std.testing.expectEqual(of(one), of(two));
    two.s = "ho";
    try std.testing.expect(of(one) != of(two));
    two = one;
    two.b = 0;
    try std.testing.expect(of(one) != of(two));
    try std.testing.expectEqual(of(@as(f32, 0.0)), of(@as(f32, -0.0)));
}

test "slice contents not address" {
    var buf: [3]u8 = "abc".*;
    const a: []const u8 = buf[0..];
    try std.testing.expectEqual(of(a), of(@as([]const u8, "abc")));
}

test "word order matters" {
    const P = struct { a: u8, b: u8 };
    try std.testing.expect(of(P{ .a = 1, .b = 2 }) != of(P{ .a = 2, .b = 1 }));
}
