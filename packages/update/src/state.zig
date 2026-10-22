//! Persistent updater state (`update.*`): last accepted serial and ETag per
//! channel, the random install id, skipped versions and the last check
//! time. Serialized as ZON; E15's `StateStore` will own the file once it
//! lands, until then callers persist `writeZon` output themselves.
//! `install_id` is never transmitted: we only GET static files.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Per-channel metadata freshness state.
pub const ChannelState = struct {
    channel: []const u8,
    last_serial: u64 = 0,
    etag: []const u8 = "",
};

/// The whole updater state.
pub const State = struct {
    /// 16 random bytes, created on first use.
    install_id: [16]u8 = @splat(0),
    channels: []const ChannelState = &.{},
    /// Versions the user chose to skip.
    skipped: []const []const u8 = &.{},
    last_check_unix: i64 = 0,

    /// The state of `channel`, or defaults.
    pub fn channelState(s: *const State, channel: []const u8) ChannelState {
        for (s.channels) |c| if (std.mem.eql(u8, c.channel, channel)) return c;
        return .{ .channel = channel };
    }

    /// A copy with `channel` updated; allocates the new channel slice.
    pub fn withChannel(s: State, arena: Allocator, cs: ChannelState) Allocator.Error!State {
        var list: std.ArrayList(ChannelState) = .empty;
        var replaced = false;
        for (s.channels) |c| {
            if (std.mem.eql(u8, c.channel, cs.channel)) {
                try list.append(arena, cs);
                replaced = true;
            } else try list.append(arena, c);
        }
        if (!replaced) try list.append(arena, cs);
        var out = s;
        out.channels = list.items;
        return out;
    }

    /// True when `id` is all zeros (not yet created).
    pub fn needsInstallId(s: *const State) bool {
        return std.mem.allEqual(u8, &s.install_id, 0);
    }

    /// True when the user skipped `version_text`.
    pub fn isSkipped(s: *const State, version_text: []const u8) bool {
        for (s.skipped) |v| if (std.mem.eql(u8, v, version_text)) return true;
        return false;
    }

    /// Writes the state as ZON.
    pub fn writeZon(s: *const State, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try std.zon.stringify.serialize(s.*, .{}, w);
        try w.writeByte('\n');
    }

    /// Parses ZON written by `writeZon`. Allocations go to `arena`.
    pub fn parseZon(arena: Allocator, text: [:0]const u8) error{ OutOfMemory, ParseZon }!State {
        return std.zon.parse.fromSliceAlloc(State, arena, text, null, .{});
    }
};

test "state: zon roundtrip and channel update" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: State = .{};
    try std.testing.expect(s.needsInstallId());
    s.install_id = @splat(7);
    s = try s.withChannel(a, .{ .channel = "stable", .last_serial = 5, .etag = "\"abc\"" });
    s = try s.withChannel(a, .{ .channel = "insiders", .last_serial = 9 });
    s = try s.withChannel(a, .{ .channel = "stable", .last_serial = 6, .etag = "\"abd\"" });
    s.skipped = &.{"0.4.0"};
    s.last_check_unix = 1761016620;

    var buf: std.Io.Writer.Allocating = .init(a);
    try s.writeZon(&buf.writer);
    const text = try a.dupeZ(u8, buf.written());
    const p = try State.parseZon(a, text);
    try std.testing.expectEqual(@as(u64, 6), p.channelState("stable").last_serial);
    try std.testing.expectEqualStrings("\"abd\"", p.channelState("stable").etag);
    try std.testing.expectEqual(@as(u64, 9), p.channelState("insiders").last_serial);
    try std.testing.expectEqual(@as(u64, 0), p.channelState("rc").last_serial);
    try std.testing.expect(p.isSkipped("0.4.0"));
    try std.testing.expect(!p.needsInstallId());
    try std.testing.expectEqual(@as(i64, 1761016620), p.last_check_unix);
}
