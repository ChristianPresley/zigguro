//! The Windows notification backend (E13.F01.S03.T03): one
//! notification-area icon on a message-only window (from E01's
//! `NativeHooks`), and each notification as its balloon
//! (`Shell_NotifyIconW` with `NIF_INFO`, respecting quiet time). Windows
//! shows one balloon at a time, so a new notification replaces the last
//! one (the router groups bursts). A click on the balloon activates the
//! last shown notification's first action. Toasts through WinRT are out
//! of scope.

const std = @import("std");
const builtin = @import("builtin");
const zg_platform = @import("zg_platform");
const zg_text = @import("zg_text");
const n_mod = @import("notification.zig");
const sh = @import("win32_shellapi.zig");

const Allocator = std.mem.Allocator;
const Notification = n_mod.Notification;
const NativeHooks = zg_platform.NativeHooks;

/// The icon's callback message on the message-only window.
pub const callback_message: u32 = sh.WM_APP + 0x51;
const icon_id: u32 = 1;

/// Calls `Shell_NotifyIconW` (a recorder in tests).
pub const ShellApi = struct {
    ctx: ?*anyopaque = null,
    notify: *const fn (ctx: ?*anyopaque, msg: u32, data: *sh.NOTIFYICONDATAW) i32,

    pub const real: ShellApi = .{ .notify = realNotify };

    fn realNotify(_: ?*anyopaque, msg: u32, data: *sh.NOTIFYICONDATAW) i32 {
        if (builtin.os.tag != .windows) return 0;
        return sh.Shell_NotifyIconW(msg, data);
    }
};

pub const Options = struct {
    api: ShellApi = .real,
    /// The notification-area icon (the app's icon).
    icon: ?sh.HICON = null,
    tip: []const u8 = "zigguro",
};

pub const Windows = struct {
    gpa: Allocator,
    io: std.Io,
    hooks: *const NativeHooks,
    activate: n_mod.ActivateFn,
    o: Options,
    hwnd: *anyopaque,
    mutex: std.Io.Mutex = .init,
    added: bool = false,
    next_id: u64 = 1,
    /// The shown balloon's key and first action, for clicks.
    last_key: std.ArrayList(u8) = .empty,
    last_action: std.ArrayList(u8) = .empty,

    pub fn backend(w: *Windows) n_mod.OsBackend {
        return .{ .ctx = w, .vtable = &vtable };
    }

    const vtable: n_mod.OsBackend.VTable = .{ .show = show, .close = close, .deinit = deinitFn };

    fn base(w: *Windows) sh.NOTIFYICONDATAW {
        return .{ .hWnd = w.hwnd, .uID = icon_id };
    }

    /// NIM_ADD, then NIM_SETVERSION (required after every add).
    fn addIcon(w: *Windows) bool {
        var d = w.base();
        d.uFlags = sh.NIF_MESSAGE | sh.NIF_TIP | sh.NIF_SHOWTIP | (if (w.o.icon != null) sh.NIF_ICON else 0);
        d.uCallbackMessage = callback_message;
        d.hIcon = w.o.icon;
        _ = fillUtf16(&d.szTip, w.o.tip);
        if (w.o.api.notify(w.o.api.ctx, sh.NIM_ADD, &d) == 0) return false;
        var v = w.base();
        v.u = .{ .uVersion = sh.NOTIFYICON_VERSION_4 };
        _ = w.o.api.notify(w.o.api.ctx, sh.NIM_SETVERSION, &v);
        w.added = true;
        return true;
    }

    fn show(ctx: *anyopaque, n: *const Notification, replaces: ?u64) anyerror!u64 {
        const w: *Windows = @ptrCast(@alignCast(ctx));
        w.mutex.lockUncancelable(w.io);
        defer w.mutex.unlock(w.io);
        var d = w.base();
        d.uFlags = sh.NIF_INFO;
        _ = fillUtf16(&d.szInfoTitle, n.title);
        _ = fillUtf16(&d.szInfo, if (n.body.len > 0) n.body else " ");
        d.dwInfoFlags = sh.NIIF_RESPECT_QUIET_TIME | switch (n.severity) {
            .info, .success => sh.NIIF_INFO,
            .warning, .needs_input => sh.NIIF_WARNING,
            .error_ => sh.NIIF_ERROR,
        };
        if (!w.added and !w.addIcon()) return error.NotifyIconFailed;
        if (w.o.api.notify(w.o.api.ctx, sh.NIM_MODIFY, &d) == 0) {
            // Explorer restarted and dropped the icon: add it again.
            w.added = false;
            if (!w.addIcon() or w.o.api.notify(w.o.api.ctx, sh.NIM_MODIFY, &d) == 0) return error.NotifyIconFailed;
        }
        w.last_key.clearRetainingCapacity();
        try w.last_key.appendSlice(w.gpa, n.key);
        w.last_action.clearRetainingCapacity();
        try w.last_action.appendSlice(w.gpa, if (n.actions.len > 0) n.actions[0].id else "open");
        return replaces orelse blk: {
            const id = w.next_id;
            w.next_id += 1;
            break :blk id;
        };
    }

    fn close(_: *anyopaque, _: u64) void {}

    /// On the platform thread: balloon clicks.
    fn onMessage(ctx: *anyopaque, _: *anyopaque, msg: u32, _: usize, lp: isize) ?isize {
        const w: *Windows = @ptrCast(@alignCast(ctx));
        if (msg != callback_message) return null;
        const event: u32 = @as(u16, @truncate(@as(usize, @bitCast(lp))));
        if (event != sh.NIN_BALLOONUSERCLICK) return 0;
        var key_buf: [256]u8 = undefined;
        var act_buf: [64]u8 = undefined;
        const key, const action = blk: {
            w.mutex.lockUncancelable(w.io);
            defer w.mutex.unlock(w.io);
            if (w.last_key.items.len == 0 or w.last_key.items.len > key_buf.len or w.last_action.items.len > act_buf.len) return 0;
            @memcpy(key_buf[0..w.last_key.items.len], w.last_key.items);
            @memcpy(act_buf[0..w.last_action.items.len], w.last_action.items);
            break :blk .{ key_buf[0..w.last_key.items.len], act_buf[0..w.last_action.items.len] };
        };
        w.activate.call(key, action, null);
        return 0;
    }

    fn deinitFn(ctx: *anyopaque) void {
        const w: *Windows = @ptrCast(@alignCast(ctx));
        if (w.added) {
            var d = w.base();
            _ = w.o.api.notify(w.o.api.ctx, sh.NIM_DELETE, &d);
        }
        w.hooks.win32DestroyMessageWindow(w.hooks.ptr, w.hwnd);
        w.last_key.deinit(w.gpa);
        w.last_action.deinit(w.gpa);
        w.gpa.destroy(w);
    }
};

