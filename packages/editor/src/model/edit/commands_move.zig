//! Movement and delete-by-unit commands over a `SelectionSet`, with the
//! stable command ids E15 registers (`cursor.*`, `delete.*`). Moving
//! without `select` collapses a range to its start (backward) or end
//! (forward) for horizontal units; vertical units keep `goal_x`.

const std = @import("std");
const movement = @import("movement.zig");
const sel_mod = @import("selection.zig");
const runner = @import("runner.zig");
const document = @import("../document.zig");
const snapshot_mod = @import("../snapshot.zig");

const Unit = movement.Unit;
const Dir = movement.Dir;
const MoveContext = movement.MoveContext;
const Selection = sel_mod.Selection;
const SelectionSet = sel_mod.SelectionSet;
const Document = document.Document;
const EditOrigin = document.EditOrigin;
const Snapshot = snapshot_mod.Snapshot;

/// A cursor command: move every selection's head by `unit`.
pub const MoveCommand = struct { id: []const u8, unit: Unit, dir: Dir, select: bool = false };

/// A delete command: delete from each caret by `unit` (a range deletes
/// itself).
pub const DeleteCommand = struct { id: []const u8, unit: Unit, dir: Dir };

/// Every cursor command and its `select` variant (`cursor.leftSelect`).
pub const move_commands = blk: {
    const base = [_]MoveCommand{
        .{ .id = "cursor.left", .unit = .grapheme, .dir = .backward },
        .{ .id = "cursor.right", .unit = .grapheme, .dir = .forward },
        .{ .id = "cursor.up", .unit = .display_row, .dir = .backward },
        .{ .id = "cursor.down", .unit = .display_row, .dir = .forward },
        .{ .id = "cursor.wordLeft", .unit = .word, .dir = .backward },
        .{ .id = "cursor.wordRight", .unit = .word, .dir = .forward },
        .{ .id = "cursor.subwordLeft", .unit = .subword, .dir = .backward },
        .{ .id = "cursor.subwordRight", .unit = .subword, .dir = .forward },
        .{ .id = "cursor.home", .unit = .line_boundary, .dir = .backward },
        .{ .id = "cursor.end", .unit = .line_boundary, .dir = .forward },
        .{ .id = "cursor.smartHome", .unit = .smart_home, .dir = .backward },
        .{ .id = "cursor.pageUp", .unit = .page, .dir = .backward },
        .{ .id = "cursor.pageDown", .unit = .page, .dir = .forward },
        .{ .id = "cursor.top", .unit = .document, .dir = .backward },
        .{ .id = "cursor.bottom", .unit = .document, .dir = .forward },
        .{ .id = "cursor.matchingBracket", .unit = .bracket, .dir = .forward },
    };
    var all: [base.len * 2]MoveCommand = undefined;
    for (base, 0..) |c, i| {
        all[2 * i] = c;
        all[2 * i + 1] = .{ .id = c.id ++ "Select", .unit = c.unit, .dir = c.dir, .select = true };
    }
    break :blk all;
};

/// The delete commands (`delete.line` is `deleteLines`).
pub const delete_commands = [_]DeleteCommand{
    .{ .id = "delete.left", .unit = .grapheme, .dir = .backward },
    .{ .id = "delete.right", .unit = .grapheme, .dir = .forward },
    .{ .id = "delete.wordLeft", .unit = .word, .dir = .backward },
    .{ .id = "delete.wordRight", .unit = .word, .dir = .forward },
    .{ .id = "delete.subwordLeft", .unit = .subword, .dir = .backward },
    .{ .id = "delete.subwordRight", .unit = .subword, .dir = .forward },
    .{ .id = "delete.toLineStart", .unit = .line_boundary, .dir = .backward },
    .{ .id = "delete.toLineEnd", .unit = .line_boundary, .dir = .forward },
};

/// The command with id `id`.
pub fn moveCommand(id: []const u8) ?MoveCommand {
    for (move_commands) |c| if (std.mem.eql(u8, c.id, id)) return c;
    return null;
}

/// Moves every selection's head by `unit`; with `select` the anchor
/// stays, otherwise the selection becomes a caret. Normalizes after.
pub fn moveSelections(snap: *const Snapshot, sels: *SelectionSet, unit: Unit, dir: Dir, select: bool, ctx: MoveContext) void {
    const vertical = movement.isVertical(unit);
    for (sels.items.items) |*s| {
        if (!select and !s.isCaret() and !vertical and unit == .grapheme) {
            // Left/Right on a range collapse it without moving.
            const at = if (dir == .backward) s.start() else s.end();
            s.anchor = at;
            s.head = at;
            s.goal_x = null;
            s.virtual = 0;
            continue;
        }
        var c = ctx;
        var goal: ?f32 = null;
        if (vertical) {
            goal = s.goal_x orelse movement.goalOf(snap, s.head, ctx);
            c.goal_x = goal;
        }
        const to = movement.move(snap, s.head, unit, dir, c);
        s.head = to;
        if (!select) s.anchor = to;
        s.goal_x = goal;
        s.virtual = 0;
    }
    sels.normalize(.for_display);
}

