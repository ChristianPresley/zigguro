//! Test helper: reads files under the package's `testdata/` directory, which
//! lies outside the module root and so cannot be embedded.

const std = @import("std");
const options = @import("zg_options");

/// Reads `rel` (relative to `packages/workspace/`) into a sentinel-terminated
/// buffer owned by the caller.
pub fn read(gpa: std.mem.Allocator, rel: []const u8) ![:0]u8 {
    const io = std.testing.io;
    var root = try std.Io.Dir.openDirAbsolute(io, options.package_root, .{});
    defer root.close(io);
    const bytes = try root.readFileAlloc(io, rel, gpa, .limited(64 << 20));
    defer gpa.free(bytes);
    return gpa.dupeZ(u8, bytes);
}

/// Opens `rel` (a directory relative to `packages/workspace/`).
pub fn openDir(rel: []const u8) !std.Io.Dir {
    const io = std.testing.io;
    var root = try std.Io.Dir.openDirAbsolute(io, options.package_root, .{});
    defer root.close(io);
    return root.openDir(io, rel, .{ .iterate = true });
}
