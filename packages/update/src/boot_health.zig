//! Boot health (E17.F04.S02.T02): whether a freshly updated version
//! starts, the automatic rollback when it does not, and the note the
//! rolled-back version shows once. Files live in `<state>/update/`:
//!
//! ```
//! boot.zon          the Record of the current version
//! boot-crashed      written by zg_crash when it crashes while pending
//! rolled-back.zon   RollbackInfo, read once after a rollback
//! ```
//!
//! `early` runs before GPU and window init, since a driver crash is the
//! likeliest failure after an update, so it only reads. The app sets the
//! `boot_pending` crash annotation when `markAttempt` returns true.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const swap = @import("swap.zig");
const state_mod = @import("state.zig");

/// Subdirectory of the state directory.
pub const dir_name = "update";
pub const record_name = "boot.zon";
/// Written by zg_crash with open/write/close only; holds the version.
pub const crash_marker_name = "boot-crashed";
pub const rollback_info_name = "rolled-back.zon";
/// Largest `boot.zon` read.
pub const max_record_bytes = 1024;
/// Time after the first frame at which a version counts as healthy.
pub const healthy_after_ms: i64 = 30 * std.time.ms_per_s;
/// Starts of a pending version after which it is rolled back.
pub const max_attempts = 2;

pub const Status = enum { pending, healthy, failed };

pub const Record = struct {
    version: []const u8,
    status: Status,
    attempts: u8,
    first_frame_seen: bool = false,
    since_unix: i64 = 0,
};

pub const EarlyDecision = enum { proceed, rollback_now };

/// The decision table: roll back only a pending current version that has
/// a previous version to go back to and has either failed to become
/// healthy `max_attempts` times or crashed while pending.
pub fn decide(rec: ?Record, marker: ?[]const u8, current: []const u8, has_prev: bool) EarlyDecision {
    const r = rec orelse return .proceed;
    if (r.status != .pending or !has_prev) return .proceed;
    if (!std.mem.eql(u8, r.version, current)) return .proceed;
    if (r.attempts >= max_attempts) return .rollback_now;
    if (marker) |m| if (std.mem.eql(u8, std.mem.trim(u8, m, " \r\n"), current)) return .rollback_now;
    return .proceed;
}

/// Reads `boot.zon` and the crash marker and decides. No writes, no heap.
pub fn early(io: Io, state_dir: Io.Dir, current: []const u8, has_prev: bool) EarlyDecision {
    if (!has_prev) return .proceed;
    var rbuf: [max_record_bytes + 1]u8 = undefined;
    var abuf: [2 * max_record_bytes]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&abuf);
    const rec = readRecordBuf(fba.allocator(), io, state_dir, &rbuf);
    var mbuf: [64]u8 = undefined;
    const marker = state_dir.readFile(io, dir_name ++ "/" ++ crash_marker_name, &mbuf) catch null;
    return decide(rec, marker, current, has_prev);
}

fn readRecordBuf(a: Allocator, io: Io, state_dir: Io.Dir, buf: []u8) ?Record {
    const text = state_dir.readFile(io, dir_name ++ "/" ++ record_name, buf[0 .. buf.len - 1]) catch return null;
    buf[text.len] = 0;
    return std.zon.parse.fromSliceAlloc(Record, a, buf[0..text.len :0], null, .{}) catch null;
}

/// The stored record, if any. Allocations go to `arena`.
pub fn readRecord(arena: Allocator, io: Io, state_dir: Io.Dir) ?Record {
    const buf = arena.alloc(u8, max_record_bytes + 1) catch return null;
    return readRecordBuf(arena, io, state_dir, buf);
}

/// The record after one more start of `version`: a new version (or
/// `updated_from`) starts pending at attempt 1; a pending one counts up.
pub fn nextRecord(prev: ?Record, version: []const u8, updated_from: bool, now_unix: i64) Record {
    if (prev) |p| if (!updated_from and std.mem.eql(u8, p.version, version)) {
        var r = p;
        if (r.status == .pending) {
            r.attempts +|= 1;
            r.first_frame_seen = false;
        }
        return r;
    };
    return .{ .version = version, .status = .pending, .attempts = 1, .since_unix = now_unix };
}

/// Records this start (on a worker, right after `early`). Returns true
/// while the version is pending, when the caller sets the `boot_pending`
/// crash annotation to "1".
pub fn markAttempt(io: Io, state_dir: Io.Dir, version: []const u8, updated_from: bool, now_unix: i64) !bool {
    var abuf: [4 * max_record_bytes]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&abuf);
    const r = nextRecord(readRecord(fba.allocator(), io, state_dir), version, updated_from, now_unix);
    try writeRecord(io, state_dir, r);
    return r.status == .pending;
}

/// Writes `boot.zon` through a temporary file.
pub fn writeRecord(io: Io, state_dir: Io.Dir, r: Record) !void {
    var buf: [max_record_bytes]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try std.zon.stringify.serialize(r, .{}, &w);
    try writeAtomic(io, state_dir, record_name, w.buffered());
}

