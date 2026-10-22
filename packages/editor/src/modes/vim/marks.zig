//! Vim marks and the jumplist (motion.txt, "Marks" and "Jumps").
//!
//! Marks are offsets kept current by mapping them through every change to
//! their document (the Vim state's listener calls `map`), so they follow
//! edits the way anchors do without depending on the change log's reach.
//! `a`-`z` belong to a document; `A`-`Z` name a document and a position
//! (`GlobalMarks`, shared by every Vim state). The jumplist keeps 100
//! entries; `Ctrl-O` and `Ctrl-I` walk it.

const std = @import("std");
const text_mod = @import("text.zig");
const cs_mod = @import("../../model/edit/change_set.zig");
const document = @import("../../model/document.zig");

const Allocator = std.mem.Allocator;
const Text = text_mod.Text;
const ChangeSet = cs_mod.ChangeSet;
pub const DocId = document.DocId;

pub const jumplist_size = 100;

pub const Marks = struct {
    local: [26]?u64 = @splat(null),
    /// The position before the latest jump (`''` and ``` `` ```).
    context: ?u64 = null,
    /// Where the last change was made (`` `. ``).
    last_change: ?u64 = null,
    jumps: std.ArrayList(u64) = .empty,
    /// Equal to `jumps.len` until `Ctrl-O` walks back.
    jump_idx: usize = 0,

    pub fn deinit(m: *Marks, gpa: Allocator) void {
        m.jumps.deinit(gpa);
    }

    /// Moves every mark through a change to the document.
    pub fn map(m: *Marks, cs: *const ChangeSet) void {
        for (&m.local) |*p| if (p.*) |v| {
            p.* = cs.mapPos(v, .left);
        };
        if (m.context) |v| m.context = cs.mapPos(v, .left);
        if (m.last_change) |v| m.last_change = cs.mapPos(v, .left);
        for (m.jumps.items) |*p| p.* = cs.mapPos(p.*, .left);
    }

    /// Sets mark `name` (`a`-`z`, `'`, `` ` ``); false for other names.
    pub fn set(m: *Marks, name: u21, pos: u64) bool {
        switch (name) {
            'a'...'z' => m.local[name - 'a'] = pos,
            '\'', '`' => m.context = pos,
            else => return false,
        }
        return true;
    }

    /// Mark `name`'s position, when set.
    pub fn get(m: *const Marks, name: u21) ?u64 {
        return switch (name) {
            'a'...'z' => m.local[name - 'a'],
            '\'', '`' => m.context,
            '.' => m.last_change,
            else => null,
        };
    }

    /// Vim's `setpcmark`: before a jump, remember where the cursor was as
    /// the context mark and at the end of the jumplist.
    pub fn pushJump(m: *Marks, gpa: Allocator, pos: u64) !void {
        m.context = pos;
        if (m.jumps.items.len == jumplist_size) _ = m.jumps.orderedRemove(0);
        try m.jumps.append(gpa, pos);
        m.jump_idx = m.jumps.items.len;
    }

    /// Drops earlier entries on the same line as a later one (Vim's
    /// `cleanup_jumplist`).
    fn cleanup(m: *Marks, x: Text) void {
        const items = m.jumps.items;
        var to: usize = 0;
        var idx = m.jump_idx;
        for (items, 0..) |p, from| {
            if (m.jump_idx == from) idx = to;
            const l = x.lineOf(p);
            var dup = false;
            for (items[from + 1 ..]) |q| {
                if (x.lineOf(q) == l) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            items[to] = p;
            to += 1;
        }
        if (m.jump_idx == items.len) idx = to;
        m.jumps.shrinkRetainingCapacity(to);
        m.jump_idx = idx;
    }

    /// `Ctrl-O` (negative `count`) or `Ctrl-I`: the position to jump to,
    /// or null at either end of the list. `cur` is the cursor, added to
    /// the list on the first `Ctrl-O` after a jump.
    pub fn walk(m: *Marks, gpa: Allocator, x: Text, cur: u64, count: i64) !?u64 {
        m.cleanup(x);
        if (m.jumps.items.len == 0) return null;
        const len: i64 = @intCast(m.jumps.items.len);
        var idx: i64 = @intCast(m.jump_idx);
        if (idx + count < 0 or idx + count >= len) return null;
        if (m.jump_idx == m.jumps.items.len) {
            try m.pushJump(gpa, cur);
            idx = @as(i64, @intCast(m.jumps.items.len)) - 1;
            if (idx + count < 0) {
                m.jump_idx = @intCast(idx);
                return null;
            }
        }
        idx += count;
        m.jump_idx = @intCast(idx);
        return m.jumps.items[m.jump_idx];
    }
};

/// File marks `A`-`Z`: a document and a position in it.
pub const GlobalMarks = struct {
    pub const Mark = struct { doc: DocId, pos: u64 };

    marks: [26]?Mark = @splat(null),

    pub fn set(g: *GlobalMarks, name: u21, doc: DocId, pos: u64) bool {
        if (name < 'A' or name > 'Z') return false;
        g.marks[name - 'A'] = .{ .doc = doc, .pos = pos };
        return true;
    }

    pub fn get(g: *const GlobalMarks, name: u21) ?Mark {
        if (name < 'A' or name > 'Z') return null;
        return g.marks[name - 'A'];
    }

    /// Moves the marks in `doc` through a change to it.
    pub fn map(g: *GlobalMarks, doc: DocId, cs: *const ChangeSet) void {
        for (&g.marks) |*e| if (e.*) |*mk| {
            if (mk.doc == doc) mk.pos = cs.mapPos(mk.pos, .left);
        };
    }
};

test "vim: marks survive edits" {
    const gpa = std.testing.allocator;
    var m: Marks = .{};
    defer m.deinit(gpa);
    var g: GlobalMarks = .{};
    try std.testing.expect(m.set('a', 10));
    try std.testing.expect(g.set('B', @enumFromInt(1), 4));
    try std.testing.expect(!m.set('A', 1));
    var cs = try ChangeSet.fromEdits(gpa, 20, &.{.{ .range = .{ .start = 2, .end = 3 }, .text = "xyz" }});
    defer cs.deinit();
    m.map(&cs);
    g.map(@enumFromInt(1), &cs);
    try std.testing.expectEqual(@as(?u64, 12), m.get('a'));
    try std.testing.expectEqual(@as(u64, 6), g.get('B').?.pos);
    // Another document's change leaves it alone.
    g.map(@enumFromInt(2), &cs);
    try std.testing.expectEqual(@as(u64, 6), g.get('B').?.pos);
    try std.testing.expectEqual(@as(?u64, null), m.get('b'));
}
