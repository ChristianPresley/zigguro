//! The tag hierarchy (E08.F06.S01.T02): a trie over `/`-separated,
//! case-folded segments. A node counts the notes that carry its tag or a
//! tag nested under it, each note once however often it repeats a tag.
//! Display casing is the first seen, in note order.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const TagNode = struct {
    /// The segment, as first written.
    name: []const u8,
    /// The full tag, as first written (`""` at the root).
    full: []const u8,
    /// The folded full tag.
    key: []const u8,
    count: u32 = 0,
    children: []const *TagNode = &.{},

    /// The node for folded `key` (`a/b`), or null.
    pub fn find(t: *const TagNode, key: []const u8) ?*const TagNode {
        if (key.len == 0) return t;
        var node = t;
        var start: usize = 0;
        while (start <= key.len) {
            const end = std.mem.indexOfScalarPos(u8, key, start, '/') orelse key.len;
            const prefix = key[0..end];
            node = for (node.children) |c| {
                if (std.mem.eql(u8, c.key, prefix)) break c;
            } else return null;
            start = end + 1;
        }
        return node;
    }
};

/// Builds the tree in `arena` from each note's (folded key, display)
/// tags, notes in a stable order.
pub const Builder = struct {
    arena: Allocator,
    root: *Mut,
    /// Prefix keys already counted for the current note.
    seen: std.StringHashMapUnmanaged(void) = .empty,

    const Mut = struct {
        name: []const u8,
        full: []const u8,
        key: []const u8,
        count: u32 = 0,
        children: std.ArrayList(*Mut) = .empty,
        index: std.StringHashMapUnmanaged(*Mut) = .empty,
    };

    pub fn init(arena: Allocator) !Builder {
        const root = try arena.create(Mut);
        root.* = .{ .name = "", .full = "", .key = "" };
        return .{ .arena = arena, .root = root };
    }

    pub fn beginNote(b: *Builder) void {
        b.seen.clearRetainingCapacity();
    }

    pub fn add(b: *Builder, key: []const u8, display: []const u8) !void {
        var node = b.root;
        var start: usize = 0;
        var dstart: usize = 0;
        while (start <= key.len) {
            const end = std.mem.indexOfScalarPos(u8, key, start, '/') orelse key.len;
            const dend = std.mem.indexOfScalarPos(u8, display, dstart, '/') orelse display.len;
            const prefix = key[0..end];
            const child = node.index.get(key[start..end]) orelse blk: {
                const c = try b.arena.create(Mut);
                c.* = .{ .name = display[dstart..dend], .full = display[0..dend], .key = prefix };
                try node.children.append(b.arena, c);
                try node.index.put(b.arena, key[start..end], c);
                break :blk c;
            };
            const gop = try b.seen.getOrPut(b.arena, prefix);
            if (!gop.found_existing) child.count += 1;
            node = child;
            start = end + 1;
            dstart = @min(dend + 1, display.len);
        }
    }

    /// The frozen tree; children sorted by name.
    pub fn finish(b: *Builder) !*const TagNode {
        return freeze(b.arena, b.root);
    }

    fn freeze(a: Allocator, m: *Mut) !*TagNode {
        const n = try a.create(TagNode);
        const kids = try a.alloc(*TagNode, m.children.items.len);
        for (m.children.items, kids) |c, *k| k.* = try freeze(a, c);
        std.mem.sort(*TagNode, kids, {}, struct {
            fn lt(_: void, x: *TagNode, y: *TagNode) bool {
                return std.mem.lessThan(u8, x.key, y.key);
            }
        }.lt);
        n.* = .{ .name = m.name, .full = m.full, .key = m.key, .count = m.count, .children = kids };
        return n;
    }
};

test "tag_tree: counts once per note and keeps first casing" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var b = try Builder.init(arena.allocator());
    b.beginNote();
    try b.add("proj/alpha", "Proj/Alpha");
    try b.add("proj/alpha", "proj/alpha");
    try b.add("proj", "proj");
    b.beginNote();
    try b.add("proj/beta", "PROJ/beta");
    try b.add("solo", "Solo");
    const t = try b.finish();
    try std.testing.expectEqual(@as(usize, 2), t.children.len);
    const proj = t.find("proj").?;
    try std.testing.expectEqual(@as(u32, 2), proj.count);
    try std.testing.expectEqualStrings("Proj", proj.name);
    try std.testing.expectEqual(@as(u32, 1), t.find("proj/alpha").?.count);
    try std.testing.expectEqualStrings("PROJ/beta", t.find("proj/beta").?.full);
    try std.testing.expect(t.find("proj/gamma") == null);
}
