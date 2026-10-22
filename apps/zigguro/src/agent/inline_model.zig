//! `InlineModel` (E12.F06.S01.T01): binds the inline edit session's
//! `ModelPort` to an E10 provider. Each answer streams on a worker; text
//! deltas are batched and posted to the UI thread, where the session's
//! sink runs. The request is one cacheable system part and one user
//! message, with no tools.
//!
//! Cancel cancels the worker's stream and waits for it; that stream's
//! end is never delivered. A stream whose drain is still posted is freed
//! by that drain, so cancelling (also from inside a chunk) never leaves a
//! dangling call in the mailbox.
//!
//! No E10 provider forwards a prediction yet, so the port reports no
//! predicted outputs and the session sends none.
//!
//! UI thread only, except the worker side of `Stream`.

const std = @import("std");
const zg_ai = @import("zg_ai");
const zg_gui = @import("zg_gui");
const zg_review = @import("zg_review");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const proto = zg_ai.proto;
const inline_edit = zg_review.assist.inline_edit;

pub const InlineModel = struct {
    gpa: Allocator,
    io: Io,
    app: *zg_gui.App,
    provider: zg_ai.Provider,
    model: []const u8,
    max_output_tokens: u32 = 4096,
    next_id: u64 = 1,
    streams: std.ArrayList(*Stream) = .empty,

    pub const Options = struct {
        /// Borrowed; must outlive the model.
        model: []const u8,
        max_output_tokens: u32 = 4096,
    };

    pub fn init(gpa: Allocator, io: Io, app: *zg_gui.App, provider: zg_ai.Provider, o: Options) InlineModel {
        return .{ .gpa = gpa, .io = io, .app = app, .provider = provider, .model = o.model, .max_output_tokens = o.max_output_tokens };
    }

    /// Cancels every running stream.
    pub fn deinit(m: *InlineModel) void {
        while (m.streams.items.len > 0) cancelFn(m, m.streams.items[0].id);
        m.streams.deinit(m.gpa);
    }

    pub fn port(m: *InlineModel) inline_edit.ModelPort {
        return .{ .ctx = m, .start = startFn, .cancel = cancelFn };
    }

    /// Streams still running or not yet delivered.
    pub fn running(m: *const InlineModel) usize {
        return m.streams.items.len;
    }

    fn startFn(ctx: *anyopaque, req: *const inline_edit.session.Request, sink: inline_edit.session.Sink) anyerror!u64 {
        const m: *InlineModel = @ptrCast(@alignCast(ctx));
        const st = try Stream.create(m, req, sink);
        errdefer st.destroy();
        try m.streams.append(m.gpa, st);
        errdefer _ = m.streams.pop();
        st.future = try m.io.concurrent(Stream.run, .{st});
        m.next_id += 1;
        return st.id;
    }

    fn cancelFn(ctx: *anyopaque, id: u64) void {
        const m: *InlineModel = @ptrCast(@alignCast(ctx));
        const st = m.take(id) orelse return;
        st.cancelled = true;
        st.future.cancel(m.io);
        st.retire();
    }

    /// Removes stream `id` from the running list.
    fn take(m: *InlineModel, id: u64) ?*Stream {
        for (m.streams.items, 0..) |st, i| if (st.id == id) return m.streams.orderedRemove(i);
        return null;
    }
};

