//! hello_zig: a ZEP extension written with zg_ext_sdk. It registers
//! `hello.say` and `hello.count`, shows the count in a tree view, and
//! decorates every `TODO` in open documents. Build with
//! `zig build examples` in packages/config.

const std = @import("std");
const zg_core = @import("zg_core");
const sdk = @import("zg_ext_sdk");

const Extension = sdk.Extension;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

/// Extension state; handlers run concurrently, so it is guarded.
var mutex: std.Io.Mutex = .init;
var count: u32 = 0;
var docs: std.StringHashMapUnmanaged([]u8) = .empty;
var gpa: Allocator = undefined;
var io: std.Io = undefined;

pub fn main(min: std.process.Init.Minimal) !u8 {
    var rt: zg_core.Runtime = undefined;
    try rt.init(min, .{});
    defer _ = rt.deinit();
    gpa = rt.gpa;
    io = rt.io;

    const ext = try Extension.initStdio(&rt, .{ .capabilities = .{
        .documentSync = true,
        .decorations = true,
        .views = &.{"hello.tree"},
    } });
    defer ext.deinit();
    try ext.onCommand("hello.say", say);
    try ext.onCommand("hello.count", increment);
    try ext.onRequest(sdk.protocol.methods.view_resolve, resolveView);
    try ext.onRequest(sdk.protocol.methods.decorations_provide, decorations);
    try ext.onNotification(sdk.protocol.methods.document_did_open, didOpen);
    try ext.onNotification(sdk.protocol.methods.document_did_change, didChange);
    try ext.onNotification(sdk.protocol.methods.document_did_close, didClose);
    try ext.run();

    var it = docs.iterator();
    while (it.next()) |kv| {
        gpa.free(kv.key_ptr.*);
        gpa.free(kv.value_ptr.*);
    }
    docs.deinit(gpa);
    return 0;
}

fn say(e: *Extension, args: ?Value, arena: Allocator) anyerror!?Value {
    const name = if (args) |a| if (a == .object) if (a.object.get("name")) |n| n.string else "world" else "world" else "world";
    const msg = try std.fmt.allocPrint(arena, "Hello, {s}!", .{name});
    const choice = try e.showMessage(arena, .info, msg, &.{ "Again", "Close" });
    return .{ .string = choice orelse "dismissed" };
}

fn increment(e: *Extension, _: ?Value, arena: Allocator) anyerror!?Value {
    mutex.lockUncancelable(io);
    count += 1;
    const n = count;
    mutex.unlock(io);
    var patch: std.json.ObjectMap = .empty;
    try patch.put(arena, "label", .{ .string = try std.fmt.allocPrint(arena, "Count: {d}", .{n}) });
    try e.updateView("hello.tree", .{ .object = patch });
    return .{ .integer = n };
}

fn resolveView(_: *Extension, _: ?Value, arena: Allocator) anyerror!?Value {
    mutex.lockUncancelable(io);
    const n = count;
    mutex.unlock(io);
    const tree: sdk.protocol.ViewTree = .{ .root = .{
        .id = "root",
        .label = try std.fmt.allocPrint(arena, "Count: {d}", .{n}),
        .collapsible = true,
        .children = &.{
            .{ .id = "say", .label = "Say hello", .command = "hello.say" },
            .{ .id = "count", .label = "Count", .command = "hello.count" },
        },
    } };
    return try std.json.parseFromSliceLeaky(Value, arena, try std.json.Stringify.valueAlloc(arena, tree, .{ .emit_null_optional_fields = false }), .{});
}

fn decorations(_: *Extension, params: ?Value, arena: Allocator) anyerror!?Value {
    const uri = params.?.object.get("uri").?.string;
    var out: std.json.Array = .init(arena);
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    const text = docs.get(uri) orelse return .{ .array = out };
    var line: u32 = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| : (line += 1) {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, l, from, "TODO")) |col| : (from = col + 4) {
            const d: sdk.protocol.Decoration = .{
                .range = .{ .start = .{ .line = line, .character = @intCast(col) }, .end = .{ .line = line, .character = @intCast(col + 4) } },
                .kind = .highlight,
                .color = "#e5c07b",
                .hover = "Something to do",
            };
            const j = try std.json.Stringify.valueAlloc(arena, d, .{ .emit_null_optional_fields = false });
            try out.append(try std.json.parseFromSliceLeaky(Value, arena, j, .{}));
            if (out.items.len >= sdk.protocol.limits.max_decorations_per_document) return .{ .array = out };
        }
    }
    return .{ .array = out };
}

fn setDoc(uri: []const u8, text: []const u8) void {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    const copy = gpa.dupe(u8, text) catch return;
    if (docs.getPtr(uri)) |old| {
        gpa.free(old.*);
        old.* = copy;
        return;
    }
    const key = gpa.dupe(u8, uri) catch return gpa.free(copy);
    docs.put(gpa, key, copy) catch {
        gpa.free(key);
        gpa.free(copy);
    };
}

fn didOpen(_: *Extension, params: ?Value, _: Allocator) void {
    const p = params orelse return;
    setDoc(p.object.get("uri").?.string, p.object.get("text").?.string);
}

fn didChange(_: *Extension, params: ?Value, _: Allocator) void {
    // This example asks for full-text changes only (a change without a range).
    const p = params orelse return;
    const changes = p.object.get("changes").?.array.items;
    if (changes.len == 0) return;
    const last = changes[changes.len - 1];
    if (last.object.get("range")) |r| if (r != .null) return;
    setDoc(p.object.get("uri").?.string, last.object.get("text").?.string);
}

fn didClose(_: *Extension, params: ?Value, _: Allocator) void {
    const p = params orelse return;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (docs.fetchRemove(p.object.get("uri").?.string)) |kv| {
        gpa.free(kv.key);
        gpa.free(kv.value);
    }
}
