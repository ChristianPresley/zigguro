//! `zg-release package`: turns a dist directory into deterministic release
//! archives (E17.F01.S02.T01).
//!
//!   zg-release package --dist zig-out/dist/<t> --target <t> --version <v>
//!       --epoch <SOURCE_DATE_EPOCH> --out zig-out/release
//!       [--portable true] [--symbols zig-out/symbols/<t>]
//!       [--channel dev] [--commit <hex>] [--release-target <triple>]
//!       [--license LICENSE] [--notices THIRD_PARTY_NOTICES.md]
//!
//! Writes `zigguro-<v>-<t>.zip` (Windows) or `.tar.gz` (Linux), the
//! portable zip with `--portable`, and `zigguro-<v>-<t>-symbols.tar.gz`
//! with `--symbols`. `<v>` is the version without build metadata.
//! BUILDINFO.zon is generated from the arguments. Input file mtimes never
//! reach the archives.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zg_release = @import("zg_release");
const args = @import("args.zig");
const layout = @import("layout.zig");
const targz = @import("targz.zig");
const symbols = @import("symbols.zig");
const ZipWriter = @import("zip_writer.zig").ZipWriter;

const Reader = struct {
    gpa: Allocator,
    io: std.Io,
    dir: std.Io.Dir,

    fn read(r: *const Reader, path: []const u8) anyerror![]const u8 {
        return r.dir.readFileAlloc(r.io, path, r.gpa, .limited(1 << 30));
    }
};

/// Writes `entries` as a deterministic zip to `path`.
pub fn writeZipFile(gpa: Allocator, io: std.Io, out_dir: std.Io.Dir, path: []const u8, entries: []const layout.Entry, epoch: i64, r: *const Reader) !void {
    var f = try out_dir.createFile(io, path, .{});
    defer f.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var fw = f.writer(io, &buf);
    var z: ZipWriter = .init(&fw.interface, gpa, .{ .dos_epoch = epoch });
    defer z.deinit();
    for (entries) |e| switch (e.source) {
        .dir => try z.add(.{ .path = e.archive_path, .mode = e.mode, .kind = .dir }),
        .symlink => |t| try z.add(.{ .path = e.archive_path, .mode = 0o777, .kind = .symlink, .link_target = t }),
        .bytes => |b| try z.add(.{ .path = e.archive_path, .mode = e.mode, .kind = .file, .data = b }),
        .file => |p| try z.add(.{ .path = e.archive_path, .mode = e.mode, .kind = .file, .data = try r.read(p) }),
    };
    try z.finish();
}

fn writeTarGzFile(gpa: Allocator, io: std.Io, out_dir: std.Io.Dir, path: []const u8, entries: []const layout.Entry, epoch: i64, r: *const Reader) !void {
    var f = try out_dir.createFile(io, path, .{});
    defer f.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var fw = f.writer(io, &buf);
    try targz.writeTarGz(gpa, &fw.interface, entries, epoch, r, Reader.read);
}

/// The debug id of each executable at the top of the dist tree.
fn debugIds(gpa: Allocator, io: std.Io, dist: std.Io.Dir, os: layout.Os) ![]const zg_release.BuildInfo.DebugId {
    var out: std.ArrayList(zg_release.BuildInfo.DebugId) = .empty;
    const names: []const []const u8 = switch (os) {
        .windows => &.{ "zigguro.exe", "zg.exe", "zigguro-setup.exe" },
        .linux => &.{ "zigguro", "zg" },
    };
    for (names) |n| {
        const bytes = dist.readFileAlloc(io, n, gpa, .limited(1 << 30)) catch continue;
        defer gpa.free(bytes);
        var buf: [128]u8 = undefined;
        const id = symbols.debugId(bytes, &buf) orelse continue;
        try out.append(gpa, .{ .exe = n, .id = try gpa.dupe(u8, id) });
    }
    return out.items;
}

/// Entries for the symbols tarball: every file under `dir`, sorted, under
/// `top/`. Each ELF `.debug` file also gets GDB's
/// `.build-id/<xx>/<rest>.debug` link.
fn symbolEntries(gpa: Allocator, io: std.Io, dir: std.Io.Dir, top: []const u8) ![]layout.Entry {
    var list: std.ArrayList(layout.Entry) = .empty;
    try list.append(gpa, .{ .archive_path = try std.fmt.allocPrint(gpa, "{s}/", .{top}), .source = .dir, .mode = 0o755 });
    var w = try dir.walk(gpa);
    defer w.deinit();
    while (try w.next(io)) |e| {
        const rel = try gpa.dupe(u8, e.path);
        std.mem.replaceScalar(u8, rel, '\\', '/');
        switch (e.kind) {
            .directory => try list.append(gpa, .{ .archive_path = try std.fmt.allocPrint(gpa, "{s}/{s}/", .{ top, rel }), .source = .dir, .mode = 0o755 }),
            .file => {
                try list.append(gpa, .{ .archive_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ top, rel }), .source = .{ .file = rel }, .mode = 0o644 });
                if (std.mem.endsWith(u8, rel, ".debug") and std.mem.indexOfScalar(u8, rel, '/') == null) {
                    const bytes = try dir.readFileAlloc(io, rel, gpa, .limited(1 << 30));
                    defer gpa.free(bytes);
                    var buf: [128]u8 = undefined;
                    if (symbols.debugId(bytes, &buf)) |id| if (id.len > 2) {
                        const sub = try std.fmt.allocPrint(gpa, "{s}/.build-id/{s}/", .{ top, id[0..2] });
                        if (!has(list.items, try std.fmt.allocPrint(gpa, "{s}/.build-id/", .{top}))) try list.append(gpa, .{ .archive_path = try std.fmt.allocPrint(gpa, "{s}/.build-id/", .{top}), .source = .dir, .mode = 0o755 });
                        if (!has(list.items, sub)) try list.append(gpa, .{ .archive_path = sub, .source = .dir, .mode = 0o755 });
                        try list.append(gpa, .{ .archive_path = try std.fmt.allocPrint(gpa, "{s}{s}.debug", .{ sub, id[2..] }), .source = .{ .symlink = try std.fmt.allocPrint(gpa, "../../{s}", .{rel}) }, .mode = 0o755 });
                    };
                }
            },
            else => {},
        }
    }
    std.mem.sort(layout.Entry, list.items, {}, struct {
        fn lt(_: void, a: layout.Entry, b: layout.Entry) bool {
            return std.mem.order(u8, a.archive_path, b.archive_path) == .lt;
        }
    }.lt);
    return list.items;
}

