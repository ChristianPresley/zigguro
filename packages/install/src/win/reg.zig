//! The registry as the installer uses it: HKCU only, paths relative to
//! HKCU with `\` separators, compared case-insensitively. `Backend` is
//! either the real registry (Windows) or `Memory`, an in-memory model the
//! integration logic is tested against on every OS. The Windows backend
//! takes a `prefix` so tests work in a throwaway subtree.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const RegValue = @import("../receipt.zig").RegValue;

pub const Error = error{ AccessDenied, UnsupportedValueType, RegistryFailed, InvalidUtf8, OutOfMemory };

pub const Backend = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Creates `path` (and missing parents); true when `path` itself
        /// did not exist.
        createKey: *const fn (ctx: *anyopaque, path: []const u8) Error!bool,
        keyExists: *const fn (ctx: *anyopaque, path: []const u8) bool,
        /// The value, or null when the key or value does not exist.
        getValue: *const fn (ctx: *anyopaque, arena: Allocator, path: []const u8, name: []const u8) Error!?RegValue,
        setValue: *const fn (ctx: *anyopaque, path: []const u8, name: []const u8, v: RegValue) Error!void,
        /// Missing values and keys are fine.
        deleteValue: *const fn (ctx: *anyopaque, path: []const u8, name: []const u8) Error!void,
        /// Deletes `path` when it has no values and no subkeys; false when
        /// it is not empty. A missing key counts as deleted.
        deleteKeyIfEmpty: *const fn (ctx: *anyopaque, path: []const u8) Error!bool,
    };

    pub fn createKey(b: Backend, path: []const u8) Error!bool {
        return b.vtable.createKey(b.ctx, path);
    }
    pub fn keyExists(b: Backend, path: []const u8) bool {
        return b.vtable.keyExists(b.ctx, path);
    }
    pub fn getValue(b: Backend, arena: Allocator, path: []const u8, name: []const u8) Error!?RegValue {
        return b.vtable.getValue(b.ctx, arena, path, name);
    }
    pub fn setValue(b: Backend, path: []const u8, name: []const u8, v: RegValue) Error!void {
        return b.vtable.setValue(b.ctx, path, name, v);
    }
    pub fn deleteValue(b: Backend, path: []const u8, name: []const u8) Error!void {
        return b.vtable.deleteValue(b.ctx, path, name);
    }
    pub fn deleteKeyIfEmpty(b: Backend, path: []const u8) Error!bool {
        return b.vtable.deleteKeyIfEmpty(b.ctx, path);
    }
};

