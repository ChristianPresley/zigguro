//! The structured zg-scm objects and their canonical-form rules.
//!
//! Blobs and text are raw bytes. Trees, changes and chunked blobs are the
//! structs below, stored in the encoding of encode.zig. Every struct here
//! has a `validate` that the encoder and decoder both run, so one value has
//! exactly one encoding and therefore one ID.

const std = @import("std");
const id_mod = @import("id.zig");
const ObjectId = id_mod.ObjectId;
const ChangeId = id_mod.ChangeId;
const Kind = id_mod.Kind;

/// Why a value is not canonical.
pub const ValidateError = error{
    InvalidName,
    UnsortedEntries,
    DuplicateName,
    UnsortedExtra,
    DuplicateExtra,
    EmptyExtraKey,
    InvalidTreeTerms,
    InvalidChunks,
    /// A view's lists are unsorted or repeat a key, or a ref target has an
    /// even number of terms.
    InvalidView,
    /// An operation's parents repeat.
    InvalidOperation,
};

/// What a tree entry points at.
pub const EntryKind = enum(u8) {
    file,
    executable,
    symlink,
    tree,
    gitlink,
    conflict_marker_file,
};

/// One name in a tree.
pub const TreeEntry = struct {
    name: []const u8,
    kind: EntryKind,
    id: ObjectId,
};

/// Whether `name` may appear in a tree: non-empty, no '/' or NUL, and not
/// ".", ".." or ".zg". Names that Windows cannot check out are allowed here.
pub fn validName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| if (c == '/' or c == 0) return false;
    if (name[0] == '.' and name.len <= 3) {
        for ([_][]const u8{ ".", "..", ".zg" }) |bad| if (std.mem.eql(u8, name, bad)) return false;
    }
    return true;
}

/// Bytewise order of `a[0..n]` and `b[0..n]`, eight bytes at a time.
fn orderPrefix(a: []const u8, b: []const u8, n: usize) std.math.Order {
    var i: usize = 0;
    while (i + 8 <= n) : (i += 8) {
        const x = std.mem.readInt(u64, a[i..][0..8], .big);
        const y = std.mem.readInt(u64, b[i..][0..8], .big);
        if (x != y) return std.math.order(x, y);
    }
    while (i < n) : (i += 1) {
        if (a[i] != b[i]) return std.math.order(a[i], b[i]);
    }
    return .eq;
}

/// git's tree order: names compare bytewise, with directories compared as
/// if they ended in '/'.
pub fn entryOrder(a_name: []const u8, a_dir: bool, b_name: []const u8, b_dir: bool) std.math.Order {
    const n = @min(a_name.len, b_name.len);
    switch (orderPrefix(a_name, b_name, n)) {
        .eq => {},
        else => |o| return o,
    }
    const ac: u16 = if (a_name.len > n) a_name[n] else if (a_dir) '/' else 0x100;
    const bc: u16 = if (b_name.len > n) b_name[n] else if (b_dir) '/' else 0x100;
    // 0x100 marks "ended": an exhausted non-dir name sorts first.
    const ak: u16 = if (ac == 0x100) 0 else ac + 1;
    const bk: u16 = if (bc == 0x100) 0 else bc + 1;
    return std.math.order(ak, bk);
}

