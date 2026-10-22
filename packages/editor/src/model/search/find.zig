//! Find in a document: pattern compilation (literal or regex, smart case,
//! whole word), the sorted match index kept current through edits, and the
//! find session that searches the viewport first, completes the count in
//! steps or from a worker over a snapshot, re-searches edited lines and
//! replaces one or all matches as one ChangeSet.
//!
//! Matches are line-bounded unless the pattern can match a newline (it
//! contains a newline or `\n`); edits then re-search only the edited lines.
//! Multiline patterns re-search the edited range plus `multiline_overlap`
//! bytes each side, so a multiline match longer than that may be missed
//! after an edit until the next full search.

const std = @import("std");
const zg_regex = @import("zg_regex");
const pt = @import("../buffer/piece_tree.zig");
const cs_mod = @import("../edit/change_set.zig");
const document = @import("../document.zig");
const snapshot_mod = @import("../snapshot.zig");
const selection = @import("../edit/selection.zig");
const replace_mod = @import("replace.zig");

const Allocator = std.mem.Allocator;
/// A byte range.
pub const Range = cs_mod.Range;
const ChangeSet = cs_mod.ChangeSet;
const Document = document.Document;
const Snapshot = snapshot_mod.Snapshot;
const PieceTree = pt.PieceTree;
const Regex = zg_regex.Regex;

/// Bytes searched around an edit for patterns that can span lines.
pub const multiline_overlap: u64 = 64 << 10;

/// How a search is run.
pub const FindOptions = struct {
    pattern: []const u8,
    /// Regex syntax; otherwise the pattern is a literal.
    regex: bool = false,
    case: enum { sensitive, insensitive, smart } = .smart,
    whole_word: bool = false,
    /// Only matches inside one of these ranges (current version at start;
    /// kept current through edits).
    in_selection: ?[]const Range = null,
    preserve_case: bool = false,
    /// Replace-all refuses above this many matches.
    max_matches: u32 = 1_000_000,
};

/// A compiled find pattern.
pub const Matcher = struct {
    re: Regex,
    /// Whether matches may span lines.
    multiline: bool,

    /// Compiles `o.pattern`. On `error.Syntax`, `diag` holds the span.
    pub fn compile(gpa: Allocator, o: FindOptions, diag: ?*zg_regex.Error) zg_regex.CompileError!Matcher {
        const insensitive = switch (o.case) {
            .sensitive => false,
            .insensitive => true,
            .smart => zg_regex.smartCaseInsensitive(o.pattern),
        };
        const re = try Regex.compile(gpa, o.pattern, .{
            .literal = !o.regex,
            .case_insensitive = insensitive,
            .whole_word = o.whole_word,
            .multi_line = true,
            .crlf = true,
            .diag = diag,
        });
        const ml = std.mem.indexOfScalar(u8, o.pattern, '\n') != null or
            (o.regex and (std.mem.indexOf(u8, o.pattern, "\\n") != null or std.mem.indexOf(u8, o.pattern, "\\s") != null or
                std.mem.indexOf(u8, o.pattern, "\\r") != null));
        return .{ .re = re, .multiline = ml };
    }

    /// Frees the regex.
    pub fn deinit(m: *Matcher, gpa: Allocator) void {
        m.re.deinit(gpa);
    }
};

fn rx(r: Range) zg_regex.Range {
    return .{ .start = r.start, .end = r.end };
}

/// Regex input over a piece tree, read in place.
pub fn treeInput(t: *const PieceTree) zg_regex.Input {
    const S = struct {
        fn chunkAt(ctx: *const anyopaque, off: u64) zg_regex.Chunk {
            const tree: *const PieceTree = @ptrCast(@alignCast(ctx));
            const p = tree.pieceAt(off);
            return .{ .base = p.base, .bytes = p.bytes };
        }
    };
    return zg_regex.Input.fromChunks(.{ .ctx = t, .chunkAtFn = S.chunkAt }, t.len());
}

