//! `ApprovalBroker` (E12.F05.S02.T01): hosts E16's approval tickets. When
//! `zg_security.Engine.decide` returns `ask`, it presents the request here
//! (through `approvalPort()`); the waiting thread (an agent's tool worker,
//! the terminal service) blocks in `await` until any view answers it or
//! the request is cancelled.
//!
//! - Every method is thread-safe. `present` copies the request into the
//!   item's own arena; listeners hear about it after the lock is released.
//! - The first answer wins; a later one gets `error.AlreadyAnswered` and
//!   its view refreshes.
//! - `Answer.edit` is accepted only for an editable request. The caller
//!   re-validates the edited input; when that asks again, it presents the
//!   new request with `presentChained(req, previous)`.
//! - A waiter whose `Io` is cancelled cancels its request and gets
//!   `error.Canceled`. A cancelled request disappears from every view.
//! - Requests are journaled (`Recorder`, the review store's `approval`
//!   records) on every state change. Restored from a load, a request that
//!   was still pending is `expired`: its waiter is gone. Answers are
//!   audited by E16 (`Engine.recordAnswer`), never here.
//! - `Options.timeout_ms` (the `approvals.timeoutSeconds` setting) expires
//!   pending requests through `expireDue`, which the owner calls on a
//!   timer; the waiter gets a denial.
//!
//! Items stay in memory, with their strings, until `prune` drops answered
//! ones; an answer `await` returned stays valid until then.

