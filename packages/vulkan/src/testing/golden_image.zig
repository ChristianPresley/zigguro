//! Golden-image tests, following E00.F07's golden conventions.
//!
//! `expectImage(io, @src(), "name", img, tol)` called from
//! `src/foo/bar.zig` compares `img` with
//! `<package>/testdata/golden/bar/name.png` (resolved against
//! `zg_options.package_root`). With `-Dupdate-golden` the file is
//! (re)written instead. On mismatch `name.actual.png` and `name.diff.png`
//! are written beside the golden (git-ignored) and their paths printed.
//! Goldens always come from the software renderer; GPU output is compared
//! against them with a tolerance (`Tolerance.gpu`).

const std = @import("std");
const options = @import("zg_options");
const CpuImage = @import("CpuImage.zig");
const png = @import("png.zig");
const image_diff = @import("image_diff.zig");

/// See `image_diff.zig`.
pub const Tolerance = image_diff.Tolerance;

/// Errors from golden comparisons.
pub const Error = error{ GoldenMismatch, GoldenMissing };

/// Overrides for `expectImageOpts`.
pub const Options = struct {
    /// Directory relative to the package root (default `testdata/golden/<file stem>`).
    dir: ?[]const u8 = null,
    /// Package root (default `zg_options.package_root`).
    root: ?[]const u8 = null,
    /// Update mode (default `zg_options.update_golden`).
    update: ?bool = null,
    /// Where messages go (default stderr).
    report: ?*std.Io.Writer = null,
};

/// Compares `img` with the golden PNG `name`.
pub fn expectImage(io: std.Io, comptime src: std.builtin.SourceLocation, name: []const u8, img: *const CpuImage, tol: Tolerance) !void {
    return expectImageOpts(io, src, name, img, tol, .{});
}

/// `expectImage` with options.
pub fn expectImageOpts(io: std.Io, comptime src: std.builtin.SourceLocation, name: []const u8, img: *const CpuImage, tol: Tolerance, opts: Options) !void {
    const stem = comptime std.fs.path.stem(src.file);
    return compareInDir(io, opts.dir orelse "testdata/golden/" ++ stem, name, img, tol, opts);
}

/// The comparison behind `expectImage`, with an explicit directory
/// (relative to the package root). Used by the scene parity runner.
pub fn compareInDir(io: std.Io, rel_dir: []const u8, name: []const u8, img: *const CpuImage, tol: Tolerance, opts: Options) !void {
    const gpa = std.testing.allocator;
    var root = try std.Io.Dir.openDirAbsolute(io, opts.root orelse options.package_root, .{});
    defer root.close(io);
    const file_name = try std.fmt.allocPrint(gpa, "{s}/{s}.png", .{ rel_dir, name });
    defer gpa.free(file_name);

    if (opts.update orelse options.update_golden) {
        try root.createDirPath(io, rel_dir);
        try writePng(io, gpa, root, file_name, img);
        return;
    }

    const bytes = root.readFileAlloc(io, file_name, gpa, .limited(256 << 20)) catch |err| switch (err) {
        error.FileNotFound => {
            report(opts, "golden image {s} is missing; run `zig build test -Dupdate-golden` to create it\n", .{file_name});
            return error.GoldenMissing;
        },
        else => return err,
    };
    defer gpa.free(bytes);
    var want = try png.decodePng(gpa, bytes);
    defer want.deinit(gpa);
    var res = try image_diff.diff(gpa, &want, img, tol, true);
    defer res.deinit(gpa);
    if (res.pass) return;

    const actual_name = try std.fmt.allocPrint(gpa, "{s}/{s}.actual.png", .{ rel_dir, name });
    defer gpa.free(actual_name);
    const diff_name = try std.fmt.allocPrint(gpa, "{s}/{s}.diff.png", .{ rel_dir, name });
    defer gpa.free(diff_name);
    writePng(io, gpa, root, actual_name, img) catch {};
    if (res.diff_image) |*d| writePng(io, gpa, root, diff_name, d) catch {};
    if (want.width != img.width or want.height != img.height) {
        report(opts, "golden image mismatch: {s} is {d}x{d}, actual is {d}x{d} (actual: {s})\n", .{ file_name, want.width, want.height, img.width, img.height, actual_name });
    } else {
        report(opts, "golden image mismatch: {s}: {d} pixels differ by more than {d} (max diff {d}, {d} allowed); actual: {s}, diff: {s}\n", .{ file_name, res.bad_pixels, tol.max_channel_diff, res.max_diff, tol.max_bad_pixels, actual_name, diff_name });
    }
    return error.GoldenMismatch;
}

fn report(opts: Options, comptime fmt: []const u8, args: anytype) void {
    if (opts.report) |w| w.print(fmt, args) catch {} else std.debug.print(fmt, args);
}

fn writePng(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir, path: []const u8, img: *const CpuImage) !void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try png.encodePng(gpa, img, &out.writer);
    try dir.writeFile(io, .{ .sub_path = path, .data = out.written() });
}

test "golden: missing file message; update mode writes" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const root = path_buf[0..n];

    var img = try CpuImage.init(gpa, 3, 3);
    defer img.deinit(gpa);
    img.fill(.{ 9, 8, 7, 255 });

    var msg: std.Io.Writer.Allocating = .init(gpa);
    defer msg.deinit();
    try std.testing.expectError(error.GoldenMissing, expectImageOpts(io, @src(), "sq", &img, .{}, .{ .root = root, .update = false, .report = &msg.writer }));
    try std.testing.expect(std.mem.indexOf(u8, msg.written(), "-Dupdate-golden") != null);

    try expectImageOpts(io, @src(), "sq", &img, .{}, .{ .root = root, .update = true });
    try expectImageOpts(io, @src(), "sq", &img, .{}, .{ .root = root, .update = false });

    img.set(1, 1, .{ 0, 0, 0, 255 });
    msg.clearRetainingCapacity();
    try std.testing.expectError(error.GoldenMismatch, expectImageOpts(io, @src(), "sq", &img, .{}, .{ .root = root, .update = false, .report = &msg.writer }));
    try std.testing.expect(std.mem.indexOf(u8, msg.written(), "sq.diff.png") != null);
    try tmp.dir.access(io, "testdata/golden/golden_image/sq.actual.png", .{});
    try tmp.dir.access(io, "testdata/golden/golden_image/sq.diff.png", .{});
    // Within tolerance passes.
    try expectImageOpts(io, @src(), "sq", &img, .{ .max_bad_pixels = 1 }, .{ .root = root, .update = false });
}