/// The backend: a message-only window from `hooks` and the icon. The
/// router owns it.
pub fn windowsBackend(gpa: Allocator, io: std.Io, hooks: *const NativeHooks, activate: n_mod.ActivateFn, o: Options) !n_mod.OsBackend {
    const w = try gpa.create(Windows);
    errdefer gpa.destroy(w);
    w.* = .{ .gpa = gpa, .io = io, .hooks = hooks, .activate = activate, .o = o, .hwnd = undefined };
    w.hwnd = try hooks.win32CreateMessageWindow(hooks.ptr, Windows.onMessage, w);
    errdefer hooks.win32DestroyMessageWindow(hooks.ptr, w.hwnd);
    if (!w.addIcon()) return error.NotifyIconFailed;
    return w.backend();
}

/// Writes `s` into `buf` as NUL-terminated UTF-16, cut on a grapheme
/// boundary with "…" when it does not fit. Returns the code units
/// written (without the NUL).
pub fn fillUtf16(buf: []u16, s: []const u8) usize {
    const max = buf.len - 1;
    if (!std.unicode.utf8ValidateSlice(s)) return fillLossy(buf, s);
    if (utf16Len(s) <= max) return encode(buf, s, false);
    // The longest prefix of whole graphemes that leaves room for "…".
    var end: usize = 0;
    var units: usize = 0;
    while (end < s.len) {
        const next = zg_text.unicode.grapheme.nextBoundary(s, end);
        const more = utf16Len(s[end..next]);
        if (units + more + 1 > max) break;
        units += more;
        end = next;
    }
    return encode(buf, s[0..end], true);
}

fn encode(buf: []u16, s: []const u8, ellipsis: bool) usize {
    var i: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp >= 0x10000) {
            const v = cp - 0x10000;
            buf[i] = std.mem.nativeToLittle(u16, @intCast(0xD800 + (v >> 10)));
            buf[i + 1] = std.mem.nativeToLittle(u16, @intCast(0xDC00 + (v & 0x3FF)));
            i += 2;
        } else {
            buf[i] = std.mem.nativeToLittle(u16, @intCast(cp));
            i += 1;
        }
    }
    if (ellipsis) {
        buf[i] = std.mem.nativeToLittle(u16, 0x2026);
        i += 1;
    }
    buf[i] = 0;
    return i;
}

fn utf16Len(s: []const u8) usize {
    var n: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |cp| n += if (cp >= 0x10000) 2 else 1;
    return n;
}

/// Invalid UTF-8: ASCII as is, other bytes as U+FFFD.
fn fillLossy(buf: []u16, s: []const u8) usize {
    const max = buf.len - 1;
    var i: usize = 0;
    for (s) |c| {
        if (i == max) break;
        buf[i] = std.mem.nativeToLittle(u16, if (c < 0x80) c else 0xFFFD);
        i += 1;
    }
    buf[i] = 0;
    return i;
}
