//! What a notification is, and the ports the router delivers through
//! (E13.F01.S03.T01). Pure data.

const std = @import("std");
const run = @import("../runs/run.zig");

pub const RunId = run.RunId;

pub const Severity = enum { info, success, warning, error_, needs_input };

pub const NotifyAction = struct {
    /// "open", "deny", "approve", ...
    id: []const u8,
    label: []const u8,
};

pub const Progress = struct { done: u32, total: u32 };

pub const Notification = struct {
    /// Same key within the rate-limit interval: the earlier one is updated
    /// in place instead of a new one shown.
    key: []const u8,
    /// Same group within the group window: merged into one "N updates".
    group: ?[]const u8 = null,
    run: ?RunId = null,
    severity: Severity,
    title: []const u8,
    body: []const u8 = "",
    actions: []const NotifyAction = &.{},
    /// A merged group shows "done/total done" (workflow workers).
    progress: ?Progress = null,
};

/// Delivers to the OS (Linux D-Bus, Windows notification area, headless
/// stderr). Called on the router's worker, never on the UI thread.
pub const OsBackend = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Shows `n`, replacing the notification `replaces` (an id this
        /// backend returned) when given; returns the new id.
        show: *const fn (ctx: *anyopaque, n: *const Notification, replaces: ?u64) anyerror!u64,
        close: *const fn (ctx: *anyopaque, id: u64) void,
        deinit: *const fn (ctx: *anyopaque) void,
    };

    pub fn show(b: OsBackend, n: *const Notification, replaces: ?u64) anyerror!u64 {
        return b.vtable.show(b.ctx, n, replaces);
    }

    pub fn close(b: OsBackend, id: u64) void {
        b.vtable.close(b.ctx, id);
    }

    pub fn deinit(b: OsBackend) void {
        b.vtable.deinit(b.ctx);
    }
};

/// The in-app side (E04 toasts and the notification center). Called on
/// the router's worker: an adapter must hand the call to the UI thread.
pub const ToastSink = struct {
    ctx: *anyopaque,
    /// Records `n` in the notification center; `show_toast` also pops a
    /// toast. `slot` names the notification across replacements (the
    /// adapter updates the entry it made for the same slot).
    deliver: *const fn (ctx: *anyopaque, n: *const Notification, slot: u32, show_toast: bool) void,
};

/// A notification (or one of its actions) was clicked. `xdg_token` is the
/// Wayland activation token, when the OS gave one. Any thread.
pub const ActivateFn = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, key: []const u8, action: []const u8, xdg_token: ?[]const u8) void,

    pub fn call(a: ActivateFn, key: []const u8, action: []const u8, xdg_token: ?[]const u8) void {
        a.f(a.ctx, key, action, xdg_token);
    }
};
