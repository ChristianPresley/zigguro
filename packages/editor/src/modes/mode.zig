//! The seam between an editor and a modal input handler (Vim, Emacs).
//!
//! A `ModeHandler` gets first refusal on every key; keys it passes
//! through go to the normal keybindings (so the command palette still
//! opens from Vim normal mode). Handlers edit through a `Host`: the
//! document, its selections and its undo tree, plus the settings smart
//! typing and movement need. The editor view builds the host from itself.
//!
//! `ChangeGroup` gives a handler control over undo grouping: every
//! document change between `begin` and `commit` becomes one undo step,
//! however many edits it took (a Vim change including its insert session).

const std = @import("std");
const key_mod = @import("key.zig");
const document = @import("../model/document.zig");
const sel_mod = @import("../model/edit/selection.zig");
const undo_mod = @import("../model/edit/undo.zig");
const cs_mod = @import("../model/edit/change_set.zig");
const smart_edit = @import("../model/edit/smart_edit.zig");
const movement = @import("../model/edit/movement.zig");
const zg_syntax = @import("zg_syntax");

const Allocator = std.mem.Allocator;
const Document = document.Document;
const ChangeEvent = document.ChangeEvent;
const Selection = sel_mod.Selection;
const SelectionSet = sel_mod.SelectionSet;
const UndoTree = undo_mod.UndoTree;
const ChangeSet = cs_mod.ChangeSet;
pub const Key = key_mod.Key;

/// How the caret is drawn.
pub const CaretShape = enum { bar, block, underline, half_block };

pub const KeyResult = enum { consumed, passthrough };

/// File and window commands a mode asks the editor for (`:w`, `:q`,
/// `:e`; Emacs `C-x C-s`).
pub const Action = union(enum) {
    write: struct { path: ?[]const u8 = null, force: bool = false },
    /// Close the editor (`:q`); `force` discards changes.
    quit: struct { force: bool = false },
    /// Write when modified, then close (`:x`).
    exit,
    edit: struct { path: ?[]const u8 = null, force: bool = false },
};

pub const Actions = struct {
    ctx: *anyopaque,
    runFn: *const fn (ctx: *anyopaque, a: Action) anyerror!void,
};

/// What a mode edits.
pub const Host = struct {
    doc: *Document,
    sels: *SelectionSet,
    undo: *UndoTree,
    edit: smart_edit.EditCtx = .{},
    move: movement.MoveContext = .{},
    brackets: ?*const zg_syntax.BracketTree = null,
    /// For undo timestamps; null records time zero.
    io: ?std.Io = null,
    /// Runs `:w`, `:q` and the like; null when the editor has none.
    actions: ?Actions = null,

    pub fn now(h: *const Host) std.Io.Timestamp {
        const io = h.io orelse return .{ .nanoseconds = 0 };
        return std.Io.Timestamp.now(io, .real);
    }

    /// Spaces per indentation level and whether to use tabs.
    pub fn indentUnit(h: *const Host) @import("../model/edit/indent.zig").IndentUnit {
        return h.edit.indentUnit();
    }
};

/// A modal input handler.
pub const ModeHandler = struct {
    ctx: *anyopaque,
    handleKeyFn: *const fn (ctx: *anyopaque, k: Key, host: *Host) anyerror!KeyResult,
    statusTextFn: *const fn (ctx: *anyopaque) []const u8,
    caretShapeFn: *const fn (ctx: *anyopaque) CaretShape,

    pub fn handleKey(m: ModeHandler, k: Key, host: *Host) !KeyResult {
        return m.handleKeyFn(m.ctx, k, host);
    }

    pub fn statusText(m: ModeHandler) []const u8 {
        return m.statusTextFn(m.ctx);
    }

    pub fn caretShape(m: ModeHandler) CaretShape {
        return m.caretShapeFn(m.ctx);
    }
};