/// A directory listing, sorted in git's tree order.
pub const Tree = struct {
    entries: []const TreeEntry,

    pub const kind: Kind = .tree;

    /// Sorts `entries` in place into tree order.
    pub fn sort(entries: []TreeEntry) void {
        std.mem.sort(TreeEntry, entries, {}, struct {
            fn lt(_: void, a: TreeEntry, b: TreeEntry) bool {
                return entryOrder(a.name, a.kind == .tree, b.name, b.kind == .tree) == .lt;
            }
        }.lt);
    }

    /// Index of `name` as a non-directory entry, by binary search.
    fn findPlain(entries: []const TreeEntry, name: []const u8) ?usize {
        var lo: usize = 0;
        var hi: usize = entries.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const e = entries[mid];
            switch (entryOrder(e.name, e.kind == .tree, name, false)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return mid,
            }
        }
        return null;
    }

    /// The entry named `name`, if any.
    pub fn find(self: Tree, name: []const u8) ?TreeEntry {
        if (findPlain(self.entries, name)) |i| return self.entries[i];
        var lo: usize = 0;
        var hi: usize = self.entries.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const e = self.entries[mid];
            switch (entryOrder(e.name, e.kind == .tree, name, true)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return e,
            }
        }
        return null;
    }

    /// Entries strictly increasing in tree order, valid unique names.
    pub fn validate(self: Tree) ValidateError!void {
        for (self.entries, 0..) |e, i| {
            if (!validName(e.name)) return error.InvalidName;
            if (i > 0) {
                const p = self.entries[i - 1];
                if (entryOrder(p.name, p.kind == .tree, e.name, e.kind == .tree) != .lt) return error.UnsortedEntries;
            }
        }
        // Sorting alone does not catch a directory "a" and a file "a": they
        // compare as "a/" and "a", possibly with "a.b" between them.
        for (self.entries) |e| {
            if (e.kind == .tree and findPlain(self.entries, e.name) != null) return error.DuplicateName;
        }
    }
};

/// Who made a change, and when.
pub const Signature = struct {
    name: []const u8,
    email: []const u8,
    /// Milliseconds since the Unix epoch.
    time_ms: i64,
    /// Minutes east of UTC.
    tz_offset_min: i16,
};

/// An unknown-to-this-version key/value pair; preserved as is.
pub const Extra = struct {
    key: []const u8,
    value: []const u8,
};

/// Keys non-empty, strictly increasing.
pub fn validateExtra(extra: []const Extra) ValidateError!void {
    for (extra, 0..) |e, i| {
        if (e.key.len == 0) return error.EmptyExtraKey;
        if (i > 0) switch (std.mem.order(u8, extra[i - 1].key, e.key)) {
            .lt => {},
            .eq => return error.DuplicateExtra,
            .gt => return error.UnsortedExtra,
        };
    }
}

/// Sorts `extra` by key in place.
pub fn sortExtra(extra: []Extra) void {
    std.mem.sort(Extra, extra, {}, struct {
        fn lt(_: void, a: Extra, b: Extra) bool {
            return std.mem.order(u8, a.key, b.key) == .lt;
        }
    }.lt);
}

/// A cryptographic signature over a change's encoding without `sig`
/// (produced and checked by F09).
pub const SignatureBlock = struct {
    /// Signature scheme, e.g. "sshsig".
    format: []const u8,
    data: []const u8,
};

/// A commit in the change graph.
pub const Change = struct {
    /// Parent commit IDs; empty only for the root change.
    parents: []const ObjectId,
    /// Odd-length merge terms: adds at even indexes, removes at odd ones.
    /// Length 1 means the tree is resolved.
    tree_terms: []const ObjectId,
    change_id: ChangeId,
    /// Commits this one rewrites (amend, rebase, split, squash).
    predecessors: []const ObjectId,
    author: Signature,
    committer: Signature,
    description: []const u8,
    /// ProvenanceManifest (F05).
    provenance: ?ObjectId,
    /// Sorted by key; unknown keys are preserved.
    extra: []const Extra,
    sig: ?SignatureBlock,

    pub const kind: Kind = .change;

    /// The resolved tree, or null while the change has conflicts.
    pub fn tree(self: Change) ?ObjectId {
        return if (self.tree_terms.len == 1) self.tree_terms[0] else null;
    }

    pub fn validate(self: Change) ValidateError!void {
        if (self.tree_terms.len % 2 != 1) return error.InvalidTreeTerms;
        try validateExtra(self.extra);
    }
};

/// One piece of a chunked blob.
pub const Chunk = struct {
    /// A `.blob` object holding the chunk bytes.
    id: ObjectId,
    size: u32,
};

