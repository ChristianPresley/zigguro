//! `Command.open_dialog` on Windows: `IFileOpenDialog`/`IFileSaveDialog`
//! shown on a thread of its own (a single-threaded COM apartment), since
//! `Show` runs a modal loop until the user answers. `Job` owns a copy of
//! the request for that thread; `show` returns the picked paths as UTF-8
//! joined by NULs, the format of `Event.dialog_result`. Building the
//! filter specs and options is pure and tested on every OS.

const std = @import("std");
const builtin = @import("builtin");
const t = @import("bindings/types.zig");
const com = @import("com.zig");
const dialog = @import("../api/dialog.zig");

const is_windows = builtin.os.tag == .windows;

/// `HRESULT_FROM_WIN32(ERROR_CANCELLED)`: the user closed the dialog.
pub const E_CANCELLED: t.HRESULT = @bitCast(@as(u32, 0x800704C7));

/// The `FOS_*` options for `kind`, added to the dialog's defaults.
pub fn optionsFor(kind: dialog.DialogKind, defaults: u32) u32 {
    var o = defaults | com.IFileDialog.FOS_FORCEFILESYSTEM;
    switch (kind) {
        .open_files => o |= com.IFileDialog.FOS_ALLOWMULTISELECT,
        .open_directory => o |= com.IFileDialog.FOS_PICKFOLDERS,
        .open_file, .save_file => {},
    }
    return o;
}

/// `COMDLG_FILTERSPEC`s for `filters`, with each filter's patterns joined
/// by `;`. Strings live in `arena`.
pub fn filterSpecs(arena: std.mem.Allocator, filters: []const dialog.DialogFilter) ![]t.COMDLG_FILTERSPEC {
    const specs = try arena.alloc(t.COMDLG_FILTERSPEC, filters.len);
    for (filters, specs) |f, *s| {
        const joined = if (f.patterns.len == 0) "*.*" else try std.mem.join(arena, ";", f.patterns);
        s.* = .{ .pszName = try wide(arena, f.name), .pszSpec = try wide(arena, joined) };
    }
    return specs;
}

/// Splits a save dialog's `default_path` into its folder (or null) and
/// file name.
pub fn splitSavePath(path: []const u8) struct { folder: ?[]const u8, name: []const u8 } {
    const i = std.mem.lastIndexOfAny(u8, path, "\\/") orelse return .{ .folder = null, .name = path };
    return .{ .folder = if (i == 0) path[0..1] else path[0..i], .name = path[i + 1 ..] };
}

fn wide(arena: std.mem.Allocator, s: []const u8) ![:0]const u16 {
    return std.unicode.wtf8ToWtf16LeAllocZ(arena, s) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidUtf8,
    };
}

/// A dialog request copied for the dialog thread.
pub const Job = struct {
    arena: std.heap.ArenaAllocator,
    /// The request, with every string in `arena`.
    req: dialog.DialogRequest,
    /// The owner window, if the request named a live one.
    owner: ?t.HWND = null,

    /// Copies `req`.
    pub fn create(gpa: std.mem.Allocator, req: dialog.DialogRequest) error{OutOfMemory}!*Job {
        const j = try gpa.create(Job);
        j.* = .{ .arena = .init(gpa), .req = req };
        errdefer j.destroy(gpa);
        const a = j.arena.allocator();
        j.req.title = try a.dupe(u8, req.title);
        if (req.default_path) |p| j.req.default_path = try a.dupe(u8, p);
        const filters = try a.alloc(dialog.DialogFilter, req.filters.len);
        for (req.filters, filters) |f, *d| {
            const pats = try a.alloc([]const u8, f.patterns.len);
            for (f.patterns, pats) |p, *q| q.* = try a.dupe(u8, p);
            d.* = .{ .name = try a.dupe(u8, f.name), .patterns = pats };
        }
        j.req.filters = filters;
        return j;
    }

    /// Frees the copy.
    pub fn destroy(j: *Job, gpa: std.mem.Allocator) void {
        j.arena.deinit();
        gpa.destroy(j);
    }
};

/// What the user picked.
pub const Result = struct {
    /// NUL-separated UTF-8 paths (owned by the caller); empty if cancelled.
    paths: []u8,
    /// The dialog was cancelled or could not be shown.
    cancelled: bool,
};

