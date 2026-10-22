//! ChangeSet: sorted, non-overlapping replacements against one document
//! version. The single currency of every mutation (typing, multi-cursor
//! commands, undo, LSP edits, agent edits), with apply, invert, compose,
//! transform (OT, TP1) and position mapping.
//!
//! Coordinates: every `Replace.range` is in the *old* (input) coordinates;
//! `newLen()` is the length after applying. A ChangeSet owns its replace
//! array and texts (one arena); copy it with `clone`, free it with `deinit`.
//!
//! Position mapping rules (`mapPos`):
//! - before a replacement: shifted by the size change of earlier ones;
//! - at an insertion point (empty range): before the inserted text with
//!   `.left`, after it with `.right`;
//! - at the start or end of a non-empty replaced range: stays with the
//!   unchanged text on that side (start of the new text, or its end);
//! - strictly inside a replaced range: start (`.left`) or end (`.right`) of
//!   the replacement text.

const std = @import("std");
const zg_core = @import("zg_core");
const pt = @import("../buffer/piece_tree.zig");
const NodePool = @import("../buffer/node_pool.zig").NodePool;

const Allocator = std.mem.Allocator;
const PieceTree = pt.PieceTree;

/// A byte range `[start, end)`.
pub const Range = pt.Range;
/// One replacement: `range` in old coordinates, replaced by `text`.
pub const Replace = pt.Edit;
/// A line and a column in the negotiated LSP position encoding.
pub const PointUtf16 = pt.PointUtf16;

/// Where a position sticks when text is inserted exactly at it.
pub const Bias = enum { left, right };

/// One LSP `TextDocumentContentChangeEvent` with a range.
pub const LspChange = struct { start: PointUtf16, end: PointUtf16, text: []const u8 };

/// How `mapRange` treats a range whose edges see insertions or deletions.
pub const MapMode = enum {
    /// Insertions at either edge are included.
    expand,
    /// Insertions at either edge are excluded.
    shrink,
    /// Any replacement touching the range (edges included) deletes it.
    delete_if_touched,
};

pub const FromEditsError = error{ Overlap, OutOfBounds, OutOfMemory };

