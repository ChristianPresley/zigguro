//! zwp_linux_dmabuf_v1 support for the Wayland presenter (E01.F04.S04.T01):
//! the feedback state machine (format table, tranches, main device), the
//! v3 modifier list, dev_t decoding, implicit-sync sync_file import and
//! presentation-time clock conversion. No protocol objects live here; the
//! backend feeds decoded events in and reads the results out.

const std = @import("std");
const linux = std.os.linux;
const surface = @import("../api/surface.zig");

const Allocator = std.mem.Allocator;
const DrmDevice = surface.DrmDevice;
const FormatModifier = surface.FormatModifier;

/// `DRM_FORMAT_MOD_INVALID`: the v3 `modifier` event's "implicit" value.
pub const mod_invalid: u64 = 0x00ff_ffff_ffff_ffff;

/// One format table entry as the compositor writes it: 16 bytes.
pub const TableEntry = extern struct {
    /// DRM fourcc.
    format: u32,
    /// Padding.
    pad: u32,
    /// DRM format modifier.
    modifier: u64,
};

comptime {
    std.debug.assert(@sizeOf(TableEntry) == 16);
}

/// `major(dev)` and `minor(dev)` of a Linux `dev_t`, the encoding glibc
/// and the kernel's `new_encode_dev` share.
pub fn decodeDev(dev: u64) DrmDevice {
    return .{
        .major = @truncate(((dev >> 8) & 0xfff) | ((dev >> 32) & 0xffff_f000)),
        .minor = @truncate((dev & 0xff) | ((dev >> 12) & 0xffff_ff00)),
    };
}

/// The device in a feedback `dev_t` array, or null if it is malformed.
pub fn devFromArray(bytes: []const u8) ?DrmDevice {
    if (bytes.len != @sizeOf(u64)) return null;
    return decodeDev(std.mem.readInt(u64, bytes[0..8], @import("builtin").cpu.arch.endian()));
}