/// Creates the dialog for `req` and applies options, filters, title and
/// starting folder; the caller releases it. Windows only.
pub fn prepare(arena: std.mem.Allocator, req: dialog.DialogRequest) !*com.IFileOpenDialog {
    const ole32 = @import("bindings/ole32.zig");
    const shell32 = @import("bindings/shell32.zig");
    const save = req.kind == .save_file;
    var p: ?*anyopaque = null;
    const hr = if (save)
        ole32.CoCreateInstance(&com.IFileDialog.clsid_save, null, ole32.CLSCTX_INPROC_SERVER, &com.IFileDialog.Vtbl.iid, &p)
    else
        ole32.CoCreateInstance(&com.IFileDialog.clsid_open, null, ole32.CLSCTX_INPROC_SERVER, &com.IFileOpenDialog.Vtbl.iid, &p);
    if (!t.succeeded(hr) or p == null) return error.Unsupported;
    // A save dialog is only used through its IFileDialog part.
    const dlg: *com.IFileOpenDialog = @ptrCast(@alignCast(p.?));
    errdefer _ = dlg.vtbl.base.Release(dlg);
    const vt = &dlg.vtbl.base;
    var opts: u32 = 0;
    _ = vt.GetOptions(dlg, &opts);
    _ = vt.SetOptions(dlg, optionsFor(req.kind, opts));
    if (req.filters.len > 0 and req.kind != .open_directory) {
        const specs = try filterSpecs(arena, req.filters);
        _ = vt.SetFileTypes(dlg, @intCast(specs.len), specs.ptr);
    }
    if (req.title.len > 0) _ = vt.SetTitle(dlg, try wide(arena, req.title));
    if (req.default_path) |path| {
        const parts: struct { folder: ?[]const u8, name: ?[]const u8 } = if (save) blk: {
            const s = splitSavePath(path);
            break :blk .{ .folder = s.folder, .name = s.name };
        } else .{ .folder = path, .name = null };
        if (parts.name) |n| if (n.len > 0) {
            _ = vt.SetFileName(dlg, try wide(arena, n));
        };
        if (parts.folder) |f| {
            var item: ?*anyopaque = null;
            if (t.succeeded(shell32.SHCreateItemFromParsingName(try wide(arena, f), null, &com.IShellItem.Vtbl.iid, &item)) and item != null) {
                const si: *com.IShellItem = @ptrCast(@alignCast(item.?));
                _ = vt.SetFolder(dlg, si);
                _ = si.vtbl.Release(si);
            }
        }
    }
    return dlg;
}

/// Shows the dialog for `job` and waits for the answer. Call on a thread
/// of its own; it enters a COM apartment for the duration. Windows only.
pub fn show(gpa: std.mem.Allocator, job: *Job) Result {
    const ole32 = @import("bindings/ole32.zig");
    const cancelled: Result = .{ .paths = &.{}, .cancelled = true };
    const init_hr = ole32.CoInitializeEx(null, ole32.COINIT_APARTMENTTHREADED | ole32.COINIT_DISABLE_OLE1DDE);
    defer if (t.succeeded(init_hr)) ole32.CoUninitialize();
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const dlg = prepare(scratch.allocator(), job.req) catch return cancelled;
    defer _ = dlg.vtbl.base.Release(dlg);
    const hr = dlg.vtbl.base.Show(dlg, job.owner);
    if (!t.succeeded(hr)) return cancelled;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (job.req.kind == .open_files) {
        var arr: ?*com.IShellItemArray = null;
        if (!t.succeeded(dlg.vtbl.GetResults(dlg, &arr)) or arr == null) return cancelled;
        defer _ = arr.?.vtbl.Release(arr.?);
        var n: t.DWORD = 0;
        _ = arr.?.vtbl.GetCount(arr.?, &n);
        for (0..n) |i| {
            var item: ?*com.IShellItem = null;
            if (!t.succeeded(arr.?.vtbl.GetItemAt(arr.?, @intCast(i), &item)) or item == null) continue;
            defer _ = item.?.vtbl.Release(item.?);
            appendPath(gpa, &out, item.?) catch return cancelled;
        }
    } else {
        var item: ?*com.IShellItem = null;
        if (!t.succeeded(dlg.vtbl.base.GetResult(dlg, &item)) or item == null) return cancelled;
        defer _ = item.?.vtbl.Release(item.?);
        appendPath(gpa, &out, item.?) catch return cancelled;
    }
    if (out.items.len == 0) return cancelled;
    const paths = out.toOwnedSlice(gpa) catch return cancelled;
    return .{ .paths = paths, .cancelled = false };
}