fn writeAtomic(io: Io, state_dir: Io.Dir, comptime name: []const u8, data: []const u8) !void {
    try state_dir.createDirPath(io, dir_name);
    const path = dir_name ++ "/" ++ name;
    try state_dir.writeFile(io, .{ .sub_path = path ++ ".tmp", .data = data });
    try state_dir.rename(path ++ ".tmp", state_dir, path, io);
}

/// Health tracking for the running process: first frame, then healthy
/// 30 s later or at a clean quit. Times are monotonic milliseconds from
/// the caller, so tests drive a fake clock.
pub const BootHealth = struct {
    io: Io,
    state_dir: Io.Dir,
    version: []const u8,
    first_frame_ms: ?i64 = null,
    healthy: bool = false,

    /// E14's first_frame_presented hook.
    pub fn markFirstFrame(h: *BootHealth, now_ms: i64) void {
        if (h.first_frame_ms == null) h.first_frame_ms = now_ms;
    }

    /// Call periodically; marks healthy 30 s after the first frame.
    /// Returns true once healthy.
    pub fn poll(h: *BootHealth, now_ms: i64) bool {
        if (h.healthy) return true;
        const ff = h.first_frame_ms orelse return false;
        if (now_ms - ff < healthy_after_ms) return false;
        h.markHealthy();
        return h.healthy;
    }

    /// A clean quit counts only once a frame was shown.
    pub fn onCleanQuit(h: *BootHealth) void {
        if (h.first_frame_ms != null) h.markHealthy();
    }

    /// Writes `healthy` and deletes the crash marker.
    pub fn markHealthy(h: *BootHealth) void {
        if (h.healthy) return;
        writeRecord(h.io, h.state_dir, .{
            .version = h.version,
            .status = .healthy,
            .attempts = 0,
            .first_frame_seen = true,
        }) catch return;
        h.state_dir.deleteFile(h.io, dir_name ++ "/" ++ crash_marker_name) catch {};
        h.healthy = true;
    }
};

pub const RollbackInfo = struct {
    from_version: []const u8,
    to_version: []const u8,
    crash_report: ?[]const u8 = null,
};

/// Rolls `root` back to `app.prev` and records it: `from` goes into the
/// skip list of `update.zon` in `state_path`, `boot.zon` is marked
/// failed, the crash marker is removed and `rolled-back.zon` is written
/// for the toast. The caller then re-executes `app/` (Linux) or hands off
/// to the setup helper (Windows).
pub fn rollbackNow(arena: Allocator, io: Io, root: Io.Dir, state_path: []const u8, info: RollbackInfo) !void {
    try swap.rollback(io, root);
    var sd = try Io.Dir.cwd().openDir(io, state_path, .{});
    defer sd.close(io);
    writeRecord(io, sd, .{ .version = info.from_version, .status = .failed, .attempts = 0 }) catch {};
    sd.deleteFile(io, dir_name ++ "/" ++ crash_marker_name) catch {};
    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try std.zon.stringify.serialize(info, .{}, &w);
    try writeAtomic(io, sd, rollback_info_name, w.buffered());
    const updater = @import("updater.zig");
    const st = try updater.loadState(arena, io, state_path);
    try updater.saveState(io, state_path, try st.withSkipped(arena, info.from_version));
}

/// The rollback note, once: read and deleted.
pub fn takeRollbackInfo(arena: Allocator, io: Io, state_dir: Io.Dir) !?RollbackInfo {
    const path = dir_name ++ "/" ++ rollback_info_name;
    const text = state_dir.readFileAllocOptions(io, path, arena, .limited(4096), .of(u8), 0) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    state_dir.deleteFile(io, path) catch {};
    return std.zon.parse.fromSliceAlloc(RollbackInfo, arena, text, null, .{}) catch null;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "boot_health: early decision table" {
    const statuses = [_]Status{ .pending, .healthy, .failed };
    for (statuses) |st| for ([_]u8{ 0, 1, 2, 3 }) |att| for ([_]bool{ false, true }) |marked| for ([_]bool{ false, true }) |has_prev| for ([_]bool{ false, true }) |same| {
        const rec: Record = .{ .version = if (same) "0.5.0" else "0.4.0", .status = st, .attempts = att };
        const d = decide(rec, if (marked) "0.5.0\n" else null, "0.5.0", has_prev);
        const want = st == .pending and same and has_prev and (att >= max_attempts or marked);
        try testing.expectEqual(if (want) EarlyDecision.rollback_now else .proceed, d);
    };
    try testing.expectEqual(EarlyDecision.proceed, decide(null, "0.5.0", "0.5.0", true));
    // A marker for another version does not count.
    try testing.expectEqual(EarlyDecision.proceed, decide(.{ .version = "0.5.0", .status = .pending, .attempts = 1 }, "0.4.0", "0.5.0", true));
}

test "boot_health: two pending starts roll back, healthy never does" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.expectEqual(EarlyDecision.proceed, early(io, tmp.dir, "0.5.0", true));
    try testing.expect(try markAttempt(io, tmp.dir, "0.5.0", true, 10));
    try testing.expectEqual(EarlyDecision.proceed, early(io, tmp.dir, "0.5.0", true));
    try testing.expect(try markAttempt(io, tmp.dir, "0.5.0", false, 11));
    try testing.expectEqual(EarlyDecision.rollback_now, early(io, tmp.dir, "0.5.0", true));
    try testing.expectEqual(EarlyDecision.proceed, early(io, tmp.dir, "0.5.0", false));

    // Healthy is sticky across later starts.
    var h: BootHealth = .{ .io = io, .state_dir = tmp.dir, .version = "0.5.0" };
    h.markFirstFrame(0);
    h.onCleanQuit();
    try testing.expect(!try markAttempt(io, tmp.dir, "0.5.0", false, 12));
    try testing.expect(!try markAttempt(io, tmp.dir, "0.5.0", false, 13));
    try testing.expectEqual(EarlyDecision.proceed, early(io, tmp.dir, "0.5.0", true));
}

