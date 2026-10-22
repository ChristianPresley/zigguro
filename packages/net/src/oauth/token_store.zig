//! Where OAuth tokens live. Tokens are keyed by (issuer, resource) and are
//! never reused with another authorization server. E16 implements
//! `TokenStore` on the OS secret store; `MemoryTokenStore` serves tests and
//! headless runs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const TokenSet = @import("flow.zig").TokenSet;

pub const TokenStore = struct {
    ctx: ?*anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// A copy of the stored set allocated with `gpa`, or null.
        load: *const fn (ctx: ?*anyopaque, gpa: Allocator, issuer: []const u8, resource: []const u8) anyerror!?TokenSet,
        /// Stores a copy of `t`, replacing any previous set.
        save: *const fn (ctx: ?*anyopaque, issuer: []const u8, resource: []const u8, t: TokenSet) anyerror!void,
        remove: *const fn (ctx: ?*anyopaque, issuer: []const u8, resource: []const u8) anyerror!void,
    };

    pub fn load(self: TokenStore, gpa: Allocator, issuer: []const u8, resource: []const u8) !?TokenSet {
        return self.vtable.load(self.ctx, gpa, issuer, resource);
    }

    pub fn save(self: TokenStore, issuer: []const u8, resource: []const u8, t: TokenSet) !void {
        return self.vtable.save(self.ctx, issuer, resource, t);
    }

    pub fn remove(self: TokenStore, issuer: []const u8, resource: []const u8) !void {
        return self.vtable.remove(self.ctx, issuer, resource);
    }
};

/// An in-memory, thread-safe store.
pub const MemoryTokenStore = struct {
    gpa: Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    map: std.StringHashMapUnmanaged(TokenSet) = .empty,

    pub fn init(gpa: Allocator, io: std.Io) MemoryTokenStore {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(self: *MemoryTokenStore) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            e.value_ptr.deinit(self.gpa);
            self.gpa.free(e.key_ptr.*);
        }
        self.map.deinit(self.gpa);
    }

    pub fn store(self: *MemoryTokenStore) TokenStore {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: TokenStore.VTable = .{ .load = load, .save = save, .remove = remove };

    fn key(buf: []u8, issuer: []const u8, resource: []const u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s}\x00{s}", .{ issuer, resource }) catch error.NameTooLong;
    }

    fn load(ctx: ?*anyopaque, gpa: Allocator, issuer: []const u8, resource: []const u8) anyerror!?TokenSet {
        const self: *MemoryTokenStore = @ptrCast(@alignCast(ctx.?));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var kb: [2048]u8 = undefined;
        const t = self.map.get(try key(&kb, issuer, resource)) orelse return null;
        return try t.clone(gpa);
    }

    fn save(ctx: ?*anyopaque, issuer: []const u8, resource: []const u8, t: TokenSet) anyerror!void {
        const self: *MemoryTokenStore = @ptrCast(@alignCast(ctx.?));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var kb: [2048]u8 = undefined;
        const k = try key(&kb, issuer, resource);
        const copy = try t.clone(self.gpa);
        errdefer copy.deinit(self.gpa);
        const gop = try self.map.getOrPut(self.gpa, k);
        if (gop.found_existing) {
            gop.value_ptr.deinit(self.gpa);
        } else {
            gop.key_ptr.* = self.gpa.dupe(u8, k) catch |err| {
                self.map.removeByPtr(gop.key_ptr);
                return err;
            };
        }
        gop.value_ptr.* = copy;
    }

    fn remove(ctx: ?*anyopaque, issuer: []const u8, resource: []const u8) anyerror!void {
        const self: *MemoryTokenStore = @ptrCast(@alignCast(ctx.?));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var kb: [2048]u8 = undefined;
        if (self.map.fetchRemove(try key(&kb, issuer, resource))) |kv| {
            kv.value.deinit(self.gpa);
            self.gpa.free(kv.key);
        }
    }
};

test "token_store: memory store keyed by issuer and resource" {
    const gpa = std.testing.allocator;
    var m: MemoryTokenStore = .init(gpa, std.testing.io);
    defer m.deinit();
    const s = m.store();
    try s.save("https://as1", "https://mcp/a", .{ .access_token = "one", .token_type = "Bearer" });
    try s.save("https://as2", "https://mcp/a", .{ .access_token = "two", .token_type = "Bearer", .refresh_token = "r" });
    try s.save("https://as1", "https://mcp/a", .{ .access_token = "one-b", .token_type = "Bearer" });
    const a = (try s.load(gpa, "https://as1", "https://mcp/a")).?;
    defer a.deinit(gpa);
    try std.testing.expectEqualStrings("one-b", a.access_token);
    const b = (try s.load(gpa, "https://as2", "https://mcp/a")).?;
    defer b.deinit(gpa);
    try std.testing.expectEqualStrings("r", b.refresh_token.?);
    try std.testing.expectEqual(@as(?TokenSet, null), try s.load(gpa, "https://as1", "https://mcp/b"));
    try s.remove("https://as1", "https://mcp/a");
    try std.testing.expectEqual(@as(?TokenSet, null), try s.load(gpa, "https://as1", "https://mcp/a"));
}
