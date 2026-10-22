//! `InlineEditSession` (E12.F06.S01.T01): one Ctrl/Cmd+K edit of a
//! selection. It builds the prompt, streams the model's answer through
//! `StreamParser` and `StreamDiff`, and keeps the live edits of the region
//! for the editor to show as a pending change. When the answer is
//! complete the edits become a changeset (origin `inline_edit`,
//! presentation `.inline_`), which stays in the queue until the user
//! accepts or rejects it, also after the editor loses focus.
//!
//! The model is a port (`ModelPort`): zg_review sits below zg_ai, so the
//! app binds it to an E10 provider stream. The prompt's system part is
//! stable across edits (cacheable); a prediction (the region) goes only
//! to models that support predicted outputs, and the request carries no
//! tools or output caps, which predicted outputs exclude.
//!
//! Follow-ups rewrite the last output, still diffed against the original
//! region; an earlier changeset is discarded. Cancel stops the stream and
//! discards the changeset. An edit inside the region cancels the session
//! ("Selection changed: cancelled"); one before it shifts the region.
//!
//! Owner thread: the queue's. The port must call the sink there (the app
//! posts stream events to the UI thread).

const std = @import("std");
const proto = @import("zg_ai_proto");
const model = @import("../../model/root.zig");
const apply = @import("../../apply/root.zig");
const prompt = @import("prompt.zig");
const StreamParser = @import("stream_parser.zig").StreamParser;
const StreamDiff = @import("stream_diff.zig").StreamDiff;

const Allocator = std.mem.Allocator;
const ChangeSet = model.changeset.ChangeSet;
const Replace = model.changeset.Replace;
const ChangesetId = model.ChangesetId;

/// Lines of context around the selection.
pub const context_before = 80;
pub const context_after = 40;

/// What the model is asked.
pub const Request = struct {
    /// Stable instructions and rules: cacheable.
    system: []const u8,
    user: []const u8,
    /// The text the answer will mostly repeat (predicted outputs).
    prediction: ?[]const u8 = null,
};

/// Where stream events go (call on the owner thread).
pub const Sink = struct {
    ctx: *anyopaque,
    chunk: *const fn (ctx: *anyopaque, stream: u64, text: []const u8) void,
    /// The stream ended; `err` when it failed.
    end: *const fn (ctx: *anyopaque, stream: u64, err: ?anyerror) void,
};

/// The model, bound by the app to an E10 provider.
pub const ModelPort = struct {
    ctx: *anyopaque,
    /// Starts a streamed answer; returns its id.
    start: *const fn (ctx: *anyopaque, req: *const Request, sink: Sink) anyerror!u64,
    /// Stops stream `id`; its `end` may still come and is ignored.
    cancel: *const fn (ctx: *anyopaque, id: u64) void,
    predicted_outputs: bool = false,
};

/// Tells secret text apart (E16).
pub const Secrets = struct {
    ctx: *anyopaque,
    isSecret: *const fn (ctx: *anyopaque, text: []const u8) bool,
};

pub const Options = struct {
    path: []const u8,
    language: []const u8 = "",
    /// The whole file as the editor has it (borrowed for the session).
    text: []const u8,
    /// The selection, bytes `[start, end)` of `text` (empty: insert).
    region: [2]usize,
    instruction: []const u8,
    /// Ask a question instead of editing.
    question: bool = false,
    diagnostics: []const []const u8 = &.{},
    rules: []const u8 = "",
    secrets: ?Secrets = null,
    ref: proto.AgentRef,
    workspace: []const u8,
};

pub const State = enum {
    streaming,
    /// The rewrite is complete and in the queue (`changeset`).
    ready,
    /// A question's answer is complete (`answer`).
    answered,
    accepted,
    rejected,
    cancelled,
    failed,
};

pub const Listener = struct {
    ctx: *anyopaque,
    changed: *const fn (ctx: *anyopaque, s: *InlineEditSession) void,
};

