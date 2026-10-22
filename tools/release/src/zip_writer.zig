//! Deterministic zip writer (PKWARE APPNOTE 6.3.10).
//!
//! Every entry carries the same DOS timestamp (`Options.dos_epoch`, UTC),
//! flag bit 11 (UTF-8 names), version made by Unix 6.3 with the Unix mode in
//! the external attributes, no data descriptors and no extra fields except
//! the Zip64 extended information field when a size or offset needs it.
//! Files are deflated (raw stream, level 9) unless that does not shrink
//! them; empty files, directories and symlinks are stored. Entries must be
//! added in byte-wise sorted path order.

const std = @import("std");
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

/// Unix file type bits stored in the high half of the external attributes.
pub const S_IFREG: u32 = 0o100000;
/// Directory type bits.
pub const S_IFDIR: u32 = 0o040000;
/// Symlink type bits.
pub const S_IFLNK: u32 = 0o120000;

const max32: u64 = 0xFFFFFFFF;
const max16: u64 = 0xFFFF;

/// A streaming deterministic zip writer.
pub const ZipWriter = struct {
    out: *std.Io.Writer,
    gpa: Allocator,
    opts: Options,
    offset: u64 = 0,
    central: std.ArrayList(u8) = .empty,
    count: u64 = 0,
    last_path: []u8 = &.{},
    time: u16,
    date: u16,

    /// Writer options.
    pub const Options = struct {
        /// Timestamp of every entry (SOURCE_DATE_EPOCH), seconds since 1970, UTC.
        dos_epoch: i64,
        level: flate.Compress.Options = .best,
    };

    /// One archive member. Directory paths end with `/`.
    pub const Entry = struct {
        path: []const u8,
        /// Permission bits (e.g. 0o755); the type bits are added from `kind`.
        mode: u32,
        kind: enum { file, dir, symlink },
        data: []const u8 = "",
        link_target: []const u8 = "",
    };

    /// Creates a writer that emits to `out`.
    pub fn init(out: *std.Io.Writer, gpa: Allocator, opts: Options) ZipWriter {
        const dt = dosDateTime(opts.dos_epoch);
        return .{ .out = out, .gpa = gpa, .opts = opts, .time = dt.time, .date = dt.date };
    }

    /// Frees bookkeeping memory (call after `finish` or on error).
    pub fn deinit(z: *ZipWriter) void {
        z.central.deinit(z.gpa);
        z.gpa.free(z.last_path);
    }

    /// Appends one entry. Paths must be strictly increasing (asserted).
    pub fn add(z: *ZipWriter, e: Entry) !void {
        std.debug.assert(z.count == 0 or std.mem.order(u8, z.last_path, e.path) == .lt);
        std.debug.assert((e.kind == .dir) == std.mem.endsWith(u8, e.path, "/"));
        z.gpa.free(z.last_path);
        z.last_path = try z.gpa.dupe(u8, e.path);

        const raw: []const u8 = switch (e.kind) {
            .file => e.data,
            .symlink => e.link_target,
            .dir => "",
        };
        const crc = std.hash.Crc32.hash(raw);
        var compressed: ?[]u8 = null;
        defer if (compressed) |c| z.gpa.free(c);
        if (e.kind == .file and raw.len > 0) {
            const c = try deflateRaw(z.gpa, raw, z.opts.level);
            if (c.len < raw.len) compressed = c else z.gpa.free(c);
        }
        const payload = compressed orelse raw;
        const method: u16 = if (compressed != null) 8 else 0;
        const type_bits: u32 = switch (e.kind) {
            .file => S_IFREG,
            .dir => S_IFDIR,
            .symlink => S_IFLNK,
        };
        const ext_attr: u32 = ((type_bits | (e.mode & 0o7777)) << 16) | @as(u32, if (e.kind == .dir) 0x10 else 0);
        const local_offset = z.offset;
        const zip64 = needsZip64(raw.len, payload.len, local_offset);
        const needed: u16 = if (zip64) 45 else 20;

        // Local file header.
        var lh: [30]u8 = undefined;
        std.mem.writeInt(u32, lh[0..4], 0x04034b50, .little);
        std.mem.writeInt(u16, lh[4..6], needed, .little);
        std.mem.writeInt(u16, lh[6..8], 0x0800, .little);
        std.mem.writeInt(u16, lh[8..10], method, .little);
        std.mem.writeInt(u16, lh[10..12], z.time, .little);
        std.mem.writeInt(u16, lh[12..14], z.date, .little);
        std.mem.writeInt(u32, lh[14..18], crc, .little);
        std.mem.writeInt(u32, lh[18..22], if (zip64) @intCast(max32) else @intCast(payload.len), .little);
        std.mem.writeInt(u32, lh[22..26], if (zip64) @intCast(max32) else @intCast(raw.len), .little);
        std.mem.writeInt(u16, lh[26..28], @intCast(e.path.len), .little);
        std.mem.writeInt(u16, lh[28..30], if (zip64) 20 else 0, .little);
        try z.out.writeAll(&lh);
        try z.out.writeAll(e.path);
        if (zip64) {
            var x: [20]u8 = undefined;
            std.mem.writeInt(u16, x[0..2], 1, .little);
            std.mem.writeInt(u16, x[2..4], 16, .little);
            std.mem.writeInt(u64, x[4..12], raw.len, .little);
            std.mem.writeInt(u64, x[12..20], payload.len, .little);
            try z.out.writeAll(&x);
        }
        try z.out.writeAll(payload);
        z.offset += 30 + e.path.len + @as(u64, if (zip64) 20 else 0) + payload.len;

        // Central directory header (buffered until finish).
        var ch: [46]u8 = undefined;
        std.mem.writeInt(u32, ch[0..4], 0x02014b50, .little);
        std.mem.writeInt(u16, ch[4..6], (3 << 8) | 63, .little);
        std.mem.writeInt(u16, ch[6..8], needed, .little);
        std.mem.writeInt(u16, ch[8..10], 0x0800, .little);
        std.mem.writeInt(u16, ch[10..12], method, .little);
        std.mem.writeInt(u16, ch[12..14], z.time, .little);
        std.mem.writeInt(u16, ch[14..16], z.date, .little);
        std.mem.writeInt(u32, ch[16..20], crc, .little);
        std.mem.writeInt(u32, ch[20..24], if (zip64) @intCast(max32) else @intCast(payload.len), .little);
        std.mem.writeInt(u32, ch[24..28], if (zip64) @intCast(max32) else @intCast(raw.len), .little);
        std.mem.writeInt(u16, ch[28..30], @intCast(e.path.len), .little);
        std.mem.writeInt(u16, ch[30..32], if (zip64) 28 else 0, .little);
        std.mem.writeInt(u16, ch[32..34], 0, .little);
        std.mem.writeInt(u16, ch[34..36], 0, .little);
        std.mem.writeInt(u16, ch[36..38], 0, .little);
        std.mem.writeInt(u32, ch[38..42], ext_attr, .little);
        std.mem.writeInt(u32, ch[42..46], if (zip64) @intCast(max32) else @intCast(local_offset), .little);
        try z.central.appendSlice(z.gpa, &ch);
        try z.central.appendSlice(z.gpa, e.path);
        if (zip64) {
            var x: [28]u8 = undefined;
            std.mem.writeInt(u16, x[0..2], 1, .little);
            std.mem.writeInt(u16, x[2..4], 24, .little);
            std.mem.writeInt(u64, x[4..12], raw.len, .little);
            std.mem.writeInt(u64, x[12..20], payload.len, .little);
            std.mem.writeInt(u64, x[20..28], local_offset, .little);
            try z.central.appendSlice(z.gpa, &x);
        }
        z.count += 1;
    }

    /// Writes the central directory and end records, then flushes `out`.
    pub fn finish(z: *ZipWriter) !void {
        const cd_offset = z.offset;
        const cd_size: u64 = z.central.items.len;
        try z.out.writeAll(z.central.items);
        const zip64 = endNeedsZip64(z.count, cd_size, cd_offset);
        if (zip64) {
            const rec_offset = cd_offset + cd_size;
            var r: [56]u8 = undefined;
            std.mem.writeInt(u32, r[0..4], 0x06064b50, .little);
            std.mem.writeInt(u64, r[4..12], 44, .little);
            std.mem.writeInt(u16, r[12..14], (3 << 8) | 63, .little);
            std.mem.writeInt(u16, r[14..16], 45, .little);
            std.mem.writeInt(u32, r[16..20], 0, .little);
            std.mem.writeInt(u32, r[20..24], 0, .little);
            std.mem.writeInt(u64, r[24..32], z.count, .little);
            std.mem.writeInt(u64, r[32..40], z.count, .little);
            std.mem.writeInt(u64, r[40..48], cd_size, .little);
            std.mem.writeInt(u64, r[48..56], cd_offset, .little);
            try z.out.writeAll(&r);
            var l: [20]u8 = undefined;
            std.mem.writeInt(u32, l[0..4], 0x07064b50, .little);
            std.mem.writeInt(u32, l[4..8], 0, .little);
            std.mem.writeInt(u64, l[8..16], rec_offset, .little);
            std.mem.writeInt(u32, l[16..20], 1, .little);
            try z.out.writeAll(&l);
        }
        var eocd: [22]u8 = undefined;
        std.mem.writeInt(u32, eocd[0..4], 0x06054b50, .little);
        std.mem.writeInt(u16, eocd[4..6], 0, .little);
        std.mem.writeInt(u16, eocd[6..8], 0, .little);
        const n16: u16 = if (z.count >= max16) @intCast(max16) else @intCast(z.count);
        std.mem.writeInt(u16, eocd[8..10], n16, .little);
        std.mem.writeInt(u16, eocd[10..12], n16, .little);
        std.mem.writeInt(u32, eocd[12..16], if (cd_size >= max32) @intCast(max32) else @intCast(cd_size), .little);
        std.mem.writeInt(u32, eocd[16..20], if (cd_offset >= max32) @intCast(max32) else @intCast(cd_offset), .little);
        std.mem.writeInt(u16, eocd[20..22], 0, .little);
        try z.out.writeAll(&eocd);
        try z.out.flush();
    }
};

