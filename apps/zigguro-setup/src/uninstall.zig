//! `zigguro-setup --uninstall` (E17.F02.S02.T01). The helper runs from
//! `<root>\app\`, which it is about to delete, so it works in two stages:
//!
//! 1. Copy itself to `%TEMP%\zigguro-uninstall-<rand>.exe`, start the
//!    copy with `--stage2 --root <root> --parent-pid <pid>` and exit.
//! 2. The copy waits for the first stage to exit, then reverses the
//!    receipt (or, when it is missing or corrupt, the full list of
//!    registrations integrate can make), deletes the install root and,
//!    on request, the per-user directories, and finally has `cmd` delete
//!    the copy once it has exited.
//!
//! `run` is the second stage's work, against any registry backend, so it
//! is tested on every OS.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zg_install = @import("zg_install");
const zg_config = @import("zg_config");
const zg_update = @import("zg_update");
const zg_release = @import("zg_release");
const registry = zg_install.win.registry;
const reg = zg_install.win.reg;
const Action = zg_install.receipt.Action;

/// Prefix of the temporary second-stage copy.
pub const temp_prefix = "zigguro-uninstall-";

pub const Plan = struct {
    /// Absolute install root.
    root: []const u8,
    /// Per-user directories to delete; each must pass `safeDataDir`.
    data_dirs: []const []const u8 = &.{},
    /// Directories deleted afterwards only when empty (`%LOCALAPPDATA%\zigguro`).
    empty_parents: []const []const u8 = &.{},
    /// Shortcut paths for the fallback action list.
    shortcut_paths: []const []const u8 = &.{},
};

pub const Error = error{
    /// The root holds neither a receipt nor `app\zigguro.exe`.
    NotInstalled,
    /// The root or a per-user directory could not be deleted.
    DeleteFailed,
    OutOfMemory,
};

/// True for zigguro's own per-user directories: the path ends in
/// `zigguro` or `zigguro\data|state|cache` (either separator, any case),
/// so a misconfigured environment can never point the uninstaller at a
/// user folder.
pub fn safeDataDir(path: []const u8) bool {
    const trimmed = std.mem.trimEnd(u8, path, "\\/");
    var it = std.mem.splitBackwardsAny(u8, trimmed, "\\/");
    const last = it.next() orelse return false;
    if (std.ascii.eqlIgnoreCase(last, "zigguro")) return it.next() != null;
    inline for (.{ "data", "state", "cache" }) |k| {
        if (std.ascii.eqlIgnoreCase(last, k)) {
            const parent = it.next() orelse return false;
            return std.ascii.eqlIgnoreCase(parent, "zigguro") and it.next() != null;
        }
    }
    return false;
}

/// The per-user directories to delete for `paths`, and the parents to
/// delete when they end up empty. Portable paths are left alone: they
/// live next to a portable copy, not an install.
pub fn dataDirs(arena: Allocator, paths: zg_config.paths.ConfigPaths) Allocator.Error!struct { dirs: []const []const u8, parents: []const []const u8 } {
    var dirs: std.ArrayList([]const u8) = .empty;
    var parents: std.ArrayList([]const u8) = .empty;
    if (paths.portable) return .{ .dirs = &.{}, .parents = &.{} };
    inline for (.{ .data, .state, .cache, .config }) |k| {
        const d = paths.dir(k);
        if (safeDataDir(d)) {
            try dirs.append(arena, d);
            if (k != .config) if (parentOf(d)) |p| {
                if (safeDataDir(p) and !contains(parents.items, p) and !contains(dirs.items, p)) try parents.append(arena, p);
            };
        }
    }
    return .{ .dirs = dirs.items, .parents = parents.items };
}

/// The parent of `path`, splitting on either separator so Windows paths
/// work in tests on every OS.
fn parentOf(path: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimEnd(u8, path, "\\/");
    const i = std.mem.lastIndexOfAny(u8, trimmed, "\\/") orelse return null;
    return trimmed[0..i];
}