pub const InlineEditSession = struct {
    gpa: Allocator,
    q: *model.Queue,
    applier: *apply.Applier,
    port: ModelPort,
    o: Options,
    arena: std.heap.ArenaAllocator,
    state: State = .streaming,
    /// Why the session failed or was cancelled.
    reason: []const u8 = "",
    stream: u64 = 0,
    parser: StreamParser,
    diff: StreamDiff,
    /// The region's edits so far (region coordinates).
    edits: ?ChangeSet = null,
    /// Earlier rounds (instructions and outputs), for follow-ups.
    history: std.ArrayList(prompt.Turn) = .empty,
    instruction: []const u8,
    changeset: ?ChangesetId = null,
    listener: ?Listener = null,

    /// Starts the first round.
    pub fn start(gpa: Allocator, q: *model.Queue, applier: *apply.Applier, port: ModelPort, o: Options) !*InlineEditSession {
        if (o.region[0] > o.region[1] or o.region[1] > o.text.len) return error.BadRegion;
        const s = try gpa.create(InlineEditSession);
        errdefer gpa.destroy(s);
        s.* = .{
            .gpa = gpa,
            .q = q,
            .applier = applier,
            .port = port,
            .o = o,
            .arena = .init(gpa),
            .parser = .init(gpa),
            .diff = undefined,
            .instruction = o.instruction,
        };
        errdefer s.arena.deinit();
        const sel = o.text[o.region[0]..o.region[1]];
        if (o.secrets) |sc| if (sc.isSecret(sc.ctx, sel)) return error.SecretSelection;
        s.diff = try .init(gpa, sel);
        errdefer s.diff.deinit();
        errdefer s.parser.deinit();
        try s.round();
        return s;
    }

    pub fn deinit(s: *InlineEditSession) void {
        if (s.state == .streaming) s.port.cancel(s.port.ctx, s.stream);
        if (s.edits) |*e| e.deinit();
        s.parser.deinit();
        s.diff.deinit();
        s.history.deinit(s.gpa);
        s.arena.deinit();
        s.gpa.destroy(s);
    }

    /// The selection's text in the original file.
    pub fn original(s: *const InlineEditSession) []const u8 {
        return s.o.text[s.o.region[0]..s.o.region[1]];
    }

    /// The rewrite (or answer) so far.
    pub fn output(s: *const InlineEditSession) []const u8 {
        return s.parser.text();
    }

    /// The region's edits shifted to file coordinates (caller owns).
    pub fn fileEdits(s: *const InlineEditSession, gpa: Allocator) !?ChangeSet {
        const e = s.edits orelse return null;
        const reps = try gpa.alloc(Replace, e.replaces.len);
        defer gpa.free(reps);
        for (e.replaces, reps) |r, *o| o.* = .{ .range = .{ .start = r.range.start + s.o.region[0], .end = r.range.end + s.o.region[0] }, .text = r.text };
        return try ChangeSet.fromEdits(gpa, s.o.text.len, reps);
    }

    fn round(s: *InlineEditSession) !void {
        const a = s.arena.allocator();
        const sel = s.original();
        const before_start = lineStartBack(s.o.text, s.o.region[0], context_before);
        const after_end = lineEndForward(s.o.text, s.o.region[1], context_after);
        var before = s.o.text[before_start..s.o.region[0]];
        var after = s.o.text[s.o.region[1]..after_end];
        if (s.o.secrets) |sc| {
            if (sc.isSecret(sc.ctx, before)) before = "";
            if (sc.isSecret(sc.ctx, after)) after = "";
        }
        const mode: prompt.Mode = if (s.o.question) .question else if (sel.len == 0) .insert else .edit;
        const parts = try prompt.buildPrompt(a, .{
            .path = s.o.path,
            .language = s.o.language,
            .before = before,
            .selection = sel,
            .after = after,
            .diagnostics = s.o.diagnostics,
            .rules = s.o.rules,
            .history = s.history.items,
            .instruction = s.instruction,
            .mode = mode,
        });
        const req: Request = .{
            .system = parts.system,
            .user = parts.user,
            .prediction = if (s.port.predicted_outputs) parts.prediction else null,
        };
        s.state = .streaming;
        s.stream = try s.port.start(s.port.ctx, &req, .{ .ctx = s, .chunk = chunkFn, .end = endFn });
    }

    fn chunkFn(ctx: *anyopaque, stream: u64, text: []const u8) void {
        const s: *InlineEditSession = @ptrCast(@alignCast(ctx));
        if (stream != s.stream or s.state != .streaming) return;
        s.onChunk(text) catch |e| s.fail(@errorName(e));
    }

    fn endFn(ctx: *anyopaque, stream: u64, err: ?anyerror) void {
        const s: *InlineEditSession = @ptrCast(@alignCast(ctx));
        if (stream != s.stream or s.state != .streaming) return;
        if (err) |e| return s.fail(@errorName(e));
        s.onEnd() catch |e| s.fail(@errorName(e));
    }

    fn onChunk(s: *InlineEditSession, text: []const u8) !void {
        if (s.o.question) {
            try s.parser.buf.appendSlice(s.gpa, text);
        } else {
            try s.parser.feed(text);
            try s.redo(false);
        }
        s.notify();
    }

    fn onEnd(s: *InlineEditSession) !void {
        if (s.o.question) {
            s.parser.ended = true;
            s.parser.state = .closed;
            s.state = .answered;
            return s.notify();
        }
        s.parser.finish();
        try s.redo(true);
        try s.submit();
        s.state = .ready;
        s.notify();
    }

    fn redo(s: *InlineEditSession, final: bool) !void {
        const next = try s.diff.update(s.parser.text(), final, s.gpa);
        if (s.edits) |*e| e.deinit();
        s.edits = next;
    }

    /// Puts the final edits in the queue.
    fn submit(s: *InlineEditSession) !void {
        if (s.edits == null or s.edits.?.replaces.len == 0) return;
        var fe = (try s.fileEdits(s.gpa)).?;
        defer fe.deinit();
        const b = try s.q.beginBatch(.{
            .origin = .{ .inline_edit = .{ .ref = s.o.ref, .instruction = s.instruction } },
            .label = s.instruction,
            .workspace = s.o.workspace,
            .created_ms = 0,
        });
        errdefer s.q.abortBatch(b);
        try s.q.addEdit(b, s.o.path, s.o.text, null, &fe);
        s.changeset = try s.q.commitBatch(b, .{ .presentation = .inline_ });
    }

    /// Asks again with `instruction`, rewriting the last output.
    pub fn followUp(s: *InlineEditSession, instruction: []const u8) !void {
        if (s.state != .ready and s.state != .answered) return error.NotReady;
        const a = s.arena.allocator();
        try s.history.append(s.gpa, .{ .instruction = try a.dupe(u8, s.instruction), .output = try a.dupe(u8, s.output()) });
        s.instruction = try a.dupe(u8, instruction);
        try s.drop(.discarded);
        s.parser.deinit();
        s.parser = .init(s.gpa);
        const orig = s.diff.original;
        s.diff.deinit();
        s.diff = try .init(s.gpa, orig);
        if (s.edits) |*e| e.deinit();
        s.edits = null;
        try s.round();
        s.notify();
    }

    /// Stops the stream (if any) and discards the changeset.
    pub fn cancel(s: *InlineEditSession, reason: []const u8) !void {
        switch (s.state) {
            .streaming => s.port.cancel(s.port.ctx, s.stream),
            .ready, .answered => {},
            else => return,
        }
        try s.drop(.discarded);
        s.state = .cancelled;
        s.reason = reason;
        s.notify();
    }

    /// Applies every hunk (the user asked for it: no further review).
    pub fn accept(s: *InlineEditSession) !apply.ApplyResult {
        if (s.state != .ready) return error.NotReady;
        const id = s.changeset orelse {
            // Nothing changed.
            s.state = .accepted;
            s.notify();
            return .{ .ok = .{ .apply = null, .files = 0, .hunks = 0 } };
        };
        const r = try s.applier.acceptAll(id);
        if (r == .ok) s.state = .accepted;
        s.notify();
        return r;
    }

    pub fn reject(s: *InlineEditSession) !void {
        if (s.state != .ready) return error.NotReady;
        try s.drop(.rejected);
        s.state = .rejected;
        s.notify();
    }

    /// The editor changed bytes `[start, end)` of the file to `new_len`
    /// bytes: inside the region cancels the session, before it shifts it.
    pub fn documentEdited(s: *InlineEditSession, from: usize, to: usize, new_len: usize) !void {
        if (s.state != .streaming and s.state != .ready) return;
        const r = s.o.region;
        if (to <= r[0]) {
            const delta: isize = @as(isize, @intCast(new_len)) - @as(isize, @intCast(to - from));
            s.o.region = .{ @intCast(@as(isize, @intCast(r[0])) + delta), @intCast(@as(isize, @intCast(r[1])) + delta) };
            return;
        }
        if (from >= r[1]) return;
        return s.cancel("Selection changed: cancelled");
    }

    fn drop(s: *InlineEditSession, to: model.State) !void {
        const id = s.changeset orelse return;
        s.changeset = null;
        const cs = s.q.getMut(id) orelse return;
        if (cs.state != .pending) return;
        const from = cs.state;
        try model.transition(cs, to);
        s.q.persist(id);
        s.q.emit(.{ .state = .{ .cs = id, .from = from, .to = to } });
    }

    fn fail(s: *InlineEditSession, why: []const u8) void {
        s.state = .failed;
        s.reason = why;
        s.notify();
    }

    fn notify(s: *InlineEditSession) void {
        if (s.listener) |l| l.changed(l.ctx, s);
    }
};

/// The start of the line `n` lines above the one holding `at`.
fn lineStartBack(text: []const u8, at: usize, n: usize) usize {
    var i = at;
    var lines: usize = 0;
    while (i > 0) {
        if (text[i - 1] == '\n') {
            if (lines == n) return i;
            lines += 1;
        }
        i -= 1;
    }
    return 0;
}

/// The end (past its line end) of the line `n` lines below the one
/// holding `at`.
fn lineEndForward(text: []const u8, at: usize, n: usize) usize {
    var i = at;
    var lines: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\n') {
            lines += 1;
            if (lines > n) return i + 1;
        }
    }
    return text.len;
}
