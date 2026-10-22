//! One Wayland toplevel: its protocol objects and the configure, state
//! and scale bookkeeping. The backend does the I/O; this file decides what
//! a configure means, so it can be tested without a compositor.
//!
//! Configures are not acked when they arrive. `onConfigure` records the
//! serial in `pending_ack`; the next present acks it right before the
//! attach and commit of a buffer at the new size, or the backend acks it
//! without a buffer once `ack_deadline_ns` passes.

const std = @import("std");
const wl = @import("wl_gen");
const types = @import("../api/types.zig");
const window_api = @import("../api/window.zig");
const scale = @import("scale.zig");
const csd = @import("csd.zig");

const PxSize = types.PxSize;
const WindowId = types.WindowId;
const WindowState = window_api.WindowState;

/// Longest title sent to the compositor, in bytes.
pub const max_title = 4096;

/// Most outputs a surface is tracked on at once.
pub const max_entered = 8;

/// What the compositor lets the window do (`xdg_toplevel.wm_capabilities`).
/// Everything is allowed until the compositor says otherwise.
pub const WmCapabilities = packed struct(u8) {
    /// A window menu can be shown.
    window_menu: bool = true,
    /// The window can be maximized.
    maximize: bool = true,
    /// The window can be fullscreen.
    fullscreen: bool = true,
    /// The window can be minimized.
    minimize: bool = true,
    _pad: u4 = 0,
};

/// The window-level result of a configure, for `Event.window_configure`.
pub const Configured = struct {
    /// Buffer size to render at.
    size: PxSize,
    /// Scale of that buffer over the logical size.
    scale: types.Scale,
    /// The new state.
    state: WindowState,
    /// The serial to pass back in the present's `ConfigureAck`.
    serial: u32,
    /// Set when `suspended` changed: the new occlusion.
    occluded: ?bool,
};

