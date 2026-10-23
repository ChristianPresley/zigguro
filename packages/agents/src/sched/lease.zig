//! The single-runner lease (E13.F02.S01.T02): `.zigguro/state/
//! scheduler.lock`, held with an exclusive OS file lock for the life of
//! the scheduler. The GUI and `zg agents host` both run a scheduler; the
//! one holding the lease fires, the other retries every 30 s and takes
//! over when the holder exits. The OS releases the lock if the holder
//! crashes.

const std = @import("std");

const Io = std.Io;

pub const file_name = "scheduler.lock";
/// How often a scheduler without the lease tries again.
pub const retry_ms = 30_000;

pub const Lease = struct {
    file: Io.File,

    /// The lease, or null when another scheduler holds it.
    pub fn tryAcquire(io: Io, dir: Io.Dir) !?Lease {
        const f = try dir.createFile(io, file_name, .{ .truncate = false });
        errdefer f.close(io);
        if (!try f.tryLock(io, .exclusive)) {
            f.close(io);
            return null;
        }
        return .{ .file = f };
    }

    pub fn release(l: Lease, io: Io) void {
        l.file.unlock(io);
        l.file.close(io);
    }
};

test "lease is exclusive until released" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const a = (try Lease.tryAcquire(io, tmp.dir)).?;
    try std.testing.expect(try Lease.tryAcquire(io, tmp.dir) == null);
    a.release(io);
    const b = (try Lease.tryAcquire(io, tmp.dir)).?;
    b.release(io);
}
