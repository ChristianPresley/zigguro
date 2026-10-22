//! Ghost text: an AI suggestion shown at a position as dim virtual text
//! until it is accepted, typed through or dismissed.
//!
//! The first line is an `inline_after` decoration at the anchor; further
//! lines are a `block_below` with one row each (the view asks `lines` for
//! their text). The ghost owns its decoration owner, so every update is an
//! atomic `setOwnerDecorations`.

const std = @import("std");
const store_mod = @import("store.zig");
const pt = @import("../buffer/piece_tree.zig");
const cs_mod = @import("../edit/change_set.zig");
const document = @import("../document.zig");

const Allocator = std.mem.Allocator;
const Range = pt.Range;
const ChangeSet = cs_mod.ChangeSet;
const ChangeEvent = document.ChangeEvent;
const Document = document.Document;
const DecorationStore = store_mod.DecorationStore;
const OwnerId = store_mod.OwnerId;

pub const GhostMeta = struct {
    request_id: u64,
    /// The decoration owner reserved for this ghost (e.g. "ai.ghost").
    source: OwnerId,
    /// Text the accepted suggestion replaces (for completions that rewrite
    /// what was typed before the anchor); it must contain the anchor.
    replace_range: ?Range = null,
    style: store_mod.StyleRef = @enumFromInt(0),
    /// Origin of the accept edit (its undo group).
    origin: document.EditOrigin = .{ .agent = 0 },
};

pub const TypeResult = enum {
    /// The edit did not touch the ghost.
    kept,
    /// The user typed the start of the ghost; the rest is still shown.
    kept_shrunk,
    /// The ghost is gone; the caller drops it.
    dismissed,
};

pub const AcceptPart = enum { all, word, line };

