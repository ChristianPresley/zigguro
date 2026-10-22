//! Neighbour snippets for completion context (E12.F07.S01.T02): the
//! recently viewed or edited documents, cut into 60-line windows that
//! overlap by 30, each kept as a set of identifier hashes. A query (the
//! identifiers just before the cursor) ranks windows by Jaccard
//! similarity.
//!
//! Identifiers are hashed (Wyhash, 32 bits) rather than interned: a
//! collision only blurs a score. Documents keep a copy of their text;
//! window sets are rebuilt lazily after an edit. Documents the security
//! policy excludes are never returned.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Windows are this many lines, starting every `window_step` lines.
pub const window_lines = 60;
pub const window_step = 30;
/// Documents kept, most recent first.
pub const max_docs = 20;

pub const Snippet = struct {
    path: []const u8,
    text: []const u8,
    score: f32 = 0,
};

const Window = struct {
    /// Bytes of the document.
    start: usize,
    end: usize,
    tokens: []u32,
};

const Doc = struct {
    id: u64,
    path: []u8,
    text: []u8,
    excluded: bool,
    windows: std.ArrayList(Window) = .empty,
    dirty: bool = true,

    fn deinit(d: *Doc, gpa: Allocator) void {
        d.freeWindows(gpa);
        d.windows.deinit(gpa);
        gpa.free(d.path);
        gpa.free(d.text);
    }

    fn freeWindows(d: *Doc, gpa: Allocator) void {
        for (d.windows.items) |w| gpa.free(w.tokens);
        d.windows.clearRetainingCapacity();
    }

    fn rebuild(d: *Doc, gpa: Allocator) !void {
        if (!d.dirty) return;
        d.freeWindows(gpa);
        var starts: std.ArrayList(usize) = .empty;
        defer starts.deinit(gpa);
        try starts.append(gpa, 0);
        for (d.text, 0..) |c, i| if (c == '\n' and i + 1 < d.text.len) try starts.append(gpa, i + 1);
        const n = starts.items.len;
        var line: usize = 0;
        while (true) : (line += window_step) {
            const last = @min(n, line + window_lines);
            const start = starts.items[line];
            const end = if (last < n) starts.items[last] else d.text.len;
            const tokens = try identifiers(gpa, d.text[start..end]);
            errdefer gpa.free(tokens);
            try d.windows.append(gpa, .{ .start = start, .end = end, .tokens = tokens });
            if (last >= n) break;
        }
        d.dirty = false;
    }
};

