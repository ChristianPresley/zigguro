//! The environment block of the system prompt (E10.F07.S02.T01): working
//! directory, platform, shell, the date at day granularity (so the cached
//! prefix stays stable within a day), workspace roots and a git snapshot
//! taken at session start.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

/// What the block shows. Strings are borrowed.
pub const Env = struct {
    cwd: []const u8,
    platform: []const u8 = @tagName(builtin.os.tag),
    shell: ?[]const u8 = null,
    /// Unix milliseconds; rendered as `YYYY-MM-DD` (UTC).
    now_ms: i64,
    workspace_roots: []const []const u8 = &.{},
    /// E09 snapshot at session start (optional).
    git_branch: ?[]const u8 = null,
    git_status: ?[]const u8 = null,
};

/// `YYYY-MM-DD` of `ms` (UTC).
pub fn day(buf: *[10]u8, ms: i64) []const u8 {
    const secs: u64 = @intCast(@max(0, @divFloor(ms, 1000)));
    const ed = (std.time.epoch.EpochSeconds{ .secs = secs }).getEpochDay();
    const yd = ed.calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ yd.year, md.month.numeric(), md.day_index + 1 }) catch unreachable;
}

/// Renders the block.
pub fn render(arena: Allocator, e: Env) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var dbuf: [10]u8 = undefined;
    try out.print(arena, "<env>\nWorking directory: {s}\nPlatform: {s}\n", .{ e.cwd, e.platform });
    if (e.shell) |s| try out.print(arena, "Shell: {s}\n", .{s});
    try out.print(arena, "Today: {s}\n", .{day(&dbuf, e.now_ms)});
    for (e.workspace_roots) |r| try out.print(arena, "Workspace root: {s}\n", .{r});
    if (e.git_branch) |b| try out.print(arena, "Git branch: {s}\n", .{b});
    if (e.git_status) |s| try out.print(arena, "Git status at session start:\n{s}\n", .{std.mem.trimEnd(u8, s, "\n")});
    try out.appendSlice(arena, "</env>");
    return out.items;
}

test "env block" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const t = try render(arena.allocator(), .{ .cwd = "/w", .platform = "linux", .shell = "bash", .now_ms = 1792627200000 + 3_600_000, .git_branch = "main" });
    try std.testing.expectEqualStrings("<env>\nWorking directory: /w\nPlatform: linux\nShell: bash\nToday: 2026-10-22\nGit branch: main\n</env>", t);
}
