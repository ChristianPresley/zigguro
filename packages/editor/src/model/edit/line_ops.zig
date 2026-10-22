//! Line operations over every selection, each one change: move, duplicate,
//! sort, reverse and transpose whole lines (each line keeps its EOL), join,
//! indent/outdent, case transforms, transpose characters and trimming
//! trailing whitespace. Lines touched by several selections are handled
//! once per block.

const std = @import("std");
const zg_text = @import("zg_text");
const sel_mod = @import("selection.zig");
const cs_mod = @import("change_set.zig");
const runner = @import("runner.zig");
const indent = @import("indent.zig");
const smart = @import("smart_edit.zig");
const cmds = @import("commands_move.zig");
const document = @import("../document.zig");
const snapshot_mod = @import("../snapshot.zig");
const pt = @import("../buffer/piece_tree.zig");

const Allocator = std.mem.Allocator;
const Selection = sel_mod.Selection;
const SelectionSet = sel_mod.SelectionSet;
const ChangeSet = cs_mod.ChangeSet;
const Replace = cs_mod.Replace;
const Document = document.Document;
const EditOrigin = document.EditOrigin;
const Snapshot = snapshot_mod.Snapshot;
const PieceTree = pt.PieceTree;
const EditCtx = smart.EditCtx;
const casemap = zg_text.unicode.casemap;
const grapheme = zg_text.unicode.grapheme;
const word = zg_text.unicode.word;

pub const LineOp = enum {
    move_up,
    move_down,
    duplicate_up,
    duplicate_down,
    join,
    sort_asc,
    sort_desc,
    sort_unique,
    reverse,
    transpose_chars,
    transpose_lines,
    delete_line,
    indent,
    outdent,
    upper,
    lower,
    title,
    trim_trailing_ws,
};

/// Command ids for keybindings (`editor.*`), one per `LineOp`.
pub const command_ids = std.enums.EnumArray(LineOp, []const u8).init(.{
    .move_up = "editor.moveLinesUp",
    .move_down = "editor.moveLinesDown",
    .duplicate_up = "editor.copyLinesUp",
    .duplicate_down = "editor.copyLinesDown",
    .join = "editor.joinLines",
    .sort_asc = "editor.sortLinesAscending",
    .sort_desc = "editor.sortLinesDescending",
    .sort_unique = "editor.sortLinesUnique",
    .reverse = "editor.reverseLines",
    .transpose_chars = "editor.transpose",
    .transpose_lines = "editor.transposeLines",
    .delete_line = "editor.deleteLines",
    .indent = "editor.indentLines",
    .outdent = "editor.outdentLines",
    .upper = "editor.transformToUppercase",
    .lower = "editor.transformToLowercase",
    .title = "editor.transformToTitlecase",
    .trim_trailing_ws = "editor.trimTrailingWhitespace",
});

/// Runs `op` at every selection as one change. Returns whether the
/// document changed.
pub fn lineOp(doc: *Document, sels: *SelectionSet, op: LineOp, ctx: EditCtx) !bool {
    return switch (op) {
        .move_up, .move_down, .duplicate_up, .duplicate_down => moveOp(doc, sels, op, ctx.origin),
        .sort_asc, .sort_desc, .sort_unique, .reverse, .transpose_lines => permuteOp(doc, sels, op, ctx.origin),
        .join => join(doc, sels, ctx.origin),
        .delete_line => (try cmds.deleteLines(doc, sels, ctx.origin)).changed,
        .indent, .outdent => shift(doc, sels, op == .indent, ctx),
        .upper, .lower, .title => caseOp(doc, sels, op, ctx.origin),
        .transpose_chars => transposeChars(doc, sels, ctx.origin),
        .trim_trailing_ws => trimTrailing(doc, sels, ctx.origin),
    };
}

// -- blocks -------------------------------------------------------------------

