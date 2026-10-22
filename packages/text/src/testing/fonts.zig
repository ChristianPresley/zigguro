//! Test helpers: load files from `testdata/` by path relative to the
//! package root (never the cwd).

const std = @import("std");
const options = @import("zg_options");

/// Reads `testdata/<rel>` into memory owned by `gpa`.
pub fn readTestdata(gpa: std.mem.Allocator, rel: []const u8) ![]u8 {
    const io = std.testing.io;
    var root = try std.Io.Dir.openDirAbsolute(io, options.package_root, .{});
    defer root.close(io);
    var td = try root.openDir(io, "testdata", .{});
    defer td.close(io);
    return td.readFileAlloc(io, rel, gpa, .limited(64 << 20));
}

/// Reads `testdata/<rel>` with a trailing NUL (for `std.zon.parse`).
pub fn readTestdataZ(gpa: std.mem.Allocator, rel: []const u8) ![:0]u8 {
    const data = try readTestdata(gpa, rel);
    defer gpa.free(data);
    return gpa.dupeZ(u8, data);
}

/// Reads font `name` from `testdata/fonts/`.
pub fn font(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    var buf: [256]u8 = undefined;
    return readTestdata(gpa, try std.fmt.bufPrint(&buf, "fonts/{s}", .{name}));
}

/// One `testdata/fonts/manifest.zon` entry.
pub const ManifestEntry = struct {
    file: []const u8,
    source: []const u8,
    version: []const u8,
    license: []const u8,
    license_file: []const u8,
    modification: []const u8,
    sha256: []const u8,
};

/// The parsed manifest; free with `std.zon.parse.free`.
pub fn manifest(gpa: std.mem.Allocator) ![]ManifestEntry {
    const src = try readTestdataZ(gpa, "fonts/manifest.zon");
    defer gpa.free(src);
    return std.zon.parse.fromSliceAlloc([]ManifestEntry, gpa, src, null, .{});
}
