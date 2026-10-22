//! Comment toggling. Line comments: when every non-blank selected line
//! starts (after its indentation) with the token, remove it and one space
//! after it; otherwise insert `token ` at the smallest indentation of the
//! non-blank lines. Blank lines are left alone. Languages without a line
//! comment wrap each line in their block comment instead. Block comments
//! wrap or unwrap each selection (a caret's line when empty).

const std = @import("std");
const zg_syntax = @import("zg_syntax");
const sel_mod = @import("selection.zig");
const cs_mod = @import("change_set.zig");
const runner = @import("runner.zig");
const indent = @import("indent.zig");
const document = @import("../document.zig");
const snapshot_mod = @import("../snapshot.zig");

const Allocator = std.mem.Allocator;
const SelectionSet = sel_mod.SelectionSet;
const Selection = sel_mod.Selection;
const Replace = cs_mod.Replace;
const Document = document.Document;
const EditOrigin = document.EditOrigin;
const Snapshot = snapshot_mod.Snapshot;
const EditRules = zg_syntax.language.EditRules;

const line_window = 4096;

/// Line spans `[first, last]` covered by the selections, merged.
fn lineSpans(gpa: Allocator, snap: *const Snapshot, sels: *const SelectionSet) Allocator.Error!std.ArrayList([2]u64) {
    const t = &snap.tree;
    var spans: std.ArrayList([2]u64) = .empty;
    errdefer spans.deinit(gpa);
    for (sels.slice()) |s| {
        const l0 = t.lineOf(s.start());
        var l1 = t.lineOf(s.end());
        if (l1 > l0 and s.end() == t.lineStart(l1)) l1 -= 1;
        if (spans.items.len > 0 and l0 <= spans.items[spans.items.len - 1][1]) {
            spans.items[spans.items.len - 1][1] = @max(spans.items[spans.items.len - 1][1], l1);
            continue;
        }
        try spans.append(gpa, .{ l0, l1 });
    }
    return spans;
}