/// Lines `[first, last]` touched by selections `[sel_lo, sel_hi)`.
const Block = struct { first: u64, last: u64, sel_lo: usize, sel_hi: usize };

fn linesOf(t: *const PieceTree, s: Selection) struct { u64, u64 } {
    const l0 = t.lineOf(s.start());
    var l1 = t.lineOf(s.end());
    if (l1 > l0 and s.end() == t.lineStart(l1)) l1 -= 1;
    return .{ l0, l1 };
}

/// Merged line blocks of the (sorted) selections; `adjacent` also merges
/// blocks with no line between them.
fn blocks(gpa: Allocator, t: *const PieceTree, sels: []const Selection, adjacent: bool) Allocator.Error!std.ArrayList(Block) {
    var out: std.ArrayList(Block) = .empty;
    errdefer out.deinit(gpa);
    for (sels, 0..) |s, i| {
        const l0, const l1 = linesOf(t, s);
        if (out.items.len > 0) {
            const last = &out.items[out.items.len - 1];
            if (l0 <= last.last + @intFromBool(adjacent)) {
                last.last = @max(last.last, l1);
                last.sel_hi = i + 1;
                continue;
            }
        }
        try out.append(gpa, .{ .first = l0, .last = l1, .sel_lo = i, .sel_hi = i + 1 });
    }
    return out;
}

// -- permutations ---------------------------------------------------------------

const Line = struct { start: u64, text: []const u8, eol: []const u8 };

/// Lines `[r0, r1]` with their text and EOL, copied into `a`.
fn readLines(a: Allocator, t: *const PieceTree, r0: u64, r1: u64) Allocator.Error![]Line {
    const start = t.lineStart(r0);
    const lr = t.lineRange(r1);
    const bytes = try t.copyRange(a, .{ .start = start, .end = lr.end + lr.eol_len });
    const lines = try a.alloc(Line, @intCast(r1 - r0 + 1));
    for (lines, 0..) |*ln, i| {
        const r = t.lineRange(r0 + i);
        const s: usize = @intCast(r.start - start);
        const e: usize = @intCast(r.end - start);
        ln.* = .{ .start = r.start, .text = bytes[s..e], .eol = bytes[e .. e + r.eol_len] };
    }
    return lines;
}

/// Writes `lines` in `order`. Each line keeps its EOL, except that the
/// document's last line (which has none) stays last: whichever line lands
/// last loses its EOL and an EOL-less line elsewhere gets the block's.
fn emit(a: Allocator, lines: []const Line, order: []const u32, starts: []u64) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    const at_end = lines[lines.len - 1].eol.len == 0;
    var default_eol: []const u8 = "\n";
    for (lines) |ln| if (ln.eol.len > 0) {
        default_eol = ln.eol;
        break;
    };
    for (order, 0..) |oi, i| {
        starts[i] = out.items.len;
        const ln = lines[oi];
        try out.appendSlice(a, ln.text);
        var eol = ln.eol;
        if (at_end) {
            if (i == order.len - 1) eol = "" else if (eol.len == 0) eol = default_eol;
        }
        try out.appendSlice(a, eol);
    }
    return out.items;
}

/// One block's rewrite: lines `[r0, r1]` become `order` (old relative line
/// per new line); selections on old line k go to new line `target[k]`.
const Plan = struct { r0: u64, r1: u64, order: []u32, target: []u32 };

