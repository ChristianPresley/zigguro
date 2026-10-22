//! The buffer table: the immutable byte buffers that pieces point into.
//!
//! - The `original` buffer holds the file as opened (owned, or borrowed
//!   from a memory map that outlives the table). It is never modified.
//! - Add pages hold inserted text. Pages are 1 MiB, allocated once and
//!   never moved or freed while the table lives, and bytes are only ever
//!   appended after the current tail, so every slice a snapshot holds stays
//!   valid. The page directory is two fixed levels, so readers on other
//!   threads never see a reallocated array.
//!
//! The table is shared by every version of a document and refcounted;
//! snapshots retain it.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Identifies a buffer: `original`, or add page `k` as `k + 1`.
pub const BufferId = enum(u32) {
    original = 0,
    _,

    /// The add page with index `k`.
    pub fn add(k: u32) BufferId {
        return @enumFromInt(k + 1);
    }
};

/// A slice of one buffer. 16 bytes.
pub const Piece = extern struct {
    /// Byte offset inside the buffer.
    start: u64,
    len: u32,
    buf: BufferId,
};

/// Size of one add page.
pub const page_size: usize = 1 << 20;
const dir_fanout = 256;
/// Maximum number of add pages (64 GiB of inserted text per document).
pub const max_pages = dir_fanout * dir_fanout;

const Page = [page_size]u8;

/// Buffers shared by all versions of a document.
pub const BufferTable = struct {
    rc: std.atomic.Value(u32) = .init(1),
    gpa: Allocator,
    original: []const u8,
    /// Whether `original` is freed with the table.
    owns_original: bool,
    dir: [dir_fanout]?*[dir_fanout]?*Page = @splat(null),
    page_count: u32 = 0,
    /// Bytes used in the last page.
    tail_len: usize = 0,

    /// A table over `original`; with `owned`, the table frees it with `gpa`.
    pub fn create(gpa: Allocator, original: []const u8, owned: bool) Allocator.Error!*BufferTable {
        const bt = try gpa.create(BufferTable);
        bt.* = .{ .gpa = gpa, .original = original, .owns_original = owned };
        return bt;
    }

    /// Adds a reference (any thread).
    pub fn retain(bt: *BufferTable) void {
        _ = bt.rc.fetchAdd(1, .monotonic);
    }

    /// Drops a reference; the last one frees every page (any thread: the
    /// table is only freed when no version can reach it).
    pub fn release(bt: *BufferTable) void {
        if (bt.rc.fetchSub(1, .release) != 1) return;
        _ = bt.rc.load(.acquire);
        const gpa = bt.gpa;
        for (bt.dir) |maybe| if (maybe) |level| {
            for (level) |p| if (p) |page| gpa.destroy(page);
            gpa.destroy(level);
        };
        if (bt.owns_original) gpa.free(bt.original);
        gpa.destroy(bt);
    }

    fn pagePtr(bt: *const BufferTable, k: u32) *Page {
        return bt.dir[k / dir_fanout].?[k % dir_fanout].?;
    }

    /// The bytes of `p`.
    pub inline fn bytes(bt: *const BufferTable, p: Piece) []const u8 {
        const start: usize = @intCast(p.start);
        if (p.buf == .original) return bt.original[start..][0..p.len];
        return bt.pagePtr(@intFromEnum(p.buf) - 1)[start..][0..p.len];
    }

    /// Appends as much of `text` (non-empty) as fits in the current page,
    /// allocating a page when full. Returns the piece for the appended part;
    /// callers loop until `piece.len == text.len`. Owner thread only.
    pub fn append(bt: *BufferTable, text: []const u8) error{ OutOfMemory, BufferFull }!Piece {
        std.debug.assert(text.len > 0);
        if (bt.page_count == 0 or bt.tail_len == page_size) try bt.addPage();
        const k = bt.page_count - 1;
        const room = page_size - bt.tail_len;
        const n = @min(room, text.len, std.math.maxInt(u32));
        const page = bt.pagePtr(k);
        @memcpy(page[bt.tail_len..][0..n], text[0..n]);
        const p: Piece = .{ .start = bt.tail_len, .len = @intCast(n), .buf = .add(k) };
        bt.tail_len += n;
        return p;
    }

    fn addPage(bt: *BufferTable) error{ OutOfMemory, BufferFull }!void {
        const k = bt.page_count;
        if (k >= max_pages) return error.BufferFull;
        const hi = k / dir_fanout;
        if (bt.dir[hi] == null) {
            const level = try bt.gpa.create([dir_fanout]?*Page);
            level.* = @splat(null);
            bt.dir[hi] = level;
        }
        const page = try bt.gpa.create(Page);
        bt.dir[hi].?[k % dir_fanout] = page;
        bt.page_count = k + 1;
        bt.tail_len = 0;
    }

    /// Makes sure the next `n` bytes (at most a page) land in one page,
    /// starting a fresh page when the current one lacks room.
    pub fn reserve(bt: *BufferTable, n: usize) error{ OutOfMemory, BufferFull }!void {
        std.debug.assert(n <= page_size);
        if (bt.tailRoom() < n) try bt.addPage();
    }

    /// Whether `p` ends at the current add tail, so text appended next
    /// extends it in place (the typing fast path).
    pub fn isTail(bt: *const BufferTable, p: Piece) bool {
        if (p.buf == .original or bt.page_count == 0) return false;
        return @intFromEnum(p.buf) == bt.page_count and p.start + p.len == bt.tail_len;
    }

    /// Room left in the current page.
    pub fn tailRoom(bt: *const BufferTable) usize {
        return if (bt.page_count == 0) 0 else page_size - bt.tail_len;
    }
};

test "buffers: append spans pages and slices stay valid" {
    const gpa = std.testing.allocator;
    const bt = try BufferTable.create(gpa, "orig", false);
    defer bt.release();
    const p1 = try bt.append("hello");
    try std.testing.expectEqualStrings("hello", bt.bytes(p1));
    try std.testing.expect(bt.isTail(p1));
    const big = try gpa.alloc(u8, page_size);
    defer gpa.free(big);
    @memset(big, 'x');
    const p2 = try bt.append(big);
    try std.testing.expectEqual(@as(u32, page_size - 5), p2.len);
    try std.testing.expect(!bt.isTail(p1));
    const p3 = try bt.append(big[p2.len..]);
    try std.testing.expectEqual(BufferId.add(1), p3.buf);
    try std.testing.expectEqualStrings("hello", bt.bytes(p1));
    try std.testing.expectEqualStrings("orig", bt.bytes(.{ .start = 0, .len = 4, .buf = .original }));
}
