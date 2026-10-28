//! Workspace diagnostics (E07.F02.S02.T01): servers that offer
//! `workspace/diagnostic` (`workspaceDiagnostics: true`) are asked for the
//! whole workspace, closed files included, with the result ids of the
//! reports they sent before. A server may hold the request open and
//! stream reports as partial results (`$/progress` on the request's
//! `partialResultToken`); each one is applied as it arrives. When the
//! request completes it is sent again (no sooner than `min_interval`
//! after the previous one), which makes it a long poll.
//!
//! ContentModified, and ServerCancelled with `retriggerRequest`, ask again
//! at once; an error waits `error_backoff`; a server that does not
//! support the request is not asked again until a refresh. UI thread,
//! except the answer callbacks, which only queue.

const WorkspacePull = @This();
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zg_core = @import("zg_core");
const zg_lsp = @import("zg_lsp");
const Manager = @import("../Manager.zig");

const Client = zg_lsp.client.Client;
const protocol = zg_lsp.protocol;
const M = .@"workspace/diagnostic";

const log = std.log.scoped(.codeintel);

pub const Options = struct {
    /// The shortest time between two requests to one server.
    min_interval: Io.Duration = .fromSeconds(2),
    /// The wait after an error answer.
    error_backoff: Io.Duration = .fromSeconds(30),
    waker: zg_core.runtime.Waker = .noop,
};

/// Receives the reports (UI thread).
pub const Sink = struct {
    ctx: *anyopaque,
    /// A full report for `uri`.
    full: *const fn (ctx: *anyopaque, server: *Manager.Server, uri: []const u8, items: []const protocol.Diagnostic) void,
};

const State = struct {
    busy: bool = false,
    /// Bumped per request: answers of an older one are dropped.
    round: u64 = 0,
    due_ns: ?i96 = 0,
    /// The request's partial-result token (in `token_buf`).
    token: ?protocol.ProgressToken = null,
    token_buf: [32]u8 = undefined,
    /// The last result id per document URI.
    ids: std.StringArrayHashMapUnmanaged([]u8) = .empty,
    /// Requests sent (tests).
    sent: u32 = 0,

    fn deinit(st: *State, gpa: Allocator) void {
        for (st.ids.keys(), st.ids.values()) |k, v| {
            gpa.free(k);
            gpa.free(v);
        }
        st.ids.deinit(gpa);
    }
};

/// One request in flight: the callback and partial sink context.
const Req = struct {
    w: *WorkspacePull,
    server: u32,
    round: u64,
};

const Msg = union(enum) {
    partial: struct { server: u32, round: u64, json: []u8 },
    done: struct { server: u32, round: u64, req: *Req, result: Client.Result(M) },
};

gpa: Allocator,
io: Io,
mgr: *Manager,
opts: Options,
states: std.AutoArrayHashMapUnmanaged(u32, State) = .empty,
mutex: Io.Mutex = .init,
inbox: std.ArrayList(Msg) = .empty,
taken: std.ArrayList(Msg) = .empty,

pub fn init(mgr: *Manager, opts: Options) WorkspacePull {
    return .{ .gpa = mgr.gpa, .io = mgr.rt.io, .mgr = mgr, .opts = opts };
}

/// Call after `Manager.deinit` (every request has answered by then).
pub fn deinit(w: *WorkspacePull) void {
    for (w.takeInbox()) |m| w.freeMsg(m);
    w.taken.deinit(w.gpa);
    w.inbox.deinit(w.gpa);
    for (w.states.values()) |*st| st.deinit(w.gpa);
    w.states.deinit(w.gpa);
}

/// `workspace/diagnostic/refresh`: ask every server again now.
pub fn refresh(w: *WorkspacePull) void {
    for (w.states.values()) |*st| if (!st.busy) {
        st.due_ns = 0;
    };
}

/// Requests sent to `server` so far.
pub fn sentTo(w: *const WorkspacePull, server: u32) u32 {
    return if (w.states.get(server)) |st| st.sent else 0;
}

pub fn nextDue(w: *const WorkspacePull) ?i96 {
    var due: ?i96 = null;
    for (w.states.values()) |st| if (!st.busy) if (st.due_ns) |d| {
        due = if (due) |x| @min(x, d) else d;
    };
    return due;
}

/// Applies what arrived, follows the running servers and sends due
/// requests.
pub fn tick(w: *WorkspacePull, now_ns: i96, sink: Sink) void {
    for (w.takeInbox()) |m| {
        defer w.freeMsg(m);
        w.handle(m, now_ns, sink);
    }
    w.taken.clearRetainingCapacity();
    w.follow();
    for (w.states.keys(), w.states.values()) |id, *st| {
        if (st.busy) continue;
        const due = st.due_ns orelse continue;
        if (now_ns < due) continue;
        w.send(id, st) catch |e| {
            log.debug("workspace/diagnostic: {t}", .{e});
            st.due_ns = now_ns + w.opts.error_backoff.nanoseconds;
        };
    }
}

fn serverOf(w: *WorkspacePull, id: u32) ?*Manager.Server {
    const list = w.mgr.serverList();
    if (id >= list.len or list[id].status != .running) return null;
    return list[id];
}

/// Adds running servers that offer workspace pulls; forgets stopped ones.
fn follow(w: *WorkspacePull) void {
    for (w.mgr.serverList()) |s| {
        if (s.status != .running or w.states.contains(s.id)) continue;
        const caps = (s.client orelse continue).caps() orelse continue;
        if (!caps.supports(.workspace_diagnostic, null)) continue;
        w.states.put(w.gpa, s.id, .{}) catch return;
    }
    var i = w.states.count();
    while (i > 0) {
        i -= 1;
        if (w.serverOf(w.states.keys()[i]) != null) continue;
        // Its request answered (server_gone) or will be dropped by round.
        w.states.values()[i].deinit(w.gpa);
        w.states.swapRemoveAt(i);
    }
}

