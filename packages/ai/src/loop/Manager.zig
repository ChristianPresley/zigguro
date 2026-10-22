//! `AgentManager`: creates, lists, looks up and disposes agents for the
//! app and the CLI. Top-level agents get a fresh session id; subagents
//! (config `parent` set) share their parent's session, get the next agent
//! number in it and are registered with the parent so `cancel(.everything)`
//! cascades. `subscribeAll` sees the events of every agent, current and
//! future. Headless: no GUI imports.

const std = @import("std");
const proto = @import("zg_ai_proto");
const Agent = @import("Agent.zig");
const ev = @import("events.zig");
const busm = @import("bus.zig");

const AgentManager = @This();
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Events of any agent, tagged with the agent.
pub const AllSubscriber = struct {
    ctx: *anyopaque,
    on_events: *const fn (ctx: *anyopaque, agent: proto.AgentRef, batch: []const ev.Envelope) void,
    mode: @FieldType(busm.Subscriber, "mode") = .queued,
    capacity: u32 = 4096,
};

pub const AgentSummary = struct {
    ref: proto.AgentRef,
    model: []const u8,
    status: ev.Status,
    turns: u32,
    cost_micros: u64,
    parent: ?proto.AgentRef,
};

/// Forwards one agent's events to one `AllSubscriber`.
const Forwarder = struct {
    all: AllSubscriber,
    ref: proto.AgentRef,
    id: busm.SubscriptionId = 0,

    fn on(ctx: *anyopaque, batch: []const ev.Envelope) void {
        const f: *Forwarder = @ptrCast(@alignCast(ctx));
        f.all.on_events(f.all.ctx, f.ref, batch);
    }

    fn subscriber(f: *Forwarder) busm.Subscriber {
        return .{ .ctx = f, .on_events = on, .mode = f.all.mode, .capacity = f.all.capacity };
    }
};

const Entry = struct {
    agent: *Agent,
    parent: ?*Agent,
    forwarders: std.ArrayList(*Forwarder) = .empty,
};

gpa: Allocator,
io: Io,
deps: Agent.Deps,
mutex: Io.Mutex = .init,
entries: std.ArrayList(Entry) = .empty,
all: std.ArrayList(AllSubscriber) = .empty,
ulid: proto.agent_ref.UlidGen = .{},

pub fn init(gpa: Allocator, io: Io, deps: Agent.Deps) Allocator.Error!*AgentManager {
    const m = try gpa.create(AgentManager);
    m.* = .{ .gpa = gpa, .io = io, .deps = deps };
    return m;
}

/// Disposes every agent (children first) and frees the manager.
pub fn deinit(m: *AgentManager) void {
    while (true) {
        const a = blk: {
            m.mutex.lockUncancelable(m.io);
            defer m.mutex.unlock(m.io);
            if (m.entries.items.len == 0) break;
            break :blk m.entries.items[m.entries.items.len - 1].agent;
        };
        m.dispose(a);
    }
    m.entries.deinit(m.gpa);
    m.all.deinit(m.gpa);
    m.gpa.destroy(m);
}

pub const CreateError = Allocator.Error || Io.ConcurrentError || error{UnknownParent};

/// Creates an idle agent with the manager's deps.
pub fn create(m: *AgentManager, cfg: Agent.Config) CreateError!*Agent {
    return m.createWith(cfg, m.deps);
}

/// Like `create` with other deps (a subagent's restricted toolset).
pub fn createWith(m: *AgentManager, cfg: Agent.Config, deps: Agent.Deps) CreateError!*Agent {
    m.mutex.lockUncancelable(m.io);
    defer m.mutex.unlock(m.io);
    var ref: proto.AgentRef = .{ .session = undefined };
    var parent: ?*Agent = null;
    if (cfg.parent) |p| {
        parent = (m.findLocked(p) orelse return error.UnknownParent).agent;
        // Agent numbers are unique per session, not per parent.
        var max: u32 = 0;
        for (m.entries.items) |e| if (e.agent.ref.session == p.session) {
            max = @max(max, e.agent.ref.agent);
        };
        ref = .{ .session = p.session, .agent = max + 1, .tool_call = cfg.spawned_by };
    } else ref.session = m.ulid.next(m.io);

    const a = try Agent.create(m.gpa, m.io, ref, cfg, deps);
    errdefer a.destroy();
    var entry: Entry = .{ .agent = a, .parent = parent };
    errdefer {
        for (entry.forwarders.items) |f| {
            a.unsubscribe(f.id);
            m.gpa.destroy(f);
        }
        entry.forwarders.deinit(m.gpa);
    }
    for (m.all.items) |s| try addForwarder(m, &entry, s);
    if (parent) |p| try p.addChild(a);
    errdefer if (parent) |p| p.removeChild(a);
    try m.entries.append(m.gpa, entry);
    return a;
}

