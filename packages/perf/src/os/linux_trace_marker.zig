//! Linux ftrace bridge (E14.F02.S03.T01): zigguro zones, frames and
//! instants written as text records to `trace_marker`, so `perf record -e
//! ftrace:print` and `trace-cmd record -e ftrace:print` capture them next
//! to kernel events.
//!
//! Records, one `write` each (at most `max_record` bytes):
//! `zg:B|<tid>|<name>`, `zg:E|<tid>|<name>|<dur_ns>`, `zg:F|<seq>`,
//! `zg:I|<name>|<value>`.

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.perf_os_trace);

/// Longest record written.
pub const max_record = 256;

/// The marker files tried, in order.
pub const default_paths = [_][]const u8{ "/sys/kernel/tracing/trace_marker", "/sys/kernel/debug/tracing/trace_marker" };

/// Names longer than this are cut so a record always fits.
const max_name = 200;

fn cut(name: []const u8) []const u8 {
    return name[0..@min(name.len, max_name)];
}

/// `zg:B|<tid>|<name>`.
pub fn formatBegin(buf: *[max_record]u8, tid: u32, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "zg:B|{d}|{s}", .{ tid, cut(name) }) catch unreachable;
}

/// `zg:E|<tid>|<name>|<dur_ns>`.
pub fn formatEnd(buf: *[max_record]u8, tid: u32, name: []const u8, dur_ns: u64) []const u8 {
    return std.fmt.bufPrint(buf, "zg:E|{d}|{s}|{d}", .{ tid, cut(name), dur_ns }) catch unreachable;
}

/// `zg:F|<seq>`.
pub fn formatFrame(buf: *[max_record]u8, seq: u64) []const u8 {
    return std.fmt.bufPrint(buf, "zg:F|{d}", .{seq}) catch unreachable;
}

/// `zg:I|<name>|<value>`.
pub fn formatInstant(buf: *[max_record]u8, name: []const u8, value: i64) []const u8 {
    return std.fmt.bufPrint(buf, "zg:I|{s}|{d}", .{ cut(name), value }) catch unreachable;
}

/// An open `trace_marker`.
pub const TraceMarker = struct {
    fd: i32,

    /// Opens the first of `paths` that accepts writes. Null when none does: the file is root-only by default, missing without
    /// tracefs, or refused when the `markers` option is off.
    pub fn open(io: std.Io, paths: []const []const u8) ?TraceMarker {
        if (builtin.os.tag != .linux) return null;
        for (paths) |p| {
            const f = std.Io.Dir.openFileAbsolute(io, p, .{ .mode = .write_only }) catch |err| {
                log.info("ftrace: cannot open {s}: {t}", .{ p, err });
                continue;
            };
            return .{ .fd = f.handle };
        }
        return null;
    }

    /// Closes the file.
    pub fn close(m: TraceMarker) void {
        if (builtin.os.tag == .linux) _ = std.os.linux.close(m.fd);
    }

    /// Writes one record; never retries (EINTR/EAGAIN drop the record).
    pub fn write(m: TraceMarker, rec: []const u8) void {
        if (builtin.os.tag != .linux) return;
        _ = std.os.linux.write(m.fd, rec.ptr, rec.len);
    }
};

test "ftrace: format records ≤ 256 bytes" {
    var buf: [max_record]u8 = undefined;
    try std.testing.expectEqualStrings("zg:B|12|gui.frame", formatBegin(&buf, 12, "gui.frame"));
    try std.testing.expectEqualStrings("zg:E|12|gui.frame|4200", formatEnd(&buf, 12, "gui.frame", 4200));
    try std.testing.expectEqualStrings("zg:F|99", formatFrame(&buf, 99));
    try std.testing.expectEqualStrings("zg:I|perf.stall|-3", formatInstant(&buf, "perf.stall", -3));
    const long = "x" ** 1000;
    const rec = formatEnd(&buf, std.math.maxInt(u32), long, std.math.maxInt(u64));
    try std.testing.expect(rec.len <= max_record);
}

test "ftrace: open failure falls back to none" {
    try std.testing.expect(TraceMarker.open(std.testing.io, &.{"/nonexistent/zigguro/trace_marker"}) == null);
}

test "ftrace: write to a regular file" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "marker", .data = "" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPathFile(io, "marker", &buf);
    const m = TraceMarker.open(io, &.{buf[0..n]}).?;
    var rb: [max_record]u8 = undefined;
    m.write(formatFrame(&rb, 1));
    m.close();
    const got = try tmp.dir.readFileAlloc(io, "marker", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("zg:F|1", got);
}
