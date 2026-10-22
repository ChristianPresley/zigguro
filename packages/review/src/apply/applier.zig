//! Lands review decisions on disk (E12.F02.S03.T02): one call applies the
//! chosen hunks and files of one changeset as a single transaction.
//!
//! 1. Plan: per file, `selection.select` splits the edits into what lands
//!    now and what stays pending.
//! 2. Preflight: every touched path is read once. A file whose content no
//!    longer hashes to the change's base fails the whole apply with
//!    `error.BaseMoved` before anything is written (rebase comes with
//!    E12.F02.S02); a create whose target exists fails with
//!    `error.TargetExists`. Preimages and postimages go to `Blobs`.
//! 3. Execute: writes and deletes through `Files`, in file order. If one
//!    fails, the ones done are reverted from the preimages, in reverse,
//!    and the result is `failed` (`rolled_back` false only if a revert
//!    failed too).
//! 4. Record: each text file is rebased on what landed (its base becomes
//!    the new text, its edits the remainder, its hunks are derived again),
//!    file and changeset states follow, the queue journals the changeset,
//!    `History` gets an `Apply` record, and listeners get `applied` and
//!    `state`.
//!
//! A rename is a write of the new path and a delete of the old one; it
//! lands with the first hunk taken (or the file accepted).
//!
//! Runs on the queue's owner thread and does its I/O there. Not yet:
//! open documents through E05 (the app routes them itself for now), E08
//! FileOps transactions, E09 provenance, line-level selection, and
//! exclusion between processes.

