//! Extensions queried at connect time, and their cached opcodes and
//! event/error bases.

const std = @import("std");

/// What QueryExtension reported for a present extension.
pub const ExtInfo = struct {
    major_opcode: u8,
    first_event: u8,
    first_error: u8,
};

/// Queried (pipelined) during `Conn.connect`.
pub const startup = [_][]const u8{
    "BIG-REQUESTS",
    "XKEYBOARD",
    "XInputExtension",
    "RANDR",
    "MIT-SHM",
    "DRI3",
    "Present",
    "SYNC",
    "RENDER",
    "XFIXES",
    "XTEST",
};

/// Index of `name` in `startup`.
pub fn index(name: []const u8) ?usize {
    for (startup, 0..) |n, i| if (std.mem.eql(u8, n, name)) return i;
    return null;
}

/// Which extension, if any, owns event code `code` (core events are
/// below 64; the extension with the highest first_event at or below the
/// code owns it).
pub fn eventOwner(infos: []const ?ExtInfo, code: u8) ?usize {
    if (code < 64) return null;
    var best: ?usize = null;
    for (infos, 0..) |maybe, i| {
        const info = maybe orelse continue;
        if (info.first_event == 0 or info.first_event > code) continue;
        if (best == null or infos[best.?].?.first_event < info.first_event) best = i;
    }
    return best;
}

test "event owner by base" {
    var infos: [startup.len]?ExtInfo = @splat(null);
    infos[index("XKEYBOARD").?] = .{ .major_opcode = 135, .first_event = 85, .first_error = 137 };
    infos[index("RANDR").?] = .{ .major_opcode = 140, .first_event = 89, .first_error = 147 };
    try std.testing.expectEqual(index("XKEYBOARD"), eventOwner(&infos, 85));
    try std.testing.expectEqual(index("RANDR"), eventOwner(&infos, 90));
    try std.testing.expectEqual(null, eventOwner(&infos, 12));
}