/// Collects the document changes of one command into a single undo step.
/// Subscribe `listener()` to the document; changes outside `begin` and
/// `commit` are ignored (whoever made them records them).
pub const ChangeGroup = struct {
    gpa: Allocator,
    active: bool = false,
    forward: ?ChangeSet = null,
    inverse: ?ChangeSet = null,
    sel_before: std.ArrayList(Selection) = .empty,
    /// Set when composing failed; the group is dropped.
    failed: bool = false,

    pub fn init(gpa: Allocator) ChangeGroup {
        return .{ .gpa = gpa };
    }

    pub fn deinit(g: *ChangeGroup) void {
        g.reset();
        g.sel_before.deinit(g.gpa);
    }

    pub fn listener(g: *ChangeGroup) document.Listener {
        return .{ .ctx = g, .onChange = onChange };
    }

    /// Starts collecting; `sels` are restored when the step is undone.
    /// A group already open stays open.
    pub fn begin(g: *ChangeGroup, sels: []const Selection) Allocator.Error!void {
        if (g.active) return;
        g.sel_before.clearRetainingCapacity();
        try g.sel_before.appendSlice(g.gpa, sels);
        g.active = true;
        g.failed = false;
    }

    /// Records what was collected as one undo step (nothing if nothing
    /// changed) and stops collecting.
    pub fn commit(g: *ChangeGroup, undo: *UndoTree, sels_after: []const Selection, meta: undo_mod.GroupMeta) Allocator.Error!void {
        if (!g.active) return;
        g.active = false;
        if (g.failed or g.forward == null) return g.reset();
        const f = g.forward.?;
        const inv = g.inverse.?;
        g.forward = null;
        g.inverse = null;
        undo.breakGroup();
        try undo.record(f, inv, g.sel_before.items, sels_after, meta);
        undo.breakGroup();
    }

    /// Stops collecting without recording.
    pub fn cancel(g: *ChangeGroup) void {
        g.active = false;
        g.reset();
    }

    fn reset(g: *ChangeGroup) void {
        if (g.forward) |*f| f.deinit();
        if (g.inverse) |*i| i.deinit();
        g.forward = null;
        g.inverse = null;
    }

    fn onChange(ctx: *anyopaque, ev: *const ChangeEvent) void {
        const g: *ChangeGroup = @ptrCast(@alignCast(ctx));
        if (!g.active or g.failed) return;
        g.add(ev) catch {
            g.failed = true;
            g.reset();
        };
    }

    fn add(g: *ChangeGroup, ev: *const ChangeEvent) Allocator.Error!void {
        var inv = try ev.changes.invert(ev.before, g.gpa);
        errdefer inv.deinit();
        if (g.forward) |*f| {
            var nf = try f.compose(ev.changes, g.gpa);
            errdefer nf.deinit();
            const ni = try inv.compose(&g.inverse.?, g.gpa);
            inv.deinit();
            f.deinit();
            g.inverse.?.deinit();
            g.forward = nf;
            g.inverse = ni;
        } else {
            g.forward = try ev.changes.clone(g.gpa);
            g.inverse = inv;
        }
    }
};

test "mode: change group records one step" {
    const gpa = std.testing.allocator;
    const doc = try Document.initBytes(gpa, @enumFromInt(1), "abc");
    defer doc.deinit();
    var undo: UndoTree = .init(gpa, .{});
    defer undo.deinit();
    var g: ChangeGroup = .init(gpa);
    defer g.deinit();
    _ = try doc.subscribe(g.listener());
    try g.begin(&.{.caret(0)});
    for ([_][]const u8{ "x", "y", "z" }) |t| {
        var cs = try ChangeSet.fromEdits(gpa, doc.len(), &.{.{ .range = .{ .start = 1, .end = 1 }, .text = t }});
        defer cs.deinit();
        try doc.applyChangeSet(&cs, .{ .user = 0 });
    }
    try g.commit(&undo, &.{.caret(4)}, .{ .origin = .{ .user = 0 }, .timestamp = .{ .nanoseconds = 0 } });
    try std.testing.expectEqual(@as(usize, 1), undo.nodes().len - 1);
    const step = undo.undo().?;
    try doc.applyChangeSet(step.changes, .undo);
    const t = try doc.tree.copyRange(gpa, .{ .start = 0, .end = doc.len() });
    defer gpa.free(t);
    try std.testing.expectEqualStrings("abc", t);
    try std.testing.expectEqual(@as(u64, 0), step.selections[0].head);
}
