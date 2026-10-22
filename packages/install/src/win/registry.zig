//! Registry integration (E17.F02.S01.T02): the HKCU registrations of
//! E17.F02's table, written through a recording `RegWriter` so the receipt
//! lists every key it created and every value it set, with the previous
//! value; and `unintegrate`, which replays a receipt in reverse.
//!
//! Default handlers stay the user's choice: an extension gets only an
//! `OpenWithProgids` entry, never `(Default)`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zg_core = @import("zg_core");
const zg_release = @import("zg_release");
const receipt_mod = @import("../receipt.zig");
const reg = @import("reg.zig");
const path_env = @import("path_env.zig");

const RegValue = receipt_mod.RegValue;
const Action = receipt_mod.Action;
const ReceiptBuilder = receipt_mod.ReceiptBuilder;
const InstallOptions = receipt_mod.InstallOptions;

pub const progid = "Zigguro.SourceFile";
pub const exe_name = "zigguro.exe";
pub const setup_name = "zigguro-setup.exe";
pub const uninstall_root = "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\";
pub const app_paths_key = "Software\\Microsoft\\Windows\\CurrentVersion\\App Paths\\" ++ exe_name;
pub const applications_key = "Software\\Classes\\Applications\\" ++ exe_name;
pub const progid_key = "Software\\Classes\\" ++ progid;
pub const folder_keys = [_][]const u8{
    "Software\\Classes\\Directory\\shell\\zigguro",
    "Software\\Classes\\Directory\\Background\\shell\\zigguro",
};

/// What the registrations say about this install.
pub const Context = struct {
    /// The install root (`<root>\app\zigguro.exe` is the app).
    root: []const u8,
    version: []const u8,
    /// `YYYYMMDD`, local date.
    install_date: []const u8,
    estimated_size_kib: u32 = 0,
    product: zg_release.product_info.Product = zg_release.product,
};

/// One planned write: a key (`name == null`) or a value.
pub const Entry = struct {
    /// The product-owned key this entry lives under: the receipt fallback
    /// treats it and every key between it and `path` as ours.
    owned_root: []const u8,
    path: []const u8,
    name: ?[]const u8 = null,
    value: RegValue = .none,
};