/// dmabuf feedback, accumulated between `done` events. Guarded by the
/// backend mutex.
pub const Feedback = struct {
    /// The latest format table.
    table: []TableEntry = &.{},
    /// Formats of the last complete feedback, preferred tranche first.
    formats: std.ArrayList(FormatModifier) = .empty,
    /// The device of the first tranche (or `main_device`) of the last
    /// complete feedback.
    device: ?DrmDevice = null,
    /// Formats of the feedback being received.
    pending: std.ArrayList(FormatModifier) = .empty,
    pending_main: ?DrmDevice = null,
    pending_first: ?DrmDevice = null,
    tranche_device: ?DrmDevice = null,
    tranches: u32 = 0,
    /// Completed feedback rounds, for tests and logging.
    rounds: u32 = 0,

    /// Frees everything.
    pub fn deinit(f: *Feedback, gpa: Allocator) void {
        gpa.free(f.table);
        f.formats.deinit(gpa);
        f.pending.deinit(gpa);
        f.* = .{};
    }

    /// `format_table`: maps `fd` read-only, copies the entries and closes
    /// `fd`.
    pub fn onFormatTable(f: *Feedback, gpa: Allocator, fd: i32, size: u32) !void {
        defer _ = linux.close(fd);
        const n = size / @sizeOf(TableEntry);
        const table = try gpa.alloc(TableEntry, n);
        errdefer gpa.free(table);
        if (n > 0) {
            const mem = try std.posix.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
            defer std.posix.munmap(mem);
            @memcpy(std.mem.sliceAsBytes(table), mem[0 .. n * @sizeOf(TableEntry)]);
        }
        gpa.free(f.table);
        f.table = table;
    }

    /// `main_device` (deprecated since v6, still honoured).
    pub fn onMainDevice(f: *Feedback, bytes: []const u8) void {
        f.pending_main = devFromArray(bytes);
    }

    /// `tranche_target_device`.
    pub fn onTrancheDevice(f: *Feedback, bytes: []const u8) void {
        f.tranche_device = devFromArray(bytes);
    }

    /// `tranche_formats`: native-endian u16 indices into the table.
    /// Duplicates of earlier tranches are dropped, so the first (most
    /// preferred) tranche keeps a pair.
    pub fn onTrancheFormats(f: *Feedback, gpa: Allocator, bytes: []const u8) !void {
        var i: usize = 0;
        while (i + 2 <= bytes.len) : (i += 2) {
            const idx = std.mem.readInt(u16, bytes[i..][0..2], @import("builtin").cpu.arch.endian());
            if (idx >= f.table.len) continue;
            const e = f.table[idx];
            const fm: FormatModifier = .{ .fourcc = e.format, .modifier = e.modifier };
            if (contains(f.pending.items, fm)) continue;
            try f.pending.append(gpa, fm);
        }
    }

    /// `tranche_done`.
    pub fn onTrancheDone(f: *Feedback) void {
        if (f.tranches == 0) f.pending_first = f.tranche_device;
        f.tranches += 1;
        f.tranche_device = null;
    }

    /// `done`: the pending feedback becomes current. Returns whether the
    /// device or the format list changed.
    pub fn onDone(f: *Feedback) bool {
        const dev = f.pending_first orelse f.pending_main;
        const changed = !std.meta.eql(dev, f.device) or !sameList(f.pending.items, f.formats.items);
        std.mem.swap(std.ArrayList(FormatModifier), &f.formats, &f.pending);
        f.pending.clearRetainingCapacity();
        f.device = dev;
        f.pending_main = null;
        f.pending_first = null;
        f.tranches = 0;
        f.rounds += 1;
        return changed;
    }

    /// A v3 `modifier` event (no feedback object): appended as received.
    pub fn onModifier(f: *Feedback, gpa: Allocator, format: u32, hi: u32, lo: u32) !void {
        const fm: FormatModifier = .{ .fourcc = format, .modifier = @as(u64, hi) << 32 | lo };
        if (fm.modifier == mod_invalid or contains(f.formats.items, fm)) return;
        try f.formats.append(gpa, fm);
    }

    /// Copies the current formats into `out`; returns the total count.
    pub fn copyFormats(f: *const Feedback, out: []FormatModifier) usize {
        const n = @min(out.len, f.formats.items.len);
        @memcpy(out[0..n], f.formats.items[0..n]);
        return f.formats.items.len;
    }
};

fn sameList(a: []const FormatModifier, b: []const FormatModifier) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x.fourcc != y.fourcc or x.modifier != y.modifier) return false;
    return true;
}

fn contains(list: []const FormatModifier, fm: FormatModifier) bool {
    for (list) |x| if (x.fourcc == fm.fourcc and x.modifier == fm.modifier) return true;
    return false;
}

/// `DMA_BUF_IOCTL_IMPORT_SYNC_FILE`: `_IOW('b', 3, struct
/// dma_buf_import_sync_file)`.
const DMA_BUF_IOCTL_IMPORT_SYNC_FILE: u32 = 0x4008_6203;
/// `DMA_BUF_SYNC_WRITE`.
const DMA_BUF_SYNC_WRITE: u32 = 2;

const ImportSyncFile = extern struct { flags: u32, fd: i32 };

/// How a sync_file was attached.
pub const SyncResult = enum {
    /// Imported as the dmabuf's write fence: the compositor waits.
    imported,
    /// The kernel lacks the ioctl (or the fd is no dmabuf): we waited on
    /// the CPU before presenting.
    waited,
};

/// Attaches `sync_file` as the write fence of every distinct fd in
/// `dmabufs` (implicit sync). Without the ioctl it waits on the sync_file
/// on the calling thread instead. Does not close `sync_file`.
pub fn importSyncFile(dmabufs: []const i32, sync_file: i32) SyncResult {
    for (dmabufs, 0..) |fd, i| {
        if (std.mem.indexOfScalar(i32, dmabufs[0..i], fd) != null) continue;
        var arg: ImportSyncFile = .{ .flags = DMA_BUF_SYNC_WRITE, .fd = sync_file };
        const rc = linux.ioctl(fd, DMA_BUF_IOCTL_IMPORT_SYNC_FILE, @intFromPtr(&arg));
        if (linux.errno(rc) != .SUCCESS) {
            waitSyncFile(sync_file);
            return .waited;
        }
    }
    return .imported;
}

