//! Tool, resource, template and prompt registries.
//!
//! Reads vastly outnumber writes, so the registry is copy-on-write: readers
//! load the current `Snapshot` through an atomic pointer and never lock;
//! `add*`/`remove*` build a new snapshot under a writer mutex and publish
//! it. Retired snapshots (and removed entries) stay alive until `deinit`,
//! so a reader holding an old snapshot is always safe. Each snapshot caches
//! its serialized list pages; a change publishes a fresh, empty cache.

const Registry = @This();
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const protocol = @import("../protocol/root.zig");
const schema = @import("../schema/root.zig");
const Server = @import("Server.zig");

const messages = protocol.messages;
const codec = protocol.codec;
const CallCtx = Server.CallCtx;

/// Runs a dynamic tool. `args` was validated against the input schema.
pub const DynHandler = struct {
    ctx: ?*anyopaque,
    call: *const fn (ctx: ?*anyopaque, cc: *CallCtx, args: Value) anyerror!messages.CallToolResult,
};

/// A tool described at runtime: its definition (schema as JSON) and handler.
pub const DynamicTool = struct { def: messages.Tool, handler: DynHandler };

/// Reads a resource.
pub const ReadHandler = struct {
    ctx: ?*anyopaque,
    read: *const fn (ctx: ?*anyopaque, cc: *CallCtx, uri: []const u8) anyerror![]const protocol.content.ResourceContents,
};

/// Renders a prompt.
pub const GetHandler = struct {
    ctx: ?*anyopaque,
    get: *const fn (ctx: ?*anyopaque, cc: *CallCtx, arguments: ?Value) anyerror!messages.GetPromptResult,
};

/// A registered tool.
pub const ToolEntry = struct { def: messages.Tool, input: *schema.Schema, handler: DynHandler };
/// A registered resource.
pub const ResourceEntry = struct { def: messages.Resource, handler: ReadHandler };
/// A registered resource template.
pub const TemplateEntry = struct { def: messages.ResourceTemplate };
/// A registered prompt.
pub const PromptEntry = struct { def: messages.Prompt, handler: GetHandler };

/// The paginated lists.
pub const ListKind = enum { tools, resources, templates, prompts };

/// Identifies one serialized page.
pub const PageKey = struct { list: ListKind, era: protocol.revision.Era, offset: u32 };

/// An immutable view of the registry.
pub const Snapshot = struct {
    version: u64,
    tools: []const *ToolEntry = &.{},
    resources: []const *ResourceEntry = &.{},
    templates: []const *TemplateEntry = &.{},
    prompts: []const *PromptEntry = &.{},
    cache_mutex: Io.Mutex = .init,
    cache: std.AutoHashMapUnmanaged(PageKey, []const u8) = .empty,

    /// The tool called `name`.
    pub fn tool(s: *const Snapshot, name: []const u8) ?*ToolEntry {
        for (s.tools) |t| if (std.mem.eql(u8, t.def.name, name)) return t;
        return null;
    }

    /// The resource at `uri`.
    pub fn resource(s: *const Snapshot, uri: []const u8) ?*ResourceEntry {
        for (s.resources) |r| if (std.mem.eql(u8, r.def.uri, uri)) return r;
        return null;
    }

    /// The prompt called `name`.
    pub fn prompt(s: *const Snapshot, name: []const u8) ?*PromptEntry {
        for (s.prompts) |p| if (std.mem.eql(u8, p.def.name, name)) return p;
        return null;
    }

    /// Length of list `k`.
    pub fn len(s: *const Snapshot, k: ListKind) usize {
        return switch (k) {
            .tools => s.tools.len,
            .resources => s.resources.len,
            .templates => s.templates.len,
            .prompts => s.prompts.len,
        };
    }

    /// The serialized page for `key`, built by `build` on first use.
    /// `build` returns bytes owned by `gpa`.
    pub fn page(s: *Snapshot, io: Io, gpa: Allocator, key: PageKey, ctx: anytype, comptime build: fn (@TypeOf(ctx), Allocator) error{OutOfMemory}![]u8) error{OutOfMemory}![]const u8 {
        {
            s.cache_mutex.lockUncancelable(io);
            defer s.cache_mutex.unlock(io);
            if (s.cache.get(key)) |b| return b;
        }
        // Build outside the lock; a racing builder's copy is dropped.
        const bytes = try build(ctx, gpa);
        s.cache_mutex.lockUncancelable(io);
        defer s.cache_mutex.unlock(io);
        const gop = s.cache.getOrPut(gpa, key) catch |err| {
            gpa.free(bytes);
            return err;
        };
        if (gop.found_existing) {
            gpa.free(bytes);
        } else gop.value_ptr.* = bytes;
        return gop.value_ptr.*;
    }

    fn deinit(s: *Snapshot, gpa: Allocator) void {
        var it = s.cache.valueIterator();
        while (it.next()) |b| gpa.free(b.*);
        s.cache.deinit(gpa);
        s.deinitLists(gpa);
        gpa.destroy(s);
    }

    fn deinitLists(s: *Snapshot, gpa: Allocator) void {
        gpa.free(s.tools);
        gpa.free(s.resources);
        gpa.free(s.templates);
        gpa.free(s.prompts);
    }
};