fn contains(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

/// True when `root` holds an install: a receipt or `app\zigguro.exe`.
pub fn looksInstalled(io: Io, root: []const u8) bool {
    var dir = Io.Dir.cwd().openDir(io, root, .{}) catch return false;
    defer dir.close(io);
    if (dir.statFile(io, zg_install.receipt.file_name, .{})) |_| return true else |_| {}
    const exe = zg_update.layout.names.app ++ std.fs.path.sep_str ++ registry.exe_name;
    if (dir.statFile(io, exe, .{})) |_| return true else |_| {}
    return false;
}

/// The receipt's actions, or every registration integrate can make for
/// `root` when the receipt is missing or unreadable.
pub fn actionsFor(arena: Allocator, io: Io, plan: Plan, log: ?*Io.Writer) Allocator.Error![]const Action {
    var dir = Io.Dir.cwd().openDir(io, plan.root, .{}) catch return fallback(arena, plan, log);
    defer dir.close(io);
    const r = zg_install.Receipt.load(arena, io, dir) catch |err| {
        line(log, "receipt: {t}; using the default action list", .{err});
        return fallback(arena, plan, log);
    };
    return r.actions;
}

fn fallback(arena: Allocator, plan: Plan, log: ?*Io.Writer) Allocator.Error![]const Action {
    _ = log;
    const ctx: registry.Context = .{ .root = plan.root, .version = "", .install_date = "" };
    const all: zg_install.InstallOptions = .{ .add_to_path = true, .start_menu = true, .desktop_shortcut = true, .open_with = true, .folder_context_menu = true };
    return registry.fallbackActions(arena, ctx, all, plan.shortcut_paths) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// The second stage's work: reverse the registrations, delete the root
/// and the requested per-user directories.
pub fn run(gpa: Allocator, io: Io, plan: Plan, backend: reg.Backend, log: ?*Io.Writer) Error!void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!looksInstalled(io, plan.root)) {
        line(log, "{s} holds no install", .{plan.root});
        return error.NotInstalled;
    }
    line(log, "uninstall {s}", .{plan.root});
    const actions = try actionsFor(arena, io, plan, log);
    registry.unintegrateActions(backend, arena, io, actions, null);

    var failed = false;
    deleteTree(io, plan.root, log) catch {
        failed = true;
    };
    for (plan.data_dirs) |d| {
        if (!safeDataDir(d)) continue;
        deleteTree(io, d, log) catch {
            failed = true;
        };
    }
    for (plan.empty_parents) |p| Io.Dir.cwd().deleteDir(io, p) catch {};
    if (failed) return error.DeleteFailed;
    line(log, "uninstalled", .{});
}

/// `deleteTree` with three retries 200 ms apart for virus scanners and
/// indexers holding a file open for a moment.
fn deleteTree(io: Io, path: []const u8, log: ?*Io.Writer) !void {
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        Io.Dir.cwd().deleteTree(io, path) catch |err| {
            if (attempt == 3) {
                line(log, "delete {s}: {t}", .{ path, err });
                return err;
            }
            io.sleep(.fromMilliseconds(200), .awake) catch {};
            continue;
        };
        return;
    }
}

fn line(log: ?*Io.Writer, comptime fmt: []const u8, args: anytype) void {
    const w = log orelse return;
    w.print(fmt ++ "\n", args) catch {};
    w.flush() catch {};
}

/// The install root for a helper at `exe_dir`: its parent when it lives
/// in `<root>\app\`, else null.
pub fn rootFromExeDir(exe_dir: []const u8) ?[]const u8 {
    const root = parentOf(exe_dir) orelse return null;
    const base = std.mem.trimEnd(u8, exe_dir, "\\/")[root.len + 1 ..];
    if (!std.ascii.eqlIgnoreCase(base, zg_update.layout.names.app)) return null;
    return root;
}

/// The contents of the script that deletes the temporary copy `exe`
/// after it exits, then itself.
pub fn cleanupScript(buf: []u8, exe: []const u8) error{NoSpaceLeft}![]const u8 {
    return std.fmt.bufPrint(buf, "@echo off\r\nping 127.0.0.1 -n 3 > nul\r\ndel /f /q \"{s}\"\r\ndel /f /q \"%~f0\"\r\n", .{exe});
}

const testing = std.testing;

test "uninstall: data-dir guard refuses C:\\Users\\x" {
    try testing.expect(!safeDataDir("C:\\Users\\x"));
    try testing.expect(!safeDataDir("C:\\Users\\x\\AppData\\Local"));
    try testing.expect(!safeDataDir("zigguro"));
    try testing.expect(!safeDataDir("C:\\Users\\x\\data"));
    try testing.expect(!safeDataDir("C:\\"));
    try testing.expect(safeDataDir("C:\\Users\\x\\AppData\\Roaming\\zigguro"));
    try testing.expect(safeDataDir("C:\\Users\\x\\AppData\\Local\\Zigguro\\Data\\"));
    try testing.expect(safeDataDir("/home/x/.local/state/zigguro"));
    try testing.expect(!safeDataDir("C:\\Users\\x\\AppData\\Local\\zigguro\\extensions"));
}

