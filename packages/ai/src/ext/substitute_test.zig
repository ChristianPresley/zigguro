const std = @import("std");
const sub = @import("substitute.zig");

const testing = std.testing;

const Case = struct {
    body: []const u8,
    args: []const u8 = "",
    names: []const []const u8 = &.{},
    compat: bool = false,
    want: []const u8,
};

const vars: sub.Vars = .{ .session_id = "S1", .skill_dir = "/skills/deploy", .project_dir = "/work" };

const cases = [_]Case{
    .{ .body = "Fix $ARGUMENTS now.", .args = "issue 12", .want = "Fix issue 12 now." },
    .{ .body = "First $0, second $1.", .args = "a b", .want = "First a, second b." },
    .{ .body = "Missing [$2].", .args = "a b", .want = "Missing []." },
    .{ .body = "$ARGUMENTS[1]/$ARGUMENTS[0]", .args = "x y", .want = "y/x" },
    .{ .body = "Quoted: $0|$1", .args = "\"hello world\" 'it''s'", .want = "Quoted: hello world|its" },
    .{ .body = "Escaped: $0", .args = "a\\ b c", .want = "Escaped: a b" },
    .{ .body = "Inner: $0", .args = "\"say \\\"hi\\\"\"", .want = "Inner: say \"hi\"" },
    .{ .body = "Issue $issue on $branch.", .args = "42 main", .names = &.{ "issue", "branch" }, .want = "Issue 42 on main." },
    .{ .body = "Named missing: [$branch]", .args = "42", .names = &.{ "issue", "branch" }, .want = "Named missing: []" },
    .{ .body = "Keep $HOME and $PATH.", .args = "", .want = "Keep $HOME and $PATH." },
    .{ .body = "Price \\$1 and $0", .args = "x", .want = "Price $1 and x" },
    .{ .body = "Literal \\$ARGUMENTS", .args = "", .want = "Literal $ARGUMENTS" },
    .{ .body = "Do the thing.", .args = "fast please", .want = "Do the thing.\n\nARGUMENTS: fast please" },
    .{ .body = "Do the thing.\n", .args = "x", .want = "Do the thing.\n\nARGUMENTS: x" },
    .{ .body = "No args.", .args = "   ", .want = "No args." },
    .{ .body = "Session ${ZIGGURO_SESSION_ID} in ${ZIGGURO_PROJECT_DIR}", .want = "Session S1 in /work" },
    .{ .body = "Run ${ZIGGURO_SKILL_DIR}/run.sh", .want = "Run /skills/deploy/run.sh" },
    .{ .body = "${CLAUDE_SKILL_DIR}/x", .compat = true, .want = "/skills/deploy/x" },
    .{ .body = "${CLAUDE_SKILL_DIR}/x", .want = "${CLAUDE_SKILL_DIR}/x" },
    .{ .body = "$ARGUMENTSX stays, $ARGUMENTS goes", .args = "v", .want = "$ARGUMENTSX stays, v goes" },
    .{ .body = "Trailing $", .args = "", .want = "Trailing $" },
    .{ .body = "${UNKNOWN} and $0", .args = "z", .want = "${UNKNOWN} and z" },
};

test "substitution_table" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for (cases, 0..) |c, k| {
        var v = vars;
        v.compat = c.compat;
        const got = try sub.substitute(arena.allocator(), c.body, c.args, c.names, v);
        testing.expectEqualStrings(c.want, got) catch |e| {
            std.debug.print("case {d}: {s}\n", .{ k, c.body });
            return e;
        };
    }
}

test "split args" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try sub.splitArgs(a, "  one 'two three' \"fo\\\"ur\" fi\\ ve '' ");
    try testing.expectEqual(@as(usize, 5), got.len);
    try testing.expectEqualStrings("one", got[0]);
    try testing.expectEqualStrings("two three", got[1]);
    try testing.expectEqualStrings("fo\"ur", got[2]);
    try testing.expectEqualStrings("fi ve", got[3]);
    try testing.expectEqualStrings("", got[4]);
}
