//! Model-facing validation errors: short, specific and self-correctable
//! (Anthropic's guidance for `is_error` tool results is to say what went
//! wrong and what to try next).

const std = @import("std");
const validate = @import("validate.zig");

/// Maximum lines in the message, including the closing instruction.
pub const max_lines = 5;

/// Writes at most 5 lines: up to 4 `Invalid input for <tool>: <pointer>:
/// <message>` lines (the last may summarise the rest), then `Fix the input
/// and call the tool again.`
pub fn formatForModel(tool: []const u8, errs: *const validate.ErrorList, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const list = errs.slice();
    const total = list.len + errs.overflow;
    const shown = @min(list.len, max_lines - 1);
    for (list[0..shown], 0..) |e, i| {
        if (i == max_lines - 2 and total > shown) {
            try w.print("Invalid input for {s}: {d} more errors (first: {s}: {s})\n", .{ tool, total - i, ptr(e.pointer), e.message });
            break;
        }
        try w.print("Invalid input for {s}: {s}: {s}\n", .{ tool, ptr(e.pointer), e.message });
    }
    if (list.len == 0) try w.print("Invalid input for {s}\n", .{tool});
    try w.writeAll("Fix the input and call the tool again.");
}

fn ptr(p: []const u8) []const u8 {
    return if (p.len == 0) "/" else p;
}

test "format_for_model_caps_at_5_lines" {
    var errs: validate.ErrorList = .{};
    for (0..10) |_| errs.add(.{ .pointer = "/edits/0/old_string", .keyword = "required", .message = "missing required property" });
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try formatForModel("edit_file", &errs, &w);
    const out = w.buffered();
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, out, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, out, "7 more errors") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "Fix the input and call the tool again."));

    var one: validate.ErrorList = .{};
    one.add(.{ .pointer = "", .keyword = "type", .message = "expected an object" });
    w = .fixed(&buf);
    try formatForModel("read_file", &one, &w);
    try std.testing.expectEqualStrings("Invalid input for read_file: /: expected an object\nFix the input and call the tool again.", w.buffered());
}