/// Every registration for `opts`, in write order. Pure: the same inputs
/// give the same list on every OS.
pub fn plan(arena: Allocator, ctx: Context, opts: InstallOptions) Allocator.Error![]const Entry {
    var out: std.ArrayList(Entry) = .empty;
    const p = ctx.product;
    const exe = try std.mem.concat(arena, u8, &.{ ctx.root, "\\app\\", exe_name });
    const setup = try std.mem.concat(arena, u8, &.{ ctx.root, "\\app\\", setup_name });
    const q = struct {
        fn quote(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
            return std.mem.concat(a, u8, &.{ "\"", s, "\"" });
        }
    }.quote;
    const open_cmd = try std.mem.concat(arena, u8, &.{ try q(arena, exe), " \"%1\"" });

    const un = try std.mem.concat(arena, u8, &.{ uninstall_root, p.app_id });
    const uninstall_cmd = try std.mem.concat(arena, u8, &.{ try q(arena, setup), " --uninstall" });
    const uv = [_]struct { []const u8, RegValue }{
        .{ "DisplayName", .{ .sz = p.display_name } },
        .{ "DisplayVersion", .{ .sz = ctx.version } },
        .{ "Publisher", .{ .sz = p.publisher } },
        .{ "DisplayIcon", .{ .sz = try std.mem.concat(arena, u8, &.{ exe, ",0" }) } },
        .{ "InstallLocation", .{ .sz = ctx.root } },
        .{ "InstallDate", .{ .sz = ctx.install_date } },
        .{ "UninstallString", .{ .sz = uninstall_cmd } },
        .{ "QuietUninstallString", .{ .sz = try std.mem.concat(arena, u8, &.{ uninstall_cmd, " --silent" }) } },
        .{ "NoModify", .{ .dword = 1 } },
        .{ "NoRepair", .{ .dword = 1 } },
        .{ "EstimatedSize", .{ .dword = ctx.estimated_size_kib } },
        .{ "URLInfoAbout", .{ .sz = p.homepage } },
        .{ "HelpLink", .{ .sz = p.issues_url } },
    };
    try out.append(arena, .{ .owned_root = un, .path = un });
    for (uv) |v| try out.append(arena, .{ .owned_root = un, .path = un, .name = v[0], .value = v[1] });

    try out.append(arena, .{ .owned_root = app_paths_key, .path = app_paths_key });
    try out.append(arena, .{ .owned_root = app_paths_key, .path = app_paths_key, .name = "", .value = .{ .sz = exe } });

    if (opts.open_with) {
        const app = applications_key;
        try out.append(arena, .{ .owned_root = app, .path = app });
        try out.append(arena, .{ .owned_root = app, .path = app, .name = "FriendlyAppName", .value = .{ .sz = p.display_name } });
        const types = app ++ "\\SupportedTypes";
        try out.append(arena, .{ .owned_root = app, .path = types });
        for (p.file_associations) |fa| try out.append(arena, .{ .owned_root = app, .path = types, .name = fa.ext, .value = .{ .sz = "" } });
        const app_cmd = app ++ "\\shell\\open\\command";
        try out.append(arena, .{ .owned_root = app, .path = app_cmd });
        try out.append(arena, .{ .owned_root = app, .path = app_cmd, .name = "", .value = .{ .sz = open_cmd } });

        const type_name = try std.fmt.allocPrint(arena, "{s} source file", .{p.display_name});
        try out.append(arena, .{ .owned_root = progid_key, .path = progid_key });
        try out.append(arena, .{ .owned_root = progid_key, .path = progid_key, .name = "", .value = .{ .sz = type_name } });
        try out.append(arena, .{ .owned_root = progid_key, .path = progid_key, .name = "FriendlyTypeName", .value = .{ .sz = type_name } });
        try out.append(arena, .{ .owned_root = progid_key, .path = progid_key, .name = "AppUserModelID", .value = .{ .sz = p.aumid } });
        const icon = progid_key ++ "\\DefaultIcon";
        try out.append(arena, .{ .owned_root = progid_key, .path = icon });
        try out.append(arena, .{ .owned_root = progid_key, .path = icon, .name = "", .value = .{ .sz = try std.mem.concat(arena, u8, &.{ try q(arena, exe), ",0" }) } });
        const cmd = progid_key ++ "\\shell\\open\\command";
        try out.append(arena, .{ .owned_root = progid_key, .path = cmd });
        try out.append(arena, .{ .owned_root = progid_key, .path = cmd, .name = "", .value = .{ .sz = open_cmd } });

        for (p.file_associations) |fa| {
            const k = try std.mem.concat(arena, u8, &.{ "Software\\Classes\\", fa.ext, "\\OpenWithProgids" });
            // The extension key may exist already; only OpenWithProgids
            // (and the extension key, when we create it) is ours.
            const ext_key = k[0 .. k.len - "\\OpenWithProgids".len];
            try out.append(arena, .{ .owned_root = ext_key, .path = k });
            try out.append(arena, .{ .owned_root = ext_key, .path = k, .name = progid, .value = .none });
        }
    }

    if (opts.folder_context_menu) {
        const folder_cmd = try std.mem.concat(arena, u8, &.{ try q(arena, exe), " \"%V\"" });
        const label = try std.fmt.allocPrint(arena, "Open with {s}", .{p.display_name});
        for (folder_keys) |k| {
            try out.append(arena, .{ .owned_root = k, .path = k });
            try out.append(arena, .{ .owned_root = k, .path = k, .name = "", .value = .{ .sz = label } });
            try out.append(arena, .{ .owned_root = k, .path = k, .name = "Icon", .value = .{ .sz = exe } });
            const c = try std.mem.concat(arena, u8, &.{ k, "\\command" });
            try out.append(arena, .{ .owned_root = k, .path = c });
            try out.append(arena, .{ .owned_root = k, .path = c, .name = "", .value = .{ .sz = folder_cmd } });
        }
    }
    return out.items;
}