fn planFor(a: Allocator, t: *const PieceTree, op: LineOp, b: Block) !?struct { Plan, []Line } {
    var r0 = b.first;
    const r1 = b.last;
    switch (op) {
        .transpose_lines => {
            if (b.first == 0) return null;
            r0 -= 1;
        },
        .sort_asc, .sort_desc, .sort_unique, .reverse => if (r0 == r1) return null,
        else => unreachable,
    }
    const lines = try readLines(a, t, r0, r1);
    const n: u32 = @intCast(lines.len);
    var order: std.ArrayList(u32) = .empty;
    const target = try a.alloc(u32, n);
    switch (op) {
        .transpose_lines => {
            // Swap the block with the line above; selections keep their
            // line numbers (Emacs transpose-lines without the point move).
            for (1..n) |k| try order.append(a, @intCast(k));
            try order.append(a, 0);
            for (target, 0..) |*x, k| x.* = @intCast(k);
        },
        .reverse => {
            var k = n;
            while (k > 0) {
                k -= 1;
                try order.append(a, k);
            }
            for (target, 0..) |*x, k2| x.* = @intCast(k2);
        },
        .sort_asc, .sort_desc, .sort_unique => {
            for (0..n) |k| try order.append(a, @intCast(k));
            const Ctx = struct {
                lines: []const Line,
                desc: bool,
                fn lt(c: @This(), x: u32, y: u32) bool {
                    const o = std.mem.order(u8, c.lines[x].text, c.lines[y].text);
                    return if (c.desc) o == .gt else o == .lt;
                }
            };
            // Stable, so equal lines keep their order (sort_unique keeps
            // the first).
            std.mem.sort(u32, order.items, Ctx{ .lines = lines, .desc = op == .sort_desc }, Ctx.lt);
            if (op == .sort_unique) {
                var w: usize = 0;
                for (order.items) |oi| {
                    if (w > 0 and std.mem.eql(u8, lines[order.items[w - 1]].text, lines[oi].text)) continue;
                    order.items[w] = oi;
                    w += 1;
                }
                order.shrinkRetainingCapacity(w);
            }
            // Selections keep their line numbers (VS Code).
            for (target, 0..) |*x, k| x.* = @intCast(@min(k, order.items.len - 1));
            if (isIdentity(order.items, n)) return null;
        },
        else => unreachable,
    }
    return .{ .{ .r0 = r0, .r1 = r1, .order = order.items, .target = target }, lines };
}

fn isIdentity(order: []const u32, n: u32) bool {
    if (order.len != n) return false;
    for (order, 0..) |x, i| if (x != i) return false;
    return true;
}

fn permuteOp(doc: *Document, sels: *SelectionSet, op: LineOp, origin: EditOrigin) !bool {
    const gpa = sels.gpa;
    var snap = doc.snapshot();
    defer snap.release();
    const t = &snap.tree;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var bl = try blocks(gpa, t, sels.slice(), true);
    defer bl.deinit(gpa);

    var edits: std.ArrayList(Replace) = .empty;
    defer edits.deinit(gpa);
    // New positions of every selection, relative to its block's new start
    // (null: the block did not change and the selection maps).
    const rel = try a.alloc(?[2]u64, sels.count());
    @memset(rel, null);
    const block_of = try a.alloc(u32, sels.count());
    var starts_new: std.ArrayList(u64) = .empty; // new start of each edit, filled after
    for (bl.items) |b| {
        const p, const lines = (try planFor(a, t, op, b)) orelse continue;
        const starts = try a.alloc(u64, p.order.len);
        const text = try emit(a, lines, p.order, starts);
        const r_start = lines[0].start;
        const last = lines[lines.len - 1];
        const r_end = last.start + last.text.len + last.eol.len;
        const ei: u32 = @intCast(edits.items.len);
        try edits.append(gpa, .{ .range = .{ .start = r_start, .end = r_end }, .text = text });
        try starts_new.append(a, 0);
        for (b.sel_lo..b.sel_hi) |si| {
            const s = sels.slice()[si];
            var out: [2]u64 = undefined;
            for ([2]u64{ s.anchor, s.head }, 0..) |pos, j| {
                const k: usize = @intCast(t.lineOf(pos) - p.r0);
                if (k >= lines.len) {
                    // A range ending at the start of the next line.
                    out[j] = text.len;
                    continue;
                }
                const col = pos - lines[k].start;
                const nl = p.target[k];
                const new_len = lines[p.order[nl]].text.len;
                // A position at the end of its line stays at the end.
                out[j] = starts[nl] + if (col >= lines[k].text.len) new_len else @min(col, new_len);
            }
            rel[si] = out;
            block_of[si] = ei;
        }
    }
    if (edits.items.len == 0) return false;
    var cs = try ChangeSet.fromEdits(gpa, doc.len(), edits.items);
    defer cs.deinit();
    try doc.applyChangeSet(&cs, origin);
    // Edit i's new start: its old start plus the growth of edits before it.
    var delta: i128 = 0;
    for (edits.items, 0..) |e, i| {
        starts_new.items[i] = @intCast(@as(i128, e.range.start) + delta);
        delta += @as(i128, @intCast(e.text.len)) - @as(i128, @intCast(e.range.end - e.range.start));
    }
    for (sels.items.items, 0..) |*x, si| {
        if (rel[si]) |r| {
            const base = starts_new.items[block_of[si]];
            x.anchor = base + r[0];
            x.head = base + r[1];
            x.goal_x = null;
            x.virtual = 0;
        } else x.* = x.map(&cs);
    }
    sels.normalize(.for_display);
    sels.clearHistory();
    sels.word_search = false;
    return true;
}

