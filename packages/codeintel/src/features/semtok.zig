//! Semantic tokens (E07.F03.S02.T02): requests a document's tokens from
//! the first server that provides them (see `routing`) and feeds the
//! results into its `zg_syntax` `SemanticOverlay`, which maps late results
//! through later edits.
//!
//! Request choice per document:
//! - `full/delta` when the server supports it and the overlay has a
//!   result id;
//! - `range` for the visible lines plus one screen above and below, for
//!   documents over `range_threshold_lines` when the server supports it;
//! - `full` otherwise (or `range` when that is all the server has).
//!
//! Edits re-request after `debounce`; a ContentModified answer is retried
//! once; `workspace/semanticTokens/refresh` re-requests documents that are
//! visible and marks the rest for their next `onViewport`. A `null` result
//! keeps the previous tokens. Without a server (or with the setting off)
//! the overlay is cleared and lexical highlighting shows.
//!
//! Threads: everything runs on the UI thread except the response
//! callbacks, which hand results over through an inbox that `tick` drains.
//! Call `tick` once per frame after `Manager.tick` (which flushes edits, so
//! the document version a request names is the one the server has).

const SemTokDriver = @This();
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zg_core = @import("zg_core");
const zg_lsp = @import("zg_lsp");
const zg_editor = @import("zg_editor");
const zg_syntax = @import("zg_syntax");
const Manager = @import("../Manager.zig");

const Client = zg_lsp.client.Client;
const protocol = zg_lsp.protocol;
const Server = Manager.Server;
const api = zg_editor.model.api;
const DocumentRegistry = api.registry.DocumentRegistry;
const DocHandle = api.registry.DocHandle;
const DocumentSyntax = zg_editor.model.syntax.DocumentSyntax;
const SemanticOverlay = zg_syntax.SemanticOverlay;
const CompiledLegend = zg_syntax.semantic.legend.CompiledLegend;
const DeltaEdit = zg_syntax.semantic.overlay.DeltaEdit;

const log = std.log.scoped(.codeintel);

const M_full = .@"textDocument/semanticTokens/full";
const M_delta = .@"textDocument/semanticTokens/full/delta";
const M_range = .@"textDocument/semanticTokens/range";

/// Finds the highlighting state of a document (owned by the editor).
pub const SyntaxPort = struct {
    ctx: *anyopaque,
    get: *const fn (ctx: *anyopaque, h: DocHandle) ?*DocumentSyntax,
};

pub const Options = struct {
    /// `editor.semanticHighlighting`.
    enabled: bool = true,
    /// `lsp.semanticTokens.rangeThresholdLines`.
    range_threshold_lines: u64 = 20_000,
    debounce: Io.Duration = .fromMilliseconds(150),
    /// Asks the UI thread for a `tick` when a result arrives.
    waker: zg_core.runtime.Waker = .noop,
};

pub const Kind = enum { full, delta, range };

/// Lines `[first, end)`.
pub const LineRange = struct { first: u64, end: u64 };

const DocState = struct {
    /// The server the tokens come from, and its client when they were
    /// requested (a restarted server has a new client and legend).
    server: ?*Server = null,
    client: ?*Client = null,
    inflight: ?*Pending = null,
    /// Document version of the last applied result.
    applied: ?u64 = null,
    applied_range: ?LineRange = null,
    /// The version seen last and when it is due for a request.
    seen: u64 = 0,
    due_ns: i96 = 0,
    /// Request regardless of versions (refresh, failed apply, retry).
    force: bool = false,
    retried: bool = false,
    visible: ?LineRange = null,
    /// A refresh arrived while the document was not visible.
    stale: bool = false,
};

/// One request in flight; owned by the driver until drained.
const Pending = struct {
    drv: *SemTokDriver,
    h: DocHandle,
    server: *Server,
    client: *Client,
    kind: Kind,
    version: u64,
    range: LineRange = .{ .first = 0, .end = 0 },
    result: union(Kind) {
        full: Client.Result(M_full),
        delta: Client.Result(M_delta),
        range: Client.Result(M_range),
    } = undefined,

    fn deinitResult(p: *Pending) void {
        switch (p.result) {
            inline else => |r| r.deinit(),
        }
    }
};

const LegendEntry = struct { client: *Client, legend: CompiledLegend };

gpa: Allocator,
io: Io,
mgr: *Manager,
docs: *DocumentRegistry,
names: *zg_syntax.HighlightNames,
port: SyntaxPort,
opts: Options,
states: std.AutoArrayHashMapUnmanaged(DocHandle, DocState) = .empty,
legends: std.AutoHashMapUnmanaged(*Server, LegendEntry) = .empty,
inbox_mutex: Io.Mutex = .init,
inbox: std.ArrayList(*Pending) = .empty,
taken: std.ArrayList(*Pending) = .empty,
/// Requests sent, by kind (tests and the status view).
sent: [3]u32 = .{ 0, 0, 0 },
/// Requests whose results have not been drained yet.
outstanding: usize = 0,

