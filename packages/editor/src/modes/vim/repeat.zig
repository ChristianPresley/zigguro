//! Dot repeat (`.`): the last change as Vim's redo buffer has it, the
//! command (operator, motion or text object, count, register), the size
//! of the Visual area it worked on, and the keys typed in the insert or
//! replace session that followed. Replaying runs the command again at the
//! cursors and feeds the keys back, so smart-edit effects (auto-indent,
//! pairs) happen again rather than being pasted.

const std = @import("std");
const key_mod = @import("../key.zig");
const parser = @import("parser.zig");
const text_mod = @import("text.zig");
const visual_mod = @import("visual.zig");

const Allocator = std.mem.Allocator;
const Key = key_mod.Key;
const VimCommand = parser.VimCommand;
const Text = text_mod.Text;

pub const AreaMode = enum { visual, visual_line, visual_block };

/// The size of a Visual area, to select the same amount again.
pub const Extent = struct {
    mode: AreaMode,
    /// Lines below the first.
    lines: u64,
    /// Characterwise on one line: characters after the first; on several
    /// lines: the last line's column. A block: columns after the first.
    cols: u32,
    to_eol: bool = false,

    /// The extent of the area from `anchor` to `pos`.
    pub fn of(x: Text, mode: AreaMode, anchor: u64, pos: u64, want: ?u32) Extent {
        const lo = @min(anchor, pos);
        const hi = @max(anchor, pos);
        const lines = x.lineOf(hi) - x.lineOf(lo);
        return switch (mode) {
            .visual_line => .{ .mode = mode, .lines = lines, .cols = 0 },
            .visual => .{ .mode = mode, .lines = lines, .cols = if (lines == 0) x.column(hi) - x.column(lo) else x.column(hi) },
            .visual_block => blk: {
                const cols = visual_mod.blockColumns(x, .{ .anchor = anchor, .pos = pos, .want = want });
                break :blk .{ .mode = mode, .lines = lines, .cols = cols.right - cols.left, .to_eol = cols.to_eol };
            },
        };
    }

    /// The area of the same size starting at `p`: its other end.
    pub fn endFrom(e: Extent, x: Text, p: u64) u64 {
        const l0 = x.lineOf(p);
        const l1 = @min(l0 + e.lines, x.lineCount() - 1);
        return switch (e.mode) {
            .visual_line => x.lineStart(l1),
            .visual => if (e.lines == 0) x.atColumn(l0, x.column(p) + e.cols, false) else x.atColumn(l1, e.cols, false),
            .visual_block => x.atColumn(l1, x.column(p) + e.cols, true),
        };
    }
};

/// One recorded change.
pub const Change = struct {
    cmd: VimCommand,
    visual: ?Extent = null,
    /// Keys of the insert or replace session, up to and including `<Esc>`.
    keys: std.ArrayList(Key) = .empty,

    pub fn deinit(c: *Change, gpa: Allocator) void {
        c.keys.deinit(gpa);
    }
};

pub const Repeat = struct {
    last: ?Change = null,
    building: ?Change = null,
    /// The building change waits for its insert session to end.
    capturing: bool = false,
    /// A replay is running: nothing is recorded.
    replaying: bool = false,

    pub fn deinit(r: *Repeat, gpa: Allocator) void {
        if (r.last) |*c| c.deinit(gpa);
        if (r.building) |*c| c.deinit(gpa);
    }

    pub fn begin(r: *Repeat, gpa: Allocator, cmd: VimCommand, visual: ?Extent) void {
        r.abort(gpa);
        r.building = .{ .cmd = cmd, .visual = visual };
    }

    pub fn addKey(r: *Repeat, gpa: Allocator, k: Key) !void {
        if (r.building) |*c| try c.keys.append(gpa, k);
    }

    /// The building change becomes the one `.` repeats.
    pub fn commit(r: *Repeat, gpa: Allocator) void {
        const c = r.building orelse return;
        if (r.last) |*l| l.deinit(gpa);
        r.last = c;
        r.building = null;
        r.capturing = false;
    }

    pub fn abort(r: *Repeat, gpa: Allocator) void {
        if (r.building) |*c| c.deinit(gpa);
        r.building = null;
        r.capturing = false;
    }
};

/// Whether `cmd` is a change that `.` repeats (yanks, motions, undo and
/// mode switches are not).
pub fn repeatable(cmd: VimCommand, visual: bool) bool {
    if (cmd.target == .motion) switch (cmd.target.motion.m) {
        .search_prompt_forward, .search_prompt_backward => return false,
        else => {},
    };
    if (cmd.command) |c| return switch (c) {
        .delete_char, .delete_char_before, .substitute_char, .substitute_line, .change_to_eol, .delete_to_eol, .put_after, .put_before, .join, .join_raw, .replace_char, .toggle_case_char, .insert, .append, .insert_line_start, .insert_column_0, .append_line_end, .open_below, .open_above, .replace_mode => true,
        .block_insert, .block_append => visual,
        else => false,
    };
    if (cmd.op) |op| return op != .yank;
    return false;
}
