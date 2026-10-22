//! Dialogs (E04.F05.S03.T01): modal overlays with a title, centred in the
//! window, plus `confirm`, an asynchronous OK/Cancel question.
//!
//! Button order follows the platform: on Windows the primary button comes
//! first (left of Cancel); elsewhere (GNOME, macOS) it comes last.

const std = @import("std");
const builtin = @import("builtin");
const ui_mod = @import("../core/ui.zig");
const view_mod = @import("../core/view.zig");
const window_mod = @import("../core/window.zig");
const overlay = @import("overlay.zig");
const controls = @import("controls.zig");

const Ui = ui_mod.Ui;
const AnyView = view_mod.AnyView;
const Window = window_mod.Window;

/// Dialog widths.
pub const DialogSize = enum(u8) {
    sm,
    md,
    lg,
    /// The whole window less the overlay margin.
    fullscreen,

    /// The width in logical pixels for a window `win_w` wide.
    pub fn width(s: DialogSize, win_w: f32) f32 {
        const max = win_w - 2 * overlay.viewport_margin;
        return @min(max, switch (s) {
            .sm => 360,
            .md => 520,
            .lg => 760,
            .fullscreen => max,
        });
    }
};

/// Dialog options.
pub const DialogProps = struct {
    title: []const u8,
    size: DialogSize = .md,
    /// Close on a press outside (off for dialogs by default).
    light_dismiss: bool = false,
    test_id: []const u8 = "",
};

/// Shows `content` in a modal dialog while `open.*` is true; Escape closes
/// it and sets `open.*` to false.
pub fn dialog(ui: *Ui, open: *bool, content: AnyView, p: DialogProps) void {
    overlay.bound(ui, open, content, .{
        .layer = .dialog,
        .modal = true,
        .light_dismiss = p.light_dismiss,
        .title = p.title,
        .label = p.title,
        .test_id = p.test_id,
        .width = p.size.width(ui.window().size.w),
    });
}

/// The answer to `confirm`.
pub const Result = enum { ok, cancel, alt };

/// What `confirm` asks.
pub const ConfirmProps = struct {
    title: []const u8,
    message: []const u8 = "",
    ok_label: []const u8 = "OK",
    cancel_label: []const u8 = "Cancel",
    /// A third choice ("Don't save"), shown away from the primary button.
    alt_label: ?[]const u8 = null,
    /// The primary action destroys something.
    danger: bool = false,
    size: DialogSize = .sm,
};

/// Receives the answer.
pub const ConfirmCb = struct {
    ctx: ?*anyopaque = null,
    f: *const fn (ctx: ?*anyopaque, r: Result) void,
};

/// Primary button first (Windows) or last (elsewhere).
pub const primary_first = builtin.os.tag == .windows;

/// Asks `p` in a modal dialog; `cb` runs once with the answer (`.cancel`
/// for Escape or when the window closes). The strings are copied.
pub fn confirm(win: *Window, p: ConfirmProps, cb: ConfirmCb) !overlay.OverlayId {
    const gpa = win.gpa;
    const v = try gpa.create(ConfirmView);
    errdefer gpa.destroy(v);
    v.* = .{ .gpa = gpa, .win = win, .cb = cb, .props = p };
    v.strings = try std.mem.concat(gpa, u8, &.{ p.title, p.message, p.ok_label, p.cancel_label, p.alt_label orelse "" });
    errdefer gpa.free(v.strings);
    // Point the props at the owned copy.
    var off: usize = 0;
    inline for (.{ "title", "message", "ok_label", "cancel_label" }) |f| {
        const n = @field(p, f).len;
        @field(v.props, f) = v.strings[off..][0..n];
        off += n;
    }
    if (p.alt_label) |a| v.props.alt_label = v.strings[off..][0..a.len];
    v.id = try win.openOverlay(.of(v), .{
        .layer = .dialog,
        .modal = true,
        .light_dismiss = false,
        .title = v.props.title,
        .label = v.props.title,
        .test_id = "confirm",
        .width = p.size.width(win.size.w),
        .on_close = .{ .ctx = v, .f = ConfirmView.onClose },
    });
    return v.id;
}

/// The view behind `confirm`; freed when its overlay closes.
const ConfirmView = struct {
    gpa: std.mem.Allocator,
    win: *Window,
    cb: ConfirmCb,
    props: ConfirmProps,
    strings: []u8 = &.{},
    id: overlay.OverlayId = .none,
    result: Result = .cancel,

    pub fn build(self: *ConfirmView, ui: *Ui) void {
        const p = &self.props;
        ui.open(.{ .style = .{ .dir = .column, .gap = ui.theme().dim(.space_lg) } });
        defer ui.close();
        if (p.message.len > 0) ui.text(p.message, .{ .color = .fg_muted });
        ui.open(.{ .style = .{ .gap = ui.theme().dim(.space_sm), .justify = .end } });
        defer ui.close();
        if (p.alt_label) |a| {
            if (controls.button(ui, .{ .label = a }).clicked) self.answer(.alt);
            controls.spacer(ui);
        }
        const primary: controls.Variant = if (p.danger) .danger else .primary;
        if (primary_first) {
            if (controls.button(ui, .{ .label = p.ok_label, .variant = primary }).clicked) self.answer(.ok);
            if (controls.button(ui, .{ .label = p.cancel_label }).clicked) self.answer(.cancel);
        } else {
            if (controls.button(ui, .{ .label = p.cancel_label }).clicked) self.answer(.cancel);
            if (controls.button(ui, .{ .label = p.ok_label, .variant = primary }).clicked) self.answer(.ok);
        }
    }

    fn answer(self: *ConfirmView, r: Result) void {
        self.result = r;
        self.win.closeOverlay(self.id);
    }

    fn onClose(ctx: *anyopaque, _: overlay.OverlayId) void {
        const self: *ConfirmView = @ptrCast(@alignCast(ctx));
        const cb = self.cb;
        const r = self.result;
        const gpa = self.gpa;
        gpa.free(self.strings);
        gpa.destroy(self);
        cb.f(cb.ctx, r);
    }
};

test {
    std.testing.refAllDecls(@This());
}
