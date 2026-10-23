//! Heading renames (E08.F06.S02.T01): when a heading's text changes, the
//! `#Old` subpaths of links to it (from other notes, and the note's own
//! `[[#Old]]` links) are rewritten. `old` and `new` are the heading's
//! path (outer headings first); a link matches when its heading
//! segments end at the renamed heading along that path (`#B` and `#A#B`
//! both name `A > B`), and only the matching segment changes.

const std = @import("std");
const note_index = @import("../index/note_index.zig");
const mentions = @import("../index/mentions.zig");
const note = @import("../vault/note.zig");
const rename = @import("rename.zig");
const link_text = @import("link_text.zig");

const Allocator = std.mem.Allocator;
const IndexView = note_index.IndexView;
const FileId = note.FileId;
const LinkEdit = rename.LinkEdit;

/// Plans the subpath edits for renaming heading `old` of `target` to
/// `new` (same depth). Source text comes from `src`.
pub fn planHeadingRename(gpa: Allocator, view: *const IndexView, src: mentions.ContentSource, target: FileId, old: []const []const u8, new: []const []const u8) !rename.Plan {
    std.debug.assert(old.len > 0 and old.len == new.len);
    var plan: rename.Plan = .{ .arena = .init(gpa), .edits = &.{}, .moved = &.{} };
    errdefer plan.arena.deinit();
    const a = plan.arena.allocator();
    const new_last = new[new.len - 1];

    // Sources: backlinks, plus the note itself for `[[#Old]]`.
    var sources: std.AutoArrayHashMapUnmanaged(u64, FileId) = .empty;
    for (view.backlinks(target)) |b| try sources.put(a, @bitCast(b.source), b.source);
    try sources.put(a, @bitCast(target), target);

    var edits: std.ArrayList(LinkEdit) = .empty;
    for (sources.values()) |sid| {
        const meta = view.note(sid) orelse continue;
        const out = view.outgoing(sid);
        var bytes: ?[]u8 = null;
        defer if (bytes) |b| gpa.free(b);
        for (meta.links, 0..) |*l, i| {
            const r = out[i];
            const to_target = (r.kind == .note and r.id.eql(target)) or (r.kind == .self and sid.eql(target));
            if (!to_target) continue;
            const segs = switch (l.subpath orelse continue) {
                .heading => |h| h,
                .block => continue,
            };
            const j = matchIndex(segs, old) orelse continue;
            if (bytes == null) bytes = (try src.read(src.ctx, gpa, sid, view.pathOf(sid).?)) orelse break;
            const range = segmentRange(bytes.?, l, j) orelse continue;
            const md = l.kind == .markdown or l.kind == .markdown_embed;
            const text = if (md and !l.angle) try link_text.percentEncode(a, new_last) else try a.dupe(u8, new_last);
            try edits.append(a, .{ .note = sid, .range = range, .new_text = text });
        }
    }
    std.mem.sort(LinkEdit, edits.items, {}, struct {
        fn lt(_: void, x: LinkEdit, y: LinkEdit) bool {
            const xi: u64 = @bitCast(x.note);
            const yi: u64 = @bitCast(y.note);
            if (xi != yi) return xi < yi;
            return x.range[0] < y.range[0];
        }
    }.lt);
    plan.edits = edits.items;
    return plan;
}

/// The index of the segment naming the renamed heading: `segs[0..j+1]`
/// is a suffix of `old` ending at its last element.
fn matchIndex(segs: []const []const u8, old: []const []const u8) ?usize {
    // The link's segments end at the renamed heading, so compare the
    // whole link path against the tail of `old`.
    if (segs.len > old.len) return null;
    for (0..segs.len) |k| {
        if (!std.ascii.eqlIgnoreCase(segs[segs.len - 1 - k], old[old.len - 1 - k])) return null;
    }
    return segs.len - 1;
}

/// The byte range of heading segment `j` of link `l` in `bytes`.
fn segmentRange(bytes: []const u8, l: *const note.Link, j: usize) ?[2]u32 {
    const s = l.target_src[1];
    if (s > bytes.len) return null;
    const md = l.kind == .markdown or l.kind == .markdown_embed;
    // The subpath text: up to `|` or `]]` (wiki), or the destination's
    // end (Markdown).
    var e: usize = s;
    while (e < l.src[1] and e < bytes.len) : (e += 1) {
        const c = bytes[e];
        if (md) {
            if (c == ')' or c == '>' or c == ' ') break;
        } else if (c == '|' or (c == ']' and e + 1 < bytes.len and bytes[e + 1] == ']') or (c == '\\' and e + 1 < bytes.len and bytes[e + 1] == '|')) break;
    }
    const hash = std.mem.indexOfScalarPos(u8, bytes[0..e], s, '#') orelse return null;
    var k: usize = 0;
    var i = hash + 1;
    while (i <= e) {
        const end = std.mem.indexOfScalarPos(u8, bytes[0..e], i, '#') orelse e;
        var a = i;
        var b = end;
        while (a < b and bytes[a] == ' ') a += 1;
        while (b > a and bytes[b - 1] == ' ') b -= 1;
        if (b > a) {
            if (k == j) return .{ @intCast(a), @intCast(b) };
            k += 1;
        }
        i = end + 1;
    }
    return null;
}
