//! Key routing hooks: the seam where E15's keymap resolver and command
//! registry plug into a window (#1077), plus key-context collection along
//! the focus path (the input to E15 when-clauses).

const std = @import("std");
const event = @import("event.zig");

/// Resolves a key press that no focused widget handled. `contexts` lists
/// the `key_context` strings of the focused node's ancestors, innermost
/// first. Return true when the key ran an action.
pub const KeyHandler = struct {
    ptr: *anyopaque,
    handle: *const fn (ptr: *anyopaque, key: event.KeyPress, contexts: []const []const u8) bool,

    /// Calls the handler.
    pub fn call(h: KeyHandler, key: event.KeyPress, contexts: []const []const u8) bool {
        return h.handle(h.ptr, key, contexts);
    }
};

/// Sees every key event before the focused node (the menubar's Alt and
/// Alt+letter handling). Return true to consume the key.
pub const KeyFilter = struct {
    ptr: *anyopaque,
    filter: *const fn (ptr: *anyopaque, key: event.KeyPress) bool,
};

test {
    std.testing.refAllDecls(@This());
}