// -- move / duplicate ---------------------------------------------------------------

/// Moves or duplicates each block with the fewest edits, leaving the
/// block's own text in place so decorations and anchors on it move with
/// it: moving deletes the neighbouring line and re-inserts it on the other
/// side; duplicating inserts a copy above (down: the selections follow the
/// original, now below) or below (up).
fn moveOp(doc: *Document, sels: *SelectionSet, op: LineOp, origin: EditOrigin) !bool {
    const gpa = sels.gpa;
    var snap = doc.snapshot();
    defer snap.release();
    const t = &snap.tree;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var bl = try blocks(gpa, t, sels.slice(), true);
    defer bl.deinit(gpa);
    const lc = t.lineCount();
    const eol_default = eolOf(t);
    var edits: std.ArrayList(Replace) = .empty;
    defer edits.deinit(gpa);
    // Positions that stay before text inserted at them.
    var pins: std.ArrayList(u64) = .empty;
    defer pins.deinit(gpa);
    for (bl.items) |b| {
        const bs = t.lineStart(b.first);
        const last = t.lineRange(b.last);
        const be = last.end + last.eol_len;
        const b_eol = try t.copyRange(a, .{ .start = last.end, .end = be });
        switch (op) {
            .move_up => {
                if (b.first == 0) continue;
                const x = t.lineRange(b.first - 1);
                const x_text = try t.copyRange(a, .{ .start = x.start, .end = x.end });
                const x_eol = try t.copyRange(a, .{ .start = x.end, .end = x.end + x.eol_len });
                try edits.append(gpa, .{ .range = .{ .start = x.start, .end = bs }, .text = "" });
                // At the end of the document the block takes the line's EOL.
                const ins = if (b_eol.len > 0) try std.mem.concat(a, u8, &.{ x_text, x_eol }) else try std.mem.concat(a, u8, &.{ x_eol, x_text });
                try edits.append(gpa, .{ .range = .{ .start = be, .end = be }, .text = ins });
                try pins.append(gpa, be);
            },
            .move_down => {
                if (b.last + 1 >= lc) continue;
                const x = t.lineRange(b.last + 1);
                const x_text = try t.copyRange(a, .{ .start = x.start, .end = x.end });
                if (x.eol_len > 0) {
                    const x_eol = try t.copyRange(a, .{ .start = x.end, .end = x.end + x.eol_len });
                    try edits.append(gpa, .{ .range = .{ .start = bs, .end = bs }, .text = try std.mem.concat(a, u8, &.{ x_text, x_eol }) });
                    try edits.append(gpa, .{ .range = .{ .start = x.start, .end = x.end + x.eol_len }, .text = "" });
                } else {
                    // The last line: it takes the block's EOL.
                    try edits.append(gpa, .{ .range = .{ .start = bs, .end = bs }, .text = try std.mem.concat(a, u8, &.{ x_text, b_eol }) });
                    try edits.append(gpa, .{ .range = .{ .start = last.end, .end = x.end }, .text = "" });
                }
            },
            .duplicate_down, .duplicate_up => {
                const body = try t.copyRange(a, .{ .start = bs, .end = be });
                if (op == .duplicate_down) {
                    const ins = if (b_eol.len > 0) body else try std.mem.concat(a, u8, &.{ body, eol_default });
                    try edits.append(gpa, .{ .range = .{ .start = bs, .end = bs }, .text = ins });
                } else {
                    const ins = if (b_eol.len > 0) body else try std.mem.concat(a, u8, &.{ eol_default, body });
                    try edits.append(gpa, .{ .range = .{ .start = be, .end = be }, .text = ins });
                    try pins.append(gpa, be);
                }
            },
            else => unreachable,
        }
    }
    if (edits.items.len == 0) return false;
    var cs = try ChangeSet.fromEdits(gpa, doc.len(), edits.items);
    defer cs.deinit();
    try doc.applyChangeSet(&cs, origin);
    for (sels.items.items) |*x| {
        const pinned_a = std.mem.indexOfScalar(u64, pins.items, x.anchor) != null;
        const pinned_h = std.mem.indexOfScalar(u64, pins.items, x.head) != null;
        const m = x.map(&cs);
        if (pinned_a) x.anchor = cs.mapPos(x.anchor, .left) else x.anchor = m.anchor;
        if (pinned_h) x.head = cs.mapPos(x.head, .left) else x.head = m.head;
        x.goal_x = null;
        x.virtual = 0;
    }
    sels.normalize(.for_display);
    sels.clearHistory();
    sels.word_search = false;
    return true;
}

