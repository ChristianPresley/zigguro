//! A read-only view of a whole file: memory-mapped when possible, otherwise
//! read into an owned buffer with `readPositionalAll`.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Errors opening a mapped file.
pub const Error = std.Io.File.OpenError || std.Io.File.StatError || std.Io.File.ReadPositionalError ||
    Allocator.Error || error{ FileTooBig, ShortRead };

/// A whole file's bytes.
pub const MappedFile = struct {
    /// File contents.
    bytes: []const u8,
    /// Last modification time.
    mtime: std.Io.Timestamp,
    map: ?std.Io.File.MemoryMap = null,
    owned: ?[]u8 = null,

    /// Opens and maps `sub_path` relative to `dir`.
    pub fn open(gpa: Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8) Error!MappedFile {
        const file = try dir.openFile(io, sub_path, .{});
        defer file.close(io);
        const st = try file.stat(io);
        if (st.size > std.math.maxInt(usize)) return error.FileTooBig;
        const len: usize = @intCast(st.size);
        if (len > 0) {
            if (std.Io.File.MemoryMap.create(io, file, .{
                .len = len,
                .protection = .{ .read = true },
                .populate = false,
            })) |mm| {
                return .{ .bytes = mm.memory[0..len], .mtime = st.mtime, .map = mm };
            } else |_| {}
        }
        const buf = try gpa.alloc(u8, len);
        errdefer gpa.free(buf);
        const n = try file.readPositionalAll(io, buf, 0);
        if (n != len) return error.ShortRead;
        return .{ .bytes = buf, .mtime = st.mtime, .owned = buf };
    }

    /// Wraps bytes the caller keeps alive (tests, in-memory packs).
    pub fn borrowed(bytes: []const u8) MappedFile {
        return .{ .bytes = bytes, .mtime = .zero };
    }

    /// Unmaps or frees.
    pub fn close(m: *MappedFile, gpa: Allocator, io: std.Io) void {
        if (m.map) |*mm| mm.destroy(io);
        if (m.owned) |b| gpa.free(b);
        m.* = undefined;
    }
};

test "mapped: open and close" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "f", .data = "hello" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "empty", .data = "" });
    var m = try MappedFile.open(t.allocator, t.io, tmp.dir, "f");
    defer m.close(t.allocator, t.io);
    try t.expectEqualStrings("hello", m.bytes);
    var e = try MappedFile.open(t.allocator, t.io, tmp.dir, "empty");
    defer e.close(t.allocator, t.io);
    try t.expectEqual(@as(usize, 0), e.bytes.len);
}