fn has(list: []const layout.Entry, path: []const u8) bool {
    for (list) |e| if (std.mem.eql(u8, e.archive_path, path)) return true;
    return false;
}

/// Sizes found as `icons/<N>.png` in the dist tree.
fn iconSizes(gpa: Allocator, io: std.Io, dist: std.Io.Dir) ![]const u32 {
    var out: std.ArrayList(u32) = .empty;
    for (layout.hicolor_sizes) |n| {
        const p = try std.fmt.allocPrint(gpa, "icons/{d}.png", .{n});
        if (dist.access(io, p, .{})) |_| try out.append(gpa, n) else |_| {}
    }
    return out.items;
}

/// The command.
pub fn run(ctx: *const args.Context) !u8 {
    const gpa = ctx.gpa;
    const io = ctx.io;
    const o = &ctx.opts;
    const target = try o.need("target");
    const version_text = try o.need("version");
    const epoch = std.fmt.parseInt(i64, try o.need("epoch"), 10) catch return error.Usage;
    const version = zg_release.Version.parse(version_text) catch return error.Usage;
    var core_buf: [128]u8 = undefined;
    const v = version.coreString(&core_buf);
    const os: layout.Os = if (std.mem.indexOf(u8, target, "windows") != null) .windows else .linux;
    const portable = o.get("portable") != null;

    var dist = try std.Io.Dir.cwd().openDir(io, try o.need("dist"), .{ .iterate = true });
    defer dist.close(io);
    var out = try std.Io.Dir.cwd().createDirPathOpen(io, try o.need("out"), .{});
    defer out.close(io);

    const bi: zg_release.BuildInfo = .{
        .debug_ids = try debugIds(gpa, io, dist, os),
        .version = version,
        .version_string = version_text,
        .channel = std.meta.stringToEnum(zg_release.Channel, o.get("channel") orelse "dev") orelse return error.Usage,
        .commit = o.get("commit") orelse "unknown",
        .target = o.get("release-target") orelse target,
        .optimize = .ReleaseFast,
        .source_date_epoch = epoch,
        .update_mode = .managed_or_notify,
        .distro = false,
    };
    var zon: std.Io.Writer.Allocating = .init(gpa);
    try bi.writeZon(&zon.writer);
    const license = try std.Io.Dir.cwd().readFileAlloc(io, o.get("license") orelse "LICENSE", gpa, .limited(1 << 20));
    const notices = if (o.get("notices")) |p| try std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(1 << 22)) else "# Third-party notices\n";

    const r: Reader = .{ .gpa = gpa, .io = io, .dir = dist };
    const top = try std.fmt.allocPrint(gpa, "zigguro-{s}-{s}", .{ v, target });
    const in: layout.Inputs = .{
        .os = os,
        .top = top,
        .buildinfo_zon = zon.written(),
        .license = license,
        .notices = notices,
        .icon_sizes = if (os == .linux) try iconSizes(gpa, io, dist) else &.{},
    };
    const entries = try layout.collect(gpa, io, dist, in);
    switch (os) {
        .windows => {
            try writeZipFile(gpa, io, out, try std.fmt.allocPrint(gpa, "{s}.zip", .{top}), entries, epoch, &r);
            if (portable) {
                var pin = in;
                pin.portable = true;
                const pentries = try layout.collect(gpa, io, dist, pin);
                try writeZipFile(gpa, io, out, try std.fmt.allocPrint(gpa, "{s}-portable.zip", .{top}), pentries, epoch, &r);
            }
        },
        .linux => try writeTarGzFile(gpa, io, out, try std.fmt.allocPrint(gpa, "{s}.tar.gz", .{top}), entries, epoch, &r),
    }
    if (o.get("symbols")) |sym_path| {
        var sym = try std.Io.Dir.cwd().openDir(io, sym_path, .{ .iterate = true });
        defer sym.close(io);
        const stop = try std.fmt.allocPrint(gpa, "{s}-symbols", .{top});
        const sr: Reader = .{ .gpa = gpa, .io = io, .dir = sym };
        try writeTarGzFile(gpa, io, out, try std.fmt.allocPrint(gpa, "{s}.tar.gz", .{stop}), try symbolEntries(gpa, io, sym, stop), epoch, &sr);
    }
    return 0;
}
