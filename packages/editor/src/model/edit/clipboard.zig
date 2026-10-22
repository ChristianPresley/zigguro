//! Multi-cursor clipboard. Copy makes one piece per selection; with only
//! carets it copies their lines (linewise). Paste gives each selection its
//! own piece when the counts match, else the joined text everywhere; a
//! linewise piece pasted at a caret goes above the caret's line (VS Code).
//! The model never touches the OS clipboard: the view moves `PlatformClip`
//! (plain text plus a private JSON format) to and from E01.

const std = @import("std");
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
const Replace = cs_mod.Replace;
const Document = document.Document;
const Snapshot = snapshot_mod.Snapshot;
const PieceTree = pt.PieceTree;
const EditCtx = smart.EditCtx;
const IndentUnit = indent.IndentUnit;

/// The private clipboard format carrying the pieces.
pub const private_mime = "application/x-zigguro-multicursor";

/// Copied text: one piece per selection. Linewise pieces are whole lines
/// with their EOL.
pub const Clipboard = struct {
    gpa: Allocator,
    pieces: [][]u8,
    linewise: bool,

    pub fn deinit(cb: *Clipboard) void {
        for (cb.pieces) |p| cb.gpa.free(p);
        cb.gpa.free(cb.pieces);
    }

    /// All pieces as one text: linewise pieces end in their EOL already,
    /// others are joined with `eol`.
    pub fn joined(cb: *const Clipboard, gpa: Allocator, eol: []const u8) Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        for (cb.pieces, 0..) |p, i| {
            if (i > 0 and !cb.linewise) try out.appendSlice(gpa, eol);
            try out.appendSlice(gpa, p);
        }
        return out.toOwnedSlice(gpa);
    }
};

/// What the view hands to the platform clipboard: `text` for every app
/// and `private` (JSON) under `private_mime`.
pub const PlatformClip = struct {
    text: []u8,
    private: []u8,

    pub fn deinit(p: *PlatformClip, gpa: Allocator) void {
        gpa.free(p.text);
        gpa.free(p.private);
    }
};

/// The document's EOL: the first line's terminator, else "\n".
pub fn documentEol(t: *const PieceTree) []const u8 {
    if (t.lineCount() < 2) return "\n";
    const r = t.lineRange(0);
    if (r.eol_len == 2) return "\r\n";
    return if (t.byteAt(r.end) == '\r') "\r" else "\n";
}

fn allCarets(sels: []const Selection) bool {
    for (sels) |s| if (!s.isCaret()) return false;
    return true;
}

/// Copies every selection; with only carets, their lines (each once).
pub fn copy(doc: *Document, sels: *const SelectionSet, gpa: Allocator) !Clipboard {
    var snap = doc.snapshot();
    defer snap.release();
    const t = &snap.tree;
    var pieces: std.ArrayList([]u8) = .empty;
    errdefer {
        for (pieces.items) |p| gpa.free(p);
        pieces.deinit(gpa);
    }
    const linewise = allCarets(sels.slice());
    var last_line: ?u64 = null;
    for (sels.slice()) |s| {
        if (linewise) {
            const l = t.lineOf(s.head);
            if (last_line == l) continue;
            last_line = l;
            const r = t.lineRange(l);
            const text = try t.copyRange(gpa, .{ .start = r.start, .end = r.end + r.eol_len });
            if (r.eol_len == 0) {
                // The last line: give it the document's EOL so it pastes as
                // a line.
                const eol = documentEol(t);
                const full = try gpa.realloc(text, text.len + eol.len);
                @memcpy(full[full.len - eol.len ..], eol);
                try pieces.append(gpa, full);
            } else try pieces.append(gpa, text);
        } else {
            try pieces.append(gpa, try t.copyRange(gpa, s.range()));
        }
    }
    return .{ .gpa = gpa, .pieces = try pieces.toOwnedSlice(gpa), .linewise = linewise };
}

/// Copies, then deletes what was copied (whole lines when linewise).
pub fn cut(doc: *Document, sels: *SelectionSet, gpa: Allocator, ctx: EditCtx) !Clipboard {
    var cb = try copy(doc, sels, gpa);
    errdefer cb.deinit();
    if (cb.linewise) {
        _ = try cmds.deleteLines(doc, sels, ctx.origin);
    } else {
        var edits: std.ArrayList(Replace) = .empty;
        defer edits.deinit(sels.gpa);
        for (sels.slice()) |s| if (!s.isCaret()) try edits.append(sels.gpa, .{ .range = s.range(), .text = "" });
        _ = try runner.applyEdits(doc, sels, edits.items, ctx.origin, .keep);
    }
    return cb;
}

const PasteState = struct {
    gpa: Allocator,
    cb: *const Clipboard,
    joined: []const u8,
    distribute: bool,
    ctx: EditCtx,
    eol: []const u8,
    next: usize = 0,
};

