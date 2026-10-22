//! RandR 1.5 monitors (E01.F05.S02.T01): `RRGetMonitors` lists the
//! monitors as the user arranged them, and `RRScreenChangeNotify` says
//! the layout changed.

const std = @import("std");
const types = @import("../api/types.zig");
const proto = @import("proto.zig");
const FdQueue = @import("../wayland/wire/fdqueue.zig").FdQueue;

/// RANDR QueryVersion; required before other RANDR requests.
pub const QueryVersion = struct {
    /// The extension that owns this request.
    pub const extension = "RANDR";
    /// The minor opcode.
    pub const minor = 0;
    client_major: u32 = 1,
    client_minor: u32 = 5,

    /// The server's version.
    pub const Reply = struct {
        major: u32,
        minor: u32,
        /// Decodes the reply from its wire bytes.
        pub fn decode(b: []const u8, _: *FdQueue) proto.DecodeError!Reply {
            if (b.len < 32) return error.Malformed;
            return .{ .major = std.mem.readInt(u32, b[8..12], .little), .minor = std.mem.readInt(u32, b[12..16], .little) };
        }
    };
};

/// RANDR SelectInput.
pub const SelectInput = struct {
    /// The extension that owns this request.
    pub const extension = "RANDR";
    /// The minor opcode.
    pub const minor = 4;
    window: u32,
    /// `NotifyMask` bits.
    enable: u16,
    _pad: [2]u8 = .{ 0, 0 },
};

/// RANDR SelectInput bits.
pub const NotifyMask = struct {
    /// `RRScreenChangeNotify`, event `first_event + 0`.
    pub const screen_change: u16 = 1;
    /// `RRNotify` CrtcChange, OutputChange and ResourceChange, event
    /// `first_event + 1`.
    pub const crtc_change: u16 = 2;
    /// See `crtc_change`.
    pub const output_change: u16 = 4;
    /// See `crtc_change`; RandR 1.4+ (monitors added with SetMonitor).
    pub const resource_change: u16 = 64;
    /// Everything that can move or add a monitor.
    pub const layout: u16 = screen_change | crtc_change | output_change | resource_change;
};

/// True when an `RRNotify` subcode (byte 1 of event `first_event + 1`)
/// can change the monitors: CrtcChange, OutputChange, ResourceChange.
pub fn notifyChangesLayout(subcode: u8) bool {
    return subcode == 0 or subcode == 1 or subcode == 5;
}

/// RANDR GetMonitors (1.5).
pub const GetMonitors = struct {
    /// The extension that owns this request.
    pub const extension = "RANDR";
    /// The minor opcode.
    pub const minor = 42;
    window: u32,
    get_active: bool = true,
    _pad: [3]u8 = .{ 0, 0, 0 },

    /// The raw reply; `parseMonitors` reads it.
    pub const Reply = struct {
        bytes: []const u8,
        /// Keeps a view of the reply's bytes.
        pub fn decode(b: []const u8, _: *FdQueue) proto.DecodeError!Reply {
            if (b.len < 32) return error.Malformed;
            return .{ .bytes = b };
        }
    };
};

/// One monitor from `RRGetMonitors`.
pub const Monitor = struct {
    /// The monitor's name atom (stable while it is connected).
    name: u32,
    primary: bool,
    rect: types.PxRect,
    mm: [2]u32,
};

/// Reads the monitors in a GetMonitors reply into `out`; returns how
/// many there were (at most `out.len` are stored).
pub fn parseMonitors(b: []const u8, out: []Monitor) proto.DecodeError!usize {
    if (b.len < 32) return error.Malformed;
    const n = std.mem.readInt(u32, b[12..16], .little);
    var pos: usize = 32;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (pos + 24 > b.len) return error.Malformed;
        const r = b[pos..][0..24];
        const outputs = std.mem.readInt(u16, r[6..8], .little);
        if (i < out.len) out[i] = .{
            .name = std.mem.readInt(u32, r[0..4], .little),
            .primary = r[4] != 0,
            .rect = .{
                .x = std.mem.readInt(i16, r[8..10], .little),
                .y = std.mem.readInt(i16, r[10..12], .little),
                .w = std.mem.readInt(u16, r[12..14], .little),
                .h = std.mem.readInt(u16, r[14..16], .little),
            },
            .mm = .{ std.mem.readInt(u32, r[16..20], .little), std.mem.readInt(u32, r[20..24], .little) },
        };
        pos += 24 + @as(usize, outputs) * 4;
    }
    if (pos > b.len) return error.Malformed;
    return n;
}

const testing = std.testing;

test "GetMonitors reply parsing" {
    var b: [32 + 24 + 8 + 24]u8 = @splat(0);
    std.mem.writeInt(u32, b[12..16], 2, .little);
    // DP-1: primary, 2 outputs, 2560x1440 at (0,0), 600x340 mm.
    var r = b[32..][0..24];
    std.mem.writeInt(u32, r[0..4], 300, .little);
    r[4] = 1;
    std.mem.writeInt(u16, r[6..8], 2, .little);
    std.mem.writeInt(u16, r[12..14], 2560, .little);
    std.mem.writeInt(u16, r[14..16], 1440, .little);
    std.mem.writeInt(u32, r[16..20], 600, .little);
    std.mem.writeInt(u32, r[20..24], 340, .little);
    // HDMI-1 to the left at (-1920, 100).
    r = b[32 + 24 + 8 ..][0..24];
    std.mem.writeInt(u32, r[0..4], 301, .little);
    std.mem.writeInt(i16, r[8..10], -1920, .little);
    std.mem.writeInt(i16, r[10..12], 100, .little);
    std.mem.writeInt(u16, r[12..14], 1920, .little);
    std.mem.writeInt(u16, r[14..16], 1080, .little);

    var out: [4]Monitor = undefined;
    try testing.expectEqual(2, try parseMonitors(&b, &out));
    try testing.expectEqual(Monitor{ .name = 300, .primary = true, .rect = .{ .x = 0, .y = 0, .w = 2560, .h = 1440 }, .mm = .{ 600, 340 } }, out[0]);
    try testing.expectEqual(types.PxRect{ .x = -1920, .y = 100, .w = 1920, .h = 1080 }, out[1].rect);
    try testing.expect(!out[1].primary);
    // A short buffer or a count past the end.
    try testing.expectError(error.Malformed, parseMonitors(b[0 .. b.len - 1], &out));
    std.mem.writeInt(u32, b[12..16], 3, .little);
    try testing.expectError(error.Malformed, parseMonitors(&b, &out));
    // More monitors than room: the count, with the first stored.
    std.mem.writeInt(u32, b[12..16], 2, .little);
    try testing.expectEqual(2, try parseMonitors(&b, out[0..1]));
}
