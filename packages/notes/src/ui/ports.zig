//! What the notes UI needs from the app: applying user edits, running
//! work off the UI thread, waking the UI, and opening notes.

const std = @import("std");
const zg_notes = @import("zg_notes");

/// One file's new bytes (`base` null creates it).
pub const FileChange = zg_notes.ai.tools.FileChange;

/// Applies user edits at once: through E05.F08 for open documents (one
/// undo step), else as a user-actor E12 changeset with `auto_apply`.
pub const ApplyPort = struct {
    ctx: *anyopaque,
    apply: *const fn (ctx: *anyopaque, label: []const u8, changes: []const FileChange) anyerror!u64,
};

/// Runs `f(arg)` on a worker. Null ports run it inline.
pub const Spawn = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque, f: *const fn (arg: *anyopaque) void, arg: *anyopaque) void,
};

/// Asks the UI to rebuild (any thread).
pub const Notify = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque) void,

    pub fn call(n: ?Notify) void {
        if (n) |x| x.f(x.ctx);
    }
};

/// Opens a vault-relative note, selecting `range` (its bytes), in the
/// active group or to the side.
pub const OpenPort = struct {
    ctx: *anyopaque,
    open: *const fn (ctx: *anyopaque, path: []const u8, range: ?[2]u32, to_side: bool) void,
};