pub const NeighbourIndex = struct {
    gpa: Allocator,
    /// Most recent first.
    docs: std.ArrayList(Doc) = .empty,

    pub fn init(gpa: Allocator) NeighbourIndex {
        return .{ .gpa = gpa };
    }

    pub fn deinit(n: *NeighbourIndex) void {
        for (n.docs.items) |*d| d.deinit(n.gpa);
        n.docs.deinit(n.gpa);
    }

    /// Document `id` was viewed or edited and now reads `text` (copied).
    /// `excluded`: the security policy keeps it out of prompts.
    pub fn note(n: *NeighbourIndex, id: u64, path: []const u8, text: []const u8, excluded: bool) !void {
        const i = n.indexOf(id);
        var d: Doc = if (i) |x| n.docs.orderedRemove(x) else .{ .id = id, .path = &.{}, .text = &.{}, .excluded = excluded };
        errdefer d.deinit(n.gpa);
        if (!std.mem.eql(u8, d.path, path)) {
            const p = try n.gpa.dupe(u8, path);
            n.gpa.free(d.path);
            d.path = p;
        }
        if (!std.mem.eql(u8, d.text, text)) {
            const t = try n.gpa.dupe(u8, text);
            n.gpa.free(d.text);
            d.text = t;
            d.dirty = true;
        }
        d.excluded = excluded;
        try n.docs.insert(n.gpa, 0, d);
        while (n.docs.items.len > max_docs) {
            var old = n.docs.pop().?;
            old.deinit(n.gpa);
        }
    }

    pub fn forget(n: *NeighbourIndex, id: u64) void {
        const i = n.indexOf(id) orelse return;
        var d = n.docs.orderedRemove(i);
        d.deinit(n.gpa);
    }

    /// Up to `out.len` windows of documents other than `exclude`, best
    /// first; returns how many. Texts and paths point into the index
    /// (valid until the next `note` or `forget`).
    pub fn top(n: *NeighbourIndex, query: []const u32, exclude: u64, out: []Snippet) !usize {
        var got: usize = 0;
        for (n.docs.items) |*d| {
            if (d.id == exclude or d.excluded) continue;
            try d.rebuild(n.gpa);
            for (d.windows.items) |w| {
                const s = jaccard(query, w.tokens);
                if (s <= 0) continue;
                insertRanked(out, &got, .{ .path = d.path, .text = d.text[w.start..w.end], .score = s });
            }
        }
        return got;
    }

    /// The best window of document `id` that does not overlap bytes
    /// `skip` (the prefix and suffix already in the prompt).
    pub fn bestIn(n: *NeighbourIndex, id: u64, query: []const u32, skip: [2]usize) !?Snippet {
        const i = n.indexOf(id) orelse return null;
        const d = &n.docs.items[i];
        if (d.excluded) return null;
        try d.rebuild(n.gpa);
        var best: ?Snippet = null;
        for (d.windows.items) |w| {
            if (w.start < skip[1] and w.end > skip[0]) continue;
            const s = jaccard(query, w.tokens);
            if (s > 0 and (best == null or s > best.?.score)) best = .{ .path = d.path, .text = d.text[w.start..w.end], .score = s };
        }
        return best;
    }

    fn indexOf(n: *const NeighbourIndex, id: u64) ?usize {
        for (n.docs.items, 0..) |d, i| if (d.id == id) return i;
        return null;
    }
};

fn insertRanked(out: []Snippet, got: *usize, s: Snippet) void {
    var i = got.*;
    if (i == out.len) {
        if (out.len == 0 or s.score <= out[out.len - 1].score) return;
        i -= 1;
    } else got.* += 1;
    while (i > 0 and out[i - 1].score < s.score) : (i -= 1) out[i] = out[i - 1];
    out[i] = s;
}

/// The identifier hashes of `text`, sorted and unique (caller owns).
/// Identifiers are ASCII letters, digits and `_`, not starting with a
/// digit, at least two bytes long.
pub fn identifiers(gpa: Allocator, text: []const u8) ![]u32 {
    var out: std.ArrayList(u32) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (!(std.ascii.isAlphabetic(c) or c == '_')) {
            i += 1;
            continue;
        }
        const s = i;
        while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '_')) i += 1;
        if (i - s >= 2) try out.append(gpa, @truncate(std.hash.Wyhash.hash(0, text[s..i])));
    }
    std.mem.sortUnstable(u32, out.items, {}, std.sort.asc(u32));
    var w: usize = 0;
    for (out.items, 0..) |x, k| {
        if (k > 0 and x == out.items[w - 1]) continue;
        out.items[w] = x;
        w += 1;
    }
    out.shrinkRetainingCapacity(w);
    return out.toOwnedSlice(gpa);
}

/// |a ∩ b| / |a ∪ b| of two sorted unique sets.
pub fn jaccard(a: []const u32, b: []const u32) f32 {
    if (a.len == 0 or b.len == 0) return 0;
    var i: usize = 0;
    var j: usize = 0;
    var common: usize = 0;
    while (i < a.len and j < b.len) {
        if (a[i] == b[j]) {
            common += 1;
            i += 1;
            j += 1;
        } else if (a[i] < b[j]) i += 1 else j += 1;
    }
    return @as(f32, @floatFromInt(common)) / @as(f32, @floatFromInt(a.len + b.len - common));
}
