//! Staging a downloaded update (E17.F04.S01.T02): extract the verified
//! archive into `<root>/staged.tmp/`, check its `BUILDINFO.zon` against
//! the offer and this build's target, then move its top directory to
//! `<root>/staged/` and record it in `<root>/staged.zon`. Every failure
//! removes `staged.tmp`; an older `staged/` is replaced only once the new
//! one is complete, and `staged/` without `staged.zon` is not an update.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const layout = @import("layout.zig");
const names = layout.names;

/// What `staged.zon` records about `staged/`.
pub const Staged = struct {
    version: []const u8,
    /// Lowercase hex SHA-256 of the archive.
    sha256: []const u8,
    serial: u64,
    staged_at: i64,
};

/// What the archive must be.
pub const Expect = struct {
    version: []const u8,
    /// This build's release target (`BuildInfo.target`).
    target: []const u8,
    sha256: [32]u8,
    serial: u64,
    now_unix: i64,
};

pub const Error = error{
    /// Not `.zip` or `.tar.gz`.
    UnknownArchive,
    /// Not exactly one top-level directory.
    BadLayout,
    MissingBuildInfo,
    VersionMismatch,
    TargetMismatch,
};

/// The archive kinds release builds produce.
pub const ArchiveKind = enum { zip, tar_gz };

pub fn archiveKind(name: []const u8) ?ArchiveKind {
    if (std.ascii.endsWithIgnoreCase(name, ".zip")) return .zip;
    if (std.ascii.endsWithIgnoreCase(name, ".tar.gz")) return .tar_gz;
    return null;
}

/// Stages `<root>/staged.download/<archive>` and deletes the archive.
pub fn stage(arena: Allocator, io: Io, root: Io.Dir, archive: []const u8, expect: Expect) anyerror!void {
    const kind = archiveKind(archive) orelse return error.UnknownArchive;
    root.deleteTree(io, names.staged_tmp) catch {};
    try root.createDirPath(io, names.staged_tmp);
    errdefer root.deleteTree(io, names.staged_tmp) catch {};
    {
        var tmp = try root.openDir(io, names.staged_tmp, .{ .iterate = true });
        defer tmp.close(io);
        var dl = try root.openDir(io, names.download, .{});
        defer dl.close(io);
        try extract(io, dl, archive, tmp, kind);

        const top = try topDir(arena, io, tmp);
        var top_dir = try tmp.openDir(io, top, .{});
        defer top_dir.close(io);
        try checkBuildInfo(arena, io, top_dir, expect);

        // Replace the older update only now that the new one is complete.
        root.deleteFile(io, names.staged_zon) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        root.deleteTree(io, names.staged) catch {};
        const from = try std.fs.path.join(arena, &.{ names.staged_tmp, top });
        try root.rename(from, root, names.staged, io);
    }
    root.deleteTree(io, names.staged_tmp) catch {};

    var hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{&expect.sha256}) catch unreachable;
    try writeStaged(io, root, .{ .version = expect.version, .sha256 = &hex, .serial = expect.serial, .staged_at = expect.now_unix });
    const dl_archive = try std.fs.path.join(arena, &.{ names.download, archive });
    root.deleteFile(io, dl_archive) catch {};
}

/// `staged.zon`, written to a temporary name and renamed into place.
fn writeStaged(io: Io, root: Io.Dir, s: Staged) !void {
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try std.zon.stringify.serialize(s, .{}, &w);
    try w.writeByte('\n');
    const tmp_name = names.staged_zon ++ ".tmp";
    try root.writeFile(io, .{ .sub_path = tmp_name, .data = w.buffered() });
    try root.rename(tmp_name, root, names.staged_zon, io);
}

/// The staged update, or null when there is none (or `staged.zon` is
/// unreadable).
pub fn readStaged(arena: Allocator, io: Io, root: Io.Dir) ?Staged {
    const text = root.readFileAllocOptions(io, names.staged_zon, arena, .limited(4096), .of(u8), 0) catch return null;
    const s = std.zon.parse.fromSliceAlloc(Staged, arena, text, null, .{}) catch return null;
    _ = root.statFile(io, names.staged, .{}) catch return null;
    return s;
}

fn extract(io: Io, dl: Io.Dir, archive: []const u8, dest: Io.Dir, kind: ArchiveKind) !void {
    var file = try dl.openFile(io, archive, .{});
    defer file.close(io);
    var rbuf: [64 * 1024]u8 = undefined;
    var fr = file.reader(io, &rbuf);
    switch (kind) {
        .zip => try std.zip.extract(dest, &fr, .{}),
        .tar_gz => {
            var window: [std.compress.flate.max_window_len]u8 = undefined;
            var dec: std.compress.flate.Decompress = .init(&fr.interface, .gzip, &window);
            try std.tar.extract(io, dest, &dec.reader, .{});
        },
    }
}

