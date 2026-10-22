//! Deterministic `.tar.gz` writer (reproducible-builds archive rules):
//! entries in the given (sorted) order, mtime = SOURCE_DATE_EPOCH, the
//! given modes, uid/gid 0 and empty owner names (std's ustar header leaves
//! them zero), long paths through the ustar prefix field, and a gzip header
//! with MTIME 0 and OS 3 at compression level 9.

const std = @import("std");
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;
const layout = @import("layout.zig");

/// Writes `entries` (with file contents resolved through `read`) as a
/// gzipped tar to `out`, whose buffer must be larger than 8 bytes.
pub fn writeTarGz(
    gpa: Allocator,
    out: *std.Io.Writer,
    entries: []const layout.Entry,
    epoch: i64,
    ctx: anytype,
    comptime read: fn (@TypeOf(ctx), []const u8) anyerror![]const u8,
) !void {
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var gz: flate.Compress = try .init(out, window, .gzip, .best);
    var tw: std.tar.Writer = .{ .underlying_writer = &gz.writer };
    const mtime: u64 = @intCast(@max(0, epoch));
    for (entries) |e| {
        const opts: std.tar.Writer.Options = .{ .mode = e.mode, .mtime = mtime };
        switch (e.source) {
            .dir => try tw.writeDir(std.mem.trimEnd(u8, e.archive_path, "/"), opts),
            .symlink => |t| try tw.writeLink(e.archive_path, t, opts),
            .bytes => |b| try tw.writeFileBytes(e.archive_path, b, opts),
            .file => |p| try tw.writeFileBytes(e.archive_path, try read(ctx, p), opts),
        }
    }
    try tw.finishPedantically();
    try gz.finish();
    try out.flush();
}

const testing = std.testing;

fn noRead(_: void, _: []const u8) anyerror![]const u8 {
    return error.Unexpected;
}

fn build(gpa: Allocator, entries: []const layout.Entry) ![]u8 {
    var aw: std.Io.Writer.Allocating = try .initCapacity(gpa, 4096);
    errdefer aw.deinit();
    try writeTarGz(gpa, &aw.writer, entries, 1761016620, {}, noRead);
    return aw.toOwnedSlice();
}

fn gunzip(gpa: Allocator, bytes: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(bytes);
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var d: flate.Decompress = .init(&in, .gzip, window);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    _ = try d.reader.streamRemaining(&aw.writer);
    return aw.toOwnedSlice();
}

test "targz: roundtrip via std.tar" {
    const long_name = "z/" ++ "d" ** 90 ++ "/" ++ "f" ** 87;
    comptime std.debug.assert(long_name.len == 180);
    const entries = [_]layout.Entry{
        .{ .archive_path = "z/", .source = .dir, .mode = 0o755 },
        .{ .archive_path = "z/AppRun", .source = .{ .symlink = "zigguro" }, .mode = 0o755 },
        .{ .archive_path = long_name, .source = .{ .bytes = "long" }, .mode = 0o644 },
        .{ .archive_path = "z/zigguro", .source = .{ .bytes = "\x7fELF" }, .mode = 0o755 },
    };
    const bytes = try build(testing.allocator, &entries);
    defer testing.allocator.free(bytes);
    // gzip header: MTIME 0 and OS 3.
    try testing.expectEqualSlices(u8, &.{ 0x1f, 0x8b, 8, 0, 0, 0, 0, 0 }, bytes[0..8]);
    try testing.expectEqual(@as(u8, 3), bytes[9]);
    const tar = try gunzip(testing.allocator, bytes);
    defer testing.allocator.free(tar);

    // Headers carry the epoch, the mode and empty owners.
    try testing.expectEqualStrings("0000755", tar[100..107]);
    try testing.expect(std.mem.allEqual(u8, tar[265..329], 0));

    var in: std.Io.Reader = .fixed(tar);
    var fname: [std.fs.max_path_bytes]u8 = undefined;
    var lname: [std.fs.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(&in, .{ .file_name_buffer = &fname, .link_name_buffer = &lname });
    var i: usize = 0;
    while (try it.next()) |f| : (i += 1) {
        const e = entries[i];
        try testing.expectEqualStrings(std.mem.trimEnd(u8, e.archive_path, "/"), f.name);
        try testing.expectEqual(e.mode, f.mode);
        switch (e.source) {
            .symlink => |t| try testing.expectEqualStrings(t, f.link_name),
            .bytes => |b| try testing.expectEqual(@as(u64, b.len), f.size),
            else => {},
        }
    }
    try testing.expectEqual(entries.len, i);

    const again = try build(testing.allocator, &entries);
    defer testing.allocator.free(again);
    try testing.expectEqualSlices(u8, bytes, again);
}