/// True when an entry needs the Zip64 extended information field.
pub fn needsZip64(uncompressed: u64, compressed: u64, local_offset: u64) bool {
    return uncompressed >= max32 or compressed >= max32 or local_offset >= max32;
}

/// True when the end of central directory needs Zip64 records.
pub fn endNeedsZip64(count: u64, cd_size: u64, cd_offset: u64) bool {
    return count >= max16 or cd_size >= max32 or cd_offset >= max32;
}

/// Raw deflate of `data` (no zlib/gzip framing).
pub fn deflateRaw(gpa: Allocator, data: []const u8, level: flate.Compress.Options) ![]u8 {
    var aw: std.Io.Writer.Allocating = try .initCapacity(gpa, @max(64, data.len / 2));
    errdefer aw.deinit();
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var c: flate.Compress = try .init(&aw.writer, window, .raw, level);
    try c.writer.writeAll(data);
    try c.finish();
    return aw.toOwnedSlice();
}

/// MS-DOS date and time fields.
pub const DosDateTime = struct { date: u16, time: u16 };

/// Converts Unix seconds (UTC) to DOS date/time, clamped to 1980..2107.
pub fn dosDateTime(unix: i64) DosDateTime {
    const min: i64 = 315532800; // 1980-01-01T00:00:00Z
    const t = std.math.clamp(unix, min, 4354819198);
    const days = @divFloor(t, 86400);
    const secs: u32 = @intCast(t - days * 86400);
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(t) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    return .{
        .date = @intCast(((@as(u32, yd.year) - 1980) << 9) | (@as(u32, md.month.numeric()) << 5) | (md.day_index + 1)),
        .time = @intCast(((secs / 3600) << 11) | ((secs / 60 % 60) << 5) | (secs % 60 / 2)),
    };
}

