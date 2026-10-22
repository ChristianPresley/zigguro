//! The review queue (E12.F01.S01.T02): every pending changeset of a
//! workspace, the batch API producers use to submit them, and the event
//! bus the UI, the agent panes and the CLI follow.
//!
//! The queue's state belongs to one owner thread (the UI thread in the
//! GUI, the main loop in `zg`). Producers on other threads use the
//! `Submitter`, which has the same batch API: `commitBatch` reserves the
//! id at once (an atomic counter), and the changeset appears when the
//! owner calls `drain` (the `wake` hook asks it to). Batches themselves
//! are guarded by a mutex, so any thread may build one.
//!
//! On commit:
//! - base and created texts go to `blobs` and hunks are derived;
//! - an edit made on top of the same session's still-undecided edit of
//!   that file (the agent read its own pending text) folds into the
//!   earlier changeset: the edits compose, hunks are derived again
//!   (unchanged hunks keep their decision), and the new changeset keeps a
//!   `superseded` stub for the file. Different sessions never fold;
//! - `auto_apply` needs a review policy, which does not exist yet, so the
//!   changeset stays pending (fail closed).

const std = @import("std");
const zg_core = @import("zg_core");
const ids = @import("ids.zig");
const changeset = @import("changeset.zig");
const provenance = @import("provenance.zig");
const hunks_mod = @import("hunks.zig");
const batch_mod = @import("batch.zig");
const blobs_mod = @import("blobs.zig");
const events = @import("events.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const ChangesetId = ids.ChangesetId;
const BatchId = ids.BatchId;
const ChangeSet = changeset.ChangeSet;
const Changeset = changeset.Changeset;
const FileChange = changeset.FileChange;
const Provenance = provenance.Provenance;
const Batch = batch_mod.Batch;
const Blobs = blobs_mod.Blobs;
pub const Event = events.Event;
pub const Listener = events.Listener;
pub const ListenerId = events.ListenerId;

pub const SubmitOptions = struct {
    /// Asks the review policy to apply without review (F05).
    auto_apply: bool = false,
    presentation: changeset.Presentation = .queue,
    supersedes: ?ChangesetId = null,
    /// The checkpoint taken before the change (F04).
    checkpoint: ?u64 = null,
};

pub const Filter = struct {
    /// Only `pending` and `partially_applied` changesets.
    open_only: bool = false,
    session: ?u128 = null,
};

/// Where the queue records changes (the durable store). Called on the
/// owner thread; must not block on I/O.
pub const Journal = struct {
    ctx: *anyopaque,
    /// A new or changed changeset (a full snapshot).
    changeset: *const fn (ctx: *anyopaque, cs: *const Changeset) void,
    removed: *const fn (ctx: *anyopaque, id: ChangesetId) void,
};

/// Asks the owner thread to call `drain` (e.g. through `Runtime.post`).
pub const Wake = struct {
    ctx: *anyopaque,
    wake: *const fn (ctx: *anyopaque) void,
};

pub const Options = struct {
    /// The workspace root (absolute); submitted paths are relative to it.
    root: []const u8,
    blobs: Blobs,
    /// The first id to hand out (the store's highest + 1).
    first_id: u64 = 1,
    wake: ?Wake = null,
    journal: ?Journal = null,
    hunk_options: hunks_mod.HunkOptions = .{},
};

pub const Error = batch_mod.Error || error{UnknownBatch};

pub const Queue = struct {
    gpa: Allocator,
    io: Io,
    root: []const u8,
    blobs: Blobs,
    wake: ?Wake,
    journal: ?Journal,
    hunk_options: hunks_mod.HunkOptions,
    next_id: std.atomic.Value(u64),
    next_batch: std.atomic.Value(u64) = .init(1),
    /// In submission order.
    changesets: std.AutoArrayHashMapUnmanaged(ChangesetId, *Changeset) = .empty,
    listeners: std.ArrayList(?Listener) = .empty,
    emitting: bool = false,
    /// Guards `batches` and `committed`.
    mutex: Io.Mutex = .init,
    batches: std.AutoHashMapUnmanaged(BatchId, *Batch) = .empty,
    committed: std.ArrayList(Committed) = .empty,
    submitter_: Submitter = undefined,

    const Committed = struct { id: ChangesetId, batch: *Batch, opts: SubmitOptions };

    pub fn init(gpa: Allocator, io: Io, o: Options) Allocator.Error!*Queue {
        const q = try gpa.create(Queue);
        errdefer gpa.destroy(q);
        q.* = .{
            .gpa = gpa,
            .io = io,
            .root = try gpa.dupe(u8, o.root),
            .blobs = o.blobs,
            .wake = o.wake,
            .journal = o.journal,
            .hunk_options = o.hunk_options,
            .next_id = .init(@max(1, o.first_id)),
        };
        q.submitter_ = .{ .q = q };
        return q;
    }

    pub fn deinit(q: *Queue) void {
        for (q.changesets.values()) |cs| {
            cs.deinit(q.gpa);
            q.gpa.destroy(cs);
        }
        q.changesets.deinit(q.gpa);
        var it = q.batches.valueIterator();
        while (it.next()) |b| b.*.deinit();
        q.batches.deinit(q.gpa);
        for (q.committed.items) |c| c.batch.deinit();
        q.committed.deinit(q.gpa);
        q.listeners.deinit(q.gpa);
        q.gpa.free(q.root);
        q.gpa.destroy(q);
    }

    /// The thread-safe façade.
    pub fn submitter(q: *Queue) *Submitter {
        return &q.submitter_;
    }

    // ------------------------------------------------------ batch API

    pub fn beginBatch(q: *Queue, prov: Provenance) Error!BatchId {
        const b = try Batch.init(q.gpa, q.root, prov);
        errdefer b.deinit();
        const id: BatchId = @enumFromInt(q.next_batch.fetchAdd(1, .monotonic));
        q.mutex.lockUncancelable(q.io);
        defer q.mutex.unlock(q.io);
        try q.batches.put(q.gpa, id, b);
        return id;
    }

    fn withBatch(q: *Queue, id: BatchId, comptime f: anytype, args: anytype) Error!void {
        q.mutex.lockUncancelable(q.io);
        defer q.mutex.unlock(q.io);
        const b = q.batches.get(id) orelse return error.UnknownBatch;
        return @call(.auto, f, .{b} ++ args);
    }

    /// `edits` change `base`, the file's text as the producer read it
    /// (`base_version` when it came from an open document).
    pub fn addEdit(q: *Queue, b: BatchId, path: []const u8, base: []const u8, base_version: ?u64, edits: *const ChangeSet) Error!void {
        return q.withBatch(b, Batch.addEdit, .{ path, base, base_version, edits });
    }
    pub fn addCreate(q: *Queue, b: BatchId, path: []const u8, bytes: []const u8) Error!void {
        return q.withBatch(b, Batch.addCreate, .{ path, bytes });
    }
    pub fn addDelete(q: *Queue, b: BatchId, path: []const u8, base: []const u8) Error!void {
        return q.withBatch(b, Batch.addDelete, .{ path, base });
    }
    pub fn addRename(q: *Queue, b: BatchId, from: []const u8, to: []const u8) Error!void {
        return q.withBatch(b, Batch.addRename, .{ from, to });
    }
    pub fn setExecutable(q: *Queue, b: BatchId, path: []const u8, on: bool) Error!void {
        return q.withBatch(b, Batch.setExecutable, .{ path, on });
    }

    pub fn abortBatch(q: *Queue, b: BatchId) void {
        q.mutex.lockUncancelable(q.io);
        const kv = q.batches.fetchRemove(b);
        q.mutex.unlock(q.io);
        if (kv) |x| x.value.deinit();
    }

    fn takeBatch(q: *Queue, b: BatchId) Error!*Batch {
        q.mutex.lockUncancelable(q.io);
        defer q.mutex.unlock(q.io);
        const kv = q.batches.fetchRemove(b) orelse return error.UnknownBatch;
        return kv.value;
    }

    /// Owner thread: the changeset is in the queue when this returns.
    pub fn commitBatch(q: *Queue, b: BatchId, o: SubmitOptions) anyerror!ChangesetId {
        const batch = try q.takeBatch(b);
        defer batch.deinit();
        const id: ChangesetId = @enumFromInt(q.next_id.fetchAdd(1, .monotonic));
        try q.install(id, batch, o);
        return id;
    }

    /// Owner thread: commits the batches submitters committed.
    pub fn drain(q: *Queue) void {
        q.mutex.lockUncancelable(q.io);
        var ready = q.committed;
        q.committed = .empty;
        q.mutex.unlock(q.io);
        defer ready.deinit(q.gpa);
        for (ready.items) |c| {
            defer c.batch.deinit();
            q.install(c.id, c.batch, c.opts) catch |e| {
                std.log.scoped(.zg_review).err("changeset {f} could not be built: {t}", .{ c.id, e });
            };
        }
    }

    // ------------------------------------------------------ reads

    pub fn get(q: *const Queue, id: ChangesetId) ?*const Changeset {
        return q.changesets.get(id);
    }

    /// Owner thread: mutable access for review actions (F02, F03).
    pub fn getMut(q: *Queue, id: ChangesetId) ?*Changeset {
        return q.changesets.get(id);
    }

    /// Appends the ids matching `f`, in submission order.
    pub fn list(q: *const Queue, f: Filter, out: *std.ArrayList(ChangesetId), gpa: Allocator) Allocator.Error!void {
        for (q.changesets.values()) |cs| {
            if (f.open_only and cs.state != .pending and cs.state != .partially_applied) continue;
            if (f.session) |s| {
                const r = cs.prov.origin.agentRef() orelse continue;
                if (r.session != s) continue;
            }
            try out.append(gpa, cs.id);
        }
    }

    /// Drops a changeset (GC of decided ones).
    pub fn remove(q: *Queue, id: ChangesetId) void {
        if (!q.changesets.contains(id)) return;
        q.forget(id);
        if (q.journal) |j| j.removed(j.ctx, id);
    }

    fn forget(q: *Queue, id: ChangesetId) void {
        const kv = q.changesets.fetchOrderedRemove(id) orelse return;
        kv.value.deinit(q.gpa);
        q.gpa.destroy(kv.value);
        q.emit(.{ .removed = id });
    }

    /// Records `id`'s current state in the journal (after a review action
    /// changed it).
    pub fn persist(q: *Queue, id: ChangesetId) void {
        const j = q.journal orelse return;
        if (q.changesets.get(id)) |cs| j.changeset(j.ctx, cs);
    }

    /// Owner thread: takes `cs` from the store (load or another process's
    /// append), replacing the changeset with its id. Not journaled.
    pub fn restore(q: *Queue, cs: *Changeset) Allocator.Error!void {
        const gop = try q.changesets.getOrPut(q.gpa, cs.id);
        const replaced = gop.found_existing;
        if (replaced) {
            gop.value_ptr.*.deinit(q.gpa);
            q.gpa.destroy(gop.value_ptr.*);
        }
        gop.value_ptr.* = cs;
        const want = @intFromEnum(cs.id) + 1;
        var cur = q.next_id.load(.monotonic);
        while (cur < want) cur = q.next_id.cmpxchgWeak(cur, want, .monotonic, .monotonic) orelse break;
        q.emit(if (replaced) .{ .updated = cs.id } else .{ .submitted = cs.id });
    }

    /// Owner thread: another process removed `id`. Not journaled.
    pub fn restoreRemoved(q: *Queue, id: ChangesetId) void {
        q.forget(id);
    }

    // ------------------------------------------------------ events

    pub fn subscribe(q: *Queue, l: Listener) Allocator.Error!ListenerId {
        try q.listeners.append(q.gpa, l);
        return @enumFromInt(q.listeners.items.len - 1);
    }

    pub fn unsubscribe(q: *Queue, id: ListenerId) void {
        q.listeners.items[@intFromEnum(id)] = null;
    }

    pub fn emit(q: *Queue, ev: Event) void {
        std.debug.assert(!q.emitting);
        q.emitting = true;
        defer q.emitting = false;
        for (q.listeners.items) |l| if (l) |x| x.on(x.ctx, &ev);
    }

    // ------------------------------------------------------ commit

    fn install(q: *Queue, id: ChangesetId, b: *Batch, o: SubmitOptions) !void {
        std.debug.assert(!q.emitting);
        const cs = try q.build(id, b, o);
        errdefer {
            cs.deinit(q.gpa);
            q.gpa.destroy(cs);
        }
        try q.changesets.put(q.gpa, id, cs);
        const folded = q.foldInto(cs) catch |e| blk: {
            std.log.scoped(.zg_review).warn("folding {f} failed: {t}", .{ id, e });
            break :blk false;
        };
        var superseded = false;
        if (folded) {
            var all = true;
            for (cs.files) |f| all = all and f.state == .superseded;
            if (all) {
                cs.state = .superseded;
                superseded = true;
            }
        }
        q.persist(id);
        q.emit(.{ .submitted = id });
        if (superseded) q.emit(.{ .state = .{ .cs = id, .from = .pending, .to = .superseded } });
    }

    /// The changeset for `b`: files in batch order, texts in `blobs`.
    fn build(q: *Queue, id: ChangesetId, b: *Batch, o: SubmitOptions) !*Changeset {
        const cs = try q.gpa.create(Changeset);
        errdefer q.gpa.destroy(cs);
        var arena: std.heap.ArenaAllocator = .init(q.gpa);
        const a = arena.allocator();
        const files = a.alloc(FileChange, b.entries.items.len) catch |e| {
            arena.deinit();
            return e;
        };
        var built: usize = 0;
        errdefer {
            for (files[0..built]) |*f| f.deinitContent();
            arena.deinit();
        }
        for (b.entries.items, files) |*e, *f| {
            f.* = try q.fileFor(a, e);
            built += 1;
        }
        const now = std.Io.Clock.real.now(q.io);
        cs.* = .{
            .id = id,
            .prov = try batch_mod.copyProvenance(a, b.prov),
            .files = files,
            .state = .pending,
            .supersedes = o.supersedes,
            .checkpoint = o.checkpoint,
            .presentation = o.presentation,
            .created_ms = @intCast(@divFloor(now.nanoseconds, std.time.ns_per_ms)),
            .arena = arena.state,
        };
        return cs;
    }

    fn fileFor(q: *Queue, a: Allocator, e: *batch_mod.Entry) !FileChange {
        var f: FileChange = .{ .path = try a.dupe(u8, e.path), .op = .modify, .content = .none };
        if (e.from) |from| f.op = .{ .rename = .{ .from = try a.dupe(u8, from) } };
        if (e.deleted) {
            const base = e.base.?;
            f.op = .delete;
            f.base = .{ .hash = try q.blobs.put(base), .size = base.len, .eol = .detect(base) };
            return f;
        }
        if (e.created) |text| {
            _ = try q.blobs.put(text);
            f.op = .{ .create = .{ .executable = e.executable orelse false } };
            var edits = try ChangeSet.fromEdits(q.gpa, 0, &.{.{ .range = .{ .start = 0, .end = 0 }, .text = text }});
            errdefer edits.deinit();
            f.hunks = try q.derive(a, "", &edits, &.{});
            f.content = .{ .text = .{ .base = null, .edits = edits } };
            return f;
        }
        if (e.executable) |on| if (e.from == null) {
            f.op = .{ .set_executable = on };
        };
        if (e.edits) |edits| {
            const base = e.base.?;
            const ref: changeset.BaseRef = .{ .hash = try q.blobs.put(base), .size = base.len, .doc_version = e.base_version, .eol = .detect(base) };
            f.hunks = try q.derive(a, base, &edits, &.{});
            f.content = .{ .text = .{ .base = ref, .edits = edits } };
            e.edits = null;
        } else if (f.op == .modify) {
            // Nothing left to change (an edit that composed to nothing).
            f.op = .{ .set_executable = e.executable orelse false };
        }
        return f;
    }

    fn derive(q: *Queue, a: Allocator, base: []const u8, edits: *const ChangeSet, previous: []const changeset.Hunk) ![]changeset.Hunk {
        var lines: zg_core.LineIndex = try .build(q.gpa, base);
        defer lines.deinit(q.gpa);
        var o = q.hunk_options;
        o.previous = previous;
        const hs = try hunks_mod.deriveHunks(q.gpa, base, &lines, edits, o);
        defer q.gpa.free(hs);
        return a.dupe(changeset.Hunk, hs);
    }

    /// Folds `cs`'s text edits into the same session's open changes of the
    /// same files; returns whether any folded.
    fn foldInto(q: *Queue, cs: *Changeset) !bool {
        const ref = cs.prov.origin.agentRef() orelse return false;
        var any = false;
        for (cs.files) |*nf| {
            if (nf.op != .modify or nf.content != .text) continue;
            // Newest first: the change the agent most likely read.
            const vals = q.changesets.values();
            var i = vals.len;
            while (i > 0) {
                i -= 1;
                const o = vals[i];
                const f = foldable(o, cs, ref.session, nf.path) orelse continue;
                if (try q.fold(o, f, cs.id, nf)) {
                    any = true;
                    break;
                }
            }
        }
        return any;
    }

    /// `o`'s file at `path` when the same session's `cs` may fold into it.
    fn foldable(o: *Changeset, cs: *const Changeset, session: u128, path: []const u8) ?*FileChange {
        if (o == cs or o.state != .pending) return null;
        const r = o.prov.origin.agentRef() orelse return null;
        if (r.session != session or !eqlOpt(o.prov.lane, cs.prov.lane)) return null;
        const f = &o.files[o.fileIndex(path) orelse return null];
        if (f.state != .pending or f.content != .text) return null;
        if (f.op != .modify and f.op != .create) return null;
        for (f.hunks) |h| if (h.decision != .undecided) return null;
        return f;
    }

    /// Composes `nf`'s edits onto `old` when `nf` was made against
    /// `old`'s new text.
    fn fold(q: *Queue, ocs: *Changeset, old: *FileChange, new_id: ChangesetId, nf: *FileChange) !bool {
        var scratch: std.heap.ArenaAllocator = .init(q.gpa);
        defer scratch.deinit();
        const sa = scratch.allocator();
        const ot = &old.content.text;
        const nt = &nf.content.text;
        const old_base: []const u8 = if (ot.base) |b| (try q.blobs.get(sa, b.hash)) orelse return false else "";
        const viewed = try ot.edits.applyToSlice(sa, old_base);
        if (!std.mem.eql(u8, &ids.blobHash(viewed), &nt.base.?.hash)) return false;
        const composed = try ot.edits.compose(&nt.edits, q.gpa);
        ot.edits.deinit();
        ot.edits = composed;
        var oarena = ocs.arena.promote(q.gpa);
        defer ocs.arena = oarena.state;
        const a = oarena.allocator();
        old.hunks = try q.derive(a, old_base, &ot.edits, old.hunks);
        const from = try a.alloc(ChangesetId, old.folded_from.len + 1);
        @memcpy(from[0..old.folded_from.len], old.folded_from);
        from[old.folded_from.len] = new_id;
        old.folded_from = from;
        if (old.op == .create) {
            // The created text changed: keep the blob current.
            _ = try q.blobs.put(try ot.edits.applyToSlice(sa, ""));
        }
        nf.deinitContent();
        nf.hunks = &.{};
        nf.state = .superseded;
        q.persist(ocs.id);
        q.emit(.{ .updated = ocs.id });
        return true;
    }
};

fn eqlOpt(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

/// The batch API for any thread. `commitBatch` returns the id at once;
/// the changeset appears on the owner thread's next `drain`.
pub const Submitter = struct {
    q: *Queue,

    pub fn beginBatch(s: *Submitter, prov: Provenance) Error!BatchId {
        return s.q.beginBatch(prov);
    }
    pub fn addEdit(s: *Submitter, b: BatchId, path: []const u8, base: []const u8, base_version: ?u64, edits: *const ChangeSet) Error!void {
        return s.q.addEdit(b, path, base, base_version, edits);
    }
    /// E10's shape.
    pub fn addCreate(s: *Submitter, b: BatchId, path: []const u8, bytes: []const u8) Error!void {
        return s.q.addCreate(b, path, bytes);
    }
    pub fn setExecutable(s: *Submitter, b: BatchId, path: []const u8, on: bool) Error!void {
        return s.q.setExecutable(b, path, on);
    }
    pub fn addDelete(s: *Submitter, b: BatchId, path: []const u8, base: []const u8) Error!void {
        return s.q.addDelete(b, path, base);
    }
    pub fn addRename(s: *Submitter, b: BatchId, from: []const u8, to: []const u8) Error!void {
        return s.q.addRename(b, from, to);
    }
    pub fn abortBatch(s: *Submitter, b: BatchId) void {
        s.q.abortBatch(b);
    }
    /// E10's shape: default options.
    pub fn commitBatch(s: *Submitter, b: BatchId) Error!ChangesetId {
        return s.commitBatchWith(b, .{});
    }
    pub fn commitBatchWith(s: *Submitter, b: BatchId, o: SubmitOptions) Error!ChangesetId {
        const q = s.q;
        const id: ChangesetId = @enumFromInt(q.next_id.fetchAdd(1, .monotonic));
        {
            q.mutex.lockUncancelable(q.io);
            defer q.mutex.unlock(q.io);
            const kv = q.batches.fetchRemove(b) orelse return error.UnknownBatch;
            q.committed.append(q.gpa, .{ .id = id, .batch = kv.value, .opts = o }) catch |e| {
                kv.value.deinit();
                return e;
            };
        }
        if (q.wake) |w| w.wake(w.ctx);
        return id;
    }
};
