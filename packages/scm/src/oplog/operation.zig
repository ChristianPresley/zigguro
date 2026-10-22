//! Operations: one per SCM action, content-addressed in the store. An
//! operation names its parent operations (two or more after concurrent
//! writers were merged) and the view it produced, with who did it and
//! when. E12 checkpoints are operation IDs; E10 tags an agent's
//! operations with its session, turn and tool call.

const std = @import("std");
const id_mod = @import("../store/id.zig");
const object = @import("../store/object.zig");
const enc = @import("../store/encode.zig");
const store_mod = @import("../store/store.zig");
const gc_mod = @import("../store/gc.zig");
const view_mod = @import("view.zig");
const ObjectId = id_mod.ObjectId;
const Kind = id_mod.Kind;
const Extra = object.Extra;
const Store = store_mod.Store;
const ValidateError = object.ValidateError;
const Allocator = std.mem.Allocator;

pub const ActorKind = enum(u8) { human = 0, agent = 1, system = 2 };

/// Who performed an operation. Agent IDs are E10's, opaque here.
pub const Actor = struct {
    kind: ActorKind,
    session: []const u8 = "",
    turn: []const u8 = "",
    tool_call: []const u8 = "",
    /// For `system`: what ran ("git_import", "snapshot", "gc", ...).
    system: []const u8 = "",

    pub const human: Actor = .{ .kind = .human };

    pub fn agent(session: []const u8, turn: []const u8, tool_call: []const u8) Actor {
        return .{ .kind = .agent, .session = session, .turn = turn, .tool_call = tool_call };
    }

    pub fn systemTask(name: []const u8) Actor {
        return .{ .kind = .system, .system = name };
    }
};

pub const OpMeta = struct {
    start_ms: i64,
    end_ms: i64,
    description: []const u8,
    user: []const u8,
    host: []const u8,
    workspace: []const u8,
    actor: Actor,
    /// Sorted by key.
    tags: []const Extra,

    pub fn validate(m: OpMeta) ValidateError!void {
        try object.validateExtra(m.tags);
    }

    /// The value of tag `key`, if set.
    pub fn tag(m: OpMeta, key: []const u8) ?[]const u8 {
        for (m.tags) |e| if (std.mem.eql(u8, e.key, key)) return e.value;
        return null;
    }

    /// `m` with tag `key` set to `value` (replacing an existing one), the
    /// tags kept sorted. The new slice lives in `arena`.
    pub fn withTag(m: OpMeta, arena: Allocator, key: []const u8, value: []const u8) Allocator.Error!OpMeta {
        var tags: std.ArrayList(Extra) = .empty;
        try tags.ensureTotalCapacity(arena, m.tags.len + 1);
        var placed = false;
        for (m.tags) |e| {
            const o = std.mem.order(u8, e.key, key);
            if (o == .eq) continue;
            if (o == .gt and !placed) {
                tags.appendAssumeCapacity(.{ .key = key, .value = value });
                placed = true;
            }
            tags.appendAssumeCapacity(e);
        }
        if (!placed) tags.appendAssumeCapacity(.{ .key = key, .value = value });
        var out = m;
        out.tags = tags.items;
        return out;
    }
};

pub const Operation = struct {
    /// Empty only for the root operation.
    parents: []const ObjectId,
    view: ObjectId,
    meta: OpMeta,

    pub const kind: Kind = .operation;

    pub fn validate(o: Operation) ValidateError!void {
        for (o.parents, 0..) |p, i| {
            for (o.parents[0..i]) |q| if (q.eql(p)) return error.InvalidOperation;
        }
    }
};

/// Reads and decodes a `T` object (`Operation` or `View`) into `arena`.
pub fn read(comptime T: type, s: *Store, arena: Allocator, id: ObjectId) !T {
    const r = try s.read(id);
    defer r.release();
    if (r.kind != T.kind) return error.WrongKind;
    const bytes = try arena.dupe(u8, r.bytes);
    return enc.decode(T, arena, bytes) catch error.CorruptObject;
}

/// GC edges for operations and views (pass as `EdgeOptions.extra_edges`):
/// an operation keeps its parents and view, a view every commit it
/// names.
pub fn gcEdges(_: ?*anyopaque, kind: Kind, bytes: []const u8, sink: *gc_mod.RootSink) anyerror!void {
    var arena_state: std.heap.ArenaAllocator = .init(sink.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    switch (kind) {
        .operation => {
            const o = try enc.decode(Operation, arena, bytes);
            for (o.parents) |p| try sink.add(p);
            try sink.add(o.view);
        },
        .view => {
            const v = try enc.decode(view_mod.View, arena, bytes);
            try view_mod.forEachCommit(v, sink, struct {
                fn add(s: *gc_mod.RootSink, id: ObjectId) anyerror!void {
                    try s.add(id);
                }
            }.add);
        },
        else => {},
    }
}