/// An in-memory registry for tests. Keys and value names are stored
/// lowercased, as the registry compares them case-insensitively.
pub const Memory = struct {
    arena: std.heap.ArenaAllocator,
    keys: std.StringArrayHashMapUnmanaged(std.StringArrayHashMapUnmanaged(RegValue)) = .empty,

    pub fn init(gpa: Allocator) Memory {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(m: *Memory) void {
        m.arena.deinit();
    }

    pub fn backend(m: *Memory) Backend {
        return .{ .ctx = m, .vtable = &vtable };
    }

    const vtable: Backend.VTable = .{
        .createKey = createKey,
        .keyExists = keyExists,
        .getValue = getValue,
        .setValue = setValue,
        .deleteValue = deleteValue,
        .deleteKeyIfEmpty = deleteKeyIfEmpty,
    };

    fn self(ctx: *anyopaque) *Memory {
        return @ptrCast(@alignCast(ctx));
    }

    fn lower(m: *Memory, s: []const u8) Error![]u8 {
        return std.ascii.allocLowerString(m.arena.allocator(), s);
    }

    fn createKey(ctx: *anyopaque, path: []const u8) Error!bool {
        const m = self(ctx);
        var created = false;
        var end: usize = 0;
        while (end <= path.len) : (end += 1) {
            if (end != path.len and path[end] != '\\') continue;
            const k = try m.lower(path[0..end]);
            const gop = try m.keys.getOrPut(m.arena.allocator(), k);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            if (end == path.len) created = !gop.found_existing;
        }
        return created;
    }

    fn keyExists(ctx: *anyopaque, path: []const u8) bool {
        const m = self(ctx);
        const k = m.lower(path) catch return false;
        return m.keys.contains(k);
    }

    fn getValue(ctx: *anyopaque, arena: Allocator, path: []const u8, name: []const u8) Error!?RegValue {
        const m = self(ctx);
        const vals = m.keys.get(try m.lower(path)) orelse return null;
        const v = vals.get(try m.lower(name)) orelse return null;
        return try @import("../receipt.zig").dupeValue(arena, v);
    }

    fn setValue(ctx: *anyopaque, path: []const u8, name: []const u8, v: RegValue) Error!void {
        const m = self(ctx);
        const vals = m.keys.getPtr(try m.lower(path)) orelse return error.RegistryFailed;
        try vals.put(m.arena.allocator(), try m.lower(name), try @import("../receipt.zig").dupeValue(m.arena.allocator(), v));
    }

    fn deleteValue(ctx: *anyopaque, path: []const u8, name: []const u8) Error!void {
        const m = self(ctx);
        const vals = m.keys.getPtr(try m.lower(path)) orelse return;
        _ = vals.orderedRemove(try m.lower(name));
    }

    fn deleteKeyIfEmpty(ctx: *anyopaque, path: []const u8) Error!bool {
        const m = self(ctx);
        const k = try m.lower(path);
        const vals = m.keys.get(k) orelse return true;
        if (vals.count() != 0) return false;
        for (m.keys.keys()) |other| {
            if (other.len > k.len and std.mem.startsWith(u8, other, k) and other[k.len] == '\\') return false;
        }
        _ = m.keys.orderedRemove(k);
        return true;
    }

    /// Every key and value, sorted, one per line: a snapshot to compare
    /// before and after.
    pub fn dump(m: *Memory, gpa: Allocator) ![]u8 {
        var lines: std.ArrayList([]const u8) = .empty;
        defer {
            for (lines.items) |l| gpa.free(l);
            lines.deinit(gpa);
        }
        for (m.keys.keys(), m.keys.values()) |k, vals| {
            try lines.append(gpa, try std.fmt.allocPrint(gpa, "[{s}]", .{k}));
            for (vals.keys(), vals.values()) |n, v| try lines.append(gpa, try std.fmt.allocPrint(gpa, "[{s}] {s} = {any}", .{ k, n, v }));
        }
        std.mem.sort([]const u8, lines.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        return std.mem.join(gpa, "\n", lines.items);
    }
};

/// The real HKCU registry, with every path under `prefix` (empty for real
/// installs; `Software\zigguro-test-<rand>\` in tests).
pub const Windows = if (builtin.os.tag == .windows) struct {
    gpa: Allocator,
    prefix: []const u8 = "",

    const w = @import("bindings.zig");

    pub fn backend(r: *@This()) Backend {
        return .{ .ctx = r, .vtable = &vtable };
    }

    const vtable: Backend.VTable = .{
        .createKey = createKey,
        .keyExists = keyExists,
        .getValue = getValue,
        .setValue = setValue,
        .deleteValue = deleteValue,
        .deleteKeyIfEmpty = deleteKeyIfEmpty,
    };

    fn self(ctx: *anyopaque) *@This() {
        return @ptrCast(@alignCast(ctx));
    }

    fn wide(r: *@This(), path: []const u8) Error![:0]u16 {
        const full = try std.mem.concat(r.gpa, u8, &.{ r.prefix, path });
        defer r.gpa.free(full);
        return std.unicode.utf8ToUtf16LeAllocZ(r.gpa, full) catch |e| switch (e) {
            error.InvalidUtf8 => error.InvalidUtf8,
            error.OutOfMemory => error.OutOfMemory,
        };
    }

    fn check(rc: w.LONG) Error!void {
        return switch (rc) {
            w.ERROR_SUCCESS => {},
            5 => error.AccessDenied,
            else => error.RegistryFailed,
        };
    }

    fn open(r: *@This(), path: []const u8, sam: w.DWORD) Error!?w.HKEY {
        const p = try r.wide(path);
        defer r.gpa.free(p);
        var key: w.HKEY = undefined;
        const rc = w.RegOpenKeyExW(w.HKEY_CURRENT_USER, p, 0, sam, &key);
        if (rc == w.ERROR_FILE_NOT_FOUND) return null;
        try check(rc);
        return key;
    }

    fn createKey(ctx: *anyopaque, path: []const u8) Error!bool {
        const r = self(ctx);
        const p = try r.wide(path);
        defer r.gpa.free(p);
        var key: w.HKEY = undefined;
        var disp: w.DWORD = 0;
        try check(w.RegCreateKeyExW(w.HKEY_CURRENT_USER, p, 0, null, w.REG_OPTION_NON_VOLATILE, w.KEY_READ | w.KEY_WRITE, null, &key, &disp));
        _ = w.RegCloseKey(key);
        return disp == w.REG_CREATED_NEW_KEY;
    }

    fn keyExists(ctx: *anyopaque, path: []const u8) bool {
        const r = self(ctx);
        const key = (r.open(path, w.KEY_QUERY_VALUE) catch return false) orelse return false;
        _ = w.RegCloseKey(key);
        return true;
    }

    fn getValue(ctx: *anyopaque, arena: Allocator, path: []const u8, name: []const u8) Error!?RegValue {
        const r = self(ctx);
        const key = (try r.open(path, w.KEY_QUERY_VALUE)) orelse return null;
        defer _ = w.RegCloseKey(key);
        const n = try std.unicode.utf8ToUtf16LeAllocZ(r.gpa, name);
        defer r.gpa.free(n);
        var kind: w.DWORD = 0;
        var len: w.DWORD = 0;
        var rc = w.RegQueryValueExW(key, n, null, &kind, null, &len);
        if (rc == w.ERROR_FILE_NOT_FOUND) return null;
        try check(rc);
        const buf = try r.gpa.alignedAlloc(u8, .of(u16), len + 2);
        defer r.gpa.free(buf);
        rc = w.RegQueryValueExW(key, n, null, &kind, buf.ptr, &len);
        try check(rc);
        return switch (kind) {
            w.REG_NONE => .none,
            w.REG_DWORD => if (len == 4) .{ .dword = std.mem.readInt(u32, buf[0..4], .little) } else error.UnsupportedValueType,
            w.REG_SZ, w.REG_EXPAND_SZ => blk: {
                var units: []const u16 = @as([*]const u16, @ptrCast(buf.ptr))[0 .. len / 2];
                while (units.len > 0 and units[units.len - 1] == 0) units = units[0 .. units.len - 1];
                const s = std.unicode.utf16LeToUtf8Alloc(arena, units) catch return error.InvalidUtf8;
                break :blk if (kind == w.REG_SZ) .{ .sz = s } else .{ .expand_sz = s };
            },
            else => error.UnsupportedValueType,
        };
    }

    fn setValue(ctx: *anyopaque, path: []const u8, name: []const u8, v: RegValue) Error!void {
        const r = self(ctx);
        const key = (try r.open(path, w.KEY_SET_VALUE)) orelse return error.RegistryFailed;
        defer _ = w.RegCloseKey(key);
        const n = try std.unicode.utf8ToUtf16LeAllocZ(r.gpa, name);
        defer r.gpa.free(n);
        switch (v) {
            .none => try check(w.RegSetValueExW(key, n, 0, w.REG_NONE, null, 0)),
            .dword => |d| {
                var b: [4]u8 = undefined;
                std.mem.writeInt(u32, &b, d, .little);
                try check(w.RegSetValueExW(key, n, 0, w.REG_DWORD, &b, 4));
            },
            .sz, .expand_sz => |s| {
                const data = std.unicode.utf8ToUtf16LeAllocZ(r.gpa, s) catch return error.InvalidUtf8;
                defer r.gpa.free(data);
                const bytes: [*]const u8 = @ptrCast(data.ptr);
                try check(w.RegSetValueExW(key, n, 0, if (v == .sz) w.REG_SZ else w.REG_EXPAND_SZ, bytes, @intCast((data.len + 1) * 2)));
            },
        }
    }

    fn deleteValue(ctx: *anyopaque, path: []const u8, name: []const u8) Error!void {
        const r = self(ctx);
        const key = (try r.open(path, w.KEY_SET_VALUE)) orelse return;
        defer _ = w.RegCloseKey(key);
        const n = try std.unicode.utf8ToUtf16LeAllocZ(r.gpa, name);
        defer r.gpa.free(n);
        const rc = w.RegDeleteValueW(key, n);
        if (rc != w.ERROR_FILE_NOT_FOUND) try check(rc);
    }

    fn deleteKeyIfEmpty(ctx: *anyopaque, path: []const u8) Error!bool {
        const r = self(ctx);
        const key = (try r.open(path, w.KEY_READ)) orelse return true;
        var subkeys: w.DWORD = 0;
        var values: w.DWORD = 0;
        const rc = w.RegQueryInfoKeyW(key, null, null, null, &subkeys, null, null, &values, null, null, null, null);
        _ = w.RegCloseKey(key);
        try check(rc);
        if (subkeys != 0 or values != 0) return false;
        const p = try r.wide(path);
        defer r.gpa.free(p);
        const drc = w.RegDeleteKeyW(w.HKEY_CURRENT_USER, p);
        if (drc != w.ERROR_FILE_NOT_FOUND) try check(drc);
        return true;
    }

    /// Deletes the whole `prefix` subtree (test cleanup).
    pub fn deletePrefixTree(r: *@This()) void {
        const p = r.wide("") catch return;
        defer r.gpa.free(p);
        _ = w.RegDeleteTreeW(w.HKEY_CURRENT_USER, p);
        _ = w.RegDeleteKeyW(w.HKEY_CURRENT_USER, p);
    }
} else struct {};

const testing = std.testing;

test "reg: memory backend creates parents and deletes only empty keys" {
    var m: Memory = .init(testing.allocator);
    defer m.deinit();
    const b = m.backend();
    try testing.expect(try b.createKey("Software\\A\\B"));
    try testing.expect(!try b.createKey("software\\a\\b"));
    try testing.expect(b.keyExists("SOFTWARE\\A"));
    try b.setValue("Software\\A\\B", "X", .{ .sz = "1" });
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("1", (try b.getValue(arena.allocator(), "software\\a\\b", "x")).?.sz);
    try testing.expect(!try b.deleteKeyIfEmpty("Software\\A")); // has a subkey
    try testing.expect(!try b.deleteKeyIfEmpty("Software\\A\\B")); // has a value
    try b.deleteValue("Software\\A\\B", "x");
    try b.deleteValue("Software\\A\\B", "x");
    try testing.expect(try b.deleteKeyIfEmpty("Software\\A\\B"));
    try testing.expect(try b.deleteKeyIfEmpty("Software\\A\\B"));
    try testing.expect(!b.keyExists("Software\\A\\B"));
}
