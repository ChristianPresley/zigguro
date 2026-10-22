//! git's lockfile protocol: create `<path>.lock` exclusively, write the new
//! contents into it, then rename it over `<path>` (commit) or delete it
//! (rollback). Contention retries with exponential backoff until a timeout.

const std = @import("std");

/// Errors acquiring a lock.
pub const AcquireError = error{LockTimeout} || std.Io.File.OpenError || std.Io.Dir.CreateDirPathError || std.Io.Cancelable;

/// A held lock on `path` inside `dir`.
pub const Lock = struct {
    dir: std.Io.Dir,
    file: ?std.Io.File,
    /// "<path>.lock".
    lock_path: []u8,
    /// Length of the locked path (lock_path without ".lock").
    path_len: usize,

    /// Locks `path`, creating parent directories. Gives up with
    /// `error.LockTimeout` after `timeout_ms` of contention.
    pub fn acquire(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, timeout_ms: u32) (AcquireError || std.mem.Allocator.Error)!Lock {
        const lock_path = try std.fmt.allocPrint(gpa, "{s}.lock", .{sub_path});
        errdefer gpa.free(lock_path);
        if (std.fs.path.dirname(sub_path)) |parent| try dir.createDirPath(io, parent);
        var waited: u64 = 0;
        var backoff: u64 = 1;
        while (true) {
            if (dir.createFile(io, lock_path, .{ .exclusive = true })) |f| {
                return .{ .dir = dir, .file = f, .lock_path = lock_path, .path_len = sub_path.len };
            } else |e| switch (e) {
                error.PathAlreadyExists => {
                    if (waited >= timeout_ms) return error.LockTimeout;
                    const step = @min(backoff, timeout_ms - waited);
                    try io.sleep(.fromMilliseconds(@intCast(step)), .awake);
                    waited += step;
                    backoff = @min(backoff * 2, 64);
                },
                else => |x| return x,
            }
        }
    }

    /// The locked path.
    pub fn path(l: *const Lock) []const u8 {
        return l.lock_path[0..l.path_len];
    }

    /// Writes all of `bytes` to the lock file and closes it.
    pub fn write(l: *Lock, io: std.Io, bytes: []const u8, fsync: bool) !void {
        const f = l.file.?;
        try f.writeStreamingAll(io, bytes);
        if (fsync) try f.sync(io);
        f.close(io);
        l.file = null;
    }

    /// Renames the lock over the path.
    pub fn commit(l: *Lock, io: std.Io) !void {
        if (l.file) |f| {
            f.close(io);
            l.file = null;
        }
        try l.dir.rename(l.lock_path, l.dir, l.path(), io);
    }

    /// Deletes the lock file if it is still there.
    pub fn rollback(l: *Lock, io: std.Io) void {
        if (l.file) |f| {
            f.close(io);
            l.file = null;
        }
        l.dir.deleteFile(io, l.lock_path) catch {};
    }

    /// Frees the path buffer (call after commit or rollback).
    pub fn deinit(l: *Lock, gpa: std.mem.Allocator) void {
        gpa.free(l.lock_path);
        l.* = undefined;
    }
};

test "refs: lock contention retry/timeout" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var a = try Lock.acquire(t.allocator, t.io, tmp.dir, "refs/heads/main", 100);
    defer a.deinit(t.allocator);
    try t.expectError(error.LockTimeout, Lock.acquire(t.allocator, t.io, tmp.dir, "refs/heads/main", 20));
    try a.write(t.io, "x\n", false);
    try a.commit(t.io);
    var b = try Lock.acquire(t.allocator, t.io, tmp.dir, "refs/heads/main", 20);
    defer b.deinit(t.allocator);
    b.rollback(t.io);
    var buf: [8]u8 = undefined;
    try t.expectEqualStrings("x\n", try tmp.dir.readFile(t.io, "refs/heads/main", &buf));
}
