//! Unlinked mentions (E08.F06.S01.T02), computed on demand for one note
//! as Obsidian does: whole-word, case-insensitive occurrences of the
//! note's title, aliases and file stem in the other notes of its vault,
//! outside links, tags, code, math, comments and frontmatter.
//!
//! Matching folds ASCII case only (non-ASCII letters must match exactly)
//! so reported ranges stay byte ranges of the source note. Note bytes come
//! from `ContentSource`, normally the open editor buffer or the file.

const std = @import("std");
const zg_text = @import("zg_text");
const note_index = @import("note_index.zig");
const extract_mod = @import("../vault/extract.zig");
const names = @import("names.zig");

const Allocator = std.mem.Allocator;
const FileId = @import("../vault/note.zig").FileId;

pub const ContentSource = struct {
    ctx: *anyopaque,
    /// The bytes of note `id` at vault-relative `path` (in `gpa`, freed
    /// by the caller), or null when unavailable.
    read: *const fn (ctx: *anyopaque, gpa: Allocator, id: FileId, path: []const u8) anyerror!?[]u8,
};

pub const Mention = struct {
    source: FileId,
    /// The mentioned text in the source note.
    range: [2]u32,
    /// 0-based line.
    line: u32,
    /// Which name matched (title, an alias or the stem).
    term: []const u8,
};

/// Appends the unlinked mentions of note `id` to `out`, sorted by source
/// id then offset. Each `term` points into the view.
pub fn unlinkedMentions(view: *const note_index.IndexView, gpa: Allocator, src: ContentSource, id: FileId, out: *std.ArrayList(Mention)) !void {
    const target = view.entry(id) orelse return;
    var terms: std.ArrayList([]const u8) = .empty;
    defer terms.deinit(gpa);
    try addTerm(gpa, &terms, target.meta.title);
    for (target.meta.aliases) |a| try addTerm(gpa, &terms, a);
    try addTerm(gpa, &terms, names.stemOf(target.path));
    // Longer terms first, so `Project Alpha` wins over `Project`.
    std.mem.sort([]const u8, terms.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return a.len > b.len;
        }
    }.lt);
    if (terms.items.len == 0) return;
    for (view.order) |sid| {
        if (sid.eql(id)) continue;
        const e = view.entry(sid).?;
        if (e.vault != target.vault) continue;
        const bytes = (try src.read(src.ctx, gpa, sid, e.path)) orelse continue;
        defer gpa.free(bytes);
        const skip = try extract_mod.excludedRanges(gpa, bytes);
        defer gpa.free(skip);
        var ex: std.ArrayList([2]u32) = .empty;
        defer ex.deinit(gpa);
        try ex.appendSlice(gpa, skip);
        for (e.meta.links) |l| try ex.append(gpa, l.src);
        for (e.meta.tags) |tg| if (!tg.in_frontmatter) try ex.append(gpa, tg.src);
        std.mem.sort([2]u32, ex.items, {}, struct {
            fn lt(_: void, a: [2]u32, b: [2]u32) bool {
                return a[0] < b[0];
            }
        }.lt);
        try scan(gpa, bytes, sid, terms.items, ex.items, out);
    }
}

fn addTerm(gpa: Allocator, terms: *std.ArrayList([]const u8), t: []const u8) !void {
    const s = std.mem.trim(u8, t, " \t");
    if (s.len < 2) return;
    for (terms.items) |x| if (std.ascii.eqlIgnoreCase(x, s)) return;
    try terms.append(gpa, s);
}

fn scan(gpa: Allocator, bytes: []const u8, sid: FileId, terms: []const []const u8, ex: []const [2]u32, out: *std.ArrayList(Mention)) !void {
    var i: usize = 0;
    var ei: usize = 0;
    var line: u32 = 0;
    var line_pos: usize = 0;
    while (i < bytes.len) {
        while (ei < ex.len and ex[ei][1] <= i) ei += 1;
        if (ei < ex.len and ex[ei][0] <= i) {
            i = ex[ei][1];
            continue;
        }
        if (!isWordStart(bytes, i)) {
            i += 1;
            continue;
        }
        const hit: ?[]const u8 = for (terms) |t| {
            if (i + t.len > bytes.len) continue;
            if (!std.ascii.eqlIgnoreCase(bytes[i .. i + t.len], t)) continue;
            if (!isWordEnd(bytes, i + t.len)) continue;
            // Not running into an excluded range.
            if (ei < ex.len and ex[ei][0] < i + t.len) continue;
            break t;
        } else null;
        if (hit) |t| {
            line += @intCast(std.mem.count(u8, bytes[line_pos..i], "\n"));
            line_pos = i;
            try out.append(gpa, .{ .source = sid, .range = .{ @intCast(i), @intCast(i + t.len) }, .line = line, .term = t });
            i += t.len;
        } else i += 1;
    }
}

fn isWordChar(cp: u21) bool {
    if (cp < 0x80) return std.ascii.isAlphanumeric(@intCast(cp)) or cp == '_';
    return switch (zg_text.unicode.props(cp).gc) {
        .Ll, .Lm, .Lo, .Lt, .Lu, .Mc, .Me, .Mn, .Nd, .Nl, .No => true,
        else => false,
    };
}

fn isWordStart(s: []const u8, i: usize) bool {
    if (i > 0 and (s[i] & 0xC0) == 0x80) return false;
    const prev = @import("../vault/tags.zig").prevCodepoint(s, i) orelse return true;
    return !isWordChar(prev);
}

fn isWordEnd(s: []const u8, i: usize) bool {
    if (i >= s.len) return true;
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return true;
    if (i + n > s.len) return true;
    const cp = std.unicode.utf8Decode(s[i .. i + n]) catch return true;
    return !isWordChar(cp);
}
