//! Vim mode (E05.F09.S01): the parser, motions, operators, text objects,
//! Visual modes and the state machine that runs them.

pub const text = @import("vim/text.zig");
pub const motions = @import("vim/motions.zig");
pub const text_objects = @import("vim/text_objects.zig");
pub const parser = @import("vim/parser.zig");
pub const operators = @import("vim/operators.zig");
pub const visual = @import("vim/visual.zig");
pub const state = @import("vim/state.zig");

pub const VimState = state.VimState;
pub const Mode = state.Mode;
pub const VimCommand = parser.VimCommand;

test {
    @import("std").testing.refAllDecls(@This());
}