/// The document's EOL: the first line's terminator, else "\n".
fn eolOf(t: *const PieceTree) []const u8 {
    if (t.lineCount() < 2) return "\n";
    const r = t.lineRange(0);
    if (r.eol_len == 2) return "\r\n";
    return if (t.byteAt(r.end) == '\r') "\r" else "\n";
}

// -- join -----------------------------------------------------------------------

/// Joins each block's lines (a one-line block with the next line): the EOL
/// and the next line's indentation become one space, or nothing next to
/// an empty line, after `(` or before `)`. Carets go to the first join.
fn join(doc: *Document, sels: *SelectionSet, origin: EditOrigin) !bool {
    const gpa = sels.gpa;
    var snap = doc.snapshot();
    defer snap.release();
    const t = &snap.tree;
    var bl = try blocks(gpa, t, sels.slice(), false);
    defer bl.deinit(gpa);
    const lc = t.lineCount();
    var edits: std.ArrayList(Replace) = .empty;
    defer edits.deinit(gpa);
    const caret_at = try gpa.alloc(?u64, sels.count());
    defer gpa.free(caret_at);
    @memset(caret_at, null);
    var buf: [4096]u8 = undefined;
    var nbuf: [4096]u8 = undefined;
    for (bl.items) |b| {
        const last = if (b.first == b.last) b.first + 1 else b.last;
        if (last >= lc) continue;
        var first_join: ?u64 = null;
        var l = b.first;
        while (l < last) : (l += 1) {
            const cur = indent.lineText(t, l, &buf);
            const next = indent.lineText(t, l + 1, &nbuf);
            const trimmed = std.mem.trimEnd(u8, cur, " \t");
            const nws = indent.leading(next).len;
            const rest = next[nws..];
            const tight = trimmed.len == 0 or rest.len == 0 or rest[0] == ')' or trimmed[trimmed.len - 1] == '(';
            const js = t.lineStart(l) + trimmed.len;
            try edits.append(gpa, .{ .range = .{ .start = js, .end = t.lineStart(l + 1) + nws }, .text = if (tight) "" else " " });
            if (first_join == null) first_join = js;
        }
        for (b.sel_lo..b.sel_hi) |si| if (sels.slice()[si].isCaret()) {
            caret_at[si] = first_join;
        };
    }
    if (edits.items.len == 0) return false;
    var cs = try ChangeSet.fromEdits(gpa, doc.len(), edits.items);
    defer cs.deinit();
    try doc.applyChangeSet(&cs, origin);
    for (sels.items.items, 0..) |*x, si| {
        if (caret_at[si]) |p| x.* = .{ .anchor = cs.mapPos(p, .left), .head = cs.mapPos(p, .left), .id = x.id } else x.* = x.map(&cs);
    }
    sels.normalize(.for_display);
    sels.clearHistory();
    sels.word_search = false;
    return true;
}

