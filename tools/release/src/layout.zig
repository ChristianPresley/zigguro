//! Release archive layouts (E17.F01 Design). Every archive has one top
//! directory `zigguro-<v>-<t>/`; entries are returned sorted byte-wise with
//! explicit directory entries, so the writers stay deterministic.
//!
//! - Windows: `zigguro.exe`, `zg.exe`, `zigguro-setup.exe` (when built),
//!   `BUILDINFO.zon`, `LICENSE`, `THIRD_PARTY_NOTICES.md`; portable adds
//!   `zigguro-data/README.txt`.
//! - Linux (a valid AppDir): `zigguro`, `zg`, `AppRun -> zigguro`,
//!   `dev.zigguro.zigguro.desktop`, `dev.zigguro.zigguro.png` and
//!   `.DirIcon -> dev.zigguro.zigguro.png` (when icons are in the dist
//!   tree), `share/icons/hicolor/<N>x<N>/apps/...`, `share/metainfo/...`,
//!   `share/mime/packages/...`, `BUILDINFO.zon`, `LICENSE`,
//!   `THIRD_PARTY_NOTICES.md`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zg_release = @import("zg_release");
const linux_files = @import("linux_files.zig");

/// Where an entry's bytes come from.
pub const Source = union(enum) {
    /// Path relative to the dist directory.
    file: []const u8,
    bytes: []const u8,
    dir,
    /// Symlink target.
    symlink: []const u8,
};

/// One archive member.
pub const Entry = struct {
    /// Path inside the archive; directories end with `/`.
    archive_path: []const u8,
    source: Source,
    /// 0o755 for executables, dirs and links, 0o644 otherwise.
    mode: u32,
};

/// Target operating system of a layout.
pub const Os = enum { windows, linux };

/// Inputs of `collect`.
pub const Inputs = struct {
    os: Os,
    /// Top directory name, `zigguro-<v>-<t>`.
    top: []const u8,
    portable: bool = false,
    buildinfo_zon: []const u8,
    license: []const u8,
    notices: []const u8,
    /// Icon sizes present in the dist tree as `icons/<N>.png` (Linux).
    icon_sizes: []const u32 = &.{},
};

/// Icon sizes the Linux layout installs when the dist tree has them.
pub const hicolor_sizes = [_]u32{ 16, 24, 32, 48, 64, 128, 256, 512 };

/// The archive's entries, sorted, for `dist` (which must contain the
/// executables). Missing required executables are `error.MissingFile`.
pub fn collect(gpa: Allocator, io: std.Io, dist: std.Io.Dir, in: Inputs) ![]Entry {
    var list: std.ArrayList(Entry) = .empty;
    const app_id = zg_release.product.app_id;
    const P = struct {
        fn join(a: Allocator, top: []const u8, rel: []const u8) ![]const u8 {
            return std.fmt.allocPrint(a, "{s}/{s}", .{ top, rel });
        }
    };
    const exe_names: []const []const u8 = switch (in.os) {
        .windows => &.{ "zigguro.exe", "zg.exe" },
        .linux => &.{ "zigguro", "zg" },
    };
    for (exe_names) |n| {
        dist.access(io, n, .{}) catch return error.MissingFile;
        try list.append(gpa, .{ .archive_path = try P.join(gpa, in.top, n), .source = .{ .file = n }, .mode = 0o755 });
    }
    if (in.os == .windows) {
        if (dist.access(io, "zigguro-setup.exe", .{})) |_| {
            try list.append(gpa, .{ .archive_path = try P.join(gpa, in.top, "zigguro-setup.exe"), .source = .{ .file = "zigguro-setup.exe" }, .mode = 0o755 });
        } else |_| {}
        if (in.portable) {
            try list.append(gpa, .{ .archive_path = try P.join(gpa, in.top, "zigguro-data/"), .source = .dir, .mode = 0o755 });
            try list.append(gpa, .{ .archive_path = try P.join(gpa, in.top, "zigguro-data/README.txt"), .source = .{ .bytes = portable_readme }, .mode = 0o644 });
        }
    } else {
        try list.append(gpa, .{ .archive_path = try P.join(gpa, in.top, "AppRun"), .source = .{ .symlink = "zigguro" }, .mode = 0o755 });
        const desktop = try linux_files.desktopEntry(gpa, .{ .exec = "AppRun" });
        try list.append(gpa, .{ .archive_path = try std.fmt.allocPrint(gpa, "{s}/{s}.desktop", .{ in.top, app_id }), .source = .{ .bytes = desktop }, .mode = 0o644 });
        try list.append(gpa, .{ .archive_path = try std.fmt.allocPrint(gpa, "{s}/share/metainfo/{s}.metainfo.xml", .{ in.top, app_id }), .source = .{ .bytes = try linux_files.metainfo(gpa) }, .mode = 0o644 });
        try list.append(gpa, .{ .archive_path = try std.fmt.allocPrint(gpa, "{s}/share/mime/packages/{s}.xml", .{ in.top, app_id }), .source = .{ .bytes = try linux_files.mimePackage(gpa) }, .mode = 0o644 });
        for (in.icon_sizes) |n| {
            const src = try std.fmt.allocPrint(gpa, "icons/{d}.png", .{n});
            try list.append(gpa, .{ .archive_path = try std.fmt.allocPrint(gpa, "{s}/share/icons/hicolor/{d}x{d}/apps/{s}.png", .{ in.top, n, n, app_id }), .source = .{ .file = src }, .mode = 0o644 });
            if (n == 256) {
                try list.append(gpa, .{ .archive_path = try std.fmt.allocPrint(gpa, "{s}/{s}.png", .{ in.top, app_id }), .source = .{ .file = src }, .mode = 0o644 });
                try list.append(gpa, .{ .archive_path = try P.join(gpa, in.top, ".DirIcon"), .source = .{ .symlink = try std.fmt.allocPrint(gpa, "{s}.png", .{app_id}) }, .mode = 0o755 });
            }
        }
    }
    try list.append(gpa, .{ .archive_path = try P.join(gpa, in.top, "BUILDINFO.zon"), .source = .{ .bytes = in.buildinfo_zon }, .mode = 0o644 });
    try list.append(gpa, .{ .archive_path = try P.join(gpa, in.top, "LICENSE"), .source = .{ .bytes = in.license }, .mode = 0o644 });
    try list.append(gpa, .{ .archive_path = try P.join(gpa, in.top, "THIRD_PARTY_NOTICES.md"), .source = .{ .bytes = in.notices }, .mode = 0o644 });
    try addParentDirs(gpa, &list);
    std.mem.sort(Entry, list.items, {}, lessThan);
    return list.items;
}

