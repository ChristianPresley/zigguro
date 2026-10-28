//! The workspace edit engine (E07.F04.S02.T01): the one applier for every
//! LSP `WorkspaceEdit` (rename, code actions, formatting,
//! `workspace/applyEdit`, agent tools).
//!
//! `apply` either routes the plan to the review queue (agent edits,
//! server edits caused by an agent-run command, `needsConfirmation`
//! annotations, edits past the size limits, or on request) or applies it
//! transactionally: steps run in order, each recording its inverse, and a
//! failure at step k rolls back steps k-1..0. Text goes through the
//! document's editor when one shows it (one undo step there) or straight
//! to the document; files that are not open are opened in the background,
//! edited and saved at the end. Resource operations go through `FileOps`;
//! deleted (and overwritten) files are moved to a trash the undo restores
//! them from.
//!
//! Each applied plan gets one workspace undo entry (`undo`): it checks
//! that every file still has the text the edit left before reverting
//! anything.

const Engine = @This();
const std = @import("std");
const zg_lsp = @import("zg_lsp");
const zg_editor = @import("zg_editor");
const plan_mod = @import("plan.zig");
const Manager = @import("../Manager.zig");

const Allocator = std.mem.Allocator;
const protocol = zg_lsp.protocol;
const DocumentRegistry = zg_editor.model.api.registry.DocumentRegistry;
const DocHandle = zg_editor.model.api.registry.DocHandle;
const ChangeSet = zg_editor.model.edit.change_set.ChangeSet;
const Replace = zg_editor.model.edit.change_set.Replace;
const EditorView = zg_editor.view.EditorView;
const log = std.log.scoped(.wsedit);

pub const EditPlan = plan_mod.EditPlan;
pub const FileOps = plan_mod.FileOps;
pub const Source = plan_mod.Source;
pub const Failure = plan_mod.Failure;

pub const Origin = union(enum) {
    user,
    /// An agent session (E10/E12).
    agent: u32,
    /// `workspace/applyEdit` from a server: the agent session when an
    /// agent-run command caused it, null for a user's.
    server: ?u32,

    pub fn isAgent(o: Origin) bool {
        return switch (o) {
            .user => false,
            .agent => true,
            .server => |s| s != null,
        };
    }
};

pub const Mode = enum { auto, force_review, force_apply };

pub const Outcome = union(enum) {
    applied: struct { undo_id: u64 },
    queued: struct { changeset: u64 },
    /// `step` is the change's index in the edit.
    failed: struct { step: u32, reason: []const u8 },
};

/// Submits a plan to the E12 review queue; on accept the queue applies it
/// (`apply(.force_apply)` or its own applier).
pub const ReviewSink = struct {
    ctx: *anyopaque,
    submit: *const fn (ctx: *anyopaque, plan: *const EditPlan, origin: Origin) anyerror!u64,
};

/// The editor showing a document, if any.
pub const EditorLookup = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, h: DocHandle) ?*EditorView,
};

pub const Options = struct {
    /// Save files that were not open (`lsp.workspaceEdit.saveUntouchedFiles`).
    save_untouched: bool = true,
    limits: plan_mod.Limits = .{},
    /// Workspace undo entries kept.
    max_undo: usize = 32,
};

const Inverse = union(enum) {
    text: struct { path: []u8, after_hash: u64, inverse: ChangeSet },
    /// Undo: remove the file, then restore what it overwrote.
    created: struct { path: []u8, trashed: ?[]u8 },
    /// Undo: move back, then restore what it overwrote.
    renamed: struct { old: []u8, new: []u8, trashed: ?[]u8 },
    deleted: struct { path: []u8, token: []u8 },
};

const UndoEntry = struct {
    id: u64,
    label: []u8,
    inverses: []Inverse,
};

gpa: Allocator,
docs: *DocumentRegistry,
fs: FileOps,
review: ?ReviewSink = null,
editors: ?EditorLookup = null,
opts: Options = .{},
undos: std.ArrayList(UndoEntry) = .empty,
next_id: u64 = 1,