fn appendPath(gpa: std.mem.Allocator, out: *std.ArrayList(u8), item: *com.IShellItem) !void {
    const ole32 = @import("bindings/ole32.zig");
    var name: ?t.LPWSTR = null;
    if (!t.succeeded(item.vtbl.GetDisplayName(item, com.IShellItem.SIGDN_FILESYSPATH, &name)) or name == null) return;
    defer ole32.CoTaskMemFree(name.?);
    const units = std.mem.sliceTo(name.?, 0);
    if (out.items.len > 0) try out.append(gpa, 0);
    const start = out.items.len;
    try out.resize(gpa, start + units.len * 3);
    const n = std.unicode.wtf16LeToWtf8(out.items[start..], units);
    out.shrinkRetainingCapacity(start + n);
}

const testing = std.testing;

test "options by dialog kind" {
    const f = com.IFileDialog;
    try testing.expectEqual(f.FOS_FORCEFILESYSTEM | 0x8, optionsFor(.open_file, 0x8));
    try testing.expect(optionsFor(.open_files, 0) & f.FOS_ALLOWMULTISELECT != 0);
    try testing.expect(optionsFor(.open_directory, 0) & f.FOS_PICKFOLDERS != 0);
    try testing.expect(optionsFor(.save_file, 0) & (f.FOS_PICKFOLDERS | f.FOS_ALLOWMULTISELECT) == 0);
}

test "COMDLG_FILTERSPEC building from filters" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const specs = try filterSpecs(arena.allocator(), &.{
        .{ .name = "Zig sources", .patterns = &.{ "*.zig", "*.zon" } },
        .{ .name = "Everything", .patterns = &.{} },
    });
    try testing.expectEqual(@as(usize, 2), specs.len);
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    try testing.expectEqualSlices(u16, L("Zig sources"), std.mem.sliceTo(specs[0].pszName, 0));
    try testing.expectEqualSlices(u16, L("*.zig;*.zon"), std.mem.sliceTo(specs[0].pszSpec, 0));
    try testing.expectEqualSlices(u16, L("*.*"), std.mem.sliceTo(specs[1].pszSpec, 0));
}

test "save path split and request copy" {
    const s = splitSavePath("C:\\work\\notes.md");
    try testing.expectEqualStrings("C:\\work", s.folder.?);
    try testing.expectEqualStrings("notes.md", s.name);
    try testing.expectEqual(@as(?[]const u8, null), splitSavePath("notes.md").folder);

    var title = "Open".*;
    const j = try Job.create(testing.allocator, .{ .request = 7, .kind = .open_files, .title = &title, .filters = &.{.{ .name = "Zig", .patterns = &.{"*.zig"} }} });
    defer j.destroy(testing.allocator);
    title[0] = 'X';
    try testing.expectEqualStrings("Open", j.req.title);
    try testing.expectEqualStrings("*.zig", j.req.filters[0].patterns[0]);
}

test "vtable offsets follow shobjidl_core.h" {
    const V = com.IFileOpenDialog.Vtbl;
    const slot = @sizeOf(usize);
    try testing.expectEqual(3 * slot, @offsetOf(V, "base") + @offsetOf(@FieldType(V, "base"), "Show"));
    try testing.expectEqual(9 * slot, @offsetOf(@FieldType(V, "base"), "SetOptions"));
    try testing.expectEqual(17 * slot, @offsetOf(@FieldType(V, "base"), "SetTitle"));
    try testing.expectEqual(20 * slot, @offsetOf(@FieldType(V, "base"), "GetResult"));
    try testing.expectEqual(27 * slot, @offsetOf(V, "GetResults"));
}

test "dialog objects accept the setup calls" {
    if (!is_windows) return error.SkipZigTest;
    const ole32 = @import("bindings/ole32.zig");
    const hr = ole32.CoInitializeEx(null, ole32.COINIT_APARTMENTTHREADED);
    defer if (t.succeeded(hr)) ole32.CoUninitialize();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for ([_]dialog.DialogKind{ .open_file, .open_files, .open_directory, .save_file }) |kind| {
        const dlg = try prepare(arena.allocator(), .{ .request = 1, .kind = kind, .title = "zg", .default_path = "C:\\windows\\win.ini", .filters = &.{.{ .name = "Text", .patterns = &.{"*.txt"} }} });
        var opts: u32 = 0;
        try testing.expect(t.succeeded(dlg.vtbl.base.GetOptions(dlg, &opts)));
        try testing.expect(opts & com.IFileDialog.FOS_FORCEFILESYSTEM != 0);
        _ = dlg.vtbl.base.Release(dlg);
    }
}