/// Sorted, non-overlapping replacements.
pub const ChangeSet = struct {
    /// Length of the text this applies to.
    base_len: u64,
    /// Sorted by `range.start`; adjacent replacements are merged.
    replaces: []const Replace,
    /// Start of each replacement in new coordinates (for `mapPos`).
    new_starts: []const u64,
    /// Set by `transform` when a replacement targeted text the other
    /// ChangeSet had already changed; it collapsed to an insertion.
    conflicted: bool = false,
    arena: std.heap.ArenaAllocator.State = .{},
    gpa: Allocator,

    /// A ChangeSet that changes nothing.
    pub fn identity(gpa: Allocator, base_len: u64) ChangeSet {
        return .{ .base_len = base_len, .replaces = &.{}, .new_starts = &.{}, .gpa = gpa };
    }

    /// Builds a ChangeSet from edits in any order: sorts them by start then
    /// end (stable, so insertions at one point keep their order),
    /// rejects overlaps and out-of-range edits, drops no-ops and merges
    /// adjacent edits (in order). Texts are copied.
    pub fn fromEdits(gpa: Allocator, base_len: u64, edits: []const Replace) FromEditsError!ChangeSet {
        for (edits) |e| if (e.range.start > e.range.end or e.range.end > base_len) return error.OutOfBounds;
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const sorted = try a.dupe(Replace, edits);
        std.sort.insertion(Replace, sorted, {}, struct {
            fn lt(_: void, x: Replace, y: Replace) bool {
                return x.range.start < y.range.start or (x.range.start == y.range.start and x.range.end < y.range.end);
            }
        }.lt);
        var out: std.ArrayList(Replace) = .empty;
        try out.ensureTotalCapacity(a, sorted.len);
        for (sorted) |e| {
            if (e.range.start == e.range.end and e.text.len == 0) continue;
            if (out.items.len > 0) {
                const last = &out.items[out.items.len - 1];
                if (e.range.start < last.range.end) return error.Overlap;
                if (e.range.start == last.range.end) {
                    last.range.end = e.range.end;
                    last.text = try std.mem.concat(a, u8, &.{ last.text, e.text });
                    continue;
                }
            }
            out.appendAssumeCapacity(.{ .range = e.range, .text = try a.dupe(u8, e.text) });
        }
        return finish(gpa, &arena, base_len, out.items, false);
    }

    /// Builds from replaces already sorted, non-overlapping and owned by
    /// `arena` (which the ChangeSet takes over).
    fn finish(gpa: Allocator, arena: *std.heap.ArenaAllocator, base_len: u64, reps: []const Replace, conflicted: bool) Allocator.Error!ChangeSet {
        const starts = try arena.allocator().alloc(u64, reps.len);
        var delta: i128 = 0;
        for (reps, starts) |r, *s| {
            s.* = @intCast(@as(i128, r.range.start) + delta);
            delta += @as(i128, r.text.len) - @as(i128, r.range.len());
        }
        return .{ .base_len = base_len, .replaces = reps, .new_starts = starts, .conflicted = conflicted, .arena = arena.state, .gpa = gpa };
    }

    /// Frees the ChangeSet.
    pub fn deinit(cs: *ChangeSet) void {
        cs.arena.promote(cs.gpa).deinit();
        cs.* = undefined;
    }

    /// A deep copy.
    pub fn clone(cs: *const ChangeSet, gpa: Allocator) Allocator.Error!ChangeSet {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const reps = try a.dupe(Replace, cs.replaces);
        for (reps) |*r| r.text = try a.dupe(u8, r.text);
        return finish(gpa, &arena, cs.base_len, reps, cs.conflicted);
    }

    /// Whether applying changes nothing.
    pub fn isIdentity(cs: *const ChangeSet) bool {
        return cs.replaces.len == 0;
    }

    /// Length after applying.
    pub fn newLen(cs: *const ChangeSet) u64 {
        return @intCast(@as(i128, cs.base_len) + @as(i128, cs.insertedBytes()) - @as(i128, cs.deletedBytes()));
    }

    /// Bytes of inserted text.
    pub fn insertedBytes(cs: *const ChangeSet) u64 {
        var n: u64 = 0;
        for (cs.replaces) |r| n += r.text.len;
        return n;
    }

    /// Bytes of removed text.
    pub fn deletedBytes(cs: *const ChangeSet) u64 {
        var n: u64 = 0;
        for (cs.replaces) |r| n += r.range.len();
        return n;
    }

    /// Approximate heap size (for change-log and undo budgets).
    pub fn memoryBytes(cs: *const ChangeSet) usize {
        return cs.replaces.len * (@sizeOf(Replace) + 8) + @as(usize, @intCast(cs.insertedBytes()));
    }

    /// Applies to `t` (whose length must be `base_len`), returning the new
    /// version; `t` is unchanged.
    pub fn apply(cs: *const ChangeSet, t: PieceTree, pool: *NodePool) pt.EditError!PieceTree {
        if (t.len() != cs.base_len) return error.OutOfBounds;
        return t.replace(pool, cs.replaces);
    }

    /// Applies to a plain string (tests and naive models).
    pub fn applyToSlice(cs: *const ChangeSet, gpa: Allocator, text: []const u8) Allocator.Error![]u8 {
        std.debug.assert(text.len == cs.base_len);
        const out = try gpa.alloc(u8, @intCast(cs.newLen()));
        var i: usize = 0;
        var prev: usize = 0;
        for (cs.replaces) |r| {
            const s: usize = @intCast(r.range.start);
            @memcpy(out[i..][0 .. s - prev], text[prev..s]);
            i += s - prev;
            @memcpy(out[i..][0..r.text.len], r.text);
            i += r.text.len;
            prev = @intCast(r.range.end);
        }
        @memcpy(out[i..], text[prev..]);
        return out;
    }

    /// The inverse: applied after `cs`, restores `before` (the text `cs`
    /// applies to). Old text is copied from `before`.
    pub fn invert(cs: *const ChangeSet, before: PieceTree, gpa: Allocator) Allocator.Error!ChangeSet {
        std.debug.assert(before.len() == cs.base_len);
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const reps = try a.alloc(Replace, cs.replaces.len);
        for (cs.replaces, cs.new_starts, reps) |r, ns, *out| {
            out.* = .{
                .range = .{ .start = ns, .end = ns + r.text.len },
                .text = try before.copyRange(a, r.range),
            };
        }
        return finish(gpa, &arena, cs.newLen(), reps, false);
    }

    /// Index of the first replacement whose range ends at or after `pos`.
    fn search(cs: *const ChangeSet, pos: u64) usize {
        var lo: usize = 0;
        var hi: usize = cs.replaces.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (cs.replaces[mid].range.end < pos) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    /// Maps an old position to the new text (see the file comment). O(log k).
    pub fn mapPos(cs: *const ChangeSet, pos: u64, bias: Bias) u64 {
        return cs.mapPosDetail(pos, bias).pos;
    }

    /// `mapPos`, also reporting whether `pos` was strictly inside replaced
    /// text.
    pub fn mapPosDetail(cs: *const ChangeSet, pos: u64, bias: Bias) struct { pos: u64, deleted: bool } {
        const i = cs.search(pos);
        if (i == cs.replaces.len) {
            const delta: i128 = @as(i128, cs.newLen()) - @as(i128, cs.base_len);
            return .{ .pos = @intCast(@as(i128, pos) + delta), .deleted = false };
        }
        const r = cs.replaces[i];
        const ns = cs.new_starts[i];
        if (pos < r.range.start) {
            // Before replacement i: shift by the deltas before it.
            return .{ .pos = ns - (r.range.start - pos), .deleted = false };
        }
        if (r.range.start == r.range.end) {
            return .{ .pos = if (bias == .left) ns else ns + r.text.len, .deleted = false };
        }
        if (pos == r.range.start) return .{ .pos = ns, .deleted = false };
        if (pos == r.range.end) return .{ .pos = ns + r.text.len, .deleted = false };
        return .{ .pos = if (bias == .left) ns else ns + r.text.len, .deleted = true };
    }

    /// Maps a range; null when `mode` is `delete_if_touched` and a
    /// replacement touches it.
    pub fn mapRange(cs: *const ChangeSet, r: Range, mode: MapMode) ?Range {
        switch (mode) {
            .expand => return .{ .start = cs.mapPos(r.start, .left), .end = cs.mapPos(r.end, .right) },
            .shrink => {
                const s = cs.mapPos(r.start, .right);
                const e = cs.mapPos(r.end, .left);
                return if (s <= e) .{ .start = s, .end = e } else .{ .start = s, .end = s };
            },
            .delete_if_touched => {
                var i = cs.search(r.start);
                while (i < cs.replaces.len and cs.replaces[i].range.start <= r.end) : (i += 1) {
                    const rep = cs.replaces[i].range;
                    if (rep.end >= r.start) return null;
                }
                return .{ .start = cs.mapPos(r.start, .left), .end = cs.mapPos(r.end, .right) };
            },
        }
    }

    /// `a` then `b`: one ChangeSet in `a`'s input coordinates.
    pub fn compose(a: *const ChangeSet, b: *const ChangeSet, gpa: Allocator) Allocator.Error!ChangeSet {
        std.debug.assert(a.newLen() == b.base_len);
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        var builder: Builder = .{ .gpa = arena.allocator() };
        var ia: OpIter = .init(a);
        var ib: OpIter = .init(b);
        var oa = ia.next();
        var ob = ib.next();
        while (oa != null or ob != null) {
            if (oa) |x| if (x == .delete) {
                try builder.delete(x.delete);
                oa = ia.next();
                continue;
            };
            if (ob) |y| if (y == .insert) {
                try builder.insert(y.insert);
                ob = ib.next();
                continue;
            };
            const x = oa.?;
            const y = ob.?;
            switch (x) {
                .retain => |n| switch (y) {
                    .retain => |m| {
                        const k = @min(n, m);
                        try builder.retain(k);
                        oa = shrinkOp(x, k, &ia);
                        ob = shrinkOp(y, k, &ib);
                    },
                    .delete => |m| {
                        const k = @min(n, m);
                        try builder.delete(k);
                        oa = shrinkOp(x, k, &ia);
                        ob = shrinkOp(y, k, &ib);
                    },
                    .insert => unreachable,
                },
                .insert => |s| switch (y) {
                    .retain => |m| {
                        const k = @min(s.len, m);
                        try builder.insert(s[0..@intCast(k)]);
                        oa = shrinkOp(x, k, &ia);
                        ob = shrinkOp(y, k, &ib);
                    },
                    .delete => |m| {
                        const k = @min(s.len, m);
                        oa = shrinkOp(x, k, &ia);
                        ob = shrinkOp(y, k, &ib);
                    },
                    .insert => unreachable,
                },
                .delete => unreachable,
            }
        }
        return builder.finish(gpa, &arena, a.base_len, false);
    }

    /// Operational transform: `a'` such that applying `b` then `a'` equals
    /// applying `a` then `transform(b, a, !a_wins_ties)` (TP1). Both apply
    /// to the same base. When both insert at one point, `a_wins_ties` puts
    /// `a`'s text first. Where `a` replaces text that `b` also replaced or
    /// deleted, `a'` keeps only `a`'s insertion and `conflicted` is set.
    pub fn transform(a: *const ChangeSet, b: *const ChangeSet, a_wins_ties: bool, gpa: Allocator) Allocator.Error!ChangeSet {
        std.debug.assert(a.base_len == b.base_len);
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        var builder: Builder = .{ .gpa = arena.allocator() };
        var conflicted = false;
        var ia: OpIter = .init(a);
        var ib: OpIter = .init(b);
        var oa = ia.next();
        var ob = ib.next();
        while (oa != null or ob != null) {
            const a_ins = oa != null and oa.? == .insert;
            const b_ins = ob != null and ob.? == .insert;
            if (a_ins and (a_wins_ties or !b_ins)) {
                try builder.insert(oa.?.insert);
                oa = ia.next();
                continue;
            }
            if (b_ins) {
                try builder.retain(ob.?.insert.len);
                ob = ib.next();
                continue;
            }
            const x = oa.?;
            const y = ob.?;
            switch (x) {
                .retain => |n| switch (y) {
                    .retain => |m| {
                        const k = @min(n, m);
                        try builder.retain(k);
                        oa = shrinkOp(x, k, &ia);
                        ob = shrinkOp(y, k, &ib);
                    },
                    .delete => |m| {
                        const k = @min(n, m);
                        oa = shrinkOp(x, k, &ia);
                        ob = shrinkOp(y, k, &ib);
                    },
                    .insert => unreachable,
                },
                .delete => |n| switch (y) {
                    .retain => |m| {
                        const k = @min(n, m);
                        try builder.delete(k);
                        oa = shrinkOp(x, k, &ia);
                        ob = shrinkOp(y, k, &ib);
                    },
                    .delete => |m| {
                        // Both changed the same text: a conflict when either
                        // side rewrote it (a plain double delete is fine).
                        const k = @min(n, m);
                        if (a.replaces[ia.i].text.len > 0 or b.replaces[ib.i].text.len > 0) conflicted = true;
                        oa = shrinkOp(x, k, &ia);
                        ob = shrinkOp(y, k, &ib);
                    },
                    .insert => unreachable,
                },
                .insert => unreachable,
            }
        }
        return builder.finish(gpa, &arena, b.newLen(), conflicted);
    }

    /// LSP `contentChanges` for this ChangeSet: old-coordinate ranges in
    /// descending order, so applying them in sequence is valid (LSP 3.17
    /// `didChange`). Columns use `enc`. Texts borrow from `cs`.
    pub fn toLspChanges(cs: *const ChangeSet, before: PieceTree, enc: zg_core.utf8.Encoding, out: *std.ArrayList(LspChange), gpa: Allocator) Allocator.Error!void {
        try out.ensureUnusedCapacity(gpa, cs.replaces.len);
        var i = cs.replaces.len;
        while (i > 0) {
            i -= 1;
            const r = cs.replaces[i];
            out.appendAssumeCapacity(.{
                .start = try position(before, r.range.start, enc, gpa),
                .end = try position(before, r.range.end, enc, gpa),
                .text = r.text,
            });
        }
    }
};

/// The LSP position of `off` with columns in `enc` units.
pub fn position(t: PieceTree, off: u64, enc: zg_core.utf8.Encoding, gpa: Allocator) Allocator.Error!PointUtf16 {
    switch (enc) {
        .utf16 => return t.offsetToUtf16(off),
        .utf8 => {
            const p = t.offsetToPoint(off);
            return .{ .line = p.line, .col = p.col };
        },
        .utf32 => {
            const line = t.lineOf(off);
            const ls = t.lineStart(line);
            // Include a few bytes past `off` so a straddling code point is
            // recognised and excluded.
            const end = @min(off + 4, t.len());
            const bytes = try t.copyRange(gpa, .{ .start = ls, .end = end });
            defer gpa.free(bytes);
            return .{ .line = line, .col = zg_core.utf8.byteToColumn(bytes, @intCast(off - ls), .utf32) };
        },
    }
}

// -- operation streams ----------------------------------------------------

const Op = union(enum) {
    retain: u64,
    delete: u64,
    insert: []const u8,
};

/// Walks a ChangeSet as retain / delete / insert operations (insert after
/// delete within a replacement), ending with the trailing retain.
const OpIter = struct {
    cs: *const ChangeSet,
    i: usize = 0,
    pos: u64 = 0,
    /// 0: before replace i (gap), 1: delete, 2: insert.
    phase: u2 = 0,

    fn init(cs: *const ChangeSet) OpIter {
        return .{ .cs = cs };
    }

    fn next(it: *OpIter) ?Op {
        while (true) {
            if (it.i == it.cs.replaces.len) {
                if (it.pos < it.cs.base_len) {
                    const n = it.cs.base_len - it.pos;
                    it.pos = it.cs.base_len;
                    return .{ .retain = n };
                }
                return null;
            }
            const r = it.cs.replaces[it.i];
            switch (it.phase) {
                0 => {
                    it.phase = 1;
                    if (r.range.start > it.pos) {
                        const n = r.range.start - it.pos;
                        it.pos = r.range.start;
                        return .{ .retain = n };
                    }
                },
                1 => {
                    it.phase = 2;
                    if (r.range.len() > 0) {
                        it.pos = r.range.end;
                        return .{ .delete = r.range.len() };
                    }
                },
                else => {
                    it.phase = 0;
                    it.i += 1;
                    if (r.text.len > 0) return .{ .insert = r.text };
                },
            }
        }
    }
};

/// The rest of `op` after consuming `k` units, or the iterator's next op.
fn shrinkOp(op: Op, k: u64, it: *OpIter) ?Op {
    switch (op) {
        .retain => |n| return if (n > k) .{ .retain = n - k } else it.next(),
        .delete => |n| return if (n > k) .{ .delete = n - k } else it.next(),
        .insert => |s| return if (s.len > k) .{ .insert = s[@intCast(k)..] } else it.next(),
    }
}

/// Accumulates operations into sorted, merged replacements.
const Builder = struct {
    gpa: Allocator,
    pos: u64 = 0,
    reps: std.ArrayList(Replace) = .empty,
    /// The replacement being built at `pos` (open while deletes/inserts
    /// arrive without an intervening retain).
    open: bool = false,
    text: std.ArrayList(u8) = .empty,

    fn retain(b: *Builder, n: u64) Allocator.Error!void {
        if (n == 0) return;
        try b.close();
        b.pos += n;
    }

    fn delete(b: *Builder, n: u64) Allocator.Error!void {
        if (n == 0) return;
        try b.openAt();
        b.reps.items[b.reps.items.len - 1].range.end += n;
        b.pos += n;
    }

    fn insert(b: *Builder, s: []const u8) Allocator.Error!void {
        if (s.len == 0) return;
        try b.openAt();
        try b.text.appendSlice(b.gpa, s);
    }

    fn openAt(b: *Builder) Allocator.Error!void {
        if (b.open) return;
        try b.reps.append(b.gpa, .{ .range = .{ .start = b.pos, .end = b.pos }, .text = "" });
        b.open = true;
    }

    fn close(b: *Builder) Allocator.Error!void {
        if (!b.open) return;
        b.reps.items[b.reps.items.len - 1].text = try b.gpa.dupe(u8, b.text.items);
        b.text.clearRetainingCapacity();
        b.open = false;
    }

    fn finish(b: *Builder, gpa: Allocator, arena: *std.heap.ArenaAllocator, base_len: u64, conflicted: bool) Allocator.Error!ChangeSet {
        try b.close();
        return ChangeSet.finish(gpa, arena, base_len, b.reps.items, conflicted);
    }
};
