//! The outcome reporter (E12.F03.S04.T01): tells the agent that made a
//! changeset what review did with it, so its next steps build on what
//! landed and not on what it proposed.
//!
//! The reporter follows the queue's `decided` and `state` events and
//! sums the decisions per changeset. It sends an `Outcome` to the
//! `OutcomeSink` (E10's glue turns it into a system reminder; see
//! `docs/contracts.md`):
//! - when the changeset is closed (`final`);
//! - 2 s after the last decision while hunks are still undecided
//!   (`pump`), so the agent learns of partial progress;
//! - when the session is about to send a request and outcomes are
//!   waiting (`flush`).
//! Each batch of decisions is sent once; the next outcome only carries
//! the decisions made since.
//!
//! E09 review records. Every hunk taken by an apply should have a review
//! reference in E09 provenance. When `Options.records` is set, `pump`
//! checks each one after the apply and writes the missing ones (logged).
//!
//! Decisions made in another process (`zg review accept`) arrive the
//! same way when the store re-emits them (`QueueSink.decided`).
//!
//! Owner thread (the queue's). The listener only copies the decisions;
//! `pump` and `flush` do the rest.

const std = @import("std");
const proto = @import("zg_ai_proto");
const diff = @import("zg_editor").model.diff;
const model = @import("../model/root.zig");
const comments = @import("comments.zig");

const Allocator = std.mem.Allocator;
const ChangesetId = model.ChangesetId;
const Decision = model.Decision;
const ThreadId = comments.ThreadId;
const CommentStore = comments.CommentStore;
const SessionId = proto.agent_ref.SessionId;

const log = std.log.scoped(.zg_review);

pub const FileOutcome = struct {
    path: []const u8,
    accepted: u32,
    rejected: u32,
    edited: u32,
    /// Hunks still undecided.
    pending: u32,
    /// The reviewer's rewrites as a unified diff from the proposal, at
    /// most `Options.max_diff_lines`; null when there were none or it
    /// was longer (see `user_rewrote`).
    user_edit_diff: ?[]const u8 = null,
    /// Lines the reviewer wrote in edited hunks.
    user_rewrote: u32 = 0,
};

pub const Outcome = struct {
    cs: ChangesetId,
    session: SessionId,
    /// The changeset's label ("Turn 7: add retry to fetch").
    label: []const u8,
    files: []const FileOutcome,
    /// Unresolved comment threads on the changeset.
    comments: []const ThreadId,
    /// The changeset is closed: nothing more will be decided.
    final: bool,
};

/// Where outcomes go: E10's glue queues a reminder for the session.
/// Called on the owner thread, outside the queue's events; the outcome
/// lives only during the call.
pub const OutcomeSink = struct {
    ctx: *anyopaque,
    deliver: *const fn (ctx: *anyopaque, o: *const Outcome) void,
};

/// E09's review reference on a hunk that landed.
pub const ReviewRef = struct {
    apply: u64,
    cs: ChangesetId,
    path: []const u8,
    hunk: u32,
    decision: Decision,
    reviewer: []const u8,
};

/// E09 provenance (E09.F05.S01): whether a hunk's review reference is
/// recorded, and recording one.
pub const ReviewRecords = struct {
    ctx: *anyopaque,
    has: *const fn (ctx: *anyopaque, apply: u64, path: []const u8, hunk: u32) bool,
    record: *const fn (ctx: *anyopaque, r: *const ReviewRef) anyerror!void,
};

pub const Options = struct {
    /// A partial outcome waits this long after the last decision.
    idle_ms: u32 = 2000,
    max_diff_lines: u32 = 30,
    /// `render`'s budget for the sink's text.
    max_chars: u32 = 2000,
    records: ?ReviewRecords = null,
    reviewer: []const u8 = "user",
};

const FileAcc = struct {
    path: []const u8,
    accepted: u32 = 0,
    rejected: u32 = 0,
    edited: u32 = 0,
    diff: std.ArrayList(u8) = .empty,
    diff_lines: u32 = 0,
    user_lines: u32 = 0,
};

/// The decisions on a changeset not yet reported.
const Acc = struct {
    session: SessionId,
    label: []const u8,
    files: std.ArrayList(FileAcc) = .empty,
    final: bool = false,
    /// When the last decision was seen by `pump`; null until then.
    last_ms: ?i64 = null,
    arena: std.heap.ArenaAllocator,
};

