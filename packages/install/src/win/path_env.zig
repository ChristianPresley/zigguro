//! The user's PATH (`HKCU\Environment\Path`): add or remove exactly one
//! entry, keeping the others, their order and their `%VAR%` references
//! (the raw value is never expanded), and preserving REG_EXPAND_SZ or
//! REG_SZ. Entries compare case-insensitively, ignoring a trailing `\`.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const reg = @import("reg.zig");
const RegValue = @import("../receipt.zig").RegValue;

pub const key = "Environment";
pub const value_name = "Path";
/// Longest PATH value, in UTF-16 code units.
pub const max_len = 32767;

pub const Error = reg.Error || error{PathTooLong};

fn norm(e: []const u8) []const u8 {
    return std.mem.trimEnd(u8, std.mem.trim(u8, e, " "), "\\");
}

fn same(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(norm(a), norm(b));
}

/// `current` with `dir` appended, or null when it is already present.
pub fn withEntry(arena: Allocator, current: []const u8, dir: []const u8) Error!?[]const u8 {
    var it = std.mem.splitScalar(u8, current, ';');
    while (it.next()) |e| if (e.len != 0 and same(e, dir)) return null;
    const trimmed = std.mem.trimEnd(u8, current, ";");
    const out = if (trimmed.len == 0) try arena.dupe(u8, dir) else try std.mem.concat(arena, u8, &.{ trimmed, ";", dir });
    if ((std.unicode.calcUtf16LeLen(out) catch out.len) > max_len) return error.PathTooLong;
    return out;
}

/// `current` without the entries equal to `dir`, or null when there are
/// none. Other entries, empty ones included, keep their order.
pub fn withoutEntry(arena: Allocator, current: []const u8, dir: []const u8) Allocator.Error!?[]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var removed = false;
    var it = std.mem.splitScalar(u8, current, ';');
    while (it.next()) |e| {
        if (e.len != 0 and same(e, dir)) {
            removed = true;
            continue;
        }
        try parts.append(arena, e);
    }
    if (!removed) return null;
    return try std.mem.join(arena, ";", parts.items);
}

/// Appends `dir` to the user's PATH. False when it was already there.
pub fn addUserPathEntry(b: reg.Backend, arena: Allocator, dir: []const u8) Error!bool {
    const cur = try b.getValue(arena, key, value_name);
    const text, const expand = if (cur) |v| switch (v) {
        .sz => |s| .{ s, false },
        .expand_sz => |s| .{ s, true },
        else => return error.UnsupportedValueType,
    } else .{ "", true };
    const next = (try withEntry(arena, text, dir)) orelse return false;
    _ = try b.createKey(key);
    try b.setValue(key, value_name, if (expand) .{ .expand_sz = next } else .{ .sz = next });
    return true;
}

/// Removes `dir` from the user's PATH, and the value itself when
/// nothing else is left. False when it was not there.
pub fn removeUserPathEntry(b: reg.Backend, arena: Allocator, dir: []const u8) Error!bool {
    const cur = (try b.getValue(arena, key, value_name)) orelse return false;
    const text, const expand = switch (cur) {
        .sz => |s| .{ s, false },
        .expand_sz => |s| .{ s, true },
        else => return false,
    };
    const next = (try withoutEntry(arena, text, dir)) orelse return false;
    // PATH held only our entry: remove the value we created.
    if (next.len == 0) {
        try b.deleteValue(key, value_name);
        return true;
    }
    try b.setValue(key, value_name, if (expand) .{ .expand_sz = next } else .{ .sz = next });
    return true;
}

/// Tells running programs (Explorer, new terminals) that the environment
/// changed. A no-op on other OSes.
pub fn broadcastEnvironmentChange() void {
    if (builtin.os.tag != .windows) return;
    const w = @import("bindings.zig");
    const env = std.unicode.utf8ToUtf16LeStringLiteral("Environment");
    var result: usize = 0;
    _ = w.SendMessageTimeoutW(w.HWND_BROADCAST, w.WM_SETTINGCHANGE, 0, @bitCast(@intFromPtr(env)), w.SMTO_ABORTIFHUNG, 5000, &result);
}

/// Tells Explorer that file associations changed. A no-op on other OSes.
pub fn notifyAssocChanged() void {
    if (builtin.os.tag != .windows) return;
    const w = @import("bindings.zig");
    w.SHChangeNotify(w.SHCNE_ASSOCCHANGED, w.SHCNF_IDLIST, null, null);
}

const testing = std.testing;

test "path_env: add idempotent, preserves REG_EXPAND_SZ and %VARS%" {
    var m: reg.Memory = .init(testing.allocator);
    defer m.deinit();
    const b = m.backend();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try b.createKey(key);
    try b.setValue(key, value_name, .{ .expand_sz = "%USERPROFILE%\\bin;C:\\tools" });
    try testing.expect(try addUserPathEntry(b, a, "C:\\zg\\app"));
    try testing.expect(!try addUserPathEntry(b, a, "c:\\ZG\\app\\"));
    const v = (try b.getValue(a, key, value_name)).?;
    try testing.expectEqualStrings("%USERPROFILE%\\bin;C:\\tools;C:\\zg\\app", v.expand_sz);
}

test "path_env: REG_SZ stays REG_SZ, missing value becomes REG_EXPAND_SZ" {
    var m: reg.Memory = .init(testing.allocator);
    defer m.deinit();
    const b = m.backend();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(try addUserPathEntry(b, a, "C:\\zg\\app"));
    try testing.expectEqualStrings("C:\\zg\\app", (try b.getValue(a, key, value_name)).?.expand_sz);
    try b.setValue(key, value_name, .{ .sz = "C:\\a;" });
    try testing.expect(try addUserPathEntry(b, a, "C:\\zg\\app"));
    try testing.expectEqualStrings("C:\\a;C:\\zg\\app", (try b.getValue(a, key, value_name)).?.sz);
}

test "path_env: remove exact entry only" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("C:\\a;;C:\\zg\\app2;%X%", (try withoutEntry(a, "C:\\a;;C:\\ZG\\app\\;C:\\zg\\app2;%X%", "C:\\zg\\app")).?);
    try testing.expect(try withoutEntry(a, "C:\\a", "C:\\zg\\app") == null);
}

test "path_env: trailing backslash and case-insensitive match" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(try withEntry(a, "c:\\zg\\APP\\", "C:\\zg\\app") == null);
    try testing.expectEqualStrings("C:\\zg\\app", (try withEntry(a, "", "C:\\zg\\app")).?);
    const long = try a.alloc(u8, max_len);
    @memset(long, 'x');
    try testing.expectError(error.PathTooLong, withEntry(a, long, "C:\\zg\\app"));
}