/// Blocks until `sync_file` signals (it polls readable).
pub fn waitSyncFile(sync_file: i32) void {
    var pfd = [1]linux.pollfd{.{ .fd = sync_file, .events = linux.POLL.IN, .revents = 0 }};
    while (true) {
        const rc = linux.poll(&pfd, 1, -1);
        if (linux.errno(rc) != .INTR) return;
    }
}

/// A presentation-time timestamp in our monotonic clock. `clk_id` is the
/// compositor's clock; `now_ours` and `now_theirs` are samples of both
/// clocks taken together, used when they differ.
pub fn presentedNs(sec_hi: u32, sec_lo: u32, nsec: u32, clk_id: u32, now_ours: u64, now_theirs: u64) u64 {
    const sec = @as(u64, sec_hi) << 32 | sec_lo;
    const t = sec *| std.time.ns_per_s +| nsec;
    if (clk_id == @intFromEnum(linux.CLOCK.MONOTONIC)) return t;
    // Shift by the offset between the clocks.
    return if (now_ours >= now_theirs) t +| (now_ours - now_theirs) else t -| (now_theirs - now_ours);
}

/// The current time of clock `clk_id` in ns, or 0 if it cannot be read.
pub fn clockNow(clk_id: u32) u64 {
    var ts: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(@enumFromInt(clk_id), &ts)) != .SUCCESS) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

// ---- tests ----

const testing = std.testing;

/// A memfd holding `entries` as a format table.
fn tableFd(entries: []const TableEntry) !i32 {
    const fd: i32 = @intCast(linux.memfd_create("zg-test-table", linux.MFD.CLOEXEC));
    const bytes = std.mem.sliceAsBytes(entries);
    _ = linux.ftruncate(fd, @intCast(bytes.len));
    _ = linux.pwrite(fd, bytes.ptr, bytes.len, 0);
    return fd;
}

fn devBytes(dev: u64) [8]u8 {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, dev, @import("builtin").cpu.arch.endian());
    return b;
}

fn indices(comptime xs: []const u16) [xs.len * 2]u8 {
    var b: [xs.len * 2]u8 = undefined;
    for (xs, 0..) |x, i| std.mem.writeInt(u16, b[i * 2 ..][0..2], x, @import("builtin").cpu.arch.endian());
    return b;
}

test "decodeDev splits major and minor" {
    // makedev(226, 128): /dev/dri/renderD128.
    try testing.expectEqual(DrmDevice{ .major = 226, .minor = 128 }, decodeDev((226 << 8) | 128));
    // Large numbers use the high bits.
    const dev: u64 = (@as(u64, 0x1234) & 0xfffff000) << 32 | (@as(u64, 0x1234) & 0xfff) << 8 | (@as(u64, 0x56789) & 0xffffff00) << 12 | (0x56789 & 0xff);
    try testing.expectEqual(DrmDevice{ .major = 0x1234, .minor = 0x56789 }, decodeDev(dev));
    try testing.expectEqual(@as(?DrmDevice, null), devFromArray(&.{ 1, 2, 3 }));
}