/// `d` must not move once registered with `mgr` (refresh listener).
pub fn init(d: *SemTokDriver, mgr: *Manager, names: *zg_syntax.HighlightNames, port: SyntaxPort, opts: Options) Allocator.Error!void {
    d.* = .{
        .gpa = mgr.gpa,
        .io = mgr.rt.io,
        .mgr = mgr,
        .docs = mgr.docs,
        .names = names,
        .port = port,
        .opts = opts,
    };
    try mgr.onRefresh(.{ .ctx = d, .func = onServerRefresh });
}

/// Frees everything. Call after `Manager.deinit`: shutting the servers
/// down answers every request still in flight (`server_gone`), so no
/// callback can run after this.
pub fn deinit(d: *SemTokDriver) void {
    for (d.takeInbox()) |p| d.drop(p);
    d.taken.deinit(d.gpa);
    std.debug.assert(d.outstanding == 0);
    d.inbox.deinit(d.gpa);
    var it = d.legends.valueIterator();
    while (it.next()) |e| e.legend.deinit();
    d.legends.deinit(d.gpa);
    d.states.deinit(d.gpa);
}

fn drop(d: *SemTokDriver, p: *Pending) void {
    p.deinitResult();
    d.gpa.destroy(p);
    d.outstanding -= 1;
}

/// Starts highlighting `h` (opened in the manager) semantically.
pub fn track(d: *SemTokDriver, h: DocHandle) Allocator.Error!void {
    const gop = try d.states.getOrPut(d.gpa, h);
    if (!gop.found_existing) gop.value_ptr.* = .{};
}

/// Stops; a request in flight is ignored when it answers.
pub fn untrack(d: *SemTokDriver, h: DocHandle) void {
    _ = d.states.swapRemove(h);
}

/// The lines on screen changed (also after a refresh for hidden docs).
pub fn onViewport(d: *SemTokDriver, h: DocHandle, visible: LineRange) void {
    const st = d.states.getPtr(h) orelse return;
    st.visible = visible;
    if (st.stale) {
        st.stale = false;
        st.force = true;
    }
}

/// The document is no longer on screen.
pub fn onHidden(d: *SemTokDriver, h: DocHandle) void {
    const st = d.states.getPtr(h) orelse return;
    st.visible = null;
}

/// Re-requests visible documents; others when next shown.
pub fn refresh(d: *SemTokDriver) void {
    for (d.states.values()) |*st| {
        if (st.visible != null) st.force = true else st.stale = true;
    }
}

/// Turns semantic highlighting on or off (`editor.semanticHighlighting`).
pub fn setEnabled(d: *SemTokDriver, on: bool) void {
    if (d.opts.enabled == on) return;
    d.opts.enabled = on;
    for (d.states.keys(), d.states.values()) |h, *st| {
        if (!on) d.clear(h, st) else st.force = true;
    }
}

fn onServerRefresh(ctx: *anyopaque, _: *Server, f: Manager.RefreshFeature) void {
    const d: *SemTokDriver = @ptrCast(@alignCast(ctx));
    if (f == .semantic_tokens) d.refresh();
}

/// Applies results and sends due requests. Returns true when tokens
/// changed (redraw).
pub fn tick(d: *SemTokDriver) bool {
    var changed = false;
    for (d.takeInbox()) |p| {
        defer d.drop(p);
        const st = d.states.getPtr(p.h) orelse continue;
        if (st.inflight != p) continue;
        st.inflight = null;
        if (d.apply(p, st)) changed = true;
    }
    d.taken.clearRetainingCapacity();
    if (!d.opts.enabled) return changed;
    const now = Io.Clock.Timestamp.now(d.io, .awake).raw.nanoseconds;
    for (d.states.keys(), d.states.values()) |h, *st| d.maybeRequest(h, st, now);
    return changed;
}

/// When a debounced request falls due (`.awake` nanoseconds), if one is
/// waiting: schedule a `tick` for then (no frame may come otherwise).
pub fn nextDue(d: *const SemTokDriver) ?i96 {
    if (!d.opts.enabled) return null;
    var best: ?i96 = null;
    for (d.states.values()) |st| {
        if (st.server == null or st.inflight != null) continue;
        if (!st.force and st.applied == st.seen) continue;
        best = if (best) |b| @min(b, st.due_ns) else st.due_ns;
    }
    return best;
}

