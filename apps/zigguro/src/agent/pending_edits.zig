//! `PendingEdits`: E05's `PendingHost` for the workbench. With inline
//! review on, an agent edit to a file open in the editor is not applied
//! but shown in place as a pending change: the replaced text highlighted
//! and struck through, the new text after it (inline, or as rows below
//! for several lines), and a header row above each hunk. The user accepts
//! or rejects the change at the caret, or all of a file's changes, from
//! the command palette; an accepted hunk lands as one undo step.
//!
//! Each document with pending changes gets a decoration store, drawn by
//! its editor, and a listener that rebases the changes through the
//! user's typing (a hunk whose text the user changed turns conflicted
//! and can only be rejected). When a document has none left the store
//! goes away again. An editor already drawing another store (ghost-text
//! completions) cannot show pending changes, so edits to it apply as
//! before (`canPlace`).
//!
//! UI thread only.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_editor = @import("zg_editor");

const Allocator = std.mem.Allocator;
const model = zg_editor.model;
const agent_edit = model.api.agent_edit;
const DocHandle = model.api.registry.DocHandle;
const Document = model.document.Document;
const DecorationStore = model.decorations.store.DecorationStore;
const OwnerId = model.decorations.store.OwnerId;
const PendingChange = model.decorations.pending.PendingChange;
const EditorView = zg_editor.view.EditorView;
const BlockInfo = zg_editor.view.editor_view.BlockInfo;

