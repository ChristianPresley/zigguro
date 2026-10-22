//! Snapshots: immutable versions of a document that cross threads.
//!
//! A `Snapshot` holds a reference to its tree's root and to the document's
//! `Store` (node pool plus buffer table), so it stays readable after the
//! document closes; the store is freed by whichever holder drops the last
//! reference. Taking a snapshot is two atomic increments and allocates
//! nothing.
//!
//! Memory ordering: increments are `.monotonic` (a reference is only ever
//! copied from one already held); decrements are `.release`, and the thread
//! that drops the last reference loads with `.acquire` before freeing.

const std = @import("std");
const pt = @import("buffer/piece_tree.zig");
const buffers = @import("buffer/buffers.zig");
const NodePool = @import("buffer/node_pool.zig").NodePool;

const Allocator = std.mem.Allocator;
const PieceTree = pt.PieceTree;

/// Identifies a document within the process.
pub const DocId = enum(u32) { _ };

/// The node pool and buffers of one document, shared by the document and
/// every snapshot of it.
pub const Store = struct {
    rc: std.atomic.Value(u32) = .init(1),
    gpa: Allocator,
    pool: NodePool,
    bt: *buffers.BufferTable,

    /// A store over `original`, which it takes ownership of (freed with
    /// `gpa`).
    pub fn create(gpa: Allocator, original: []const u8) Allocator.Error!*Store {
        const s = try gpa.create(Store);
        errdefer gpa.destroy(s);
        s.* = .{ .gpa = gpa, .pool = .init(gpa), .bt = try buffers.BufferTable.create(gpa, original, true) };
        return s;
    }

    /// Adds a reference.
    pub fn retain(s: *Store) void {
        _ = s.rc.fetchAdd(1, .monotonic);
    }

    /// Drops a reference; the last one frees the pool and buffers. Every
    /// tree from this store must be released before its holder's
    /// reference.
    pub fn release(s: *Store) void {
        if (s.rc.fetchSub(1, .release) != 1) return;
        _ = s.rc.load(.acquire);
        s.pool.deinit();
        s.bt.release();
        s.gpa.destroy(s);
    }
};

/// An immutable version of a document. Copying the struct does not add a
/// reference; use `retain`.
pub const Snapshot = struct {
    tree: PieceTree,
    version: u64,
    doc_id: DocId,
    store: *Store,

    /// Another reference to the same version (any thread).
    pub fn retain(s: *const Snapshot) Snapshot {
        s.store.retain();
        return .{ .tree = s.tree.clone(), .version = s.version, .doc_id = s.doc_id, .store = s.store };
    }

    /// Drops this reference (any thread; frees are deferred to the
    /// document's owner thread while it lives).
    pub fn release(s: *Snapshot) void {
        s.tree.deinit(&s.store.pool);
        s.store.release();
        s.* = undefined;
    }

    /// Length in bytes.
    pub fn len(s: *const Snapshot) u64 {
        return s.tree.len();
    }
};