const testing = std.testing;

fn writeZip(gpa: Allocator, entries: []const ZipWriter.Entry, epoch: i64) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    var z: ZipWriter = .init(&aw.writer, gpa, .{ .dos_epoch = epoch });
    defer z.deinit();
    for (entries) |e| try z.add(e);
    try z.finish();
    return aw.toOwnedSlice();
}

/// Reads every member of `bytes` back through `std.zip` (via a temp file)
/// and checks it against `entries`.
fn expectRoundTrip(entries: []const ZipWriter.Entry, bytes: []const u8) !void {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zip", .data = bytes });
    var f = try tmp.dir.openFile(io, "a.zip", .{});
    defer f.close(io);
    var rbuf: [4096]u8 = undefined;
    var fr = f.reader(io, &rbuf);
    var it = try std.zip.Iterator.init(&fr);
    var i: usize = 0;
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    while (try it.next()) |entry| : (i += 1) {
        const e = entries[i];
        try fr.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
        const name = name_buf[0..entry.filename_len];
        try fr.interface.readSliceAll(name);
        try testing.expectEqualStrings(e.path, name);
        const expect_data: []const u8 = switch (e.kind) {
            .file => e.data,
            .symlink => e.link_target,
            .dir => "",
        };
        try testing.expectEqual(@as(u64, expect_data.len), entry.uncompressed_size);
        try testing.expectEqual(std.hash.Crc32.hash(expect_data), entry.crc32);
    }
    try testing.expectEqual(entries.len, i);

    // And std.zip.extract accepts the archive (files and dirs only).
    var only_files: std.ArrayList(ZipWriter.Entry) = .empty;
    defer only_files.deinit(testing.allocator);
    for (entries) |e| if (e.kind != .symlink) try only_files.append(testing.allocator, e);
    const plain = try writeZip(testing.allocator, only_files.items, 0);
    defer testing.allocator.free(plain);
    try tmp.dir.writeFile(io, .{ .sub_path = "b.zip", .data = plain });
    var out = try tmp.dir.createDirPathOpen(io, "out", .{});
    defer out.close(io);
    var g = try tmp.dir.openFile(io, "b.zip", .{});
    defer g.close(io);
    var gr = g.reader(io, &rbuf);
    try std.zip.extract(out, &gr, .{});
    for (only_files.items) |e| if (e.kind == .file) {
        const got = try out.readFileAlloc(io, e.path, testing.allocator, .unlimited);
        defer testing.allocator.free(got);
        try testing.expectEqualSlices(u8, e.data, got);
    };
}