test "boot_health: crash marker rolls back on the next start" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    _ = try markAttempt(io, tmp.dir, "0.5.0", true, 10);
    try tmp.dir.writeFile(io, .{ .sub_path = "update/boot-crashed", .data = "0.5.0" });
    try testing.expectEqual(EarlyDecision.rollback_now, early(io, tmp.dir, "0.5.0", true));
}

test "boot_health: healthy after 30 s" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    _ = try markAttempt(io, tmp.dir, "0.5.0", true, 10);
    try tmp.dir.writeFile(io, .{ .sub_path = "update/boot-crashed", .data = "0.5.0" });
    var h: BootHealth = .{ .io = io, .state_dir = tmp.dir, .version = "0.5.0" };
    try testing.expect(!h.poll(100_000));
    h.markFirstFrame(1_000);
    try testing.expect(!h.poll(30_999));
    try testing.expect(h.poll(31_000));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(Status.healthy, readRecord(arena.allocator(), io, tmp.dir).?.status);
    var b: [8]u8 = undefined;
    try testing.expectError(error.FileNotFound, tmp.dir.readFile(io, "update/boot-crashed", &b));
}

test "boot_health: clean quit before first frame does not mark healthy" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    _ = try markAttempt(io, tmp.dir, "0.5.0", true, 10);
    var h: BootHealth = .{ .io = io, .state_dir = tmp.dir, .version = "0.5.0" };
    h.onCleanQuit();
    try testing.expect(!h.healthy);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(Status.pending, readRecord(arena.allocator(), io, tmp.dir).?.status);
}

test "boot_health: rollback skips the version, takeRollbackInfo returns once" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.createDirPath(io, "root/app");
    try tmp.dir.createDirPath(io, "root/app.prev");
    try tmp.dir.writeFile(io, .{ .sub_path = "root/app.prev/v", .data = "0.4.0" });
    try tmp.dir.createDirPath(io, "state");
    var root = try tmp.dir.openDir(io, "root", .{});
    defer root.close(io);
    const state_path = try tmp.dir.realPathFileAlloc(io, "state", a);
    var sd = try tmp.dir.openDir(io, "state", .{});
    defer sd.close(io);
    _ = try markAttempt(io, sd, "0.5.0", true, 10);

    try rollbackNow(a, io, root, state_path, .{ .from_version = "0.5.0", .to_version = "0.4.0", .crash_report = "x.zgcrash" });
    var b: [8]u8 = undefined;
    try testing.expectEqualStrings("0.4.0", try root.readFile(io, "app/v", &b));
    const st = try @import("updater.zig").loadState(a, io, state_path);
    try testing.expect(st.isSkipped("0.5.0"));
    const info = (try takeRollbackInfo(a, io, sd)).?;
    try testing.expectEqualStrings("0.5.0", info.from_version);
    try testing.expectEqualStrings("x.zgcrash", info.crash_report.?);
    try testing.expect(try takeRollbackInfo(a, io, sd) == null);
    // The version that comes back starts pending without a prev: no loop.
    _ = try markAttempt(io, sd, "0.4.0", false, 20);
    try testing.expectEqual(EarlyDecision.proceed, early(io, sd, "0.4.0", false));
}

test "boot_health: blocklist suppresses offer, installAnyway clears" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var st: state_mod.State = .{};
    st = try st.withSkipped(a, "0.5.0");
    st = try st.withSkipped(a, "0.5.0");
    try testing.expectEqual(1, st.skipped.len);
    try testing.expect(st.isSkipped("0.5.0"));
    st = try st.withoutSkipped(a, "0.5.0");
    try testing.expect(!st.isSkipped("0.5.0"));
}
