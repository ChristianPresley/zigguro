//! The Windows backend with a recording `Shell_NotifyIconW` and fake
//! native hooks (runs on every OS).

const std = @import("std");
const zg_platform = @import("zg_platform");
const n_mod = @import("notification.zig");
const os_windows = @import("os_windows.zig");
const sh = @import("win32_shellapi.zig");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;

const Recorder = struct {
    calls: std.ArrayList(u32) = .empty,
    /// Fail the next NIM_MODIFY (explorer restarted).
    fail_modify: bool = false,
    last: sh.NOTIFYICONDATAW = .{},

    fn api(r: *Recorder) os_windows.ShellApi {
        return .{ .ctx = r, .notify = notify };
    }

    fn notify(ctx: ?*anyopaque, msg: u32, d: *sh.NOTIFYICONDATAW) i32 {
        const r: *Recorder = @ptrCast(@alignCast(ctx.?));
        r.calls.append(gpa, msg) catch {};
        if (msg == sh.NIM_MODIFY) {
            if (r.fail_modify) {
                r.fail_modify = false;
                return 0;
            }
            r.last = d.*;
        }
        if (msg == sh.NIM_SETVERSION and d.u.uVersion != sh.NOTIFYICON_VERSION_4) return 0;
        return 1;
    }
};

const Hooks = struct {
    hook: ?zg_platform.native.Win32MsgHook = null,
    ctx: ?*anyopaque = null,
    destroyed: bool = false,
    dummy: u8 = 0,

    fn native(h: *Hooks) zg_platform.NativeHooks {
        return .{
            .ptr = h,
            .win32SetMessageHook = setHook,
            .win32CreateMessageWindow = create,
            .win32DestroyMessageWindow = destroy,
            .windowHandle = handle,
        };
    }

    fn setHook(_: *anyopaque, _: zg_platform.WindowId, _: []const u32, _: ?zg_platform.native.Win32MsgHook, _: *anyopaque) error{Unsupported}!void {
        return error.Unsupported;
    }

    fn create(p: *anyopaque, hook: zg_platform.native.Win32MsgHook, ctx: *anyopaque) error{ Unsupported, SystemResources }!*anyopaque {
        const h: *Hooks = @ptrCast(@alignCast(p));
        h.hook = hook;
        h.ctx = ctx;
        return &h.dummy;
    }

    fn destroy(p: *anyopaque, _: *anyopaque) void {
        const h: *Hooks = @ptrCast(@alignCast(p));
        h.destroyed = true;
    }

    fn handle(_: *anyopaque, _: zg_platform.WindowId) zg_platform.native.NativeWindow {
        return .headless;
    }

    /// The shell posting the icon's callback message.
    fn send(h: *Hooks, event: u32) ?isize {
        return h.hook.?(h.ctx.?, &h.dummy, os_windows.callback_message, 0, @intCast(event));
    }
};

const Got = struct {
    key: [32]u8 = undefined,
    len: usize = 0,
    action: [16]u8 = undefined,
    alen: usize = 0,
    n: u32 = 0,

    fn activate(g: *Got) n_mod.ActivateFn {
        return .{ .ctx = g, .f = on };
    }

    fn on(ctx: *anyopaque, key: []const u8, action: []const u8, _: ?[]const u8) void {
        const g: *Got = @ptrCast(@alignCast(ctx));
        @memcpy(g.key[0..key.len], key);
        g.len = key.len;
        @memcpy(g.action[0..action.len], action);
        g.alen = action.len;
        g.n += 1;
    }
};

fn utf16(buf: []const u16, out: []u8) []const u8 {
    const end = std.mem.indexOfScalar(u16, buf, 0) orelse buf.len;
    const n = std.unicode.utf16LeToUtf8(out, buf[0..end]) catch unreachable;
    return out[0..n];
}