fn send(w: *WorkspacePull, id: u32, st: *State) !void {
    const s = w.serverOf(id) orelse return;
    const c = s.client.?;
    var prev: std.ArrayList(protocol.PreviousResultId) = .empty;
    defer prev.deinit(w.gpa);
    for (st.ids.keys(), st.ids.values()) |uri, v| try prev.append(w.gpa, .{ .uri = uri, .value = v });
    st.round += 1;
    const req = try w.gpa.create(Req);
    errdefer w.gpa.destroy(req);
    req.* = .{ .w = w, .server = id, .round = st.round };
    const token = try w.mgr.progress.issue(id, &st.token_buf);
    errdefer w.mgr.progress.release(id, token);
    try w.mgr.progress.addPartial(id, token, .{ .ctx = req, .func = onPartial });
    _ = try c.request(M, .{ .previousResultIds = prev.items, .partialResultToken = token }, .{ .priority = .background }, .{ .ctx = req, .func = onDone });
    st.token = token;
    st.busy = true;
    st.due_ns = null;
    st.sent += 1;
}

// Reader thread.
fn onPartial(ctx: ?*anyopaque, value_json: []const u8) void {
    const req: *Req = @ptrCast(@alignCast(ctx.?));
    const json = req.w.gpa.dupe(u8, value_json) catch return;
    req.w.push(.{ .partial = .{ .server = req.server, .round = req.round, .json = json } }) catch req.w.gpa.free(json);
}

// Reader thread (or the caller's, when the request is rejected).
fn onDone(ctx: ?*anyopaque, r: Client.Result(M)) void {
    const req: *Req = @ptrCast(@alignCast(ctx.?));
    const w = req.w;
    w.push(.{ .done = .{ .server = req.server, .round = req.round, .req = req, .result = r } }) catch {
        r.deinit();
        w.gpa.destroy(req);
    };
}

fn push(w: *WorkspacePull, m: Msg) !void {
    {
        w.mutex.lockUncancelable(w.io);
        defer w.mutex.unlock(w.io);
        try w.inbox.append(w.gpa, m);
    }
    w.opts.waker.wake();
}

fn takeInbox(w: *WorkspacePull) []const Msg {
    w.mutex.lockUncancelable(w.io);
    defer w.mutex.unlock(w.io);
    std.mem.swap(std.ArrayList(Msg), &w.inbox, &w.taken);
    return w.taken.items;
}

fn freeMsg(w: *WorkspacePull, m: Msg) void {
    switch (m) {
        .partial => |p| w.gpa.free(p.json),
        .done => |d| {
            d.result.deinit();
            w.gpa.destroy(d.req);
        },
    }
}

fn handle(w: *WorkspacePull, m: Msg, now_ns: i96, sink: Sink) void {
    switch (m) {
        .partial => |p| {
            const st = w.states.getPtr(p.server) orelse return;
            if (p.round != st.round) return;
            const s = w.serverOf(p.server) orelse return;
            var arena: std.heap.ArenaAllocator = .init(w.gpa);
            defer arena.deinit();
            const v = std.json.parseFromSliceLeaky(protocol.WorkspaceDiagnosticReportPartialResult, arena.allocator(), p.json, .{ .ignore_unknown_fields = true, .allocate = .alloc_if_needed }) catch |e| {
                log.debug("workspace/diagnostic partial result: {t}", .{e});
                return;
            };
            w.apply(st, s, v.items, sink);
        },
        .done => |d| {
            const st = w.states.getPtr(d.server) orelse return;
            if (d.round != st.round) return;
            if (st.token) |t| w.mgr.progress.release(d.server, t);
            st.token = null;
            st.busy = false;
            const min = now_ns + w.opts.min_interval.nanoseconds;
            switch (d.result) {
                .ok => |o| {
                    if (w.serverOf(d.server)) |s| w.apply(st, s, o.value.items, sink);
                    st.due_ns = min;
                },
                .content_modified => st.due_ns = now_ns,
                .canceled, .server_gone => st.due_ns = min,
                .lsp_error, .timeout => st.due_ns = now_ns + w.opts.error_backoff.nanoseconds,
                // Until a refresh.
                .unsupported => st.due_ns = null,
            }
        },
    }
}

fn apply(w: *WorkspacePull, st: *State, s: *Manager.Server, items: []const protocol.WorkspaceDocumentDiagnosticReport, sink: Sink) void {
    for (items) |it| switch (it) {
        .workspace_full_document_diagnostic_report => |r| {
            sink.full(sink.ctx, s, r.uri, r.items);
            w.remember(st, r.uri, r.resultId);
        },
        .workspace_unchanged_document_diagnostic_report => |r| w.remember(st, r.uri, r.resultId),
    };
}

fn remember(w: *WorkspacePull, st: *State, uri: []const u8, id: ?[]const u8) void {
    if (st.ids.getIndex(uri)) |i| {
        w.gpa.free(st.ids.values()[i]);
        const k = st.ids.keys()[i];
        if (id) |x| if (w.gpa.dupe(u8, x)) |v| {
            st.ids.values()[i] = v;
            return;
        } else |_| {};
        st.ids.swapRemoveAt(i);
        w.gpa.free(k);
        return;
    }
    const x = id orelse return;
    const k = w.gpa.dupe(u8, uri) catch return;
    const v = w.gpa.dupe(u8, x) catch {
        w.gpa.free(k);
        return;
    };
    st.ids.put(w.gpa, k, v) catch {
        w.gpa.free(k);
        w.gpa.free(v);
    };
}
