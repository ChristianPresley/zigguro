//! zg_scm: the AI-first source control core (epic E09). This module holds the
//! content-addressed object store: object IDs, the object model and its
//! canonical encoding.

const std = @import("std");

/// Object kinds, BLAKE3 object IDs, change IDs.
pub const id = @import("store/id.zig");
/// Trees, changes, chunked blobs and their canonical-form rules.
pub const object = @import("store/object.zig");
/// The canonical binary encoding (and debug JSON).
pub const encode = @import("store/encode.zig");

pub const ObjectId = id.ObjectId;
pub const ChangeId = id.ChangeId;
pub const Kind = id.Kind;
pub const hashObject = id.hashObject;
pub const Tree = object.Tree;
pub const TreeEntry = object.TreeEntry;
pub const Change = object.Change;
pub const Signature = object.Signature;
pub const ChunkedBlob = object.ChunkedBlob;

test {
    std.testing.refAllDecls(@This());
    _ = @import("store/encode_test.zig");
}
