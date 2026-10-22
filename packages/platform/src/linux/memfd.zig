//! Shared memory for `wl_shm` (E01.F04.S04.T02): a sealed memfd mapped
//! read-write. The file is sealed against shrinking, so a compositor that
//! maps it can never fault on a truncated page; it may still grow, and
//! `grow` remaps it. Used by the Wayland presenter's buffer pools and the
//! cursor surfaces.

const std = @import("std");
const linux = std.os.linux;

const page = std.heap.page_size_min;

/// Bytes per row of a 32-bit-per-pixel image `w` pixels wide, rounded up
/// to 64 bytes (a cache line, and what GPU copies like).
pub fn stride32(w: u32) u32 {
    return std.mem.alignForward(u32, w * 4, 64);
}

/// A mapped memfd.
pub const Memfd = struct {
    /// The file (close-on-exec).
    fd: i32,
    /// The mapping, the whole file.
    mem: []align(page) u8,

    /// A new memfd of `size` bytes (at least 1), sealed against
    /// shrinking and mapped.
    pub fn create(name: [:0]const u8, size: usize) !Memfd {
        const rc = linux.memfd_create(name, linux.MFD.CLOEXEC | linux.MFD.ALLOW_SEALING);
        if (linux.errno(rc) != .SUCCESS) return error.SystemResources;
        const fd: i32 = @intCast(rc);
        errdefer _ = linux.close(fd);
        const n = @max(size, 1);
        if (linux.errno(linux.ftruncate(fd, @intCast(n))) != .SUCCESS) return error.SystemResources;
        if (linux.errno(linux.fcntl(fd, linux.F.ADD_SEALS, linux.F.SEAL_SHRINK)) != .SUCCESS) return error.SystemResources;
        const mem = try std.posix.mmap(null, n, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
        return .{ .fd = fd, .mem = mem };
    }

    /// A memfd holding a copy of `bytes`.
    pub fn fromBytes(name: [:0]const u8, bytes: []const u8) !Memfd {
        const m = try create(name, bytes.len);
        @memcpy(m.mem[0..bytes.len], bytes);
        return m;
    }

    /// Grows the file to `size` bytes and remaps it; earlier slices of
    /// `mem` are invalid afterwards. Never shrinks.
    pub fn grow(m: *Memfd, size: usize) !void {
        if (size <= m.mem.len) return;
        if (linux.errno(linux.ftruncate(m.fd, @intCast(size))) != .SUCCESS) return error.SystemResources;
        const mem = try std.posix.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, m.fd, 0);
        std.posix.munmap(m.mem);
        m.mem = mem;
    }

    /// Unmaps and closes.
    pub fn deinit(m: *Memfd) void {
        std.posix.munmap(m.mem);
        _ = linux.close(m.fd);
        m.* = undefined;
    }
};

const testing = std.testing;

test "stride32 rounds rows up to 64 bytes" {
    try testing.expectEqual(64, stride32(1));
    try testing.expectEqual(64, stride32(16));
    try testing.expectEqual(128, stride32(17));
    try testing.expectEqual(15360, stride32(3840));
}

test "memfd: mapped, shared with the file, sealed against shrinking, grows" {
    var m = try Memfd.fromBytes("zg-test", "hello");
    defer m.deinit();
    m.mem[0] = 'j';
    var buf: [5]u8 = undefined;
    try testing.expectEqual(5, linux.pread(m.fd, &buf, 5, 0));
    try testing.expectEqualStrings("jello", &buf);
    const seals = linux.fcntl(m.fd, linux.F.GET_SEALS, 0);
    try testing.expect(seals & linux.F.SEAL_SHRINK != 0);
    try testing.expectEqual(linux.E.PERM, linux.errno(linux.ftruncate(m.fd, 1)));

    try m.grow(3 * page);
    try testing.expectEqual(3 * page, m.mem.len);
    try testing.expectEqualStrings("jello", m.mem[0..5]);
    m.mem[3 * page - 1] = 7;
    try testing.expectEqual(1, linux.pread(m.fd, &buf, 1, 3 * page - 1));
    try testing.expectEqual(7, buf[0]);
    // Smaller sizes leave it as it is.
    try m.grow(10);
    try testing.expectEqual(3 * page, m.mem.len);
}
