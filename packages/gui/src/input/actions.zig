//! Actions: the seam where menus (and later the command palette and
//! toolbar) hand a chosen command to E15's command registry (#1077).
//!
//! Until E04.F03.S02.T01 lands its full dispatcher, an action is a command
//! id string ("file.open") plus an optional argument, run by the window's
//! `ActionHandler`.

const std = @import("std");

/// A command id, such as "editor.action.copy".
pub const ActionId = []const u8;

/// Runs actions for a window and, optionally, labels their shortcuts.
pub const ActionHandler = struct {
    ptr: *anyopaque,
    run: *const fn (ptr: *anyopaque, action: ActionId, arg: ?[]const u8) bool,
    /// The key binding shown next to `action` in menus ("Ctrl+O"), or null.
    /// The string must stay valid until the next call.
    label_for: ?*const fn (ptr: *anyopaque, action: ActionId) ?[]const u8 = null,

    /// Runs `action`; true when something handled it.
    pub fn call(h: ActionHandler, action: ActionId, arg: ?[]const u8) bool {
        return h.run(h.ptr, action, arg);
    }

    /// The shortcut label for `action`, if the handler knows one.
    pub fn labelFor(h: ActionHandler, action: ActionId) ?[]const u8 {
        const f = h.label_for orelse return null;
        return f(h.ptr, action);
    }
};

test "handler forwards" {
    const Rec = struct {
        last: []const u8 = "",
        fn run(p: *anyopaque, a: ActionId, _: ?[]const u8) bool {
            const r: *@This() = @ptrCast(@alignCast(p));
            r.last = a;
            return true;
        }
    };
    var r: Rec = .{};
    const h: ActionHandler = .{ .ptr = &r, .run = Rec.run };
    try std.testing.expect(h.call("file.open", null));
    try std.testing.expectEqualStrings("file.open", r.last);
    try std.testing.expect(h.labelFor("file.open") == null);
}
