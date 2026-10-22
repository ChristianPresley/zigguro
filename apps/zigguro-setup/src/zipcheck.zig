//! CRC-32 check of every entry of a zip, which `std.zip.extract` does not
//! do (its `verify_checksums` is unimplemented in Zig 0.16). Setup runs
//! it on the payload before extracting, so a damaged installer fails with
//! exit code 4 instead of installing damaged files.

const std = @import("std");
const Io = std.Io;
const zip = std.zip;

pub const Error = error{ ZipBadCrc, ZipDecompressTruncated, ZipBadFileOffset, UnsupportedCompressionMethod };

/// Checks every entry of the zip `file` against its central directory
/// CRC-32.
pub fn verify(io: Io, file: Io.File) !void {
    var rbuf: [64 * 1024]u8 = undefined;
    var fr = file.reader(io, &rbuf);
    var it = try zip.Iterator.init(&fr);
    var data_buf: [64 * 1024]u8 = undefined;
    while (try it.next()) |e| {
        var src = file.reader(io, &data_buf);
        try src.seekTo(e.file_offset);
        const lh = src.interface.takeStruct(zip.LocalFileHeader, .little) catch |err| return mapStream(err);
        if (!std.mem.eql(u8, &lh.signature, &zip.local_file_header_sig)) return error.ZipBadFileOffset;
        try src.seekTo(e.file_offset + @sizeOf(zip.LocalFileHeader) + lh.filename_len + lh.extra_len);
        var hb: [256]u8 = undefined;
        var h: Io.Writer.Hashing(std.hash.Crc32) = .initHasher(.init(), &hb);
        switch (e.compression_method) {
            .store => src.interface.streamExact64(&h.writer, e.uncompressed_size) catch |err| return mapStream(err),
            .deflate => {
                var window: [std.compress.flate.max_window_len]u8 = undefined;
                var dec: std.compress.flate.Decompress = .init(&src.interface, .raw, &window);
                dec.reader.streamExact64(&h.writer, e.uncompressed_size) catch |err| return mapStream(err);
            },
            else => return error.UnsupportedCompressionMethod,
        }
        h.writer.flush() catch unreachable;
        if (h.hasher.final() != e.crc32) return error.ZipBadCrc;
    }
}

fn mapStream(err: anyerror) anyerror {
    return switch (err) {
        error.EndOfStream => error.ZipDecompressTruncated,
        error.ReadFailed => error.ZipDecompressTruncated,
        else => err,
    };
}

/// Tests: a zip of `files` (name, data), each stored or deflated.
pub fn testZip(gpa: std.mem.Allocator, files: []const [2][]const u8, method: zip.CompressionMethod) ![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    var offsets: [8]u32 = undefined;
    var sizes: [8]u32 = undefined;
    for (files, 0..) |f, i| {
        var body: Io.Writer.Allocating = .init(gpa);
        defer body.deinit();
        if (method == .deflate) {
            var cbuf: [std.compress.flate.max_window_len]u8 = undefined;
            var c = try std.compress.flate.Compress.Raw.init(&body.writer, &cbuf, .raw);
            try c.writer.writeAll(f[1]);
            try c.writer.flush();
        } else try body.writer.writeAll(f[1]);
        offsets[i] = @intCast(out.written().len);
        sizes[i] = @intCast(body.written().len);
        try header(w, 0x04034b50, false, method, std.hash.Crc32.hash(f[1]), sizes[i], f, 0);
        try w.writeAll(f[0]);
        try w.writeAll(body.written());
    }
    const cd_start: u32 = @intCast(out.written().len);
    for (files, 0..) |f, i| {
        try header(w, 0x02014b50, true, method, std.hash.Crc32.hash(f[1]), sizes[i], f, offsets[i]);
        try w.writeAll(f[0]);
    }
    const cd_len: u32 = @intCast(out.written().len - cd_start);
    try w.writeInt(u32, 0x06054b50, .little);
    try w.writeInt(u32, 0, .little);
    try w.writeInt(u16, @intCast(files.len), .little);
    try w.writeInt(u16, @intCast(files.len), .little);
    try w.writeInt(u32, cd_len, .little);
    try w.writeInt(u32, cd_start, .little);
    try w.writeInt(u16, 0, .little);
    return out.toOwnedSlice();
}

fn header(w: *Io.Writer, sig: u32, central: bool, method: zip.CompressionMethod, crc: u32, csize: u32, f: [2][]const u8, offset: u32) !void {
    try w.writeInt(u32, sig, .little);
    if (central) try w.writeInt(u16, 20, .little);
    try w.writeInt(u16, 20, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, @intFromEnum(method), .little);
    try w.writeInt(u32, 0, .little);
    try w.writeInt(u32, crc, .little);
    try w.writeInt(u32, csize, .little);
    try w.writeInt(u32, @intCast(f[1].len), .little);
    try w.writeInt(u16, @intCast(f[0].len), .little);
    try w.writeInt(u16, 0, .little);
    if (central) {
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u32, 0, .little);
        try w.writeInt(u32, offset, .little);
    }
}

const testing = std.testing;

test "zipcheck: stored and deflated entries, damaged data fails the CRC" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const body = "zigguro " ** 200;
    inline for (.{ zip.CompressionMethod.store, zip.CompressionMethod.deflate }) |m| {
        const z = try testZip(testing.allocator, &.{ .{ "top/a.txt", body }, .{ "top/b.txt", "b" } }, m);
        defer testing.allocator.free(z);
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "ok.zip", .data = z });
        {
            const f = try tmp.dir.openFile(testing.io, "ok.zip", .{});
            defer f.close(testing.io);
            try verify(testing.io, f);
        }
        // For stored data flip a payload byte; for deflate, the central
        // directory's CRC (damaged deflate data may not decode at all).
        if (m == .store) {
            z[std.mem.indexOf(u8, z, "zigguro").?] = 'Z';
        } else {
            const cd = std.mem.readInt(u32, z[z.len - 6 ..][0..4], .little);
            z[cd + 16] ^= 0xff;
        }
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "bad.zip", .data = z });
        const f = try tmp.dir.openFile(testing.io, "bad.zip", .{});
        defer f.close(testing.io);
        try testing.expectError(error.ZipBadCrc, verify(testing.io, f));
    }
}
