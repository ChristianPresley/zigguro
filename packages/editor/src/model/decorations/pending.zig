//! PendingChange: an agent's proposed ChangeSet shown as an inline diff
//! with per-hunk accept and reject, kept valid while the user edits.
//!
//! Each replace of the proposal is a hunk with its own single-replace
//! ChangeSet in current coordinates. Document changes rebase every
//! unresolved hunk through `ChangeSet.transform` (the user wins ties); a
//! user edit inside a hunk's old text marks it `conflicted` for E12 to
//! resolve (re-ask the agent or show a three-way view).

const std = @import("std");
const store_mod = @import("store.zig");
const pt = @import("../buffer/piece_tree.zig");
const cs_mod = @import("../edit/change_set.zig");
const document = @import("../document.zig");
const diff = @import("../diff.zig");

const Allocator = std.mem.Allocator;
const Range = pt.Range;
const ChangeSet = cs_mod.ChangeSet;
const ChangeEvent = document.ChangeEvent;
const Document = document.Document;
const DecorationStore = store_mod.DecorationStore;
const OwnerId = store_mod.OwnerId;

pub const HunkState = enum { pending, accepted, rejected, conflicted };

pub const PendingHunk = struct {
    id: u32,
    /// The text the hunk replaces, in current coordinates.
    old_range: Range,
    new_text: []const u8,
    /// Word-level highlights between the old and new text (ranges relative
    /// to each side's text).
    intraline: []const diff.DiffRange,
    state: HunkState,
};

/// Styles for the inline diff (E15 theme tokens).
pub const Styles = struct {
    removed: store_mod.StyleRef = @enumFromInt(0),
    inserted: store_mod.StyleRef = @enumFromInt(0),
    conflicted: store_mod.StyleRef = @enumFromInt(0),
};

pub const Error = Allocator.Error || error{ Conflicted, NoSuchHunk, StaleVersion, VersionMismatch, BufferFull } || cs_mod.FromEditsError;

