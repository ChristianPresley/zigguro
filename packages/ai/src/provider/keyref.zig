//! API key references and the secret-store seam. Settings never hold key
//! values, only references: `${secret:ai/anthropic/default}` (E16 secret
//! store) or `${env:ANTHROPIC_API_KEY}`. Anything else in a `key` setting
//! is treated as a raw key and flagged.

const std = @import("std");

/// Where a provider's key comes from.
pub const KeyRef = union(enum) {
    /// No key (local servers).
    none,
    secret: []const u8,
    env: []const u8,
    /// A key value pasted straight into settings (warned about, redacted).
    raw: []const u8,

    /// Parses a `key` setting value.
    pub fn parse(s: ?[]const u8) KeyRef {
        const v = std.mem.trim(u8, s orelse return .none, " \t");
        if (v.len == 0) return .none;
        if (std.mem.startsWith(u8, v, "${") and std.mem.endsWith(u8, v, "}")) {
            const inner = v[2 .. v.len - 1];
            if (std.mem.startsWith(u8, inner, "secret:")) return .{ .secret = inner["secret:".len..] };
            if (std.mem.startsWith(u8, inner, "env:")) return .{ .env = inner["env:".len..] };
        }
        return .{ .raw = v };
    }

    /// The settings form, e.g. `${secret:name}`. Raw keys never format.
    pub fn format(r: KeyRef, buf: []u8) ?[]const u8 {
        return switch (r) {
            .none, .raw => null,
            .secret => |n| std.fmt.bufPrint(buf, "${{secret:{s}}}", .{n}) catch null,
            .env => |n| std.fmt.bufPrint(buf, "${{env:{s}}}", .{n}) catch null,
        };
    }
};

pub const SecretError = error{ OutOfMemory, Unavailable };

/// The E16 secret store as the hub needs it. `get` returns a value owned
/// by the store, valid until the next `put` of the same name.
pub const SecretStore = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        get: *const fn (ctx: *anyopaque, io: std.Io, name: []const u8) SecretError!?[]const u8,
        put: *const fn (ctx: *anyopaque, io: std.Io, name: []const u8, value: []const u8) SecretError!void,
    };

    pub fn get(s: SecretStore, io: std.Io, name: []const u8) SecretError!?[]const u8 {
        return s.vtable.get(s.ctx, io, name);
    }

    pub fn put(s: SecretStore, io: std.Io, name: []const u8, value: []const u8) SecretError!void {
        return s.vtable.put(s.ctx, io, name, value);
    }
};

/// In-memory store for tests and the headless CLI without a keychain.
pub const MemorySecretStore = struct {
    gpa: std.mem.Allocator,
    map: std.StringHashMapUnmanaged([]u8) = .empty,
    mutex: std.Io.Mutex = .init,

    pub fn init(gpa: std.mem.Allocator) MemorySecretStore {
        return .{ .gpa = gpa };
    }

    pub fn deinit(m: *MemorySecretStore) void {
        var it = m.map.iterator();
        while (it.next()) |e| {
            m.gpa.free(e.key_ptr.*);
            std.crypto.secureZero(u8, e.value_ptr.*);
            m.gpa.free(e.value_ptr.*);
        }
        m.map.deinit(m.gpa);
    }

    pub fn store(m: *MemorySecretStore) SecretStore {
        return .{ .ctx = m, .vtable = &.{ .get = get, .put = put } };
    }

    fn get(ctx: *anyopaque, io: std.Io, name: []const u8) SecretError!?[]const u8 {
        const m: *MemorySecretStore = @ptrCast(@alignCast(ctx));
        m.mutex.lockUncancelable(io);
        defer m.mutex.unlock(io);
        return m.map.get(name);
    }

    fn put(ctx: *anyopaque, io: std.Io, name: []const u8, value: []const u8) SecretError!void {
        const m: *MemorySecretStore = @ptrCast(@alignCast(ctx));
        m.mutex.lockUncancelable(io);
        defer m.mutex.unlock(io);
        const v = try m.gpa.dupe(u8, value);
        errdefer m.gpa.free(v);
        const gop = try m.map.getOrPut(m.gpa, name);
        if (gop.found_existing) {
            std.crypto.secureZero(u8, gop.value_ptr.*);
            m.gpa.free(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = m.gpa.dupe(u8, name) catch |e| {
                m.map.removeByPtr(gop.key_ptr);
                return e;
            };
        }
        gop.value_ptr.* = v;
    }
};

const testing = std.testing;

test "parse and format" {
    try testing.expect(KeyRef.parse(null) == .none);
    try testing.expect(KeyRef.parse("  ") == .none);
    try testing.expectEqualStrings("ai/anthropic/default", KeyRef.parse("${secret:ai/anthropic/default}").secret);
    try testing.expectEqualStrings("MY_KEY", KeyRef.parse("${env:MY_KEY}").env);
    try testing.expectEqualStrings("sk-ant-123", KeyRef.parse("sk-ant-123").raw);
    try testing.expectEqualStrings("${oops}", KeyRef.parse("${oops}").raw);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("${secret:a/b}", (KeyRef{ .secret = "a/b" }).format(&buf).?);
    try testing.expect((KeyRef{ .raw = "sk" }).format(&buf) == null);
}

test "memory store" {
    var m = MemorySecretStore.init(testing.allocator);
    defer m.deinit();
    const s = m.store();
    try testing.expect(try s.get(testing.io, "x") == null);
    try s.put(testing.io, "x", "one");
    try s.put(testing.io, "x", "two");
    try testing.expectEqualStrings("two", (try s.get(testing.io, "x")).?);
}