pub fn init(gpa: Allocator, docs: *DocumentRegistry, fs: FileOps, opts: Options) Engine {
    return .{ .gpa = gpa, .docs = docs, .fs = fs, .opts = opts };
}

pub fn deinit(e: *Engine) void {
    for (e.undos.items) |*u| e.freeEntry(u, true);
    e.undos.deinit(e.gpa);
}

/// Plans `edit` (see plan.zig).
pub fn plan(e: *Engine, edit: *const protocol.WorkspaceEdit, src: Source, label: []const u8, fail: ?*Failure) !EditPlan {
    return plan_mod.plan(e.gpa, e.docs, e.fs, edit, src, label, fail);
}

/// The encoding of `s` and the versions it was sent.
pub fn sourceOf(s: *Manager.Server) Source {
    const enc: plan_mod.Encoding = if (s.sync) |sy| sy.enc else .utf16;
    return .{ .enc = enc, .versions = .{ .ctx = s, .f = serverVersion } };
}

fn serverVersion(ctx: *anyopaque, h: DocHandle) ?i32 {
    const s: *Manager.Server = @ptrCast(@alignCast(ctx));
    const sy = if (s.sync) |*x| x else return null;
    if (sy.hasPending(h)) return null;
    return sy.version(h);
}

pub const ApplyEditResult = zg_lsp.client.host.ApplyEditResult;

/// Applies a server's `workspace/applyEdit`. `agent` is the agent session
/// whose command caused it, if any (the edit then goes to review).
pub fn serverEdit(e: *Engine, s: *Manager.Server, params: *const protocol.ApplyWorkspaceEditParams, agent: ?u32) ApplyEditResult {
    var fail: Failure = .{ .index = 0, .err = error.Unknown };
    var p = e.plan(&params.edit, sourceOf(s), params.label orelse "Workspace edit", &fail) catch
        return .{ .applied = false, .failure_reason = plan_mod.reason(fail.err), .failed_change = fail.index };
    defer p.deinit();
    const out = e.apply(&p, .{ .server = agent }, .auto) catch |err|
        return .{ .applied = false, .failure_reason = plan_mod.reason(err) };
    return switch (out) {
        .applied => .{ .applied = true },
        .queued => .{ .applied = false, .failure_reason = "queued for review" },
        .failed => |f| .{ .applied = false, .failure_reason = f.reason, .failed_change = f.step },
    };
}

/// Whether `apply(p, origin, mode)` would queue the plan for review.
pub fn routesToReview(e: *const Engine, p: *const EditPlan, origin: Origin, mode: Mode) bool {
    return switch (mode) {
        .force_review => true,
        .force_apply => false,
        .auto => origin.isAgent() or p.needs_confirmation or p.isLarge(e.opts.limits),
    };
}

pub fn apply(e: *Engine, p: *const EditPlan, origin: Origin, mode: Mode) !Outcome {
    if (e.routesToReview(p, origin, mode)) {
        // Fail closed: an edit that needs review never applies without it.
        const sink = e.review orelse return .{ .failed = .{ .step = 0, .reason = "review is not available" } };
        return .{ .queued = .{ .changeset = try sink.submit(sink.ctx, p, origin) } };
    }
    var done: std.ArrayList(Inverse) = .empty;
    defer done.deinit(e.gpa);
    var bg: std.ArrayList(DocHandle) = .empty;
    defer {
        for (bg.items) |h| e.docs.release(h);
        bg.deinit(e.gpa);
    }
    for (p.steps) |*st| {
        e.step(st, &done, &bg) catch |err| {
            log.info("workspace edit '{s}' failed at change {d}: {t}", .{ p.label, st.index, err });
            e.rollback(done.items);
            return .{ .failed = .{ .step = st.index, .reason = plan_mod.reason(err) } };
        };
    }
    if (e.opts.save_untouched) {
        for (bg.items, 0..) |h, k| e.saveDoc(h) catch |err| {
            log.info("workspace edit '{s}': saving failed: {t}", .{ p.label, err });
            e.rollback(done.items);
            // The files saved before the failure get their old text back.
            for (bg.items[0..k]) |s| e.saveDoc(s) catch {};
            return .{ .failed = .{ .step = @intCast(p.steps.len), .reason = plan_mod.reason(err) } };
        };
    }
    const inverses = try done.toOwnedSlice(e.gpa);
    errdefer e.gpa.free(inverses);
    const label = try e.gpa.dupe(u8, p.label);
    errdefer e.gpa.free(label);
    if (e.undos.items.len >= e.opts.max_undo and e.undos.items.len > 0) {
        var old = e.undos.orderedRemove(0);
        e.freeEntry(&old, true);
    }
    const id = e.next_id;
    e.next_id += 1;
    try e.undos.append(e.gpa, .{ .id = id, .label = label, .inverses = inverses });
    return .{ .applied = .{ .undo_id = id } };
}

