//! Mission Control's dispatch box (E13.F01.S02.T01): `@agent` picks an
//! E10 agent definition, `/skill args` invokes a skill or command, `! cmd`
//! asks for a shell-only run and `+lane` forces lane isolation. `@agent`
//! and `+lane` may come in any order before the rest. Pure.

const std = @import("std");
const run = @import("../runs/run.zig");

pub const Dispatch = struct {
    agent: ?[]const u8 = null,
    skill: ?[]const u8 = null,
    /// The prompt, or the skill's arguments.
    args: []const u8 = "",
    lane: bool = false,
    /// `! cmd`: the command.
    shell: ?[]const u8 = null,

    pub fn isEmpty(d: Dispatch) bool {
        return d.skill == null and d.shell == null and d.args.len == 0;
    }
};

/// Parses `text`; strings point into it.
pub fn parseDispatch(text: []const u8) Dispatch {
    var d: Dispatch = .{};
    var rest = std.mem.trim(u8, text, &std.ascii.whitespace);
    while (rest.len > 0) {
        const end = std.mem.indexOfAny(u8, rest, &std.ascii.whitespace) orelse rest.len;
        const word = rest[0..end];
        if (std.mem.eql(u8, word, "+lane")) {
            d.lane = true;
        } else if (word.len > 1 and word[0] == '@' and d.agent == null) {
            d.agent = word[1..];
        } else break;
        rest = std.mem.trimStart(u8, rest[end..], &std.ascii.whitespace);
    }
    if (rest.len > 0 and rest[0] == '!') {
        const cmd = std.mem.trim(u8, rest[1..], &std.ascii.whitespace);
        if (cmd.len > 0) d.shell = cmd;
        return d;
    }
    if (rest.len > 1 and rest[0] == '/' and !std.ascii.isWhitespace(rest[1]) and rest[1] != '/') {
        const end = std.mem.indexOfAny(u8, rest, &std.ascii.whitespace) orelse rest.len;
        d.skill = rest[1..end];
        d.args = std.mem.trim(u8, rest[end..], &std.ascii.whitespace);
        return d;
    }
    d.args = rest;
    return d;
}

/// The run spec for `d`. `buf` holds the generated title and prompt (the
/// spec's strings point into it or into `d`). A shell run is an agent run
/// asked to run exactly that command, so the command still goes through
/// the profile's permission checks; nothing executes it directly.
pub fn toSpec(d: Dispatch, buf: []u8) error{NoSpaceLeft}!run.RunSpec {
    var w: std.Io.Writer = .fixed(buf);
    const prompt: []const u8 = if (d.shell) |cmd| blk: {
        w.print("Run this shell command in the terminal and report its output:\n\n```sh\n{s}\n```\n", .{cmd}) catch return error.NoSpaceLeft;
        break :blk w.buffered();
    } else if (d.skill) |s| blk: {
        w.print("/{s}{s}{s}", .{ s, if (d.args.len > 0) " " else "", d.args }) catch return error.NoSpaceLeft;
        break :blk w.buffered();
    } else d.args;
    const title_src = d.shell orelse if (d.skill != null) prompt else d.args;
    const first_line = title_src[0 .. std.mem.indexOfScalar(u8, title_src, '\n') orelse title_src.len];
    const title = first_line[0..@min(first_line.len, 80)];
    return .{
        .kind = .background,
        .title = title,
        .prompt = prompt,
        .agent_def = d.agent,
        .isolation = if (d.lane) .lane else .shared,
        .tags = if (d.shell != null) &shell_tags else &.{},
    };
}

const shell_tags = [_][]const u8{"shell"};

const testing = std.testing;

test "dispatch_parse_table" {
    const Case = struct { in: []const u8, want: Dispatch };
    const cases = [_]Case{
        .{ .in = "", .want = .{} },
        .{ .in = "   ", .want = .{} },
        .{ .in = "fix the build", .want = .{ .args = "fix the build" } },
        .{ .in = "@reviewer look at main", .want = .{ .agent = "reviewer", .args = "look at main" } },
        .{ .in = "/triage label new issues", .want = .{ .skill = "triage", .args = "label new issues" } },
        .{ .in = "/triage", .want = .{ .skill = "triage" } },
        .{ .in = "! zig build test", .want = .{ .shell = "zig build test" } },
        .{ .in = "!ls", .want = .{ .shell = "ls" } },
        .{ .in = "!", .want = .{} },
        .{ .in = "+lane refactor x", .want = .{ .lane = true, .args = "refactor x" } },
        .{ .in = "@coder +lane /fix bug 12", .want = .{ .agent = "coder", .lane = true, .skill = "fix", .args = "bug 12" } },
        .{ .in = "+lane @coder ! make", .want = .{ .agent = "coder", .lane = true, .shell = "make" } },
        // Only leading tokens are special.
        .{ .in = "email @bob about +lane", .want = .{ .args = "email @bob about +lane" } },
        .{ .in = "@a @b hi", .want = .{ .agent = "a", .args = "@b hi" } },
        .{ .in = "@ hi", .want = .{ .args = "@ hi" } },
        .{ .in = "/ not a skill", .want = .{ .args = "/ not a skill" } },
        .{ .in = "// comment", .want = .{ .args = "// comment" } },
        .{ .in = "  /deploy   prod  ", .want = .{ .skill = "deploy", .args = "prod" } },
    };
    for (cases) |c| {
        const got = parseDispatch(c.in);
        errdefer std.debug.print("case: '{s}'\n", .{c.in});
        try testing.expectEqual(c.want.lane, got.lane);
        try expectOpt(c.want.agent, got.agent);
        try expectOpt(c.want.skill, got.skill);
        try expectOpt(c.want.shell, got.shell);
        try testing.expectEqualStrings(c.want.args, got.args);
    }
}

fn expectOpt(want: ?[]const u8, got: ?[]const u8) !void {
    if (want) |w| try testing.expectEqualStrings(w, got orelse return error.TestExpectedEqual) else try testing.expect(got == null);
}

test "dispatch to spec" {
    var buf: [512]u8 = undefined;
    const s = try toSpec(parseDispatch("@coder +lane /fix bug 12"), &buf);
    try testing.expectEqualStrings("/fix bug 12", s.prompt);
    try testing.expectEqualStrings("coder", s.agent_def.?);
    try testing.expectEqual(run.Isolation.lane, s.isolation);
    const sh = try toSpec(parseDispatch("! zig build"), &buf);
    try testing.expectEqualStrings("zig build", sh.title);
    try testing.expect(std.mem.indexOf(u8, sh.prompt, "```sh\nzig build\n```") != null);
    try testing.expectEqualStrings("shell", sh.tags[0]);
}