test "uninstall: data dirs from ConfigPaths, portable left alone" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("USERPROFILE", "C:\\Users\\x");
    try env.put("APPDATA", "C:\\Users\\x\\AppData\\Roaming");
    try env.put("LOCALAPPDATA", "C:\\Users\\x\\AppData\\Local");
    var paths = try zg_config.paths.resolve(a, &env, .{ .os = .windows });
    const d = try dataDirs(a, paths);
    try testing.expectEqual(@as(usize, 4), d.dirs.len);
    try testing.expectEqualStrings("C:\\Users\\x\\AppData\\Local\\zigguro\\data", d.dirs[0]);
    try testing.expectEqualStrings("C:\\Users\\x\\AppData\\Roaming\\zigguro", d.dirs[3]);
    try testing.expectEqual(@as(usize, 1), d.parents.len);
    try testing.expectEqualStrings("C:\\Users\\x\\AppData\\Local\\zigguro", d.parents[0]);
    // A misconfigured override is skipped.
    paths.config = "C:\\Users\\x";
    try testing.expectEqual(@as(usize, 3), (try dataDirs(a, paths)).dirs.len);
    paths.portable = true;
    try testing.expectEqual(@as(usize, 0), (try dataDirs(a, paths)).dirs.len);
}

test "uninstall: root from the helper's directory; cleanup script" {
    try testing.expectEqualStrings("C:\\zg", rootFromExeDir("C:\\zg\\app").?);
    try testing.expectEqualStrings("C:\\zg", rootFromExeDir("C:\\zg\\APP").?);
    try testing.expect(rootFromExeDir("C:\\Users\\x\\Downloads") == null);
    var buf: [512]u8 = undefined;
    const s = try cleanupScript(&buf, "C:\\Users\\a b\\Temp\\zigguro-uninstall-1.exe");
    try testing.expect(std.mem.indexOf(u8, s, "del /f /q \"C:\\Users\\a b\\Temp\\zigguro-uninstall-1.exe\"") != null);
}

/// Integrates into `mem` and writes `<root>\app\zigguro.exe`.
fn fakeInstall(a: Allocator, mem: *reg.Memory, root_dir: Io.Dir, root: []const u8, with_receipt: bool) !void {
    try root_dir.createDirPath(testing.io, "app");
    try root_dir.writeFile(testing.io, .{ .sub_path = "app/zigguro.exe", .data = "MZ" });
    var rb: zg_install.ReceiptBuilder = .{ .arena = a };
    const b = mem.backend();
    _ = try b.createKey(zg_install.win.path_env.key);
    try b.setValue(zg_install.win.path_env.key, zg_install.win.path_env.value_name, .{ .expand_sz = "%USERPROFILE%\\bin" });
    try registry.integrateRegistry(b, a, .{ .root = root, .version = "0.5.0", .install_date = "20261022" }, .{}, &rb);
    if (with_receipt) {
        const r: zg_install.Receipt = .{ .app_id = zg_release.product.app_id, .version = "0.5.0", .root = root, .installed_at_unix = 1, .actions = rb.actions.items };
        try r.store(testing.allocator, testing.io, root_dir);
    }
}

test "uninstall: receipt or corrupt receipt, root and data dirs deleted, registry clean" {
    inline for (.{ true, false }) |with_receipt| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const base = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
        const root = try std.fs.path.join(a, &.{ base, "zïggürø" });
        try tmp.dir.createDirPath(testing.io, "zïggürø");
        var root_dir = try tmp.dir.openDir(testing.io, "zïggürø", .{});
        defer root_dir.close(testing.io);
        try tmp.dir.createDirPath(testing.io, "local/zigguro/data");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "local/zigguro/data/x", .data = "x" });
        try tmp.dir.createDirPath(testing.io, "local/keep");

        var mem: reg.Memory = .init(testing.allocator);
        defer mem.deinit();
        try fakeInstall(a, &mem, root_dir, root, with_receipt);
        if (!with_receipt) try root_dir.writeFile(testing.io, .{ .sub_path = zg_install.receipt.file_name, .data = ".{ .schema = " });

        const data = try std.fs.path.join(a, &.{ base, "local", "zigguro", "data" });
        const parent = try std.fs.path.join(a, &.{ base, "local", "zigguro" });
        try run(testing.allocator, testing.io, .{ .root = root, .data_dirs = &.{data}, .empty_parents = &.{parent} }, mem.backend(), null);

        try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "zïggürø", .{}));
        try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "local/zigguro", .{}));
        _ = try tmp.dir.statFile(testing.io, "local/keep", .{});
        try testing.expect(!mem.backend().keyExists(registry.progid_key));
        try testing.expect(!mem.backend().keyExists(registry.uninstall_root ++ "dev.zigguro.zigguro"));
        const path = (try mem.backend().getValue(a, zg_install.win.path_env.key, zg_install.win.path_env.value_name)).?;
        try testing.expectEqualStrings("%USERPROFILE%\\bin", path.expand_sz);
    }
}

test "uninstall: a root without an install is refused" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", arena.allocator());
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "precious.txt", .data = "keep" });
    var mem: reg.Memory = .init(testing.allocator);
    defer mem.deinit();
    try testing.expectError(error.NotInstalled, run(testing.allocator, testing.io, .{ .root = base }, mem.backend(), null));
    _ = try tmp.dir.statFile(testing.io, "precious.txt", .{});
}