/// Adds an explicit entry for every parent directory of every entry.
fn addParentDirs(gpa: Allocator, list: *std.ArrayList(Entry)) !void {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(gpa);
    for (list.items) |e| if (e.source == .dir) try seen.put(gpa, e.archive_path, {});
    const n = list.items.len;
    for (0..n) |i| {
        const p = list.items[i].archive_path;
        var end: usize = 0;
        while (std.mem.indexOfScalarPos(u8, p, end, '/')) |slash| : (end = slash + 1) {
            if (slash + 1 == p.len) break;
            const dir = p[0 .. slash + 1];
            if (seen.contains(dir)) continue;
            try seen.put(gpa, dir, {});
            try list.append(gpa, .{ .archive_path = dir, .source = .dir, .mode = 0o755 });
        }
    }
}

fn lessThan(_: void, a: Entry, b: Entry) bool {
    return std.mem.order(u8, a.archive_path, b.archive_path) == .lt;
}

/// Contents of `zigguro-data/README.txt` in the portable zip.
pub const portable_readme =
    \\zigguro portable mode
    \\
    \\While this folder exists next to zigguro.exe, zigguro keeps its settings,
    \\state and caches here instead of in your user profile.
    \\Delete this folder to disable portable mode.
    \\
;

test "layout: windows portable" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "zigguro.exe", .data = "MZ" });
    try tmp.dir.writeFile(io, .{ .sub_path = "zg.exe", .data = "MZ" });
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const es = try collect(arena.allocator(), io, tmp.dir, .{ .os = .windows, .top = "zigguro-0.4.0-x86_64-windows", .portable = true, .buildinfo_zon = ".{}", .license = "L", .notices = "N" });
    const want = [_][]const u8{
        "zigguro-0.4.0-x86_64-windows/",
        "zigguro-0.4.0-x86_64-windows/BUILDINFO.zon",
        "zigguro-0.4.0-x86_64-windows/LICENSE",
        "zigguro-0.4.0-x86_64-windows/THIRD_PARTY_NOTICES.md",
        "zigguro-0.4.0-x86_64-windows/zg.exe",
        "zigguro-0.4.0-x86_64-windows/zigguro-data/",
        "zigguro-0.4.0-x86_64-windows/zigguro-data/README.txt",
        "zigguro-0.4.0-x86_64-windows/zigguro.exe",
    };
    try std.testing.expectEqual(want.len, es.len);
    for (want, es) |w, e| try std.testing.expectEqualStrings(w, e.archive_path);
}

test "layout: linux appdir" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "zigguro", .data = "\x7fELF" });
    try tmp.dir.writeFile(io, .{ .sub_path = "zg", .data = "\x7fELF" });
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const es = try collect(arena.allocator(), io, tmp.dir, .{ .os = .linux, .top = "z", .buildinfo_zon = ".{}", .license = "L", .notices = "N", .icon_sizes = &.{ 48, 256 } });
    var have_apprun = false;
    var have_diricon = false;
    for (es, 0..) |e, i| {
        if (i > 0) try std.testing.expect(std.mem.order(u8, es[i - 1].archive_path, e.archive_path) == .lt);
        if (std.mem.eql(u8, e.archive_path, "z/AppRun")) have_apprun = std.mem.eql(u8, e.source.symlink, "zigguro");
        if (std.mem.eql(u8, e.archive_path, "z/.DirIcon")) have_diricon = true;
    }
    try std.testing.expect(have_apprun and have_diricon);
    try std.testing.expectError(error.MissingFile, collect(arena.allocator(), io, tmp.dir, .{ .os = .windows, .top = "z", .buildinfo_zon = "", .license = "", .notices = "" }));
}
