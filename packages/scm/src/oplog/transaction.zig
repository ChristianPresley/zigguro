//! Transactions: edit a `MutableRepo` on top of one operation, then write
//! the new view and operation and publish it as an op head. Commit is
//! split into `writeOp` (store only) and `publishHead` (the op heads
//! directory) so preview operations (F03.S02.T02) can write an operation
//! without publishing it.
//!
//! No locks: two transactions on the same operation both publish, and the
//! next load merges their views.

const std = @import("std");
const id_mod = @import("../store/id.zig");
const enc = @import("../store/encode.zig");
const store_mod = @import("../store/store.zig");
const op_mod = @import("operation.zig");
const view_mod = @import("view.zig");
const op_heads = @import("op_heads.zig");
const repo_mod = @import("repo.zig");
const mutable_mod = @import("mutable_repo.zig");
const ObjectId = id_mod.ObjectId;
const Operation = op_mod.Operation;
const OpMeta = op_mod.OpMeta;
const View = view_mod.View;
const Repo = repo_mod.Repo;
const MutableRepo = mutable_mod.MutableRepo;
const Allocator = std.mem.Allocator;

pub const Transaction = struct {
    gpa: Allocator,
    repo: *Repo,
    arena_state: std.heap.ArenaAllocator,
    meta: OpMeta,
    /// Pointed to by `mut.batch`, so the transaction stays on the heap.
    batch: store_mod.WriteBatch,
    mut: MutableRepo,
    /// The operations the new one follows (the loaded operation, plus any
    /// added with `addParent`).
    parents: std.ArrayList(ObjectId) = .empty,
    /// Set by `writeOp`.
    written: ?ObjectId = null,

    /// Starts a transaction on `r` (use `Repo.startTransaction`). A zero
    /// `meta.start_ms` is set to now.
    pub fn begin(r: *Repo, meta: OpMeta) !*Transaction {
        const gpa = r.gpa;
        const t = try gpa.create(Transaction);
        errdefer gpa.destroy(t);
        t.* = .{
            .gpa = gpa,
            .repo = r,
            .arena_state = .init(gpa),
            .meta = meta,
            .batch = r.store.batch(),
            .mut = undefined,
        };
        errdefer t.arena_state.deinit();
        errdefer t.batch.abort();
        if (t.meta.start_ms == 0) t.meta.start_ms = repo_mod.now(r.io);
        var vb = try view_mod.ViewBuilder.fromView(gpa, r.view().*);
        errdefer vb.deinit();
        t.mut = .{ .gpa = gpa, .arena = t.arena_state.allocator(), .batch = &t.batch, .view = vb };
        try t.parents.append(gpa, r.op());
        return t;
    }

    pub fn mutRepo(t: *Transaction) *MutableRepo {
        return &t.mut;
    }

    /// Owns strings and ref targets passed to the `MutableRepo`.
    pub fn arena(t: *Transaction) Allocator {
        return t.arena_state.allocator();
    }

    /// Adds another parent operation (op merges and undo bookkeeping).
    pub fn addParent(t: *Transaction, id: ObjectId) !void {
        for (t.parents.items) |p| if (p.eql(id)) return;
        try t.parents.append(t.gpa, id);
    }

    /// Replaces the whole view (restore, undo). Its slices must outlive
    /// the transaction.
    pub fn setView(t: *Transaction, v: View) !void {
        const vb = try view_mod.ViewBuilder.fromView(t.gpa, v);
        t.mut.view.deinit();
        t.mut.view = vb;
    }

    /// Writes the changes, the view and the operation to the store and
    /// returns the operation's ID. Nothing is published.
    pub fn writeOp(t: *Transaction) !ObjectId {
        if (t.written) |id| return id;
        const r = t.repo;
        const gpa = t.gpa;
        const a = t.arena();
        // Changes first: the index reads them to normalize the heads.
        try t.batch.commit();
        var v = try t.mut.view.toView(a);
        if (r.opts.index) |ix| v = try repo_mod.normalizeHeads(a, ix, v);
        v.validate() catch return error.InvalidView;

        var end = repo_mod.now(r.io);
        end = @max(end, t.meta.start_ms);
        var g: repo_mod.OpGraph = .init(gpa, r.store);
        defer g.deinit();
        for (t.parents.items) |p| end = @max(end, (try g.get(p)).end_ms);
        t.meta.end_ms = end;

        var b = r.store.batch();
        defer b.abort();
        const view_bytes = try enc.encodeAlloc(gpa, View, v);
        defer gpa.free(view_bytes);
        const view_id = try b.put(.view, view_bytes);
        const op_bytes = try enc.encodeAlloc(gpa, Operation, .{ .parents = t.parents.items, .view = view_id, .meta = t.meta });
        defer gpa.free(op_bytes);
        const op_id = try b.put(.operation, op_bytes);
        try b.commit();
        t.written = op_id;
        return op_id;
    }

    /// Makes `id` an op head in place of the transaction's parents.
    pub fn publishHead(t: *Transaction, id: ObjectId) !void {
        try op_heads.publish(t.repo.io, t.repo.heads_dir, id, t.parents.items);
    }

    /// Writes and publishes the operation, returning the repo at it. The
    /// transaction is finished either way; the old `Repo` stays valid.
    pub fn commit(t: *Transaction) !*Repo {
        defer t.discard();
        const id = try t.writeOp();
        try t.publishHead(id);
        return t.repo.reopen(id, false);
    }

    /// Drops the transaction. Changes already written by `writeOp` stay in
    /// the store until GC.
    pub fn discard(t: *Transaction) void {
        const gpa = t.gpa;
        t.batch.abort();
        t.mut.deinit();
        t.parents.deinit(gpa);
        t.arena_state.deinit();
        gpa.destroy(t);
    }
};