/// Errors from registration.
pub const AddError = error{ OutOfMemory, DuplicateName, InvalidSchema };

gpa: Allocator,
io: Io,
/// Serializes writers; guards `arena`, `retired` and `schemas`.
mutex: Io.Mutex = .init,
/// Entry definitions (deep copies); freed at `deinit`.
arena: std.heap.ArenaAllocator,
current: std.atomic.Value(*Snapshot),
retired: std.ArrayList(*Snapshot) = .empty,
schemas: std.ArrayList(*schema.Schema) = .empty,
/// Called after each publish with the list that changed (`list_changed`).
on_change: ?struct { ctx: ?*anyopaque, func: *const fn (?*anyopaque, ListKind) void } = null,

/// An empty registry.
pub fn init(gpa: Allocator, io: Io) error{OutOfMemory}!Registry {
    const s = try gpa.create(Snapshot);
    s.* = .{ .version = 1 };
    return .{ .gpa = gpa, .io = io, .arena = .init(gpa), .current = .init(s) };
}

/// Frees every snapshot and entry. No reader may be active.
pub fn deinit(r: *Registry) void {
    r.current.load(.acquire).deinit(r.gpa);
    for (r.retired.items) |s| s.deinit(r.gpa);
    r.retired.deinit(r.gpa);
    for (r.schemas.items) |s| s.deinit();
    r.schemas.deinit(r.gpa);
    r.arena.deinit();
}

/// The current snapshot (valid until `deinit`).
pub fn snapshot(r: *Registry) *Snapshot {
    return r.current.load(.acquire);
}

/// Registers a tool; its input schema is compiled once here.
pub fn addTool(r: *Registry, def: messages.Tool, handler: DynHandler) AddError!void {
    r.mutex.lockUncancelable(r.io);
    const cur = r.snapshot();
    if (cur.tool(def.name) != null) {
        r.mutex.unlock(r.io);
        return error.DuplicateName;
    }
    const a = r.arena.allocator();
    const e = a.create(ToolEntry) catch return r.unlockWith(error.OutOfMemory);
    e.def = deepCopy(messages.Tool, a, def) catch return r.unlockWith(error.OutOfMemory);
    r.schemas.ensureUnusedCapacity(r.gpa, 1) catch return r.unlockWith(error.OutOfMemory);
    e.input = schema.compile(r.gpa, e.def.input_schema, .{}) catch |err| return r.unlockWith(switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidSchema,
    });
    r.schemas.appendAssumeCapacity(e.input);
    e.handler = handler;
    return r.publish(.tools, appended(*ToolEntry, cur.tools, e));
}

/// Registers a resource.
pub fn addResource(r: *Registry, def: messages.Resource, handler: ReadHandler) AddError!void {
    r.mutex.lockUncancelable(r.io);
    const cur = r.snapshot();
    if (cur.resource(def.uri) != null) {
        r.mutex.unlock(r.io);
        return error.DuplicateName;
    }
    const a = r.arena.allocator();
    const e = a.create(ResourceEntry) catch return r.unlockWith(error.OutOfMemory);
    e.* = .{ .def = deepCopy(messages.Resource, a, def) catch return r.unlockWith(error.OutOfMemory), .handler = handler };
    return r.publish(.resources, appended(*ResourceEntry, cur.resources, e));
}

/// Registers a resource template.
pub fn addTemplate(r: *Registry, def: messages.ResourceTemplate) AddError!void {
    r.mutex.lockUncancelable(r.io);
    const cur = r.snapshot();
    const a = r.arena.allocator();
    const e = a.create(TemplateEntry) catch return r.unlockWith(error.OutOfMemory);
    e.* = .{ .def = deepCopy(messages.ResourceTemplate, a, def) catch return r.unlockWith(error.OutOfMemory) };
    return r.publish(.templates, appended(*TemplateEntry, cur.templates, e));
}

/// Registers a prompt.
pub fn addPrompt(r: *Registry, def: messages.Prompt, handler: GetHandler) AddError!void {
    r.mutex.lockUncancelable(r.io);
    const cur = r.snapshot();
    if (cur.prompt(def.name) != null) {
        r.mutex.unlock(r.io);
        return error.DuplicateName;
    }
    const a = r.arena.allocator();
    const e = a.create(PromptEntry) catch return r.unlockWith(error.OutOfMemory);
    e.* = .{ .def = deepCopy(messages.Prompt, a, def) catch return r.unlockWith(error.OutOfMemory), .handler = handler };
    return r.publish(.prompts, appended(*PromptEntry, cur.prompts, e));
}

