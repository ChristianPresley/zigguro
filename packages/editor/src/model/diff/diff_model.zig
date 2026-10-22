//! DiffModel: a live line diff between a base snapshot and a document,
//! for the dirty-diff gutter, inline and side-by-side review and hunk
//! revert, accept and stage.
//!
//! Hunks have no context lines: each is one change block, with `old` lines
//! in the base and `new` lines in the current text (0-based; a zero count
//! is a pure deletion or insertion). Line numbering follows `LineSource`:
//! a text ending in a terminator has no empty last line.
//!
//! Updates:
//! - **Full diff** on `init`, `setBase` and large edits (more than 10,000
//!   lines, or a rediff window over 2,000 lines): `diffLines` runs on a
//!   worker over the base and a snapshot. When it finishes it posts
//!   `ui_msg_kind` (payload `a` = the model's address); the UI thread
//!   calls `completeFull`, which maps the result through the edits made
//!   meanwhile and rediffs their regions. Until then hunks are stale but
//!   shifted.
//! - **Local rediff** on every other edit (UI thread): hunks after the edit
//!   shift by its line delta; the edited lines widen to a window bounded by
//!   at least 3 equal lines on each side (or the file ends), whose base
//!   lines follow from the equal runs; only that window is diffed and its
//!   hunks spliced in.
//!
//! A local rediff can split a change differently from a full diff of the
//! same texts (the window bounds the search), but the hunks always
//! describe the texts exactly.

const std = @import("std");
const zg_core = @import("zg_core");
const diff = @import("../diff.zig");
const pt = @import("../buffer/piece_tree.zig");
const document = @import("../document.zig");
const Snapshot = @import("../snapshot.zig").Snapshot;
const cs_mod = @import("../edit/change_set.zig");

const Allocator = std.mem.Allocator;
const PieceTree = pt.PieceTree;
const Document = document.Document;
const ChangeSet = cs_mod.ChangeSet;
const LineSource = diff.LineSource;
const LineHunk = diff.LineHunk;
const DiffRange = diff.DiffRange;

/// Posted to the UI mailbox when a background full diff finishes.
pub const ui_msg_kind: u32 = 0x0507_0001;

/// Equal lines kept around a local rediff window.
pub const anchor_lines = 3;
/// A local rediff window larger than this goes to a full diff instead.
pub const max_window_lines = 2000;
/// An edit touching more lines than this goes to a full diff.
pub const large_edit_lines = 10_000;

/// Hunks `first..first + removed` were replaced by `inserted` new ones.
pub const HunksChanged = struct { first: u32, removed: u32, inserted: u32, version: u64 };

/// A hunk-change callback (UI thread).
pub const DiffListener = struct {
    ctx: *anyopaque,
    onHunks: *const fn (ctx: *anyopaque, ev: HunksChanged) void,
};

/// Which way a hunk's ChangeSet goes.
pub const Direction = enum {
    /// Against the current text: restore the base lines (revert).
    current_to_base,
    /// Against the base text: apply the current lines (accept, stage).
    base_to_current,
};

/// One edit in line coordinates: `old_count` lines from `start` became
/// `new_count` lines.
const LineEdit = struct { start: u64, old_count: u64, new_count: u64 };

/// A full diff running on a worker.
const FullJob = struct {
    gpa: Allocator,
    base: *const LineSource,
    snap: Snapshot,
    o: diff.DiffOptions,
    rt: ?*zg_core.Runtime,
    model_addr: usize,
    hunks: []LineHunk = &.{},
    failed: bool = false,

    fn run(job: *FullJob) void {
        job.compute() catch {
            job.failed = true;
        };
        if (job.rt) |rt| rt.post(.{ .kind = ui_msg_kind, .a = job.model_addr }) catch {};
    }

    fn compute(job: *FullJob) !void {
        var cur = try LineSource.fromTree(job.gpa, job.snap.tree);
        defer cur.deinit(job.gpa);
        var o = job.o;
        o.context_lines = 0;
        o.intraline = .none;
        o.detect_moves = false;
        o.ignore_ws = .none;
        var r = try diff.diffLines(job.gpa, job.base, &cur, o);
        defer r.deinit(job.gpa);
        job.hunks = r.hunks;
        r.hunks = &.{};
    }
};