/// The only entry of `dir`, which must be a directory.
fn topDir(arena: Allocator, io: Io, dir: Io.Dir) ![]const u8 {
    var it = dir.iterate();
    var top: ?[]const u8 = null;
    while (try it.next(io)) |e| {
        if (top != null or e.kind != .directory) return error.BadLayout;
        top = try arena.dupe(u8, e.name);
    }
    return top orelse error.BadLayout;
}

fn checkBuildInfo(arena: Allocator, io: Io, top: Io.Dir, expect: Expect) !void {
    const Info = struct { version: []const u8, target: []const u8 };
    const text = top.readFileAllocOptions(io, "BUILDINFO.zon", arena, .limited(16 * 1024), .of(u8), 0) catch return error.MissingBuildInfo;
    const info = std.zon.parse.fromSliceAlloc(Info, arena, text, null, .{ .ignore_unknown_fields = true }) catch return error.MissingBuildInfo;
    if (!std.mem.eql(u8, info.version, expect.version)) return error.VersionMismatch;
    if (!std.mem.eql(u8, info.target, expect.target)) return error.TargetMismatch;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

/// A stored (uncompressed) zip of `files`, enough for `std.zip.extract`.
fn testZip(gpa: Allocator, files: []const [2][]const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var central: std.ArrayList(u8) = .empty;
    defer central.deinit(gpa);
    for (files) |f| {
        const off: u32 = @intCast(out.items.len);
        const crc = std.hash.Crc32.hash(f[1]);
        const n: u32 = @intCast(f[1].len);
        const name_len: u16 = @intCast(f[0].len);
        var lh: [30]u8 = @splat(0);
        std.mem.writeInt(u32, lh[0..4], 0x04034b50, .little);
        std.mem.writeInt(u16, lh[4..6], 20, .little);
        std.mem.writeInt(u32, lh[14..18], crc, .little);
        std.mem.writeInt(u32, lh[18..22], n, .little);
        std.mem.writeInt(u32, lh[22..26], n, .little);
        std.mem.writeInt(u16, lh[26..28], name_len, .little);
        try out.appendSlice(gpa, &lh);
        try out.appendSlice(gpa, f[0]);
        try out.appendSlice(gpa, f[1]);
        var ch: [46]u8 = @splat(0);
        std.mem.writeInt(u32, ch[0..4], 0x02014b50, .little);
        std.mem.writeInt(u16, ch[4..6], 20, .little);
        std.mem.writeInt(u16, ch[6..8], 20, .little);
        std.mem.writeInt(u32, ch[16..20], crc, .little);
        std.mem.writeInt(u32, ch[20..24], n, .little);
        std.mem.writeInt(u32, ch[24..28], n, .little);
        std.mem.writeInt(u16, ch[28..30], name_len, .little);
        std.mem.writeInt(u32, ch[42..46], off, .little);
        try central.appendSlice(gpa, &ch);
        try central.appendSlice(gpa, f[0]);
    }
    const cd_off: u32 = @intCast(out.items.len);
    try out.appendSlice(gpa, central.items);
    var eocd: [22]u8 = @splat(0);
    std.mem.writeInt(u32, eocd[0..4], 0x06054b50, .little);
    std.mem.writeInt(u16, eocd[8..10], @intCast(files.len), .little);
    std.mem.writeInt(u16, eocd[10..12], @intCast(files.len), .little);
    std.mem.writeInt(u32, eocd[12..16], @intCast(central.items.len), .little);
    std.mem.writeInt(u32, eocd[16..20], cd_off, .little);
    try out.appendSlice(gpa, &eocd);
    return out.toOwnedSlice(gpa);
}

/// A gzip (stored blocks) tarball of `files`.
fn testTarGz(gpa: Allocator, files: []const [2][]const u8) ![]u8 {
    var tar_out: Io.Writer.Allocating = .init(gpa);
    defer tar_out.deinit();
    var tw: std.tar.Writer = .{ .underlying_writer = &tar_out.writer };
    for (files) |f| try tw.writeFileBytes(f[0], f[1], .{ .mode = 0o644 });
    try tw.finishPedantically();
    var gz: Io.Writer.Allocating = .init(gpa);
    errdefer gz.deinit();
    var cbuf: [std.compress.flate.max_window_len]u8 = undefined;
    var raw = try std.compress.flate.Compress.Raw.init(&gz.writer, &cbuf, .gzip);
    try raw.writer.writeAll(tar_out.written());
    try raw.writer.flush();
    return gz.toOwnedSlice();
}

/// Tests (here and in updater.zig): a release-shaped `.tar.gz` with
/// `<top>/BUILDINFO.zon` and `<top>/zigguro`.
pub fn testArchive(gpa: Allocator, top: []const u8, version: []const u8, target: []const u8) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const info = try std.fmt.allocPrint(a, ".{{ .version = \"{s}\", .target = \"{s}\" }}\n", .{ version, target });
    return testTarGz(gpa, &.{
        .{ try std.fmt.allocPrint(a, "{s}/BUILDINFO.zon", .{top}), info },
        .{ try std.fmt.allocPrint(a, "{s}/zigguro", .{top}), "binary" },
    });
}