/// The newest workspace undo entry: its id and label.
pub fn lastUndo(e: *const Engine) ?struct { id: u64, label: []const u8, files: usize } {
    if (e.undos.items.len == 0) return null;
    const u = e.undos.items[e.undos.items.len - 1];
    return .{ .id = u.id, .label = u.label, .files = u.inverses.len };
}

/// Reverts the edit `undo_id` applied. Fails (changing nothing) when a
/// file no longer has the text the edit left.
pub fn undo(e: *Engine, undo_id: u64) !void {
    const i = for (e.undos.items, 0..) |u, i| {
        if (u.id == undo_id) break i;
    } else return error.UnknownUndo;
    const u = &e.undos.items[i];
    // Check first: undo all or nothing.
    for (u.inverses) |*inv| switch (inv.*) {
        .text => |t| {
            // A file the edit deleted or moved afterwards is checked when
            // its text is reverted.
            const cur = e.hashPath(t.path) catch continue;
            if (cur != t.after_hash) return error.Changed;
        },
        else => {},
    };
    var bg: std.ArrayList(DocHandle) = .empty;
    defer {
        for (bg.items) |h| e.docs.release(h);
        bg.deinit(e.gpa);
    }
    var j = u.inverses.len;
    while (j > 0) {
        j -= 1;
        try e.revertOne(&u.inverses[j], &bg);
    }
    for (bg.items) |h| try e.saveDoc(h);
    var entry = e.undos.orderedRemove(i);
    e.freeEntry(&entry, false);
}

fn freeEntry(e: *Engine, u: *UndoEntry, forget: bool) void {
    for (u.inverses) |*inv| e.freeInverse(inv, forget);
    e.gpa.free(u.inverses);
    e.gpa.free(u.label);
}

fn freeInverse(e: *Engine, inv: *Inverse, forget: bool) void {
    switch (inv.*) {
        .text => |*t| {
            e.gpa.free(t.path);
            t.inverse.deinit();
        },
        .created => |c| {
            e.gpa.free(c.path);
            if (c.trashed) |tok| {
                if (forget) e.fs.forget(tok);
                e.gpa.free(tok);
            }
        },
        .renamed => |r| {
            e.gpa.free(r.old);
            e.gpa.free(r.new);
            if (r.trashed) |tok| {
                if (forget) e.fs.forget(tok);
                e.gpa.free(tok);
            }
        },
        .deleted => |d| {
            e.gpa.free(d.path);
            if (forget) e.fs.forget(d.token);
            e.gpa.free(d.token);
        },
    }
}

/// Undoes `done` (newest first) after a failed step, freeing it.
fn rollback(e: *Engine, done: []Inverse) void {
    var bg: std.ArrayList(DocHandle) = .empty;
    defer {
        for (bg.items) |h| e.docs.release(h);
        bg.deinit(e.gpa);
    }
    var j = done.len;
    while (j > 0) {
        j -= 1;
        e.revertOne(&done[j], &bg) catch |err| log.warn("workspace edit rollback: {t}", .{err});
        e.freeInverse(&done[j], false);
    }
    // Background documents were edited in memory only: drop them without
    // saving, unless a file saved before a save failure must be put back.
    for (bg.items) |h| if (e.docs.get(h)) |d| if (d.isDirty()) e.saveDoc(h) catch {};
}