/// A large blob stored as content-defined chunks (T03).
pub const ChunkedBlob = struct {
    total_size: u64,
    chunks: []const Chunk,

    pub const kind: Kind = .chunked_blob;

    /// At least one chunk, none empty, sizes summing to `total_size`.
    pub fn validate(self: ChunkedBlob) ValidateError!void {
        if (self.chunks.len == 0) return error.InvalidChunks;
        var sum: u64 = 0;
        for (self.chunks) |c| {
            if (c.size == 0) return error.InvalidChunks;
            sum += c.size;
        }
        if (sum != self.total_size) return error.InvalidChunks;
    }
};

test "tree: git ordering and lookup" {
    const t = std.testing;
    const z = ObjectId.zero;
    var entries = [_]TreeEntry{
        .{ .name = "a", .kind = .tree, .id = z },
        .{ .name = "a.b", .kind = .file, .id = z },
        .{ .name = "a-", .kind = .file, .id = z },
        .{ .name = "ab", .kind = .file, .id = z },
        .{ .name = "A", .kind = .file, .id = z },
    };
    Tree.sort(&entries);
    const want = [_][]const u8{ "A", "a-", "a.b", "a", "ab" };
    for (want, entries) |w, e| try t.expectEqualStrings(w, e.name);
    const tr: Tree = .{ .entries = &entries };
    try tr.validate();
    try t.expectEqual(EntryKind.tree, tr.find("a").?.kind);
    try t.expect(tr.find("ab") != null);
    try t.expect(tr.find("b") == null);
}

test "tree: rejects bad names, order and duplicates" {
    const t = std.testing;
    const z = ObjectId.zero;
    for ([_][]const u8{ "", ".", "..", ".zg", "a/b", "a\x00" }) |n| {
        const tr: Tree = .{ .entries = &.{.{ .name = n, .kind = .file, .id = z }} };
        try t.expectError(error.InvalidName, tr.validate());
    }
    const unsorted: Tree = .{ .entries = &.{ .{ .name = "b", .kind = .file, .id = z }, .{ .name = "a", .kind = .file, .id = z } } };
    try t.expectError(error.UnsortedEntries, unsorted.validate());
    const dup: Tree = .{ .entries = &.{ .{ .name = "a", .kind = .file, .id = z }, .{ .name = "a", .kind = .executable, .id = z } } };
    try t.expectError(error.UnsortedEntries, dup.validate());
    const dir_dup: Tree = .{ .entries = &.{
        .{ .name = "a", .kind = .file, .id = z },
        .{ .name = "a.b", .kind = .file, .id = z },
        .{ .name = "a", .kind = .tree, .id = z },
    } };
    try t.expectError(error.DuplicateName, dir_dup.validate());
    try t.expect(validName(".git") and validName("con") and validName("a:b"));
}

test "change: tree terms and extra rules" {
    const t = std.testing;
    const sig: Signature = .{ .name = "n", .email = "e", .time_ms = 0, .tz_offset_min = 0 };
    var c: Change = .{
        .parents = &.{},
        .tree_terms = &.{ ObjectId.zero, ObjectId.zero },
        .change_id = .{ .bytes = @splat(0) },
        .predecessors = &.{},
        .author = sig,
        .committer = sig,
        .description = "",
        .provenance = null,
        .extra = &.{},
        .sig = null,
    };
    try t.expectError(error.InvalidTreeTerms, c.validate());
    c.tree_terms = &.{};
    try t.expectError(error.InvalidTreeTerms, c.validate());
    c.tree_terms = &.{ObjectId.zero};
    try c.validate();
    try t.expect(c.tree() != null);
    c.extra = &.{ .{ .key = "b", .value = "" }, .{ .key = "a", .value = "" } };
    try t.expectError(error.UnsortedExtra, c.validate());
    c.extra = &.{ .{ .key = "a", .value = "" }, .{ .key = "a", .value = "" } };
    try t.expectError(error.DuplicateExtra, c.validate());
    c.extra = &.{.{ .key = "", .value = "" }};
    try t.expectError(error.EmptyExtraKey, c.validate());
}
