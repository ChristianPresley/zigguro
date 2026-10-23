//! Parser diagnostics (E13.F07.S02.T01): a message at a span, with the
//! 1-based line and column of its start.

const std = @import("std");
const ast = @import("ast.zig");

pub const Severity = enum { err, warning };

pub const Diagnostic = struct {
    span: ast.Span,
    line: u32,
    col: u32,
    message: []const u8,
    severity: Severity,
};

/// The 1-based line and column (in bytes) of `offset` in `src`.
pub fn lineCol(src: []const u8, offset: u32) struct { line: u32, col: u32 } {
    const at = @min(offset, src.len);
    var line: u32 = 1;
    var start: usize = 0;
    for (src[0..at], 0..) |c, i| if (c == '\n') {
        line += 1;
        start = i + 1;
    };
    return .{ .line = line, .col = @intCast(at - start + 1) };
}

/// Appends a diagnostic at `span`, its message formatted into `arena`.
pub fn add(
    arena: std.mem.Allocator,
    list: *std.ArrayList(Diagnostic),
    src: []const u8,
    severity: Severity,
    span: ast.Span,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const lc = lineCol(src, span.start);
    try list.append(arena, .{
        .span = span,
        .line = lc.line,
        .col = lc.col,
        .message = try std.fmt.allocPrint(arena, fmt, args),
        .severity = severity,
    });
}

/// "3:7: error: message" lines, for tests and the CLI.
pub fn format(w: *std.Io.Writer, list: []const Diagnostic) std.Io.Writer.Error!void {
    for (list) |d| try w.print("{d}:{d}: {s}: {s}\n", .{ d.line, d.col, if (d.severity == .err) "error" else "warning", d.message });
}

pub fn hasErrors(list: []const Diagnostic) bool {
    for (list) |d| if (d.severity == .err) return true;
    return false;
}

test "line and column" {
    const s = "ab\ncd\n\nx";
    try std.testing.expectEqual(@as(u32, 1), lineCol(s, 0).line);
    try std.testing.expectEqual(@as(u32, 2), lineCol(s, 4).line);
    try std.testing.expectEqual(@as(u32, 2), lineCol(s, 4).col);
    try std.testing.expectEqual(@as(u32, 4), lineCol(s, 7).line);
    try std.testing.expectEqual(@as(u32, 1), lineCol(s, 7).col);
}