/// The document open at `path`, opened in the background (added to `bg`)
/// when it is not.
fn docAt(e: *Engine, path: []const u8, bg: *std.ArrayList(DocHandle)) !DocHandle {
    if (try e.docs.findFile(path)) |h| return h;
    const bytes = try e.fs.read(e.gpa, path);
    defer e.gpa.free(bytes);
    const h = try e.docs.openFile(path, bytes);
    errdefer e.docs.release(h);
    try bg.append(e.gpa, h);
    return h;
}

fn isBackground(bg: []const DocHandle, h: DocHandle) bool {
    for (bg) |b| if (std.meta.eql(b, h)) return true;
    return false;
}

fn hashPath(e: *Engine, path: []const u8) !u64 {
    if (try e.docs.findFile(path)) |h| return plan_mod.hashText(&e.docs.get(h).?.tree);
    const bytes = try e.fs.read(e.gpa, path);
    defer e.gpa.free(bytes);
    var hs: std.hash.Fnv1a_64 = .init();
    hs.update(bytes);
    return hs.final();
}

fn saveDoc(e: *Engine, h: DocHandle) !void {
    const doc = e.docs.get(h) orelse return;
    const path = e.docs.name(h) orelse return;
    const bytes = try doc.tree.copyRange(e.gpa, .{ .start = 0, .end = doc.len() });
    defer e.gpa.free(bytes);
    try e.fs.write(path, bytes);
}

/// Writes the background documents at `path` or under it to disk, so the
/// file operation that follows moves or trashes their edited text.
fn flushUnder(e: *Engine, path: []const u8, bg: *std.ArrayList(DocHandle)) !void {
    var hs: std.ArrayList(DocHandle) = .empty;
    defer hs.deinit(e.gpa);
    try e.docs.filesUnder(e.gpa, path, &hs);
    for (hs.items) |h| {
        const k = for (bg.items, 0..) |b, k| {
            if (std.meta.eql(b, h)) break k;
        } else continue;
        try e.saveDoc(h);
        _ = bg.swapRemove(k);
        e.docs.release(h);
    }
}

/// Applies `edits` (sorted, against `h`'s current text) and returns the
/// inverse.
fn editDoc(e: *Engine, h: DocHandle, edits: []const Replace) !ChangeSet {
    if (e.docs.isReadOnly(h)) return error.ReadOnly;
    const doc = e.docs.get(h).?;
    var cs = try ChangeSet.fromEdits(e.gpa, doc.len(), edits);
    defer cs.deinit();
    var inverse = try cs.invert(doc.tree, e.gpa);
    errdefer inverse.deinit();
    const view = if (e.editors) |l| l.f(l.ctx, h) else null;
    if (view) |v| try v.applyEdits(edits) else try doc.applyChangeSet(&cs, .lsp_edit);
    return inverse;
}