// -- indent / outdent -------------------------------------------------------------

/// Indents (one unit at the line start) or outdents (back to the previous
/// tab stop) every line of every block. Indenting skips empty lines of
/// multi-line blocks.
fn shift(doc: *Document, sels: *SelectionSet, in: bool, ctx: EditCtx) !bool {
    const gpa = sels.gpa;
    var snap = doc.snapshot();
    defer snap.release();
    const t = &snap.tree;
    var bl = try blocks(gpa, t, sels.slice(), false);
    defer bl.deinit(gpa);
    const unit = ctx.indentUnit();
    var ub: [256]u8 = undefined;
    const one = unit.write(unit.size, &ub);
    var edits: std.ArrayList(Replace) = .empty;
    defer edits.deinit(gpa);
    var buf: [4096]u8 = undefined;
    for (bl.items) |b| {
        var l = b.first;
        while (l <= b.last) : (l += 1) {
            const text = indent.lineText(t, l, &buf);
            const ls = t.lineStart(l);
            if (in) {
                if (text.len == 0 and b.first != b.last) continue;
                try edits.append(gpa, .{ .range = .{ .start = ls, .end = ls }, .text = one });
                continue;
            }
            const ws = indent.leading(text);
            if (ws.len == 0) continue;
            var n: usize = 1;
            if (ws[0] == ' ') {
                var spaces: usize = 0;
                while (spaces < ws.len and ws[spaces] == ' ') spaces += 1;
                n = @min(spaces, (spaces - 1) % @max(ctx.tab_size, 1) + 1);
            }
            try edits.append(gpa, .{ .range = .{ .start = ls, .end = ls + n }, .text = "" });
        }
    }
    return runner.applyEdits(doc, sels, edits.items, ctx.origin, .grow);
}

// -- case -------------------------------------------------------------------------

const CaseState = struct { op: LineOp, gpa: Allocator };

fn caseOne(ptr: *anyopaque, snap: *const Snapshot, sel: Selection, out: *runner.EditBuilder) anyerror!void {
    const st: *CaseState = @ptrCast(@alignCast(ptr));
    const t = &snap.tree;
    var range = sel.range();
    var caret_off: ?u64 = null;
    if (sel.isCaret()) {
        // The word under the caret (VS Code).
        var buf: [4096]u8 = undefined;
        const line = t.lineOf(sel.head);
        const ls = t.lineStart(line);
        const text = indent.lineText(t, line, &buf);
        const col: usize = @intCast(@min(sel.head - ls, text.len));
        var w = word.wordAt(text, col);
        if (!wordish(w.kind) and col > 0) w = word.wordAt(text, col - 1);
        if (!wordish(w.kind)) return;
        range = .{ .start = ls + w.start, .end = ls + w.start + w.len };
        caret_off = sel.head - range.start;
    }
    const src = try t.copyRange(st.gpa, range);
    defer st.gpa.free(src);
    var mapped: std.ArrayList(u8) = .empty;
    defer mapped.deinit(st.gpa);
    switch (st.op) {
        .upper => try casemap.toUpper(&mapped, st.gpa, src),
        .lower => try casemap.toLower(&mapped, st.gpa, src),
        .title => try casemap.toTitle(&mapped, st.gpa, src),
        else => unreachable,
    }
    if (std.mem.eql(u8, mapped.items, src)) return;
    _ = try out.replace(range, mapped.items);
    const n: u32 = @intCast(mapped.items.len);
    if (caret_off) |c| {
        out.select(.{ .in_edit = .{ .edit = 0, .delta = @min(@as(u32, @intCast(c)), n) } });
    } else {
        out.select(.{ .range_in_edit = if (sel.head >= sel.anchor) .{ .edit = 0, .anchor = 0, .head = n } else .{ .edit = 0, .anchor = n, .head = 0 } });
    }
}

