//! `wl_output` state: geometry, current mode, scale and name, gathered
//! until `done` and then published as a `MonitorInfo`.

const std = @import("std");
const wl = @import("wl_gen");
const types = @import("../api/types.zig");
const MonitorInfo = types.MonitorInfo;

/// One bound `wl_output`.
pub const Output = struct {
    /// The registry name of the global.
    global: u32,
    /// The bound object.
    id: wl.wl_output.Id,
    /// The integer scale (`wl_output.scale`); 1 until sent.
    scale: i32 = 1,
    /// The published state; valid once `ready`.
    info: MonitorInfo,
    /// Whether one `done` has arrived.
    ready: bool = false,
    pending: MonitorInfo,
    pending_scale: i32 = 1,
    transform: wl.wl_output.Transform = @enumFromInt(0),
    have_name: bool = false,

    /// A fresh output for global `global` bound as `id`.
    pub fn init(global: u32, id: wl.wl_output.Id) Output {
        const blank: MonitorInfo = .{
            .id = global,
            .rect_px = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            .work_px = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            .scale = .{},
            .refresh_mhz = 0,
            .primary = false,
        };
        return .{ .global = global, .id = id, .info = blank, .pending = blank };
    }

    /// Applies one event; returns true on `done`, when `info` changed.
    pub fn apply(o: *Output, ev: wl.wl_output.Event) bool {
        switch (ev) {
            .geometry => |g| {
                o.transform = g.transform;
                if (!o.have_name) setName(&o.pending, g.make, g.model);
            },
            .mode => |m| if (m.flags.current) {
                o.pending.rect_px.w = @intCast(@max(0, m.width));
                o.pending.rect_px.h = @intCast(@max(0, m.height));
                o.pending.refresh_mhz = @intCast(@max(0, m.refresh));
            },
            .scale => |s| o.pending_scale = @max(1, s.factor),
            .name => |n| {
                o.have_name = true;
                setName(&o.pending, n.name, "");
            },
            .description => {},
            .done => {
                var info = o.pending;
                // Transforms 90 and 270 (and their flipped forms) rotate the mode.
                if (@intFromEnum(o.transform) & 1 == 1) std.mem.swap(u32, &info.rect_px.w, &info.rect_px.h);
                info.work_px = info.rect_px;
                info.scale = .{ .factor = @floatFromInt(o.pending_scale) };
                o.scale = o.pending_scale;
                o.info = info;
                o.ready = true;
                return true;
            },
        }
        return false;
    }
};

fn setName(m: *MonitorInfo, a: []const u8, b: []const u8) void {
    var len: usize = @min(a.len, m.name_buf.len);
    @memcpy(m.name_buf[0..len], a[0..len]);
    if (b.len > 0 and len < m.name_buf.len) {
        m.name_buf[len] = ' ';
        len += 1;
        const n = @min(b.len, m.name_buf.len - len);
        @memcpy(m.name_buf[len..][0..n], b[0..n]);
        len += n;
    }
    m.name_len = @intCast(len);
}

const testing = std.testing;

test "output publishes on done, with rotation and the name event" {
    var o: Output = .init(7, @enumFromInt(9));
    try testing.expect(!o.apply(.{ .geometry = .{ .x = 0, .y = 0, .physical_width = 600, .physical_height = 340, .subpixel = @enumFromInt(0), .make = "ACME", .model = "View", .transform = @enumFromInt(1) } }));
    try testing.expect(!o.apply(.{ .mode = .{ .flags = .{ .current = false }, .width = 800, .height = 600, .refresh = 60000 } }));
    try testing.expect(!o.apply(.{ .mode = .{ .flags = .{ .current = true }, .width = 2560, .height = 1440, .refresh = 143912 } }));
    try testing.expect(!o.apply(.{ .scale = .{ .factor = 2 } }));
    try testing.expect(!o.ready);
    try testing.expect(o.apply(.done));
    try testing.expect(o.ready);
    try testing.expectEqual(@as(u32, 1440), o.info.rect_px.w);
    try testing.expectEqual(@as(u32, 2560), o.info.rect_px.h);
    try testing.expectEqual(@as(u32, 143912), o.info.refresh_mhz);
    try testing.expectEqual(@as(f32, 2), o.info.scale.factor);
    try testing.expectEqual(@as(i32, 2), o.scale);
    try testing.expectEqualStrings("ACME View", o.info.name());
    _ = o.apply(.{ .name = .{ .name = "DP-1" } });
    _ = o.apply(.{ .geometry = .{ .x = 0, .y = 0, .physical_width = 0, .physical_height = 0, .subpixel = @enumFromInt(0), .make = "X", .model = "Y", .transform = @enumFromInt(0) } });
    try testing.expect(o.apply(.done));
    try testing.expectEqualStrings("DP-1", o.info.name());
    try testing.expectEqual(@as(u32, 2560), o.info.rect_px.w);
}
