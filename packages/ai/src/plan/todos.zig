//! The `todo_write` tool (E10.F09.S02.T02): the agent's visible task
//! list.
//!
//! Each call replaces an agent's whole list. At most one item may be
//! `in_progress`; ids are assigned when missing. A change publishes
//! `todo_changed` (the session records it, so resume restores the list)
//! and, for the main agent, updates the assembler state, which reminds
//! the model only when the list differs from the last one it saw.

const std = @import("std");
const proto = @import("zg_ai_proto");
const AgentManager = @import("../loop/Manager.zig");
const assembler = @import("../context/assembler.zig");
const registry = @import("../tools/registry.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const json = proto.json;

pub const Todo = @import("../loop/events.zig").Todo;
pub const Status = @FieldType(Todo, "status");

pub const schema =
    \\{"type":"object","properties":{"todos":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"content":{"type":"string","minLength":1},"status":{"enum":["pending","in_progress","completed"]},"active_form":{"type":"string","description":"Present tense, shown while in progress (\"Running tests\")."}},"required":["content","status"],"additionalProperties":false}}},"required":["todos"],"additionalProperties":false}
;

pub const description = "Replaces your todo list for this task. Use it for work with three or more steps: list the steps, mark one in_progress before starting it and completed as soon as it is done. Only one item may be in_progress. The user sees the list.";

pub const one_in_progress = "Only one todo may be in_progress at a time. Mark the others pending or completed and call todo_write again.";

/// One agent's list; `arena` owns it.
const List = struct {
    session: proto.SessionId,
    agent: u32,
    arena: std.heap.ArenaAllocator,
    items: []const Todo = &.{},
};

pub const TodoStore = struct {
    gpa: Allocator,
    io: Io,
    /// Publishes `todo_changed` on the calling agent, when set.
    mgr: ?*AgentManager = null,
    /// The main agent's assembler state; its `todos` follow that agent's
    /// list (agent 0 of any session).
    state: ?*assembler.State = null,
    mutex: Io.Mutex = .init,
    lists: std.ArrayList(*List) = .empty,
    /// Owns `state.todos`.
    state_arena: std.heap.ArenaAllocator,
    spec_list: [1]proto.ToolSpec = undefined,

    pub fn init(gpa: Allocator, io: Io) TodoStore {
        return .{ .gpa = gpa, .io = io, .state_arena = .init(gpa) };
    }

    pub fn deinit(s: *TodoStore) void {
        if (s.state) |st| st.todos = &.{};
        for (s.lists.items) |l| {
            l.arena.deinit();
            s.gpa.destroy(l);
        }
        s.lists.deinit(s.gpa);
        s.state_arena.deinit();
    }

    /// A copy of `ref`'s list, for the UI.
    pub fn snapshot(s: *TodoStore, arena: Allocator, ref: proto.AgentRef) Allocator.Error![]const Todo {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const l = s.find(ref) orelse return &.{};
        return dupeAll(arena, l.items);
    }

    /// Validates and stores `todos` as `ref`'s list. Returns false when
    /// the list did not change.
    pub fn set(s: *TodoStore, ref: proto.AgentRef, todos: []const Todo) (Allocator.Error || error{MultipleInProgress})!bool {
        var in_progress: u32 = 0;
        for (todos) |t| if (t.status == .in_progress) {
            in_progress += 1;
        };
        if (in_progress > 1) return error.MultipleInProgress;

        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const l = s.find(ref) orelse blk: {
            const l = try s.gpa.create(List);
            errdefer s.gpa.destroy(l);
            l.* = .{ .session = ref.session, .agent = ref.agent, .arena = .init(s.gpa) };
            try s.lists.append(s.gpa, l);
            break :blk l;
        };
        if (equal(l.items, todos)) return false;
        var next: std.heap.ArenaAllocator = .init(s.gpa);
        errdefer next.deinit();
        const items = try dupeAll(next.allocator(), todos);
        try assignIds(next.allocator(), items);
        l.arena.deinit();
        l.arena = next;
        l.items = items;
        if (ref.agent == 0) if (s.state) |st| {
            _ = s.state_arena.reset(.retain_capacity);
            const view = try s.state_arena.allocator().alloc(assembler.Todo, items.len);
            for (items, view) |t, *v| v.* = .{ .text = t.content, .status = switch (t.status) {
                .pending => .pending,
                .in_progress => .in_progress,
                .completed => .completed,
            } };
            st.todos = view;
        };
        return true;
    }

    /// Restores `ref`'s list from a `todo_changed` session record.
    pub fn restore(s: *TodoStore, ref: proto.AgentRef, data_json: []const u8) !void {
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const v = try json.parseValue(arena.allocator(), data_json);
        const obj = json.asObject(v) orelse return error.InvalidTodos;
        const todos = try json.decodeValue([]Todo, arena.allocator(), obj.get("todos") orelse return error.InvalidTodos);
        _ = try s.set(ref, todos);
    }

    fn find(s: *TodoStore, ref: proto.AgentRef) ?*List {
        for (s.lists.items) |l| if (l.session == ref.session and l.agent == ref.agent) return l;
        return null;
    }

    pub fn specs(s: *TodoStore) []const proto.ToolSpec {
        s.spec_list = .{.{
            .name = "todo_write",
            .description = description,
            .input_schema_json = schema,
            .read_only = true,
            .handler = .{ .ctx = s, .call = call },
        }};
        return &s.spec_list;
    }

    pub fn source(s: *TodoStore) registry.ToolSource {
        return .{ .name = "todos", .ctx = s, .list = list, .kind = .builtin };
    }

    fn list(ctx: *anyopaque, gpa: Allocator, out: *std.ArrayList(proto.ToolSpec)) anyerror!void {
        const s: *TodoStore = @ptrCast(@alignCast(ctx));
        try out.appendSlice(gpa, s.specs());
    }

    fn call(ctx: *anyopaque, c: *proto.ToolCall) proto.ToolError!proto.ToolOutput {
        const s: *TodoStore = @ptrCast(@alignCast(ctx));
        const a = c.arena;
        const obj = json.asObject(c.input) orelse return errOut(a, "todo_write needs {\"todos\": [...]}.");
        const todos = json.decodeValue([]Input, a, obj.get("todos") orelse return errOut(a, "todo_write needs \"todos\".")) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return errOut(a, "Each todo needs \"content\" and a \"status\" of pending, in_progress or completed."),
        };
        const items = a.alloc(Todo, todos.len) catch return error.OutOfMemory;
        for (todos, items) |t, *it| it.* = .{ .id = t.id orelse "", .content = t.content, .status = t.status, .active_form = t.active_form };
        const changed = s.set(c.agent, items) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.MultipleInProgress => return errOut(a, one_in_progress),
        };
        if (changed) s.publish(c.agent);
        return proto.ToolOutput.text(a, summary(a, items) catch return error.OutOfMemory, false) catch error.OutOfMemory;
    }

    fn publish(s: *TodoStore, ref: proto.AgentRef) void {
        const m = s.mgr orelse return;
        const agent = m.get(ref) orelse return;
        agent.alloc_mutex.lockUncancelable(agent.io);
        defer agent.alloc_mutex.unlock(agent.io);
        const items = s.snapshot(agent.arena.allocator(), ref) catch return;
        agent.publish(.{ .todo_changed = items });
    }
};

