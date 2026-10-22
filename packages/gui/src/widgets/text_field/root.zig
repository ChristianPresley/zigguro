//! Text input (E04.F05.S02): the gap buffer, undo, editing commands and
//! the `TextField` widget.

const std = @import("std");

/// The `model.zig` module.
pub const model = @import("model.zig");
/// The `undo.zig` module.
pub const undo = @import("undo.zig");
/// The `commands.zig` module.
pub const commands = @import("commands.zig");
/// The `ime.zig` module.
pub const ime = @import("ime.zig");
/// The `prompt_hooks.zig` module.
pub const prompt_hooks = @import("prompt_hooks.zig");
/// The `view.zig` module.
pub const view = @import("view.zig");

/// See `model.TextBuffer`.
pub const TextBuffer = model.TextBuffer;
/// See `model.Selection`.
pub const Selection = model.Selection;
/// See `view.TextField`.
pub const TextField = view.TextField;
/// See `view.ImeHooks`.
pub const ImeHooks = view.ImeHooks;
/// See `prompt_hooks.PromptHooks`.
pub const PromptHooks = prompt_hooks.PromptHooks;
/// See `view.textField`.
pub const textField = view.textField;

test {
    std.testing.refAllDecls(@This());
}