test "zip: roundtrip via std.zip.extract" {
    var prng: std.Random.DefaultPrng = .init(0x21b);
    const r = prng.random();
    const big = try testing.allocator.alloc(u8, 70 * 1024);
    defer testing.allocator.free(big);
    r.bytes(big);
    for (0..50) |round| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var list: std.ArrayList(ZipWriter.Entry) = .empty;
        try list.append(a, .{ .path = "d/", .mode = 0o755, .kind = .dir });
        try list.append(a, .{ .path = "d/empty", .mode = 0o644, .kind = .file });
        try list.append(a, .{ .path = "d/emptydir/", .mode = 0o755, .kind = .dir });
        try list.append(a, .{ .path = "d/link", .mode = 0o777, .kind = .symlink, .link_target = "zigguro" });
        try list.append(a, .{ .path = "d/noise.bin", .mode = 0o644, .kind = .file, .data = if (round % 5 == 0) big else big[0..r.uintLessThan(usize, 4096)] });
        const n = r.uintLessThan(usize, 6);
        for (0..n) |k| {
            const len = r.uintLessThan(usize, 3000);
            const data = try a.alloc(u8, len);
            for (data) |*c| c.* = "abc\n"[r.uintLessThan(usize, 4)];
            try list.append(a, .{ .path = try std.fmt.allocPrint(a, "d/z{d}-ünï.txt", .{k}), .mode = if (k % 2 == 0) 0o755 else 0o644, .kind = .file, .data = data });
        }
        const bytes = try writeZip(testing.allocator, list.items, 1761016620);
        defer testing.allocator.free(bytes);
        try expectRoundTrip(list.items, bytes);
    }
}