/// Options for delete commands.
pub const DeleteOptions = struct {
    ctx: MoveContext = .{},
    /// `editor.useTabStops`: Backspace in leading spaces deletes back to
    /// the previous tab stop.
    use_tab_stops: bool = true,
};

const DeleteCtx = struct { unit: Unit, dir: Dir, o: DeleteOptions };

fn deleteOne(ctx_ptr: *anyopaque, snap: *const Snapshot, sel: Selection, out: *runner.EditBuilder) anyerror!void {
    const c: *const DeleteCtx = @ptrCast(@alignCast(ctx_ptr));
    if (!sel.isCaret()) {
        _ = try out.delete(sel.range());
        out.select(.{ .in_edit = .{ .edit = 0 } });
        return;
    }
    var to = movement.move(snap, sel.head, c.unit, c.dir, c.o.ctx);
    if (c.unit == .grapheme and c.dir == .backward and c.o.use_tab_stops) {
        if (tabStopBack(snap, sel.head, c.o.ctx.tab_size)) |t| to = t;
    }
    if (to == sel.head) return;
    _ = try out.delete(.{ .start = @min(to, sel.head), .end = @max(to, sel.head) });
    out.select(.{ .in_edit = .{ .edit = 0 } });
}

/// Where Backspace at `pos` stops when only spaces precede it on its
/// line: the previous tab stop (at least one space back). Null otherwise.
pub fn tabStopBack(snap: *const Snapshot, pos: u64, tab_size: u8) ?u64 {
    const t = &snap.tree;
    const ls = t.lineStart(t.lineOf(pos));
    const col = pos - ls;
    if (col == 0 or col > 4096) return null;
    var buf: [4096]u8 = undefined;
    var n: usize = 0;
    var it = t.slice(.{ .start = ls, .end = pos });
    while (it.next()) |chunk| {
        @memcpy(buf[n..][0..chunk.len], chunk);
        n += chunk.len;
    }
    for (buf[0..n]) |b| if (b != ' ') return null;
    const ts: u64 = @max(tab_size, 1);
    const back = (col - 1) % ts + 1;
    return pos - back;
}

/// Deletes by `unit` from every caret (ranges delete themselves), as one
/// change. Selections are first merged for editing.
pub fn deleteBy(doc: *Document, sels: *SelectionSet, unit: Unit, dir: Dir, o: DeleteOptions, origin: EditOrigin) !runner.RunResult {
    sels.normalize(.for_edit);
    var c: DeleteCtx = .{ .unit = unit, .dir = dir, .o = o };
    return runner.runPerSelection(doc, sels, deleteOne, &c, origin);
}

/// The lines a selection touches (a range ending at column 0 leaves that
/// line out).
fn linesOf(t: anytype, sel: Selection) struct { u64, u64 } {
    const l0 = t.lineOf(sel.start());
    var l1 = t.lineOf(sel.end());
    if (l1 > l0 and sel.end() == t.lineStart(l1)) l1 -= 1;
    return .{ l0, l1 };
}

fn deleteLineOne(_: *anyopaque, snap: *const Snapshot, sel: Selection, out: *runner.EditBuilder) anyerror!void {
    const t = &snap.tree;
    const l0, const l1 = linesOf(t, sel);
    var start = t.lineStart(l0);
    var end = if (l1 + 1 < t.lineCount()) t.lineStart(l1 + 1) else t.len();
    // The last line has no EOL to take: take the one before it instead.
    if (l1 + 1 >= t.lineCount() and l0 > 0) start = t.lineRange(l0 - 1).end;
    if (end < start) end = start;
    _ = try out.delete(.{ .start = start, .end = end });
}

/// `delete.line`: deletes every line a selection touches, with its EOL.
/// Selections on the same or adjacent lines are merged first.
pub fn deleteLines(doc: *Document, sels: *SelectionSet, origin: EditOrigin) !runner.RunResult {
    {
        var snap = doc.snapshot();
        defer snap.release();
        const t = &snap.tree;
        var spans: std.ArrayList(Selection) = .empty;
        defer spans.deinit(sels.gpa);
        var prim: usize = 0;
        const pi = sels.primaryIndex();
        for (sels.slice(), 0..) |s, i| {
            const l0, const l1 = linesOf(t, s);
            if (spans.items.len > 0) {
                const last = &spans.items[spans.items.len - 1];
                const pl0, const pl1 = linesOf(t, last.*);
                _ = pl0;
                if (l0 <= pl1 + 1) {
                    last.head = @max(last.head, t.lineRange(l1).end);
                    if (i == pi) prim = spans.items.len - 1;
                    continue;
                }
            }
            if (i == pi) prim = spans.items.len;
            try spans.append(sels.gpa, .{ .anchor = t.lineStart(l0), .head = t.lineRange(l1).end });
        }
        try sels.set(spans.items, prim);
    }
    var dummy: u8 = 0;
    return runner.runPerSelection(doc, sels, deleteLineOne, &dummy, origin);
}
