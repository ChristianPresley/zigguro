//! Start Menu and desktop shortcuts (E17.F02.S01.T01) through the Shell's
//! own `CLSID_ShellLink` COM object, with `System.AppUserModel.ID` set so
//! the taskbar groups the running window with its shortcut. Windows only.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const w = @import("bindings.zig");

pub const ShortcutSpec = struct {
    /// Full `.lnk` path (UTF-8).
    path: []const u8,
    target: []const u8,
    arguments: []const u8 = "",
    description: []const u8,
    icon_path: []const u8,
    icon_index: i32 = 0,
    working_dir: ?[]const u8 = null,
    aumid: []const u8,
};

pub const Error = error{ Unsupported, ComInitFailed, CreateFailed, SaveFailed, InvalidPath, OutOfMemory };

/// Longest shortcut description the Shell keeps.
pub const max_description = 259;

/// `s` cut to at most `max` bytes on a UTF-8 code point boundary.
pub fn truncateUtf8(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and s[end] & 0xC0 == 0x80) end -= 1;
    return s[0..end];
}

/// COM for the calling thread; `deinit` only uninitializes what `init`
/// initialized.
pub const Com = struct {
    owned: bool,

    pub fn init() Error!Com {
        if (builtin.os.tag != .windows) return error.Unsupported;
        const hr = w.CoInitializeEx(null, w.COINIT_APARTMENTTHREADED);
        if (hr == w.S_OK or hr == w.S_FALSE) return .{ .owned = true };
        if (hr == w.RPC_E_CHANGED_MODE) return .{ .owned = false };
        return error.ComInitFailed;
    }

    pub fn deinit(c: Com) void {
        if (builtin.os.tag == .windows and c.owned) w.CoUninitialize();
    }
};

