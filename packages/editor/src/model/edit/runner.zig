//! The per-selection command runner: a command describes its edit for one
//! selection at a time into an `EditBuilder`, and the runner turns the N
//! descriptions into one ChangeSet, applies it, and places every new
//! selection from where its own edit landed (so a caret ends after the
//! text typed for it even when generic mapping would be ambiguous).

const std = @import("std");
const cs_mod = @import("change_set.zig");
const sel_mod = @import("selection.zig");
const document = @import("../document.zig");
const snapshot_mod = @import("../snapshot.zig");

const Allocator = std.mem.Allocator;
const ChangeSet = cs_mod.ChangeSet;
const Range = cs_mod.Range;
const Replace = cs_mod.Replace;
const Selection = sel_mod.Selection;
const SelectionSet = sel_mod.SelectionSet;
const Document = document.Document;
const EditOrigin = document.EditOrigin;
const Snapshot = snapshot_mod.Snapshot;

/// Where a selection goes after the edit, relative to the edits it made.
pub const Target = union(enum) {
    /// Map the old selection through the change.
    map,
    /// A caret `delta` bytes into the inserted text of this selection's
    /// edit `edit` (null `delta`: after all of it).
    in_edit: struct { edit: u32, delta: ?u32 = null },
    /// A range inside the inserted text of edit `edit`.
    range_in_edit: struct { edit: u32, anchor: u32, head: u32 },
    /// A caret at an offset of the snapshot the command saw, mapped
    /// through the change (moving past text inserted there).
    at: u64,
};

