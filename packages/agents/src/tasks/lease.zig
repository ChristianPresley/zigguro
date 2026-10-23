//! Claim lock files (E13.F03.S02.T01): `.zigguro/tasks/.claims/T-0042.lock`
//! says which run holds a task and until when. Exactly one claimer wins,
//! across threads and processes:
//!
//! - A new lock is written whole to a private temporary file and then
//!   renamed into place without replacing (`renamePreserve`), so the lock
//!   never exists half-written. Where the file system has no such rename,
//!   the lock is created with `exclusive` (O_EXCL / CREATE_NEW) instead
//!   and readers treat an unreadable lock as held until it is older than
//!   the grace period.
//! - A lock whose lease ended more than `grace_s` ago is stale. A claimer
//!   steals it by renaming it to a private tombstone (only one rename of
//!   the same file can succeed), checking that the tombstone holds what it
//!   read (else it puts it back and reports the holder), and claiming
//!   afresh.
//! - Renewal rewrites the lock atomically; only the holder renews or
//!   releases.

const std = @import("std");
const runs = @import("../runs/root.zig");

const Io = std.Io;
const RunId = runs.RunId;

pub const dir_name = ".claims";
pub const default_grace_s: i64 = 30;
const max_bytes = 512;

pub const Info = struct {
    run: RunId,
    /// Unix seconds when the lease ends.
    until_s: i64,
    pid: u32 = 0,
    /// The machine or app instance (at most 64 bytes).
    host: []const u8 = "",

    pub fn write(i: Info, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "run={f}\nuntil={d}\npid={d}\nhost={s}\n", .{ i.run, i.until_s, i.pid, i.host[0..@min(i.host.len, 64)] });
    }

    /// Strings point into `bytes`.
    pub fn parse(bytes: []const u8) ?Info {
        var run: ?RunId = null;
        var until: ?i64 = null;
        var info: Info = .{ .run = .zero, .until_s = 0 };
        var it = std.mem.splitScalar(u8, bytes, '\n');
        while (it.next()) |line| {
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const k = line[0..eq];
            const v = line[eq + 1 ..];
            if (std.mem.eql(u8, k, "run")) run = RunId.parse(v) catch return null;
            if (std.mem.eql(u8, k, "until")) until = std.fmt.parseInt(i64, v, 10) catch return null;
            if (std.mem.eql(u8, k, "pid")) info.pid = std.fmt.parseInt(u32, v, 10) catch 0;
            if (std.mem.eql(u8, k, "host")) info.host = v;
        }
        info.run = run orelse return null;
        info.until_s = until orelse return null;
        return info;
    }
};

pub const Acquire = union(enum) {
    ok,
    /// Held by another run (`run` is zero when the lock is unreadable).
    taken: Info,
};

/// The lock file name of a task id.
pub fn lockName(buf: []u8, task: u32) []const u8 {
    return std.fmt.bufPrint(buf, "T-{d:0>4}.lock", .{task}) catch unreachable;
}

var tmp_counter: std.atomic.Value(u64) = .init(0);

