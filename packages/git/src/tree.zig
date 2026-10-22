//! Tree objects: a zero-copy entry iterator, git's entry ordering, and
//! serialization with path hardening (no `.`, `..`, `.git` or its NTFS and
//! HFS+ aliases).

const std = @import("std");
const oid_mod = @import("oid.zig");
const Oid = oid_mod.Oid;
const ObjectFormat = oid_mod.ObjectFormat;

/// Mode of a regular file.
pub const mode_file: u32 = 0o100644;
/// Mode of an executable file.
pub const mode_exec: u32 = 0o100755;
/// Mode of a symbolic link.
pub const mode_symlink: u32 = 0o120000;
/// Mode of a subtree.
pub const mode_tree: u32 = 0o40000;
/// Mode of a submodule commit (gitlink).
pub const mode_gitlink: u32 = 0o160000;

/// One tree entry. `name` borrows from the tree data when iterated.
pub const TreeEntry = struct {
    /// File mode (see the `mode_*` constants).
    mode: u32,
    /// Path component.
    name: []const u8,
    /// Object ID of the blob, tree or commit.
    oid: Oid,

    /// Whether the entry is a subtree.
    pub fn isTree(e: TreeEntry) bool {
        return e.mode == mode_tree;
    }
};

/// Errors from parsing and validation.
pub const Error = error{ CorruptObject, DangerousPath, InvalidMode, UnsortedTree };

/// Zero-copy iterator over a tree object's entries.
pub const TreeIterator = struct {
    data: []const u8,
    format: ObjectFormat,
    pos: usize = 0,

    /// Next entry, null at the end, or `error.CorruptObject`.
    pub fn next(it: *TreeIterator) error{CorruptObject}!?TreeEntry {
        const d = it.data;
        if (it.pos >= d.len) return null;
        const sp = std.mem.indexOfScalarPos(u8, d, it.pos, ' ') orelse return error.CorruptObject;
        const mode_text = d[it.pos..sp];
        if (mode_text.len == 0 or mode_text.len > 7) return error.CorruptObject;
        const mode = std.fmt.parseInt(u32, mode_text, 8) catch return error.CorruptObject;
        const nul = std.mem.indexOfScalarPos(u8, d, sp + 1, 0) orelse return error.CorruptObject;
        const name = d[sp + 1 .. nul];
        if (name.len == 0) return error.CorruptObject;
        const hl = it.format.len();
        if (nul + 1 + hl > d.len) return error.CorruptObject;
        it.pos = nul + 1 + hl;
        return .{ .mode = mode, .name = name, .oid = .fromBytes(it.format, d[nul + 1 ..][0..hl]) };
    }
};

/// Iterates a tree object's entries without copying.
pub fn parseTree(fmt: ObjectFormat, data: []const u8) TreeIterator {
    return .{ .data = data, .format = fmt };
}

/// Git's tree order: names compare bytewise, with subtrees compared as if
/// their name ended in '/'.
pub fn entryOrder(a: TreeEntry, b: TreeEntry) std.math.Order {
    return nameOrder(a.name, a.isTree(), b.name, b.isTree());
}

/// `entryOrder` on bare names and tree flags.
pub fn nameOrder(a: []const u8, a_tree: bool, b: []const u8, b_tree: bool) std.math.Order {
    const n = @min(a.len, b.len);
    switch (std.mem.order(u8, a[0..n], b[0..n])) {
        .eq => {},
        else => |o| return o,
    }
    const ca: u8 = if (a.len > n) a[n] else if (a_tree) '/' else 0;
    const cb: u8 = if (b.len > n) b[n] else if (b_tree) '/' else 0;
    return std.math.order(ca, cb);
}

fn lessThan(_: void, a: TreeEntry, b: TreeEntry) bool {
    return entryOrder(a, b) == .lt;
}

/// Sorts entries into git's tree order.
pub fn sortEntries(entries: []TreeEntry) void {
    std.mem.sort(TreeEntry, entries, {}, lessThan);
}

/// Unicode code points HFS+ ignores when comparing names (git's
/// `next_hfs_char`).
fn hfsIgnorable(cp: u21) bool {
    return switch (cp) {
        0x200c...0x200f, 0x202a...0x202e, 0x206a...0x206f, 0xfeff => true,
        else => false,
    };
}

/// True when `name` would be ".git" on HFS+ (case-insensitive, ignorable
/// code points removed).
fn isHfsDotGit(name: []const u8) bool {
    var view = std.unicode.Utf8View.init(name) catch return false;
    var cps = view.iterator();
    const want = ".git";
    var i: usize = 0;
    while (cps.nextCodepoint()) |cp| {
        if (hfsIgnorable(cp)) continue;
        if (i >= want.len or cp > 0x7f) return false;
        if (std.ascii.toLower(@intCast(cp)) != want[i]) return false;
        i += 1;
    }
    return i == want.len;
}