const std = @import("std");
const zg_security = @import("zg_security");
const inbox = @import("inbox.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const contracts = zg_security.contracts;
const ApprovalRequest = contracts.ApprovalRequest;
const Answer = contracts.Answer;
const ApprovalId = inbox.ApprovalId;
const ApprovalState = inbox.ApprovalState;
const InboxItem = inbox.InboxItem;
const InboxListener = inbox.InboxListener;

const log = std.log.scoped(.zg_review);

/// Receives each item's JSON record when it is presented or changes
/// state; must not block (the review store frames it for its next flush).
pub const Recorder = struct {
    ctx: *anyopaque,
    record: *const fn (ctx: *anyopaque, json: []const u8) void,
};

/// Takes the approval records of a store load.
pub const RestoreSink = struct {
    ctx: *anyopaque,
    restore: *const fn (ctx: *anyopaque, record: std.json.Value) anyerror!void,
};

pub const Options = struct {
    /// Pending requests expire this long after they were presented; 0
    /// never.
    timeout_ms: i64 = 0,
    /// The first id. Processes that share a store pick distinct bases
    /// (the glue uses the store's process tag).
    id_base: u64 = 0,
    recorder: ?Recorder = null,
};

pub const AnswerError = error{ UnknownApproval, AlreadyAnswered, NotEditable, OutOfMemory };

const Item = struct {
    arena: std.heap.ArenaAllocator,
    view: InboxItem,
    done: Io.Event = .unset,
    /// Came back expired from a load; not journaled as such yet.
    restored: bool = false,
};

pub const ApprovalBroker = struct {
    gpa: Allocator,
    io: Io,
    opts: Options,
    /// Guards everything below and every item.
    mutex: Io.Mutex = .init,
    items: std.AutoArrayHashMapUnmanaged(u64, *Item) = .empty,
    next_id: u64,
    listeners: std.ArrayList(InboxListener) = .empty,

    pub fn init(gpa: Allocator, io: Io, opts: Options) ApprovalBroker {
        return .{ .gpa = gpa, .io = io, .opts = opts, .next_id = opts.id_base + 1 };
    }

    /// No thread may still be waiting.
    pub fn deinit(b: *ApprovalBroker) void {
        for (b.items.values()) |it| b.freeItem(it);
        b.items.deinit(b.gpa);
        b.listeners.deinit(b.gpa);
    }

    fn freeItem(b: *ApprovalBroker, it: *Item) void {
        it.arena.deinit();
        b.gpa.destroy(it);
    }

    /// Starts journaling through `r` (once the store is open), with ids
    /// from `id_base` on. Call before a load restores into the broker.
    pub fn bind(b: *ApprovalBroker, r: ?Recorder, id_base: u64) void {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        b.opts.recorder = r;
        b.opts.id_base = id_base;
        b.next_id = @max(b.next_id, id_base + 1);
    }

    // ------------------------------------------------- E16 port

    /// `zg_security.contracts.ApprovalPort` over this broker; ids are
    /// `ApprovalId`s.
    pub fn approvalPort(b: *ApprovalBroker) contracts.ApprovalPort {
        return .{ .ctx = b, .vtable = &port_vtable };
    }

    const port_vtable: contracts.ApprovalPort.VTable = .{ .present = portPresent, .await = portAwait, .cancel = portCancel };

    fn portPresent(ctx: *anyopaque, req: ApprovalRequest) anyerror!u64 {
        const b: *ApprovalBroker = @ptrCast(@alignCast(ctx));
        return @intFromEnum(try b.present(req));
    }

    fn portAwait(ctx: *anyopaque, id: u64, io: Io) Io.Cancelable!Answer {
        const b: *ApprovalBroker = @ptrCast(@alignCast(ctx));
        return b.await(@enumFromInt(id), io);
    }

    fn portCancel(ctx: *anyopaque, id: u64) void {
        const b: *ApprovalBroker = @ptrCast(@alignCast(ctx));
        b.cancel(@enumFromInt(id));
    }

    // ------------------------------------------------- requests

    /// Adds `req` (copied) to the inbox as pending.
    pub fn present(b: *ApprovalBroker, req: ApprovalRequest) Allocator.Error!ApprovalId {
        return b.presentChained(req, null);
    }

    /// `present`, for a request that re-asks `previous` (an edited input
    /// that still needs approval).
    pub fn presentChained(b: *ApprovalBroker, req: ApprovalRequest, previous: ?ApprovalId) Allocator.Error!ApprovalId {
        const it = try b.gpa.create(Item);
        it.* = .{ .arena = .init(b.gpa), .view = undefined };
        errdefer b.freeItem(it);
        var copy = try copyRequest(it.arena.allocator(), req);
        // Callers that leave the time out get the broker's clock.
        if (copy.created_ms == 0) copy.created_ms = Io.Clock.real.now(b.io).toMilliseconds();
        const id = blk: {
            b.mutex.lockUncancelable(b.io);
            defer b.mutex.unlock(b.io);
            const id: ApprovalId = @enumFromInt(b.next_id);
            it.view = .{ .id = id, .req = copy, .state = .pending, .previous = previous };
            try b.items.put(b.gpa, @intFromEnum(id), it);
            b.next_id += 1;
            b.recordLocked(it);
            break :blk id;
        };
        b.notify(id, .pending);
        return id;
    }

    /// Blocks until `id` is answered, cancelled or expires. Cancelling
    /// `io` cancels the request and returns `error.Canceled`. An unknown
    /// id is denied.
    pub fn await(b: *ApprovalBroker, id: ApprovalId, io: Io) Io.Cancelable!Answer {
        const it = blk: {
            b.mutex.lockUncancelable(b.io);
            defer b.mutex.unlock(b.io);
            break :blk b.items.get(@intFromEnum(id)) orelse return .{ .deny = "unknown approval request" };
        };
        it.done.wait(io) catch |e| {
            b.cancel(id);
            return e;
        };
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        return it.view.answer.?;
    }

    /// Answers a pending request from the view `by`; wakes its waiter.
    pub fn answer(b: *ApprovalBroker, id: ApprovalId, a: Answer, by: []const u8) AnswerError!void {
        const state = ApprovalState.of(a);
        {
            b.mutex.lockUncancelable(b.io);
            defer b.mutex.unlock(b.io);
            const it = b.items.get(@intFromEnum(id)) orelse return error.UnknownApproval;
            if (it.view.state != .pending) return error.AlreadyAnswered;
            if (a == .edit and !it.view.req.editable) return error.NotEditable;
            try b.closeLocked(it, state, a, by, true);
        }
        b.notify(id, state);
    }

    /// Withdraws a pending request (the agent's turn was cancelled): it
    /// leaves every view and its waiter gets a denial.
    pub fn cancel(b: *ApprovalBroker, id: ApprovalId) void {
        {
            b.mutex.lockUncancelable(b.io);
            defer b.mutex.unlock(b.io);
            const it = b.items.get(@intFromEnum(id)) orelse return;
            if (it.view.state != .pending) return;
            b.closeLocked(it, .cancelled, .{ .deny = "cancelled" }, null, true) catch return;
        }
        b.notify(id, .cancelled);
    }

    /// Expires the requests pending for `Options.timeout_ms` or longer at
    /// `now_ms`; returns how many.
    pub fn expireDue(b: *ApprovalBroker, now_ms: i64) u32 {
        if (b.opts.timeout_ms <= 0) return 0;
        var buf: [64]ApprovalId = undefined;
        var n: u32 = 0;
        var more = true;
        while (more) {
            var k: usize = 0;
            more = false;
            {
                b.mutex.lockUncancelable(b.io);
                defer b.mutex.unlock(b.io);
                for (b.items.values()) |it| {
                    if (it.view.state != .pending or now_ms - it.view.req.created_ms < b.opts.timeout_ms) continue;
                    if (k == buf.len) {
                        more = true;
                        break;
                    }
                    b.closeLocked(it, .expired, .{ .deny = "the approval request timed out" }, null, true) catch {
                        more = false;
                        break;
                    };
                    buf[k] = it.view.id;
                    k += 1;
                }
            }
            for (buf[0..k]) |id| b.notify(id, .expired);
            n += @intCast(k);
        }
        return n;
    }

    /// Sets the outcome (its strings copied), journals it (unless the
    /// journal already holds it) and wakes the waiter.
    fn closeLocked(b: *ApprovalBroker, it: *Item, state: ApprovalState, a: Answer, by: ?[]const u8, record: bool) Allocator.Error!void {
        const ar = it.arena.allocator();
        const copy = try copyAnswer(ar, a);
        const by_copy = if (by) |s| try ar.dupe(u8, s) else null;
        it.view.state = state;
        it.view.answer = copy;
        it.view.answered_by = by_copy;
        it.view.answered_ms = Io.Clock.real.now(b.io).toMilliseconds();
        if (record) b.recordLocked(it);
        it.done.set(b.io);
    }

    // ------------------------------------------------- views

    /// The item; its strings live until `prune`.
    pub fn get(b: *ApprovalBroker, id: ApprovalId) ?InboxItem {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        const it = b.items.get(@intFromEnum(id)) orelse return null;
        return it.view;
    }

    /// The items `f` selects, in inbox order (pending first, then oldest
    /// first), allocated in `arena`; their strings live until `prune`.
    pub fn list(b: *ApprovalBroker, arena: Allocator, f: inbox.Filter) Allocator.Error![]InboxItem {
        var out: std.ArrayList(InboxItem) = .empty;
        {
            b.mutex.lockUncancelable(b.io);
            defer b.mutex.unlock(b.io);
            for (b.items.values()) |it| if (inbox.matches(f, &it.view)) try out.append(arena, it.view);
        }
        std.mem.sort(InboxItem, out.items, {}, inbox.lessThan);
        return out.toOwnedSlice(arena);
    }

    /// Pending requests `f` selects (a badge, "3 approvals needed").
    pub fn pendingCount(b: *ApprovalBroker, f: inbox.Filter) usize {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        var n: usize = 0;
        for (b.items.values()) |it| n += @intFromBool(it.view.state == .pending and inbox.matches(f, &it.view));
        return n;
    }

    pub fn addListener(b: *ApprovalBroker, l: InboxListener) Allocator.Error!void {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        try b.listeners.append(b.gpa, l);
    }

    pub fn removeListener(b: *ApprovalBroker, ctx: *anyopaque) void {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        var i: usize = 0;
        while (i < b.listeners.items.len) {
            if (b.listeners.items[i].ctx == ctx) _ = b.listeners.orderedRemove(i) else i += 1;
        }
    }

    fn notify(b: *ApprovalBroker, id: ApprovalId, state: ApprovalState) void {
        var buf: [16]InboxListener = undefined;
        const n = blk: {
            b.mutex.lockUncancelable(b.io);
            defer b.mutex.unlock(b.io);
            const n = @min(buf.len, b.listeners.items.len);
            @memcpy(buf[0..n], b.listeners.items[0..n]);
            break :blk n;
        };
        for (buf[0..n]) |l| l.changed(l.ctx, id, state);
    }

    /// Frees the items that are no longer pending and were answered
    /// before `before_ms`; returns how many. Keep answers a caller may
    /// still hold (minutes, not milliseconds).
    pub fn prune(b: *ApprovalBroker, before_ms: i64) u32 {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        var n: u32 = 0;
        var i: usize = 0;
        while (i < b.items.count()) {
            const it = b.items.values()[i];
            if (it.view.state != .pending and (it.view.answered_ms orelse it.view.req.created_ms) < before_ms) {
                b.items.orderedRemoveAt(i);
                b.freeItem(it);
                n += 1;
            } else i += 1;
        }
        return n;
    }

    // ------------------------------------------------- journal

    fn recordLocked(b: *ApprovalBroker, it: *const Item) void {
        const r = b.opts.recorder orelse return;
        var aw: Io.Writer.Allocating = .init(b.gpa);
        defer aw.deinit();
        writeRecord(&aw.writer, &it.view) catch |e| {
            log.err("approval {f} not recorded: {t}", .{ it.view.id, e });
            return;
        };
        r.record(r.ctx, aw.written());
    }

    /// The sink a store load restores approval records into.
    pub fn restoreSink(b: *ApprovalBroker) RestoreSink {
        return .{ .ctx = b, .restore = restoreRecord };
    }

    fn restoreRecord(ctx: *anyopaque, v: std.json.Value) anyerror!void {
        const b: *ApprovalBroker = @ptrCast(@alignCast(ctx));
        try b.restore(v);
    }

    /// A sink that copies records as they are, for a viewer of another
    /// process's approvals (`zg review approvals`).
    pub fn mirrorSink(b: *ApprovalBroker) RestoreSink {
        return .{ .ctx = b, .restore = struct {
            fn f(ctx: *anyopaque, v: std.json.Value) anyerror!void {
                const self: *ApprovalBroker = @ptrCast(@alignCast(ctx));
                try self.put(v, .keep);
            }
        }.f };
    }

    /// A sink for the records other processes append later (`tail`): an
    /// answer to one of this broker's pending requests (`zg review
    /// approve`) is taken as if a view gave it.
    pub fn remoteSink(b: *ApprovalBroker) RestoreSink {
        return .{ .ctx = b, .restore = struct {
            fn f(ctx: *anyopaque, v: std.json.Value) anyerror!void {
                const self: *ApprovalBroker = @ptrCast(@alignCast(ctx));
                try self.applyRemote(v);
            }
        }.f };
    }

    /// Restores one record from a load (a later record of the same id
    /// replaces the earlier one). Pending requests come back `expired`,
    /// and nobody waits on them; `journalRestored` records that.
    pub fn restore(b: *ApprovalBroker, v: std.json.Value) !void {
        return b.put(v, .expire);
    }

    /// Journals the requests a load turned `expired`, so other processes
    /// stop showing them as waiting. After the load (the store's lock is
    /// free again).
    pub fn journalRestored(b: *ApprovalBroker) void {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        for (b.items.values()) |it| if (it.restored) {
            it.restored = false;
            b.recordLocked(it);
        };
    }

    /// Takes another process's answer to one of this broker's pending
    /// requests; anything else is ignored.
    pub fn applyRemote(b: *ApprovalBroker, v: std.json.Value) !void {
        var arena_state: std.heap.ArenaAllocator = .init(b.gpa);
        defer arena_state.deinit();
        const rec = try readRecord(arena_state.allocator(), v);
        const a = rec.answer orelse return;
        if (rec.state == .pending or rec.state == .cancelled) return;
        if (@intFromEnum(rec.id) >> 32 != b.opts.id_base >> 32) return;
        {
            b.mutex.lockUncancelable(b.io);
            defer b.mutex.unlock(b.io);
            const it = b.items.get(@intFromEnum(rec.id)) orelse return;
            if (it.view.state != .pending) return;
            if (a == .edit and !it.view.req.editable) return;
            // The journal already holds this answer.
            try b.closeLocked(it, rec.state, a, rec.answered_by orelse "cli", false);
        }
        b.notify(rec.id, rec.state);
    }

    fn put(b: *ApprovalBroker, v: std.json.Value, how: enum { expire, keep }) !void {
        const it = try b.gpa.create(Item);
        it.* = .{ .arena = .init(b.gpa), .view = undefined };
        errdefer b.freeItem(it);
        it.view = try readRecord(it.arena.allocator(), v);
        if (it.view.state == .pending and how == .expire) {
            it.view.state = .expired;
            it.view.answer = .{ .deny = "the approval request expired" };
            it.restored = true;
        }
        // A mirrored pending request has no waiter here and no answer.
        if (it.view.state != .pending) it.done.set(b.io);
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        const raw = @intFromEnum(it.view.id);
        const gop = try b.items.getOrPut(b.gpa, raw);
        if (gop.found_existing) b.freeItem(gop.value_ptr.*);
        gop.value_ptr.* = it;
        if (raw >> 32 == b.opts.id_base >> 32 and raw >= b.next_id) b.next_id = raw + 1;
    }
};

// ------------------------------------------------- copies

fn copyRequest(a: Allocator, req: ApprovalRequest) Allocator.Error!ApprovalRequest {
    var c = req;
    c.title = try a.dupe(u8, req.title);
    c.detail_json = try a.dupe(u8, req.detail_json);
    if (req.command) |s| c.command = try a.dupe(u8, s);
    if (req.rule_suggestion) |s| c.rule_suggestion = try a.dupe(u8, s);
    const risk = try a.alloc([]const u8, req.risk.len);
    for (req.risk, risk) |r, *d| d.* = try a.dupe(u8, r);
    c.risk = risk;
    c.actor = switch (req.actor) {
        .human => |h| .{ .human = try a.dupe(u8, h) },
        .agent => |g| .{ .agent = .{
            .session = try a.dupe(u8, g.session),
            .agent = try a.dupe(u8, g.agent),
            .parent = if (g.parent) |p| try a.dupe(u8, p) else null,
        } },
        .mcp_server => |s| .{ .mcp_server = try a.dupe(u8, s) },
        .system => .system,
    };
    return c;
}

fn copyAnswer(a: Allocator, ans: Answer) Allocator.Error!Answer {
    return switch (ans) {
        .allow_once => .allow_once,
        .allow_session => |s| .{ .allow_session = try a.dupe(u8, s) },
        .allow_always => |s| .{ .allow_always = try a.dupe(u8, s) },
        .deny => |s| .{ .deny = try a.dupe(u8, s) },
        .edit => |s| .{ .edit = try a.dupe(u8, s) },
    };
}

// ------------------------------------------------- records

const ActorRecord = struct {
    t: enum { human, agent, mcp_server, system },
    name: ?[]const u8 = null,
    session: ?[]const u8 = null,
    agent: ?[]const u8 = null,
    parent: ?[]const u8 = null,
};

const AnswerRecord = struct {
    t: std.meta.Tag(Answer),
    text: ?[]const u8 = null,
};

/// The journal record of an item (journal kind `approval`).
const Record = struct {
    id: u64,
    state: ApprovalState,
    kind: contracts.ApprovalKind,
    actor: ActorRecord,
    title: []const u8,
    detail: []const u8 = "",
    command: ?[]const u8 = null,
    risk: []const []const u8 = &.{},
    rule: ?[]const u8 = null,
    editable: bool = false,
    created_ms: i64,
    previous: ?u64 = null,
    answer: ?AnswerRecord = null,
    answered_by: ?[]const u8 = null,
    answered_ms: ?i64 = null,
};

pub fn writeRecord(w: *Io.Writer, it: *const InboxItem) std.json.Stringify.Error!void {
    const r = &it.req;
    const rec: Record = .{
        .id = @intFromEnum(it.id),
        .state = it.state,
        .kind = r.kind,
        .actor = switch (r.actor) {
            .human => |h| .{ .t = .human, .name = h },
            .agent => |g| .{ .t = .agent, .session = g.session, .agent = g.agent, .parent = g.parent },
            .mcp_server => |s| .{ .t = .mcp_server, .name = s },
            .system => .{ .t = .system },
        },
        .title = r.title,
        .detail = r.detail_json,
        .command = r.command,
        .risk = r.risk,
        .rule = r.rule_suggestion,
        .editable = r.editable,
        .created_ms = r.created_ms,
        .previous = if (it.previous) |p| @intFromEnum(p) else null,
        .answer = if (it.answer) |a| switch (a) {
            .allow_once => .{ .t = .allow_once },
            inline else => |s, t| .{ .t = t, .text = s },
        } else null,
        .answered_by = it.answered_by,
        .answered_ms = it.answered_ms,
    };
    try std.json.Stringify.value(rec, .{ .emit_null_optional_fields = false }, w);
}

/// Decodes `writeRecord`'s record; strings are allocated in `arena`.
pub fn readRecord(arena: Allocator, v: std.json.Value) !InboxItem {
    const rec = std.json.parseFromValueLeaky(Record, arena, v, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return error.InvalidRecord;
    const ar = rec.actor;
    return .{
        .id = @enumFromInt(rec.id),
        .state = rec.state,
        .req = .{
            .kind = rec.kind,
            .actor = switch (ar.t) {
                .human => .{ .human = ar.name orelse "" },
                .agent => .{ .agent = .{ .session = ar.session orelse "", .agent = ar.agent orelse "", .parent = ar.parent } },
                .mcp_server => .{ .mcp_server = ar.name orelse "" },
                .system => .system,
            },
            .title = rec.title,
            .detail_json = rec.detail,
            .command = rec.command,
            .risk = rec.risk,
            .rule_suggestion = rec.rule,
            .editable = rec.editable,
            .created_ms = rec.created_ms,
        },
        .previous = if (rec.previous) |p| @enumFromInt(p) else null,
        .answer = if (rec.answer) |a| switch (a.t) {
            .allow_once => .allow_once,
            inline else => |t| @unionInit(Answer, @tagName(t), a.text orelse ""),
        } else null,
        .answered_by = rec.answered_by,
        .answered_ms = rec.answered_ms,
    };
}

comptime {
    // The port is E16's type, not a copy (E16.F01.S01.T02).
    std.debug.assert(@TypeOf(ApprovalBroker.approvalPort) == fn (*ApprovalBroker) contracts.ApprovalPort);
}