pub const OutcomeReporter = struct {
    gpa: Allocator,
    q: *model.Queue,
    comments: *CommentStore,
    sink: OutcomeSink,
    opts: Options,
    listener_id: ?model.events.ListenerId = null,
    accs: std.AutoArrayHashMapUnmanaged(ChangesetId, Acc) = .empty,
    /// Hunks taken by applies, checked against E09 by `pump`.
    checks: std.ArrayList(ReviewRef) = .empty,
    checks_arena: std.heap.ArenaAllocator,

    pub fn init(gpa: Allocator, q: *model.Queue, cs: *CommentStore, sink: OutcomeSink, o: Options) !*OutcomeReporter {
        const r = try gpa.create(OutcomeReporter);
        errdefer gpa.destroy(r);
        r.* = .{ .gpa = gpa, .q = q, .comments = cs, .sink = sink, .opts = o, .checks_arena = .init(gpa) };
        r.listener_id = try q.subscribe(.{ .ctx = r, .on = onEvent });
        return r;
    }

    pub fn deinit(r: *OutcomeReporter) void {
        if (r.listener_id) |id| r.q.unsubscribe(id);
        for (r.accs.values()) |*a| a.arena.deinit();
        r.accs.deinit(r.gpa);
        r.checks.deinit(r.gpa);
        r.checks_arena.deinit();
        r.gpa.destroy(r);
    }

    /// Whether decisions on `cs` wait to be reported.
    pub fn waiting(r: *const OutcomeReporter, cs: ChangesetId) bool {
        return r.accs.contains(cs);
    }

    // ------------------------------------------------------ events

    fn onEvent(ctx: *anyopaque, ev: *const model.Event) void {
        const r: *OutcomeReporter = @ptrCast(@alignCast(ctx));
        switch (ev.*) {
            .decided => |d| r.noteDecided(&d) catch |e| log.warn("outcome of {f}: {t}", .{ d.cs, e }),
            .state => |s| if (closed(s.to)) {
                if (r.accs.getPtr(s.cs)) |a| a.final = true;
            },
            else => {},
        }
    }

    fn noteDecided(r: *OutcomeReporter, d: *const model.Decided) !void {
        const cs = r.q.get(d.cs) orelse return;
        const ref = cs.prov.origin.agentRef() orelse return;
        const gop = try r.accs.getOrPut(r.gpa, d.cs);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .session = ref.session, .label = "", .arena = .init(r.gpa) };
            gop.value_ptr.label = gop.value_ptr.arena.allocator().dupe(u8, cs.prov.label) catch "";
        }
        const acc = gop.value_ptr;
        acc.last_ms = null;
        // Another process's decisions arrive after the changeset's new
        // state.
        if (closed(cs.state)) acc.final = true;
        const a = acc.arena.allocator();
        for (d.files) |fd| {
            const f = try fileAcc(acc, fd.path);
            f.accepted += fd.count(.accepted);
            f.rejected += fd.count(.rejected);
            f.edited += fd.count(.edited);
            for (fd.edits) |e| try r.addEdit(a, f, e);
            if (r.opts.records != null) if (d.apply) |apply| for (fd.hunks) |h| {
                if (h.decision == .rejected) continue;
                const ca = r.checks_arena.allocator();
                try r.checks.append(r.gpa, .{ .apply = apply, .cs = d.cs, .path = try ca.dupe(u8, fd.path), .hunk = h.hunk, .decision = h.decision, .reviewer = r.opts.reviewer });
            };
        }
    }

    fn fileAcc(acc: *Acc, path: []const u8) !*FileAcc {
        for (acc.files.items) |*f| if (std.mem.eql(u8, f.path, path)) return f;
        const a = acc.arena.allocator();
        try acc.files.append(a, .{ .path = try a.dupe(u8, path) });
        return &acc.files.items[acc.files.items.len - 1];
    }

    /// Adds the unified diff of one edited hunk.
    fn addEdit(r: *OutcomeReporter, a: Allocator, f: *FileAcc, e: model.HunkEdit) !void {
        f.user_lines += lineCount(e.user);
        if (f.diff_lines > r.opts.max_diff_lines) return;
        var la = try diff.LineSource.fromBytes(r.gpa, e.proposed);
        defer la.deinit(r.gpa);
        var lb = try diff.LineSource.fromBytes(r.gpa, e.user);
        defer lb.deinit(r.gpa);
        var d = try diff.diffLines(r.gpa, &la, &lb, .{ .intraline = .none, .context_lines = 1 });
        defer d.deinit(r.gpa);
        var aw: std.Io.Writer.Allocating = .init(r.gpa);
        defer aw.deinit();
        const names: [2][]const u8 = if (f.diff.items.len == 0) .{ "proposed", "landed" } else .{ "", "" };
        try diff.unified.writeUnified(&aw.writer, d.edits, d.hunks, &la, &lb, names);
        var text = aw.written();
        // One header per file.
        if (f.diff.items.len > 0) if (std.mem.indexOf(u8, text, "@@")) |at| {
            text = text[at..];
        };
        f.diff_lines += lineCount(text);
        if (f.diff_lines > r.opts.max_diff_lines) return;
        try f.diff.appendSlice(a, text);
    }

    // ------------------------------------------------------ delivery

    /// Stamps new decisions with `now_ms`, sends closed changesets'
    /// outcomes and partial ones idle for `idle_ms`, and checks E09's
    /// records. Call on the owner thread after queue changes and on a
    /// timer.
    pub fn pump(r: *OutcomeReporter, now_ms: i64) void {
        r.checkRecords();
        var i: usize = 0;
        while (i < r.accs.count()) {
            const acc = &r.accs.values()[i];
            const last = acc.last_ms orelse blk: {
                acc.last_ms = now_ms;
                break :blk now_ms;
            };
            if (acc.final or now_ms - last >= r.opts.idle_ms) {
                r.deliverAt(i);
            } else i += 1;
        }
    }

    /// Sends every waiting outcome of `session` (E10's glue calls this
    /// before the session's next request). Returns how many were sent.
    pub fn flush(r: *OutcomeReporter, session: SessionId) u32 {
        var n: u32 = 0;
        var i: usize = 0;
        while (i < r.accs.count()) {
            if (r.accs.values()[i].session == session) {
                r.deliverAt(i);
                n += 1;
            } else i += 1;
        }
        return n;
    }

    fn deliverAt(r: *OutcomeReporter, i: usize) void {
        const id = r.accs.keys()[i];
        var acc = r.accs.values()[i];
        r.accs.orderedRemoveAt(i);
        defer acc.arena.deinit();
        r.deliver(id, &acc) catch |e| log.warn("outcome of {f} not delivered: {t}", .{ id, e });
    }

    fn deliver(r: *OutcomeReporter, id: ChangesetId, acc: *Acc) !void {
        const a = acc.arena.allocator();
        const cs = r.q.get(id);
        var files: std.ArrayList(FileOutcome) = .empty;
        for (acc.files.items) |f| {
            try files.append(a, .{
                .path = f.path,
                .accepted = f.accepted,
                .rejected = f.rejected,
                .edited = f.edited,
                .pending = if (cs) |c| pendingOf(c, f.path) else 0,
                .user_edit_diff = if (f.diff.items.len > 0 and f.diff_lines <= r.opts.max_diff_lines) f.diff.items else null,
                .user_rewrote = f.user_lines,
            });
        }
        // Files nothing was decided on yet.
        if (cs) |c| for (c.files) |*fc| {
            const p = pendingOf(c, fc.path);
            if (p == 0) continue;
            for (acc.files.items) |f| {
                if (std.mem.eql(u8, f.path, fc.path)) break;
            } else try files.append(a, .{ .path = fc.path, .accepted = 0, .rejected = 0, .edited = 0, .pending = p });
        };
        var threads: std.ArrayList(ThreadId) = .empty;
        for (r.comments.threadsOf(id)) |t| if (!t.resolved) try threads.append(a, t.id);
        const final = acc.final or (if (cs) |c| closed(c.state) else true);
        const o: Outcome = .{ .cs = id, .session = acc.session, .label = acc.label, .files = files.items, .comments = threads.items, .final = final };
        r.sink.deliver(r.sink.ctx, &o);
    }

    /// Writes missing E09 review references.
    fn checkRecords(r: *OutcomeReporter) void {
        defer {
            r.checks.clearRetainingCapacity();
            _ = r.checks_arena.reset(.retain_capacity);
        }
        const rec = r.opts.records orelse return;
        for (r.checks.items) |*c| {
            if (rec.has(rec.ctx, c.apply, c.path, c.hunk)) continue;
            log.warn("apply {d}: {s} hunk {d} of {f} has no review record; writing it", .{ c.apply, c.path, c.hunk, c.cs });
            rec.record(rec.ctx, c) catch |e| log.warn("review record for {s} failed: {t}", .{ c.path, e });
        }
    }
};

