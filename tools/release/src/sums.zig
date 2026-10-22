//! `SHA256SUMS`: `<64 hex>  <filename>` lines (two spaces, binary mode),
//! sorted by file name, LF endings; compatible with `sha256sum -c`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const args = @import("args.zig");

/// One checksum line.
pub const Line = struct { name: []const u8, digest: [32]u8 };

/// Writes the lines sorted by name.
pub fn write(w: *std.Io.Writer, lines: []Line) std.Io.Writer.Error!void {
    std.mem.sort(Line, lines, {}, struct {
        fn lt(_: void, a: Line, b: Line) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lt);
    for (lines) |l| try w.print("{x}  {s}\n", .{ &l.digest, l.name });
}

/// SHA-256 of a file, streamed.
pub fn hashFile(io: std.Io, dir: std.Io.Dir, path: []const u8) ![32]u8 {
    var f = try dir.openFile(io, path, .{});
    defer f.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var r = f.reader(io, &buf);
    var h: Sha256 = .init(.{});
    while (true) {
        const chunk = r.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        h.update(chunk);
        r.interface.toss(chunk.len);
    }
    return h.finalResult();
}

/// `zg-release sums --dir <d> [--out <d>/SHA256SUMS]`: checksums every
/// regular file in `<d>` except SHA256SUMS* itself.
pub fn run(ctx: *const args.Context) !u8 {
    const io = ctx.io;
    const dir_path = try ctx.opts.need("dir");
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var lines: std.ArrayList(Line) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file or std.mem.startsWith(u8, e.name, "SHA256SUMS")) continue;
        const name = try ctx.gpa.dupe(u8, e.name);
        try lines.append(ctx.gpa, .{ .name = name, .digest = try hashFile(io, dir, name) });
    }
    var aw: std.Io.Writer.Allocating = .init(ctx.gpa);
    try write(&aw.writer, lines.items);
    const out = ctx.opts.get("out") orelse try std.fmt.allocPrint(ctx.gpa, "{s}/SHA256SUMS", .{dir_path});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out, .data = aw.written() });
    return 0;
}

test "sums: sha256sum format" {
    var lines = [_]Line{
        .{ .name = "zigguro-0.4.0-x86_64-windows.zip", .digest = undefined },
        .{ .name = "SHA256SUMS.minisig.not", .digest = undefined },
        .{ .name = "zigguro-0.4.0-x86_64-linux.tar.gz", .digest = undefined },
    };
    Sha256.hash("", &lines[0].digest, .{});
    Sha256.hash("abc", &lines[1].digest, .{});
    Sha256.hash("x", &lines[2].digest, .{});
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try write(&w, &lines);
    try std.testing.expectEqualStrings(
        \\ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  SHA256SUMS.minisig.not
        \\2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881  zigguro-0.4.0-x86_64-linux.tar.gz
        \\e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  zigguro-0.4.0-x86_64-windows.zip
        \\
    , w.buffered());
}