const std = @import("std");
const zg_core = @import("zg_core");
const model = @import("../model/root.zig");
const selection = @import("selection.zig");
const files_mod = @import("files.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const ChangesetId = model.ChangesetId;
const Changeset = model.Changeset;
const FileChange = model.FileChange;
const BlobHash = model.BlobHash;
const Files = files_mod.Files;
const Entry = files_mod.Entry;
const SelectionInput = selection.SelectionInput;
const SelectionResult = selection.SelectionResult;

pub const Whole = enum { accept, reject };

pub const ApplyItem = struct {
    /// Index into the changeset's files.
    file: u32,
    input: SelectionInput = .{},
    /// Decides the whole file: required for files without hunks (delete,
    /// rename, mode change, binary); for text, every hunk.
    whole_file: ?Whole = null,
};

pub const ApplyRequest = struct {
    cs: ChangesetId,
    items: []const ApplyItem,
};

pub const ApplyResult = union(enum) {
    ok: struct {
        /// The `History` record; null when nothing was written (only
        /// rejections).
        apply: ?u64,
        files: u32,
        hunks: u32,
    },
    failed: struct {
        /// Owned by the changeset.
        path: []const u8,
        err: anyerror,
        rolled_back: bool,
    },
};

pub const Error = error{
    UnknownChangeset,
    /// The changeset is not pending or partially applied.
    NotOpen,
    UnknownFile,
    DuplicateItem,
    /// The file is already applied, rejected or superseded.
    AlreadyDecided,
    /// A file without hunks needs `whole_file`.
    DecisionNeeded,
    /// A file's content no longer matches the change's base.
    BaseMoved,
    /// A create or rename target exists already.
    TargetExists,
    /// The file to rename or change the mode of is gone.
    SourceMissing,
    /// A base or binary blob is not in the store.
    MissingBlob,
} || selection.Error;

pub const Applier = struct {
    gpa: Allocator,
    io: Io,
    q: *model.Queue,
    files: Files,
    history: *model.History,

    /// What one file contributes to an apply.
    const Plan = struct {
        idx: u32,
        whole: ?Whole,
        /// Text files only.
        sel: ?SelectionResult = null,
        base: []const u8 = "",
        /// The text after `sel.selected`.
        new_text: []const u8 = "",
        /// Something of this file reaches the disk.
        lands: bool = false,
    };

    const Op = struct { path: []const u8, new: ?[]const u8, exec: ?bool };

    pub fn init(gpa: Allocator, io: Io, q: *model.Queue, files: Files, history: *model.History) Applier {
        return .{ .gpa = gpa, .io = io, .q = q, .files = files, .history = history };
    }

    /// Accepts every hunk and file still open in `cs`.
    pub fn acceptAll(a: *Applier, cs_id: ChangesetId) anyerror!ApplyResult {
        const cs = a.q.get(cs_id) orelse return error.UnknownChangeset;
        var items: std.ArrayList(ApplyItem) = .empty;
        defer items.deinit(a.gpa);
        for (cs.files, 0..) |f, i| if (isOpen(f.state)) try items.append(a.gpa, .{ .file = @intCast(i), .whole_file = .accept });
        return a.apply(.{ .cs = cs_id, .items = items.items });
    }

    /// Applies `req` (see the file comment). Errors leave disk and queue
    /// untouched; a failure while writing is reported in the result.
    pub fn apply(a: *Applier, req: ApplyRequest) anyerror!ApplyResult {
        const cs = a.q.getMut(req.cs) orelse return error.UnknownChangeset;
        if (cs.state != .pending and cs.state != .partially_applied) return error.NotOpen;
        var arena_state: std.heap.ArenaAllocator = .init(a.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        // 1. Plan.
        const plans = try arena.alloc(Plan, req.items.len);
        var planned: usize = 0;
        defer for (plans[0..planned]) |*p| if (p.sel) |*s| s.deinit(a.gpa);
        for (req.items, plans, 0..) |it, *p, k| {
            if (it.file >= cs.files.len) return error.UnknownFile;
            for (req.items[0..k]) |o| if (o.file == it.file) return error.DuplicateItem;
            const fc = &cs.files[it.file];
            if (!isOpen(fc.state)) return error.AlreadyDecided;
            p.* = .{ .idx = it.file, .whole = it.whole_file };
            try a.plan(arena, fc, it, p);
            planned += 1;
        }

        // 2. Preflight.
        var pre: std.StringArrayHashMapUnmanaged(?Entry) = .empty;
        var ops: std.ArrayList(Op) = .empty;
        for (plans) |*p| {
            if (!p.lands) continue;
            const fc = &cs.files[p.idx];
            const src = srcPath(fc);
            const cur = try a.readOnce(arena, &pre, src);
            switch (fc.op) {
                .rename => if (try a.readOnce(arena, &pre, fc.path) != null) return error.TargetExists,
                else => {},
            }
            try checkBase(fc, cur);
            try a.opsFor(arena, fc, p, cur, &ops);
        }
        for (pre.values()) |e| if (e) |x| {
            _ = try a.q.blobs.put(x.bytes);
        };
        for (ops.items) |op| if (op.new) |b| {
            _ = try a.q.blobs.put(b);
        };

        // 3. Execute.
        for (ops.items, 0..) |op, i| {
            const r = if (op.new) |b| a.files.write(op.path, b, op.exec) else a.files.delete(op.path);
            r catch |err| {
                const rolled = a.revert(ops.items[0..i], &pre);
                return .{ .failed = .{ .path = failedPath(cs, op.path), .err = err, .rolled_back = rolled } };
            };
        }

        // 4. Record.
        var hunk_count: u32 = 0;
        for (plans) |*p| hunk_count += try a.settle(cs, p);
        const from = cs.state;
        const to = model.state.derivedState(cs);
        if (to != from) {
            try model.transition(cs, to);
            if (to == .applied or to == .rejected) cs.decided_ms = nowMs(a.io);
        }
        var apply_id: ?u64 = null;
        if (ops.items.len > 0) {
            const recs = try arena.alloc(model.ApplyFile, ops.items.len);
            for (ops.items, recs) |op, *r| {
                const before = pre.get(op.path) orelse null;
                r.* = .{
                    .path = op.path,
                    .pre = if (before) |b| model.blobHash(b.bytes) else null,
                    .post = if (op.new) |b| model.blobHash(b) else null,
                    .pre_exec = if (before) |b| b.executable else false,
                    .post_exec = if (op.new != null) op.exec orelse (if (before) |b| b.executable else false) else false,
                };
            }
            const ref = cs.prov.origin.agentRef();
            apply_id = try a.history.record(.{
                .cs = cs.id,
                .session = if (ref) |r| r.session else null,
                .created_ms = nowMs(a.io),
                .files = recs,
            });
        }
        a.q.persist(cs.id);
        a.q.emit(.{ .updated = cs.id });
        if (apply_id) |id| a.q.emit(.{ .applied = .{ .cs = cs.id, .apply = id } });
        if (to != from) a.q.emit(.{ .state = .{ .cs = cs.id, .from = from, .to = to } });
        return .{ .ok = .{ .apply = apply_id, .files = @intCast(plans.len), .hunks = hunk_count } };
    }

    fn plan(a: *Applier, arena: Allocator, fc: *FileChange, it: ApplyItem, p: *Plan) !void {
        switch (fc.content) {
            .text => |*t| {
                var in = it.input;
                if (it.whole_file) |w| {
                    const all = try arena.alloc(u32, fc.hunks.len);
                    for (all, 0..) |*x, i| x.* = @intCast(i);
                    in = if (w == .accept) .{ .accept = all } else .{ .reject = all };
                }
                if (t.base) |b| {
                    p.base = try a.q.blobs.get(arena, b.hash) orelse return error.MissingBlob;
                }
                var lines: zg_core.LineIndex = try .build(a.gpa, p.base);
                defer lines.deinit(a.gpa);
                p.sel = try selection.select(a.gpa, p.base, &lines, fc, in);
                const takes = p.sel.?.takes();
                p.lands = takes or (fc.op == .rename and it.whole_file == .accept);
                if (p.lands) p.new_text = try p.sel.?.selected.applyToSlice(arena, p.base);
            },
            .none, .binary => {
                const w = it.whole_file orelse return error.DecisionNeeded;
                p.lands = w == .accept;
            },
        }
    }

    /// The disk operations of a landing file.
    fn opsFor(a: *Applier, arena: Allocator, fc: *const FileChange, p: *const Plan, cur: ?Entry, ops: *std.ArrayList(Op)) !void {
        const exec_now: ?bool = if (cur) |c| c.executable else null;
        switch (fc.content) {
            .text => {
                const exec: ?bool = switch (fc.op) {
                    .create => |c| c.executable,
                    .rename => exec_now,
                    else => null,
                };
                try ops.append(arena, .{ .path = fc.path, .new = p.new_text, .exec = exec });
            },
            .binary => |b| {
                const bytes = try a.q.blobs.get(arena, b.new) orelse return error.MissingBlob;
                const exec: ?bool = switch (fc.op) {
                    .create => |c| c.executable,
                    .rename => exec_now,
                    else => null,
                };
                try ops.append(arena, .{ .path = fc.path, .new = bytes, .exec = exec });
            },
            .none => switch (fc.op) {
                .delete => {
                    try ops.append(arena, .{ .path = fc.path, .new = null, .exec = null });
                    return;
                },
                .set_executable => |on| try ops.append(arena, .{ .path = fc.path, .new = cur.?.bytes, .exec = on }),
                .rename => try ops.append(arena, .{ .path = fc.path, .new = cur.?.bytes, .exec = exec_now }),
                .create, .modify => unreachable,
            },
        }
        if (fc.op == .rename) try ops.append(arena, .{ .path = fc.op.rename.from, .new = null, .exec = null });
    }

    fn readOnce(a: *Applier, arena: Allocator, pre: *std.StringArrayHashMapUnmanaged(?Entry), path: []const u8) !?Entry {
        const gop = try pre.getOrPut(arena, path);
        if (!gop.found_existing) gop.value_ptr.* = try a.files.read(arena, path);
        return gop.value_ptr.*;
    }

    /// Reverts `done` from the preimages, newest first; false if any
    /// revert failed.
    fn revert(a: *Applier, done: []const Op, pre: *const std.StringArrayHashMapUnmanaged(?Entry)) bool {
        var ok = true;
        var i = done.len;
        while (i > 0) {
            i -= 1;
            const path = done[i].path;
            const before = pre.get(path) orelse null;
            const r = if (before) |b| a.files.write(path, b.bytes, b.executable) else a.files.delete(path);
            r catch |e| {
                std.log.scoped(.zg_review).warn("apply rollback: {s} not restored: {t}", .{ path, e });
                ok = false;
            };
        }
        return ok;
    }

    /// Moves a file's state and content past this apply; returns the
    /// number of hunks decided.
    fn settle(a: *Applier, cs: *Changeset, p: *Plan) !u32 {
        const fc = &cs.files[p.idx];
        const landed_before = fc.state == .partially_applied;
        const sel = if (p.sel) |*s| s else {
            try model.fileTransition(fc, if (p.lands) .applied else .rejected);
            return 0;
        };
        const decided: u32 = @intCast(sel.decided.len);
        const rest_open = !sel.remainder.isIdentity();
        const new_text = if (p.lands) p.new_text else p.base;

        var arena = cs.arena.promote(a.gpa);
        defer cs.arena = arena.state;
        var lines: zg_core.LineIndex = try .build(a.gpa, new_text);
        defer lines.deinit(a.gpa);
        var o = a.q.hunk_options;
        o.previous = &.{};
        const hs = try model.deriveHunks(a.gpa, new_text, &lines, &sel.remainder, o);
        defer a.gpa.free(hs);
        const hunks = try arena.allocator().dupe(model.Hunk, hs);

        const t = &fc.content.text;
        t.edits.deinit();
        t.edits = sel.remainder;
        sel.remainder = .identity(a.gpa, sel.selected.newLen());
        if (p.lands) {
            // The file on disk is the new base; the op is done.
            t.base = .of(new_text);
            if (fc.op != .modify) fc.op = .modify;
        }
        fc.hunks = hunks;
        const landed = landed_before or p.lands;
        const to: model.FileState = if (rest_open)
            (if (landed) .partially_applied else .pending)
        else if (landed) .applied else .rejected;
        if (to != fc.state) try model.fileTransition(fc, to);
        return decided;
    }
};

fn isOpen(s: model.FileState) bool {
    return s == .pending or s == .partially_applied;
}

fn srcPath(fc: *const FileChange) []const u8 {
    return switch (fc.op) {
        .rename => |r| r.from,
        else => fc.path,
    };
}

/// Whether the file now at the source matches what the change was made
/// against.
fn checkBase(fc: *const FileChange, cur: ?Entry) Error!void {
    const want: ?BlobHash = switch (fc.content) {
        .text => |t| if (t.base) |b| b.hash else null,
        .binary => |b| b.base,
        .none => if (fc.base) |b| b.hash else {
            if (cur == null) return error.SourceMissing;
            return;
        },
    };
    if (want) |h| {
        const c = cur orelse return error.BaseMoved;
        if (!std.mem.eql(u8, &model.blobHash(c.bytes), &h)) return error.BaseMoved;
    } else if (cur != null) return error.TargetExists;
}

fn failedPath(cs: *const Changeset, path: []const u8) []const u8 {
    for (cs.files) |f| {
        if (std.mem.eql(u8, f.path, path)) return f.path;
        if (f.op == .rename and std.mem.eql(u8, f.op.rename.from, path)) return f.op.rename.from;
    }
    unreachable;
}

fn nowMs(io: Io) i64 {
    const now = Io.Clock.real.now(io);
    return @intCast(@divFloor(now.nanoseconds, std.time.ns_per_ms));
}
