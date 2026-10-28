//! What the editor gutter shows for breakpoints and the execution pointer
//! (E07.F06.S03.T01). The app draws these into the E05 decoration store
//! under the owners below.
//!
//! - A breakpoint's glyph: disabled; a logpoint (diamond), conditional
//!   (`=`) or hit-count breakpoint; else a plain one. It is hollow while
//!   sessions run and none verified it, and warns when a session could
//!   not take all of it.
//! - The execution pointer: an arrow in the breakpoint lane and a line
//!   highlight for the top frame, a lighter style for a selected frame
//!   below it.

const std = @import("std");
const BreakpointManager = @import("BreakpointManager.zig");
const Allocator = std.mem.Allocator;

pub const owner_breakpoints = "dap.breakpoints";
pub const owner_exec = "dap.exec";

pub const Glyph = enum { breakpoint, conditional, logpoint, hit_count, disabled };

pub const Mark = struct {
    id: BreakpointManager.BpId,
    /// 1-based.
    line: u32,
    /// An inline breakpoint's column (1-based).
    column: ?u32,
    glyph: Glyph,
    hollow: bool,
    warning: bool,
    /// The hover text.
    message: ?[]const u8,
};

pub fn glyphOf(bp: BreakpointManager.Breakpoint) Glyph {
    if (!bp.enabled) return .disabled;
    const s = switch (bp.kind) {
        .source => |s| s,
        else => return .breakpoint,
    };
    if (s.log_message != null) return .logpoint;
    if (s.condition != null) return .conditional;
    if (s.hit_condition != null) return .hit_count;
    return .breakpoint;
}

/// The gutter marks of `path`, in `a`.
pub fn marks(m: *BreakpointManager, a: Allocator, path: []const u8) Allocator.Error![]Mark {
    const views = try m.inSource(a, path);
    const out = try a.alloc(Mark, views.len);
    for (out, views) |*o, v| {
        const s = v.bp.kind.source;
        o.* = .{
            .id = v.bp.id,
            .line = s.line,
            .column = s.column,
            .glyph = glyphOf(v.bp),
            .hollow = v.bp.enabled and v.sessions and !v.verified,
            .warning = v.unsupported,
            .message = v.message,
        };
    }
    return out;
}

pub const ExecStyle = enum { top, selected };

pub const ExecMark = struct {
    /// 1-based.
    line: u32,
    style: ExecStyle,
};

/// A stack frame's position.
pub const FramePos = struct { path: []const u8, line: u32 };

/// The execution pointer in `path`: the top frame's line and, when a frame
/// below it is selected, that one's. At most two marks.
pub fn execMarks(path: []const u8, top: ?FramePos, selected: ?FramePos, out: *[2]ExecMark) []ExecMark {
    var n: usize = 0;
    if (top) |t| if (std.mem.eql(u8, t.path, path)) {
        out[n] = .{ .line = t.line, .style = .top };
        n += 1;
    };
    if (selected) |s| if (std.mem.eql(u8, s.path, path)) {
        const same = if (top) |t| std.mem.eql(u8, t.path, s.path) and t.line == s.line else false;
        if (!same) {
            out[n] = .{ .line = s.line, .style = .selected };
            n += 1;
        }
    };
    return out[0..n];
}
