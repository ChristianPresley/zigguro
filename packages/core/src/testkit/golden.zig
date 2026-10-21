//! Golden (snapshot) tests for text output.
//!
//! The golden file for `expectGolden(io, @src(), "name", actual)` called from
//! `src/foo/bar.zig` is `<package>/testdata/golden/bar/name.golden`, resolved
//! against `zg_options.package_root` (injected per package by
//! `zg_build.addPackage`), never the cwd. Run with `-Dupdate-golden` to
//! (re)write golden files. On mismatch a unified diff is printed and the
//! actual output is written beside the golden file as `<name>.golden.actual`
//! (git-ignored).

const std = @import("std");
const options = @import("zg_options");
const diff = @import("diff.zig");

/// How outputs are normalised before comparison.
pub const Normalize = enum {
    /// Byte-exact.
    exact,
    /// LF line endings, trailing whitespace stripped, exactly one final LF.
    text,
};

/// Options for `expectGoldenOpts`.
pub const Options = struct {
    normalize: Normalize = .text,
    /// Override the directory (relative to the package root) holding the file.
    dir: ?[]const u8 = null,
    /// Override the package root (defaults to `zg_options.package_root`).
    root: ?[]const u8 = null,
    /// Override update mode (defaults to `zg_options.update_golden`).
    update: ?bool = null,
    /// Where the diff goes on mismatch (defaults to stderr).
    report: ?*std.Io.Writer = null,
};

/// Errors from golden comparisons.
pub const Error = error{ GoldenMismatch, GoldenMissing } || std.mem.Allocator.Error;

/// Compares `actual` with the golden file named `name` (text-normalised).
pub fn expectGolden(io: std.Io, comptime src: std.builtin.SourceLocation, name: []const u8, actual: []const u8) !void {
    return expectGoldenOpts(io, src, name, actual, .{});
}

/// `expectGolden` with options.
pub fn expectGoldenOpts(io: std.Io, comptime src: std.builtin.SourceLocation, name: []const u8, actual: []const u8, opts: Options) !void {
    const gpa = std.testing.allocator;
    const stem = comptime std.fs.path.stem(src.file);
    const rel_dir = opts.dir orelse "testdata/golden/" ++ stem;
    var root = try std.Io.Dir.openDirAbsolute(io, opts.root orelse options.package_root, .{});
    defer root.close(io);
    const file_name = try std.fmt.allocPrint(gpa, "{s}/{s}.golden", .{ rel_dir, name });
    defer gpa.free(file_name);

    const got = try normalize(gpa, actual, opts.normalize);
    defer gpa.free(got);

    if (opts.update orelse options.update_golden) {
        try root.createDirPath(io, rel_dir);
        try root.writeFile(io, .{ .sub_path = file_name, .data = got });
        return;
    }

    const raw = root.readFileAlloc(io, file_name, gpa, .limited(64 << 20)) catch |err| switch (err) {
        error.FileNotFound => {
            const fmt = "golden file {s} is missing; run `zig build test -Dupdate-golden` to create it\n";
            if (opts.report) |w| try w.print(fmt, .{file_name}) else std.debug.print(fmt, .{file_name});
            return error.GoldenMissing;
        },
        else => return err,
    };
    defer gpa.free(raw);
    const want = try normalize(gpa, raw, opts.normalize);
    defer gpa.free(want);
    if (std.mem.eql(u8, want, got)) return;

    const actual_name = try std.fmt.allocPrint(gpa, "{s}.actual", .{file_name});
    defer gpa.free(actual_name);
    root.writeFile(io, .{ .sub_path = actual_name, .data = got }) catch {};
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.writer.print("golden mismatch: {s} (actual written to {s})\n--- golden\n+++ actual\n", .{ file_name, actual_name });
    try diff.unifiedDiff(gpa, want, got, 3, &out.writer);
    if (opts.report) |w| try w.writeAll(out.written()) else std.debug.print("{s}", .{out.written()});
    return error.GoldenMismatch;
}

/// Normalises `s`; caller frees.
pub fn normalize(gpa: std.mem.Allocator, s: []const u8, mode: Normalize) ![]u8 {
    if (mode == .exact) return gpa.dupe(u8, s);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |line| {
        const l = std.mem.trimEnd(u8, line, " \t\r");
        try out.appendSlice(gpa, l);
        try out.append(gpa, '\n');
    }
    while (out.items.len > 1 and out.items[out.items.len - 1] == '\n' and out.items[out.items.len - 2] == '\n') _ = out.pop();
    if (out.items.len == 1) out.clearRetainingCapacity();
    return out.toOwnedSlice(gpa);
}

test "golden: text normaliser CRLF/trailing ws" {
    const gpa = std.testing.allocator;
    const n = try normalize(gpa, "a  \r\nb\t\r\n\n\n", .text);
    defer gpa.free(n);
    try std.testing.expectEqualStrings("a\nb\n", n);
    const e = try normalize(gpa, "", .text);
    defer gpa.free(e);
    try std.testing.expectEqualStrings("", e);
}

test "golden: update mode writes file, then equal passes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const root = path_buf[0..n];
    try expectGoldenOpts(io, @src(), "sample", "hello\r\nworld  \n", .{ .root = root, .update = true });
    const written = try tmp.dir.readFileAlloc(io, "testdata/golden/golden/sample.golden", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings("hello\nworld\n", written);
    try expectGoldenOpts(io, @src(), "sample", "hello\nworld\n", .{ .root = root, .update = false });
}

test "golden: mismatch error with diff" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const root = path_buf[0..n];
    try expectGoldenOpts(io, @src(), "m", "one\ntwo\n", .{ .root = root, .update = true });
    var report: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer report.deinit();
    try std.testing.expectError(error.GoldenMismatch, expectGoldenOpts(io, @src(), "m", "one\nTWO\n", .{ .root = root, .update = false, .report = &report.writer }));
    try std.testing.expect(std.mem.indexOf(u8, report.written(), "-two\n+TWO\n") != null);
    try tmp.dir.access(io, "testdata/golden/golden/m.golden.actual", .{});
    try std.testing.expectError(error.GoldenMissing, expectGoldenOpts(io, @src(), "absent", "x", .{ .root = root, .update = false, .report = &report.writer }));
}