/// One streamed answer. The worker fills `pending` under `mutex`; the
/// UI thread drains it.
const Stream = struct {
    gpa: Allocator,
    io: Io,
    m: *InlineModel,
    id: u64,
    sink: inline_edit.session.Sink,
    arena: std.heap.ArenaAllocator,
    req: zg_ai.Request = undefined,
    future: Io.Future(void) = undefined,
    mutex: Io.Mutex = .init,
    pending: std.ArrayList(u8) = .empty,
    done: bool = false,
    err: ?anyerror = null,
    posted: std.atomic.Value(bool) = .init(false),
    // UI thread only.
    cancelled: bool = false,
    draining: bool = false,

    fn create(m: *InlineModel, r: *const inline_edit.session.Request, sink: inline_edit.session.Sink) !*Stream {
        const st = try m.gpa.create(Stream);
        st.* = .{ .gpa = m.gpa, .io = m.io, .m = m, .id = m.next_id, .sink = sink, .arena = .init(m.gpa) };
        errdefer st.destroy();
        const a = st.arena.allocator();
        const system = try a.alloc(zg_ai.request.SystemPart, 1);
        system[0] = .{ .text = try a.dupe(u8, r.system), .cache_break = true };
        const content = try a.alloc(proto.ContentBlock, 1);
        content[0] = .{ .text = .{ .text = try a.dupe(u8, r.user) } };
        const messages = try a.alloc(proto.Message, 1);
        messages[0] = .{ .role = .user, .content = content };
        st.req = .{
            .model = m.model,
            .system = system,
            .messages = messages,
            .max_output_tokens = m.max_output_tokens,
        };
        return st;
    }

    fn destroy(st: *Stream) void {
        st.pending.deinit(st.gpa);
        st.arena.deinit();
        st.gpa.destroy(st);
    }

    /// Worker: runs the provider stream, then posts its end.
    fn run(st: *Stream) void {
        var arena: std.heap.ArenaAllocator = .init(st.gpa);
        defer arena.deinit();
        const sink: zg_ai.EventSink = .{ .ctx = st, .emit = emit };
        const res = st.m.provider.stream(st.io, arena.allocator(), &st.req, sink);
        st.mutex.lockUncancelable(st.io);
        st.done = true;
        st.err = if (res) |_| null else |e| e;
        st.mutex.unlock(st.io);
        st.post();
    }

    fn emit(ctx: *anyopaque, ev: zg_ai.StreamEvent) void {
        const st: *Stream = @ptrCast(@alignCast(ctx));
        const d = switch (ev) {
            .text_delta => |d| d,
            else => return,
        };
        st.mutex.lockUncancelable(st.io);
        defer st.mutex.unlock(st.io);
        st.pending.appendSlice(st.gpa, d.text) catch {
            st.err = error.OutOfMemory;
            return;
        };
        st.post();
    }

    fn post(st: *Stream) void {
        if (!st.posted.swap(true, .acq_rel)) st.m.app.post(.{ .ctx = st, .f = drain }) catch st.posted.store(false, .release);
    }

    /// A cancelled stream: freed now, or by the drain still posted.
    fn retire(st: *Stream) void {
        if (st.draining or st.posted.load(.acquire)) return;
        st.destroy();
    }

    /// UI thread: hands the batched text, then the end, to the sink.
    fn drain(ctx: *anyopaque, _: *zg_gui.App) void {
        const st: *Stream = @ptrCast(@alignCast(ctx));
        st.posted.store(false, .release);
        if (st.cancelled) return st.retire();

        st.mutex.lockUncancelable(st.io);
        var text = st.pending;
        st.pending = .empty;
        const done = st.done;
        const err = st.err;
        st.mutex.unlock(st.io);
        defer text.deinit(st.gpa);

        st.draining = true;
        if (text.items.len > 0) st.sink.chunk(st.sink.ctx, st.id, text.items);
        st.draining = false;
        if (st.cancelled) return st.retire();
        if (!done) return;

        _ = st.m.take(st.id);
        st.future.await(st.io);
        const sink = st.sink;
        const id = st.id;
        // Chunks already delivered still make a partial answer the session
        // can use; a cancelled worker's error never reaches here.
        st.destroy();
        sink.end(sink.ctx, id, err);
    }
};

const testing = std.testing;
const scripted = zg_ai.scripted;

const Got = struct {
    text: std.ArrayList(u8) = .empty,
    ends: u32 = 0,
    err: ?anyerror = null,
    /// Cancel the stream from inside its first chunk.
    cancel_in_chunk: ?*InlineModel = null,

    fn sink(g: *Got) inline_edit.session.Sink {
        return .{ .ctx = g, .chunk = chunk, .end = end };
    }

    fn chunk(ctx: *anyopaque, id: u64, text: []const u8) void {
        const g: *Got = @ptrCast(@alignCast(ctx));
        g.text.appendSlice(testing.allocator, text) catch unreachable;
        if (g.cancel_in_chunk) |m| {
            g.cancel_in_chunk = null;
            m.port().cancel(m, id);
        }
    }

    fn end(ctx: *anyopaque, _: u64, err: ?anyerror) void {
        const g: *Got = @ptrCast(@alignCast(ctx));
        g.ends += 1;
        g.err = err;
    }
};

