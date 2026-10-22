//! Windows font discovery tests. The default table, `%VAR%` expansion,
//! suffix stripping and assembly over a fixture tree run everywhere;
//! the registry tests run on Windows only (`builtin.os.tag`).

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const discovery = @import("discovery.zig");
const win = @import("discovery_windows.zig");
const reg = @import("win_registry.zig");
const fallback = @import("fallback.zig");

test "windowsDefaults table well-formed" {
    const d = win.windowsDefaults();
    for ([_][]const []const u8{ d.ui, d.mono, d.serif, d.emoji }) |list| {
        try testing.expect(list.len > 0);
        for (list) |f| try testing.expect(f.len > 0 and std.mem.trim(u8, f, " ").len == f.len);
    }
    try testing.expectEqualStrings("Segoe UI Emoji", d.emoji[0]);
    try testing.expectEqualStrings("Cascadia Mono", d.mono[0]);
    // Each Han variant once; every other script at most once.
    for (std.enums.values(fallback.HanVariant)) |v| {
        var n: usize = 0;
        for (d.per_script) |sf| if (sf.script == .Hani and sf.han == v) {
            n += 1;
        };
        try testing.expectEqual(1, n);
    }
    for (d.per_script, 0..) |a, i| {
        try testing.expect(a.families.len > 0);
        try testing.expect((a.script == .Hani) == (a.han != null));
        for (d.per_script[i + 1 ..]) |b| if (a.script != .Hani) try testing.expect(a.script != b.script);
    }
}

fn testEnv(gpa: std.mem.Allocator) !std.process.Environ.Map {
    var env: std.process.Environ.Map = .init(gpa);
    errdefer env.deinit();
    try env.put("SystemRoot", "C:\\Windows");
    try env.put("USERPROFILE", "C:\\Users\\me");
    try env.put("EMPTY", "");
    return env;
}

test "expand environment references" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try testEnv(testing.allocator);
    defer env.deinit();
    const cases = [_][2][]const u8{
        .{ "plain.ttf", "plain.ttf" },
        .{ "%SystemRoot%\\Fonts\\a.ttf", "C:\\Windows\\Fonts\\a.ttf" },
        .{ "%USERPROFILE%\\x\\%SystemRoot%", "C:\\Users\\me\\x\\C:\\Windows" },
        .{ "%EMPTY%b", "b" },
        // Unknown names, empty names and a lone `%` stay as written.
        .{ "%NOPE%\\a", "%NOPE%\\a" },
        .{ "50% off", "50% off" },
        .{ "%%", "%%" },
        .{ "%NOPE%SystemRoot%", "%NOPEC:\\Windows" },
        .{ "a%", "a%" },
    };
    for (cases) |c| try testing.expectEqualStrings(c[1], try win.expandEnv(a, c[0], &env));
}

test "suffix stripping" {
    try testing.expectEqualStrings("Segoe UI", win.stripSuffix("Segoe UI (TrueType)"));
    try testing.expectEqualStrings("Cascadia Code", win.stripSuffix("Cascadia Code (opentype)"));
    try testing.expectEqualStrings("Cambria & Cambria Math", win.stripSuffix("Cambria & Cambria Math (TrueType)"));
    try testing.expectEqualStrings("Courier 10,12,15", win.stripSuffix("Courier 10,12,15"));
    try testing.expectEqualStrings("(TrueType)", win.stripSuffix("(TrueType)"));
}

test "system fonts dir from the environment" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    const sep = std.fs.path.sep_str;
    try testing.expectEqualStrings("C:\\Windows" ++ sep ++ "Fonts", try win.systemFontsDir(a, &env));
    try env.put("WINDIR", "D:\\Win");
    try testing.expectEqualStrings("D:\\Win" ++ sep ++ "Fonts", try win.systemFontsDir(a, &env));
    try env.put("SystemRoot", "E:\\Sys");
    try testing.expectEqualStrings("E:\\Sys" ++ sep ++ "Fonts", try win.systemFontsDir(a, &env));
}

