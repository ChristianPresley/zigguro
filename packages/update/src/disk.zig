//! Free disk space for the download (E17.F04.S01.T02): an update needs
//! at least three times the archive size on the install volume (archive,
//! extracted copy, previous version).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// Bytes available to this user on the volume holding `path`, or null
/// when the OS cannot say.
pub fn freeBytes(arena: Allocator, path: []const u8) ?u64 {
    return switch (builtin.os.tag) {
        .linux => linuxFree(arena, path),
        .windows => windowsFree(arena, path),
        else => null,
    };
}

/// True when `free` leaves room for an update of `size` bytes.
pub fn enoughFor(free: ?u64, size: u64) bool {
    const f = free orelse return true;
    return f / 3 >= size;
}

/// The kernel's `struct statfs` on 64-bit Linux (x86_64 and the generic
/// layout aarch64 uses).
const StatFs = extern struct {
    type: i64,
    bsize: i64,
    blocks: u64,
    bfree: u64,
    bavail: u64,
    files: u64,
    ffree: u64,
    fsid: [2]i32,
    namelen: i64,
    frsize: i64,
    flags: i64,
    spare: [4]i64,
};

fn linuxFree(arena: Allocator, path: []const u8) ?u64 {
    if (@sizeOf(usize) != 8) return null;
    const linux = std.os.linux;
    const z = arena.dupeZ(u8, path) catch return null;
    var st: StatFs = undefined;
    const rc = linux.syscall2(.statfs, @intFromPtr(z.ptr), @intFromPtr(&st));
    if (linux.errno(rc) != .SUCCESS) return null;
    return st.bavail *| @as(u64, @intCast(@max(st.bsize, 0)));
}

extern "kernel32" fn GetDiskFreeSpaceExW(dir: [*:0]const u16, avail: ?*u64, total: ?*u64, free: ?*u64) callconv(.winapi) std.os.windows.BOOL;

fn windowsFree(arena: Allocator, path: []const u8) ?u64 {
    const w = std.unicode.wtf8ToWtf16LeAllocZ(arena, path) catch return null;
    var avail: u64 = 0;
    if (!GetDiskFreeSpaceExW(w.ptr, &avail, null, null).toBool()) return null;
    return avail;
}

test "disk: free space of the temp volume" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = buf[0..try tmp.dir.realPath(std.testing.io, &buf)];
    if (builtin.os.tag == .linux or builtin.os.tag == .windows) {
        const f = freeBytes(arena.allocator(), path) orelse return error.NoFreeSpace;
        try std.testing.expect(f > 0);
    }
    try std.testing.expect(enoughFor(300, 100));
    try std.testing.expect(!enoughFor(299, 100));
    try std.testing.expect(enoughFor(null, 1 << 40));
}
