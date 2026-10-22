//! Identifier types shared across zg_workspace (re-exported by the model and
//! the path store).

/// A workspace root (folder) index, stable while the root stays open.
pub const RootId = enum(u16) {
    _,

    /// The id of the root at `index`.
    pub fn of(i: u16) RootId {
        return @enumFromInt(i);
    }

    /// The root's index.
    pub fn index(r: RootId) u16 {
        return @intFromEnum(r);
    }
};

/// A path-store node. `index` addresses a slot; `gen` changes whenever the
/// slot is reused, so a stale id never aliases a new node. Stable across
/// renames.
pub const FileId = packed struct(u64) {
    index: u32,
    gen: u32,

    /// The sentinel "no node" id.
    pub const none: FileId = .{ .index = 0xffff_ffff, .gen = 0 };

    /// Whether two ids name the same node.
    pub fn eql(a: FileId, b: FileId) bool {
        return a.index == b.index and a.gen == b.gen;
    }
};