const Fx = struct {
    rt: zg_core.Runtime,
    t: *zg_gui.testing.TestApp,
    sp: *scripted.ScriptedProvider,
    provider: zg_ai.Provider,
    m: InlineModel,

    const Root = struct {
        pub fn build(_: *@This(), _: *zg_gui.Ui) void {}
    };
    var root: Root = .{};

    fn init(fx: *Fx, turns: []const []const scripted.ScriptedProvider.Step) !void {
        const gpa = testing.allocator;
        fx.rt.initTesting();
        fx.rt.bindUiThread(.noop);
        fx.t = try zg_gui.testing.TestApp.init(gpa, .{ .size = .{ .w = 100, .h = 100 }, .root = .of(&root) });
        fx.t.app.attachRuntime(&fx.rt);
        fx.sp = try scripted.ScriptedProvider.init(gpa, turns, .all);
        fx.provider = fx.sp.provider();
        fx.m = .init(gpa, testing.io, &fx.t.app, fx.provider, .{ .model = "m" });
    }

    fn deinit(fx: *Fx) void {
        fx.m.deinit();
        _ = fx.t.settle();
        fx.provider.deinit();
        fx.t.deinit();
        _ = fx.rt.deinit();
    }

    /// Settles until `done` holds.
    fn until(fx: *Fx, comptime done: fn (*Fx, *Got) bool, g: *Got) !void {
        var spins: u32 = 0;
        while (!done(fx, g)) : (spins += 1) {
            try testing.expect(spins < 5000);
            _ = fx.t.settle();
            testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
        }
    }

    fn ended(_: *Fx, g: *Got) bool {
        return g.ends > 0;
    }
};

const zg_core = @import("zg_core");

fn deltas(comptime parts: []const []const u8) []const scripted.ScriptedProvider.Step {
    comptime var steps: []const scripted.ScriptedProvider.Step = &.{
        .{ .event = .{ .message_start = .{ .id = "msg", .model = "m" } } },
        .{ .event = .{ .block_start = .{ .index = 0, .kind = .text } } },
    };
    inline for (parts) |p| steps = steps ++ [_]scripted.ScriptedProvider.Step{.{ .event = .{ .text_delta = .{ .index = 0, .text = p } } }};
    return steps ++ [_]scripted.ScriptedProvider.Step{
        .{ .event = .{ .block_stop = .{ .index = 0 } } },
        .{ .event = .{ .stop = .end_turn } },
    };
}

test "inline model: streams text deltas to the sink, then the end" {
    var fx: Fx = undefined;
    try fx.init(&.{deltas(&.{ "<rewrite>\n  const", " x = 1;\n", "</rewrite>" })});
    defer fx.deinit();
    var g: Got = .{};
    defer g.text.deinit(testing.allocator);

    const p = fx.m.port();
    try testing.expect(!p.predicted_outputs);
    const id = try p.start(p.ctx, &.{ .system = "Rewrite the selection.", .user = "File: a.ts", .prediction = "ignored" }, g.sink());
    try fx.until(Fx.ended, &g);

    try testing.expectEqual(@as(u64, 1), id);
    try testing.expectEqualStrings("<rewrite>\n  const x = 1;\n</rewrite>", g.text.items);
    try testing.expectEqual(@as(u32, 1), g.ends);
    try testing.expect(g.err == null);
    try testing.expectEqual(@as(usize, 0), fx.m.running());

    // One cacheable system part and the user message; no tools.
    const req = fx.sp.requests()[0];
    try testing.expectEqualStrings("m", req.model);
    try testing.expectEqualStrings("Rewrite the selection.", req.system[0].text);
    try testing.expect(req.system[0].cache_break);
    try testing.expectEqualStrings("File: a.ts", req.messages[0].content[0].text.text);
    try testing.expectEqual(@as(usize, 0), req.tools.len);
    try testing.expect(req.extra_body_json == null);
}

