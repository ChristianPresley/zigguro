//! Parsed control-sequence records handed to parser handlers: `Csi` (CSI and
//! DCS headers, with colon sub-parameters), `Esc` and the string terminator.

const std = @import("std");

/// Maximum number of parameters (including sub-parameters) kept per sequence.
/// Further parameters set `Csi.overflow` and are dropped; xterm likewise
/// dispatches with the first N.
pub const max_params = 32;

/// Maximum number of intermediate bytes (0x20-0x2F) kept per sequence. A
/// sequence with more is ignored entirely, as Williams' parser does.
pub const max_intermediates = 2;

/// A CSI (or DCS header): parameters, private marker, intermediates and the
/// final byte.
pub const Csi = struct {
    /// Parameter values, saturated at 65535. Only `params[0..count]` is valid.
    params: [max_params]u16 = @splat(0),
    /// Number of parameters, counting empty ones (`ESC[;5H` has 2).
    count: u8 = 0,
    /// Bit i is set when param i was introduced by ':' (it is a sub-parameter
    /// of the nearest preceding param whose bit is clear).
    colon_mask: u32 = 0,
    /// Bit i is set when param i had at least one digit; distinguishes an
    /// empty param from an explicit 0.
    has_value: u32 = 0,
    /// The private marker: one of 0, '?', '>', '<', '='.
    private: u8 = 0,
    /// Intermediate bytes, in order.
    inter: [max_intermediates]u8 = .{ 0, 0 },
    /// Number of valid bytes in `inter`.
    inter_len: u2 = 0,
    /// The final byte (0x40-0x7E).
    final: u8 = 0,
    /// More than `max_params` parameters were present.
    overflow: bool = false,

    /// Param `i`, or `default` when it is missing or empty. Callers that
    /// treat an explicit 0 as the default (most cursor functions) check that
    /// themselves.
    pub fn get(c: *const Csi, i: usize, default: u16) u16 {
        if (i >= c.count) return default;
        if (c.has_value & (@as(u32, 1) << @intCast(i)) == 0) return default;
        return c.params[i];
    }

    /// Whether param `i` was introduced by ':'.
    pub fn isSub(c: *const Csi, i: usize) bool {
        if (i >= c.count) return false;
        return c.colon_mask & (@as(u32, 1) << @intCast(i)) != 0;
    }

    /// The intermediate bytes as a slice.
    pub fn intermediates(c: *const Csi) []const u8 {
        return c.inter[0..c.inter_len];
    }

    /// Resets to the empty sequence (Williams "clear").
    pub fn clear(c: *Csi) void {
        c.* = .{};
    }

    /// Accumulates a digit into the current param with saturation at 65535.
    pub fn digit(c: *Csi, d: u8) void {
        if (c.count == 0) c.count = 1;
        if (c.overflow) return;
        const i = c.count - 1;
        const v: u32 = @as(u32, c.params[i]) * 10 + d;
        c.params[i] = @intCast(@min(v, std.math.maxInt(u16)));
        c.has_value |= @as(u32, 1) << @intCast(i);
    }

    /// Starts a new param after ';' (`sub = false`) or ':' (`sub = true`).
    pub fn separator(c: *Csi, sub: bool) void {
        if (c.count == 0) c.count = 1;
        if (c.overflow) return;
        if (c.count == max_params) {
            c.overflow = true;
            return;
        }
        c.params[c.count] = 0;
        if (sub) c.colon_mask |= @as(u32, 1) << @intCast(c.count);
        c.count += 1;
    }
};

/// An escape sequence: intermediates and final byte.
pub const Esc = struct {
    /// Intermediate bytes, in order.
    inter: [max_intermediates]u8 = .{ 0, 0 },
    /// Number of valid bytes in `inter`.
    inter_len: u2 = 0,
    /// The final byte (0x30-0x7E).
    final: u8 = 0,

    /// The intermediate bytes as a slice.
    pub fn intermediates(e: *const Esc) []const u8 {
        return e.inter[0..e.inter_len];
    }
};

/// How an OSC string was terminated. Replies reuse the requester's
/// terminator, as xterm does.
pub const StringTerm = enum { st, bel };

test "Csi.get distinguishes empty from zero and applies defaults" {
    var c: Csi = .{};
    c.separator(false); // ";" → two empty params
    c.digit(0);
    try std.testing.expectEqual(@as(u8, 2), c.count);
    try std.testing.expectEqual(@as(u16, 7), c.get(0, 7));
    try std.testing.expectEqual(@as(u16, 0), c.get(1, 7));
    try std.testing.expectEqual(@as(u16, 9), c.get(5, 9));
}

test "Csi.digit saturates" {
    var c: Csi = .{};
    for ("999999") |d| c.digit(d - '0');
    try std.testing.expectEqual(@as(u16, 65535), c.get(0, 0));
}
