//! Vim mode (E05.F09.S01): the parser, motions, operators, text objects,
//! Visual modes and the state machine that runs them.

pub const text = @import("vim/text.zig");
pub const motions = @import("vim/motions.zig");
pub const text_objects = @import("vim/text_objects.zig");
pub const parser = @import("vim/parser.zig");
pub const operators = @import("vim/operators.zig");
pub const visual = @import("vim/visual.zig");
pub const pattern = @import("vim/pattern.zig");
pub const registers = @import("vim/registers.zig");
pub const marks = @import("vim/marks.zig");
pub const macros = @import("vim/macros.zig");
pub const search = @import("vim/search.zig");
pub const repeat = @import("vim/repeat.zig");
pub const ex = @import("vim/ex.zig");
pub const state = @import("vim/state.zig");

pub const VimState = state.VimState;
pub const Mode = state.Mode;
pub const VimCommand = parser.VimCommand;

test {
    @import("std").testing.refAllDecls(@This());
}