const build_info =
    \\.{ .version = "0.5.0+gabc", .channel = .stable, .target = "x86_64-linux-gnu.2.28", .optimize = .ReleaseSafe }
;

fn expect05() Expect {
    return .{ .version = "0.5.0+gabc", .target = "x86_64-linux-gnu.2.28", .sha256 = @splat(0xab), .serial = 7, .now_unix = 1_761_000_000 };
}

fn setup(tmp: *testing.TmpDir, archive: []const u8, bytes: []const u8) !void {
    try tmp.dir.createDirPath(testing.io, names.download);
    var dl = try tmp.dir.openDir(testing.io, names.download, .{});
    defer dl.close(testing.io);
    try dl.writeFile(testing.io, .{ .sub_path = archive, .data = bytes });
}

test "stage: zip and tar.gz" {
    const gpa = testing.allocator;
    const io = testing.io;
    const files = [_][2][]const u8{
        .{ "zigguro-0.5.0-x86_64-linux/BUILDINFO.zon", build_info },
        .{ "zigguro-0.5.0-x86_64-linux/zigguro", "binary" },
    };
    const zip = try testZip(gpa, &files);
    defer gpa.free(zip);
    const tgz = try testTarGz(gpa, &files);
    defer gpa.free(tgz);
    for ([_]struct { []const u8, []const u8 }{ .{ "a.zip", zip }, .{ "a.tar.gz", tgz } }) |c| {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        try setup(&tmp, c[0], c[1]);
        try stage(arena.allocator(), io, tmp.dir, c[0], expect05());
        var buf: [64]u8 = undefined;
        try testing.expectEqualStrings("binary", try tmp.dir.readFile(io, "staged/zigguro", &buf));
        const s = readStaged(arena.allocator(), io, tmp.dir).?;
        try testing.expectEqualStrings("0.5.0+gabc", s.version);
        try testing.expectEqual(@as(u64, 7), s.serial);
        try testing.expectEqualStrings("abab", s.sha256[0..4]);
        // The archive and the scratch directory are gone.
        try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "staged.download/" ++ "a.zip", .{}));
        try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, names.staged_tmp, .{}));
    }
}

test "stage: version and target mismatch rejected, nothing left behind" {
    const gpa = testing.allocator;
    const io = testing.io;
    const zip = try testZip(gpa, &.{.{ "top/BUILDINFO.zon", build_info }});
    defer gpa.free(zip);
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try setup(&tmp, "a.zip", zip);
    var e = expect05();
    e.version = "0.6.0";
    try testing.expectError(error.VersionMismatch, stage(arena.allocator(), io, tmp.dir, "a.zip", e));
    e = expect05();
    e.target = "aarch64-linux-gnu.2.28";
    try testing.expectError(error.TargetMismatch, stage(arena.allocator(), io, tmp.dir, "a.zip", e));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, names.staged_tmp, .{}));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, names.staged, .{}));
    try testing.expect(readStaged(arena.allocator(), io, tmp.dir) == null);

    // Two top-level entries, or no BUILDINFO.zon.
    const two = try testZip(gpa, &.{ .{ "a/BUILDINFO.zon", build_info }, .{ "b/x", "" } });
    defer gpa.free(two);
    try setup(&tmp, "two.zip", two);
    try testing.expectError(error.BadLayout, stage(arena.allocator(), io, tmp.dir, "two.zip", expect05()));
    const none = try testZip(gpa, &.{.{ "a/x", "" }});
    defer gpa.free(none);
    try setup(&tmp, "none.zip", none);
    try testing.expectError(error.MissingBuildInfo, stage(arena.allocator(), io, tmp.dir, "none.zip", expect05()));
    try testing.expectError(error.UnknownArchive, stage(arena.allocator(), io, tmp.dir, "a.7z", expect05()));
}

test "stage: replaces older staged" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try tmp.dir.createDirPath(io, "staged");
    try tmp.dir.writeFile(io, .{ .sub_path = "staged/old-only", .data = "old" });
    const zip = try testZip(gpa, &.{ .{ "top/BUILDINFO.zon", build_info }, .{ "top/new", "new" } });
    defer gpa.free(zip);
    try setup(&tmp, "a.zip", zip);
    try stage(arena.allocator(), io, tmp.dir, "a.zip", expect05());
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "staged/old-only", .{}));
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("new", try tmp.dir.readFile(io, "staged/new", &buf));
}
