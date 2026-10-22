//! Ignore filters decide which paths a watcher skips. E08 supplies the real
//! one (gitignore rules); `none` and `NameList` cover tests and simple use.

const std = @import("std");

/// Decides whether a root-relative path is ignored. Directories that are
/// ignored are not watched at all.
pub const IgnoreFilter = struct {
    /// Filter state.
    ctx: *anyopaque,
    /// Returns true to skip `rel_path`. Called on the watcher thread.
    isIgnored: *const fn (ctx: *anyopaque, rel_path: []const u8, is_dir: bool) bool,

    /// A filter that ignores nothing.
    pub const none: IgnoreFilter = .{ .ctx = undefined, .isIgnored = never };

    fn never(_: *anyopaque, _: []const u8, _: bool) bool {
        return false;
    }

    /// Asks the filter about `rel_path`.
    pub fn ignored(f: *const IgnoreFilter, rel_path: []const u8, is_dir: bool) bool {
        return f.isIgnored(f.ctx, rel_path, is_dir);
    }
};

/// Ignores any path with a component equal to one of `names`, such as
/// `.git` or `zig-cache`.
pub const NameList = struct {
    /// Component names to ignore.
    names: []const []const u8,

    /// The filter; `self` must outlive it.
    pub fn filter(self: *NameList) IgnoreFilter {
        return .{ .ctx = self, .isIgnored = isIgnored };
    }

    fn isIgnored(ctx: *anyopaque, rel_path: []const u8, _: bool) bool {
        const self: *NameList = @ptrCast(@alignCast(ctx));
        var it = std.mem.splitScalar(u8, rel_path, '/');
        while (it.next()) |part| for (self.names) |n| if (std.mem.eql(u8, part, n)) return true;
        return false;
    }
};

test "NameList matches whole components" {
    var nl: NameList = .{ .names = &.{ ".git", "zig-out" } };
    const f = nl.filter();
    try std.testing.expect(f.ignored(".git", true));
    try std.testing.expect(f.ignored("a/.git/HEAD", false));
    try std.testing.expect(!f.ignored("a/.github/x", false));
    try std.testing.expect(!IgnoreFilter.none.ignored(".git", true));
}
