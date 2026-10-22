//! The install receipt (E17.F02.S01.T02): every registry key, value, PATH
//! entry and file an install created or changed, in execution order, with
//! the previous value of anything it overwrote. Uninstall replays it in
//! reverse. Stored as `<root>/receipt.zon`, written through a temporary
//! file and a rename.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const file_name = "receipt.zon";
/// Largest receipt read back.
pub const max_bytes = 1024 * 1024;

pub const Hive = enum { hkcu };

/// A registry value as the installer writes it. `none` is REG_NONE with
/// empty data (OpenWithProgids entries).
pub const RegValue = union(enum) {
    sz: []const u8,
    expand_sz: []const u8,
    dword: u32,
    none,

    pub fn eql(a: RegValue, b: RegValue) bool {
        return switch (a) {
            .sz => |s| b == .sz and std.mem.eql(u8, s, b.sz),
            .expand_sz => |s| b == .expand_sz and std.mem.eql(u8, s, b.expand_sz),
            .dword => |d| b == .dword and d == b.dword,
            .none => b == .none,
        };
    }
};

pub const InstallOptions = struct {
    add_to_path: bool = true,
    start_menu: bool = true,
    desktop_shortcut: bool = false,
    open_with: bool = true,
    folder_context_menu: bool = true,
};

/// A file an install created.
pub const FilePath = struct { path: []const u8 };

pub const Action = union(enum) {
    /// Deleted on uninstall when it holds nothing else.
    reg_key_created: struct { hive: Hive = .hkcu, path: []const u8 },
    /// Restored to `previous`, or deleted when it had none.
    reg_value_set: struct { hive: Hive = .hkcu, path: []const u8, name: []const u8, previous: ?RegValue },
    /// Exactly this entry is removed from the user's PATH.
    path_entry_added: struct { dir: []const u8 },
    /// Shortcut files.
    file_created: FilePath,
    /// Linux (E17.F03).
    desktop_file: FilePath,
    /// Linux (E17.F03).
    symlink: FilePath,
};

pub const Receipt = struct {
    schema: u32 = 1,
    app_id: []const u8,
    version: []const u8,
    root: []const u8,
    installed_at_unix: i64,
    options: InstallOptions = .{},
    /// In execution order.
    actions: []const Action = &.{},

    /// Reads `<root>/receipt.zon`. Allocations go to `arena`.
    pub fn load(arena: Allocator, io: Io, root: Io.Dir) !Receipt {
        const text = try root.readFileAllocOptions(io, file_name, arena, .limited(max_bytes), .of(u8), 0);
        return std.zon.parse.fromSliceAlloc(Receipt, arena, text, null, .{}) catch error.CorruptReceipt;
    }

    /// Writes `<root>/receipt.zon` through `receipt.zon.tmp`.
    pub fn store(r: *const Receipt, gpa: Allocator, io: Io, root: Io.Dir) !void {
        var aw: Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try std.zon.stringify.serialize(r.*, .{}, &aw.writer);
        try aw.writer.writeByte('\n');
        try root.writeFile(io, .{ .sub_path = file_name ++ ".tmp", .data = aw.written() });
        try root.rename(file_name ++ ".tmp", root, file_name, io);
    }
};

/// Collects actions as they happen. Strings are copied into `arena`.
pub const ReceiptBuilder = struct {
    arena: Allocator,
    actions: std.ArrayList(Action) = .empty,

    pub fn add(rb: *ReceiptBuilder, a: Action) Allocator.Error!void {
        const d = struct {
            fn s(ar: Allocator, x: []const u8) Allocator.Error![]const u8 {
                return ar.dupe(u8, x);
            }
        }.s;
        const copy: Action = switch (a) {
            .reg_key_created => |k| .{ .reg_key_created = .{ .hive = k.hive, .path = try d(rb.arena, k.path) } },
            .reg_value_set => |v| .{ .reg_value_set = .{
                .hive = v.hive,
                .path = try d(rb.arena, v.path),
                .name = try d(rb.arena, v.name),
                .previous = if (v.previous) |p| try dupeValue(rb.arena, p) else null,
            } },
            .path_entry_added => |p| .{ .path_entry_added = .{ .dir = try d(rb.arena, p.dir) } },
            .file_created => |p| .{ .file_created = .{ .path = try d(rb.arena, p.path) } },
            .desktop_file => |p| .{ .desktop_file = .{ .path = try d(rb.arena, p.path) } },
            .symlink => |p| .{ .symlink = .{ .path = try d(rb.arena, p.path) } },
        };
        try rb.actions.append(rb.arena, copy);
    }
};

pub fn dupeValue(arena: Allocator, v: RegValue) Allocator.Error!RegValue {
    return switch (v) {
        .sz => |s| .{ .sz = try arena.dupe(u8, s) },
        .expand_sz => |s| .{ .expand_sz = try arena.dupe(u8, s) },
        .dword, .none => v,
    };
}

const testing = std.testing;

test "receipt: zon roundtrip" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var rb: ReceiptBuilder = .{ .arena = a };
    try rb.add(.{ .reg_key_created = .{ .path = "Software\\Classes\\Zigguro.SourceFile" } });
    try rb.add(.{ .reg_value_set = .{ .path = "Software\\Classes\\.zig\\OpenWithProgids", .name = "Zigguro.SourceFile", .previous = null } });
    try rb.add(.{ .reg_value_set = .{ .path = "Environment", .name = "Path", .previous = .{ .expand_sz = "%USERPROFILE%\\bin" } } });
    try rb.add(.{ .reg_value_set = .{ .path = "X", .name = "N", .previous = .{ .dword = 7 } } });
    try rb.add(.{ .reg_value_set = .{ .path = "X", .name = "E", .previous = .none } });
    try rb.add(.{ .path_entry_added = .{ .dir = "C:\\Users\\zïggürø\\app" } });
    try rb.add(.{ .file_created = .{ .path = "C:\\Start\\zigguro.lnk" } });
    const r: Receipt = .{ .app_id = "dev.zigguro.zigguro", .version = "0.5.0", .root = "C:\\zg", .installed_at_unix = 1, .options = .{ .desktop_shortcut = true }, .actions = rb.actions.items };
    try r.store(testing.allocator, io, tmp.dir);
    const back = try Receipt.load(a, io, tmp.dir);
    try testing.expectEqual(@as(usize, 7), back.actions.len);
    try testing.expect(back.options.desktop_shortcut);
    try testing.expectEqualStrings("%USERPROFILE%\\bin", back.actions[2].reg_value_set.previous.?.expand_sz);
    try testing.expect(back.actions[1].reg_value_set.previous == null);
    try testing.expectEqual(@as(u32, 7), back.actions[3].reg_value_set.previous.?.dword);
    try testing.expect(back.actions[4].reg_value_set.previous.? == .none);
    try testing.expectEqualStrings("C:\\Users\\zïggürø\\app", back.actions[5].path_entry_added.dir);

    try tmp.dir.writeFile(io, .{ .sub_path = file_name, .data = ".{ .schema = " });
    try testing.expectError(error.CorruptReceipt, Receipt.load(a, io, tmp.dir));
}