/// One toplevel window.
pub const Window = struct {
    /// The public id.
    id: WindowId,
    /// The `wl_surface`.
    surface: wl.wl_surface.Id,
    /// Its `xdg_surface` role.
    xdg_surface: wl.xdg_surface.Id,
    /// Its `xdg_toplevel`.
    toplevel: wl.xdg_toplevel.Id,
    /// The viewport, when `wp_viewporter` exists.
    viewport: ?wl.wp_viewport.Id = null,
    /// The fractional-scale object, when the manager exists.
    frac: ?wl.wp_fractional_scale_v1.Id = null,
    /// The outstanding frame callback.
    frame_cb: ?wl.wl_callback.Id = null,
    /// Logical size used when a configure leaves it to the client.
    default_logical: PxSize,
    /// The current logical size (surface coordinates).
    logical: PxSize,
    /// Minimum logical size.
    min_logical: ?PxSize = null,
    /// The current scale, in 1/120 units.
    scale120: u32 = scale.unit,
    /// The last `preferred_scale` from `wp_fractional_scale_v1`.
    frac_scale: ?u32 = null,
    /// The last `wl_surface.preferred_buffer_scale`.
    preferred_buffer: ?i32 = null,
    /// Outputs the surface is on (`wl_surface.enter`).
    entered: [max_entered]wl.wl_output.Id = undefined,
    entered_len: u8 = 0,
    /// The current state.
    state: WindowState = .{},
    /// The last configure serial, acked or not.
    serial: u32 = 0,
    /// A configure serial not yet acked.
    pending_ack: ?u32 = null,
    /// When to ack `pending_ack` without a buffer (monotonic ns).
    ack_deadline_ns: u64 = 0,
    /// The buffer scale last set on the surface.
    applied_buffer_scale: i32 = 1,
    /// The viewport destination last set.
    applied_destination: ?PxSize = null,
    /// What the compositor allows.
    wm_caps: WmCapabilities = .{},
    /// Whether the window is reported as occluded.
    occluded: bool = false,
    /// Whether a configure has been seen (the window can map).
    configured: bool = false,
    /// Toplevel fields buffered until `xdg_surface.configure`.
    pending: Pending = .{},
    /// The app asked for a frame before the first configure; it is
    /// answered when the configure arrives.
    frame_requested: bool = false,
    /// A buffer has been attached: the surface is mapped and frame
    /// callbacks fire. Before that, frames are answered at once.
    presented: bool = false,
    /// The window draws its own decorations (no server-side mode
    /// negotiated); takes effect at the next configure.
    csd: bool = false,
    /// The CSD margins around the visible window, in logical pixels
    /// (zero for server-side decorations).
    margins: csd.Margins = .{},
    /// The `zxdg_toplevel_decoration_v1`, when the manager exists.
    decoration: ?wl.zxdg_toplevel_decoration_v1.Id = null,
    /// The window geometry and input rectangle last sent (CSD only).
    applied_geometry: ?[4]i32 = null,
    applied_input: ?[4]i32 = null,
    /// The decorations last reported with `window_decorations`.
    reported_client: ?bool = null,
    reported_margins: [4]u32 = .{ 0, 0, 0, 0 },

    /// `xdg_toplevel.configure` fields waiting for the surface configure.
    pub const Pending = struct {
        /// The suggested size; 0 in a dimension leaves it to the client.
        w: u32 = 0,
        /// See `w`.
        h: u32 = 0,
        /// The states, as decoded.
        state: WindowState = .{},
        /// Whether a toplevel configure arrived since the last surface one.
        have: bool = false,
    };

    /// Buffers `xdg_toplevel.configure`.
    pub fn onToplevelConfigure(w: *Window, width: i32, height: i32, states: []const u8) void {
        w.pending = .{ .w = @intCast(@max(0, width)), .h = @intCast(@max(0, height)), .state = statesFrom(states), .have = true };
    }

    /// Applies `xdg_surface.configure(serial)` at time `now_ns`, with the
    /// ack falling due `ack_timeout_ns` later.
    pub fn onConfigure(w: *Window, serial: u32, now_ns: u64, ack_timeout_ns: u64) Configured {
        var occluded: ?bool = null;
        if (w.pending.have) {
            const p = w.pending;
            var size: PxSize = .{ .w = if (p.w != 0) p.w else w.logical.w, .h = if (p.h != 0) p.h else w.logical.h };
            const floating = !p.state.maximized and !p.state.fullscreen and !tiled(p.state);
            if (floating) if (w.min_logical) |m| {
                size = .{ .w = @max(size.w, m.w), .h = @max(size.h, m.h) };
            };
            w.logical = .{ .w = @max(1, size.w), .h = @max(1, size.h) };
            if (p.state.suspended != w.state.suspended) {
                w.occluded = p.state.suspended;
                occluded = w.occluded;
            }
            w.state = p.state;
            w.pending.have = false;
        }
        w.margins = if (w.csd) csd.margins(w.state, csd.default_margin) else .{};
        w.serial = serial;
        w.pending_ack = serial;
        w.ack_deadline_ns = now_ns + ack_timeout_ns;
        w.configured = true;
        return .{ .size = w.bufferSize(), .scale = scale.factor(w.scale120), .state = w.state, .serial = serial, .occluded = occluded };
    }

    /// Recomputes the scale from what the compositor reported, with
    /// `max_output` the largest scale of the entered outputs. Returns the
    /// configure to report when it changed (same serial: no new ack).
    pub fn rescale(w: *Window, max_output: ?i32) ?Configured {
        const s = scale.choose(w.frac_scale, w.preferred_buffer, max_output);
        if (s == w.scale120) return null;
        w.scale120 = s;
        if (!w.configured) return null;
        return .{ .size = w.bufferSize(), .scale = scale.factor(s), .state = w.state, .serial = w.serial, .occluded = null };
    }

    /// The buffer size for the current logical size and scale. Without a
    /// viewport the scale is rounded to an integer buffer scale.
    pub fn bufferSize(w: *const Window) PxSize {
        return scale.bufferSize(w.surfaceLogical(), w.effectiveScale120());
    }

    /// The surface's logical size: the window plus its CSD margins.
    pub fn surfaceLogical(w: *const Window) PxSize {
        const m = w.margins;
        return .{ .w = w.logical.w + m.left + m.right, .h = w.logical.h + m.top + m.bottom };
    }

    /// The scale the buffer is rendered at: exact with a viewport,
    /// otherwise the integer buffer scale.
    pub fn effectiveScale120(w: *const Window) u32 {
        if (w.viewport != null) return w.scale120;
        return @as(u32, @intCast(scale.integerScale(w.scale120))) * scale.unit;
    }

    /// Whether the configure serial `serial` still needs an ack; clears it.
    pub fn takeAck(w: *Window, serial: ?u32) ?u32 {
        const p = w.pending_ack orelse return null;
        if (serial) |s| if (s != p) return null;
        w.pending_ack = null;
        return p;
    }

    /// Records `wl_surface.enter`.
    pub fn enter(w: *Window, out: wl.wl_output.Id) void {
        for (w.entered[0..w.entered_len]) |o| if (o == out) return;
        if (w.entered_len == max_entered) return;
        w.entered[w.entered_len] = out;
        w.entered_len += 1;
    }

    /// Records `wl_surface.leave` (or a removed output).
    pub fn leave(w: *Window, out: wl.wl_output.Id) void {
        for (w.entered[0..w.entered_len], 0..) |o, i| if (o == out) {
            w.entered[i] = w.entered[w.entered_len - 1];
            w.entered_len -= 1;
            return;
        };
    }

    /// The outputs the surface is on.
    pub fn enteredOutputs(w: *const Window) []const wl.wl_output.Id {
        return w.entered[0..w.entered_len];
    }
};

