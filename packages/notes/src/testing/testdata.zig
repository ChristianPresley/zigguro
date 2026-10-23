//! Test helper: opens directories under the package's `testdata/`, which
//! lies outside the module root and so cannot be embedded.

const std = @import("std");
const options = @import("zg_options");

/// Opens `rel` (a directory relative to `packages/notes/`).
pub fn openDir(rel: []const u8) !std.Io.Dir {
    const io = std.testing.io;
    var root = try std.Io.Dir.openDirAbsolute(io, options.package_root, .{});
    defer root.close(io);
    return root.openDir(io, rel, .{ .iterate = true });
}
