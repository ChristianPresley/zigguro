//! Third-party data notices. `packaging/notices/<id>.zon` describes one
//! third-party data item (name, version, SPDX license, source, whether it
//! ships, the repository paths it covers and its license text files).
//!
//! - `--check` walks the data directories (`packages/*/data`,
//!   `packages/*/vendor`, `tools/*/data`, font test data and font fuzz
//!   corpora) and fails when a file matches no notice entry.
//! - `--generate` writes `THIRD_PARTY_NOTICES.md` for the shipped entries,
//!   sorted by name, with their full license texts.

const std = @import("std");
const Allocator = std.mem.Allocator;
const args = @import("args.zig");

/// One `packaging/notices/<id>.zon` file.
pub const Notice = struct {
    name: []const u8,
    version: []const u8,
    license_spdx: []const u8,
    source_url: []const u8,
    /// False for test-only data that never enters a release archive.
    shipped: bool,
    /// Repository paths: exact files, or directories ending in `/**`.
    paths: []const []const u8,
    license_text_files: []const []const u8,
};

/// True when `path` (repo-relative, `/` separated) matches `pattern`.
pub fn matches(pattern: []const u8, path: []const u8) bool {
    if (std.mem.endsWith(u8, pattern, "/**")) return std.mem.startsWith(u8, path, pattern[0 .. pattern.len - 2]);
    return std.mem.eql(u8, pattern, path);
}

/// Data directory roots `--check` walks: `<top>/*/<sub>`.
pub const scanned = [_]struct { top: []const u8, sub: []const u8 }{
    .{ .top = "packages", .sub = "data" },
    .{ .top = "packages", .sub = "vendor" },
    .{ .top = "packages", .sub = "testdata/fonts" },
    .{ .top = "packages", .sub = "fuzz/corpus/ot-face" },
    .{ .top = "tools", .sub = "data" },
};

/// Loads every notice under `<root>/packaging/notices`.
pub fn load(gpa: Allocator, io: std.Io, root: std.Io.Dir) ![]Notice {
    var dir = try root.openDir(io, "packaging/notices", .{ .iterate = true });
    defer dir.close(io);
    var out: std.ArrayList(Notice) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".zon")) continue;
        const text = try dir.readFileAllocOptions(io, e.name, gpa, .limited(1 << 20), .of(u8), 0);
        try out.append(gpa, std.zon.parse.fromSliceAlloc(Notice, gpa, text, null, .{}) catch |err| {
            std.debug.print("packaging/notices/{s}: {t}\n", .{ e.name, err });
            return error.BadNotice;
        });
    }
    std.mem.sort(Notice, out.items, {}, struct {
        fn lt(_: void, a: Notice, b: Notice) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lt);
    return out.items;
}

/// Repo-relative paths of every data file `--check` covers, sorted.
pub fn dataFiles(gpa: Allocator, io: std.Io, root: std.Io.Dir) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (scanned) |s| {
        var top = root.openDir(io, s.top, .{ .iterate = true }) catch continue;
        defer top.close(io);
        var it = top.iterate();
        while (try it.next(io)) |pkg| {
            if (pkg.kind != .directory) continue;
            const rel = try std.fmt.allocPrint(gpa, "{s}/{s}/{s}", .{ s.top, pkg.name, s.sub });
            var d = root.openDir(io, rel, .{ .iterate = true }) catch continue;
            defer d.close(io);
            var w = try d.walk(gpa);
            defer w.deinit();
            while (try w.next(io)) |f| {
                if (f.kind == .directory) continue;
                const p = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ rel, f.path });
                std.mem.replaceScalar(u8, p, '\\', '/');
                try out.append(gpa, p);
            }
        }
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return out.items;
}

/// Data files that no notice covers.
pub fn unlisted(gpa: Allocator, files: []const []const u8, notices: []const Notice) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    outer: for (files) |f| {
        for (notices) |n| for (n.paths) |p| if (matches(p, f)) continue :outer;
        try out.append(gpa, f);
    }
    return out.items;
}

/// Writes THIRD_PARTY_NOTICES.md for the shipped notices.
pub fn generate(gpa: Allocator, io: std.Io, root: std.Io.Dir, notices: []const Notice, w: *std.Io.Writer) !void {
    try w.writeAll("# Third-party notices\n\nzigguro is Apache-2.0 licensed and has no third-party code dependencies.\nThe following third-party data is built into or shipped with it.\n");
    for (notices) |n| {
        if (!n.shipped) continue;
        try w.print("\n## {s}\n\n- Version: {s}\n- License: {s}\n- Source: {s}\n", .{ n.name, n.version, n.license_spdx, n.source_url });
        for (n.license_text_files) |lf| {
            const text = try root.readFileAlloc(io, lf, gpa, .limited(1 << 20));
            try w.print("\n```text\n{s}{s}```\n", .{ text, if (std.mem.endsWith(u8, text, "\n")) "" else "\n" });
        }
    }
}

/// `zg-release notices --generate|--check true [--root .] [--out THIRD_PARTY_NOTICES.md]`.
pub fn run(ctx: *const args.Context) !u8 {
    const io = ctx.io;
    var root = try std.Io.Dir.cwd().openDir(io, ctx.opts.get("root") orelse ".", .{ .iterate = true });
    defer root.close(io);
    const notices = try load(ctx.gpa, io, root);
    if (ctx.opts.get("check") != null) {
        const missing = try unlisted(ctx.gpa, try dataFiles(ctx.gpa, io, root), notices);
        for (missing) |m| std.debug.print("notices: no packaging/notices entry covers {s}\n", .{m});
        return if (missing.len == 0) 0 else 1;
    }
    if (ctx.opts.get("generate") != null) {
        var aw: std.Io.Writer.Allocating = .init(ctx.gpa);
        try generate(ctx.gpa, io, root, notices, &aw.writer);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ctx.opts.get("out") orelse "THIRD_PARTY_NOTICES.md", .data = aw.written() });
        return 0;
    }
    return error.Usage;
}

test "notices: check fails on unlisted data file" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "packaging/notices");
    try tmp.dir.createDirPath(io, "packages/text/data/ucd");
    try tmp.dir.createDirPath(io, "tools/gen/data");
    try tmp.dir.writeFile(io, .{ .sub_path = "packages/text/data/ucd/UnicodeData.txt", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "tools/gen/data/schema.json", .data = "{}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "LICENSE-UCD.txt", .data = "Unicode License v3\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "packaging/notices/ucd.zon", .data =
        \\.{ .name = "Unicode Character Database", .version = "16.0.0", .license_spdx = "Unicode-3.0",
        \\   .source_url = "https://www.unicode.org/Public/16.0.0/ucd/", .shipped = true,
        \\   .paths = .{"packages/text/data/ucd/**"}, .license_text_files = .{"LICENSE-UCD.txt"} }
    });
    var root = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer root.close(io);
    const ns = try load(gpa, io, root);
    const files = try dataFiles(gpa, io, root);
    try std.testing.expectEqual(@as(usize, 2), files.len);
    const missing = try unlisted(gpa, files, ns);
    try std.testing.expectEqual(@as(usize, 1), missing.len);
    try std.testing.expectEqualStrings("tools/gen/data/schema.json", missing[0]);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    try generate(gpa, io, root, ns, &aw.writer);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "## Unicode Character Database") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "Unicode License v3") != null);
}

test "notices: path patterns" {
    try std.testing.expect(matches("a/b/**", "a/b/c/d"));
    try std.testing.expect(!matches("a/b/**", "a/bc"));
    try std.testing.expect(matches("a/x.txt", "a/x.txt"));
}