fn wordish(k: word.WordSpan.Kind) bool {
    return k == .word or k == .number;
}

/// Upper, lower or title case of each selection (a caret: its word). The
/// length may change (`ß` → `SS`); selections cover the new text.
fn caseOp(doc: *Document, sels: *SelectionSet, op: LineOp, origin: EditOrigin) !bool {
    var st: CaseState = .{ .op = op, .gpa = sels.gpa };
    return (try runner.runPerSelection(doc, sels, caseOne, &st, origin)).changed;
}

// -- transpose characters -----------------------------------------------------------

fn transposeOne(_: *anyopaque, snap: *const Snapshot, sel: Selection, out: *runner.EditBuilder) anyerror!void {
    if (!sel.isCaret()) return;
    const t = &snap.tree;
    var buf: [4096]u8 = undefined;
    const line = t.lineOf(sel.head);
    const ls = t.lineStart(line);
    const text = indent.lineText(t, line, &buf);
    var col: usize = @intCast(@min(sel.head - ls, text.len));
    if (col == 0) return;
    // At the end of the line, swap the two graphemes before the caret.
    if (col == text.len) col = grapheme.prevBoundary(text, col);
    if (col == 0) return;
    const a = grapheme.prevBoundary(text, col);
    const c = grapheme.nextBoundary(text, col);
    if (c == col) return;
    var swapped: [64]u8 = undefined;
    if (c - a > swapped.len) return;
    @memcpy(swapped[0 .. c - col], text[col..c]);
    @memcpy(swapped[c - col .. c - a], text[a..col]);
    _ = try out.replace(.{ .start = ls + a, .end = ls + c }, swapped[0 .. c - a]);
    out.select(.{ .in_edit = .{ .edit = 0 } });
}

/// Swaps the graphemes around each caret (at the end of a line, the two
/// before it) and moves the caret past them.
fn transposeChars(doc: *Document, sels: *SelectionSet, origin: EditOrigin) !bool {
    var dummy: u8 = 0;
    return (try runner.runPerSelection(doc, sels, transposeOne, &dummy, origin)).changed;
}

// -- trim trailing whitespace ----------------------------------------------------------

/// Deletes blanks before every EOL and at the end of the document, in one
/// streaming pass.
fn trimTrailing(doc: *Document, sels: *SelectionSet, origin: EditOrigin) !bool {
    const gpa = sels.gpa;
    var snap = doc.snapshot();
    defer snap.release();
    var edits: std.ArrayList(Replace) = .empty;
    defer edits.deinit(gpa);
    var pos: u64 = 0;
    var run: ?u64 = null;
    var it = snap.tree.chunks(0);
    while (it.next()) |c| {
        for (c) |b| {
            switch (b) {
                ' ', '\t' => {
                    if (run == null) run = pos;
                },
                '\n', '\r' => {
                    if (run) |r| try edits.append(gpa, .{ .range = .{ .start = r, .end = pos }, .text = "" });
                    run = null;
                },
                else => run = null,
            }
            pos += 1;
        }
    }
    if (run) |r| try edits.append(gpa, .{ .range = .{ .start = r, .end = pos }, .text = "" });
    return runner.applyEdits(doc, sels, edits.items, origin, .keep);
}