/// Removes the tool called `name`; false when there is none.
pub fn removeTool(r: *Registry, name: []const u8) error{OutOfMemory}!bool {
    return r.remove(.tools, name);
}

/// Removes the resource at `uri`; false when there is none.
pub fn removeResource(r: *Registry, uri: []const u8) error{OutOfMemory}!bool {
    return r.remove(.resources, uri);
}

/// Removes the prompt called `name`; false when there is none.
pub fn removePrompt(r: *Registry, name: []const u8) error{OutOfMemory}!bool {
    return r.remove(.prompts, name);
}

fn remove(r: *Registry, comptime k: ListKind, key: []const u8) error{OutOfMemory}!bool {
    r.mutex.lockUncancelable(r.io);
    const cur = r.snapshot();
    const items = @field(cur, @tagName(k));
    const i = for (items, 0..) |e, i| {
        const id = if (k == .resources) e.def.uri else e.def.name;
        if (std.mem.eql(u8, id, key)) break i;
    } else {
        r.mutex.unlock(r.io);
        return false;
    };
    // The entry itself stays in the arena for readers of older snapshots.
    try r.publish(k, .{ .remove = .{ items, i } });
    return true;
}

fn Edit(comptime T: type) type {
    return union(enum) { append: struct { []const T, T }, remove: struct { []const T, usize } };
}

fn appended(comptime T: type, items: []const T, e: T) Edit(T) {
    return .{ .append = .{ items, e } };
}

fn EntryOf(comptime k: ListKind) type {
    return @typeInfo(@FieldType(Snapshot, @tagName(k))).pointer.child;
}

/// Publishes a snapshot with list `k` edited; releases `mutex`.
fn publish(r: *Registry, comptime k: ListKind, edit: Edit(EntryOf(k))) error{OutOfMemory}!void {
    const T = EntryOf(k);
    {
        defer r.mutex.unlock(r.io);
        const cur = r.snapshot();
        const next = try r.gpa.create(Snapshot);
        errdefer r.gpa.destroy(next);
        next.* = .{ .version = cur.version + 1 };
        errdefer next.deinitLists(r.gpa);
        @field(next, @tagName(k)) = switch (edit) {
            .append => |e| blk: {
                const out = try r.gpa.alloc(T, e[0].len + 1);
                @memcpy(out[0..e[0].len], e[0]);
                out[e[0].len] = e[1];
                break :blk out;
            },
            .remove => |e| blk: {
                const out = try r.gpa.alloc(T, e[0].len - 1);
                @memcpy(out[0..e[1]], e[0][0..e[1]]);
                @memcpy(out[e[1]..], e[0][e[1] + 1 ..]);
                break :blk out;
            },
        };
        inline for (.{ "tools", "resources", "templates", "prompts" }) |f| {
            if (comptime !std.mem.eql(u8, f, @tagName(k)))
                @field(next, f) = try r.gpa.dupe(EntryOf(@field(ListKind, f)), @field(cur, f));
        }
        try r.retired.append(r.gpa, cur);
        r.current.store(next, .release);
    }
    if (r.on_change) |cb| cb.func(cb.ctx, k);
}

fn unlockWith(r: *Registry, err: AddError) AddError {
    r.mutex.unlock(r.io);
    return err;
}

/// A deep copy of `v` in `arena` (through the codec).
fn deepCopy(comptime T: type, arena: Allocator, v: T) error{OutOfMemory}!T {
    const bytes = try codec.encodeAlloc(arena, v);
    return codec.decodeBytes(T, arena, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        // The codec decodes what it encodes.
        else => unreachable,
    };
}

const testing = std.testing;

fn nopCall(_: ?*anyopaque, _: *CallCtx, _: Value) anyerror!messages.CallToolResult {
    return .{ .content = &.{} };
}

fn toolDef(arena: Allocator, name: []const u8) !messages.Tool {
    return .{ .name = name, .input_schema = try codec.parseValue(arena, "{\"type\":\"object\"}") };
}

test "registry: copy-on-write snapshots" {
    var r: Registry = try .init(testing.allocator, testing.io);
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s0 = r.snapshot();
    try r.addTool(try toolDef(a, "a"), .{ .ctx = null, .call = nopCall });
    try r.addTool(try toolDef(a, "b"), .{ .ctx = null, .call = nopCall });
    try testing.expectError(error.DuplicateName, r.addTool(try toolDef(a, "a"), .{ .ctx = null, .call = nopCall }));
    const s2 = r.snapshot();
    try testing.expectEqual(@as(usize, 0), s0.tools.len);
    try testing.expectEqual(@as(usize, 2), s2.tools.len);
    try testing.expect(s2.version > s0.version);
    try testing.expect(try r.removeTool("a"));
    try testing.expect(!try r.removeTool("a"));
    try testing.expectEqualStrings("b", r.snapshot().tools[0].def.name);
    // The old snapshot still sees both.
    try testing.expectEqualStrings("a", s2.tools[0].def.name);
}
