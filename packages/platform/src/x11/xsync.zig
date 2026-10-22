//! The SYNC extension's counters, for `_NET_WM_SYNC_REQUEST`
//! (E01.F05.S02.T01): the window manager asks for a value, and the client
//! sets its counter to it once it has drawn at the new size, so
//! compositing WMs resize without showing stale frames.

const std = @import("std");
const proto = @import("proto.zig");
const FdQueue = @import("../wayland/wire/fdqueue.zig").FdQueue;

/// SYNC Initialize; required before other SYNC requests.
pub const Initialize = struct {
    /// The extension that owns this request.
    pub const extension = "SYNC";
    /// The minor opcode.
    pub const minor = 0;
    desired_major: u8 = 3,
    desired_minor: u8 = 1,
    _pad: [2]u8 = .{ 0, 0 },

    /// The server's version.
    pub const Reply = struct {
        major: u8,
        minor: u8,
        /// Decodes the reply from its wire bytes.
        pub fn decode(b: []const u8, _: *FdQueue) proto.DecodeError!Reply {
            if (b.len < 32) return error.Malformed;
            return .{ .major = b[8], .minor = b[9] };
        }
    };
};

/// SYNC CreateCounter.
pub const CreateCounter = struct {
    /// The extension that owns this request.
    pub const extension = "SYNC";
    /// The minor opcode.
    pub const minor = 2;
    id: u32,
    hi: i32 = 0,
    lo: u32 = 0,
};

/// SYNC SetCounter.
pub const SetCounter = struct {
    /// The extension that owns this request.
    pub const extension = "SYNC";
    /// The minor opcode.
    pub const minor = 3;
    counter: u32,
    hi: i32,
    lo: u32,
};

/// SYNC QueryCounter (tests read the value back).
pub const QueryCounter = struct {
    /// The extension that owns this request.
    pub const extension = "SYNC";
    /// The minor opcode.
    pub const minor = 5;
    counter: u32,

    /// The counter's value.
    pub const Reply = struct {
        value: u64,
        /// Decodes the reply from its wire bytes.
        pub fn decode(b: []const u8, _: *FdQueue) proto.DecodeError!Reply {
            if (b.len < 32) return error.Malformed;
            return .{ .value = join(@bitCast(std.mem.readInt(u32, b[8..12], .little)), std.mem.readInt(u32, b[12..16], .little)) };
        }
    };
};

/// SYNC DestroyCounter.
pub const DestroyCounter = struct {
    /// The extension that owns this request.
    pub const extension = "SYNC";
    /// The minor opcode.
    pub const minor = 6;
    counter: u32,
};

/// A 64-bit counter value from its halves.
pub fn join(hi: i32, lo: u32) u64 {
    return (@as(u64, @as(u32, @bitCast(hi))) << 32) | lo;
}

/// `v` as SetCounter arguments.
pub fn split(v: u64) struct { hi: i32, lo: u32 } {
    return .{ .hi = @bitCast(@as(u32, @truncate(v >> 32))), .lo = @truncate(v) };
}

test "counter values split and join" {
    const v: u64 = 0x1_0000_0002;
    const s = split(v);
    try std.testing.expectEqual(1, s.hi);
    try std.testing.expectEqual(2, s.lo);
    try std.testing.expectEqual(v, join(s.hi, s.lo));
    try std.testing.expectEqual(0xffff_ffff_0000_0000, join(-1, 0));
}