/// Toggles line comments on every line the selections touch. Returns
/// whether the document changed. Without a line comment token, falls
/// back to a block comment per line; without either, does nothing.
pub fn toggleLineComment(doc: *Document, sels: *SelectionSet, rules: EditRules, origin: EditOrigin) !bool {
    const lc = rules.line_comment orelse {
        const bc = rules.block_comment orelse return false;
        return toggleBlockPerLine(doc, sels, bc, origin);
    };
    const gpa = sels.gpa;
    var snap = doc.snapshot();
    defer snap.release();
    const t = &snap.tree;
    var spans = try lineSpans(gpa, &snap, sels);
    defer spans.deinit(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const insert_text = try std.mem.concat(a, u8, &.{ lc, " " });
    var edits: std.ArrayList(Replace) = .empty;
    defer edits.deinit(gpa);
    var buf: [line_window]u8 = undefined;
    for (spans.items) |sp| {
        // Pass 1: are all non-blank lines commented? smallest indent?
        var all = true;
        var any = false;
        var min_indent: usize = std.math.maxInt(usize);
        var l = sp[0];
        while (l <= sp[1]) : (l += 1) {
            const text = indent.lineText(t, l, &buf);
            const ws = indent.leading(text);
            if (ws.len == text.len) continue;
            any = true;
            min_indent = @min(min_indent, ws.len);
            if (!std.mem.startsWith(u8, text[ws.len..], lc)) all = false;
        }
        if (!any) {
            // Only blank lines: comment the first one at its indentation.
            const text = indent.lineText(t, sp[0], &buf);
            try edits.append(gpa, .{ .range = .{ .start = t.lineStart(sp[0]) + text.len, .end = t.lineStart(sp[0]) + text.len }, .text = insert_text });
            continue;
        }
        l = sp[0];
        while (l <= sp[1]) : (l += 1) {
            const ls = t.lineStart(l);
            const text = indent.lineText(t, l, &buf);
            const ws = indent.leading(text);
            if (ws.len == text.len) continue;
            if (all) {
                var n = lc.len;
                if (ws.len + n < text.len and text[ws.len + n] == ' ') n += 1;
                try edits.append(gpa, .{ .range = .{ .start = ls + ws.len, .end = ls + ws.len + n }, .text = "" });
            } else {
                try edits.append(gpa, .{ .range = .{ .start = ls + min_indent, .end = ls + min_indent }, .text = insert_text });
            }
        }
    }
    return runner.applyEdits(doc, sels, edits.items, origin, .grow);
}

/// Wraps or unwraps each non-blank line in `bc` (HTML, CSS).
fn toggleBlockPerLine(doc: *Document, sels: *SelectionSet, bc: zg_syntax.language.BracketPair, origin: EditOrigin) !bool {
    const gpa = sels.gpa;
    var snap = doc.snapshot();
    defer snap.release();
    const t = &snap.tree;
    var spans = try lineSpans(gpa, &snap, sels);
    defer spans.deinit(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const open = try std.mem.concat(a, u8, &.{ bc.open, " " });
    const close = try std.mem.concat(a, u8, &.{ " ", bc.close });
    var edits: std.ArrayList(Replace) = .empty;
    defer edits.deinit(gpa);
    var buf: [line_window]u8 = undefined;
    for (spans.items) |sp| {
        var all = true;
        var l = sp[0];
        while (l <= sp[1]) : (l += 1) {
            const text = indent.lineText(t, l, &buf);
            const body = std.mem.trim(u8, text, " \t");
            if (body.len == 0) continue;
            if (!(std.mem.startsWith(u8, body, bc.open) and std.mem.endsWith(u8, body, bc.close) and body.len >= bc.open.len + bc.close.len)) all = false;
        }
        l = sp[0];
        while (l <= sp[1]) : (l += 1) {
            const ls = t.lineStart(l);
            const text = indent.lineText(t, l, &buf);
            const ws = indent.leading(text);
            const body = std.mem.trim(u8, text, " \t");
            if (body.len == 0) continue;
            const body_end = ls + ws.len + body.len;
            if (all) {
                var no = bc.open.len;
                if (ws.len + no < text.len and text[ws.len + no] == ' ') no += 1;
                var nc = bc.close.len;
                if (body.len > bc.open.len + bc.close.len and body[body.len - nc - 1] == ' ') nc += 1;
                try edits.append(gpa, .{ .range = .{ .start = ls + ws.len, .end = ls + ws.len + no }, .text = "" });
                try edits.append(gpa, .{ .range = .{ .start = body_end - nc, .end = body_end }, .text = "" });
            } else {
                try edits.append(gpa, .{ .range = .{ .start = ls + ws.len, .end = ls + ws.len }, .text = open });
                try edits.append(gpa, .{ .range = .{ .start = body_end, .end = body_end }, .text = close });
            }
        }
    }
    return runner.applyEdits(doc, sels, edits.items, origin, .grow);
}

/// Wraps each selection (a caret: its line's text) in the block comment,
/// or unwraps it when it already is one (ignoring surrounding blanks).
/// Without a block comment token, does nothing.
pub fn toggleBlockComment(doc: *Document, sels: *SelectionSet, rules: EditRules, origin: EditOrigin) !bool {
    const bc = rules.block_comment orelse return false;
    const gpa = sels.gpa;
    var snap = doc.snapshot();
    defer snap.release();
    const t = &snap.tree;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const open = try std.mem.concat(a, u8, &.{ bc.open, " " });
    const close = try std.mem.concat(a, u8, &.{ " ", bc.close });
    var edits: std.ArrayList(Replace) = .empty;
    defer edits.deinit(gpa);
    for (sels.slice()) |s| {
        var start = s.start();
        var end = s.end();
        if (s.isCaret()) {
            var buf: [line_window]u8 = undefined;
            const l = t.lineOf(s.head);
            const ls = t.lineStart(l);
            const text = indent.lineText(t, l, &buf);
            const ws = indent.leading(text);
            start = ls + ws.len;
            end = ls + std.mem.trimEnd(u8, text, " \t").len;
            if (end < start) end = start;
        }
        const text = try t.copyRange(a, .{ .start = start, .end = end });
        const lead = text.len - std.mem.trimStart(u8, text, " \t\r\n").len;
        const body = std.mem.trim(u8, text, " \t\r\n");
        if (body.len >= bc.open.len + bc.close.len and std.mem.startsWith(u8, body, bc.open) and std.mem.endsWith(u8, body, bc.close)) {
            const bs = start + lead;
            const be = bs + body.len;
            var no = bc.open.len;
            if (no < body.len and body[no] == ' ') no += 1;
            var nc = bc.close.len;
            if (body.len > no + nc and body[body.len - nc - 1] == ' ') nc += 1;
            try edits.append(gpa, .{ .range = .{ .start = bs, .end = bs + no }, .text = "" });
            try edits.append(gpa, .{ .range = .{ .start = be - nc, .end = be }, .text = "" });
        } else {
            try edits.append(gpa, .{ .range = .{ .start = start, .end = start }, .text = open });
            try edits.append(gpa, .{ .range = .{ .start = end, .end = end }, .text = close });
        }
    }
    return runner.applyEdits(doc, sels, edits.items, origin, .grow);
}
