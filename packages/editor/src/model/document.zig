//! Document: the live, versioned text of one file or buffer. Every mutation
//! goes through `applyChangeSet` on the owner (UI) thread; readers on other
//! threads take `snapshot()`s.

const std = @import("std");
const pt = @import("buffer/piece_tree.zig");
const snapshot_mod = @import("snapshot.zig");
const cs_mod = @import("edit/change_set.zig");
const ChangeLog = @import("change_log.zig").ChangeLog;

const Allocator = std.mem.Allocator;
const PieceTree = pt.PieceTree;
const ChangeSet = cs_mod.ChangeSet;
const Snapshot = snapshot_mod.Snapshot;
const Store = snapshot_mod.Store;

pub const DocId = snapshot_mod.DocId;

/// Who made an edit. Undo grouping, LSP sync and agent review key on it.
pub const EditOrigin = union(enum) {
    /// A user command (E15 command id).
    user: u32,
    undo,
    redo,
    /// An agent session (E10/E12).
    agent: u32,
    reload,
    lsp_edit,
    format,
};

/// Passed to listeners after each mutation. `before` is the previous
/// version's tree, valid only during the callback.
pub const ChangeEvent = struct {
    doc: DocId,
    old_version: u64,
    new_version: u64,
    changes: *const ChangeSet,
    origin: EditOrigin,
    before: PieceTree,
};

/// A synchronous change callback (UI thread).
pub const Listener = struct {
    ctx: *anyopaque,
    onChange: *const fn (ctx: *anyopaque, ev: *const ChangeEvent) void,
};

/// Identifies a subscription.
pub const ListenerId = enum(u32) { _ };

/// A live document.
pub const Document = struct {
    gpa: Allocator,
    id: DocId,
    store: *Store,
    tree: PieceTree,
    version: u64 = 0,
    saved_version: u64 = 0,
    change_log: ChangeLog,
    listeners: std.ArrayList(struct { id: ListenerId, l: Listener }) = .empty,
    next_listener: u32 = 0,
    in_listener: bool = false,

    /// A document holding a copy of `bytes`, at version 0.
    pub fn initBytes(gpa: Allocator, id: DocId, bytes: []const u8) Allocator.Error!*Document {
        const store = try Store.create(gpa, try gpa.dupe(u8, bytes));
        errdefer store.release();
        const tree = try PieceTree.fromOriginal(&store.pool, store.bt);
        const d = try gpa.create(Document);
        d.* = .{ .gpa = gpa, .id = id, .store = store, .tree = tree, .change_log = .init(gpa, 0) };
        return d;
    }

    /// Frees the document. Snapshots taken earlier stay valid.
    pub fn deinit(d: *Document) void {
        d.tree.deinit(&d.store.pool);
        d.change_log.deinit();
        d.listeners.deinit(d.gpa);
        d.store.pool.drainGarbage();
        d.store.release();
        d.gpa.destroy(d);
    }

    /// An immutable snapshot of the current version. O(1), no allocation.
    pub fn snapshot(d: *Document) Snapshot {
        d.store.retain();
        return .{ .tree = d.tree.clone(), .version = d.version, .doc_id = d.id, .store = d.store };
    }

    /// Length in bytes.
    pub fn len(d: *const Document) u64 {
        return d.tree.len();
    }

    /// Whether the text differs from the last saved version.
    pub fn isDirty(d: *const Document) bool {
        return d.version != d.saved_version;
    }

    /// The only mutation entry point: applies `cs` (against the current
    /// version), records it in the change log, bumps the version and
    /// notifies listeners in subscription order. Listeners must not edit
    /// re-entrantly; they post a command instead.
    pub fn applyChangeSet(d: *Document, cs: *const ChangeSet, origin: EditOrigin) !void {
        std.debug.assert(!d.in_listener);
        if (cs.base_len != d.tree.len()) return error.VersionMismatch;
        var logged = try cs.clone(d.gpa);
        errdefer logged.deinit();
        var next = try cs.apply(d.tree, &d.store.pool);
        errdefer next.deinit(&d.store.pool);
        try d.change_log.push(d.version + 1, logged);
        var before = d.tree;
        d.tree = next;
        d.version += 1;
        const ev: ChangeEvent = .{ .doc = d.id, .old_version = d.version - 1, .new_version = d.version, .changes = cs, .origin = origin, .before = before };
        d.in_listener = true;
        for (d.listeners.items) |entry| entry.l.onChange(entry.l.ctx, &ev);
        d.in_listener = false;
        before.deinit(&d.store.pool);
    }

    /// Maps `range` computed against `from_version` onto the current
    /// version, or null when that version was evicted from the change log
    /// or the (non-empty) range was deleted.
    pub fn mapForward(d: *const Document, from_version: u64, range: cs_mod.Range, bias: cs_mod.Bias) ?cs_mod.Range {
        if (from_version == d.version) return range;
        const s = d.change_log.mapPos(from_version, range.start, bias) orelse return null;
        const e = d.change_log.mapPos(from_version, range.end, bias) orelse return null;
        if (range.end > range.start and e.pos <= s.pos) return null;
        return .{ .start = s.pos, .end = e.pos };
    }

    /// Registers a listener; called after every mutation, in order.
    pub fn subscribe(d: *Document, l: Listener) Allocator.Error!ListenerId {
        const id: ListenerId = @enumFromInt(d.next_listener);
        d.next_listener += 1;
        try d.listeners.append(d.gpa, .{ .id = id, .l = l });
        return id;
    }

    /// Removes a listener.
    pub fn unsubscribe(d: *Document, id: ListenerId) void {
        for (d.listeners.items, 0..) |e, i| if (e.id == id) {
            _ = d.listeners.orderedRemove(i);
            return;
        };
    }

    /// Frees nodes released on other threads; call once per frame.
    pub fn endFrame(d: *Document) void {
        d.store.pool.drainGarbage();
    }
};