test "assemble dirs, registered files and aliases" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "win/Fonts");
    try tmp.dir.createDirPath(io, "local/Microsoft/Windows/Fonts");
    try tmp.dir.createDirPath(io, "elsewhere");
    for ([_][]const u8{
        "win/Fonts/segoeui.ttf",
        "win/Fonts/unregistered.otf",
        "win/Fonts/serife.fon",
        "local/Microsoft/Windows/Fonts/user.ttf",
        "elsewhere/extra.otf",
        "elsewhere/expanded.ttc",
        "elsewhere/bitmap.fon",
    }) |p| try tmp.dir.writeFile(io, .{ .sub_path = p, .data = "x" });
    const base = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(base);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const join = struct {
        fn f(al: std.mem.Allocator, parts: []const []const u8) []const u8 {
            return std.fs.path.join(al, parts) catch unreachable;
        }
    }.f;

    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put("SystemRoot", join(a, &.{ base, "win" }));
    try env.put("LOCALAPPDATA", join(a, &.{ base, "local" }));
    try env.put("EXTRA", join(a, &.{ base, "elsewhere" }));
    const values = [_]reg.NameValue{
        .{ .name = "Segoe UI (TrueType)", .value = "segoeui.ttf", .kind = .sz },
        .{ .name = "Missing (TrueType)", .value = "missing.ttf", .kind = .sz },
        .{ .name = "Serif", .value = "serife.fon", .kind = .sz },
        .{ .name = "Extra (OpenType)", .value = join(a, &.{ base, "elsewhere", "extra.otf" }), .kind = .sz },
        .{ .name = "Extra again (OpenType)", .value = join(a, &.{ base, "elsewhere", "extra.otf" }), .kind = .sz },
        .{ .name = "Expanded (TrueType)", .value = "%EXTRA%" ++ std.fs.path.sep_str ++ "expanded.ttc", .kind = .expand_sz },
        .{ .name = "Bitmap", .value = join(a, &.{ base, "elsewhere", "bitmap.fon" }), .kind = .sz },
        .{ .name = "User (TrueType)", .value = join(a, &.{ base, "local", "Microsoft", "Windows", "Fonts", "user.ttf" }), .kind = .sz },
        .{ .name = "Gone (TrueType)", .value = join(a, &.{ base, "elsewhere", "gone.ttf" }), .kind = .sz },
    };
    // The result must not point into the values, which callers free.
    var copies: [values.len]reg.NameValue = undefined;
    for (&copies, values) |*c, v| c.* = .{ .name = v.name, .value = try gpa.dupe(u8, v.value), .kind = v.kind };
    var d = try win.assemble(gpa, io, &env, &copies, win.windows_defaults);
    defer d.deinit(gpa);
    for (copies) |c| {
        @memset(@constCast(c.value), 0xAA);
        gpa.free(c.value);
    }

    try testing.expectEqual(2, d.dirs.len);
    try testing.expectEqualStrings(join(a, &.{ base, "win", "Fonts" }), d.dirs[0]);
    try testing.expectEqualStrings(join(a, &.{ base, "local", "Microsoft", "Windows", "Fonts" }), d.dirs[1]);
    // Registered font files outside the directories, once; a missing
    // one is listed here and skipped by `listFiles`.
    try testing.expectEqual(3, d.files.len);
    try testing.expectEqualStrings(join(a, &.{ base, "elsewhere", "extra.otf" }), d.files[0]);
    try testing.expectEqualStrings(join(a, &.{ base, "elsewhere", "expanded.ttc" }), d.files[1]);
    try testing.expectEqualStrings(join(a, &.{ base, "elsewhere", "gone.ttf" }), d.files[2]);

    var out: std.ArrayList(discovery.FileEntry) = .empty;
    defer discovery.freeFileEntries(gpa, &out);
    try d.listFiles(gpa, io, &out);
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    for (out.items) |e| try names.append(gpa, std.fs.path.basename(e.path));
    const want: []const []const u8 = &.{ "segoeui.ttf", "unregistered.otf", "user.ttf", "extra.otf", "expanded.ttc" };
    try testing.expectEqualDeep(want, names.items);

    const mono = try d.preferences(a, "monospace");
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "Cascadia Mono", "Cascadia Code", "Consolas" }), mono);
    const ui = try d.preferences(a, "system-ui");
    try testing.expectEqualStrings("Segoe UI Variable Text", ui[0]);
    try testing.expectEqualStrings("Segoe UI Emoji", (try d.preferences(a, "emoji"))[0]);
}