const Input = struct {
    id: ?[]const u8 = null,
    content: []const u8,
    status: Status,
    active_form: ?[]const u8 = null,
};

fn summary(a: Allocator, items: []const Todo) Allocator.Error![]const u8 {
    var done: usize = 0;
    var current: ?[]const u8 = null;
    for (items) |t| switch (t.status) {
        .completed => done += 1,
        .in_progress => current = t.active_form orelse t.content,
        .pending => {},
    };
    if (current) |cur| return std.fmt.allocPrint(a, "Todos updated: {d} of {d} done; now: {s}.", .{ done, items.len, cur });
    return std.fmt.allocPrint(a, "Todos updated: {d} of {d} done.", .{ done, items.len });
}

/// Gives items without an id the lowest unused number.
fn assignIds(a: Allocator, items: []Todo) Allocator.Error!void {
    var n: u32 = 1;
    for (items) |*t| {
        if (t.id.len > 0) continue;
        while (true) : (n += 1) {
            var buf: [12]u8 = undefined;
            const id = std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable;
            for (items) |o| {
                if (std.mem.eql(u8, o.id, id)) break;
            } else {
                t.id = try a.dupe(u8, id);
                n += 1;
                break;
            }
        }
    }
}

fn dupeAll(a: Allocator, items: []const Todo) Allocator.Error![]Todo {
    const out = try a.alloc(Todo, items.len);
    for (items, out) |t, *o| o.* = .{
        .id = try a.dupe(u8, t.id),
        .content = try a.dupe(u8, t.content),
        .status = t.status,
        .active_form = if (t.active_form) |f| try a.dupe(u8, f) else null,
    };
    return out;
}

/// Same contents and statuses; ids the caller left out do not count.
fn equal(old: []const Todo, new: []const Todo) bool {
    if (old.len != new.len) return false;
    for (old, new) |o, n| {
        if (o.status != n.status or !std.mem.eql(u8, o.content, n.content)) return false;
        if (n.id.len > 0 and !std.mem.eql(u8, o.id, n.id)) return false;
        if (!std.mem.eql(u8, o.active_form orelse "", n.active_form orelse "")) return false;
    }
    return true;
}

fn errOut(a: Allocator, s: []const u8) proto.ToolError!proto.ToolOutput {
    return proto.ToolOutput.text(a, s, true) catch error.OutOfMemory;
}
