//! zg_scm: the AI-first source control core (epic E09). This module holds the
//! content-addressed object store: object IDs, the object model and its
//! canonical encoding, the segmented store, chunked blobs, compaction,
//! GC and fsck; the commit graph (commit index, ancestry); and conflicts
//! (the `Merge` algebra and conflict markers); and the operation log
//! (operations, views, transactions, undo).

const std = @import("std");

/// Object kinds, BLAKE3 object IDs, change IDs.
pub const id = @import("store/id.zig");
/// Trees, changes, chunked blobs and their canonical-form rules.
pub const object = @import("store/object.zig");
/// The canonical binary encoding (and debug JSON).
pub const encode = @import("store/encode.zig");
/// Segment and index file formats.
pub const segment = @import("store/segment.zig");
/// The decode cache.
pub const cache = @import("store/cache.zig");
/// The segmented object store.
pub const store = @import("store/store.zig");
/// Content-defined chunking and streaming blob reads/writes.
pub const chunker = @import("store/chunker.zig");
/// Geometric segment compaction.
pub const compaction = @import("store/compaction.zig");
/// Mark-and-sweep garbage collection.
pub const gc = @import("store/gc.zig");
/// Store integrity checks.
pub const fsck = @import("store/fsck.zig");
/// The commit index segment file format.
pub const index_segment = @import("graph/index_segment.zig");
/// The commit index: positions, parents, generations, change IDs.
pub const index = @import("graph/index.zig");
/// Ancestry queries over the commit index.
pub const ancestry = @import("graph/ancestry.zig");
/// The revset query language.
pub const revset = @import("graph/revset.zig");
/// `Merge(T)`: first-class conflicts and their algebra.
pub const merge = @import("merge/merge.zig");
/// Writing conflicts as marker text.
pub const materialize = @import("merge/materialize.zig");
/// Reading marker text back.
pub const parse_markers = @import("merge/parse_markers.zig");
/// Operation objects and their metadata.
pub const operation = @import("oplog/operation.zig");
/// Views: heads, refs, working copies and lanes at one operation.
pub const view = @import("oplog/view.zig");
/// The lock-free op heads directory.
pub const op_heads = @import("oplog/op_heads.zig");
/// Three-way view merges.
pub const merge_views = @import("oplog/merge_views.zig");
/// The editable repository inside a transaction.
pub const mutable_repo = @import("oplog/mutable_repo.zig");
/// Transactions: write and publish operations.
pub const transaction = @import("oplog/transaction.zig");
/// Loading the repository at an operation.
pub const repo = @import("oplog/repo.zig");
/// Undo, restore, the op log and op abandon.
pub const undo = @import("oplog/undo.zig");
/// Preview (detached) operations and view diffs.
pub const preview = @import("oplog/preview.zig");
/// Adopting a preview onto the current repo.
pub const adopt = @import("oplog/adopt.zig");

pub const ObjectId = id.ObjectId;
pub const ChangeId = id.ChangeId;
pub const Kind = id.Kind;
pub const hashObject = id.hashObject;
pub const Tree = object.Tree;
pub const TreeEntry = object.TreeEntry;
pub const Change = object.Change;
pub const Signature = object.Signature;
pub const ChunkedBlob = object.ChunkedBlob;
pub const Store = store.Store;
pub const WriteBatch = store.WriteBatch;
pub const ObjectRef = store.ObjectRef;
pub const CommitIndex = index.CommitIndex;
pub const Pos = index.Pos;
pub const Merge = merge.Merge;
pub const Repo = repo.Repo;
pub const Transaction = transaction.Transaction;
pub const View = view.View;
pub const RefTarget = view.RefTarget;
pub const Operation = operation.Operation;
pub const OpMeta = operation.OpMeta;
pub const DetachedOp = preview.DetachedOp;

test {
    std.testing.refAllDecls(@This());
    _ = @import("store/encode_test.zig");
    _ = @import("store/store_test.zig");
    _ = @import("store/gc_test.zig");
    _ = @import("graph/index_test.zig");
    _ = @import("graph/ancestry_test.zig");
    _ = @import("graph/revset_test.zig");
    _ = @import("merge/markers_test.zig");
    _ = @import("oplog/oplog_test.zig");
    _ = @import("oplog/oplog_concurrency_test.zig");
    _ = @import("oplog/preview_test.zig");
}
