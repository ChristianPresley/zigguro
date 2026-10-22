//! zg_scm: the AI-first source control core (epic E09). This module holds the
//! content-addressed object store: object IDs, the object model and its
//! canonical encoding, the segmented store, chunked blobs, compaction,
//! GC and fsck; the commit graph (commit index, ancestry); and conflicts
//! (the `Merge` algebra and conflict markers).

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
/// `Merge(T)`: first-class conflicts and their algebra.
pub const merge = @import("merge/merge.zig");
/// Writing conflicts as marker text.
pub const materialize = @import("merge/materialize.zig");
/// Reading marker text back.
pub const parse_markers = @import("merge/parse_markers.zig");

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

test {
    std.testing.refAllDecls(@This());
    _ = @import("store/encode_test.zig");
    _ = @import("store/store_test.zig");
    _ = @import("store/gc_test.zig");
    _ = @import("graph/index_test.zig");
    _ = @import("graph/ancestry_test.zig");
    _ = @import("merge/markers_test.zig");
}
