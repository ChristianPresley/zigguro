//! StringInterner: deduplicates strings and hands out stable `u32` ids.
//! Lookups of already-interned strings never allocate.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Interns byte strings into one arena; ids are dense and stable.
pub const StringInterner = struct {
    /// A string id; dense from 0 in insertion order.
    pub const Id = enum(u32) { _ };

    bytes: std.ArrayList(u8) = .empty,
    /// Start offset of each string; string i is bytes[offsets[i]..offsets[i+1]] (or end).
    offsets: std.ArrayList(u32) = .empty,
    map: std.HashMapUnmanaged(Id, void, Ctx, 80) = .empty,

    /// An empty interner.
    pub const empty: StringInterner = .{};

    const Ctx = struct {
        interner: *const StringInterner,
        pub fn hash(c: Ctx, id: Id) u64 {
            return std.hash.Wyhash.hash(0, c.interner.get(id));
        }
        pub fn eql(c: Ctx, a: Id, b: Id) bool {
            _ = c;
            return a == b;
        }
    };

    const Adapter = struct {
        interner: *const StringInterner,
        pub fn hash(_: Adapter, s: []const u8) u64 {
            return std.hash.Wyhash.hash(0, s);
        }
        pub fn eql(a: Adapter, s: []const u8, id: Id) bool {
            return std.mem.eql(u8, s, a.interner.get(id));
        }
    };

    /// Returns the id for `s`, copying it in on first sight.
    pub fn intern(self: *StringInterner, gpa: Allocator, s: []const u8) Allocator.Error!Id {
        const gop = try self.map.getOrPutContextAdapted(gpa, s, Adapter{ .interner = self }, Ctx{ .interner = self });
        if (gop.found_existing) return gop.key_ptr.*;
        errdefer self.map.removeByPtr(gop.key_ptr);
        if (self.bytes.items.len + s.len > std.math.maxInt(u32)) return error.OutOfMemory;
        try self.offsets.ensureUnusedCapacity(gpa, 1);
        try self.bytes.appendSlice(gpa, s);
        const id: Id = @enumFromInt(self.offsets.items.len);
        self.offsets.appendAssumeCapacity(@intCast(self.bytes.items.len - s.len));
        gop.key_ptr.* = id;
        return id;
    }

    /// The string for `id`. Valid until the next `intern`.
    pub fn get(self: *const StringInterner, id: Id) []const u8 {
        const i = @intFromEnum(id);
        const start = self.offsets.items[i];
        const end = if (i + 1 < self.offsets.items.len) self.offsets.items[i + 1] else self.bytes.items.len;
        return self.bytes.items[start..end];
    }

    /// The id of `s` if already interned; never allocates.
    pub fn lookup(self: *const StringInterner, s: []const u8) ?Id {
        return self.map.getKeyAdapted(s, Adapter{ .interner = self });
    }

    /// Number of distinct strings.
    pub fn count(self: *const StringInterner) usize {
        return self.offsets.items.len;
    }

    /// Frees all memory.
    pub fn deinit(self: *StringInterner, gpa: Allocator) void {
        self.bytes.deinit(gpa);
        self.offsets.deinit(gpa);
        self.map.deinit(gpa);
        self.* = undefined;
    }
};

test "interner: same string same id; lookup without alloc" {
    const alloc = @import("../alloc.zig");
    var counting = alloc.CountingAllocator.init(std.testing.allocator);
    const gpa = counting.allocator();
    var in: StringInterner = .empty;
    defer in.deinit(gpa);
    const a = try in.intern(gpa, "alpha");
    const b = try in.intern(gpa, "beta");
    const e = try in.intern(gpa, "");
    try std.testing.expect(a != b);
    try std.testing.expectEqual(a, try in.intern(gpa, "alpha"));
    try std.testing.expectEqualStrings("beta", in.get(b));
    try std.testing.expectEqualStrings("", in.get(e));
    const before = counting.allocs.load(.monotonic);
    try std.testing.expectEqual(@as(?StringInterner.Id, a), in.lookup("alpha"));
    try std.testing.expect(in.lookup("gamma") == null);
    _ = try in.intern(gpa, "beta");
    try std.testing.expectEqual(before, counting.allocs.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 3), in.count());
}