fn step(e: *Engine, st: *const plan_mod.Step, done: *std.ArrayList(Inverse), bg: *std.ArrayList(DocHandle)) !void {
    try done.ensureUnusedCapacity(e.gpa, 1);
    switch (st.op) {
        .skip => {},
        .text => |t| {
            const h = try e.docAt(t.path, bg);
            const doc = e.docs.get(h).?;
            if (doc.len() != t.base_len or plan_mod.hashText(&doc.tree) != t.base_hash) return error.Changed;
            const path = try e.gpa.dupe(u8, t.path);
            errdefer e.gpa.free(path);
            var inverse = try e.editDoc(h, t.edits);
            errdefer inverse.deinit();
            done.appendAssumeCapacity(.{ .text = .{ .path = path, .after_hash = plan_mod.hashText(&doc.tree), .inverse = inverse } });
        },
        .create => |c| {
            const path = try e.gpa.dupe(u8, c.path);
            errdefer e.gpa.free(path);
            var trashed: ?[]u8 = null;
            if (c.overwrite) {
                try e.flushUnder(c.path, bg);
                trashed = try e.fs.trash(e.gpa, c.path);
            }
            errdefer if (trashed) |tok| {
                e.fs.restore(tok, c.path) catch {};
                e.gpa.free(tok);
            };
            try e.fs.write(c.path, "");
            // An open document of the overwritten file now shows the new,
            // empty one.
            if (c.overwrite) if (try e.docs.findFile(c.path)) |h| {
                const doc = e.docs.get(h).?;
                if (doc.len() > 0) {
                    const edits = [_]Replace{.{ .range = .{ .start = 0, .end = doc.len() }, .text = "" }};
                    var cs = try ChangeSet.fromEdits(e.gpa, doc.len(), &edits);
                    defer cs.deinit();
                    try doc.applyChangeSet(&cs, .reload);
                }
            };
            done.appendAssumeCapacity(.{ .created = .{ .path = path, .trashed = trashed } });
        },
        .rename => |r| {
            const old = try e.gpa.dupe(u8, r.old);
            errdefer e.gpa.free(old);
            const new = try e.gpa.dupe(u8, r.new);
            errdefer e.gpa.free(new);
            var trashed: ?[]u8 = null;
            if (r.overwrite) {
                try e.flushUnder(r.new, bg);
                trashed = try e.fs.trash(e.gpa, r.new);
            }
            errdefer if (trashed) |tok| {
                e.fs.restore(tok, r.new) catch {};
                e.gpa.free(tok);
            };
            try e.fs.move(r.old, r.new);
            errdefer e.fs.move(r.new, r.old) catch {};
            try e.moveDocs(r.old, r.new);
            done.appendAssumeCapacity(.{ .renamed = .{ .old = old, .new = new, .trashed = trashed } });
        },
        .delete => |d| {
            const path = try e.gpa.dupe(u8, d.path);
            errdefer e.gpa.free(path);
            try e.flushUnder(d.path, bg);
            const token = try e.fs.trash(e.gpa, d.path);
            done.appendAssumeCapacity(.{ .deleted = .{ .path = path, .token = token } });
        },
    }
}

/// Moves the documents open at `old` or under it to `new`.
fn moveDocs(e: *Engine, old: []const u8, new: []const u8) !void {
    var hs: std.ArrayList(DocHandle) = .empty;
    defer hs.deinit(e.gpa);
    try e.docs.filesUnder(e.gpa, old, &hs);
    for (hs.items) |h| {
        const name = e.docs.name(h).?;
        const rest = name[@min(name.len, old.len)..];
        const to = try std.mem.concat(e.gpa, u8, &.{ new, rest });
        defer e.gpa.free(to);
        try e.docs.rename(h, to);
    }
}

fn revertOne(e: *Engine, inv: *Inverse, bg: *std.ArrayList(DocHandle)) !void {
    switch (inv.*) {
        .text => |*t| {
            const h = try e.docAt(t.path, bg);
            const doc = e.docs.get(h).?;
            if (doc.len() != t.inverse.base_len) return error.Changed;
            var back = try e.editDoc(h, t.inverse.replaces);
            back.deinit();
        },
        .created => |*c| {
            try e.flushUnder(c.path, bg);
            const tok = try e.fs.trash(e.gpa, c.path);
            e.fs.forget(tok);
            e.gpa.free(tok);
            if (c.trashed) |old| {
                try e.fs.restore(old, c.path);
                e.gpa.free(old);
                c.trashed = null;
            }
        },
        .renamed => |*r| {
            try e.flushUnder(r.new, bg);
            try e.fs.move(r.new, r.old);
            try e.moveDocs(r.new, r.old);
            if (r.trashed) |old| {
                try e.fs.restore(old, r.new);
                e.gpa.free(old);
                r.trashed = null;
            }
        },
        .deleted => |*d| {
            try e.fs.restore(d.token, d.path);
        },
    }
}