/// Writes keys and values, recording what changed.
pub const RegWriter = struct {
    backend: reg.Backend,
    receipt: *ReceiptBuilder,
    arena: Allocator,

    /// Creates `path` and its parents, recording each key that did not
    /// exist (parents first, so reverse order deletes children first).
    pub fn ensureKey(w: *RegWriter, path: []const u8) !void {
        var end = std.mem.indexOfScalar(u8, path, '\\') orelse path.len;
        while (true) {
            if (try w.backend.createKey(path[0..end])) try w.receipt.add(.{ .reg_key_created = .{ .path = path[0..end] } });
            if (end == path.len) break;
            end = std.mem.indexOfScalarPos(u8, path, end + 1, '\\') orelse path.len;
        }
    }

    /// Sets a value, recording its previous value (or null).
    pub fn setValue(w: *RegWriter, path: []const u8, name: []const u8, v: RegValue) !void {
        const previous = try w.backend.getValue(w.arena, path, name);
        try w.receipt.add(.{ .reg_value_set = .{ .path = path, .name = name, .previous = previous } });
        try w.backend.setValue(path, name, v);
    }
};

/// Writes every registration of `plan` and, with `opts.add_to_path`, the
/// PATH entry `<root>\app`.
pub fn integrateRegistry(b: reg.Backend, arena: Allocator, ctx: Context, opts: InstallOptions, rb: *ReceiptBuilder) !void {
    var w: RegWriter = .{ .backend = b, .receipt = rb, .arena = arena };
    for (try plan(arena, ctx, opts)) |e| {
        if (e.name) |n| try w.setValue(e.path, n, e.value) else try w.ensureKey(e.path);
    }
    if (opts.add_to_path) {
        const dir = try std.mem.concat(arena, u8, &.{ ctx.root, "\\app" });
        try w.ensureKey(path_env.key);
        if (try path_env.addUserPathEntry(b, arena, dir)) try rb.add(.{ .path_entry_added = .{ .dir = dir } });
    }
}

/// Updates the Apps & features version and size after an update swap.
pub fn updateDisplayVersion(b: reg.Backend, app_id: []const u8, version: []const u8, estimated_size_kib: u32) !void {
    var buf: [256]u8 = undefined;
    const un = try std.fmt.bufPrint(&buf, "{s}{s}", .{ uninstall_root, app_id });
    if (!b.keyExists(un)) return;
    try b.setValue(un, "DisplayVersion", .{ .sz = version });
    try b.setValue(un, "EstimatedSize", .{ .dword = estimated_size_kib });
}

/// Undoes `actions` in reverse: values are restored or deleted, keys we
/// created are deleted when nothing else lives in them, the PATH entry is
/// removed and files are deleted. Best effort: failures go to `diag` and
/// the rest still runs.
pub fn unintegrateActions(b: reg.Backend, arena: Allocator, io: std.Io, actions: []const Action, diag: ?*zg_core.report.Diagnostics) void {
    var i = actions.len;
    while (i > 0) {
        i -= 1;
        undo(b, arena, io, actions[i]) catch |err| if (diag) |d| d.add(.warn, "uninstall: {t} undoing {t}", .{ err, actions[i] });
    }
}

