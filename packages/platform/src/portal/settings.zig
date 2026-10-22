//! `org.freedesktop.portal.Settings`: the desktop's color scheme, accent
//! colour, contrast and reduced-motion preference, read at startup and
//! followed live through `SettingChanged`.

const std = @import("std");
const request = @import("request.zig");
const conn = @import("../dbus/conn.zig");
const Bus = conn.Bus;
const Value = @import("../dbus/variant.zig").Value;
const event = @import("../api/event.zig");
const Appearance = event.Appearance;

/// The interface name.
pub const interface = "org.freedesktop.portal.Settings";
/// The namespace holding the appearance keys.
pub const namespace = "org.freedesktop.appearance";

const keys = [_][]const u8{ "color-scheme", "accent-color", "contrast", "reduced-motion" };

/// Applies one `org.freedesktop.appearance` key to `app`; unknown keys
/// and malformed values leave it unchanged.
pub fn apply(app: *Appearance, key: []const u8, value: Value) void {
    const v = value.unwrap();
    if (std.mem.eql(u8, key, "color-scheme")) {
        app.scheme = switch (v.asU64() orelse return) {
            1 => .dark,
            2 => .light,
            else => .no_preference,
        };
    } else if (std.mem.eql(u8, key, "accent-color")) {
        app.has_accent = false;
        if (v != .structure or v.structure.len != 3) return;
        var rgb: [3]u8 = undefined;
        for (v.structure, 0..) |c, i| {
            if (c != .double) return;
            const d = c.double;
            // Out of range means "no accent colour".
            if (!(d >= 0 and d <= 1)) return;
            rgb[i] = @intFromFloat(@round(d * 255));
        }
        app.accent = rgb;
        app.has_accent = true;
    } else if (std.mem.eql(u8, key, "contrast")) {
        app.contrast = if ((v.asU64() orelse return) == 1) .high else .normal;
    } else if (std.mem.eql(u8, key, "reduced-motion")) {
        app.reduced_motion = (v.asU64() orelse return) == 1;
    }
}

/// Reads every appearance key. A missing portal or key gives the
/// defaults (`no_preference`). Uses `ReadOne`, falling back to the
/// deprecated `Read` (whose value is wrapped in an extra variant) on
/// portals older than version 2.
pub fn read(gpa: std.mem.Allocator, bus: *Bus, timeout_ns: ?u64) Appearance {
    var app: Appearance = .{};
    var use_read = false;
    for (keys) |key| {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const v = readKey(bus, arena.allocator(), key, use_read, timeout_ns) catch |err| switch (err) {
            error.Unknown => blk: {
                if (use_read) continue;
                use_read = true;
                break :blk readKey(bus, arena.allocator(), key, true, timeout_ns) catch continue;
            },
            error.Unavailable => return app,
            else => continue,
        };
        apply(&app, key, v);
    }
    return app;
}

fn readKey(bus: *Bus, arena: std.mem.Allocator, key: []const u8, use_read: bool, timeout_ns: ?u64) !Value {
    var p = try bus.call(request.destination, request.object_path, interface, if (use_read) "Read" else "ReadOne", "ss", .{ namespace, key });
    defer p.deinit();
    var r = try p.wait(timeout_ns);
    defer r.deinit();
    if (r.errorName()) |name| {
        if (std.mem.eql(u8, name, "org.freedesktop.DBus.Error.UnknownMethod")) return error.Unknown;
        if (std.mem.eql(u8, name, request.service_unknown) or std.mem.eql(u8, name, "org.freedesktop.DBus.Error.NameHasNoOwner")) return error.Unavailable;
        return error.Failed;
    }
    const a = try r.args(arena);
    if (a.len != 1) return error.Failed;
    // Values live in the reply's buffer; copy what we keep.
    return dupeValue(arena, a[0]);
}

fn dupeValue(arena: std.mem.Allocator, v: Value) !Value {
    return switch (v) {
        .variant => |p| blk: {
            const inner = try arena.create(Value);
            inner.* = try dupeValue(arena, p.*);
            break :blk .{ .variant = inner };
        },
        .structure => |fields| blk: {
            const out = try arena.alloc(Value, fields.len);
            for (fields, out) |f, *o| o.* = try dupeValue(arena, f);
            break :blk .{ .structure = out };
        },
        // Appearance keys are numbers and structs of doubles; anything
        // else is ignored by `apply`, so a shallow copy is enough.
        else => v,
    };
}

/// Called with the updated appearance (on the bus reader thread).
pub const ChangeCallback = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, app: Appearance) void,
};

/// Follows `SettingChanged` for the appearance namespace.
pub const Watcher = struct {
    bus: *Bus,
    current: Appearance,
    callback: ChangeCallback,
    match: conn.MatchId = undefined,

    /// Subscribes, starting from `initial` (usually from `read`).
    pub fn start(w: *Watcher) !void {
        const rule = "type='signal',interface='" ++ interface ++ "',member='SettingChanged',path='" ++ request.object_path ++ "',arg0='" ++ namespace ++ "'";
        w.match = try w.bus.addMatch(rule, .{ .ctx = w, .func = onChanged });
    }

    /// Unsubscribes.
    pub fn stop(w: *Watcher) void {
        w.bus.removeMatch(w.match);
    }

    fn onChanged(ctx: ?*anyopaque, in: *const conn.Incoming) void {
        const w: *Watcher = @ptrCast(@alignCast(ctx.?));
        const a = in.args() catch return;
        if (a.len != 3) return;
        const ns = a[0].asString() orelse return;
        if (!std.mem.eql(u8, ns, namespace)) return;
        const before = w.current;
        apply(&w.current, a[1].asString() orelse return, a[2]);
        if (!std.meta.eql(before, w.current)) w.callback.func(w.callback.ctx, w.current);
    }
};

const testing = std.testing;

test "apply: every key, out-of-range accent, unknown values" {
    var app: Appearance = .{};
    apply(&app, "color-scheme", .{ .u32 = 1 });
    try testing.expectEqual(event.ColorScheme.dark, app.scheme);
    var red = [_]Value{ .{ .double = 1 }, .{ .double = 0 }, .{ .double = 0.5 } };
    apply(&app, "accent-color", .{ .structure = &red });
    try testing.expect(app.has_accent);
    try testing.expectEqual([3]u8{ 255, 0, 128 }, app.accent);
    red[0] = .{ .double = 1.5 };
    apply(&app, "accent-color", .{ .structure = &red });
    try testing.expect(!app.has_accent);
    apply(&app, "contrast", .{ .u32 = 1 });
    try testing.expectEqual(event.Contrast.high, app.contrast);
    apply(&app, "reduced-motion", .{ .u32 = 1 });
    try testing.expect(app.reduced_motion);
    apply(&app, "color-scheme", .{ .string = "dark" });
    try testing.expectEqual(event.ColorScheme.dark, app.scheme);
    apply(&app, "color-scheme", .{ .u32 = 7 });
    try testing.expectEqual(event.ColorScheme.no_preference, app.scheme);
}
