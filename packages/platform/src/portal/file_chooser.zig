//! `org.freedesktop.portal.FileChooser`: OpenFile and SaveFile for
//! `Command.open_dialog`. The response's `uris` become absolute paths.

const std = @import("std");
const request = @import("request.zig");
const dialog = @import("../api/dialog.zig");
const Bus = @import("../dbus/conn.zig").Bus;
const marshal = @import("../dbus/marshal.zig");
const Value = @import("../dbus/variant.zig").Value;

/// The interface name.
pub const interface = "org.freedesktop.portal.FileChooser";

/// One `a{sv}` option.
pub const Option = struct { []const u8, Value };

/// The `filters` value: `a(sa(us))` with glob patterns (type 0).
pub fn filtersValue(arena: std.mem.Allocator, filters: []const dialog.DialogFilter) !Value {
    const items = try arena.alloc(Value, filters.len);
    for (filters, items) |f, *item| {
        const pats = try arena.alloc(Value, f.patterns.len);
        for (f.patterns, pats) |p, *pv| {
            const fields = try arena.dupe(Value, &.{ .{ .u32 = 0 }, .{ .string = p } });
            pv.* = .{ .structure = fields };
        }
        const fields = try arena.dupe(Value, &.{ .{ .string = f.name }, .{ .array = .{ .elem_sig = "(us)", .items = pats } } });
        item.* = .{ .structure = fields };
    }
    return .{ .array = .{ .elem_sig = "(sa(us))", .items = items } };
}

fn bytesValue(arena: std.mem.Allocator, s: []const u8) !Value {
    // Paths travel as NUL-terminated byte arrays.
    const z = try arena.alloc(u8, s.len + 1);
    @memcpy(z[0..s.len], s);
    z[s.len] = 0;
    return .{ .array = .{ .elem_sig = "y", .bytes = z } };
}

/// The method and options for `req`.
pub fn buildCall(arena: std.mem.Allocator, req: dialog.DialogRequest, token: []const u8) !struct { method: []const u8, options: []const Option } {
    var opts: std.ArrayList(Option) = .empty;
    try opts.append(arena, .{ "handle_token", .{ .string = token } });
    try opts.append(arena, .{ "modal", .{ .boolean = req.parent != null } });
    const save = req.kind == .save_file;
    if (req.kind == .open_files) try opts.append(arena, .{ "multiple", .{ .boolean = true } });
    if (req.kind == .open_directory) try opts.append(arena, .{ "directory", .{ .boolean = true } });
    if (req.filters.len > 0) try opts.append(arena, .{ "filters", try filtersValue(arena, req.filters) });
    if (req.default_path) |p| {
        if (save) {
            const dir = std.fs.path.dirname(p);
            const base = std.fs.path.basename(p);
            if (dir) |d| try opts.append(arena, .{ "current_folder", try bytesValue(arena, d) });
            if (base.len > 0) try opts.append(arena, .{ "current_name", .{ .string = base } });
        } else try opts.append(arena, .{ "current_folder", try bytesValue(arena, p) });
    }
    return .{ .method = if (save) "SaveFile" else "OpenFile", .options = opts.items };
}

/// Opens the dialog. `parent` is a window handle (`wayland:...`,
/// `x11:...` or ""). The callback gets the response; read paths from it
/// with `paths`. Free the returned request after the callback ran.
pub fn open(gpa: std.mem.Allocator, bus: *Bus, req: dialog.DialogRequest, parent: []const u8, cb: request.Callback) !*request.Request {
    const r = try request.Request.begin(gpa, bus, cb);
    errdefer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const call = try buildCall(arena.allocator(), req, r.token());
    try bus.callAsync(request.destination, request.object_path, interface, call.method, "ssa{sv}", .{ parent, req.title, call.options }, r.replyHandler());
    return r;
}

/// Appends the response's `uris` to `out` as NUL-separated absolute
/// paths; non-file URIs are skipped. Returns how many were added.
pub fn paths(resp: *const request.Response, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !usize {
    const uris = resp.get("uris") orelse return 0;
    if (uris != .array) return 0;
    var n: usize = 0;
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    for (uris.array.items) |u| {
        const s = u.asString() orelse continue;
        const p = request.fileUriToPath(&buf, s) orelse continue;
        try out.appendSlice(gpa, p);
        try out.append(gpa, 0);
        n += 1;
    }
    return n;
}

const testing = std.testing;

test "filters encoding golden bytes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try filtersValue(arena.allocator(), &.{.{ .name = "Zig", .patterns = &.{"*.zig"} }});
    const want = [_]u8{ 30, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 'Z', 'i', 'g', 0, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5, 0, 0, 0, '*', '.', 'z', 'i', 'g', 0 };
    var e2: marshal.Encoder = .init(testing.allocator, 0);
    defer e2.deinit();
    try @import("../dbus/variant.zig").encodeValue(&e2, v);
    try testing.expectEqualSlices(u8, &want, e2.buf.items);
}

test "options for open, multiple, directory and save" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const multi = try buildCall(a, .{ .request = 1, .kind = .open_files, .default_path = "/tmp" }, "zg1");
    try testing.expectEqualStrings("OpenFile", multi.method);
    try testing.expectEqualStrings("multiple", multi.options[2][0]);
    try testing.expectEqualStrings("current_folder", multi.options[3][0]);
    try testing.expectEqualSlices(u8, "/tmp\x00", multi.options[3][1].array.bytes);
    const dir = try buildCall(a, .{ .request = 2, .kind = .open_directory }, "zg2");
    try testing.expectEqualStrings("directory", dir.options[2][0]);
    const save = try buildCall(a, .{ .request = 3, .kind = .save_file, .default_path = "/home/u/notes.md" }, "zg3");
    try testing.expectEqualStrings("SaveFile", save.method);
    try testing.expectEqualStrings("current_name", save.options[3][0]);
    try testing.expectEqualStrings("notes.md", save.options[3][1].string);
}