fn undo(b: reg.Backend, arena: Allocator, io: std.Io, a: Action) !void {
    switch (a) {
        .reg_value_set => |v| if (v.previous) |p| {
            _ = try b.createKey(v.path);
            try b.setValue(v.path, v.name, p);
        } else try b.deleteValue(v.path, v.name),
        .reg_key_created => |k| if (!try b.deleteKeyIfEmpty(k.path)) return error.KeyNotEmpty,
        .path_entry_added => |p| _ = try path_env.removeUserPathEntry(b, arena, p.dir),
        .file_created, .desktop_file, .symlink => |f| std.Io.Dir.cwd().deleteFile(io, f.path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        },
    }
}

/// The actions an install with `opts` would have recorded, for a missing
/// or corrupt receipt: every product-owned key and value, as if each was
/// new. Deleting only empty keys keeps anything else that lives there.
pub fn fallbackActions(arena: Allocator, ctx: Context, opts: InstallOptions, shortcut_paths: []const []const u8) ![]const Action {
    var out: std.ArrayList(Action) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (try plan(arena, ctx, opts)) |e| {
        if (e.name) |n| {
            try out.append(arena, .{ .reg_value_set = .{ .path = e.path, .name = n, .previous = null } });
            continue;
        }
        var end = e.owned_root.len;
        while (true) {
            const k = e.path[0..end];
            if (!(try seen.getOrPut(arena, k)).found_existing) try out.append(arena, .{ .reg_key_created = .{ .path = k } });
            if (end == e.path.len) break;
            end = std.mem.indexOfScalarPos(u8, e.path, end + 1, '\\') orelse e.path.len;
        }
    }
    if (opts.add_to_path) try out.append(arena, .{ .reg_key_created = .{ .path = path_env.key } });
    if (opts.add_to_path) try out.append(arena, .{ .path_entry_added = .{ .dir = try std.mem.concat(arena, u8, &.{ ctx.root, "\\app" }) } });
    for (shortcut_paths) |s| try out.append(arena, .{ .file_created = .{ .path = s } });
    return out.items;
}

const testing = std.testing;

/// Keys every Windows profile has.
fn baseKeys(b: reg.Backend) !void {
    _ = try b.createKey("Software\\Classes\\Directory\\Background\\shell");
    _ = try b.createKey("Software\\Classes\\Directory\\shell");
    _ = try b.createKey("Software\\Classes\\Applications");
    _ = try b.createKey("Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall");
    _ = try b.createKey("Software\\Microsoft\\Windows\\CurrentVersion\\App Paths");
}

fn testCtx() Context {
    return .{ .root = "C:\\Users\\zïggürø\\AppData\\Local\\Programs\\zigguro", .version = "0.5.0", .install_date = "20261022", .estimated_size_kib = 40960 };
}

test "registry: plan never writes an extension's default handler" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const entries = try plan(arena.allocator(), testCtx(), .{});
    var open_with: usize = 0;
    for (entries) |e| {
        if (std.mem.startsWith(u8, e.path, "Software\\Classes\\.")) {
            try testing.expect(std.mem.endsWith(u8, e.path, "\\OpenWithProgids"));
            if (e.name) |n| {
                try testing.expectEqualStrings(progid, n);
                open_with += 1;
            }
        }
        if (e.name) |n| if (n.len == 0) try testing.expect(!std.mem.startsWith(u8, e.path, "Software\\Classes\\."));
    }
    try testing.expectEqual(zg_release.product.file_associations.len, open_with);
    const none = try plan(arena.allocator(), testCtx(), .{ .open_with = false, .folder_context_menu = false });
    for (none) |e| try testing.expect(!std.mem.startsWith(u8, e.path, "Software\\Classes"));
}

test "registry: ensureKey records only new keys" {
    var m: reg.Memory = .init(testing.allocator);
    defer m.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try m.backend().createKey("Software\\Classes\\Directory\\shell");
    var rb: ReceiptBuilder = .{ .arena = a };
    var w: RegWriter = .{ .backend = m.backend(), .receipt = &rb, .arena = a };
    try w.ensureKey(folder_keys[0] ++ "\\command");
    try w.ensureKey(folder_keys[0] ++ "\\command");
    try testing.expectEqual(@as(usize, 2), rb.actions.items.len);
    try testing.expectEqualStrings(folder_keys[0], rb.actions.items[0].reg_key_created.path);
}