/// True when `name` would be ".git" or its 8.3 short name on NTFS: trailing
/// spaces and dots are dropped, and ":" starts an alternate stream.
fn isNtfsDotGit(name: []const u8) bool {
    const end = std.mem.indexOfScalar(u8, name, ':') orelse name.len;
    const base = std.mem.trimEnd(u8, name[0..end], ". ");
    return std.ascii.eqlIgnoreCase(base, ".git") or std.ascii.eqlIgnoreCase(base, "git~1");
}

/// Rejects names git refuses to write or check out.
pub fn validateEntryName(name: []const u8) error{DangerousPath}!void {
    if (name.len == 0) return error.DangerousPath;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.DangerousPath;
    for (name) |c| if (c == '/' or c == 0 or c == '\\') return error.DangerousPath;
    if (std.ascii.eqlIgnoreCase(name, ".git")) return error.DangerousPath;
    if (isNtfsDotGit(name) or isHfsDotGit(name)) return error.DangerousPath;
}

/// Whether `mode` is one git writes.
pub fn validMode(mode: u32) bool {
    return switch (mode) {
        mode_file, mode_exec, mode_symlink, mode_tree, mode_gitlink => true,
        else => false,
    };
}

/// Serializes entries, which must already be in git order (`sortEntries`)
/// with unique names, valid modes and safe names.
pub fn serializeTree(entries: []const TreeEntry, w: *std.Io.Writer) (Error || std.Io.Writer.Error)!void {
    for (entries, 0..) |e, i| {
        try validateEntryName(e.name);
        if (!validMode(e.mode)) return error.InvalidMode;
        if (i > 0 and entryOrder(entries[i - 1], e) != .lt) return error.UnsortedTree;
        if (i > 0 and std.mem.eql(u8, entries[i - 1].name, e.name)) return error.UnsortedTree;
        try w.print("{o} ", .{e.mode});
        try w.writeAll(e.name);
        try w.writeByte(0);
        try w.writeAll(e.oid.slice());
    }
}

test "tree: ordering and validation (dangerous names rejected)" {
    const t = std.testing;
    const z = Oid.zero(.sha1);
    var es = [_]TreeEntry{
        .{ .mode = mode_file, .name = "foo.c", .oid = z },
        .{ .mode = mode_tree, .name = "foo", .oid = z },
        .{ .mode = mode_file, .name = "foo-bar", .oid = z },
        .{ .mode = mode_file, .name = "Foo", .oid = z },
    };
    sortEntries(&es);
    // "foo/" sorts after "foo.c" and "foo-bar" because '/' > '.' > '-'.
    try t.expectEqualStrings("Foo", es[0].name);
    try t.expectEqualStrings("foo-bar", es[1].name);
    try t.expectEqualStrings("foo.c", es[2].name);
    try t.expectEqualStrings("foo", es[3].name);

    var aw: std.Io.Writer.Allocating = .init(t.allocator);
    defer aw.deinit();
    try serializeTree(&es, &aw.writer);
    var it = parseTree(.sha1, aw.written());
    var n: usize = 0;
    while (try it.next()) |e| : (n += 1) {
        try t.expectEqualStrings(es[n].name, e.name);
        try t.expectEqual(es[n].mode, e.mode);
    }
    try t.expectEqual(@as(usize, 4), n);

    for ([_][]const u8{ ".", "..", ".git", ".GIT", "git~1", ".git.", ".git ", ".git::$INDEX_ALLOCATION", ".g\u{200c}it", ".Gi\u{feff}t", "a/b", "a\\b", "" }) |bad| {
        try t.expectError(error.DangerousPath, validateEntryName(bad));
    }
    try validateEntryName(".gitignore");
    try validateEntryName("git~2");
    try t.expectError(error.UnsortedTree, serializeTree(&.{ es[1], es[0] }, &aw.writer));
    try t.expectError(error.InvalidMode, serializeTree(&.{.{ .mode = 0o100664, .name = "x", .oid = z }}, &aw.writer));
}

test "tree: corrupt data" {
    const t = std.testing;
    var it = parseTree(.sha1, "100644 a\x00short");
    try t.expectError(error.CorruptObject, it.next());
    var it2 = parseTree(.sha1, "1z0644 a\x00" ++ "x" ** 20);
    try t.expectError(error.CorruptObject, it2.next());
}