fn closed(s: model.State) bool {
    return switch (s) {
        .applied, .rejected, .superseded, .discarded => true,
        .open_batch, .pending, .partially_applied => false,
    };
}

/// Hunks of `path` still undecided (a file without hunks counts as one).
fn pendingOf(cs: *const model.Changeset, path: []const u8) u32 {
    const fc = &cs.files[cs.fileIndex(path) orelse return 0];
    if (fc.state != .pending and fc.state != .partially_applied and fc.state != .conflicted and fc.state != .stale) return 0;
    if (fc.content != .text) return 1;
    var n: u32 = 0;
    for (fc.hunks) |h| n += @intFromBool(h.decision == .undecided);
    return n;
}

fn lineCount(text: []const u8) u32 {
    if (text.len == 0) return 0;
    return @intCast(std.mem.count(u8, text, "\n") + @intFromBool(text[text.len - 1] != '\n'));
}

// ---------------------------------------------------------- rendering

/// Writes `o` as the reminder text: deterministic, at most `max_chars`
/// bytes. Over the budget, diffs give way to "the user rewrote N lines",
/// then files are cut.
///
/// ```
/// Review outcome #12 ("Turn 7: add retry to fetch"):
/// - src/a.zig: accepted (2/2)
/// - src/b.zig: partially accepted (1 accepted, 1 rejected, 1 edited by user)
///   --- proposed
///   +++ landed
///   @@ -1 +1 @@
///   -    get(url, buf) catch continue;
///   +    get(url, buf) catch |e| return e;
/// Rejected changes are not in the files; do not assume them.
/// Re-read files before editing them again.
/// ```
pub fn render(o: *const Outcome, w: *std.Io.Writer, max_chars: u32) !void {
    var files: usize = o.files.len;
    for ([_]bool{ true, false }) |diffs| {
        if (measure(o, diffs, files) <= max_chars) return write(o, w, diffs, files);
    }
    while (files > 0) {
        files -= 1;
        if (measure(o, false, files) <= max_chars) return write(o, w, false, files);
    }
    // Even the header and the tail are over: write them anyway.
    return write(o, w, false, 0);
}