fn tiled(s: WindowState) bool {
    return s.tiled_left or s.tiled_right or s.tiled_top or s.tiled_bottom;
}

/// Decodes the `xdg_toplevel.configure` states array.
pub fn statesFrom(bytes: []const u8) WindowState {
    var s: WindowState = .{};
    var i: usize = 0;
    while (i + 4 <= bytes.len) : (i += 4) {
        const v: wl.xdg_toplevel.State = @enumFromInt(std.mem.readInt(u32, bytes[i..][0..4], @import("builtin").cpu.arch.endian()));
        switch (v) {
            .maximized => s.maximized = true,
            .fullscreen => s.fullscreen = true,
            .resizing => s.resizing = true,
            .activated => s.activated = true,
            .tiled_left => s.tiled_left = true,
            .tiled_right => s.tiled_right = true,
            .tiled_top => s.tiled_top = true,
            .tiled_bottom => s.tiled_bottom = true,
            .suspended => s.suspended = true,
            else => {},
        }
    }
    return s;
}

/// Decodes `xdg_toplevel.wm_capabilities`: only the listed ones remain.
pub fn capsFrom(bytes: []const u8) WmCapabilities {
    var c: WmCapabilities = .{ .window_menu = false, .maximize = false, .fullscreen = false, .minimize = false };
    var i: usize = 0;
    while (i + 4 <= bytes.len) : (i += 4) {
        const v: wl.xdg_toplevel.WmCapabilities = @enumFromInt(std.mem.readInt(u32, bytes[i..][0..4], @import("builtin").cpu.arch.endian()));
        switch (v) {
            .window_menu => c.window_menu = true,
            .maximize => c.maximize = true,
            .fullscreen => c.fullscreen = true,
            .minimize => c.minimize = true,
            else => {},
        }
    }
    return c;
}

/// `title` cut to `max_title` bytes on a UTF-8 boundary.
pub fn truncateTitle(title: []const u8) []const u8 {
    if (title.len <= max_title) return title;
    var end: usize = max_title;
    while (end > 0 and title[end] & 0xc0 == 0x80) end -= 1;
    return title[0..end];
}

const testing = std.testing;

fn testWindow() Window {
    const size: PxSize = .{ .w = 320, .h = 240 };
    return .{ .id = @enumFromInt(1), .surface = @enumFromInt(3), .xdg_surface = @enumFromInt(4), .toplevel = @enumFromInt(5), .default_logical = size, .logical = size };
}

fn statesBytes(comptime list: []const wl.xdg_toplevel.State) [list.len * 4]u8 {
    var out: [list.len * 4]u8 = undefined;
    for (list, 0..) |s, i| std.mem.writeInt(u32, out[i * 4 ..][0..4], @intFromEnum(s), @import("builtin").cpu.arch.endian());
    return out;
}

test "0x0 configure keeps size" {
    var w = testWindow();
    w.onToplevelConfigure(0, 0, &.{});
    const c = w.onConfigure(11, 0, 100);
    try testing.expectEqual(PxSize{ .w = 320, .h = 240 }, c.size);
    try testing.expectEqual(@as(u32, 11), c.serial);
    w.onToplevelConfigure(800, 0, &.{});
    try testing.expectEqual(PxSize{ .w = 800, .h = 240 }, w.onConfigure(12, 0, 100).size);
}

test "configure is held for the present" {
    var w = testWindow();
    w.onToplevelConfigure(640, 480, &.{});
    _ = w.onConfigure(5, 1000, 100);
    try testing.expectEqual(@as(?u32, 5), w.pending_ack);
    try testing.expectEqual(@as(u64, 1100), w.ack_deadline_ns);
    // A present for an older serial does not ack the newer one.
    try testing.expectEqual(@as(?u32, null), w.takeAck(4));
    try testing.expectEqual(@as(?u32, 5), w.takeAck(5));
    try testing.expectEqual(@as(?u32, null), w.takeAck(5));
}

