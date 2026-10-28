//! The inspection model of one debug session (E07.F06.S04): the call
//! stacks (`stack`), the selected frame's variables (`vars`), sources
//! without a path, evaluation and completions (`eval`) and the watches
//! (`watches`), and the exception a stop broke on (`exception`), as the debug views (E07.F07) and the agent tools
//! (E07.F05.S02) show them.
//!
//! The app forwards the session's changes from its `DebugManager`
//! listener (`onChange`, any thread) and calls `pump` on the UI thread,
//! which applies what arrived and sends the next requests. Everything
//! else is UI thread only.
//!
//! Generations: requests carry the session generation of the stop they
//! were sent in. On `continued` the model marks itself running and drops
//! results that arrive later; the old frames and values stay until the
//! next stop's replace them.

const Inspector = @This();
const std = @import("std");
const Channel = @import("Channel.zig");
const StackModel = @import("StackModel.zig");
const VariablesModel = @import("VariablesModel.zig");
const sources = @import("sources.zig");
const Evaluator = @import("Evaluator.zig");
const Watches = @import("Watches.zig");
const exception_mod = @import("exception.zig");
const DebugSession = @import("../session/DebugSession.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const log = std.log.scoped(.dap_inspect);

pub const FrameRow = StackModel.FrameRow;
pub const NodeId = VariablesModel.NodeId;
pub const Exception = exception_mod.Exception;

/// What the model asks of the app.
pub const Host = struct {
    ctx: ?*anyopaque = null,
    /// A frame's source without a path arrived: open `uri` read-only with
    /// `text` (valid during the call).
    open_source: ?*const fn (ctx: ?*anyopaque, uri: []const u8, text: []const u8, mime_type: ?[]const u8) void = null,
    /// A frame was selected: reveal its line.
    reveal: ?*const fn (ctx: ?*anyopaque, row: *const FrameRow) void = null,
};

pub const Options = struct {
    host: Host = .{},
    /// Frames per `stackTrace` page.
    page: u32 = 20,
    /// Large arrays are paged into buckets (`start`/`count`); off for an
    /// adapter known to ignore them.
    paging: bool = true,
    /// Children kept without paging.
    max_children: u32 = 10_000,
    /// Nodes fetched again after a stop, and how deep below the scopes.
    reexpand_nodes: u32 = 200,
    reexpand_depth: u8 = 3,
    /// Hover evaluation may use the `repl` context when the adapter has
    /// no `hover` one (`debug.hoverEvaluateWithRepl`).
    hover_with_repl: bool = false,
    /// A watch not answered within this is `timed_out`.
    watch_timeout: Io.Duration = .fromSeconds(2),
};

gpa: Allocator,
io: Io,
opts: Options,
session: ?*DebugSession,
ch: Channel,
stack: StackModel,
vars: VariablesModel,
eval: Evaluator,
watches: Watches,
source_cache: sources.Cache,
/// The generation of the last stop applied.
gen: u64 = 0,
/// Between `continued` and the next stop (or before the first).
running: bool = true,
/// The exception the last stop broke on (until the program runs).
exception: ?Exception = null,

/// `port` is normally `Channel.Port.ofSession(s)` with `session = s`.
pub fn init(i: *Inspector, gpa: Allocator, io: Io, session: ?*DebugSession, port: Channel.Port, opts: Options) Allocator.Error!void {
    i.* = .{
        .gpa = gpa,
        .io = io,
        .opts = opts,
        .session = session,
        .ch = try .init(gpa, io, port),
        .stack = .init(gpa),
        .vars = .init(gpa),
        .eval = .init(gpa),
        .watches = .init(gpa),
        .source_cache = .init(gpa),
    };
}

/// For a session: requests go to it.
pub fn initSession(i: *Inspector, gpa: Allocator, io: Io, s: *DebugSession, opts: Options) Allocator.Error!void {
    return i.init(gpa, io, s, .ofSession(s), opts);
}

pub fn deinit(i: *Inspector) void {
    i.clearException();
    i.eval.deinit();
    i.watches.deinit();
    i.vars.deinit();
    i.stack.deinit();
    i.source_cache.deinit();
    i.ch.deinit();
    i.* = undefined;
}

/// From a `DebugManager` listener (any thread).
pub fn onChange(i: *Inspector, s: *DebugSession, change: DebugSession.Change) void {
    if (i.session != s) return;
    switch (change) {
        .stack, .continued => i.ch.post(change, ""),
        .invalidated => {
            const body = s.lastInvalidated(i.gpa) catch return;
            defer i.gpa.free(body);
            i.ch.post(change, body);
        },
        .state => switch (s.state()) {
            .terminated, .failed => i.ch.post(change, ""),
            else => {},
        },
        else => {},
    }
}

/// The generation requests may use now; null while the program runs.
pub fn liveGen(i: *const Inspector) ?u64 {
    if (i.running) return null;
    return i.gen;
}

pub fn stopped(i: *const Inspector) bool {
    return !i.running;
}

/// Sends a request tagged with the current generation.
pub fn send(i: *Inspector, command: []const u8, args: []const u8, tag: Channel.Tag) bool {
    return i.ch.send(command, args, tag, i.gen);
}

/// Applies what arrived; true when anything did. UI thread.
pub fn pump(i: *Inspector) bool {
    // Deadlines first: an answer after its watch's deadline is late even
    // when it arrives in this batch.
    const timed_out = i.watches.tick(Io.Timestamp.now(i.io, .awake));
    const items = i.ch.take() catch return timed_out;
    defer i.gpa.free(items);
    for (items) |it| {
        defer it.deinit(i.gpa);
        i.apply(it) catch |e| log.warn("inspection update dropped: {t}", .{e});
    }
    return items.len > 0 or timed_out;
}

fn apply(i: *Inspector, it: Channel.Item) Allocator.Error!void {
    switch (it.what) {
        .change => |c| switch (c.change) {
            .stack => {
                const s = i.session orelse return;
                var arena: std.heap.ArenaAllocator = .init(i.gpa);
                defer arena.deinit();
                const pf = (try s.prefetch(arena.allocator())) orelse return;
                if (pf.gen != s.generation()) return;
                try i.applyStop(pf);
            },
            .continued => {
                i.running = true;
                i.clearException();
                i.watches.markNotStopped();
            },
            .invalidated => i.applyInvalidated(c.bytes),
            .state => {
                i.running = true;
                i.clearException();
                i.eval.failAll("the debug session ended");
                i.watches.markNotStopped();
                i.stack.clear();
                i.vars.clear();
                i.source_cache.clear();
            },
            else => {},
        },
        .result => |r| try i.deliver(r.tag, r.gen, r.ok, r.bytes),
    }
}

/// A stop, with what the session already fetched: the first page of the
/// stopped thread's stack and its top frame's scopes.
pub fn applyStop(i: *Inspector, pf: DebugSession.Prefetch) Allocator.Error!void {
    i.gen = pf.gen;
    i.running = false;
    i.clearException();
    i.vars.newStop(pf.gen);
    try i.askException(pf.thread);
    _ = try i.stack.applyPage(pf.thread, 0, i.opts.page, pf.gen, true, pf.stack);
    if (i.stack.autoSelect(pf.thread)) |idx| {
        const row = &i.stack.frames(pf.thread)[idx];
        i.stack.selected_index = idx;
        i.selectRow(pf.thread, row, if (idx == 0) pf.scopes else null);
    } else i.stack.selected_ = null;
    // The second page alongside the scopes.
    if (!i.stack.complete(pf.thread)) i.stack.loadMore(pf.thread, i.opts.page);
}

fn clearException(i: *Inspector) void {
    if (i.exception) |*e| e.deinit();
    i.exception = null;
}

/// A stop on an exception: what it was (`exceptionInfo`, else the stop's
/// own text).
fn askException(i: *Inspector, thread: i64) Allocator.Error!void {
    const s = i.session orelse return;
    var arena: std.heap.ArenaAllocator = .init(i.gpa);
    defer arena.deinit();
    const ts = try s.threads(arena.allocator());
    const t = for (ts) |t| {
        if (t.id == thread) break t;
    } else return;
    const r = t.stop_reason orelse return;
    const signal = std.mem.eql(u8, r.reason, "signal");
    if (!signal and !std.mem.eql(u8, r.reason, "exception")) return;
    if (!signal and (i.ch.caps().supportsExceptionInfoRequest orelse false)) {
        var buf: [48]u8 = undefined;
        const args = std.fmt.bufPrint(&buf, "{{\"threadId\":{d}}}", .{thread}) catch unreachable;
        if (i.send("exceptionInfo", args, .{ .kind = .exception_info, .a = @bitCast(thread) })) return;
    }
    i.exception = try exception_mod.fromStop(i.gpa, thread, r.description, r.text, signal);
}

/// Selects `row` of `thread` (`scopes`: its `scopes` body when known).
pub fn selectRow(i: *Inspector, thread: i64, row: *const FrameRow, scopes: ?[]const u8) void {
    i.stack.selected_ = .{ .thread = thread, .frame = row.id };
    i.vars.setFrame(row.id, row.name, scopes);
    i.watches.reevaluate(row.id);
    if (i.opts.host.reveal) |f| f(i.opts.host.ctx, row);
    const src = row.source orelse return;
    if (!sources.needsFetch(src.path, src.reference)) return;
    const ref = src.reference.?;
    if (i.source_cache.get(ref)) |c| return i.openSource(ref, c);
    var buf: [96]u8 = undefined;
    const args = std.fmt.bufPrint(&buf, "{{\"source\":{{\"sourceReference\":{d}}},\"sourceReference\":{d}}}", .{ ref, ref }) catch unreachable;
    _ = i.send("source", args, .{ .kind = .source, .a = @bitCast(ref) });
}

fn openSource(i: *Inspector, ref: i64, c: sources.Content) void {
    const f = i.opts.host.open_source orelse return;
    const uri = sources.uri(i.gpa, i.ch.port.id, ref) catch return;
    defer i.gpa.free(uri);
    f(i.opts.host.ctx, uri, c.text, c.mime_type);
}

/// Applies a request's result (`pump` does; benchmarks call it directly).
pub fn deliver(i: *Inspector, tag: Channel.Tag, gen: u64, ok: bool, bytes: []const u8) Allocator.Error!void {
    if (tag.kind == .source) {
        // Source references hold for the whole session.
        if (!ok) return;
        var arena: std.heap.ArenaAllocator = .init(i.gpa);
        defer arena.deinit();
        const c = sources.decode(arena.allocator(), bytes) orelse return;
        const ref: i64 = @bitCast(tag.a);
        return i.openSource(ref, try i.source_cache.put(ref, c));
    }
    if (tag.kind == .evaluate or tag.kind == .completions) {
        // REPL input works while the program runs; references count only
        // for the stop they came from.
        return i.eval.apply(tag.a, gen, gen == i.gen and !i.running, ok, bytes);
    }
    if (gen != i.gen or i.running) {
        if (tag.kind == .set_value) i.vars.failSet(tag.b, "the program is running");
        return;
    }
    switch (tag.kind) {
        .stack_page => {
            const thread: i64 = @bitCast(tag.a);
            if (try i.stack.applyPage(thread, @intCast(tag.b), @intCast(tag.c), gen, ok, bytes)) |t| {
                if (i.stack.reselectRow(t)) |row| i.selectRow(thread, row, null);
            }
        },
        .scopes => try i.vars.applyScopes(@bitCast(tag.a), gen, ok, bytes),
        .variables => try i.vars.applyVariables(@enumFromInt(tag.a), tag.b, gen, ok, bytes),
        .lazy => try i.vars.applyLazy(@enumFromInt(tag.a), gen, ok, bytes),
        .set_value => try i.vars.applySet(tag.b, gen, ok, bytes),
        .exception_info => {
            const thread: i64 = @bitCast(tag.a);
            i.clearException();
            i.exception = if (ok) exception_mod.parse(i.gpa, thread, bytes) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidBody => try exception_mod.fromStop(i.gpa, thread, null, null, false),
            } else try exception_mod.fromStop(i.gpa, thread, null, bytes, false);
        },
        .source, .evaluate, .completions => unreachable,
    }
}