test "windows_setversion_after_every_add" {
    var rec: Recorder = .{};
    defer rec.calls.deinit(gpa);
    var hooks: Hooks = .{};
    const native = hooks.native();
    var got: Got = .{};
    const b = try os_windows.windowsBackend(gpa, io, &native, got.activate(), .{ .api = rec.api() });
    try testing.expectEqualSlices(u32, &.{ sh.NIM_ADD, sh.NIM_SETVERSION }, rec.calls.items);
    const n: n_mod.Notification = .{ .key = "run:1", .severity = .error_, .title = "Failed: Lint", .body = "exit 2" };
    _ = try b.show(&n, null);
    try testing.expectEqual(sh.NIF_INFO, rec.last.uFlags);
    try testing.expectEqual(sh.NIIF_ERROR | sh.NIIF_RESPECT_QUIET_TIME, rec.last.dwInfoFlags);
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("Failed: Lint", utf16(&rec.last.szInfoTitle, &buf));
    // The icon vanished: added again (with its version) and retried.
    rec.fail_modify = true;
    rec.calls.clearRetainingCapacity();
    _ = try b.show(&n, null);
    try testing.expectEqualSlices(u32, &.{ sh.NIM_MODIFY, sh.NIM_ADD, sh.NIM_SETVERSION, sh.NIM_MODIFY }, rec.calls.items);
    b.deinit();
}

test "windows_balloon_click_routes_last_key" {
    var rec: Recorder = .{};
    defer rec.calls.deinit(gpa);
    var hooks: Hooks = .{};
    const native = hooks.native();
    var got: Got = .{};
    const b = try os_windows.windowsBackend(gpa, io, &native, got.activate(), .{ .api = rec.api() });
    defer b.deinit();
    const acts = [_]n_mod.NotifyAction{.{ .id = "open", .label = "Open" }};
    _ = try b.show(&.{ .key = "run:1", .severity = .info, .title = "a" }, null);
    _ = try b.show(&.{ .key = "run:2", .severity = .needs_input, .title = "b", .actions = &acts }, null);
    try testing.expectEqual(@as(?isize, 0), hooks.send(sh.NIN_BALLOONSHOW));
    try testing.expectEqual(@as(u32, 0), got.n);
    try testing.expectEqual(@as(?isize, 0), hooks.send(sh.NIN_BALLOONUSERCLICK));
    try testing.expectEqual(@as(u32, 1), got.n);
    try testing.expectEqualStrings("run:2", got.key[0..got.len]);
    try testing.expectEqualStrings("open", got.action[0..got.alen]);
    // Other messages are not ours.
    try testing.expectEqual(@as(?isize, null), hooks.hook.?(hooks.ctx.?, &hooks.dummy, 0x0010, 0, 0));
}

test "windows_delete_on_shutdown" {
    var rec: Recorder = .{};
    defer rec.calls.deinit(gpa);
    var hooks: Hooks = .{};
    const native = hooks.native();
    var got: Got = .{};
    const b = try os_windows.windowsBackend(gpa, io, &native, got.activate(), .{ .api = rec.api() });
    b.deinit();
    try testing.expectEqual(sh.NIM_DELETE, rec.calls.items[rec.calls.items.len - 1]);
    try testing.expect(hooks.destroyed);
}

test "windows_truncation_on_graphemes" {
    var title: [64]u16 = undefined;
    var out: [512]u8 = undefined;
    // Fits: as is.
    try testing.expectEqual(@as(usize, 5), os_windows.fillUtf16(&title, "hello"));
    // 70 ASCII chars into 63 units: 62 and "…".
    const long = "a" ** 70;
    try testing.expectEqual(@as(usize, 63), os_windows.fillUtf16(&title, long));
    try testing.expectEqualStrings("a" ** 62 ++ "\u{2026}", utf16(&title, &out));
    // A family emoji (ZWJ sequence, 8 units) is never split.
    const fam = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";
    const s = "b" ** 57 ++ fam;
    const n = os_windows.fillUtf16(&title, s);
    try testing.expectEqualStrings("b" ** 57 ++ "\u{2026}", utf16(&title, &out));
    try testing.expectEqual(@as(usize, 58), n);
    // e + combining acute stays whole.
    var small: [5]u16 = undefined;
    _ = os_windows.fillUtf16(&small, "abce\u{0301}x");
    try testing.expectEqualStrings("abc\u{2026}", utf16(&small, &out));
    // Invalid UTF-8 does not crash.
    _ = os_windows.fillUtf16(&small, "\xff\xfeab");
}
