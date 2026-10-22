//! Modal input: Vim and Emacs keybindings as handlers over the editing
//! model (E05.F09).

/// Keys in Vim notation.
pub const key = @import("modes/key.zig");
/// The handler seam, the host and undo grouping.
pub const mode = @import("modes/mode.zig");
/// Vim mode.
pub const vim = @import("modes/vim.zig");

pub const Key = key.Key;
pub const Host = mode.Host;
pub const ModeHandler = mode.ModeHandler;
pub const VimState = vim.VimState;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("modes/vim/vim_core_test.zig");
}
