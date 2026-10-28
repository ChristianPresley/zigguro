//! perf-docs-check (E14.F02.S03.T02): fails when a trace_processor recipe
//! in tools/perf/sql/ is not referenced from docs/perf/profiling.md, so the
//! guide and the recipes cannot drift apart. Run from the repository root
//! (`zig build test` does).

const std = @import("std");

/// The recipe names in `names` that `doc` never mentions.
pub fn missing(gpa: std.mem.Allocator, doc: []const u8, names: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (names) |n| if (std.mem.indexOf(u8, doc, n) == null) try out.append(gpa, n);
    return out.toOwnedSlice(gpa);
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.arena.allocator();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    const doc = try cwd.readFileAlloc(io, "docs/perf/profiling.md", gpa, .limited(1 << 20));
    var dir = try cwd.openDir(io, "tools/perf/sql", .{ .iterate = true });
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind == .file and std.mem.endsWith(u8, e.name, ".sql")) try names.append(gpa, try gpa.dupe(u8, e.name));
    }
    const gone = try missing(gpa, doc, names.items);
    for (gone) |n| std.debug.print("perf-docs-check: tools/perf/sql/{s} is not referenced in docs/perf/profiling.md\n", .{n});
    return if (gone.len == 0) 0 else 1;
}

test "perf-docs-check: reports unreferenced recipes" {
    const gpa = std.testing.allocator;
    const gone = try missing(gpa, "see `a.sql` and b.sql", &.{ "a.sql", "b.sql", "c.sql" });
    defer gpa.free(gone);
    try std.testing.expectEqual(@as(usize, 1), gone.len);
    try std.testing.expectEqualStrings("c.sql", gone[0]);
}