test "zip: deterministic bytes" {
    const entries = [_]ZipWriter.Entry{
        .{ .path = "zigguro-0.4.0-x86_64-windows/", .mode = 0o755, .kind = .dir },
        .{ .path = "zigguro-0.4.0-x86_64-windows/LICENSE", .mode = 0o644, .kind = .file, .data = "Apache License 2.0\n" ** 20 },
        .{ .path = "zigguro-0.4.0-x86_64-windows/zg.exe", .mode = 0o755, .kind = .file, .data = "MZ" },
    };
    const a = try writeZip(testing.allocator, &entries, 1761016620);
    defer testing.allocator.free(a);
    const b = try writeZip(testing.allocator, &entries, 1761016620);
    defer testing.allocator.free(b);
    try testing.expectEqualSlices(u8, a, b);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(a, &digest, .{});
    var hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&hex, "{x}", .{&digest});
    try testing.expectEqualStrings("f62836f42a937ad5183069e26f651aedc27ccbec7fbd0f07b1eab4742c4ce136", &hex);
    // External attributes carry the mode; LICENSE is deflated, zg.exe stored.
    try testing.expect(std.mem.indexOf(u8, a, &.{ 0xed, 0x81 }) != null); // 0o100755 >> 8 within attrs
}

test "zip: zip64 thresholds" {
    try testing.expect(!needsZip64(0xFFFFFFFE, 10, 0));
    try testing.expect(needsZip64(4 << 30, 10, 0));
    try testing.expect(needsZip64(0, 0xFFFFFFFF, 0));
    try testing.expect(needsZip64(0, 0, 0xFFFFFFFF));
    try testing.expect(!endNeedsZip64(0xFFFE, 100, 100));
    try testing.expect(endNeedsZip64(0xFFFF, 100, 100));
    try testing.expect(endNeedsZip64(1, 0xFFFFFFFF, 0));
    try testing.expect(endNeedsZip64(1, 0, 0xFFFFFFFF));
    // A writer whose offset is already past 4 GiB emits Zip64 records that
    // still describe a no-data entry correctly.
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var z: ZipWriter = .init(&aw.writer, testing.allocator, .{ .dos_epoch = 0 });
    defer z.deinit();
    z.offset = 5 << 30;
    try z.add(.{ .path = "x/", .mode = 0o755, .kind = .dir });
    try z.finish();
    const w = aw.written();
    try testing.expectEqual(@as(u16, 45), std.mem.readInt(u16, w[4..6], .little));
    try testing.expect(std.mem.indexOf(u8, w, &.{ 'P', 'K', 6, 6 }) != null);
    try testing.expect(std.mem.indexOf(u8, w, &.{ 'P', 'K', 6, 7 }) != null);
}

test "zip: dos time" {
    const dt = dosDateTime(1761016620); // 2025-10-21T03:17:00Z
    try testing.expectEqual(@as(u16, ((2025 - 1980) << 9) | (10 << 5) | 21), dt.date);
    try testing.expectEqual(@as(u16, (3 << 11) | (17 << 5)), dt.time);
    const early = dosDateTime(0);
    try testing.expectEqual(@as(u16, (1 << 5) | 1), early.date);
}

test "fuzz: zip writer→reader roundtrip" {
    try testing.fuzz({}, struct {
        fn one(_: void, s: *testing.Smith) anyerror!void {
            var input: [1024]u8 = undefined;
            const n = s.slice(&input);
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var list: std.ArrayList(ZipWriter.Entry) = .empty;
            var pos: usize = 0;
            var k: usize = 0;
            while (pos < n and k < 8) : (k += 1) {
                const take = @min(n - pos, @as(usize, input[pos]) * 4);
                pos += 1;
                const data = input[pos..][0..@min(take, n - pos)];
                pos += data.len;
                try list.append(a, .{ .path = try std.fmt.allocPrint(a, "f{d}", .{k}), .mode = 0o644, .kind = .file, .data = data });
            }
            const bytes = try writeZip(testing.allocator, list.items, 0);
            defer testing.allocator.free(bytes);
            try expectRoundTrip(list.items, bytes);
        }
    }.one, .{});
}
