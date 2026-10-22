//! Client and server capabilities.
//!
//! Capabilities stay a JSON object rather than a fixed struct: new
//! sub-capabilities and extensions appear often, and every check is a dotted
//! path lookup (`"resources.subscribe"`, `"elicitation.url"`), so supporting
//! one needs no code change here.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Stringify = std.json.Stringify;
const codec = @import("codec.zig");

/// A capabilities object (`ClientCapabilities` or `ServerCapabilities`).
pub const Capabilities = struct {
    /// Always a JSON object.
    value: Value,

    /// `{}`.
    pub const empty: Capabilities = .{ .value = .{ .object = .empty } };

    /// Codec hook: requires a JSON object.
    pub fn jsonDecode(ctx: *codec.Ctx, v: Value) codec.DecodeError!Capabilities {
        if (v != .object) return ctx.fail(error.TypeMismatch);
        return .{ .value = v };
    }

    /// Codec hook.
    pub fn jsonEncode(c: Capabilities, s: *Stringify) Stringify.Error!void {
        return s.write(c.value);
    }

    /// The value at dotted `path` (`"resources.subscribe"`), or null.
    pub fn get(c: Capabilities, path: []const u8) ?Value {
        var cur = c.value;
        var it = std.mem.splitScalar(u8, path, '.');
        while (it.next()) |seg| {
            if (cur != .object) return null;
            cur = cur.object.get(seg) orelse return null;
        }
        return cur;
    }

    /// Whether `path` is declared: present and neither `false` nor `null`.
    /// A boolean leaf (`"tools.listChanged"`) must be `true`.
    pub fn has(c: Capabilities, path: []const u8) bool {
        const v = c.get(path) orelse return false;
        return switch (v) {
            .null => false,
            .bool => |b| b,
            else => true,
        };
    }

    /// `extensions[id]`. Extension ids contain dots and slashes
    /// (`io.modelcontextprotocol/tasks`), so they are not dotted paths.
    pub fn extension(c: Capabilities, id: []const u8) ?Value {
        const exts = c.get("extensions") orelse return null;
        if (exts != .object) return null;
        return exts.object.get(id);
    }
};

/// Builds a capabilities object in an arena.
pub const Builder = struct {
    arena: Allocator,
    root: std.json.ObjectMap,

    /// Starts an empty object.
    pub fn init(arena: Allocator) Builder {
        return .{ .arena = arena, .root = .empty };
    }

    /// Sets `{}` (or `value`) at dotted `path`, creating parents.
    pub fn set(b: *Builder, path: []const u8, value: ?Value) Allocator.Error!void {
        var obj = &b.root;
        var it = std.mem.splitScalar(u8, path, '.');
        var seg = it.next().?;
        while (it.next()) |next| : (seg = next) {
            const gop = try obj.getOrPut(b.arena, seg);
            if (!gop.found_existing or gop.value_ptr.* != .object) gop.value_ptr.* = .{ .object = .empty };
            obj = &gop.value_ptr.object;
        }
        try obj.put(b.arena, seg, value orelse .{ .object = .empty });
    }

    /// Declares extension `id` (with `{}` settings).
    pub fn addExtension(b: *Builder, id: []const u8) Allocator.Error!void {
        const gop = try b.root.getOrPut(b.arena, "extensions");
        if (!gop.found_existing or gop.value_ptr.* != .object) gop.value_ptr.* = .{ .object = .empty };
        try gop.value_ptr.object.put(b.arena, id, .{ .object = .empty });
    }

    /// The finished object.
    pub fn finish(b: *Builder) Capabilities {
        return .{ .value = .{ .object = b.root } };
    }
};

/// Extension id of the 2026-07-28 tasks extension.
pub const tasks_extension = "io.modelcontextprotocol/tasks";

/// Which optional client features to declare.
pub const ClientFeatures = struct {
    elicitation_form: bool = true,
    elicitation_url: bool = true,
    /// Deprecated in 2026-07-28; off by default for remote servers (E15 settings).
    sampling: bool = true,
    sampling_tools: bool = true,
    /// Deprecated in 2026-07-28.
    roots: bool = true,
    tasks: bool = true,
};

/// The capabilities zigguro declares as a client, e.g. by default
/// `{ elicitation: { form: {}, url: {} }, sampling: { tools: {} }, roots: {},
///   extensions: { "io.modelcontextprotocol/tasks": {} } }`.
pub fn defaultClient(arena: Allocator, f: ClientFeatures) Allocator.Error!Capabilities {
    var b: Builder = .init(arena);
    if (f.elicitation_form) try b.set("elicitation.form", null);
    if (f.elicitation_url) try b.set("elicitation.url", null);
    if (f.sampling) try b.set(if (f.sampling_tools) "sampling.tools" else "sampling", null);
    if (f.roots) try b.set("roots", null);
    if (f.tasks) try b.addExtension(tasks_extension);
    return b.finish();
}

const testing = std.testing;

test "capabilities: dotted paths and builder" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try defaultClient(a, .{});
    const s = try codec.encodeAlloc(a, c);
    try testing.expectEqualStrings(
        "{\"elicitation\":{\"form\":{},\"url\":{}},\"sampling\":{\"tools\":{}},\"roots\":{},\"extensions\":{\"io.modelcontextprotocol/tasks\":{}}}",
        s,
    );
    try testing.expect(c.has("elicitation.url"));
    try testing.expect(!c.has("elicitation.foo"));
    try testing.expect(c.extension(tasks_extension) != null);

    const srv = try codec.decodeBytes(Capabilities, a, "{\"tools\":{\"listChanged\":false},\"resources\":{\"subscribe\":true}}", .{});
    try testing.expect(srv.has("tools"));
    try testing.expect(!srv.has("tools.listChanged"));
    try testing.expect(srv.has("resources.subscribe"));
    try testing.expect(!Capabilities.empty.has("tools"));
}