pub const Locks = struct {
    io: Io,
    /// The `.claims` directory.
    dir: Io.Dir,
    grace_s: i64 = default_grace_s,

    /// Takes the lock `name` for `info.run` unless a live lease holds it.
    pub fn acquire(l: Locks, name: []const u8, info: Info, now_s: i64) !Acquire {
        var body_buf: [max_bytes]u8 = undefined;
        const body = try info.write(&body_buf);
        var attempts: u32 = 0;
        while (attempts < 4) : (attempts += 1) {
            if (try l.create(name, body, info.run)) return .ok;
            var cur_buf: [max_bytes]u8 = undefined;
            const cur = l.dir.readFile(l.io, name, &cur_buf) catch |e| switch (e) {
                error.FileNotFound => continue, // released meanwhile
                else => return e,
            };
            const parsed = Info.parse(cur);
            const stale = if (parsed) |p| p.until_s < now_s - l.grace_s else l.olderThanGrace(name, now_s);
            if (!stale) return .{ .taken = parsed orelse .{ .run = .zero, .until_s = now_s } };
            if (try l.steal(name, cur, info.run)) |holder| return .{ .taken = holder };
        }
        return .{ .taken = .{ .run = .zero, .until_s = now_s } };
    }

    /// Creates the lock with its content, or returns false when it exists.
    fn create(l: Locks, name: []const u8, body: []const u8, run: RunId) !bool {
        var tmp_buf: [128]u8 = undefined;
        const tmp = try std.fmt.bufPrint(&tmp_buf, ".{s}.{f}.{d}.tmp", .{ name, run, tmp_counter.fetchAdd(1, .monotonic) });
        {
            const f = try l.dir.createFile(l.io, tmp, .{});
            defer f.close(l.io);
            try f.writeStreamingAll(l.io, body);
        }
        l.dir.renamePreserve(tmp, l.dir, name, l.io) catch |e| {
            l.dir.deleteFile(l.io, tmp) catch {};
            switch (e) {
                error.PathAlreadyExists => return false,
                error.OperationUnsupported => return l.createExclusive(name, body),
                else => return e,
            }
        };
        return true;
    }

    fn createExclusive(l: Locks, name: []const u8, body: []const u8) !bool {
        const f = l.dir.createFile(l.io, name, .{ .exclusive = true }) catch |e| switch (e) {
            error.PathAlreadyExists => return false,
            else => return e,
        };
        defer f.close(l.io);
        try f.writeStreamingAll(l.io, body);
        return true;
    }

    fn olderThanGrace(l: Locks, name: []const u8, now_s: i64) bool {
        const st = l.dir.statFile(l.io, name, .{}) catch return false;
        const mtime_s: i64 = @intCast(@divFloor(st.mtime.nanoseconds, std.time.ns_per_s));
        return mtime_s < now_s - l.grace_s;
    }

    /// Moves a stale lock out of the way. Null when it is gone (claim
    /// again); the holder when the lock changed since it was read.
    fn steal(l: Locks, name: []const u8, seen: []const u8, run: RunId) !?Info {
        var tomb_buf: [128]u8 = undefined;
        const tomb = try std.fmt.bufPrint(&tomb_buf, ".{s}.{f}.{d}.stale", .{ name, run, tmp_counter.fetchAdd(1, .monotonic) });
        l.dir.rename(name, l.dir, tomb, l.io) catch |e| switch (e) {
            error.FileNotFound => return null,
            else => return e,
        };
        var got_buf: [max_bytes]u8 = undefined;
        const got = l.dir.readFile(l.io, tomb, &got_buf) catch "";
        if (!std.mem.eql(u8, got, seen)) {
            // A fresh claim replaced the stale one before our rename: put
            // it back (unless yet another claim took the name meanwhile).
            l.dir.renamePreserve(tomb, l.dir, name, l.io) catch {
                l.dir.deleteFile(l.io, tomb) catch {};
            };
            return Info.parse(got) orelse .{ .run = .zero, .until_s = 0 };
        }
        l.dir.deleteFile(l.io, tomb) catch {};
        return null;
    }

    /// The lock's holder, or null when there is no lock.
    pub fn read(l: Locks, name: []const u8, buf: *[max_bytes]u8) !?Info {
        const b = l.dir.readFile(l.io, name, buf) catch |e| switch (e) {
            error.FileNotFound => return null,
            else => return e,
        };
        return Info.parse(b) orelse .{ .run = .zero, .until_s = 0 };
    }

    /// Extends `run`'s lease; false when `run` does not hold the lock.
    pub fn renew(l: Locks, name: []const u8, info: Info) !bool {
        var buf: [max_bytes]u8 = undefined;
        const cur = try l.read(name, &buf) orelse return false;
        if (!cur.run.eql(info.run)) return false;
        var body_buf: [max_bytes]u8 = undefined;
        const body = try info.write(&body_buf);
        var af = try l.dir.createFileAtomic(l.io, name, .{ .replace = true });
        defer af.deinit(l.io);
        try af.file.writeStreamingAll(l.io, body);
        try af.replace(l.io);
        return true;
    }

    /// Removes `run`'s lock; false when `run` does not hold it.
    pub fn release(l: Locks, name: []const u8, run: RunId) !bool {
        var buf: [max_bytes]u8 = undefined;
        const cur = try l.read(name, &buf) orelse return false;
        if (!cur.run.eql(run)) return false;
        l.dir.deleteFile(l.io, name) catch |e| switch (e) {
            error.FileNotFound => return false,
            else => return e,
        };
        return true;
    }
};

/// The task id of a lock file name.
pub fn taskOf(name: []const u8) ?u32 {
    if (!std.mem.startsWith(u8, name, "T-") or !std.mem.endsWith(u8, name, ".lock")) return null;
    return std.fmt.parseInt(u32, name[2 .. name.len - 5], 10) catch null;
}

test "info round trip" {
    const t = std.testing;
    const id: RunId = .fromInt(0x0123456789abcdef0123456789abcdef);
    var buf: [256]u8 = undefined;
    const s = try (Info{ .run = id, .until_s = 1_800_000_000, .pid = 42, .host = "virindi" }).write(&buf);
    const p = Info.parse(s).?;
    try t.expect(p.run.eql(id));
    try t.expectEqual(@as(i64, 1_800_000_000), p.until_s);
    try t.expectEqual(@as(u32, 42), p.pid);
    try t.expectEqualStrings("virindi", p.host);
    try t.expect(Info.parse("") == null);
    try t.expectEqual(@as(?u32, 42), taskOf("T-0042.lock"));
    try t.expect(taskOf(".T-0042.lock.x.tmp") == null);
}