fn pasteOne(ptr: *anyopaque, snap: *const Snapshot, sel: Selection, out: *runner.EditBuilder) anyerror!void {
    const st: *PasteState = @ptrCast(@alignCast(ptr));
    const t = &snap.tree;
    const piece = if (st.distribute) st.cb.pieces[st.next] else st.joined;
    st.next += 1;
    const above = st.cb.linewise and sel.isCaret();
    const at = if (above) t.lineStart(t.lineOf(sel.head)) else sel.start();
    var arena: std.heap.ArenaAllocator = .init(st.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var text = try normalizeEol(a, piece, st.eol);
    if (st.ctx.reindent_on_paste) {
        var buf: [4096]u8 = undefined;
        const line = indent.lineText(t, t.lineOf(at), &buf);
        const target = IndentUnit.columns(indent.leading(line), st.ctx.tab_size);
        const ls = t.lineStart(t.lineOf(at));
        // Pasting mid-line: the first line keeps its place.
        text = try reindent(a, text, target, above or at == ls, st.ctx);
    }
    if (above) {
        _ = try out.insert(at, text);
        out.select(.map);
    } else {
        _ = try out.replace(sel.range(), text);
        out.select(.{ .in_edit = .{ .edit = 0 } });
    }
}

/// Pastes `cb` at every selection as one change.
pub fn paste(doc: *Document, sels: *SelectionSet, cb: *const Clipboard, ctx: EditCtx) !bool {
    if (cb.pieces.len == 0) return false;
    const gpa = sels.gpa;
    var snap = doc.snapshot();
    const eol = documentEol(&snap.tree);
    snap.release();
    const joined = try cb.joined(gpa, eol);
    defer gpa.free(joined);
    var st: PasteState = .{
        .gpa = gpa,
        .cb = cb,
        .joined = joined,
        .distribute = cb.pieces.len > 1 and cb.pieces.len == sels.count(),
        .ctx = ctx,
        .eol = eol,
    };
    return (try runner.runPerSelection(doc, sels, pasteOne, &st, ctx.origin)).changed;
}

/// `text` with every CRLF, CR or LF turned into `eol`.
fn normalizeEol(a: Allocator, text: []const u8, eol: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfAny(u8, text, "\r\n") == null) return text;
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, text.len);
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const b = text[i];
        if (b == '\r' or b == '\n') {
            if (b == '\r' and i + 1 < text.len and text[i + 1] == '\n') i += 1;
            try out.appendSlice(a, eol);
        } else try out.append(a, b);
    }
    return out.items;
}

/// Re-bases `text` on `target` columns: each non-blank line keeps its
/// indentation relative to the block's smallest one, written in the
/// context's unit. The first line is left alone unless `first`.
pub fn reindent(a: Allocator, text: []const u8, target: u32, first: bool, ctx: EditCtx) Allocator.Error![]const u8 {
    const unit = ctx.indentUnit();
    var min: u32 = std.math.maxInt(u32);
    var it = std.mem.splitScalar(u8, text, '\n');
    var idx: usize = 0;
    while (it.next()) |raw| : (idx += 1) {
        if (idx == 0 and !first) continue;
        const ln = std.mem.trimEnd(u8, raw, "\r");
        const ws = indent.leading(ln);
        if (ws.len == ln.len) continue;
        min = @min(min, IndentUnit.columns(ws, ctx.tab_size));
    }
    if (min == std.math.maxInt(u32)) return text;
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, text.len);
    it = std.mem.splitScalar(u8, text, '\n');
    idx = 0;
    var ib: [1024]u8 = undefined;
    while (it.next()) |ln| : (idx += 1) {
        if (idx > 0) try out.append(a, '\n');
        const ws = indent.leading(ln);
        const body = ln[ws.len..];
        if ((idx == 0 and !first) or std.mem.trimEnd(u8, body, "\r").len == 0) {
            try out.appendSlice(a, if (idx == 0) ln else body);
            continue;
        }
        const cols = IndentUnit.columns(ws, ctx.tab_size) - min + target;
        try out.appendSlice(a, unit.write(@min(cols, ib.len), &ib));
        try out.appendSlice(a, body);
    }
    return out.items;
}

const Private = struct { v: u32, linewise: bool, pieces: []const []const u8 };

/// The platform form of `cb`: plain text (pieces joined by "\n") and the
/// pieces as JSON.
pub fn encodePlatform(cb: *const Clipboard, gpa: Allocator) !PlatformClip {
    const text = try cb.joined(gpa, "\n");
    errdefer gpa.free(text);
    const private = try std.json.Stringify.valueAlloc(gpa, Private{ .v = 1, .linewise = cb.linewise, .pieces = cb.pieces }, .{});
    return .{ .text = text, .private = private };
}

/// Reads the platform clipboard: the private pieces when present and
/// still matching `text` (another app may have replaced the text), else
/// `text` as one piece.
pub fn decodePlatform(text: []const u8, private: ?[]const u8, gpa: Allocator) !Clipboard {
    if (private) |p| blk: {
        const parsed = std.json.parseFromSlice(Private, gpa, p, .{ .ignore_unknown_fields = true }) catch break :blk;
        defer parsed.deinit();
        if (parsed.value.v != 1) break :blk;
        var pieces = try gpa.alloc([]u8, parsed.value.pieces.len);
        var n: usize = 0;
        errdefer {
            for (pieces[0..n]) |x| gpa.free(x);
            gpa.free(pieces);
        }
        for (parsed.value.pieces) |x| {
            pieces[n] = try gpa.dupe(u8, x);
            n += 1;
        }
        var cb: Clipboard = .{ .gpa = gpa, .pieces = pieces, .linewise = parsed.value.linewise };
        const j = try cb.joined(gpa, "\n");
        defer gpa.free(j);
        if (std.mem.eql(u8, j, text)) return cb;
        cb.deinit();
    }
    const pieces = try gpa.alloc([]u8, 1);
    errdefer gpa.free(pieces);
    pieces[0] = try gpa.dupe(u8, text);
    return .{ .gpa = gpa, .pieces = pieces, .linewise = false };
}