test "inline model: a failed call ends with its error" {
    var fx: Fx = undefined;
    try fx.init(&.{&.{.{ .fail = error.Overloaded }}});
    defer fx.deinit();
    var g: Got = .{};
    defer g.text.deinit(testing.allocator);

    const p = fx.m.port();
    _ = try p.start(p.ctx, &.{ .system = "s", .user = "u" }, g.sink());
    try fx.until(Fx.ended, &g);
    try testing.expectEqual(@as(?anyerror, error.Overloaded), g.err);
}

test "inline model: cancel stops the stream and drops its end" {
    var fx: Fx = undefined;
    try fx.init(&.{
        &.{ .{ .delay_ms = 60_000 }, .{ .event = .{ .text_delta = .{ .index = 0, .text = "late" } } } },
        deltas(&.{ "a", "b" }),
    });
    defer fx.deinit();
    var g: Got = .{};
    defer g.text.deinit(testing.allocator);

    const p = fx.m.port();
    const id = try p.start(p.ctx, &.{ .system = "s", .user = "u" }, g.sink());
    p.cancel(p.ctx, id);
    try testing.expectEqual(@as(usize, 0), fx.m.running());
    for (0..20) |_| _ = fx.t.settle();
    try testing.expectEqual(@as(u32, 0), g.ends);
    try testing.expectEqualStrings("", g.text.items);

    // Cancelling from inside a chunk frees the stream once its drain is done.
    var h: Got = .{ .cancel_in_chunk = &fx.m };
    defer h.text.deinit(testing.allocator);
    _ = try p.start(p.ctx, &.{ .system = "s", .user = "u" }, h.sink());
    const Seen = struct {
        fn f(_: *Fx, x: *Got) bool {
            return x.text.items.len > 0;
        }
    };
    try fx.until(Seen.f, &h);
    for (0..20) |_| _ = fx.t.settle();
    try testing.expectEqual(@as(u32, 0), h.ends);
    try testing.expectEqual(@as(usize, 0), fx.m.running());
}

test "inline model: drives an inline edit session to a queued changeset" {
    const gpa = testing.allocator;
    var fx: Fx = undefined;
    try fx.init(&.{deltas(&.{ "<rewrite>\n  const x", " = 1;\n</rewrite>" })});
    defer fx.deinit();

    var blobs: zg_review.model.MemBlobs = .init(gpa);
    defer blobs.deinit();
    var disk: zg_review.apply.MemFiles = .init(gpa);
    defer disk.deinit();
    var history: zg_review.model.History = .init(gpa, null);
    defer history.deinit();
    const q = try zg_review.model.Queue.init(gpa, testing.io, .{ .root = "/w", .blobs = blobs.blobs() });
    defer q.deinit();
    var ap: zg_review.apply.Applier = .init(gpa, testing.io, q, disk.files(), &history);

    const file = "function f() {\n  let x = 1;\n  return x;\n}\n";
    try disk.put("a.ts", file, false);
    const s = try inline_edit.InlineEditSession.start(gpa, q, &ap, fx.m.port(), .{
        .path = "a.ts",
        .language = "typescript",
        .text = file,
        .region = .{ 15, 28 },
        .instruction = "make it const",
        .ref = .{ .session = 1 },
        .workspace = "/w",
    });
    defer s.deinit();

    var spins: u32 = 0;
    while (s.state == .streaming) : (spins += 1) {
        try testing.expect(spins < 5000);
        _ = fx.t.settle();
        testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try testing.expectEqual(inline_edit.session.State.ready, s.state);
    try testing.expect(s.changeset != null);
    try testing.expect(try s.accept() == .ok);
    try testing.expectEqualStrings("function f() {\n  const x = 1;\n  return x;\n}\n", disk.get("a.ts").?);
}