/// A live base-vs-current diff.
pub const DiffModel = struct {
    gpa: Allocator,
    /// Null runs full diffs inline (CLI, fuzzing); they still install on
    /// `completeFull`.
    rt: ?*zg_core.Runtime,
    doc: *Document,
    listener_id: document.ListenerId,
    o: diff.DiffOptions,
    base_snap: Snapshot,
    base: LineSource,
    list: std.ArrayList(LineHunk) = .empty,
    /// The document version the hunks describe.
    ver: u64,
    listeners: std.ArrayList(DiffListener) = .empty,
    job: ?*FullJob = null,
    future: ?std.Io.Future(void) = null,
    /// Edits made since the running job's snapshot.
    pending: std.ArrayList(LineEdit) = .empty,
    /// A full diff is wanted once the running one finishes.
    rerun: bool = false,

    /// A model diffing `base` (whose reference it takes over) against
    /// `current`, starting a full diff.
    pub fn init(gpa: Allocator, rt: ?*zg_core.Runtime, base: Snapshot, current: *Document, o: diff.DiffOptions) !*DiffModel {
        const m = try gpa.create(DiffModel);
        errdefer gpa.destroy(m);
        var bsnap = base;
        errdefer bsnap.release();
        var bsrc = try LineSource.fromTree(gpa, base.tree);
        errdefer bsrc.deinit(gpa);
        m.* = .{ .gpa = gpa, .rt = rt, .doc = current, .listener_id = undefined, .o = o, .base_snap = base, .base = bsrc, .ver = current.version };
        m.listener_id = try current.subscribe(.{ .ctx = m, .onChange = onChangeCb });
        m.scheduleFull();
        return m;
    }

    /// Waits for a running full diff and frees the model.
    pub fn deinit(m: *DiffModel) void {
        m.dropJob();
        m.doc.unsubscribe(m.listener_id);
        m.list.deinit(m.gpa);
        m.listeners.deinit(m.gpa);
        m.pending.deinit(m.gpa);
        m.base.deinit(m.gpa);
        m.base_snap.release();
        m.gpa.destroy(m);
    }

    /// The current hunks (borrowed until the next update).
    pub fn hunks(m: *const DiffModel) []const LineHunk {
        return m.list.items;
    }

    /// The document version the hunks describe.
    pub fn version(m: *const DiffModel) u64 {
        return m.ver;
    }

    /// Whether a full diff is running (hunks are approximate meanwhile).
    pub fn fullPending(m: *const DiffModel) bool {
        return m.job != null;
    }

    /// Registers a listener for hunk changes.
    pub fn subscribe(m: *DiffModel, l: DiffListener) Allocator.Error!void {
        try m.listeners.append(m.gpa, l);
    }

    /// Replaces the base (taking over its reference) and recomputes.
    pub fn setBase(m: *DiffModel, base: Snapshot) !void {
        m.dropJob();
        var bsrc = try LineSource.fromTree(m.gpa, base.tree);
        errdefer bsrc.deinit(m.gpa);
        m.base.deinit(m.gpa);
        m.base_snap.release();
        m.base = bsrc;
        m.base_snap = base;
        m.scheduleFull();
    }

    /// Handles `ui_msg_kind` for this model (UI thread).
    pub fn handleMsg(msg: zg_core.UiMsg) void {
        if (msg.kind != ui_msg_kind) return;
        const m: *DiffModel = @ptrFromInt(@as(usize, @intCast(msg.a)));
        m.completeFull() catch {};
    }

    /// Waits for the running full diff, if any, and installs its result
    /// (UI thread).
    pub fn completeFull(m: *DiffModel) !void {
        const job = m.job orelse return;
        if (m.future) |*fut| fut.await(m.rt.?.io);
        m.future = null;
        m.job = null;
        defer {
            job.snap.release();
            m.gpa.free(job.hunks);
            m.gpa.destroy(job);
        }
        if (job.failed) return error.OutOfMemory;
        // Map the result through the edits made while it ran.
        var result: std.ArrayList(LineHunk) = .fromOwnedSlice(job.hunks);
        job.hunks = &.{};
        defer result.deinit(m.gpa);
        var dirty: std.ArrayList(LineEdit) = .empty;
        defer dirty.deinit(m.gpa);
        for (m.pending.items) |e| {
            shiftHunks(result.items, e);
            for (dirty.items) |*d| {
                const end = mapEnd(d.start + d.new_count, e);
                d.start = mapStart(d.start, e);
                d.new_count = end - d.start;
            }
            try dirty.append(m.gpa, .{ .start = e.start, .old_count = e.old_count, .new_count = e.new_count });
        }
        m.pending.clearRetainingCapacity();
        const old_len = m.list.items.len;
        std.mem.swap(std.ArrayList(LineHunk), &m.list, &result);
        m.ver = m.doc.version;
        m.emit(.{ .first = 0, .removed = @intCast(old_len), .inserted = @intCast(m.list.items.len), .version = m.ver });
        const rerun = m.rerun;
        m.rerun = false;
        for (dirty.items) |d| try m.rediff(d.start, d.new_count);
        if (rerun and m.job == null) m.scheduleFull();
    }

    /// The ChangeSet for hunk `idx`: against the current text to restore
    /// the base lines, or against the base text to apply the current ones.
    pub fn hunkChangeSet(m: *const DiffModel, idx: u32, direction: Direction) !ChangeSet {
        const h = m.list.items[idx];
        const t = m.doc.tree;
        const cur: pt.Range = .{ .start = lineOffset(t, h.new.start), .end = lineOffset(t, h.new.start + h.new.count) };
        const base: pt.Range = .{ .start = m.base.offsetOf(@intCast(h.old.start)), .end = m.base.offsetOf(@intCast(h.old.start + h.old.count)) };
        const base_text = m.base.text[@intCast(base.start)..@intCast(base.end)];
        switch (direction) {
            .current_to_base => return ChangeSet.fromEdits(m.gpa, t.len(), &.{.{ .range = cur, .text = base_text }}),
            .base_to_current => {
                const cur_text = try t.copyRange(m.gpa, cur);
                defer m.gpa.free(cur_text);
                return ChangeSet.fromEdits(m.gpa, m.base.text.len, &.{.{ .range = base, .text = cur_text }});
            },
        }
    }

    /// Word highlights for hunk `idx`: `old` ranges in the base text,
    /// `new` ranges in the current text (owned by the caller).
    pub fn intraline(m: *const DiffModel, idx: u32, mode: diff.intraline.Mode, gpa: Allocator) ![]DiffRange {
        const h = m.list.items[idx];
        if (h.old.count == 0 or h.new.count == 0) return &.{};
        const t = m.doc.tree;
        const start = lineOffset(t, h.new.start);
        const text = try t.copyRange(gpa, .{ .start = start, .end = lineOffset(t, h.new.start + h.new.count) });
        defer gpa.free(text);
        var cur = try LineSource.fromBytes(gpa, text);
        defer cur.deinit(gpa);
        const edits = [_]diff.Edit{
            .{ .kind = .delete, .a_start = @intCast(h.old.start), .b_start = 0, .len = @intCast(h.old.count) },
            .{ .kind = .insert, .a_start = @intCast(h.old.start + h.old.count), .b_start = 0, .len = @intCast(cur.count()) },
        };
        const out = try diff.intraline.intralineEdits(gpa, &edits, &m.base, &cur, mode);
        for (out) |*r| if (r.side == .new) {
            r.range.start += start;
            r.range.end += start;
        };
        return out;
    }

    fn onChangeCb(ctx: *anyopaque, ev: *const document.ChangeEvent) void {
        const m: *DiffModel = @ptrCast(@alignCast(ctx));
        m.onChange(ev) catch {
            // Out of memory: fall back to a full diff.
            if (m.job == null) m.scheduleFull() else m.rerun = true;
        };
    }

    /// Updates the hunks for one document change (called by the
    /// document's listener).
    pub fn onChange(m: *DiffModel, ev: *const document.ChangeEvent) !void {
        const reps = ev.changes.replaces;
        if (reps.len == 0) {
            if (m.job == null) m.ver = m.doc.version;
            return;
        }
        const before = ev.before;
        const after = m.doc.tree;
        const n_before = numLines(before);
        const n_after = numLines(after);
        const start = before.lineOf(reps[0].range.start);
        const last = before.lineOf(reps[reps.len - 1].range.end);
        const old_count = @min(last + 1, n_before) -| start;
        const delta: i64 = @as(i64, @intCast(n_after)) - @as(i64, @intCast(n_before));
        const new_count: u64 = @intCast(@max(0, @as(i64, @intCast(old_count)) + delta));
        const e: LineEdit = .{ .start = start, .old_count = old_count, .new_count = new_count };
        shiftHunks(m.list.items, e);
        if (m.job != null) {
            try m.pending.append(m.gpa, e);
            return;
        }
        if (old_count > large_edit_lines or new_count > large_edit_lines) {
            m.scheduleFull();
            return;
        }
        m.ver = m.doc.version;
        try m.rediff(e.start, e.new_count);
    }

    /// Rediffs the window around current lines `start..start + count`.
    fn rediff(m: *DiffModel, start: u64, count: u64) !void {
        const t = m.doc.tree;
        const n = numLines(t);
        const items = m.list.items;
        var w0 = start -| anchor_lines;
        var w1 = @min(n, start + count + anchor_lines);
        // Hunks touching the window join it, with their own anchors.
        var lo: usize = 0;
        var hi: usize = 0;
        while (true) {
            lo = 0;
            while (lo < items.len and hunkEnd(items[lo]) < w0) lo += 1;
            hi = lo;
            var grew = false;
            while (hi < items.len and items[hi].new.start <= w1) : (hi += 1) {
                const nw0 = @min(w0, items[hi].new.start -| anchor_lines);
                const nw1 = @max(w1, @min(n, hunkEnd(items[hi]) + anchor_lines));
                if (nw0 != w0 or nw1 != w1) grew = true;
                w0 = nw0;
                w1 = nw1;
            }
            if (!grew) break;
        }
        const b0: u64 = if (lo > 0) items[lo - 1].old.start + items[lo - 1].old.count + (w0 - hunkEnd(items[lo - 1])) else w0;
        // The equal run after the window gives its base end.
        const after_gap = if (hi < items.len) items[hi].new.start - w1 else n - w1;
        const after_base = if (hi < items.len) items[hi].old.start else m.base.count();
        const b1 = after_base -| after_gap;
        if (after_base < after_gap or b1 < b0 or b1 > m.base.count() or w1 - w0 > max_window_lines or b1 - b0 > max_window_lines) {
            m.scheduleFull();
            return;
        }
        const fresh = try m.diffWindow(w0, w1, b0, b1);
        defer m.gpa.free(fresh);
        try m.list.replaceRange(m.gpa, lo, hi - lo, fresh);
        m.emit(.{ .first = @intCast(lo), .removed = @intCast(hi - lo), .inserted = @intCast(fresh.len), .version = m.ver });
    }

    /// Diffs current lines `w0..w1` against base lines `b0..b1`.
    fn diffWindow(m: *DiffModel, w0: u64, w1: u64, b0: u64, b1: u64) ![]LineHunk {
        const t = m.doc.tree;
        const n = numLines(t);
        const text = try t.copyRange(m.gpa, .{ .start = lineOffset(t, w0), .end = lineOffset(t, w1) });
        defer m.gpa.free(text);
        var cur = try LineSource.fromBytes(m.gpa, text);
        defer cur.deinit(m.gpa);
        var ids: std.StringHashMapUnmanaged(u32) = .empty;
        defer ids.deinit(m.gpa);
        const ia = try m.gpa.alloc(u32, @intCast(b1 - b0));
        defer m.gpa.free(ia);
        const ib = try m.gpa.alloc(u32, cur.count());
        defer m.gpa.free(ib);
        for (ia, 0..) |*id, k| id.* = try intern(m.gpa, &ids, m.base.line(@intCast(b0 + k)), m.base.missingEol(@intCast(b0 + k)));
        for (ib, 0..) |*id, k| id.* = try intern(m.gpa, &ids, cur.line(k), w1 == n and cur.missingEol(k));
        const edits = try diff.diffTokens(m.gpa, ia, ib, m.o.algorithm, null);
        defer m.gpa.free(edits);
        const hs = try diff.hunks.buildHunks(m.gpa, edits, 0);
        for (hs) |*h| {
            h.old.start += b0;
            h.new.start += w0;
        }
        return hs;
    }

    fn scheduleFull(m: *DiffModel) void {
        if (m.job != null) {
            m.rerun = true;
            return;
        }
        const job = m.gpa.create(FullJob) catch return;
        job.* = .{ .gpa = m.gpa, .base = &m.base, .snap = m.doc.snapshot(), .o = m.o, .rt = m.rt, .model_addr = @intFromPtr(m) };
        // Pathological inputs fall back to a coarse diff after the timeout.
        job.o.io = if (m.rt) |rt| rt.io else null;
        m.job = job;
        m.pending.clearRetainingCapacity();
        if (m.rt) |rt| m.future = rt.io.async(FullJob.run, .{job}) else job.run();
    }

    /// Waits for and discards a running full diff.
    fn dropJob(m: *DiffModel) void {
        const job = m.job orelse return;
        if (m.future) |*fut| fut.await(m.rt.?.io);
        m.future = null;
        m.job = null;
        job.snap.release();
        m.gpa.free(job.hunks);
        m.gpa.destroy(job);
        m.pending.clearRetainingCapacity();
        m.rerun = false;
    }

    fn emit(m: *DiffModel, ev: HunksChanged) void {
        if (ev.removed == 0 and ev.inserted == 0) return;
        for (m.listeners.items) |l| l.onHunks(l.ctx, ev);
    }
};