/// Collects one command's edits and the selections they leave.
pub const EditBuilder = struct {
    gpa: Allocator,
    edits: std.ArrayList(Pending) = .empty,
    targets: std.ArrayList(Target) = .empty,
    /// Owns copies of the inserted texts.
    arena: std.heap.ArenaAllocator,
    sel: u32 = 0,
    first_edit: u32 = 0,

    const Pending = struct { rep: Replace, sel: u32, nth: u32 };

    fn init(gpa: Allocator) EditBuilder {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    fn deinit(b: *EditBuilder) void {
        b.edits.deinit(b.gpa);
        b.targets.deinit(b.gpa);
        b.arena.deinit();
    }

    fn begin(b: *EditBuilder, sel: u32) Allocator.Error!void {
        b.sel = sel;
        b.first_edit = @intCast(b.edits.items.len);
        try b.targets.append(b.gpa, .map);
    }

    /// Replaces `range` (in the snapshot the command sees) with `text`;
    /// returns the edit's index within this selection.
    pub fn replace(b: *EditBuilder, range: Range, text: []const u8) Allocator.Error!u32 {
        const nth: u32 = @intCast(b.edits.items.len - b.first_edit);
        const owned = try b.arena.allocator().dupe(u8, text);
        try b.edits.append(b.gpa, .{ .rep = .{ .range = range, .text = owned }, .sel = b.sel, .nth = nth });
        return nth;
    }

    /// Inserts `text` at `at`.
    pub fn insert(b: *EditBuilder, at: u64, text: []const u8) Allocator.Error!u32 {
        return b.replace(.{ .start = at, .end = at }, text);
    }

    /// Deletes `range`.
    pub fn delete(b: *EditBuilder, range: Range) Allocator.Error!u32 {
        return b.replace(range, "");
    }

    /// Sets where this selection goes after the edit (default `.map`).
    pub fn select(b: *EditBuilder, t: Target) void {
        b.targets.items[b.targets.items.len - 1] = t;
    }
};

/// Describes the edit for one selection.
pub const EditFn = *const fn (ctx: *anyopaque, snap: *const Snapshot, sel: Selection, out: *EditBuilder) anyerror!void;

/// What a run did.
pub const RunResult = struct {
    /// Edits dropped because they overlapped an earlier one.
    dropped: u32 = 0,
    /// Whether the document changed.
    changed: bool = false,
};

/// Calls `f` for every selection, builds one ChangeSet from all edits,
/// applies it with `origin`, and sets each selection from its target.
/// Edits are ordered by position, then by selection order; one that
/// overlaps an edit kept before it is dropped (and counted), and the
/// selection that made it falls back to `.map`.
pub fn runPerSelection(doc: *Document, sels: *SelectionSet, f: EditFn, ctx: *anyopaque, origin: EditOrigin) !RunResult {
    const gpa = sels.gpa;
    var snap = doc.snapshot();
    defer snap.release();
    var b: EditBuilder = .init(gpa);
    defer b.deinit();
    for (sels.items.items, 0..) |sel, i| {
        try b.begin(@intCast(i));
        try f(ctx, &snap, sel, &b);
    }
    var res: RunResult = .{};

    // Order by position (then selection order) and drop overlaps.
    const order = try gpa.alloc(u32, b.edits.items.len);
    defer gpa.free(order);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    std.sort.pdq(u32, order, b.edits.items, struct {
        fn lt(e: []const EditBuilder.Pending, x: u32, y: u32) bool {
            const a = e[x].rep.range;
            const c = e[y].rep.range;
            if (a.start != c.start) return a.start < c.start;
            if (a.end != c.end) return a.end < c.end;
            return x < y;
        }
    }.lt);
    var kept: std.ArrayList(Replace) = .empty;
    defer kept.deinit(gpa);
    // New start of each kept edit, by edit index; maxInt for dropped ones.
    const new_start = try gpa.alloc(u64, b.edits.items.len);
    defer gpa.free(new_start);
    @memset(new_start, std.math.maxInt(u64));
    var delta: i128 = 0;
    var last_end: u64 = 0;
    for (order) |i| {
        const e = b.edits.items[i].rep;
        if (kept.items.len > 0 and e.range.start < last_end) {
            res.dropped += 1;
            continue;
        }
        if (e.range.end > snap.len() or e.range.start > e.range.end) return error.OutOfBounds;
        new_start[i] = @intCast(@as(i128, e.range.start) + delta);
        delta += @as(i128, e.text.len) - @as(i128, e.range.len());
        last_end = e.range.end;
        try kept.append(gpa, e);
    }
    var cs = try ChangeSet.fromEdits(gpa, snap.len(), kept.items);
    defer cs.deinit();
    // Even without a change, `.at` targets move carets (typing over a
    // closer).
    if (!cs.isIdentity()) {
        try doc.applyChangeSet(&cs, origin);
        res.changed = true;
    }

    // Index of each selection's first edit.
    const first = try gpa.alloc(u32, sels.items.items.len + 1);
    defer gpa.free(first);
    {
        var k: u32 = 0;
        for (first[0..sels.items.items.len], 0..) |*fi, si| {
            fi.* = k;
            while (k < b.edits.items.len and b.edits.items[k].sel == si) k += 1;
        }
        first[sels.items.items.len] = k;
    }
    for (sels.items.items, b.targets.items, 0..) |*sel, t, si| {
        const lo = first[si];
        const hi = first[si + 1];
        const placed: ?Selection = switch (t) {
            .map => null,
            .at => |o| Selection.caret(cs.mapPos(o, .right)),
            .in_edit => |p| blk: {
                if (lo + p.edit >= hi) break :blk null;
                const ns = new_start[lo + p.edit];
                if (ns == std.math.maxInt(u64)) break :blk null;
                const len = b.edits.items[lo + p.edit].rep.text.len;
                break :blk Selection.caret(ns + @min(p.delta orelse len, len));
            },
            .range_in_edit => |p| blk: {
                if (lo + p.edit >= hi) break :blk null;
                const ns = new_start[lo + p.edit];
                if (ns == std.math.maxInt(u64)) break :blk null;
                break :blk .{ .anchor = ns + p.anchor, .head = ns + p.head };
            },
        };
        if (placed) |p| {
            const id = sel.id;
            sel.* = p;
            sel.id = id;
        } else sel.* = sel.map(&cs);
    }
    sels.normalize(.for_display);
    sels.clearHistory();
    sels.word_search = false;
    return res;
}

/// How `applyEdits` moves selections. `keep` doesn't grow a range over
/// text inserted at its edges; `grow` does (comment toggles keep the
/// toggled lines selected).
pub const Mapping = enum { keep, grow };

/// Applies `edits` (against the current version, any order, no
/// overlaps) as one change and maps every selection through it.
pub fn applyEdits(doc: *Document, sels: *SelectionSet, edits: []const Replace, origin: EditOrigin, mapping: Mapping) !bool {
    var cs = try ChangeSet.fromEdits(sels.gpa, doc.len(), edits);
    defer cs.deinit();
    if (cs.isIdentity()) return false;
    try doc.applyChangeSet(&cs, origin);
    switch (mapping) {
        .keep => sels.mapThrough(&cs),
        .grow => {
            for (sels.items.items) |*x| {
                if (x.isCaret()) {
                    x.* = x.map(&cs);
                    continue;
                }
                const lo = cs.mapPos(x.start(), .left);
                const hi = cs.mapPos(x.end(), .right);
                if (x.head > x.anchor) {
                    x.anchor = lo;
                    x.head = hi;
                } else {
                    x.anchor = hi;
                    x.head = lo;
                }
                x.goal_x = null;
                x.virtual = 0;
            }
            sels.normalize(.for_display);
        },
    }
    sels.clearHistory();
    sels.word_search = false;
    return true;
}

const TypeCtx = struct { text: []const u8, pad: []const u8 };

fn typeOne(ctx_ptr: *anyopaque, _: *const Snapshot, sel: Selection, out: *EditBuilder) anyerror!void {
    const ctx: *const TypeCtx = @ptrCast(@alignCast(ctx_ptr));
    if (sel.virtual == 0 or !sel.isCaret()) {
        _ = try out.replace(sel.range(), ctx.text);
    } else {
        const n = @min(sel.virtual, ctx.pad.len);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(out.gpa);
        try buf.appendSlice(out.gpa, ctx.pad[0..n]);
        try buf.appendSlice(out.gpa, ctx.text);
        _ = try out.replace(sel.range(), buf.items);
    }
    out.select(.{ .in_edit = .{ .edit = 0 } });
}

/// Types `text` at every selection, replacing selected text; a caret in
/// virtual space is first padded with spaces to its column.
pub fn typeText(doc: *Document, sels: *SelectionSet, text: []const u8, origin: EditOrigin) !RunResult {
    var max_pad: u32 = 0;
    for (sels.items.items) |s| max_pad = @max(max_pad, s.virtual);
    const pad = try sels.gpa.alloc(u8, max_pad);
    defer sels.gpa.free(pad);
    @memset(pad, ' ');
    var ctx: TypeCtx = .{ .text = text, .pad = pad };
    return runPerSelection(doc, sels, typeOne, &ctx, origin);
}