fn maybeRequest(d: *SemTokDriver, h: DocHandle, st: *DocState, now: i96) void {
    const doc = d.docs.get(h) orelse return;
    var servers: [1]*Server = undefined;
    const n = blk: {
        const full = d.mgr.serversFor(h, .semantic_tokens_full, &servers);
        break :blk if (full > 0) full else d.mgr.serversFor(h, .semantic_tokens_range, &servers);
    };
    if (n == 0) {
        if (st.server != null) d.clear(h, st);
        return;
    }
    const s = servers[0];
    if (st.server != s or st.client != s.client) {
        // A new source: its tokens replace the old ones entirely.
        if (st.server != null) d.clear(h, st);
        st.server = s;
        st.client = s.client;
        st.force = true;
    }
    if (st.inflight != null) return;
    const ver = doc.version;
    if (ver != st.seen) {
        st.seen = ver;
        st.due_ns = if (st.applied == null) now else now + d.opts.debounce.nanoseconds;
    }
    const range_mode = d.wantsRange(h, s);
    const want = st.force or st.applied != ver or
        (range_mode and !covers(st.applied_range, st.visible));
    if (!want or now < st.due_ns) return;
    d.send(h, st, s, ver, range_mode) catch |err| log.debug("semantic tokens: {t}", .{err});
}

fn covers(have: ?LineRange, visible: ?LineRange) bool {
    const v = visible orelse return true;
    const r = have orelse return false;
    return r.first <= v.first and r.end >= v.end;
}

fn wantsRange(d: *SemTokDriver, h: DocHandle, s: *Server) bool {
    const st = d.states.getPtr(h).?;
    if (st.visible == null) return false;
    const caps = s.client.?.caps() orelse return false;
    const match = d.mgr.docMatch(h);
    if (!caps.supports(.semantic_tokens_range, match)) return false;
    if (!caps.supports(.semantic_tokens_full, match)) return true;
    return d.docs.get(h).?.tree.lineCount() > d.opts.range_threshold_lines;
}

fn send(d: *SemTokDriver, h: DocHandle, st: *DocState, s: *Server, ver: u64, range_mode: bool) !void {
    const c = s.client.?;
    const caps = c.caps() orelse return;
    const match = d.mgr.docMatch(h) orelse return;
    _ = try d.legendFor(s, match);
    const uri = d.docs.uri(h) orelse return;
    const ds = d.port.get(d.port.ctx, h) orelse return;
    const prev_id: ?[]const u8 = if (ds.semantic) |*o| o.lastResultId() else null;

    const p = try d.gpa.create(Pending);
    errdefer d.gpa.destroy(p);
    p.* = .{ .drv = d, .h = h, .server = s, .client = c, .kind = .full, .version = ver };
    const opts: Client.ReqOpts = .{ .doc = match };
    const td: protocol.TextDocumentIdentifier = .{ .uri = uri };
    st.inflight = p;
    errdefer st.inflight = null;
    if (range_mode) {
        const lines = d.docs.get(h).?.tree.lineCount();
        const v = st.visible.?;
        const screen = v.end -| v.first;
        p.kind = .range;
        p.range = .{ .first = v.first -| screen, .end = @min(lines, v.end + screen) };
        _ = try c.request(M_range, .{ .textDocument = td, .range = .{
            .start = .{ .line = @intCast(p.range.first), .character = 0 },
            .end = .{ .line = @intCast(p.range.end), .character = 0 },
        } }, opts, .{ .ctx = p, .func = onRange });
    } else if (prev_id != null and !st.force and caps.supports(.semantic_tokens_delta, match)) {
        p.kind = .delta;
        _ = try c.request(M_delta, .{ .textDocument = td, .previousResultId = prev_id.? }, opts, .{ .ctx = p, .func = onDelta });
    } else {
        _ = try c.request(M_full, .{ .textDocument = td }, opts, .{ .ctx = p, .func = onFull });
    }
    d.sent[@intFromEnum(p.kind)] += 1;
    d.outstanding += 1;
    st.force = false;
}

fn onFull(ctx: ?*anyopaque, r: Client.Result(M_full)) void {
    const p: *Pending = @ptrCast(@alignCast(ctx.?));
    p.result = .{ .full = r };
    p.drv.push(p);
}

fn onDelta(ctx: ?*anyopaque, r: Client.Result(M_delta)) void {
    const p: *Pending = @ptrCast(@alignCast(ctx.?));
    p.result = .{ .delta = r };
    p.drv.push(p);
}

fn onRange(ctx: ?*anyopaque, r: Client.Result(M_range)) void {
    const p: *Pending = @ptrCast(@alignCast(ctx.?));
    p.result = .{ .range = r };
    p.drv.push(p);
}

