//! Async spans and flows (E14.F02.S01.T03): one cheap API for work whose
//! begin and end may happen on different threads (agent turns, provider
//! requests, SSE streams, tool calls, MCP/LSP/DAP requests, indexing jobs,
//! SCM operations), and flows that tie a cause to the frame showing its
//! effect (input -> frame, stream chunk -> frame). Ids, not thread nesting,
//! pair begin and end. Everything compiles to nothing with
//! `-Dtracing=off`.

const std = @import("std");
const zg_core = @import("zg_core");
const taxonomy = @import("taxonomy.zig");

const trace = zg_core.trace;
const Site = trace.Site;

/// True when trace zones are compiled in.
pub const enabled = trace.enabled;

/// A span id: process-unique, never 0.
pub const AsyncId = u64;

var next_id: std.atomic.Value(u64) = .init(1);

/// A fresh span id.
pub fn newId() AsyncId {
    return next_id.fetchAdd(1, .monotonic);
}

/// The static site of a taxonomy name.
pub fn siteOf(comptime n: taxonomy.Name) *const Site {
    return &struct {
        const site: Site = .{ .name = n.str(), .file = "", .line = 0 };
    }.site;
}

const flow_site: Site = .{ .name = "flow", .file = "", .line = 0 };

/// Begins span `n` with `id` on this thread's ring.
pub inline fn asyncBegin(comptime n: taxonomy.Name, id: AsyncId) void {
    if (!enabled) return;
    trace.recordRaw(.async_begin, siteOf(n), @bitCast(id));
}

/// Ends span `n` with `id` (any thread).
pub inline fn asyncEnd(comptime n: taxonomy.Name, id: AsyncId) void {
    if (!enabled) return;
    trace.recordRaw(.async_end, siteOf(n), @bitCast(id));
}

/// Marks an instant `n` on the lane of span `id` (e.g. `ai.first_token`
/// on an `ai.request`), with an optional value recorded as a counter.
pub inline fn asyncInstant(comptime n: taxonomy.Name, id: AsyncId, value: i64) void {
    if (!enabled) return;
    trace.recordRaw(.async_instant, siteOf(n), @bitCast(id));
    if (value != 0) trace.recordRaw(.counter, siteOf(n), value);
}

/// The innermost open zone on this thread starts flow `id`.
pub inline fn flowOut(id: u64) void {
    if (!enabled) return;
    trace.recordRaw(.flow_out, &flow_site, @bitCast(id));
}

/// The innermost open zone on this thread ends flow `id`.
pub inline fn flowIn(id: u64) void {
    if (!enabled) return;
    trace.recordRaw(.flow_in, &flow_site, @bitCast(id));
}

/// The flow id of input event `input_seq` (E01 sets the top bit).
pub fn inputFlowId(input_seq: u64) u64 {
    return (@as(u64, 1) << 63) | input_seq;
}

/// Longest label an async span may carry (Debug check against content
/// such as prompts, file text or URLs leaking into traces).
pub const max_arg_len = 128;

/// True when `arg` is short enough to be a label, not content. Producers
/// that attach labels (model id, tool name, method name, host) check them
/// with this before attaching them.
pub fn checkArg(arg: []const u8) bool {
    return arg.len <= max_arg_len and std.mem.indexOfAny(u8, arg, "\n?") == null;
}

/// A span begun and ended in one scope (zero-sized when tracing is off).
pub const Span = if (enabled) struct {
    id: AsyncId,
    site: *const Site,

    /// `newId` plus `asyncBegin`.
    pub fn begin(comptime n: taxonomy.Name) Span {
        const id = newId();
        asyncBegin(n, id);
        return .{ .id = id, .site = siteOf(n) };
    }

    /// Ends the span.
    pub fn end(s: Span) void {
        trace.recordRaw(.async_end, s.site, @bitCast(s.id));
    }
} else struct {
    /// No-op when tracing is compiled out.
    pub inline fn begin(comptime _: taxonomy.Name) Span {
        return .{};
    }
    /// No-op when tracing is compiled out.
    pub inline fn end(_: Span) void {}
};

test "async: newId unique across 8 threads x 100 k" {
    const gpa = std.testing.allocator;
    const per = 100_000;
    const ids = try gpa.alloc(u64, 8 * per);
    defer gpa.free(ids);
    const W = struct {
        fn run(out: []u64) void {
            for (out) |*o| o.* = newId();
        }
    };
    var threads: [8]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, W.run, .{ids[i * per .. (i + 1) * per]});
    for (threads) |t| t.join();
    std.mem.sort(u64, ids, {}, std.sort.asc(u64));
    for (ids[1..], ids[0 .. ids.len - 1]) |b, a| try std.testing.expect(b != a);
    try std.testing.expect(ids[0] != 0);
}

test "async: begin/end on different threads pair by id after collect" {
    if (!enabled) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var events: std.ArrayList(trace.Event) = .empty;
    defer events.deinit(gpa);
    try trace.collect(gpa, &events);
    events.clearRetainingCapacity();
    const id = newId();
    const B = struct {
        fn run(i: u64) void {
            asyncBegin(.ai_request, i);
        }
        fn stop(i: u64) void {
            asyncEnd(.ai_request, i);
        }
    };
    const t1 = try std.Thread.spawn(.{}, B.run, .{id});
    t1.join();
    const t2 = try std.Thread.spawn(.{}, B.stop, .{id});
    t2.join();
    try trace.collect(gpa, &events);
    var begin_tid: ?u32 = null;
    var end_tid: ?u32 = null;
    for (events.items) |e| {
        if (@as(u64, @bitCast(e.value)) != id) continue;
        const site: *const Site = @ptrFromInt(e.site_or_name);
        try std.testing.expectEqualStrings("ai.request", site.name);
        switch (@as(trace.Kind, @enumFromInt(e.kind))) {
            .async_begin => begin_tid = e.tid,
            .async_end => end_tid = e.tid,
            else => {},
        }
    }
    try std.testing.expect(begin_tid != null and end_tid != null);
}

test "async: disabled build emits nothing" {
    if (enabled) {
        try std.testing.expect(@sizeOf(Span) > 0);
    } else {
        comptime std.debug.assert(@sizeOf(Span) == 0);
        const s = Span.begin(.ai_turn);
        s.end();
    }
}

test "async: debug rejects long arg string" {
    try std.testing.expect(checkArg("claude-model-x"));
    try std.testing.expect(!checkArg("a" ** 129));
    try std.testing.expect(!checkArg("https://h/p?token=1"));
    try std.testing.expect(!checkArg("line one\nline two"));
}
