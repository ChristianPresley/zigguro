//! `CostLedger`: thread-safe aggregation of request costs per request,
//! agent, session and workspace. Each `record` holds an `Io.Mutex` for a
//! few map updates; listeners run after the lock is released.

const std = @import("std");
const proto = @import("zg_ai_proto");
const pricing = @import("pricing.zig");
const registry = @import("registry.zig");

const Allocator = std.mem.Allocator;
const Usage = proto.Usage;
const AgentRef = proto.AgentRef;
const SessionId = proto.SessionId;

/// Aggregated usage and cost.
pub const Totals = struct {
    usage: Usage = .{},
    micros: u64 = 0,
    requests: u64 = 0,
    /// Some contributing usage came from the estimator.
    estimated: bool = false,
    /// Some contributing model had no known price (cost counted as 0).
    unpriced: bool = false,

    fn add(t: *Totals, r: Record) void {
        t.usage.add(r.usage);
        t.micros += r.cost.micros;
        t.requests += 1;
        t.estimated = t.estimated or r.cost.estimated;
        t.unpriced = t.unpriced or r.unpriced;
    }
};

/// One recorded request.
pub const Record = struct {
    /// Sequence number, usable as `Scope.request`.
    seq: u64,
    session: SessionId,
    agent: u32,
    usage: Usage,
    cost: pricing.Cost,
    unpriced: bool,
};

/// What `total` aggregates over.
pub const Scope = union(enum) {
    request: u64,
    agent: AgentRef,
    session: SessionId,
    workspace,
};

/// Receives each record after it is added (the UI coalesces them).
pub const Listener = struct {
    ctx: *anyopaque,
    on_record: *const fn (ctx: *anyopaque, r: Record) void,
};

const AgentKey = struct { session: SessionId, agent: u32 };

pub const CostLedger = struct {
    gpa: Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    records: std.ArrayList(Record) = .empty,
    agents: std.AutoHashMapUnmanaged(AgentKey, Totals) = .empty,
    sessions: std.AutoHashMapUnmanaged(SessionId, Totals) = .empty,
    workspace: Totals = .{},
    listeners: std.ArrayList(Listener) = .empty,

    pub fn init(gpa: Allocator, io: std.Io) CostLedger {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(l: *CostLedger) void {
        l.records.deinit(l.gpa);
        l.agents.deinit(l.gpa);
        l.sessions.deinit(l.gpa);
        l.listeners.deinit(l.gpa);
    }

    /// Prices `u` with `model`'s price and adds it to every scope.
    pub fn record(l: *CostLedger, who: AgentRef, model: *const registry.ModelInfo, u: Usage, estimated: bool) Allocator.Error!pricing.Cost {
        var cost: pricing.Cost = if (model.price) |p| pricing.costOf(p, u) else .{ .micros = 0 };
        cost.estimated = estimated;
        const rec = try l.add(who, u, cost, model.price == null);
        return rec.cost;
    }

    /// Adds an already-priced record (e.g. replayed from a session log).
    pub fn add(l: *CostLedger, who: AgentRef, u: Usage, cost: pricing.Cost, unpriced: bool) Allocator.Error!Record {
        l.mutex.lockUncancelable(l.io);
        const rec: Record = .{ .seq = l.records.items.len, .session = who.session, .agent = who.agent, .usage = u, .cost = cost, .unpriced = unpriced };
        const listeners = blk: {
            defer l.mutex.unlock(l.io);
            try l.records.ensureUnusedCapacity(l.gpa, 1);
            const a = try l.agents.getOrPutValue(l.gpa, .{ .session = who.session, .agent = who.agent }, .{});
            const s = l.sessions.getOrPutValue(l.gpa, who.session, .{}) catch |e| {
                if (a.value_ptr.requests == 0) _ = l.agents.remove(.{ .session = who.session, .agent = who.agent });
                return e;
            };
            l.records.appendAssumeCapacity(rec);
            a.value_ptr.add(rec);
            s.value_ptr.add(rec);
            l.workspace.add(rec);
            break :blk l.listeners.items;
        };
        // Listeners are registered at startup and never removed.
        for (listeners) |li| li.on_record(li.ctx, rec);
        return rec;
    }

    /// Totals for one scope (zeroes when nothing was recorded).
    pub fn total(l: *CostLedger, scope: Scope) Totals {
        l.mutex.lockUncancelable(l.io);
        defer l.mutex.unlock(l.io);
        return switch (scope) {
            .request => |seq| blk: {
                if (seq >= l.records.items.len) break :blk .{};
                var t: Totals = .{};
                t.add(l.records.items[seq]);
                break :blk t;
            },
            .agent => |a| l.agents.get(.{ .session = a.session, .agent = a.agent }) orelse .{},
            .session => |s| l.sessions.get(s) orelse .{},
            .workspace => l.workspace,
        };
    }

    /// Registers a listener. Call before recording starts.
    pub fn subscribe(l: *CostLedger, li: Listener) Allocator.Error!void {
        l.mutex.lockUncancelable(l.io);
        defer l.mutex.unlock(l.io);
        try l.listeners.append(l.gpa, li);
    }
};