test "registry: setValue records previous and unintegrate restores it" {
    var m: reg.Memory = .init(testing.allocator);
    defer m.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const b = m.backend();
    try baseKeys(b);
    // Another app already has an Applications entry value we overwrite.
    _ = try b.createKey(applications_key);
    try b.setValue(applications_key, "FriendlyAppName", .{ .sz = "old" });
    const before = try m.dump(testing.allocator);
    defer testing.allocator.free(before);
    var rb: ReceiptBuilder = .{ .arena = a };
    try integrateRegistry(b, a, testCtx(), .{}, &rb);
    try testing.expectEqualStrings("zigguro", (try b.getValue(a, applications_key, "FriendlyAppName")).?.sz);
    unintegrateActions(b, a, testing.io, rb.actions.items, null);
    const after = try m.dump(testing.allocator);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
}

test "integrate/unintegrate: registry snapshot equal before and after" {
    var m: reg.Memory = .init(testing.allocator);
    defer m.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const b = m.backend();
    try baseKeys(b);
    _ = try b.createKey("Software\\Classes\\.txt\\OpenWithProgids");
    try b.setValue("Software\\Classes\\.txt\\OpenWithProgids", "Notepad.txt", .none);
    _ = try b.createKey(path_env.key);
    try b.setValue(path_env.key, path_env.value_name, .{ .expand_sz = "%USERPROFILE%\\bin" });
    const before = try m.dump(testing.allocator);
    defer testing.allocator.free(before);
    var rb: ReceiptBuilder = .{ .arena = a };
    try integrateRegistry(b, a, testCtx(), .{}, &rb);
    try testing.expect(b.keyExists(progid_key ++ "\\shell\\open\\command"));
    unintegrateActions(b, a, testing.io, rb.actions.items, null);
    const after = try m.dump(testing.allocator);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
}

test "registry: unintegrate leaves foreign subkeys" {
    var m: reg.Memory = .init(testing.allocator);
    defer m.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const b = m.backend();
    var rb: ReceiptBuilder = .{ .arena = a };
    try integrateRegistry(b, a, testCtx(), .{}, &rb);
    // Something else adds a verb under our ProgID after install.
    _ = try b.createKey(progid_key ++ "\\shell\\edit");
    var diag: zg_core.report.Diagnostics = .init(testing.allocator);
    defer diag.deinit();
    unintegrateActions(b, a, testing.io, rb.actions.items, &diag);
    try testing.expect(b.keyExists(progid_key ++ "\\shell\\edit"));
    try testing.expect(!b.keyExists(progid_key ++ "\\shell\\open"));
    try testing.expect(diag.messages.items.len > 0);
}

test "uninstall: fallback action list equals integrate's list" {
    var m: reg.Memory = .init(testing.allocator);
    defer m.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const b = m.backend();
    try baseKeys(b);
    const before = try m.dump(testing.allocator);
    defer testing.allocator.free(before);
    var rb: ReceiptBuilder = .{ .arena = a };
    try integrateRegistry(b, a, testCtx(), .{}, &rb);
    // Without the receipt, the fallback list undoes the same install.
    const fb = try fallbackActions(a, testCtx(), .{}, &.{});
    for (rb.actions.items) |act| switch (act) {
        .reg_key_created => |k| {
            var found = false;
            for (fb) |f| if (f == .reg_key_created and std.ascii.eqlIgnoreCase(f.reg_key_created.path, k.path)) {
                found = true;
            };
            try testing.expect(found);
        },
        else => {},
    };
    unintegrateActions(b, a, testing.io, fb, null);
    const after = try m.dump(testing.allocator);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
}