/// Applies `p`'s result; true when the overlay changed.
fn apply(d: *SemTokDriver, p: *Pending, st: *DocState) bool {
    const failure: ?[]const u8 = switch (p.result) {
        inline else => |r| switch (r) {
            .ok => null,
            .content_modified => "content modified",
            .lsp_error => "error",
            .canceled => "canceled",
            .server_gone => "server gone",
            .timeout => "timeout",
            .unsupported => "unsupported",
        },
    };
    if (failure) |why| {
        if (std.mem.eql(u8, why, "content modified") and !st.retried) {
            st.retried = true;
            st.force = true;
        }
        return false;
    }
    if (!d.opts.enabled or st.client != p.client) return false;
    const doc = d.docs.get(p.h) orelse return false;
    const ds = d.port.get(d.port.ctx, p.h) orelse return false;
    const match = d.mgr.docMatch(p.h) orelse return false;
    const legend = d.legendFor(p.server, match) catch return false;
    const o = ds.semanticOverlay(&doc.tree) catch return false;
    o.enc = switch (p.client.encoding()) {
        .utf8 => .utf8,
        .utf16 => .utf16,
        .utf32 => .utf32,
    };
    const src = zg_editor.model.syntax.lineSource(&doc.tree);
    const ok = d.applyTo(o, p, legend, src) catch false orelse return false;
    if (!ok) {
        st.force = true;
        return false;
    }
    st.retried = false;
    st.applied = p.version;
    st.applied_range = if (p.kind == .range) p.range else null;
    return true;
}

/// Null: the server answered `null` (keep what is shown).
fn applyTo(d: *SemTokDriver, o: *SemanticOverlay, p: *Pending, legend: *CompiledLegend, src: zg_syntax.LineSource) Allocator.Error!?bool {
    switch (p.result) {
        .full => |r| {
            const t = r.ok.value orelse return null;
            return try o.applyFull(p.version, t.resultId, t.data, legend, src);
        },
        .range => |r| {
            const t = r.ok.value orelse return null;
            return try o.applyRange(p.version, p.range.first, p.range.end, t.data, legend, src);
        },
        .delta => |r| switch (r.ok.value orelse return null) {
            .semantic_tokens => |t| return try o.applyFull(p.version, t.resultId, t.data, legend, src),
            .semantic_tokens_delta => |t| {
                const edits = try d.gpa.alloc(DeltaEdit, t.edits.len);
                defer d.gpa.free(edits);
                for (t.edits, edits) |e, *x| x.* = .{ .start = e.start, .delete_count = e.deleteCount, .data = e.data orelse &.{} };
                return try o.applyDelta(p.version, t.resultId, edits, legend, src);
            },
        },
    }
}

fn clear(d: *SemTokDriver, h: DocHandle, st: *DocState) void {
    if (d.port.get(d.port.ctx, h)) |ds| ds.clearSemantic();
    st.server = null;
    st.client = null;
    st.applied = null;
    st.applied_range = null;
}

/// `s`'s legend, compiled once per client.
fn legendFor(d: *SemTokDriver, s: *Server, match: zg_lsp.client.doc_selector.DocMatch) !*CompiledLegend {
    const c = s.client orelse return error.NotRunning;
    const gop = try d.legends.getOrPut(d.gpa, s);
    if (gop.found_existing) {
        if (gop.value_ptr.client == c) return &gop.value_ptr.legend;
        gop.value_ptr.legend.deinit();
    }
    errdefer _ = d.legends.remove(s);
    const caps = c.caps() orelse return error.NotRunning;
    var arena: std.heap.ArenaAllocator = .init(d.gpa);
    defer arena.deinit();
    const legend: protocol.SemanticTokensLegend = if (caps.options(.semantic_tokens_full)) |o|
        o.legend
    else if (caps.options(.semantic_tokens_range)) |o|
        o.legend
    else if (caps.registrationOptions(.semantic_tokens_full, match) orelse caps.registrationOptions(.semantic_tokens_range, match)) |v|
        try std.json.parseFromValueLeaky(protocol.SemanticTokensLegend, arena.allocator(), v.object.get("legend") orelse return error.NoLegend, .{ .ignore_unknown_fields = true })
    else
        return error.NoLegend;
    gop.value_ptr.* = .{
        .client = c,
        .legend = try zg_syntax.SemanticLegend.compile(.{ .types = legend.tokenTypes, .modifiers = legend.tokenModifiers }, d.gpa, d.names),
    };
    return &gop.value_ptr.legend;
}

fn push(d: *SemTokDriver, p: *Pending) void {
    {
        d.inbox_mutex.lockUncancelable(d.io);
        defer d.inbox_mutex.unlock(d.io);
        d.inbox.append(d.gpa, p) catch {
            // Leaks the result rather than racing on it.
            log.err("semantic tokens: inbox out of memory", .{});
            return;
        };
    }
    d.opts.waker.wake();
}

fn takeInbox(d: *SemTokDriver) []const *Pending {
    d.inbox_mutex.lockUncancelable(d.io);
    defer d.inbox_mutex.unlock(d.io);
    std.mem.swap(std.ArrayList(*Pending), &d.inbox, &d.taken);
    return d.taken.items;
}