test "states map, suspended reports occlusion once" {
    var w = testWindow();
    const sb = statesBytes(&.{ .activated, .tiled_left, .tiled_top, .suspended });
    w.onToplevelConfigure(0, 0, &sb);
    const c = w.onConfigure(1, 0, 0);
    try testing.expect(c.state.activated and c.state.tiled_left and c.state.tiled_top and c.state.suspended);
    try testing.expect(!c.state.maximized);
    try testing.expectEqual(@as(?bool, true), c.occluded);
    w.onToplevelConfigure(0, 0, &sb);
    try testing.expectEqual(@as(?bool, null), w.onConfigure(2, 0, 0).occluded);
    w.onToplevelConfigure(0, 0, &.{});
    try testing.expectEqual(@as(?bool, false), w.onConfigure(3, 0, 0).occluded);
}

test "min size applies to floating windows only" {
    var w = testWindow();
    w.min_logical = .{ .w = 400, .h = 300 };
    w.onToplevelConfigure(200, 100, &.{});
    try testing.expectEqual(PxSize{ .w = 400, .h = 300 }, w.onConfigure(1, 0, 0).size);
    const sb = statesBytes(&.{.tiled_left});
    w.onToplevelConfigure(200, 100, &sb);
    try testing.expectEqual(PxSize{ .w = 200, .h = 100 }, w.onConfigure(2, 0, 0).size);
}

test "fractional scale needs the viewport; without it the scale rounds up" {
    var w = testWindow();
    w.logical = .{ .w = 100, .h = 50 };
    w.viewport = @enumFromInt(9);
    w.frac_scale = 180;
    w.onToplevelConfigure(100, 50, &.{});
    _ = w.onConfigure(1, 0, 0);
    const c = w.rescale(null).?;
    try testing.expectEqual(PxSize{ .w = 150, .h = 75 }, c.size);
    try testing.expectEqual(@as(u32, 1), c.serial);
    try testing.expectEqual(@as(?Configured, null), w.rescale(null));
    w.viewport = null;
    try testing.expectEqual(PxSize{ .w = 200, .h = 100 }, w.bufferSize());
}

test "entered outputs and wm capabilities" {
    var w = testWindow();
    w.enter(@enumFromInt(20));
    w.enter(@enumFromInt(21));
    w.enter(@enumFromInt(20));
    try testing.expectEqual(2, w.enteredOutputs().len);
    w.leave(@enumFromInt(20));
    try testing.expectEqual(@as(wl.wl_output.Id, @enumFromInt(21)), w.enteredOutputs()[0]);
    var cb: [8]u8 = undefined;
    std.mem.writeInt(u32, cb[0..4], @intFromEnum(wl.xdg_toplevel.WmCapabilities.maximize), @import("builtin").cpu.arch.endian());
    std.mem.writeInt(u32, cb[4..8], @intFromEnum(wl.xdg_toplevel.WmCapabilities.window_menu), @import("builtin").cpu.arch.endian());
    const c = capsFrom(&cb);
    try testing.expect(c.maximize and c.window_menu and !c.minimize and !c.fullscreen);
}

test "titles truncate on a codepoint boundary" {
    var buf: [max_title + 2]u8 = undefined;
    @memset(buf[0 .. max_title - 1], 'a');
    // "é" (2 bytes) straddles the limit.
    buf[max_title - 1] = 0xc3;
    buf[max_title] = 0xa9;
    buf[max_title + 1] = 'b';
    try testing.expectEqual(@as(usize, max_title - 1), truncateTitle(&buf).len);
    try testing.expectEqualStrings("short", truncateTitle("short"));
}

test "client-side decorations grow the surface by the margins, except maximized" {
    var w = testWindow();
    w.csd = true;
    w.onToplevelConfigure(400, 300, &.{});
    const c = w.onConfigure(1, 0, 100);
    try testing.expectEqual(PxSize{ .w = 424, .h = 324 }, c.size);
    w.onToplevelConfigure(800, 600, &statesBytes(&.{.maximized}));
    try testing.expectEqual(PxSize{ .w = 800, .h = 600 }, w.onConfigure(2, 0, 100).size);
}