fn wide(gpa: Allocator, s: []const u8) Error![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(gpa, s) catch |e| switch (e) {
        error.InvalidUtf8 => error.InvalidPath,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn release(p: anytype) void {
    _ = p.vtbl.Release(p);
}

fn query(p: anytype, comptime T: type, iid: *const w.GUID) ?*T {
    var out: ?*anyopaque = null;
    if (p.vtbl.QueryInterface(p, iid, &out) < 0) return null;
    return @ptrCast(@alignCast(out.?));
}

/// Writes the shortcut `spec.path`. The caller holds a `Com`.
pub fn createShortcut(gpa: Allocator, io: std.Io, spec: ShortcutSpec) Error!void {
    if (builtin.os.tag != .windows) return error.Unsupported;
    var obj: ?*anyopaque = null;
    if (w.CoCreateInstance(&w.CLSID_ShellLink, null, w.CLSCTX_INPROC_SERVER, &w.IID_IShellLinkW, &obj) < 0) return error.CreateFailed;
    const link: *w.IShellLinkW = @ptrCast(@alignCast(obj.?));
    defer release(link);

    const target = try wide(gpa, spec.target);
    defer gpa.free(target);
    const args = try wide(gpa, spec.arguments);
    defer gpa.free(args);
    const desc = try wide(gpa, truncateUtf8(spec.description, max_description));
    defer gpa.free(desc);
    const icon = try wide(gpa, spec.icon_path);
    defer gpa.free(icon);
    if (link.vtbl.SetPath(link, target) < 0) return error.CreateFailed;
    if (link.vtbl.SetArguments(link, args) < 0) return error.CreateFailed;
    if (link.vtbl.SetDescription(link, desc) < 0) return error.CreateFailed;
    if (link.vtbl.SetIconLocation(link, icon, spec.icon_index) < 0) return error.CreateFailed;
    if (spec.working_dir) |wd| {
        const d = try wide(gpa, wd);
        defer gpa.free(d);
        if (link.vtbl.SetWorkingDirectory(link, d) < 0) return error.CreateFailed;
    }

    // The PROPVARIANT points at our own buffer: no PropVariantClear.
    const aumid = try wide(gpa, spec.aumid);
    defer gpa.free(aumid);
    const store = query(link, w.IPropertyStore, &w.IID_IPropertyStore) orelse return error.CreateFailed;
    defer release(store);
    const pv: w.PROPVARIANT = .{ .vt = w.VT_LPWSTR, .value = .{ .pwszVal = aumid.ptr } };
    if (store.vtbl.SetValue(store, &w.PKEY_AppUserModel_ID, &pv) < 0) return error.CreateFailed;
    if (store.vtbl.Commit(store) < 0) return error.CreateFailed;

    if (std.fs.path.dirname(spec.path)) |dir| std.Io.Dir.cwd().createDirPath(io, dir) catch return error.SaveFailed;
    const path = try wide(gpa, spec.path);
    defer gpa.free(path);
    const file = query(link, w.IPersistFile, &w.IID_IPersistFile) orelse return error.SaveFailed;
    defer release(file);
    if (file.vtbl.Save(file, path, 1) < 0) return error.SaveFailed;
}

/// What a saved shortcut holds (tests and diagnostics).
pub const Readback = struct {
    target: []const u8,
    description: []const u8,
    icon_path: []const u8,
    icon_index: i32,
    aumid: ?[]const u8,
};

/// Loads `path` and reads it back. Strings go to `arena`.
pub fn readShortcut(arena: Allocator, path: []const u8) Error!Readback {
    if (builtin.os.tag != .windows) return error.Unsupported;
    var obj: ?*anyopaque = null;
    if (w.CoCreateInstance(&w.CLSID_ShellLink, null, w.CLSCTX_INPROC_SERVER, &w.IID_IShellLinkW, &obj) < 0) return error.CreateFailed;
    const link: *w.IShellLinkW = @ptrCast(@alignCast(obj.?));
    defer release(link);
    const file = query(link, w.IPersistFile, &w.IID_IPersistFile) orelse return error.CreateFailed;
    defer release(file);
    const p = try wide(arena, path);
    if (file.vtbl.Load(file, p, 0) < 0) return error.InvalidPath;

    var buf: [1024]u16 = undefined;
    const u = struct {
        fn str(a: Allocator, b: []const u16) Error![]const u8 {
            return std.unicode.utf16LeToUtf8Alloc(a, std.mem.sliceTo(b, 0)) catch error.OutOfMemory;
        }
    };
    @memset(&buf, 0);
    if (link.vtbl.GetPath(link, &buf, buf.len, null, 0) < 0) return error.CreateFailed;
    const target = try u.str(arena, &buf);
    @memset(&buf, 0);
    if (link.vtbl.GetDescription(link, &buf, buf.len) < 0) return error.CreateFailed;
    const description = try u.str(arena, &buf);
    @memset(&buf, 0);
    var index: i32 = 0;
    if (link.vtbl.GetIconLocation(link, &buf, buf.len, &index) < 0) return error.CreateFailed;
    const icon_path = try u.str(arena, &buf);

    var aumid: ?[]const u8 = null;
    if (query(link, w.IPropertyStore, &w.IID_IPropertyStore)) |store| {
        defer release(store);
        var pv: w.PROPVARIANT = .{ .vt = 0, .value = .{ .pad = .{ 0, 0 } } };
        if (store.vtbl.GetValue(store, &w.PKEY_AppUserModel_ID, &pv) >= 0) {
            if (pv.vt == w.VT_LPWSTR) if (pv.value.pwszVal) |s| {
                aumid = std.unicode.utf16LeToUtf8Alloc(arena, std.mem.sliceTo(s, 0)) catch null;
            };
            _ = w.PropVariantClear(&pv);
        }
    }
    return .{ .target = target, .description = description, .icon_path = icon_path, .icon_index = index, .aumid = aumid };
}

/// Deletes the shortcut; a missing file is fine.
pub fn deleteShortcut(io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

const testing = std.testing;

test "shortcut: description truncates on a code point boundary" {
    try testing.expectEqualStrings("ab", truncateUtf8("abc", 2));
    try testing.expectEqualStrings("a", truncateUtf8("aé", 2)); // é is 2 bytes
    try testing.expectEqualStrings("aé", truncateUtf8("aé", 3));
}

test "shortcut: create then read back" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    // Wine's ShellLink object hangs in CoCreateInstance on the cloud
    // runners; the Windows CI job runs this test.
    if (w.underWine()) return error.SkipZigTest;
    const com = try Com.init();
    defer com.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const target = try std.fs.path.join(a, &.{ dir, "zïggürø", "zigguro.exe" });
    try tmp.dir.createDirPath(testing.io, "zïggürø");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "zïggürø/zigguro.exe", .data = "MZ" });
    const lnk = try std.fs.path.join(a, &.{ dir, "zigguro.lnk" });
    try createShortcut(testing.allocator, testing.io, .{ .path = lnk, .target = target, .description = "zigguro: AI-native IDE", .icon_path = target, .aumid = "Zigguro.Zigguro" });
    const back = try readShortcut(a, lnk);
    try testing.expect(std.ascii.eqlIgnoreCase(target, back.target));
    try testing.expectEqualStrings("zigguro: AI-native IDE", back.description);
    try testing.expectEqual(@as(i32, 0), back.icon_index);
    if (back.aumid) |id| try testing.expectEqualStrings("Zigguro.Zigguro", id);
    try deleteShortcut(testing.io, lnk);
    try deleteShortcut(testing.io, lnk);
}