fn measure(o: *const Outcome, diffs: bool, files: usize) u64 {
    var buf: [256]u8 = undefined;
    var d: std.Io.Writer.Discarding = .init(&buf);
    write(o, &d.writer, diffs, files) catch {};
    return d.fullCount();
}

fn write(o: *const Outcome, w: *std.Io.Writer, diffs: bool, max_files: usize) std.Io.Writer.Error!void {
    var pending: u32 = 0;
    var any_rejected = false;
    var any_edited = false;
    for (o.files) |f| {
        pending += f.pending;
        any_rejected = any_rejected or f.rejected > 0;
        any_edited = any_edited or f.edited > 0;
    }
    try w.print("Review outcome {f} (\"{s}\")", .{ o.cs, o.label });
    if (!o.final and pending > 0) try w.print(", so far ({d} {s} still pending review)", .{ pending, plural(pending, "hunk", "hunks") });
    try w.writeAll(":\n");
    for (o.files[0..@min(max_files, o.files.len)]) |f| {
        try w.print("- {s}: ", .{f.path});
        try status(w, f);
        try w.writeByte('\n');
        if (f.edited == 0) continue;
        if (diffs and f.user_edit_diff != null) {
            var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, f.user_edit_diff.?, "\n"), '\n');
            while (it.next()) |line| try w.print("  {s}\n", .{line});
        } else try w.print("  The user rewrote {d} {s}; re-read the file.\n", .{ f.user_rewrote, plural(f.user_rewrote, "line", "lines") });
    }
    if (max_files < o.files.len) try w.print("- … and {d} more files\n", .{o.files.len - max_files});
    if (any_rejected) try w.writeAll("Rejected changes are not in the files; do not assume them.\n");
    if (o.comments.len > 0) try w.print("The reviewer left {d} open review {s}; a fix request may follow.\n", .{ o.comments.len, plural(@intCast(o.comments.len), "comment", "comments") });
    if (any_rejected or any_edited) try w.writeAll("Re-read files before editing them again.\n");
}

fn status(w: *std.Io.Writer, f: FileOutcome) !void {
    const total = f.accepted + f.rejected + f.edited + f.pending;
    if (f.accepted + f.rejected + f.edited == 0) {
        return w.print("{d} {s} pending review", .{ f.pending, plural(f.pending, "hunk", "hunks") });
    }
    if (f.accepted == total) return w.print("accepted ({d}/{d})", .{ f.accepted, total });
    if (f.rejected == total) return w.print("rejected ({d}/{d})", .{ f.rejected, total });
    try w.writeAll(if (f.accepted + f.edited == 0) "partly rejected (" else "partially accepted (");
    var first = true;
    const parts = [_]struct { n: u32, what: []const u8 }{
        .{ .n = f.accepted, .what = "accepted" },
        .{ .n = f.rejected, .what = "rejected" },
        .{ .n = f.edited, .what = "edited by user" },
        .{ .n = f.pending, .what = "pending" },
    };
    for (parts) |p| {
        if (p.n == 0) continue;
        if (!first) try w.writeAll(", ");
        try w.print("{d} {s}", .{ p.n, p.what });
        first = false;
    }
    try w.writeByte(')');
}

fn plural(n: u32, one: []const u8, many: []const u8) []const u8 {
    return if (n == 1) one else many;
}
