//! `ReviewSession` (E12.F03.S02.T01): the UI-independent controller of a
//! review, hunk by hunk. It walks a cursor over (file, hunk) of a target
//! (one changeset, or every open changeset of an agent session), turns
//! decisions into `Applier` calls, and keeps an undo stack of them.
//!
//! - Files are listed per changeset, oldest changeset first, in path
//!   order. The order is stable during the session: files that arrive
//!   later (a new changeset, a fold) are appended.
//! - Deciding a hunk removes it from its file (the Applier re-derives the
//!   rest), so the cursor stays on the same index: the next undecided
//!   hunk. Otherwise the cursor follows its hunk by key when the file is
//!   re-derived (rebase, fold).
//! - Undo pops the last decision: an accept is reverted with
//!   `Applier.undoApply`; a reject, which writes nothing, gets the file's
//!   edits and hunks from before it back.
//!
//! Owner thread (the queue's), like the Applier. Line selection inside a
//! hunk and edit-before-accept wait for the Applier's line-level split.

const std = @import("std");
const model = @import("../model/root.zig");
const apply = @import("../apply/root.zig");

const Allocator = std.mem.Allocator;
const ChangesetId = model.ChangesetId;
const Changeset = model.Changeset;
const FileChange = model.FileChange;
const ChangeSet = model.changeset.ChangeSet;

pub const Target = union(enum) {
    changeset: ChangesetId,
    /// Every open changeset whose origin is this agent session.
    session: u128,
};

/// A file of the review: `cs.files[idx]`.
pub const FileRef = struct {
    cs: ChangesetId,
    idx: u32,
    /// Arrived after the session started.
    new: bool = false,
};

pub const Cursor = struct {
    /// Index into `files()`.
    file: u32 = 0,
    /// Index into that file's hunks; null for files without hunks
    /// (deletes, renames, binaries) or when none is left.
    hunk: ?u32 = null,
};

pub const Progress = struct { decided: u32 = 0, total: u32 = 0 };

pub const Error = error{
    /// The cursor is on nothing that can be decided.
    NothingHere,
    NothingToUndo,
};

/// A decision that failed; nothing changed. `message` lives until the
/// next decision.
pub const Failure = struct { message: []const u8 };

pub const Listener = struct {
    ctx: *anyopaque,
    changed: *const fn (ctx: *anyopaque, s: *ReviewSession) void,
};