test "assemble without per-user directory" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "win/Fonts");
    const root = try tmp.dir.realPathFileAlloc(io, "win", gpa);
    defer gpa.free(root);
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put("WINDIR", root);
    try env.put("LOCALAPPDATA", "/nonexistent-zigguro-test");
    var d = try win.assemble(gpa, io, &env, &.{}, .{});
    defer d.deinit(gpa);
    try testing.expectEqual(1, d.dirs.len);
    try testing.expectEqual(0, d.files.len);
}

// Windows only: the real registry.

const W = if (builtin.os.tag == .windows) struct {
    const HKEY = reg.HKEY;
    extern "advapi32" fn RegCreateKeyExW(hKey: HKEY, lpSubKey: [*:0]const u16, Reserved: u32, lpClass: ?[*:0]u16, dwOptions: u32, samDesired: u32, lpSecurityAttributes: ?*anyopaque, phkResult: *HKEY, lpdwDisposition: ?*u32) callconv(.winapi) i32;
    extern "advapi32" fn RegSetValueExW(hKey: HKEY, lpValueName: [*:0]const u16, Reserved: u32, dwType: u32, lpData: [*]const u8, cbData: u32) callconv(.winapi) i32;
    extern "advapi32" fn RegDeleteTreeW(hKey: HKEY, lpSubKey: ?[*:0]const u16) callconv(.winapi) i32;

    const test_key = "Software\\zigguro-test";
    const test_subkey = test_key ++ "\\Fonts";
    const KEY_WRITE: u32 = 0x20006;

    /// Creates HKCU\Software\zigguro-test\Fonts with `values`.
    fn createTestKey(values: []const struct { []const u8, []const u8, u32 }) !void {
        const w = std.unicode.utf8ToUtf16LeStringLiteral;
        var key: HKEY = undefined;
        if (RegCreateKeyExW(std.os.windows.HKEY_CURRENT_USER, w(test_subkey), 0, null, 0, KEY_WRITE, null, &key, null) != 0)
            return error.RegistryError;
        defer _ = reg.RegCloseKey(key);
        for (values) |v| {
            const name = try std.unicode.utf8ToUtf16LeAllocZ(testing.allocator, v[0]);
            defer testing.allocator.free(name);
            const data = try std.unicode.utf8ToUtf16LeAllocZ(testing.allocator, v[1]);
            defer testing.allocator.free(data);
            const bytes = std.mem.sliceAsBytes(data[0 .. data.len + 1]);
            if (RegSetValueExW(key, name.ptr, 0, v[2], bytes.ptr, @intCast(bytes.len)) != 0) return error.RegistryError;
        }
    }

    /// Wine keeps its fonts outside C:\windows\Fonts.
    fn isWine() bool {
        var key: HKEY = undefined;
        if (reg.RegOpenKeyExW(std.os.windows.HKEY_LOCAL_MACHINE, std.unicode.utf8ToUtf16LeStringLiteral("Software\\Wine"), 0, reg.KEY_READ, &key) != 0) return false;
        _ = reg.RegCloseKey(key);
        return true;
    }

    fn deleteTestKey() void {
        _ = RegDeleteTreeW(std.os.windows.HKEY_CURRENT_USER, std.unicode.utf8ToUtf16LeStringLiteral(test_key));
    }
} else struct {};

test "enumerate HKLM fonts non-empty" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var values: std.ArrayList(reg.NameValue) = .empty;
    defer reg.freeValues(testing.allocator, &values);
    try reg.enumStringValues(testing.allocator, .hklm, win.fonts_subkey, &values);
    try testing.expect(values.items.len > 0);
    for (values.items) |v| try testing.expect(v.value.len > 0);
}

