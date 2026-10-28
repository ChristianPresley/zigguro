//! Corpus shape parameters (E14.F06.S01.T01). These are model
//! parameters, not copied data; docs/perf/benchmarks.md derives them.
//! Distributions use integer tables only: a size or length is a uniform
//! pick inside one of N equal-probability buckets of a log-normal, whose
//! edges were computed once and pinned here, so output is identical on
//! every target and optimisation mode.

const std = @import("std");
const names = @import("names.zig");

pub const Profile = enum { linux, chromium, huge, lines_100k, bigfile_1g, minified_50m, notes_10k, mixed_unicode_10m };

/// An extension (or a whole file name when `whole`) and its share in
/// parts per thousand.
pub const Ext = struct { name: []const u8, permille: u16, whole: bool = false };

/// A directory tree's shape.
pub const TreeShape = struct {
    files: u64,
    dirs: u64,
    max_depth: u8,
    top: []const []const u8,
    exts: []const Ext,
    /// Syllables per name.
    name_parts: [2]u8 = .{ 1, 3 },
    /// Names of 40..120 bytes, per thousand.
    long_name_permille: u16 = 0,
    /// Extra parent-pool weight for these top-level dirs (third_party).
    heavy_top: []const []const u8 = &.{},
    /// Dirs named like test data, per thousand; they attract files.
    test_data_permille: u16 = 0,
    /// File sizes; null: paths only by default.
    sizes: ?*const [65]u32 = null,
};

/// File sizes, log-normal with median 6 KiB and p99 about 90 KiB, capped
/// at 384 KiB: about 14 KB mean, 1.5 GB over 108 k files.
pub const linux_sizes = [65]u32{
    64,    482,   680,   847,   1002,  1150,  1294,  1436,  1578,  1719,  1862,  2007,  2153,
    2302,  2454,  2610,  2768,  2931,  3099,  3271,  3448,  3631,  3819,  4014,  4216,  4425,
    4642,  4867,  5101,  5345,  5600,  5866,  6144,  6435,  6740,  7061,  7399,  7755,  8131,
    8530,  8953,  9402,  9882,  10396, 10946, 11539, 12180, 12875, 13632, 14463, 15377, 16392,
    17527, 18807, 20265, 21949, 23921, 26278, 29163, 32812, 37647, 44516, 55510, 78304, 393216,
};

/// Line lengths before indentation, log-normal with median 33 and p99
/// 120 (mean about 38).
pub const line_lengths = [33]u8{ 1, 11, 14, 15, 17, 18, 20, 21, 22, 23, 25, 26, 27, 28, 30, 31, 33, 34, 36, 37, 39, 41, 43, 45, 47, 50, 53, 57, 62, 68, 77, 92, 160 };

/// A uniform pick inside one of the equal-probability buckets of `edges`.
pub fn pickBucket(comptime T: type, r: std.Random, edges: []const T) T {
    const i = names.pick(r, edges.len - 1);
    const lo = edges[i];
    const hi = edges[i + 1];
    return if (hi > lo) lo + r.uintLessThan(T, hi - lo) else lo;
}

const linux_top = [_][]const u8{ "arch", "block", "certs", "crypto", "Documentation", "drivers", "fs", "include", "init", "io_uring", "ipc", "kernel", "lib", "mm", "net", "rust", "samples", "scripts", "security", "sound", "tools", "virt" };

/// Calibrated to 108 158 files / about 40 M lines (Linux 7.2 scale).
pub const linux: TreeShape = .{
    .files = 108_158,
    .dirs = 6_000,
    .max_depth = 9,
    .top = &linux_top,
    .exts = &.{
        .{ .name = ".c", .permille = 450 },
        .{ .name = ".h", .permille = 220 },
        .{ .name = ".rst", .permille = 60 },
        .{ .name = ".txt", .permille = 20 },
        .{ .name = ".yaml", .permille = 50 },
        .{ .name = ".S", .permille = 20 },
        .{ .name = "Makefile", .permille = 35, .whole = true },
        .{ .name = "Kconfig", .permille = 25, .whole = true },
        .{ .name = ".sh", .permille = 30 },
        .{ .name = ".py", .permille = 25 },
        .{ .name = ".json", .permille = 20 },
        .{ .name = ".dts", .permille = 25 },
        .{ .name = ".rs", .permille = 20 },
    },
    .heavy_top = &.{ "drivers", "arch" },
    .sizes = &linux_sizes,
};

const chromium_top = [_][]const u8{ "android_webview", "ash", "base", "build", "cc", "chrome", "chromeos", "components", "content", "courgette", "device", "docs", "extensions", "gpu", "headless", "ios", "ipc", "media", "mojo", "net", "pdf", "printing", "remoting", "sandbox", "services", "skia", "sql", "storage", "testing", "third_party", "tools", "ui", "url", "v8", "weblayer" };

const chromium_exts = [_]Ext{
    .{ .name = ".cc", .permille = 300 },
    .{ .name = ".h", .permille = 240 },
    .{ .name = ".java", .permille = 70 },
    .{ .name = ".py", .permille = 60 },
    .{ .name = ".js", .permille = 90 },
    .{ .name = ".json", .permille = 60 },
    .{ .name = ".png", .permille = 80 },
    .{ .name = ".gn", .permille = 40 },
    .{ .name = ".html", .permille = 40 },
    .{ .name = ".md", .permille = 20 },
};

/// 1 M paths, depth up to 14, long names, third_party subtrees and
/// test-data clusters.
pub const chromium: TreeShape = .{
    .files = 1_000_000,
    .dirs = 80_000,
    .max_depth = 14,
    .top = &chromium_top,
    .exts = &chromium_exts,
    .name_parts = .{ 1, 4 },
    .long_name_permille = 20,
    .heavy_top = &.{ "third_party", "chrome", "components" },
    .test_data_permille = 30,
};

/// 2 M paths for fuzzy-finder and explorer stress.
pub const huge: TreeShape = .{
    .files = 2_000_000,
    .dirs = 160_000,
    .max_depth = 14,
    .top = &chromium_top,
    .exts = &chromium_exts,
    .name_parts = .{ 1, 4 },
    .long_name_permille = 20,
    .heavy_top = &.{ "third_party", "chrome", "components" },
    .test_data_permille = 30,
};

pub fn tree(p: Profile) ?TreeShape {
    return switch (p) {
        .linux => linux,
        .chromium => chromium,
        .huge => huge,
        else => null,
    };
}

/// Profiles written as real files by default (the large path sets
/// default to paths only).
pub fn defaultsToTree(p: Profile) bool {
    return switch (p) {
        .chromium, .huge => false,
        else => true,
    };
}

pub const lines_100k_lines: u64 = 100_000;
pub const bigfile_bytes: u64 = 1 << 30;
pub const minified_bytes: u64 = 50_000_000;
pub const notes_count: u64 = 10_000;
pub const unicode_bytes: u64 = 10_000_000;

/// `n` scaled by `scale_ppm` (parts per million), at least `min`.
pub fn scaled(n: u64, scale_ppm: u32, min: u64) u64 {
    return @max(min, n * scale_ppm / 1_000_000);
}

test "corpusgen profiles: extension shares add up" {
    for ([_]TreeShape{ linux, chromium }) |t| {
        var sum: u32 = 0;
        for (t.exts) |e| sum += e.permille;
        try std.testing.expectEqual(@as(u32, 1000), sum);
    }
}