fn addForwarder(m: *AgentManager, e: *Entry, s: AllSubscriber) (Allocator.Error || Io.ConcurrentError)!void {
    const f = try m.gpa.create(Forwarder);
    errdefer m.gpa.destroy(f);
    f.* = .{ .all = s, .ref = e.agent.ref };
    try e.forwarders.ensureUnusedCapacity(m.gpa, 1);
    f.id = try e.agent.subscribe(f.subscriber());
    e.forwarders.appendAssumeCapacity(f);
}

fn findLocked(m: *AgentManager, ref: proto.AgentRef) ?*Entry {
    for (m.entries.items) |*e| if (e.agent.ref.session == ref.session and e.agent.ref.agent == ref.agent) return e;
    return null;
}

/// The agent with this session and agent number.
pub fn get(m: *AgentManager, ref: proto.AgentRef) ?*Agent {
    m.mutex.lockUncancelable(m.io);
    defer m.mutex.unlock(m.io);
    return if (m.findLocked(ref)) |e| e.agent else null;
}

/// Appends a summary of every agent, in creation order.
pub fn list(m: *AgentManager, gpa: Allocator, out: *std.ArrayList(AgentSummary)) Allocator.Error!void {
    m.mutex.lockUncancelable(m.io);
    defer m.mutex.unlock(m.io);
    try out.ensureUnusedCapacity(gpa, m.entries.items.len);
    for (m.entries.items) |e| {
        const s = e.agent.snapshot();
        out.appendAssumeCapacity(.{
            .ref = e.agent.ref,
            .model = e.agent.cfg.model,
            .status = s.status,
            .turns = s.turns,
            .cost_micros = s.cost_micros,
            .parent = if (e.parent) |p| p.ref else null,
        });
    }
}

pub fn count(m: *AgentManager) usize {
    m.mutex.lockUncancelable(m.io);
    defer m.mutex.unlock(m.io);
    return m.entries.items.len;
}

/// Disposes the agent's subagents, then cancels it, waits for its turn
/// task, flushes the session log and frees it. `a` is invalid afterwards.
pub fn dispose(m: *AgentManager, a: *Agent) void {
    // Children first, so none outlives its parent.
    while (true) {
        const child = blk: {
            m.mutex.lockUncancelable(m.io);
            defer m.mutex.unlock(m.io);
            for (m.entries.items) |e| if (e.parent == a) break :blk e.agent;
            break :blk null;
        };
        m.dispose(child orelse break);
    }
    var entry = blk: {
        m.mutex.lockUncancelable(m.io);
        defer m.mutex.unlock(m.io);
        for (m.entries.items, 0..) |e, i| if (e.agent == a) break :blk m.entries.orderedRemove(i);
        return;
    };
    if (entry.parent) |p| p.removeChild(a);
    a.cancel(.everything);
    if (a.deps.session) |s| s.vtable.sync(s.ctx, m.io) catch {};
    for (entry.forwarders.items) |f| {
        a.unsubscribe(f.id);
        m.gpa.destroy(f);
    }
    entry.forwarders.deinit(m.gpa);
    a.destroy();
}

/// Subscribes to every agent's events, current and future.
pub fn subscribeAll(m: *AgentManager, s: AllSubscriber) (Allocator.Error || Io.ConcurrentError)!void {
    m.mutex.lockUncancelable(m.io);
    defer m.mutex.unlock(m.io);
    try m.all.append(m.gpa, s);
    for (m.entries.items) |*e| try addForwarder(m, e, s);
}