/// Matches as sorted, non-overlapping ranges in current-version
/// coordinates.
pub const MatchIndex = struct {
    items: std.ArrayList(Range) = .empty,

    /// Frees the index.
    pub fn deinit(m: *MatchIndex, gpa: Allocator) void {
        m.items.deinit(gpa);
    }

    /// Number of matches.
    pub fn count(m: *const MatchIndex) u64 {
        return m.items.items.len;
    }

    /// The `i`-th match.
    pub fn nth(m: *const MatchIndex, i: u64) Range {
        return m.items.items[@intCast(i)];
    }

    /// Number of matches starting before `pos`.
    pub fn rank(m: *const MatchIndex, pos: u64) u64 {
        var lo: usize = 0;
        var hi: usize = m.items.items.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (m.items.items[mid].start < pos) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    /// Inserts ranges found against `version`, mapping them to the
    /// document's current version (dropping any an edit touched) and
    /// skipping duplicates.
    pub fn insertBatch(m: *MatchIndex, gpa: Allocator, version: u64, ranges: []const Range, doc: *const Document) Allocator.Error!void {
        for (ranges) |r0| {
            const r = if (version == doc.version) r0 else blk: {
                const es = doc.change_log.since(version) orelse return;
                var cur: ?Range = r0;
                for (es) |*e| cur = if (cur) |c| e.changes.mapRange(c, .delete_if_touched) else null;
                break :blk cur orelse continue;
            };
            try m.insert(gpa, r);
        }
    }

    /// Inserts one range unless it overlaps an existing match.
    pub fn insert(m: *MatchIndex, gpa: Allocator, r: Range) Allocator.Error!void {
        const i: usize = @intCast(m.rank(r.start));
        const items = m.items.items;
        if (i < items.len and items[i].start == r.start) return;
        if (i > 0 and items[i - 1].end > r.start) return;
        if (i < items.len and r.end > items[i].start and r.end > r.start) return;
        try m.items.insert(gpa, i, r);
    }

    /// Removes matches intersecting `r` (touching counts for empty `r`).
    pub fn removeRange(m: *MatchIndex, r: Range) void {
        const items = m.items.items;
        var lo: usize = @intCast(m.rank(r.start));
        while (lo > 0 and items[lo - 1].end > r.start) lo -= 1;
        var hi = lo;
        while (hi < items.len and items[hi].start < r.end) hi += 1;
        if (hi == lo) return;
        const n = hi - lo;
        std.mem.copyForwards(Range, items[lo..], items[hi..]);
        m.items.shrinkRetainingCapacity(items.len - n);
    }

    /// Maps every match through `cs`; matches an edit touched are dropped.
    pub fn applyChange(m: *MatchIndex, cs: *const ChangeSet) void {
        var w: usize = 0;
        for (m.items.items) |r| {
            const nr = cs.mapRange(r, .delete_if_touched) orelse continue;
            m.items.items[w] = nr;
            w += 1;
        }
        m.items.shrinkRetainingCapacity(w);
    }
};

/// Where matches go when a search runs off the session (a worker).
pub const Sink = struct {
    ctx: *anyopaque,
    /// A batch found against `version`; the slice is only valid during the
    /// call.
    batchFn: *const fn (ctx: *anyopaque, version: u64, ranges: []const Range) void,
};

/// Searches `span` of a snapshot, posting batches of up to `batch` matches
/// to `sink`. Any thread; the cache must belong to the calling thread.
/// Returns the number of matches.
pub fn searchSnapshot(gpa: Allocator, re: *const Regex, cache: *zg_regex.Cache, snap: *const Snapshot, span: Range, sink: Sink, batch: usize) Allocator.Error!u64 {
    var buf: std.ArrayList(Range) = .empty;
    defer buf.deinit(gpa);
    const in = treeInput(&snap.tree).withSpan(rx(span));
    var it = re.findIter(cache, in);
    var n: u64 = 0;
    while (it.next()) |mt| {
        if (mt.start == mt.end) continue;
        try buf.append(gpa, .{ .start = mt.start, .end = mt.end });
        n += 1;
        if (buf.items.len >= batch) {
            sink.batchFn(sink.ctx, snap.version, buf.items);
            buf.clearRetainingCapacity();
        }
    }
    if (buf.items.len > 0) sink.batchFn(sink.ctx, snap.version, buf.items);
    return n;
}

/// One find session over a live document (owner thread).
pub const FindSession = struct {
    gpa: Allocator,
    doc: *Document,
    pattern: []u8,
    opts: FindOptions,
    matcher: Matcher,
    cache: zg_regex.Cache,
    index: MatchIndex = .{},
    /// Everything before this offset (current coordinates) has been
    /// searched by the full pass.
    scanned: u64 = 0,
    complete: bool = false,
    /// `in_selection` ranges, kept current.
    scopes: std.ArrayList(Range) = .empty,

    pub const StartError = zg_regex.CompileError;

    /// Compiles the pattern and searches `viewport` synchronously.
    pub fn start(gpa: Allocator, doc: *Document, o: FindOptions, viewport: Range, diag: ?*zg_regex.Error) StartError!*FindSession {
        const s = try gpa.create(FindSession);
        errdefer gpa.destroy(s);
        const pattern = try gpa.dupe(u8, o.pattern);
        errdefer gpa.free(pattern);
        var m = try Matcher.compile(gpa, o, diag);
        errdefer m.deinit(gpa);
        var cache = try m.re.newCache(gpa);
        errdefer cache.deinit();
        s.* = .{ .gpa = gpa, .doc = doc, .pattern = pattern, .opts = o, .matcher = m, .cache = cache };
        s.opts.pattern = pattern;
        if (o.in_selection) |sel| try s.scopes.appendSlice(gpa, sel);
        s.opts.in_selection = null;
        const vp: Range = .{ .start = @min(viewport.start, doc.len()), .end = @min(viewport.end, doc.len()) };
        try s.searchRegion(s.expandRegion(vp));
        return s;
    }

    /// Ends the session.
    pub fn stop(s: *FindSession) void {
        const gpa = s.gpa;
        s.index.deinit(gpa);
        s.scopes.deinit(gpa);
        s.cache.deinit();
        s.matcher.deinit(gpa);
        gpa.free(s.pattern);
        gpa.destroy(s);
    }

    fn inScope(s: *const FindSession, r: Range) bool {
        if (s.scopes.items.len == 0) return true;
        for (s.scopes.items) |sc| if (r.start >= sc.start and r.end <= sc.end) return true;
        return false;
    }

    /// The region to search for an edit or viewport at `r`: whole lines,
    /// or `r` plus the overlap for multiline patterns.
    fn expandRegion(s: *const FindSession, r: Range) Range {
        const t = &s.doc.tree;
        if (s.matcher.multiline) {
            return .{ .start = r.start -| multiline_overlap, .end = @min(r.end + multiline_overlap, t.len()) };
        }
        const l0 = t.lineOf(r.start);
        const l1 = t.lineOf(r.end);
        const lr = t.lineRange(l1);
        return .{ .start = t.lineStart(l0), .end = lr.end + lr.eol_len };
    }

    /// Re-searches `region` of the current version, replacing its matches.
    fn searchRegion(s: *FindSession, region: Range) Allocator.Error!void {
        return s.searchRegions(&.{region});
    }

    /// Re-searches sorted, disjoint regions in one merge pass over the
    /// index (so replace-all's many small regions stay linear).
    fn searchRegions(s: *FindSession, regions: []const Range) Allocator.Error!void {
        if (regions.len == 0) return;
        var old = s.index.items;
        var out: std.ArrayList(Range) = .empty;
        errdefer out.deinit(s.gpa);
        try out.ensureTotalCapacity(s.gpa, old.items.len);
        var i: usize = 0;
        for (regions) |region| {
            // Keep matches wholly before the region.
            while (i < old.items.len and old.items[i].end <= region.start and !(old.items[i].start == region.start)) : (i += 1) try out.append(s.gpa, old.items[i]);
            // Drop matches intersecting it.
            while (i < old.items.len and old.items[i].start < region.end) i += 1;
            const in = treeInput(&s.doc.tree).withSpan(rx(region));
            var it = s.matcher.re.findIter(&s.cache, in);
            while (it.next()) |mt| {
                if (mt.start == mt.end) continue;
                const r: Range = .{ .start = mt.start, .end = mt.end };
                if (!s.inScope(r)) continue;
                if (out.items.len > 0 and out.items[out.items.len - 1].end > r.start) continue;
                try out.append(s.gpa, r);
            }
        }
        while (i < old.items.len) : (i += 1) {
            const r = old.items[i];
            if (out.items.len > 0 and out.items[out.items.len - 1].end > r.start) continue;
            try out.append(s.gpa, r);
        }
        old.deinit(s.gpa);
        s.index.items = out;
    }

    /// Continues the full search on this thread for about `max_bytes`;
    /// returns true once complete.
    pub fn step(s: *FindSession, max_bytes: u64) Allocator.Error!bool {
        if (s.complete) return true;
        const total = s.doc.len();
        var end = @min(s.scanned + max_bytes, total);
        if (!s.matcher.multiline and end < total) {
            const lr = s.doc.tree.lineRange(s.doc.tree.lineOf(end));
            end = lr.end + lr.eol_len;
        } else if (end < total) {
            end = @min(end + multiline_overlap, total);
        }
        const in = treeInput(&s.doc.tree).withSpan(rx(.{ .start = s.scanned, .end = total }));
        var it = s.matcher.re.findIter(&s.cache, in);
        var next_scan = end;
        while (it.next()) |mt| {
            if (mt.start >= end) break;
            if (mt.start == mt.end) continue;
            const r: Range = .{ .start = mt.start, .end = mt.end };
            if (s.inScope(r)) try s.index.insert(s.gpa, r);
            next_scan = @max(next_scan, mt.end);
        }
        s.scanned = @min(next_scan, total);
        if (s.scanned >= total) s.complete = true;
        return s.complete;
    }

    /// Runs the full search to completion on this thread.
    pub fn finish(s: *FindSession) Allocator.Error!void {
        while (!try s.step(4 << 20)) {}
    }

    /// Merges a batch a worker found against `version`.
    pub fn insertBatch(s: *FindSession, version: u64, ranges: []const Range) Allocator.Error!void {
        for (ranges) |r| {
            if (version == s.doc.version) {
                if (s.inScope(r)) try s.index.insert(s.gpa, r);
            } else {
                try s.index.insertBatch(s.gpa, version, &.{r}, s.doc);
            }
        }
    }

    /// Marks the full search done (a worker finished searching the
    /// snapshot it was given; edits since were re-searched by `onChange`).
    pub fn markComplete(s: *FindSession) void {
        s.complete = true;
        s.scanned = s.doc.len();
    }

    /// Keeps matches current after an edit (call from a document
    /// listener).
    pub fn onChange(s: *FindSession, ev: *const document.ChangeEvent) Allocator.Error!void {
        return s.onChangeSet(ev.changes);
    }

    /// `onChange` given just the ChangeSet that produced the current
    /// version.
    pub fn onChangeSet(s: *FindSession, cs: *const ChangeSet) Allocator.Error!void {
        s.index.applyChange(cs);
        s.scanned = cs.mapPos(s.scanned, .left);
        for (s.scopes.items) |*sc| sc.* = cs.mapRange(sc.*, .expand).?;
        // Always re-search, even beyond the scan front: a worker's batch
        // from an older version drops matches the edit touched.
        var regions: std.ArrayList(Range) = .empty;
        defer regions.deinit(s.gpa);
        for (cs.replaces, cs.new_starts) |r, ns| {
            const reg = s.expandRegion(.{ .start = ns, .end = ns + r.text.len });
            if (regions.items.len > 0 and reg.start <= regions.items[regions.items.len - 1].end) {
                const last = &regions.items[regions.items.len - 1];
                last.end = @max(last.end, reg.end);
            } else try regions.append(s.gpa, reg);
        }
        try s.searchRegions(regions.items);
    }

    /// Match count; `complete` is false while counting continues ("N+").
    pub fn matchCount(s: *const FindSession) struct { known: u64, complete: bool } {
        return .{ .known = s.index.count(), .complete = s.complete };
    }

    /// The first match starting at or after `from`, wrapping around.
    pub fn next(s: *const FindSession, from: u64) ?Range {
        const n = s.index.count();
        if (n == 0) return null;
        const i = s.index.rank(from);
        return s.index.nth(if (i < n) i else 0);
    }

    /// The last match starting before `from`, wrapping around.
    pub fn prev(s: *const FindSession, from: u64) ?Range {
        const n = s.index.count();
        if (n == 0) return null;
        const i = s.index.rank(from);
        return s.index.nth(if (i > 0) i - 1 else n - 1);
    }

    /// The 0-based position of match `r` ("i of N").
    pub fn indexOf(s: *const FindSession, r: Range) ?u64 {
        const i = s.index.rank(r.start);
        if (i < s.index.count() and s.index.nth(i).start == r.start and s.index.nth(i).end == r.end) return i;
        return null;
    }

    /// The replacement text for match `r` (template expanded, preserve
    /// case applied when enabled).
    pub fn replacementFor(s: *FindSession, r: Range, template: []const u8, gpa: Allocator) Allocator.Error![]u8 {
        const literal = !s.opts.regex and !s.opts.preserve_case;
        if (literal) return gpa.dupe(u8, template);
        var caps = try s.matcher.re.newCaptures(gpa);
        defer caps.deinit(gpa);
        const in = treeInput(&s.doc.tree).withSpan(rx(.{ .start = r.start, .end = s.doc.len() })).withAnchored(true);
        const texts = try gpa.alloc(?[]const u8, caps.len());
        defer gpa.free(texts);
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        if (s.opts.regex and s.matcher.re.captures(&s.cache, in, &caps)) {
            for (texts, 0..) |*t, i| t.* = if (caps.get(i)) |m| try s.doc.tree.copyRange(arena.allocator(), .{ .start = m.start, .end = m.end }) else null;
        } else {
            @memset(texts, null);
            texts[0] = try s.doc.tree.copyRange(arena.allocator(), r);
        }
        const sg: replace_mod.SliceGroups = .{ .texts = texts, .names = s.matcher.re.captureNames() };
        const tmpl = if (s.opts.regex) template else try escapeTemplate(arena.allocator(), template);
        return replace_mod.expandReplacement(gpa, tmpl, sg.groups(), s.opts.preserve_case);
    }

    /// Replaces match `r` and returns the next match after it (in the new
    /// version), or null when `r` is not a match.
    pub fn replaceCurrent(s: *FindSession, r: Range, template: []const u8, origin: document.EditOrigin) !?Range {
        if (s.indexOf(r) == null) return null;
        const text = try s.replacementFor(r, template, s.gpa);
        defer s.gpa.free(text);
        var cs = try ChangeSet.fromEdits(s.gpa, s.doc.len(), &.{.{ .range = r, .text = text }});
        defer cs.deinit();
        try s.applyOwn(&cs, origin);
        return s.next(r.start + text.len);
    }

    /// Completes the search and replaces every match as one ChangeSet (one
    /// undo group). Returns the number replaced.
    pub fn replaceAll(s: *FindSession, template: []const u8, origin: document.EditOrigin) !u64 {
        try s.finish();
        const n = s.index.count();
        if (n > s.opts.max_matches) return error.TooManyMatches;
        if (n == 0) return 0;
        var arena = std.heap.ArenaAllocator.init(s.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const edits = try a.alloc(cs_mod.Replace, @intCast(n));
        for (s.index.items.items, edits) |r, *e| e.* = .{ .range = r, .text = try s.replacementFor(r, template, a) };
        var cs = try ChangeSet.fromEdits(s.gpa, s.doc.len(), edits);
        defer cs.deinit();
        try s.applyOwn(&cs, origin);
        return n;
    }

    /// Applies a ChangeSet made by the session and updates the index.
    fn applyOwn(s: *FindSession, cs: *const ChangeSet, origin: document.EditOrigin) !void {
        try s.doc.applyChangeSet(cs, origin);
        try s.onChangeSet(cs);
    }

    /// A selection per match (select all occurrences).
    pub fn selectAll(s: *FindSession, gpa: Allocator) Allocator.Error![]selection.Selection {
        try s.finish();
        const out = try gpa.alloc(selection.Selection, s.index.items.items.len);
        for (s.index.items.items, out, 0..) |r, *o, i| o.* = .{ .anchor = r.start, .head = r.end, .id = @intCast(i) };
        return out;
    }
};

/// Escapes `$` and `\` so a literal-mode replacement is taken verbatim by
/// the template expander.
fn escapeTemplate(gpa: Allocator, t: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (t) |c| {
        if (c == '$') try out.append(gpa, '$') else if (c == '\\') try out.append(gpa, '\\');
        try out.append(gpa, c);
    }
    return out.items;
}

/// Literal search options.
pub const LiteralOptions = struct { case_sensitive: bool, whole_word: bool, backward: bool = false };

/// The next (or previous) occurrence of `needle` from `from`, wrapping
/// around (multi-cursor "add next occurrence"). Backward search scans
/// forward from the start, so it is O(n).
pub fn literalSearch(gpa: Allocator, snap: *const Snapshot, needle: []const u8, from: u64, o: LiteralOptions) zg_regex.CompileError!?Range {
    if (needle.len == 0) return null;
    var re = try Regex.compile(gpa, needle, .{ .literal = true, .case_insensitive = !o.case_sensitive, .whole_word = o.whole_word });
    defer re.deinit(gpa);
    var cache = try re.newCache(gpa);
    defer cache.deinit();
    const in = treeInput(&snap.tree);
    const len = snap.len();
    if (!o.backward) {
        if (re.find(&cache, in.withSpan(rx(.{ .start = @min(from, len), .end = len })))) |m| return .{ .start = m.start, .end = m.end };
        if (re.find(&cache, in)) |m| return .{ .start = m.start, .end = m.end };
        return null;
    }
    var last_before: ?Range = null;
    var last: ?Range = null;
    var it = re.findIter(&cache, in);
    while (it.next()) |m| {
        const r: Range = .{ .start = m.start, .end = m.end };
        if (r.start == r.end) continue;
        if (r.end <= from) last_before = r;
        last = r;
    }
    return last_before orelse last;
}