/// See the module doc.
pub const PendingEdits = struct {
    gpa: Allocator,
    resolver: Resolver,
    docs: std.ArrayList(*Entry) = .empty,
    /// Runs after pending changes appear, move or resolve (repaint).
    on_change: ?Hook = null,

    /// The editor showing a document (null: not open).
    pub const Resolver = struct {
        ctx: *anyopaque,
        view: *const fn (ctx: *anyopaque, doc: DocHandle) ?*EditorView,
    };

    pub const Hook = struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque) void };

    /// One document with pending changes.
    const Entry = struct {
        set: *PendingEdits,
        handle: DocHandle,
        view: *EditorView,
        doc: *Document,
        store: *DecorationStore,
        store_listener: model.document.ListenerId,
        listener: model.document.ListenerId,
        changes: std.ArrayList(*PendingChange) = .empty,
        /// Owners registered in `store` (one per change; a store lives
        /// only while the document has changes, so they don't pile up).
        owners: u32 = 0,
    };

    pub fn init(gpa: Allocator, resolver: Resolver) PendingEdits {
        return .{ .gpa = gpa, .resolver = resolver };
    }

    /// Drops every pending change (the documents keep their text).
    pub fn deinit(pe: *PendingEdits) void {
        while (pe.docs.items.len > 0) pe.dropEntry(pe.docs.items.len - 1);
        pe.docs.deinit(pe.gpa);
    }

    /// The `PendingHost` for an `AgentEditSession`. `pe` must not move.
    pub fn host(pe: *PendingEdits) agent_edit.PendingHost {
        return .{ .ctx = pe, .place = place, .created = created };
    }

    /// Whether an edit to `doc` can be shown pending: it is open and its
    /// editor draws no other decoration store.
    pub fn canPlace(pe: *PendingEdits, doc: DocHandle) bool {
        if (pe.entryOf(doc) != null) return true;
        const v = pe.resolver.view(pe.resolver.ctx, doc) orelse return false;
        return v.decorations == null and v.block_painter == null;
    }

    /// Pending changes in all documents.
    pub fn count(pe: *const PendingEdits) usize {
        var n: usize = 0;
        for (pe.docs.items) |e| n += e.changes.items.len;
        return n;
    }

    fn cast(ctx: *anyopaque) *PendingEdits {
        return @ptrCast(@alignCast(ctx));
    }

    fn entryOf(pe: *PendingEdits, doc: DocHandle) ?*Entry {
        for (pe.docs.items) |e| if (std.meta.eql(e.handle, doc)) return e;
        return null;
    }

    fn entryOfView(pe: *PendingEdits, v: *const EditorView) ?*Entry {
        for (pe.docs.items) |e| if (e.view == v) return e;
        return null;
    }

    fn place(ctx: *anyopaque, doc: DocHandle) ?agent_edit.PendingPlace {
        const pe = cast(ctx);
        const e = pe.entryOf(doc) orelse pe.newEntry(doc) catch return null;
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "agent.pending.{d}", .{e.owners}) catch unreachable;
        const owner = e.store.registerOwner(name, 30) catch return null;
        e.owners += 1;
        return .{ .store = e.store, .owner = owner };
    }

    fn created(ctx: *anyopaque, doc: DocHandle, change: *PendingChange) void {
        const pe = cast(ctx);
        const e = pe.entryOf(doc) orelse return change.destroy();
        e.changes.append(pe.gpa, change) catch return change.destroy();
        pe.changed();
    }

    fn newEntry(pe: *PendingEdits, doc: DocHandle) !*Entry {
        const v = pe.resolver.view(pe.resolver.ctx, doc) orelse return error.NotOpen;
        if (v.decorations != null or v.block_painter != null) return error.Busy;
        const e = try pe.gpa.create(Entry);
        errdefer pe.gpa.destroy(e);
        const store = try pe.gpa.create(DecorationStore);
        errdefer pe.gpa.destroy(store);
        store.* = .init(pe.gpa, v.doc);
        errdefer store.deinit();
        e.* = .{ .set = pe, .handle = doc, .view = v, .doc = v.doc, .store = store, .store_listener = undefined, .listener = undefined };
        // The store moves its decorations before the changes rebase.
        e.store_listener = try v.doc.subscribe(store.listener());
        errdefer v.doc.unsubscribe(e.store_listener);
        e.listener = try v.doc.subscribe(.{ .ctx = e, .onChange = onDocChange });
        errdefer v.doc.unsubscribe(e.listener);
        try pe.docs.append(pe.gpa, e);
        v.decorations = store;
        v.block_painter = .{ .ctx = e, .paint = paintBlock };
        return e;
    }

    fn dropEntry(pe: *PendingEdits, i: usize) void {
        const e = pe.docs.orderedRemove(i);
        for (e.changes.items) |c| c.destroy();
        e.changes.deinit(pe.gpa);
        e.doc.unsubscribe(e.listener);
        e.doc.unsubscribe(e.store_listener);
        if (e.view.decorations == e.store) e.view.decorations = null;
        if (e.view.block_painter) |bp| if (bp.ctx == @as(?*anyopaque, e)) {
            e.view.block_painter = null;
        };
        e.store.deinit();
        pe.gpa.destroy(e.store);
        pe.gpa.destroy(e);
    }

    /// Forgets `view`'s pending changes (its file is closing).
    pub fn dropView(pe: *PendingEdits, view: *const EditorView) void {
        var i: usize = pe.docs.items.len;
        while (i > 0) {
            i -= 1;
            if (pe.docs.items[i].view == view) pe.dropEntry(i);
        }
    }

    fn onDocChange(ctx: *anyopaque, ev: *const model.document.ChangeEvent) void {
        const e: *Entry = @ptrCast(@alignCast(ctx));
        for (e.changes.items) |c| c.onChange(ev) catch {};
    }

    /// Frees resolved changes and documents left without any.
    fn sweep(pe: *PendingEdits) void {
        var i: usize = pe.docs.items.len;
        while (i > 0) {
            i -= 1;
            const e = pe.docs.items[i];
            var j: usize = e.changes.items.len;
            while (j > 0) {
                j -= 1;
                if (e.changes.items[j].resolved()) e.changes.orderedRemove(j).destroy();
            }
            if (e.changes.items.len == 0) pe.dropEntry(i);
        }
    }

    fn changed(pe: *PendingEdits) void {
        if (pe.on_change) |h| h.f(h.ctx);
    }

    /// The hunk of `view`'s document at `offset` (on its old text or at
    /// its insertion point), else the nearest one after it.
    fn hunkAt(pe: *PendingEdits, view: *const EditorView, offset: u64) ?struct { change: *PendingChange, id: u32 } {
        const e = pe.entryOfView(view) orelse return null;
        var best: ?struct { change: *PendingChange, id: u32, start: u64 } = null;
        for (e.changes.items) |c| for (c.hunks()) |h| {
            if (h.state != .pending and h.state != .conflicted) continue;
            const r = h.old_range;
            if (offset >= r.start and offset <= r.end) return .{ .change = c, .id = h.id };
            if (r.start > offset and (best == null or r.start < best.?.start)) best = .{ .change = c, .id = h.id, .start = r.start };
        };
        const b = best orelse return null;
        return .{ .change = b.change, .id = b.id };
    }

    pub const Result = enum { none, done, conflicted };

    /// Accepts the hunk at `view`'s caret.
    pub fn acceptAt(pe: *PendingEdits, view: *const EditorView) Result {
        const at = pe.hunkAt(view, view.primarySel().head) orelse return .none;
        defer pe.after();
        at.change.acceptHunk(at.id) catch |err| return if (err == error.Conflicted) .conflicted else .none;
        return .done;
    }

    /// Rejects the hunk at `view`'s caret.
    pub fn rejectAt(pe: *PendingEdits, view: *const EditorView) Result {
        const at = pe.hunkAt(view, view.primarySel().head) orelse return .none;
        defer pe.after();
        at.change.rejectHunk(at.id);
        return .done;
    }

    /// Accepts every pending hunk of `view`'s document (conflicted ones
    /// stay).
    pub fn acceptAll(pe: *PendingEdits, view: *const EditorView) Result {
        const e = pe.entryOfView(view) orelse return .none;
        defer pe.after();
        var conflicted = false;
        // Accepting one change moves the others; they rebase as it lands.
        for (e.changes.items) |c| {
            c.acceptAll() catch {};
            if (!c.resolved()) conflicted = true;
        }
        return if (conflicted) .conflicted else .done;
    }

    /// Rejects every hunk of `view`'s document.
    pub fn rejectAll(pe: *PendingEdits, view: *const EditorView) Result {
        const e = pe.entryOfView(view) orelse return .none;
        defer pe.after();
        for (e.changes.items) |c| c.rejectAll();
        return .done;
    }

    fn after(pe: *PendingEdits) void {
        pe.sweep();
        pe.changed();
    }

    /// The header row above a hunk and the rows of its new text.
    fn paintBlock(ctx: ?*anyopaque, pc: *zg_gui.paint.PaintCx, rect: zg_gui.core.Rect, b: BlockInfo) void {
        const e: *Entry = @ptrCast(@alignCast(ctx.?));
        const v = e.view;
        const st = v.textStyle();
        const m = pc.text_sys.metrics(st);
        const lh = v.lineHeight();
        const base = (lh - (m.ascent + m.descent)) / 2 + m.ascent;
        const hunk = findHunk(e, b) orelse return pc.rect(rect, pc.color(.bg_base), .{});
        if (b.above) {
            const conflicted = hunk.h.state == .conflicted;
            const tone = pc.color(if (conflicted) .warning else .accent);
            pc.rect(rect, tone.fade(0.12), .{});
            pc.rect(.{ .x = rect.x, .y = rect.y, .w = 2, .h = rect.h }, tone, .{});
            var buf: [256]u8 = undefined;
            const s = if (conflicted)
                std.fmt.bufPrint(&buf, "{s}: you changed this text; reject it or ask again", .{hunk.label}) catch hunk.label
            else
                std.fmt.bufPrint(&buf, "{s}: Accept or Reject Agent Change (command palette)", .{hunk.label}) catch hunk.label;
            pc.textLine(s, st, pc.color(.fg).fade(0.75), .{ .x = rect.x + 8, .y = rect.y + base });
            return;
        }
        const ok = pc.color(.success);
        pc.rect(rect, ok.fade(0.14), .{});
        var it = std.mem.splitScalar(u8, hunk.h.new_text, '\n');
        var y = rect.y;
        while (it.next()) |line| : (y += lh) {
            if (y >= rect.y + rect.h) break;
            pc.textLine(line, st, pc.color(.fg), .{ .x = rect.x + 4, .y = y + base });
        }
    }

    fn findHunk(e: *Entry, b: BlockInfo) ?struct { h: model.decorations.pending.PendingHunk, label: []const u8 } {
        for (e.changes.items) |c| {
            if (c.owner != b.owner) continue;
            for (c.hunks()) |h| if (h.id == b.payload) return .{ .h = h, .label = c.label };
        }
        return null;
    }
};