/// One visible suggestion.
pub const GhostText = struct {
    gpa: Allocator,
    doc: *Document,
    store: *DecorationStore,
    meta: GhostMeta,
    /// Where the remaining text would be inserted.
    at: u64,
    /// The text still shown.
    text: std.ArrayList(u8) = .empty,
    visible: bool = true,
    /// Set while `accept` applies its own edit, which `onType` ignores.
    applying: bool = false,

    /// Shows `text` at `at`.
    pub fn show(gpa: Allocator, doc: *Document, store: *DecorationStore, at: u64, text: []const u8, meta: GhostMeta) !GhostText {
        var g: GhostText = .{ .gpa = gpa, .doc = doc, .store = store, .meta = meta, .at = at };
        errdefer g.text.deinit(gpa);
        try g.text.appendSlice(gpa, text);
        try g.render();
        return g;
    }

    /// Hides the ghost and frees it.
    pub fn deinit(g: *GhostText) void {
        g.dismiss();
        g.text.deinit(g.gpa);
    }

    /// Removes the decorations; the ghost stays dismissed.
    pub fn dismiss(g: *GhostText) void {
        if (!g.visible) return;
        g.visible = false;
        g.store.clearOwner(g.meta.source);
    }

    /// The remaining text.
    pub fn remaining(g: *const GhostText) []const u8 {
        return g.text.items;
    }

    /// The remaining text's lines (the first is shown inline).
    pub fn lines(g: *const GhostText) std.mem.SplitIterator(u8, .scalar) {
        return std.mem.splitScalar(u8, g.text.items, '\n');
    }

    /// Follows a document change (call from the document listener, after
    /// the decoration store's). Typing the start of the ghost at its
    /// anchor consumes it; an auto-closed pair counts as typed, so typing
    /// `(` that inserts `()` consumes the ghost's `(` and its `)`. Any other
    /// edit at the anchor dismisses the ghost.
    pub fn onType(g: *GhostText, ev: *const ChangeEvent) Allocator.Error!TypeResult {
        if (!g.visible) return .dismissed;
        if (g.applying) return .kept;
        const rs = ev.changes.replaces;
        var touches = false;
        for (rs) |r| touches = touches or (r.range.start <= g.at and r.range.end >= g.at);
        if (!touches) {
            g.at = ev.changes.mapPos(g.at, .right);
            if (g.meta.replace_range) |*rr| rr.* = ev.changes.mapRange(rr.*, .expand) orelse rr.*;
            return .kept;
        }
        if (rs.len == 1 and rs[0].range.start == g.at and rs[0].range.end == g.at) {
            const typed = rs[0].text;
            const ghost = g.text.items;
            const new_at = ev.changes.new_starts[0];
            if (typed.len > 0 and typed.len < ghost.len and std.mem.startsWith(u8, ghost, typed)) {
                g.consume(typed.len, null);
                g.at = new_at + typed.len;
                try g.render();
                return .kept_shrunk;
            }
            // An auto-closed pair: the typed opener plus its closer, with
            // the caret between them.
            if (typed.len >= 2 and typed.len - 1 < ghost.len and std.mem.startsWith(u8, ghost, typed[0 .. typed.len - 1])) {
                const closer = typed[typed.len - 1];
                const rest = ghost[typed.len - 1 ..];
                const first_line = rest[0 .. std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len];
                if (isCloser(closer) and std.mem.lastIndexOfScalar(u8, first_line, closer) != null) {
                    const cut = std.mem.lastIndexOfScalar(u8, first_line, closer).?;
                    g.consume(typed.len - 1, cut);
                    g.at = new_at + typed.len - 1;
                    if (g.text.items.len == 0) {
                        g.dismiss();
                        return .dismissed;
                    }
                    try g.render();
                    return .kept_shrunk;
                }
            }
        }
        g.dismiss();
        return .dismissed;
    }

    /// Drops the first `n` bytes, and the byte at `extra` of what remains.
    fn consume(g: *GhostText, n: usize, extra: ?usize) void {
        g.text.replaceRangeAssumeCapacity(0, n, "");
        if (extra) |i| _ = g.text.orderedRemove(i);
    }

    /// Inserts all of the ghost, its next word or its next line as one
    /// edit (one undo group); returns the caret position after the
    /// inserted text. A partial accept keeps showing the rest.
    pub fn accept(g: *GhostText, part: AcceptPart) !u64 {
        std.debug.assert(g.visible);
        const ghost = g.text.items;
        const n = switch (part) {
            .all => ghost.len,
            .line => if (std.mem.indexOfScalar(u8, ghost, '\n')) |i| i + 1 else ghost.len,
            .word => wordEnd(ghost),
        };
        const range: Range = if (g.meta.replace_range) |rr| .{ .start = @min(rr.start, g.at), .end = @max(rr.end, g.at) } else .{ .start = g.at, .end = g.at };
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(g.gpa);
        try text.appendSlice(g.gpa, ghost[0..n]);
        var cs = try ChangeSet.fromEdits(g.gpa, g.doc.len(), &.{.{ .range = range, .text = text.items }});
        defer cs.deinit();
        const caret = range.start + text.items.len;
        // Update first, so our own listener sees a consistent ghost.
        g.consume(n, null);
        g.meta.replace_range = null;
        const done = g.text.items.len == 0 or part == .all;
        if (done) g.dismiss();
        g.at = caret;
        g.applying = true;
        defer g.applying = false;
        try g.doc.applyChangeSet(&cs, g.meta.origin);
        if (!done) try g.render();
        return caret;
    }

    fn render(g: *GhostText) Allocator.Error!void {
        const ghost = g.text.items;
        const nl = std.mem.indexOfScalar(u8, ghost, '\n');
        var decos: [2]store_mod.Decoration = undefined;
        var n: usize = 0;
        decos[n] = .{ .range = .{ .start = g.at, .end = g.at }, .owner = g.meta.source, .stick = .point_left, .kind = .{ .inline_after = .{ .text = ghost[0 .. nl orelse ghost.len], .style = g.meta.style } } };
        n += 1;
        if (nl != null) {
            const rows: u32 = @intCast(std.mem.count(u8, ghost, "\n"));
            decos[n] = .{ .range = .{ .start = g.at, .end = g.at }, .owner = g.meta.source, .stick = .point_left, .kind = .{ .block_below = .{ .rows = rows, .payload = g.meta.request_id } } };
            n += 1;
        }
        try g.store.setOwnerDecorations(g.meta.source, g.doc.version, decos[0..n]);
    }
};

fn isCloser(c: u8) bool {
    return switch (c) {
        ')', ']', '}', '"', '\'', '`', '>' => true,
        else => false,
    };
}

/// End of the next word of `s` for partial accept: leading spaces, then a
/// run of identifier characters (or a single other character), then the
/// spaces after it.
fn wordEnd(s: []const u8) usize {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    if (i < s.len and s[i] == '\n') return i + 1;
    if (i < s.len and isIdent(s[i])) {
        while (i < s.len and isIdent(s[i])) i += 1;
    } else if (i < s.len) {
        i += std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
    }
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    return @min(i, s.len);
}

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}
