//! Anchors: positions that follow edits. An anchor records the version it
//! was made at; resolving it maps the offset through the document's change
//! log. Long-lived anchors (decorations) are kept current by the view's
//! decoration store instead (E05.F05).

const std = @import("std");
const cs_mod = @import("change_set.zig");
const Document = @import("../document.zig").Document;

/// A position at a document version.
pub const Anchor = struct {
    offset: u64,
    version: u64,
    bias: cs_mod.Bias,

    /// An anchor at `offset` in the document's current version.
    pub fn at(doc: *const Document, offset: u64, bias: cs_mod.Bias) Anchor {
        return .{ .offset = offset, .version = doc.version, .bias = bias };
    }
};

/// The anchor's offset in the current version; null when its version was
/// evicted from the change log or the text around it was deleted (the
/// position fell strictly inside replaced text).
pub fn resolve(doc: *const Document, a: Anchor) ?u64 {
    if (a.version == doc.version) return a.offset;
    const m = doc.change_log.mapPos(a.version, a.offset, a.bias) orelse return null;
    if (m.deleted) return null;
    return m.pos;
}

/// Resolves and caches the result in the anchor (so the next resolve is
/// the fast path). Returns false (leaving the anchor unchanged) when it no
/// longer resolves.
pub fn refresh(doc: *const Document, a: *Anchor) bool {
    const off = resolve(doc, a.*) orelse return false;
    a.* = .{ .offset = off, .version = doc.version, .bias = a.bias };
    return true;
}

test "anchor: resolve across edits and eviction" {
    const gpa = std.testing.allocator;
    var doc = try Document.initBytes(gpa, @enumFromInt(1), "hello world");
    defer doc.deinit();
    const a = Anchor.at(doc, 6, .left); // "world"
    const inside = Anchor.at(doc, 2, .left);
    var cs = try cs_mod.ChangeSet.fromEdits(gpa, doc.len(), &.{.{ .range = .{ .start = 0, .end = 5 }, .text = "hi" }});
    defer cs.deinit();
    try doc.applyChangeSet(&cs, .{ .user = 0 });
    try std.testing.expectEqual(@as(?u64, 3), resolve(doc, a));
    try std.testing.expectEqual(@as(?u64, null), resolve(doc, inside));
    var b = a;
    try std.testing.expect(refresh(doc, &b));
    try std.testing.expectEqual(doc.version, b.version);
    doc.change_log.capacity_versions = 4;
    for (0..10) |_| {
        var c = try cs_mod.ChangeSet.fromEdits(gpa, doc.len(), &.{.{ .range = .{ .start = 0, .end = 0 }, .text = "x" }});
        defer c.deinit();
        try doc.applyChangeSet(&c, .{ .user = 0 });
    }
    try std.testing.expectEqual(@as(?u64, null), resolve(doc, a));
}