const testing = std.testing;

test "PendingEdits: places, rebases, accepts and rejects at the caret" {
    const gpa = testing.allocator;
    const doc = try Document.initBytes(gpa, @enumFromInt(1), "one\ntwo\nthree\n");
    defer doc.deinit();
    const view = try EditorView.init(gpa, doc, .{});
    defer view.deinit();
    const handle: DocHandle = .{ .id = @enumFromInt(1), .gen = 1 };

    const R = struct {
        v: *EditorView,
        fn get(ctx: *anyopaque, _: DocHandle) ?*EditorView {
            const r: *@This() = @ptrCast(@alignCast(ctx));
            return r.v;
        }
    };
    var r: R = .{ .v = view };
    var pe: PendingEdits = .init(gpa, .{ .ctx = &r, .view = R.get });
    defer pe.deinit();
    try testing.expect(pe.canPlace(handle));

    // Two hunks: "two" -> "TWO" and "three" -> "3".
    const host = pe.host();
    const pl = host.place(host.ctx, handle).?;
    var cs = try model.edit.change_set.ChangeSet.fromEdits(gpa, doc.len(), &.{
        .{ .range = .{ .start = 4, .end = 7 }, .text = "TWO" },
        .{ .range = .{ .start = 8, .end = 13 }, .text = "3" },
    });
    defer cs.deinit();
    const change = try PendingChange.create(gpa, doc, pl.store, pl.owner, &cs, doc.version, "Agent 1 edit", .{ .agent = 1 }, .{});
    host.created(host.ctx, handle, change);
    try testing.expect(view.decorations != null and view.block_painter != null);
    try testing.expectEqual(@as(usize, 1), pe.count());

    // The user types above both hunks; they move with the text.
    var typed = try model.edit.change_set.ChangeSet.fromEdits(gpa, doc.len(), &.{.{ .range = .{ .start = 0, .end = 0 }, .text = "zero\n" }});
    defer typed.deinit();
    try doc.applyChangeSet(&typed, .{ .user = 0 });
    view.setSelection(.caret(10));
    try testing.expectEqual(PendingEdits.Result.done, pe.acceptAt(view));
    {
        const got = try doc.tree.copyRange(gpa, .{ .start = 0, .end = doc.len() });
        defer gpa.free(got);
        try testing.expectEqualStrings("zero\none\nTWO\nthree\n", got);
    }
    // The other hunk is the next one after the caret.
    try testing.expectEqual(PendingEdits.Result.done, pe.rejectAt(view));
    try testing.expectEqual(@as(usize, 0), pe.count());
    // Nothing left: the editor draws no store again.
    try testing.expect(view.decorations == null and view.block_painter == null);
    try testing.expectEqual(PendingEdits.Result.none, pe.acceptAt(view));
}