/// See the module doc.
pub const ReviewSession = struct {
    gpa: Allocator,
    q: *model.Queue,
    applier: *apply.Applier,
    target: Target,
    files_: std.ArrayList(FileRef) = .empty,
    cursor: Cursor = .{},
    /// The focused hunk's key, to find it again after a re-derive.
    cursor_key: ?u64 = null,
    decided: u32 = 0,
    last_error: ?[]const u8 = null,
    error_buf: [160]u8 = undefined,
    undo_stack: std.ArrayList(Undo) = .empty,
    listener_id: model.queue.ListenerId = undefined,
    listener: ?Listener = null,
    /// Inside our own Applier call: events are ours, refreshed after.
    busy: bool = false,

    const Undo = union(enum) {
        /// `History` apply record of an accept.
        accept: struct { apply: u64, hunks: u32 },
        /// The file as it was before a reject.
        reject: Snapshot,
    };

    const Snapshot = struct {
        cs: ChangesetId,
        idx: u32,
        state: model.FileState,
        cs_state: model.State,
        hunks: []model.Hunk,
        edits: ?ChangeSet,
        count: u32,
    };

    pub fn init(gpa: Allocator, q: *model.Queue, applier: *apply.Applier, target: Target) !*ReviewSession {
        const s = try gpa.create(ReviewSession);
        errdefer gpa.destroy(s);
        s.* = .{ .gpa = gpa, .q = q, .applier = applier, .target = target };
        errdefer s.files_.deinit(gpa);
        try s.collect(false);
        s.listener_id = try q.subscribe(.{ .ctx = s, .on = onEvent });
        s.focus(s.cursor);
        return s;
    }

    pub fn deinit(s: *ReviewSession) void {
        s.q.unsubscribe(s.listener_id);
        for (s.undo_stack.items) |*u| freeUndo(s.gpa, u);
        s.undo_stack.deinit(s.gpa);
        s.files_.deinit(s.gpa);
        s.gpa.destroy(s);
    }

    fn freeUndo(gpa: Allocator, u: *Undo) void {
        switch (u.*) {
            .accept => {},
            .reject => |*r| {
                gpa.free(r.hunks);
                if (r.edits) |*e| e.deinit();
            },
        }
    }

    // -------------------------------------------------------- reading

    pub fn files(s: *const ReviewSession) []const FileRef {
        return s.files_.items;
    }

    pub fn fileChange(s: *const ReviewSession, i: u32) ?*const FileChange {
        if (i >= s.files_.items.len) return null;
        const r = s.files_.items[i];
        const cs = s.q.get(r.cs) orelse return null;
        if (r.idx >= cs.files.len) return null;
        return &cs.files[r.idx];
    }

    pub fn changesetOf(s: *const ReviewSession, i: u32) ?*const Changeset {
        if (i >= s.files_.items.len) return null;
        return s.q.get(s.files_.items[i].cs);
    }

    /// File `i`'s text before and after its open changes, in `arena`
    /// (a create's base is empty); null for a file without text.
    pub fn texts(s: *const ReviewSession, arena: Allocator, i: u32) !?struct { base: []const u8, new: []const u8 } {
        const fc = s.fileChange(i) orelse return null;
        const t = switch (fc.content) {
            .text => |*t| t,
            else => return null,
        };
        const base: []const u8 = if (t.base) |b| try s.q.blobs.get(arena, b.hash) orelse return error.MissingBlob else "";
        return .{ .base = base, .new = try t.edits.applyToSlice(arena, base) };
    }

    /// The focused hunk, if any.
    pub fn hunk(s: *const ReviewSession) ?*const model.Hunk {
        const fc = s.fileChange(s.cursor.file) orelse return null;
        const h = s.cursor.hunk orelse return null;
        return if (h < fc.hunks.len) &fc.hunks[h] else null;
    }

    /// Decided in this session, and that plus what is still open.
    pub fn progress(s: *const ReviewSession) Progress {
        var open: u32 = 0;
        for (0..s.files_.items.len) |i| {
            const fc = s.fileChange(@intCast(i)) orelse continue;
            if (!isOpen(fc.state)) continue;
            open += if (fc.hunks.len > 0) @intCast(fc.hunks.len) else 1;
        }
        return .{ .decided = s.decided, .total = s.decided + open };
    }

    pub fn subscribe(s: *ReviewSession, l: Listener) void {
        s.listener = l;
    }

    // ----------------------------------------------------- navigation

    /// The next hunk (into the next file at the end of one).
    pub fn next(s: *ReviewSession) void {
        const fc = s.fileChange(s.cursor.file);
        if (fc != null and s.cursor.hunk != null and s.cursor.hunk.? + 1 < fc.?.hunks.len) {
            s.focus(.{ .file = s.cursor.file, .hunk = s.cursor.hunk.? + 1 });
        } else s.nextFile();
    }

    pub fn prev(s: *ReviewSession) void {
        if (s.cursor.hunk) |h| if (h > 0) return s.focus(.{ .file = s.cursor.file, .hunk = h - 1 });
        if (s.cursor.file == 0) return;
        const f = s.cursor.file - 1;
        const n = if (s.fileChange(f)) |fc| fc.hunks.len else 0;
        s.focus(.{ .file = f, .hunk = if (n > 0) @intCast(n - 1) else null });
    }

    pub fn nextFile(s: *ReviewSession) void {
        if (s.cursor.file + 1 < s.files_.items.len) s.focus(.{ .file = s.cursor.file + 1, .hunk = 0 });
    }

    pub fn prevFile(s: *ReviewSession) void {
        if (s.cursor.file > 0) s.focus(.{ .file = s.cursor.file - 1, .hunk = 0 });
    }

    /// The next open hunk or file after the cursor, wrapping around.
    pub fn nextUndecided(s: *ReviewSession) bool {
        return s.seek(struct {
            fn want(fc: *const FileChange, h: ?u32) bool {
                _ = h;
                return isOpen(fc.state);
            }
        }.want);
    }

    /// The next hunk with a conflict, wrapping around.
    pub fn nextConflict(s: *ReviewSession) bool {
        return s.seek(struct {
            fn want(fc: *const FileChange, h: ?u32) bool {
                const i = h orelse return fc.state == .conflicted;
                return fc.hunks[i].conflict != null;
            }
        }.want);
    }

    fn seek(s: *ReviewSession, comptime want: fn (*const FileChange, ?u32) bool) bool {
        const n: u32 = @intCast(s.files_.items.len);
        if (n == 0) return false;
        var f = s.cursor.file;
        var start: u32 = if (s.cursor.hunk) |h| h + 1 else 1;
        var steps: u32 = 0;
        while (steps <= n) : (steps += 1) {
            if (s.fileChange(f)) |fc| if (isOpen(fc.state) or fc.state == .conflicted) {
                if (fc.hunks.len == 0) {
                    if (start == 0 and want(fc, null)) return s.focusFound(.{ .file = f, .hunk = null });
                } else {
                    var h = start;
                    while (h < fc.hunks.len) : (h += 1) if (want(fc, h)) return s.focusFound(.{ .file = f, .hunk = h });
                }
            };
            f = (f + 1) % n;
            start = 0;
        }
        return false;
    }

    fn focusFound(s: *ReviewSession, c: Cursor) bool {
        s.focus(c);
        return true;
    }

    /// Moves the cursor to `c`, clamped.
    pub fn focus(s: *ReviewSession, c: Cursor) void {
        const n = s.files_.items.len;
        var f = c.file;
        if (n == 0) f = 0 else if (f >= n) f = @intCast(n - 1);
        var h: ?u32 = null;
        if (s.fileChange(f)) |fc| if (fc.hunks.len > 0) {
            h = @min(c.hunk orelse 0, @as(u32, @intCast(fc.hunks.len - 1)));
        };
        s.cursor = .{ .file = f, .hunk = h };
        s.cursor_key = if (s.hunk()) |x| x.key else null;
    }

    // ------------------------------------------------------ decisions

    pub fn acceptHunk(s: *ReviewSession) !?Failure {
        const h = s.cursor.hunk orelse return s.decideFile(.accept);
        return s.decide(&.{.{ .file = s.files_.items[s.cursor.file].idx, .input = .{ .accept = &.{h} } }}, 1, null);
    }

    pub fn rejectHunk(s: *ReviewSession) !?Failure {
        const h = s.cursor.hunk orelse return s.decideFile(.reject);
        return s.decide(&.{.{ .file = s.files_.items[s.cursor.file].idx, .input = .{ .reject = &.{h} } }}, 1, s.cursor.file);
    }

    pub fn acceptFile(s: *ReviewSession) !?Failure {
        return s.decideFile(.accept);
    }

    pub fn rejectFile(s: *ReviewSession) !?Failure {
        return s.decideFile(.reject);
    }

    fn decideFile(s: *ReviewSession, w: apply.applier.Whole) !?Failure {
        const fc = s.fileChange(s.cursor.file) orelse return error.NothingHere;
        if (!isOpen(fc.state)) return error.NothingHere;
        const n: u32 = if (fc.hunks.len > 0) @intCast(fc.hunks.len) else 1;
        return s.decide(&.{.{ .file = s.files_.items[s.cursor.file].idx, .whole_file = w }}, n, if (w == .reject) s.cursor.file else null);
    }

    /// Accepts every open file of the focused file's changeset.
    pub fn acceptChangeset(s: *ReviewSession) !?Failure {
        if (s.cursor.file >= s.files_.items.len) return error.NothingHere;
        const id = s.files_.items[s.cursor.file].cs;
        const cs = s.q.get(id) orelse return error.NothingHere;
        var items: std.ArrayList(apply.ApplyItem) = .empty;
        defer items.deinit(s.gpa);
        var n: u32 = 0;
        for (cs.files, 0..) |f, i| if (isOpen(f.state)) {
            try items.append(s.gpa, .{ .file = @intCast(i), .whole_file = .accept });
            n += if (f.hunks.len > 0) @intCast(f.hunks.len) else 1;
        };
        if (items.items.len == 0) return error.NothingHere;
        return s.decideIn(id, items.items, n, null);
    }

    fn decide(s: *ReviewSession, items: []const apply.ApplyItem, n: u32, reject_file: ?u32) !?Failure {
        if (s.cursor.file >= s.files_.items.len) return error.NothingHere;
        return s.decideIn(s.files_.items[s.cursor.file].cs, items, n, reject_file);
    }

    /// Runs the Applier; a reject of file `reject_file` keeps a snapshot
    /// for undo.
    fn decideIn(s: *ReviewSession, id: ChangesetId, items: []const apply.ApplyItem, n: u32, reject_file: ?u32) !?Failure {
        s.last_error = null;
        try s.undo_stack.ensureUnusedCapacity(s.gpa, 1);
        var snap: ?Snapshot = if (reject_file) |f| try s.snapshot(f) else null;
        s.busy = true;
        const r = s.applier.apply(.{ .cs = id, .items = items }) catch |e| {
            s.busy = false;
            if (snap) |*x| freeSnapshot(s.gpa, x);
            return s.fail("{t}", .{e});
        };
        s.busy = false;
        switch (r) {
            .ok => |ok| {
                if (ok.apply) |a| {
                    if (snap) |*x| freeSnapshot(s.gpa, x);
                    s.undo_stack.appendAssumeCapacity(.{ .accept = .{ .apply = a, .hunks = n } });
                } else if (snap) |x| {
                    var y = x;
                    y.count = n;
                    s.undo_stack.appendAssumeCapacity(.{ .reject = y });
                }
                s.decided += n;
            },
            .failed => |f| {
                if (snap) |*x| freeSnapshot(s.gpa, x);
                return s.fail("Writing {s} failed: {t}", .{ f.path, f.err });
            },
        }
        try s.collect(true);
        // The decided hunk is gone: the same index is the next one.
        s.focus(s.cursor);
        if (s.hunk() == null and s.fileChange(s.cursor.file) != null and !isOpen(s.fileChange(s.cursor.file).?.state)) _ = s.nextUndecided();
        s.notify();
        return null;
    }

    fn fail(s: *ReviewSession, comptime fmt: []const u8, args: anytype) ?Failure {
        const m = std.fmt.bufPrint(&s.error_buf, fmt, args) catch s.error_buf[0..];
        s.last_error = m;
        s.notify();
        return .{ .message = m };
    }

    /// Undoes the last decision. A reverted accept can conflict with
    /// later edits: then nothing changes and the failure says where.
    pub fn undo(s: *ReviewSession) !?Failure {
        const u = s.undo_stack.pop() orelse return error.NothingToUndo;
        s.last_error = null;
        switch (u) {
            .accept => |a| {
                var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
                defer arena_state.deinit();
                s.busy = true;
                const r = s.applier.undoApply(arena_state.allocator(), a.apply) catch |e| {
                    s.busy = false;
                    s.undo_stack.appendAssumeCapacity(u);
                    return s.fail("Undo failed: {t}", .{e});
                };
                s.busy = false;
                switch (r) {
                    .ok => s.decided -|= a.hunks,
                    .conflicts => |c| {
                        s.undo_stack.appendAssumeCapacity(u);
                        return s.fail("Not undone: {s} changed since on the same lines", .{c[0].path});
                    },
                    .failed => |f| {
                        s.undo_stack.appendAssumeCapacity(u);
                        return s.fail("Writing {s} failed: {t}", .{ f.path, f.err });
                    },
                }
            },
            .reject => |r| {
                var x = r;
                s.restore(&x);
                s.decided -|= r.count;
            },
        }
        try s.collect(true);
        s.focus(s.cursor);
        s.notify();
        return null;
    }

    fn snapshot(s: *ReviewSession, f: u32) !Snapshot {
        const fc = s.fileChange(f) orelse return error.NothingHere;
        const id = s.files_.items[f].cs;
        const hunks = try s.gpa.dupe(model.Hunk, fc.hunks);
        errdefer s.gpa.free(hunks);
        const edits: ?ChangeSet = switch (fc.content) {
            .text => |*t| try t.edits.clone(s.gpa),
            else => null,
        };
        return .{ .cs = id, .idx = s.files_.items[f].idx, .state = fc.state, .cs_state = s.q.get(id).?.state, .hunks = hunks, .edits = edits, .count = 0 };
    }

    fn freeSnapshot(gpa: Allocator, x: *Snapshot) void {
        gpa.free(x.hunks);
        if (x.edits) |*e| e.deinit();
    }

    /// Puts a rejected file back as it was (and frees `x`).
    fn restore(s: *ReviewSession, x: *Snapshot) void {
        defer s.gpa.free(x.hunks);
        const cs = s.q.getMut(x.cs) orelse {
            if (x.edits) |*e| e.deinit();
            return;
        };
        const fc = &cs.files[x.idx];
        var arena = cs.arena.promote(s.gpa);
        defer cs.arena = arena.state;
        if (arena.allocator().dupe(model.Hunk, x.hunks)) |hs| fc.hunks = hs else |_| {}
        switch (fc.content) {
            .text => |*t| if (x.edits) |e| {
                t.edits.deinit();
                t.edits = e;
            },
            else => if (x.edits) |*e| e.deinit(),
        }
        fc.state = x.state;
        const from = cs.state;
        cs.state = x.cs_state;
        if (cs.state == .pending) cs.decided_ms = null;
        s.q.persist(cs.id);
        s.q.emit(.{ .updated = cs.id });
        if (from != cs.state) s.q.emit(.{ .state = .{ .cs = cs.id, .from = from, .to = cs.state } });
    }

    // ------------------------------------------------------- updates

    /// Lists the target's files; with `keep`, the current ones stay in
    /// place and new ones are appended.
    fn collect(s: *ReviewSession, keep: bool) !void {
        if (!keep) s.files_.clearRetainingCapacity();
        var ids: std.ArrayList(*const Changeset) = .empty;
        defer ids.deinit(s.gpa);
        for (s.q.changesets.values()) |cs| if (s.inTarget(cs)) try ids.append(s.gpa, cs);
        std.mem.sort(*const Changeset, ids.items, {}, struct {
            fn lt(_: void, a: *const Changeset, b: *const Changeset) bool {
                if (a.created_ms != b.created_ms) return a.created_ms < b.created_ms;
                return @intFromEnum(a.id) < @intFromEnum(b.id);
            }
        }.lt);
        for (ids.items) |cs| {
            const start = s.files_.items.len;
            for (cs.files, 0..) |f, i| {
                if (f.state == .superseded) continue;
                const known = for (s.files_.items) |r| {
                    if (r.cs == cs.id and r.idx == i) break true;
                } else false;
                if (!known) try s.files_.append(s.gpa, .{ .cs = cs.id, .idx = @intCast(i), .new = keep });
            }
            const Ctx = struct { cs: *const Changeset };
            std.mem.sort(FileRef, s.files_.items[start..], Ctx{ .cs = cs }, struct {
                fn lt(c: Ctx, a: FileRef, b: FileRef) bool {
                    return std.mem.order(u8, c.cs.files[a.idx].path, c.cs.files[b.idx].path) == .lt;
                }
            }.lt);
        }
    }

    fn inTarget(s: *const ReviewSession, cs: *const Changeset) bool {
        return switch (s.target) {
            .changeset => |id| cs.id == id,
            .session => |sess| blk: {
                const r = cs.prov.origin.agentRef() orelse break :blk false;
                break :blk r.session == sess and (cs.state == .pending or cs.state == .partially_applied);
            },
        };
    }

    fn onEvent(ctx: *anyopaque, ev: *const model.Event) void {
        const s: *ReviewSession = @ptrCast(@alignCast(ctx));
        if (s.busy) return;
        switch (ev.*) {
            .applied => return,
            else => {},
        }
        s.collect(true) catch {};
        // Keep the focused hunk by key.
        if (s.cursor_key) |k| if (s.fileChange(s.cursor.file)) |fc| {
            for (fc.hunks, 0..) |h, i| if (h.key == k) {
                s.cursor.hunk = @intCast(i);
                break;
            };
        };
        s.focus(s.cursor);
        s.notify();
    }

    fn notify(s: *ReviewSession) void {
        if (s.listener) |l| l.changed(l.ctx, s);
    }
};

fn isOpen(st: model.FileState) bool {
    return st == .pending or st == .partially_applied;
}