test "format_table parsing & tranche ordering" {
    const gpa = testing.allocator;
    var f: Feedback = .{};
    defer f.deinit(gpa);
    const ar24: u32 = 0x34325241;
    const xr24: u32 = 0x34325258;
    const table = [_]TableEntry{
        .{ .format = ar24, .pad = 0, .modifier = 0 },
        .{ .format = xr24, .pad = 0, .modifier = 0 },
        .{ .format = xr24, .pad = 0, .modifier = 0x0100_0000_0000_0001 },
    };
    try f.onFormatTable(gpa, try tableFd(&table), @sizeOf(@TypeOf(table)));
    try testing.expectEqual(@as(usize, 3), f.table.len);

    f.onMainDevice(&devBytes((226 << 8) | 0));
    // Scanout tranche first, on the render node's card.
    f.onTrancheDevice(&devBytes((226 << 8) | 1));
    try f.onTrancheFormats(gpa, &indices(&.{ 2, 9 }));
    f.onTrancheDone();
    f.onTrancheDevice(&devBytes((226 << 8) | 128));
    try f.onTrancheFormats(gpa, &indices(&.{ 1, 0, 2 }));
    f.onTrancheDone();
    try testing.expect(f.onDone());

    try testing.expectEqual(DrmDevice{ .major = 226, .minor = 1 }, f.device.?);
    var out: [8]FormatModifier = undefined;
    try testing.expectEqual(@as(usize, 3), f.copyFormats(&out));
    try testing.expectEqual(FormatModifier{ .fourcc = xr24, .modifier = 0x0100_0000_0000_0001 }, out[0]);
    try testing.expectEqual(FormatModifier{ .fourcc = xr24, .modifier = 0 }, out[1]);
    try testing.expectEqual(FormatModifier{ .fourcc = ar24, .modifier = 0 }, out[2]);

    // The same feedback again is no change; the table stays valid.
    f.onTrancheDevice(&devBytes((226 << 8) | 1));
    try f.onTrancheFormats(gpa, &indices(&.{2}));
    f.onTrancheDone();
    f.onTrancheDevice(&devBytes((226 << 8) | 128));
    try f.onTrancheFormats(gpa, &indices(&.{ 1, 0 }));
    f.onTrancheDone();
    try testing.expect(!f.onDone());
    try testing.expectEqual(@as(usize, 3), f.copyFormats(&out));
    // Dropping a format is a change.
    f.onTrancheDevice(&devBytes((226 << 8) | 1));
    try f.onTrancheFormats(gpa, &indices(&.{ 2, 1 }));
    f.onTrancheDone();
    try testing.expect(f.onDone());
    try testing.expectEqual(@as(usize, 2), f.copyFormats(&out));
}

test "v3 modifiers skip the invalid modifier" {
    const gpa = testing.allocator;
    var f: Feedback = .{};
    defer f.deinit(gpa);
    try f.onModifier(gpa, 0x34325258, 0, 0);
    try f.onModifier(gpa, 0x34325258, 0x00ffffff, 0xffffffff);
    try f.onModifier(gpa, 0x34325258, 0, 0);
    try testing.expectEqual(@as(usize, 1), f.formats.items.len);
}

test "presented timestamp conversion" {
    const mono = @intFromEnum(linux.CLOCK.MONOTONIC);
    try testing.expectEqual(@as(u64, 5 * std.time.ns_per_s + 7), presentedNs(0, 5, 7, mono, 0, 0));
    try testing.expectEqual(@as(u64, (1 << 32) * std.time.ns_per_s), presentedNs(1, 0, 0, mono, 0, 0));
    // Another clock 100 ns ahead of ours.
    const real = @intFromEnum(linux.CLOCK.REALTIME);
    try testing.expectEqual(@as(u64, 900), presentedNs(0, 0, 1000, real, 5000, 5100));
    try testing.expectEqual(@as(u64, 1100), presentedNs(0, 0, 1000, real, 5100, 5000));
}

test "importSyncFile falls back to a CPU wait without a dmabuf" {
    // A memfd is no dmabuf: the ioctl fails and the (signalled) eventfd is
    // waited on instead.
    const mfd: i32 = @intCast(linux.memfd_create("zg-test-buf", linux.MFD.CLOEXEC));
    defer _ = linux.close(mfd);
    const efd: i32 = @intCast(linux.eventfd(1, linux.EFD.CLOEXEC));
    defer _ = linux.close(efd);
    try testing.expectEqual(SyncResult.waited, importSyncFile(&.{ mfd, mfd }, efd));
}
