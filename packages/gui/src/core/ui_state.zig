//! Small UI state that outlives a run (E04.F07.S03.T01): MRU lists,
//! collapsed sections, last choices. Keys are dotted names owned by the
//! widget or panel that sets them (`"explorer.collapsed"`); values are
//! short strings. Saved with the layout (`dock/persist.zig`).

const std = @import("std");

const Allocator = std.mem.Allocator;

/// One entry.
pub const KV = struct { key: []const u8, value: []const u8 };

/// Values above this are not kept.
pub const max_value_bytes = 16 << 10;

/// The entries, by key.
pub const UiState = struct {
    gpa: Allocator,
    map: std.StringArrayHashMapUnmanaged([]u8) = .empty,

    pub fn init(gpa: Allocator) UiState {
        return .{ .gpa = gpa };
    }

    pub fn deinit(s: *UiState) void {
        for (s.map.keys(), s.map.values()) |k, v| {
            s.gpa.free(k);
            s.gpa.free(v);
        }
        s.map.deinit(s.gpa);
    }

    /// The value of `key`, if set.
    pub fn get(s: *const UiState, key: []const u8) ?[]const u8 {
        return s.map.get(key);
    }

    /// Sets `key` (values above `max_value_bytes` are refused).
    pub fn put(s: *UiState, key: []const u8, value: []const u8) Allocator.Error!void {
        if (value.len > max_value_bytes) return;
        const v = try s.gpa.dupe(u8, value);
        errdefer s.gpa.free(v);
        const gop = try s.map.getOrPut(s.gpa, key);
        if (gop.found_existing) {
            s.gpa.free(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = s.gpa.dupe(u8, key) catch |e| {
                _ = s.map.swapRemove(key);
                return e;
            };
        }
        gop.value_ptr.* = v;
    }

    /// Drops `key`.
    pub fn remove(s: *UiState, key: []const u8) void {
        const kv = s.map.fetchOrderedRemove(key) orelse return;
        s.gpa.free(kv.key);
        s.gpa.free(kv.value);
    }

    /// The entries, in `arena` (for saving).
    pub fn entries(s: *const UiState, arena: Allocator) Allocator.Error![]KV {
        const out = try arena.alloc(KV, s.map.count());
        for (s.map.keys(), s.map.values(), out) |k, v, *o| o.* = .{ .key = try arena.dupe(u8, k), .value = try arena.dupe(u8, v) };
        return out;
    }

    /// Replaces the entries with `kvs` (after loading).
    pub fn setAll(s: *UiState, kvs: []const KV) Allocator.Error!void {
        for (s.map.keys(), s.map.values()) |k, v| {
            s.gpa.free(k);
            s.gpa.free(v);
        }
        s.map.clearRetainingCapacity();
        for (kvs) |kv| try s.put(kv.key, kv.value);
    }
};

test "ui state: put, replace, remove, round-trip" {
    const gpa = std.testing.allocator;
    var s: UiState = .init(gpa);
    defer s.deinit();
    try s.put("explorer.collapsed", "src,docs");
    try s.put("quickopen.mru", "a.zig");
    try s.put("quickopen.mru", "b.zig\na.zig");
    try std.testing.expectEqualStrings("b.zig\na.zig", s.get("quickopen.mru").?);
    s.remove("explorer.collapsed");
    try std.testing.expect(s.get("explorer.collapsed") == null);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const kvs = try s.entries(arena.allocator());
    var t: UiState = .init(gpa);
    defer t.deinit();
    try t.setAll(kvs);
    try std.testing.expectEqualStrings("b.zig\na.zig", t.get("quickopen.mru").?);
    try s.put("big", &([_]u8{'x'} ** (max_value_bytes + 1)));
    try std.testing.expect(s.get("big") == null);
}