fn applyInvalidated(i: *Inspector, body: []const u8) void {
    if (i.running) return; // the next stop fetches everything
    const B = struct { areas: ?[]const []const u8 = null, threadId: ?i64 = null, stackFrameId: ?i64 = null };
    var arena: std.heap.ArenaAllocator = .init(i.gpa);
    defer arena.deinit();
    const b = std.json.parseFromSliceLeaky(B, arena.allocator(), body, .{ .ignore_unknown_fields = true }) catch B{};
    var stacks = false;
    var vars = false;
    const all: []const []const u8 = &.{"all"};
    const areas = b.areas orelse all;
    if (areas.len == 0) stacks = true;
    for (areas) |a| {
        if (std.mem.eql(u8, a, "all") or std.mem.eql(u8, a, "stacks")) stacks = true;
        if (std.mem.eql(u8, a, "variables")) vars = true;
    }
    if (stacks) {
        const thread = b.threadId orelse (if (i.stack.selected()) |s| s.thread else return);
        // The page re-selects the frame, which fetches the scopes.
        return i.stack.refresh(thread);
    }
    if (vars) i.vars.refresh();
}

/// Waits until nothing is in flight or queued, applying results (tests
/// and headless callers).
pub fn settle(i: *Inspector, timeout: Io.Duration) error{Timeout}!void {
    const deadline = Io.Timestamp.now(i.io, .awake).addDuration(timeout);
    while (true) {
        _ = i.pump();
        if (i.ch.inflight() == 0) {
            if (!i.pump()) return;
            continue;
        }
        if (Io.Timestamp.now(i.io, .awake).nanoseconds > deadline.nanoseconds) return error.Timeout;
        i.ch.wait(.fromMilliseconds(20));
    }
}
