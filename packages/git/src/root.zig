//! zg_git: a from-scratch implementation of git's on-disk formats (E09.F07)
//! for colocation with existing repositories. Pure Zig std; no git binary.

const std = @import("std");

/// Object IDs and hash functions.
pub const oid = @import("oid.zig");
/// Object types, headers and hashing.
pub const object = @import("object.zig");
/// Commit parser and serializer.
pub const commit = @import("commit.zig");
/// Tree iterator, ordering and validation.
pub const tree = @import("tree.zig");
/// Annotated tag parser and serializer.
pub const tag = @import("tag.zig");
/// zlib inflate helpers with trailer verification.
pub const zlib = @import("zlib.zig");
/// Loose object read and write.
pub const loose = @import("loose.zig");
/// Whole-file read-only maps.
pub const mapped = @import("mapped.zig");
/// Pack index v2.
pub const idx = @import("pack/idx.zig");
/// Packfile reading.
pub const pack = @import("pack/pack.zig");
/// Delta encoding and application.
pub const delta = @import("pack/delta.zig");
/// Delta-base cache.
pub const cache = @import("pack/cache.zig");
/// Reverse indexes.
pub const rev = @import("pack/rev.zig");
/// Multi-pack-index reader.
pub const midx = @import("pack/midx.zig");
/// Delta compression.
pub const deltify = @import("pack/deltify.zig");
/// Pack writer.
pub const pack_writer = @import("pack/writer.zig");
/// Pack indexer (index-pack).
pub const indexer = @import("pack/indexer.zig");
/// commit-graph reader.
pub const commit_graph = @import("commit_graph.zig");
/// The object database.
pub const odb = @import("odb.zig");

/// See `oid.Oid`.
pub const Oid = oid.Oid;
/// See `oid.ObjectFormat`.
pub const ObjectFormat = oid.ObjectFormat;
/// See `object.ObjectType`.
pub const ObjectType = object.ObjectType;
/// See `object.Object`.
pub const Object = object.Object;
/// See `odb.Odb`.
pub const Odb = odb.Odb;
/// See `object.hashObject`.
pub const hashObject = object.hashObject;

test {
    std.testing.refAllDecls(@This());
    _ = @import("object_test.zig");
}
