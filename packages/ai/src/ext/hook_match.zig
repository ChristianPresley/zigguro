//! Hook matchers (E10.F09.S03.T01), as in Claude Code: `*`, empty or
//! omitted matches everything; a matcher of only letters, digits, `_`,
//! `-`, spaces, commas and `|` is a list of exact names; anything else is
//! a `zg_regex` pattern searched unanchored. Tool names match by their
//! zigguro name or any Claude Code alias (`Bash` for `run_command`).

const std = @import("std");
const zg_regex = @import("zg_regex");
const defs = @import("../subagent/defs.zig");

const Allocator = std.mem.Allocator;

pub const Matcher = union(enum) {
    all,
    names: []const []const u8,
    regex: zg_regex.Regex,

    /// Compiles `text`; regexes and names live in `arena`.
    pub fn compile(arena: Allocator, text: []const u8) !Matcher {
        const t = std.mem.trim(u8, text, " \t");
        if (t.len == 0 or std.mem.eql(u8, t, "*")) return .all;
        for (t) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == ' ' or c == ',' or c == '|')) {
            return .{ .regex = try zg_regex.Regex.compile(arena, t, .{}) };
        };
        var out: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeAny(u8, t, "|, ");
        while (it.next()) |n| try out.append(arena, try arena.dupe(u8, n));
        return .{ .names = out.items };
    }

    /// Whether `key` (a tool name, a session source, ...) matches, or one
    /// of the tool's compat aliases does.
    pub fn matches(m: *const Matcher, scratch: Allocator, key: []const u8) bool {
        switch (m.*) {
            .all => return true,
            .names => |ns| {
                for (ns) |n| {
                    if (std.mem.eql(u8, n, key)) return true;
                    if (aliasOf(n)) |real| if (std.mem.eql(u8, real, key)) return true;
                }
                return false;
            },
            .regex => |*re| {
                var cache = re.newCache(scratch) catch return false;
                if (re.isMatch(&cache, .fromSlice(key))) return true;
                for (defs.compat_aliases) |c| if (std.mem.eql(u8, c[1], key) and re.isMatch(&cache, .fromSlice(c[0]))) return true;
                return false;
            },
        }
    }
};

/// The zigguro tool a Claude Code name stands for.
fn aliasOf(name: []const u8) ?[]const u8 {
    for (defs.compat_aliases) |c| if (std.mem.eql(u8, c[0], name)) return c[1];
    return null;
}

test "matcher forms" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = std.testing;
    try t.expect((try Matcher.compile(a, "")).matches(a, "anything"));
    try t.expect((try Matcher.compile(a, "*")).matches(a, "anything"));
    const list = try Matcher.compile(a, "Edit|write_file");
    try t.expect(list == .names);
    try t.expect(list.matches(a, "edit_file"));
    try t.expect(list.matches(a, "write_file"));
    try t.expect(!list.matches(a, "read_file"));
    const re = try Matcher.compile(a, "^(Bash|mcp__.*)$");
    try t.expect(re == .regex);
    try t.expect(re.matches(a, "run_command"));
    try t.expect(re.matches(a, "mcp__github__search"));
    try t.expect(!re.matches(a, "read_file"));
    try t.expect((try Matcher.compile(a, "file")).matches(a, "file"));
    try t.expect((try Matcher.compile(a, ".*_file")).matches(a, "read_file"));
}