/// Lines of `t` as `LineSource` counts them.
fn numLines(t: PieceTree) u64 {
    const len = t.len();
    if (len == 0) return 0;
    const last = t.byteAt(len - 1);
    return if (last == '\n' or last == '\r') t.lineCount() - 1 else t.lineCount();
}

/// Byte offset where line `i` starts (`len` past the last line).
fn lineOffset(t: PieceTree, i: u64) u64 {
    return if (i >= numLines(t)) t.len() else t.lineStart(i);
}

fn hunkEnd(h: LineHunk) u64 {
    return h.new.start + h.new.count;
}

fn mapStart(x: u64, e: LineEdit) u64 {
    if (x <= e.start) return x;
    if (x >= e.start + e.old_count) return x + e.new_count - e.old_count;
    return e.start;
}

fn mapEnd(x: u64, e: LineEdit) u64 {
    if (x <= e.start) return x;
    if (x >= e.start + e.old_count) return x + e.new_count - e.old_count;
    return e.start + e.new_count;
}

/// Moves hunks' current-side lines through `e`; hunks it overlaps cover
/// the edited lines (their exact lines are recomputed by the rediff).
fn shiftHunks(items: []LineHunk, e: LineEdit) void {
    for (items) |*h| {
        const s = mapStart(h.new.start, e);
        const end = mapEnd(hunkEnd(h.*), e);
        h.new = .{ .start = s, .count = end - s };
    }
}

fn intern(gpa: Allocator, ids: *std.StringHashMapUnmanaged(u32), line: []const u8, missing_eol: bool) !u32 {
    const gop = try ids.getOrPut(gpa, line);
    if (!gop.found_existing) gop.value_ptr.* = ids.count() - 1;
    return gop.value_ptr.* * 2 + @intFromBool(missing_eol);
}
