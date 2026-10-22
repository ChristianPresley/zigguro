//! Windows desktop integration (E17.F02): the registry table, the user's
//! PATH and the Start Menu and desktop shortcuts, all recorded in the
//! receipt, and their exact reversal.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const zg_core = @import("zg_core");
const receipt_mod = @import("../receipt.zig");

/// Win32 externs and COM vtables.
pub const bindings = @import("bindings.zig");
/// The registry backend (real or in-memory).
pub const reg = @import("reg.zig");
/// Registrations, `RegWriter` and their reversal.
pub const registry = @import("registry.zig");
/// The user's PATH.
pub const path_env = @import("path_env.zig");
/// `.lnk` shortcuts.
pub const shortcut = @import("shortcut.zig");
/// Known folders.
pub const known_folders = @import("known_folders.zig");

pub const shortcut_name = "zigguro.lnk";

/// Registers the install at `ctx.root` in HKCU, adds the PATH entry and
/// the shortcuts `opts` asks for, records everything in `rb` and notifies
/// the shell. On Windows only.
pub fn integrate(gpa: Allocator, io: std.Io, ctx: registry.Context, opts: receipt_mod.InstallOptions, rb: *receipt_mod.ReceiptBuilder) !void {
    if (builtin.os.tag != .windows) return error.Unsupported;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var backend: reg.Windows = .{ .gpa = gpa };
    try registry.integrateRegistry(backend.backend(), arena.allocator(), ctx, opts, rb);

    const exe = try std.mem.concat(arena.allocator(), u8, &.{ ctx.root, "\\app\\", registry.exe_name });
    const com = try shortcut.Com.init();
    defer com.deinit();
    inline for (.{ .{ opts.start_menu, known_folders.Folder.programs }, .{ opts.desktop_shortcut, known_folders.Folder.desktop } }) |s| {
        if (s[0]) {
            const dir = try known_folders.knownFolderPath(arena.allocator(), s[1]);
            const lnk = try std.fs.path.join(arena.allocator(), &.{ dir, shortcut_name });
            try shortcut.createShortcut(gpa, io, .{
                .path = lnk,
                .target = exe,
                .description = ctx.product.display_name,
                .icon_path = exe,
                .aumid = ctx.product.aumid,
            });
            try rb.add(.{ .file_created = .{ .path = lnk } });
        }
    }
    path_env.notifyAssocChanged();
    if (opts.add_to_path) path_env.broadcastEnvironmentChange();
}

/// Undoes a receipt's actions in reverse, best effort, then notifies the
/// shell. On Windows only.
pub fn unintegrate(gpa: Allocator, io: std.Io, actions: []const receipt_mod.Action, diag: ?*zg_core.report.Diagnostics) void {
    if (builtin.os.tag != .windows) return;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var backend: reg.Windows = .{ .gpa = gpa };
    registry.unintegrateActions(backend.backend(), arena.allocator(), io, actions, diag);
    path_env.notifyAssocChanged();
    path_env.broadcastEnvironmentChange();
}

test {
    std.testing.refAllDecls(@This());
    _ = bindings;
    _ = reg;
    _ = registry;
    _ = path_env;
    _ = shortcut;
    _ = known_folders;
}

test "registry: real HKCU subtree, integrate then unintegrate" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var rnd: [4]u8 = undefined;
    std.testing.io.random(&rnd);
    var backend: reg.Windows = .{ .gpa = gpa, .prefix = try std.fmt.allocPrint(a, "Software\\zigguro-test-{x}\\", .{std.mem.readInt(u32, &rnd, .little)}) };
    defer backend.deletePrefixTree();
    const b = backend.backend();
    _ = try b.createKey(path_env.key);
    try b.setValue(path_env.key, path_env.value_name, .{ .expand_sz = "%USERPROFILE%\\bin" });
    var rb: receipt_mod.ReceiptBuilder = .{ .arena = a };
    const ctx: registry.Context = .{ .root = "C:\\Users\\zïggürø\\zg", .version = "0.5.0", .install_date = "20261022" };
    try registry.integrateRegistry(b, a, ctx, .{}, &rb);
    try std.testing.expectEqualStrings("0.5.0", (try b.getValue(a, registry.uninstall_root ++ "dev.zigguro.zigguro", "DisplayVersion")).?.sz);
    try std.testing.expect((try b.getValue(a, "Software\\Classes\\.zig\\OpenWithProgids", registry.progid)).? == .none);
    try std.testing.expectEqual(@as(u32, 1), (try b.getValue(a, registry.uninstall_root ++ "dev.zigguro.zigguro", "NoModify")).?.dword);
    try std.testing.expectEqualStrings("%USERPROFILE%\\bin;C:\\Users\\zïggürø\\zg\\app", (try b.getValue(a, path_env.key, path_env.value_name)).?.expand_sz);
    registry.unintegrateActions(b, a, std.testing.io, rb.actions.items, null);
    try std.testing.expect(!b.keyExists(registry.progid_key));
    try std.testing.expect(!b.keyExists("Software\\Classes\\.zig"));
    try std.testing.expectEqualStrings("%USERPROFILE%\\bin", (try b.getValue(a, path_env.key, path_env.value_name)).?.expand_sz);
}
