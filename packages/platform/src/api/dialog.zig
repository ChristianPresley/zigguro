//! Native file dialogs (portal FileChooser, IFileDialog).

const types = @import("types.zig");

/// The kind of file dialog.
pub const DialogKind = enum(u8) {
    /// Pick one existing file.
    open_file,
    /// Pick one or more existing files.
    open_files,
    /// Pick a directory.
    open_directory,
    /// Choose a path to save to.
    save_file,
};

/// A named file filter, such as "Zig sources" with `*.zig`.
pub const DialogFilter = struct {
    /// Label shown to the user.
    name: []const u8,
    /// Glob patterns such as "*.zig".
    patterns: []const []const u8,
};

/// A request for `Command.open_dialog`. The answer arrives later as
/// `Event.dialog_result` carrying the same `request` id.
pub const DialogRequest = struct {
    /// Caller-chosen id echoed in the result.
    request: u32,
    /// What to pick.
    kind: DialogKind,
    /// Window the dialog is modal to, if any.
    parent: ?types.WindowId = null,
    /// Dialog title.
    title: []const u8 = "",
    /// Starting directory or suggested file path.
    default_path: ?[]const u8 = null,
    /// Filters; empty shows every file.
    filters: []const DialogFilter = &.{},
};