test "Segoe UI resolves to existing file" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    var values: std.ArrayList(reg.NameValue) = .empty;
    defer reg.freeValues(gpa, &values);
    try reg.enumStringValues(gpa, .hklm, win.fonts_subkey, &values);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var env = try testing.environ.createMap(gpa);
    defer env.deinit();
    const dir = try win.systemFontsDir(arena.allocator(), &env);
    for (values.items) |v| {
        if (!std.mem.eql(u8, win.stripSuffix(v.name), "Segoe UI")) continue;
        const p = try win.resolveFontPath(arena.allocator(), v.value, dir);
        const st = try std.Io.Dir.cwd().statFile(testing.io, p, .{});
        try testing.expect(st.kind == .file);
        return;
    }
    // Wine (used to run these tests off Windows) registers no Segoe UI.
    return error.SkipZigTest;
}

test "per-user font path" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    W.deleteTestKey();
    defer W.deleteTestKey();
    try W.createTestKey(&.{
        .{ "Test Font (TrueType)", "C:\\Users\\me\\AppData\\Local\\Microsoft\\Windows\\Fonts\\test.ttf", reg.REG_SZ },
        .{ "Expanded (TrueType)", "%LOCALAPPDATA%\\Microsoft\\Windows\\Fonts\\exp.ttf", reg.REG_EXPAND_SZ },
        .{ "Bitmap", "x.fon", reg.REG_SZ },
    });
    var values: std.ArrayList(reg.NameValue) = .empty;
    defer reg.freeValues(gpa, &values);
    try reg.enumStringValues(gpa, .hkcu, W.test_subkey, &values);
    try testing.expectEqual(3, values.items.len);
    var found: usize = 0;
    for (values.items) |v| {
        if (std.mem.eql(u8, v.name, "Test Font (TrueType)")) {
            try testing.expectEqual(reg.Kind.sz, v.kind);
            try testing.expectEqualStrings("C:\\Users\\me\\AppData\\Local\\Microsoft\\Windows\\Fonts\\test.ttf", v.value);
            found += 1;
        }
    }
    try testing.expectEqual(1, found);
    // A missing key is not an error.
    W.deleteTestKey();
    var none: std.ArrayList(reg.NameValue) = .empty;
    defer reg.freeValues(gpa, &none);
    try reg.enumStringValues(gpa, .hkcu, W.test_subkey, &none);
    try testing.expectEqual(0, none.items.len);
}

test "expand REG_EXPAND_SZ" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    W.deleteTestKey();
    defer W.deleteTestKey();
    // A long name and value exercise the ERROR_MORE_DATA retry.
    const long_name = "N" ** 300;
    const long_value = "%ZG_FONT_TEST_DIR%\\" ++ "v" ** 700 ++ ".ttf";
    try W.createTestKey(&.{.{ long_name, long_value, reg.REG_EXPAND_SZ }});
    var values: std.ArrayList(reg.NameValue) = .empty;
    defer reg.freeValues(gpa, &values);
    try reg.enumStringValues(gpa, .hkcu, W.test_subkey, &values);
    try testing.expectEqual(1, values.items.len);
    const v = values.items[0];
    try testing.expectEqual(reg.Kind.expand_sz, v.kind);
    try testing.expectEqualStrings(long_name, v.name);
    try testing.expectEqualStrings(long_value, v.value);
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put("zg_font_test_dir", "D:\\f");
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    // Environment names compare case-insensitively on Windows.
    try testing.expectEqualStrings("D:\\f\\" ++ "v" ** 700 ++ ".ttf", try win.expandEnv(arena.allocator(), v.value, &env));
}

test "discoverWindows on this machine" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try testing.environ.createMap(gpa);
    defer env.deinit();
    var d = try win.discoverWindows(gpa, testing.io, &env);
    defer d.deinit(gpa);
    try testing.expect(d.dirs.len >= 1);
    var out: std.ArrayList(discovery.FileEntry) = .empty;
    defer discovery.freeFileEntries(gpa, &out);
    try d.listFiles(gpa, testing.io, &out);
    if (out.items.len == 0 and W.isWine()) return error.SkipZigTest;
    try testing.expect(out.items.len > 0);
}
