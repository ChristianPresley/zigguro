//! The crash report store: `<state>/crashes/*.zgcrash`, listed newest
//! first, pruned oldest first (default 50 reports / 50 MiB). Normal code
//! path (allocates); never used from a crash handler. Listing reads at most
//! the first 8 KiB of each report (META, EXCEPTION and the first TRACE
//! entry).

const std = @import("std");
const Allocator = std.mem.Allocator;
const format = @import("format.zig");
const timefmt = @import("timefmt.zig");

/// Default retention.
pub const default_max_count = 50;
/// Default retention in bytes.
pub const default_max_bytes = 50 * 1024 * 1024;
/// Bytes read per report when listing.
pub const list_read_bytes = 8 * 1024;

/// Summary of one report.
pub const ReportInfo = struct {
    name: []const u8,
    created_unix_ms: i64,
    kind: format.ReportKind,
    /// `.version` from META, or "".
    version: []const u8,
    /// Innermost TRACE address, or the EXCEPTION pc, or 0.
    top_frame_pc: u64,
    size: u64,
};

/// Extracts the string value of `.<field> = "..."` from META ZON text.
pub fn metaField(meta: []const u8, comptime field: []const u8) []const u8 {
    const needle = "." ++ field ++ " = \"";
    const at = std.mem.indexOf(u8, meta, needle) orelse return "";
    const rest = meta[at + needle.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return "";
    return rest[0..end];
}

/// Summarizes a report prefix.
pub fn summarize(name: []const u8, bytes: []const u8, size: u64) ?ReportInfo {
    var r = format.Reader.init(bytes) catch return null;
    var info: ReportInfo = .{ .name = name, .created_unix_ms = r.header.created_unix_ms, .kind = .unknown, .version = "", .top_frame_pc = 0, .size = size };
    while (r.next()) |s| switch (s.kind) {
        .meta => info.version = metaField(s.data, "version"),
        .exception => if (format.decodeException(s.data)) |e| {
            info.kind = @enumFromInt(e.kind);
            if (info.top_frame_pc == 0) info.top_frame_pc = e.pc;
        },
        .trace => if (format.decodeTrace(s.data)) |t| {
            if (t.count > 0) info.top_frame_pc = t.at(0);
        },
        else => {},
    };
    return info;
}

/// Lists the reports in `dir`, newest first. Strings are owned by `gpa`.
pub fn list(gpa: Allocator, io: std.Io, dir: std.Io.Dir) ![]ReportInfo {
    var out: std.ArrayList(ReportInfo) = .empty;
    errdefer out.deinit(gpa);
    var it = dir.iterate();
    var buf: [list_read_bytes]u8 = undefined;
    while (try it.next(io)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".zgcrash")) continue;
        var f = dir.openFile(io, e.name, .{}) catch continue;
        defer f.close(io);
        const st = f.stat(io) catch continue;
        const n = f.readPositionalAll(io, &buf, 0) catch continue;
        const name = try gpa.dupe(u8, e.name);
        const prefix = try gpa.dupe(u8, buf[0..n]);
        if (summarize(name, prefix, st.size)) |info| try out.append(gpa, info) else {
            gpa.free(name);
            gpa.free(prefix);
        }
    }
    std.mem.sort(ReportInfo, out.items, {}, newerFirst);
    return out.toOwnedSlice(gpa);
}

fn newerFirst(_: void, a: ReportInfo, b: ReportInfo) bool {
    if (a.created_unix_ms != b.created_unix_ms) return a.created_unix_ms > b.created_unix_ms;
    return std.mem.order(u8, a.name, b.name) == .gt;
}

/// Deletes the oldest reports until at most `max_count` remain and they
/// total at most `max_bytes`.
pub fn prune(gpa: Allocator, io: std.Io, dir: std.Io.Dir, max_count: u32, max_bytes: u64) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const infos = try list(arena.allocator(), io, dir);
    var total: u64 = 0;
    for (infos, 0..) |info, i| {
        total += info.size;
        if (i >= max_count or total > max_bytes) dir.deleteFile(io, info.name) catch {};
    }
}

/// The prefix of `infos` (newest first) created after `last_seen_ms`.
pub fn unseen(infos: []const ReportInfo, last_seen_ms: i64) []const ReportInfo {
    for (infos, 0..) |info, i| if (info.created_unix_ms <= last_seen_ms) return infos[0..i];
    return infos;
}

/// Writes a minimal synthetic report (tests and fixtures).
pub fn writeSynthetic(io: std.Io, dir: std.Io.Dir, created_ms: i64, pid: u32, kind: format.ReportKind, ver: []const u8, padding: usize) !void {
    var out: [64 * 1024]u8 = undefined;
    var ms: format.MemorySink = .{ .buf = &out };
    var wbuf: [32 * 1024]u8 = undefined;
    var w: format.Writer = .{ .buf = &wbuf, .sink = ms.sink() };
    w.begin(created_ms);
    var meta_buf: [128]u8 = undefined;
    w.writeSection(.meta, try std.fmt.bufPrint(&meta_buf, ".{{ .version = \"{s}\" }}", .{ver}));
    var e = w.section(.exception);
    e.writeStruct(format.Exception{ .kind = @intFromEnum(kind), .os_code = 11, .si_code = 0, .has_fault_addr = 0, .access = 255, .fault_addr = 0, .thread_id = 1, .pc = 0x1000, .sp = 0 });
    e.end();
    format.writeTrace(&w, &.{0x2000}, 0);
    var pad = w.section(.log);
    for (0..padding) |_| pad.write("x");
    pad.end();
    w.finish();
    var name_buf: [timefmt.max_name_len]u8 = undefined;
    try dir.writeFile(io, .{ .sub_path = timefmt.reportName(&name_buf, created_ms, pid), .data = ms.bytes() });
}

test "store: list/prune/unseen" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    for (0..6) |i| try writeSynthetic(io, tmp.dir, 1761016620000 + @as(i64, @intCast(i)) * 1000, 100 + @as(u32, @intCast(i)), .segfault, "0.4.0", 1000);
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "ignored" });
    try tmp.dir.writeFile(io, .{ .sub_path = "broken.zgcrash", .data = "nope" });

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const infos = try list(arena.allocator(), io, tmp.dir);
    try std.testing.expectEqual(@as(usize, 6), infos.len);
    try std.testing.expectEqual(@as(i64, 1761016625000), infos[0].created_unix_ms);
    try std.testing.expectEqualStrings("0.4.0", infos[0].version);
    try std.testing.expectEqual(format.ReportKind.segfault, infos[0].kind);
    try std.testing.expectEqual(@as(u64, 0x2000), infos[0].top_frame_pc);
    try std.testing.expectEqual(@as(usize, 2), unseen(infos, 1761016623000).len);
    try std.testing.expectEqual(@as(usize, 0), unseen(infos, 1761016625000).len);

    try prune(std.testing.allocator, io, tmp.dir, 4, 1 << 30);
    try std.testing.expectEqual(@as(usize, 4), (try list(arena.allocator(), io, tmp.dir)).len);
    try prune(std.testing.allocator, io, tmp.dir, 50, infos[0].size * 2);
    const left = try list(arena.allocator(), io, tmp.dir);
    try std.testing.expectEqual(@as(usize, 2), left.len);
    try std.testing.expectEqual(@as(i64, 1761016625000), left[0].created_unix_ms);
}