pub const PendingChange = struct {
    gpa: Allocator,
    doc: *Document,
    store: *DecorationStore,
    /// The decoration owner reserved for this change.
    owner: OwnerId,
    label: []u8,
    origin: document.EditOrigin,
    styles: Styles,
    hunk_list: std.ArrayList(PendingHunk) = .empty,
    arena: std.heap.ArenaAllocator,
    /// Set while this change applies its own edits.
    applying: bool = false,

    /// A pending change from `cs`, computed against `base_version` (it is
    /// rebased onto the current version; hunks whose text changed since
    /// start out `conflicted`). Subscribe `onChange` to the document after
    /// the decoration store.
    pub fn create(gpa: Allocator, doc: *Document, store: *DecorationStore, owner: OwnerId, cs: *const ChangeSet, base_version: u64, label: []const u8, origin: document.EditOrigin, styles: Styles) Error!*PendingChange {
        const p = try gpa.create(PendingChange);
        errdefer gpa.destroy(p);
        p.* = .{ .gpa = gpa, .doc = doc, .store = store, .owner = owner, .label = undefined, .origin = origin, .styles = styles, .arena = .init(gpa) };
        errdefer p.arena.deinit();
        const a = p.arena.allocator();
        p.label = try a.dupe(u8, label);
        // Everything since the base, as one ChangeSet.
        var since: ?ChangeSet = null;
        defer if (since) |*x| x.deinit();
        if (base_version != doc.version) {
            since = (try doc.change_log.compose(base_version, doc.version, gpa)) orelse return error.StaleVersion;
        }
        try p.hunk_list.ensureTotalCapacity(gpa, cs.replaces.len);
        errdefer p.hunk_list.deinit(gpa);
        for (cs.replaces, 0..) |r, i| {
            var h: PendingHunk = .{ .id = @intCast(i), .old_range = r.range, .new_text = try a.dupe(u8, r.text), .intraline = &.{}, .state = .pending };
            if (since) |*s| {
                const one = try singleChange(gpa, cs.base_len, h.old_range, h.new_text);
                var moved = one;
                defer moved.deinit();
                var t = try moved.transform(s, false, gpa);
                defer t.deinit();
                h.old_range = rangeOf(&t, h.old_range, s);
                if (t.conflicted) h.state = .conflicted;
            }
            p.hunk_list.appendAssumeCapacity(h);
        }
        for (p.hunk_list.items) |*h| h.intraline = try p.intralineOf(h);
        try p.render();
        return p;
    }

    /// Removes the decorations and frees the change.
    pub fn destroy(p: *PendingChange) void {
        p.store.clearOwner(p.owner);
        p.hunk_list.deinit(p.gpa);
        p.arena.deinit();
        p.gpa.destroy(p);
    }

    pub fn hunks(p: *const PendingChange) []const PendingHunk {
        return p.hunk_list.items;
    }

    /// Whether every hunk is accepted or rejected.
    pub fn resolved(p: *const PendingChange) bool {
        for (p.hunk_list.items) |h| if (h.state == .pending or h.state == .conflicted) return false;
        return true;
    }

    fn find(p: *PendingChange, id: u32) ?*PendingHunk {
        for (p.hunk_list.items) |*h| if (h.id == id) return h;
        return null;
    }

    /// Applies one hunk (its rebased text) as one edit and undo group.
    pub fn acceptHunk(p: *PendingChange, id: u32) Error!void {
        const h = p.find(id) orelse return error.NoSuchHunk;
        switch (h.state) {
            .pending => {},
            .conflicted => return error.Conflicted,
            .accepted, .rejected => return,
        }
        try p.apply(&.{h});
    }

    pub fn rejectHunk(p: *PendingChange, id: u32) void {
        const h = p.find(id) orelse return;
        if (h.state == .pending or h.state == .conflicted) h.state = .rejected;
        p.render() catch {};
    }

    /// Applies every pending hunk as one edit (one undo group); conflicted
    /// hunks are left for the caller.
    pub fn acceptAll(p: *PendingChange) Error!void {
        var list: std.ArrayList(*PendingHunk) = .empty;
        defer list.deinit(p.gpa);
        for (p.hunk_list.items) |*h| if (h.state == .pending) try list.append(p.gpa, h);
        if (list.items.len > 0) try p.apply(list.items);
    }

    pub fn rejectAll(p: *PendingChange) void {
        for (p.hunk_list.items) |*h| if (h.state == .pending or h.state == .conflicted) {
            h.state = .rejected;
        };
        p.render() catch {};
    }

    fn apply(p: *PendingChange, hs: []const *PendingHunk) Error!void {
        const edits = try p.gpa.alloc(pt.Edit, hs.len);
        defer p.gpa.free(edits);
        for (hs, edits) |h, *e| e.* = .{ .range = h.old_range, .text = h.new_text };
        var cs = try ChangeSet.fromEdits(p.gpa, p.doc.len(), edits);
        defer cs.deinit();
        for (hs) |h| h.state = .accepted;
        p.applying = true;
        defer p.applying = false;
        // Our own edit still moves the other hunks.
        try p.doc.applyChangeSet(&cs, p.origin);
    }

    /// Rebases the unresolved hunks through a document change (call from
    /// the document listener, after the decoration store's).
    pub fn onChange(p: *PendingChange, ev: *const ChangeEvent) Allocator.Error!void {
        for (p.hunk_list.items) |*h| {
            switch (h.state) {
                .pending, .conflicted => {},
                .accepted, .rejected => continue,
            }
            const one = try singleChange(p.gpa, ev.changes.base_len, h.old_range, h.new_text);
            var moved = one;
            defer moved.deinit();
            var t = try moved.transform(ev.changes, false, p.gpa);
            defer t.deinit();
            h.old_range = rangeOf(&t, h.old_range, ev.changes);
            if (t.conflicted and !p.applying) h.state = .conflicted;
        }
        try p.render();
    }

    fn intralineOf(p: *PendingChange, h: *const PendingHunk) Allocator.Error![]const diff.DiffRange {
        const a = p.arena.allocator();
        const old_text = try p.doc.tree.copyRange(p.gpa, h.old_range);
        defer p.gpa.free(old_text);
        var la = try diff.LineSource.fromBytes(p.gpa, old_text);
        defer la.deinit(p.gpa);
        var lb = try diff.LineSource.fromBytes(p.gpa, h.new_text);
        defer lb.deinit(p.gpa);
        var res = try diff.diffLines(p.gpa, &la, &lb, .{ .intraline = .word, .context_lines = 0 });
        defer res.deinit(p.gpa);
        return a.dupe(diff.DiffRange, res.ranges);
    }

    /// Decorations: removed text highlighted and struck through, inserted
    /// text inline (one line) or as a block below (several), and a block
    /// above each hunk for its Accept/Reject row (payload: hunk id).
    fn render(p: *PendingChange) Allocator.Error!void {
        var decos: std.ArrayList(store_mod.Decoration) = .empty;
        defer decos.deinit(p.gpa);
        for (p.hunk_list.items) |h| {
            switch (h.state) {
                .pending, .conflicted => {},
                .accepted, .rejected => continue,
            }
            const style = if (h.state == .conflicted) p.styles.conflicted else p.styles.removed;
            const r = h.old_range;
            try decos.append(p.gpa, .{ .range = r, .owner = p.owner, .stick = .point_left, .kind = .{ .block_above = .{ .rows = 1, .payload = h.id } } });
            if (r.end > r.start) {
                try decos.append(p.gpa, .{ .range = r, .owner = p.owner, .kind = .{ .highlight = style } });
                try decos.append(p.gpa, .{ .range = r, .owner = p.owner, .kind = .strike });
            }
            if (h.new_text.len > 0) {
                const at: Range = .{ .start = r.end, .end = r.end };
                if (std.mem.indexOfScalar(u8, h.new_text, '\n') == null) {
                    try decos.append(p.gpa, .{ .range = at, .owner = p.owner, .stick = .point_left, .kind = .{ .inline_after = .{ .text = h.new_text, .style = p.styles.inserted } } });
                } else {
                    const rows: u32 = @intCast(std.mem.count(u8, h.new_text, "\n") + 1);
                    try decos.append(p.gpa, .{ .range = at, .owner = p.owner, .stick = .point_left, .kind = .{ .block_below = .{ .rows = rows, .payload = h.id } } });
                }
            }
        }
        try p.store.setOwnerDecorations(p.owner, p.doc.version, decos.items);
    }
};

/// A ChangeSet replacing `range` of a `len`-byte text by `text`.
fn singleChange(gpa: Allocator, len: u64, range: Range, text: []const u8) Allocator.Error!ChangeSet {
    return ChangeSet.fromEdits(gpa, len, &.{.{ .range = range, .text = text }}) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.Overlap, error.OutOfBounds => unreachable,
    };
}

/// The old range of the single replace in `t` (the rebased hunk), in the
/// coordinates after `by`. A hunk whose old text was entirely replaced
/// becomes an insertion where it was.
fn rangeOf(t: *const ChangeSet, old: Range, by: *const ChangeSet) Range {
    if (t.replaces.len == 1) return t.replaces[0].range;
    // The transformed hunk is a no-op (nothing to delete or insert).
    const s = by.mapPos(old.start, .left);
    return .{ .start = s, .end = s };
}
