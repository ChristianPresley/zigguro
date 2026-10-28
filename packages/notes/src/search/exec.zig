//! Query execution (E08.F06.S03.T01). A query tree evaluates to a set of
//! doc slots, narrowing a candidate set as it goes:
//!   1. metadata filters (`tag:` with nested tags, `[prop]`, `file:`,
//!      `path:`) test note metadata;
//!   2. terms intersect posting lists (a term of 3+ bytes also matches
//!      indexed words it prefixes, so `meet` finds `meeting`);
//!   3. verification operators (phrases, `/regex/`, `line:`, `block:`,
//!      `section:`, `task*:`, `match-case:`) run on the text of the
//!      remaining candidates.
//! AND evaluates its cheap children first. Matches are ranked by BM25F
//! over the query's positive terms (filters add no score), then by path.
//! Case-insensitive substring tests fold ASCII only.
//!
//! Text checks that only narrow the result (not under `-` or `OR`) are
//! deferred: the candidates are ranked first and checked best first,
//! stopping once `k` pass, so a phrase or `/regex/` over many candidates
//! reads only as many notes as it needs.

const std = @import("std");
const zg_regex = @import("zg_regex");
const query = @import("query.zig");
const bm25 = @import("bm25.zig");
const tokenize = @import("tokenize.zig");
const postings_mod = @import("postings.zig");
const search_index = @import("search_index.zig");
const retriever = @import("retriever.zig");
const snippets = @import("snippets.zig");
const note_mod = @import("../vault/note.zig");
const frontmatter = @import("zg_frontmatter").frontmatter;
const names = @import("../index/names.zig");

const Allocator = std.mem.Allocator;
const QueryAst = query.QueryAst;
const OpKind = query.OpKind;
const SearchIndex = search_index.SearchIndex;
const Entry = @import("../index/note_index.zig").Entry;
const Scored = retriever.Scored;
const Set = std.DynamicBitSetUnmanaged;

/// Appends the top `k` matches of `q`, best first. `out` uses `gpa`.
pub fn search(s: *SearchIndex, gpa: Allocator, q: *const QueryAst, k: u32, out: *std.ArrayList(Scored)) !void {
    const ix = s.ix;
    ix.mutex.lockUncancelable(ix.io);
    defer ix.mutex.unlock(ix.io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c: Ctx = .{ .s = s, .a = arena.allocator(), .n = s.postings.slots() };
    defer c.deinit();
    var live = try Set.initEmpty(c.a, c.n);
    for (s.postings.docs.items, 0..) |d, i| if (d.live and c.entry(@intCast(i)) != null) live.set(i);
    if (q.* == .and_ and q.and_.len == 0) return;
    c.deferring = true;
    const hits = try c.eval(q, live);
    c.deferring = false;
    // Score.
    var terms: std.StringArrayHashMapUnmanaged(void) = .empty;
    try c.scoreTerms(q, &terms);
    const scores = try c.a.alloc(f32, c.n);
    @memset(scores, 0);
    const acc = try c.a.alloc(f32, c.n);
    @memset(acc, 0);
    var touched: std.ArrayList(u32) = .empty;
    const avg = bm25.averages(&s.postings);
    var ids: std.AutoArrayHashMapUnmanaged(u32, void) = .empty;
    for (terms.keys()) |t| {
        for (try c.expand(t, true)) |id| try ids.put(c.a, id, {});
    }
    for (ids.keys()) |id| try bm25.accumulate(&s.postings, &s.params, &avg, id, acc, scores, &touched, c.a);
    var ranked: std.ArrayList(Ranked) = .empty;
    var it = hits.iterator(.{});
    while (it.next()) |doc| try ranked.append(c.a, .{ .doc = @intCast(doc), .score = scores[doc], .path = c.entry(@intCast(doc)).?.path });
    std.mem.sort(Ranked, ranked.items, {}, Ranked.lt);
    // The deferred checks, best first, until `k` pass.
    var n_top: usize = 0;
    for (ranked.items) |r| {
        if (n_top == k) break;
        if (!try c.passesDeferred(r.doc)) continue;
        ranked.items[n_top] = r;
        n_top += 1;
    }
    const top = ranked.items[0..n_top];
    try out.ensureUnusedCapacity(gpa, top.len);
    var hl_terms: std.StringHashMapUnmanaged(void) = .empty;
    for (terms.keys()) |t| try hl_terms.put(c.a, t, {});
    for (top) |r| {
        var sc: Scored = .{ .note = s.postings.docs.items[r.doc].id, .score = r.score };
        try c.snippetsFor(q, r.doc, &hl_terms, &sc);
        out.appendAssumeCapacity(sc);
    }
}

const Ranked = struct {
    doc: u32,
    score: f32,
    path: []const u8,

    fn lt(_: void, a: Ranked, b: Ranked) bool {
        if (a.score != b.score) return a.score > b.score;
        return std.mem.lessThan(u8, a.path, b.path);
    }
};

const Scope = enum { all, body };

const Ctx = struct {
    s: *SearchIndex,
    a: Allocator,
    n: usize,
    case_sensitive: bool = false,
    regex_ci: bool = false,
    scope: Scope = .all,
    texts: std.AutoHashMapUnmanaged(u32, ?[]const u8) = .empty,
    regexes: std.AutoHashMapUnmanaged(u64, ?Compiled) = .empty,
    expansions: std.StringHashMapUnmanaged([]const u32) = .empty,
    tok_a: tokenize.Tokenizer = .{},
    tok_b: tokenize.Tokenizer = .{},
    /// Text checks may be deferred (`Deferred`): set while evaluating the
    /// query for ranking, cleared under `-` and `OR`.
    deferring: bool = false,
    deferred: std.ArrayList(Deferred) = .empty,

    const Compiled = struct { re: zg_regex.Regex, cache: zg_regex.Cache };

    /// A text check left for the ranked candidates, with the settings in
    /// force where it appeared.
    const Deferred = struct {
        kind: enum { text, unit, task },
        q: *const QueryAst,
        op: OpKind = .line,
        scope: Scope,
        case_sensitive: bool,
        regex_ci: bool,
    };

    fn deferCheck(c: *Ctx, d: Deferred) !void {
        try c.deferred.append(c.a, d);
    }

    /// Whether `doc` passes every deferred check.
    fn passesDeferred(c: *Ctx, doc: u32) !bool {
        const saved = .{ c.scope, c.case_sensitive, c.regex_ci };
        defer {
            c.scope = saved[0];
            c.case_sensitive = saved[1];
            c.regex_ci = saved[2];
        }
        for (c.deferred.items) |d| {
            c.scope = d.scope;
            c.case_sensitive = d.case_sensitive;
            c.regex_ci = d.regex_ci;
            const ok = switch (d.kind) {
                .text => try c.textMatches(d.q, doc),
                .unit => try c.unitMatch(d.op, d.q, doc),
                .task => try c.taskMatch(d.op, d.q, doc) != null,
            };
            if (!ok) return false;
        }
        return true;
    }

    fn here(c: *const Ctx, kind: @FieldType(Deferred, "kind"), q: *const QueryAst, op: OpKind) Deferred {
        return .{ .kind = kind, .q = q, .op = op, .scope = c.scope, .case_sensitive = c.case_sensitive, .regex_ci = c.regex_ci };
    }

    fn deinit(c: *Ctx) void {
        var it = c.regexes.valueIterator();
        while (it.next()) |r| if (r.*) |*x| {
            x.cache.deinit();
            x.re.deinit(c.a);
        };
    }

    fn entry(c: *Ctx, doc: u32) ?*const Entry {
        const d = c.s.postings.docs.items[doc];
        if (!d.live) return null;
        return c.s.ix.entries.get(@bitCast(d.id));
    }

    /// The note's bytes, or null when unavailable.
    fn noteText(c: *Ctx, doc: u32) !?[]const u8 {
        const gop = try c.texts.getOrPut(c.a, doc);
        if (gop.found_existing) return gop.value_ptr.*;
        gop.value_ptr.* = null;
        const e = c.entry(doc) orelse return null;
        const t = (try c.s.text(c.a, c.s.postings.docs.items[doc].id, e.path)) orelse return null;
        gop.value_ptr.* = t.bytes;
        return t.bytes;
    }

    /// The text verification runs on: the body under `content:`, else
    /// the whole note.
    fn scopeText(c: *Ctx, doc: u32) !?[]const u8 {
        const t = (try c.noteText(doc)) orelse return null;
        if (c.scope == .body) return search_index.bodyOf(&c.entry(doc).?.meta, t);
        return t;
    }

    /// Term ids for folded `tok`: the exact term, plus (3+ bytes) the
    /// indexed terms it prefixes, at most 128.
    fn expand(c: *Ctx, tok: []const u8, prefix: bool) ![]const u32 {
        if (!prefix or tok.len < 3) {
            const id = c.s.postings.termId(tok) orelse return &.{};
            const one = try c.a.alloc(u32, 1);
            one[0] = id;
            return one;
        }
        if (c.expansions.get(tok)) |e| return e;
        var out: std.ArrayList(u32) = .empty;
        if (c.s.postings.termId(tok)) |id| try out.append(c.a, id);
        for (c.s.postings.term_text.items, 0..) |t, id| {
            if (out.items.len >= 128) break;
            if (t.len > tok.len and std.mem.startsWith(u8, t, tok) and c.s.postings.df.items[id] > 0) try out.append(c.a, @intCast(id));
        }
        try c.expansions.put(c.a, try c.a.dupe(u8, tok), out.items);
        return out.items;
    }

    /// Docs holding any of `ids` in the fields of the current scope.
    fn postingSet(c: *Ctx, ids: []const u32) !Set {
        var set = try Set.initEmpty(c.a, c.n);
        for (ids) |id| for (c.s.postings.lists.items[id].items) |p| {
            if (c.scope == .body and p.field != .body and p.field != .headings) continue;
            set.set(p.doc);
        };
        return set;
    }

    fn folded(c: *Ctx, s: []const u8) ![][]const u8 {
        try c.tok_a.run(c.a, s);
        const out = try c.a.alloc([]const u8, c.tok_a.len());
        for (out, 0..) |*o, i| o.* = try c.a.dupe(u8, c.tok_a.get(i).text);
        return out;
    }

    fn eval(c: *Ctx, q: *const QueryAst, cand: Set) anyerror!Set {
        switch (q.*) {
            .term => |t| {
                const toks = try c.folded(t.text);
                var set = try cand.clone(c.a);
                for (toks) |tok| {
                    const ps = try c.postingSet(try c.expand(tok, true));
                    set.setIntersection(ps);
                }
                // A punctuation-only term, a multi-word term (`foo-bar`)
                // or exact case: check the text.
                if (toks.len != 1 or c.case_sensitive) try c.verify(q, &set);
                return set;
            },
            .phrase => |words| {
                var set = try cand.clone(c.a);
                for (words) |w| for (try c.folded(w)) |tok| {
                    set.setIntersection(try c.postingSet(try c.expand(tok, false)));
                };
                if (words.len > 0) try c.verify(q, &set);
                return set;
            },
            .regex => {
                var set = try cand.clone(c.a);
                try c.verify(q, &set);
                return set;
            },
            .and_ => |items| {
                var set = try cand.clone(c.a);
                for ([_]bool{ true, false }) |cheap_pass| for (items) |*it| {
                    if (isCheap(it) != cheap_pass) continue;
                    set = try c.eval(it, set);
                };
                return set;
            },
            .or_ => |items| {
                const saved = c.deferring;
                c.deferring = false;
                defer c.deferring = saved;
                var set = try Set.initEmpty(c.a, c.n);
                for (items) |*it| set.setUnion(try c.eval(it, cand));
                return set;
            },
            .not => |inner| {
                const saved = c.deferring;
                c.deferring = false;
                defer c.deferring = saved;
                var r = try c.eval(inner, cand);
                r.toggleAll();
                r.setIntersection(cand);
                return r;
            },
            .prop => |pr| {
                var set = try cand.clone(c.a);
                var it = cand.iterator(.{});
                while (it.next()) |doc| if (!propMatches(&c.entry(@intCast(doc)).?.meta, pr.name, pr.cmp, pr.value)) set.unset(doc);
                return set;
            },
            .op => |o| return c.evalOp(o.kind, o.arg, cand),
        }
    }

    fn evalOp(c: *Ctx, kind: OpKind, arg: *const QueryAst, cand: Set) !Set {
        switch (kind) {
            .file, .path, .tag => {
                var set = try cand.clone(c.a);
                var it = cand.iterator(.{});
                while (it.next()) |doc| if (!try c.metaMatch(kind, arg, c.entry(@intCast(doc)).?)) set.unset(doc);
                return set;
            },
            .content => {
                const saved = c.scope;
                c.scope = .body;
                defer c.scope = saved;
                return c.eval(arg, cand);
            },
            .match_case, .ignore_case => {
                const saved = .{ c.case_sensitive, c.regex_ci };
                c.case_sensitive = kind == .match_case;
                c.regex_ci = kind == .ignore_case;
                defer {
                    c.case_sensitive = saved[0];
                    c.regex_ci = saved[1];
                }
                return c.eval(arg, cand);
            },
            .line, .block, .section => {
                var set = try c.eval(arg, cand);
                if (c.deferring) {
                    try c.deferCheck(c.here(.unit, arg, kind));
                    return set;
                }
                var it = set.iterator(.{});
                var drop: std.ArrayList(usize) = .empty;
                while (it.next()) |doc| if (!try c.unitMatch(kind, arg, @intCast(doc))) try drop.append(c.a, doc);
                for (drop.items) |d| set.unset(d);
                return set;
            },
            .task, .task_todo, .task_done => {
                var set = try c.eval(arg, cand);
                if (c.deferring) {
                    try c.deferCheck(c.here(.task, arg, kind));
                    return set;
                }
                var it = set.iterator(.{});
                var drop: std.ArrayList(usize) = .empty;
                while (it.next()) |doc| if (try c.taskMatch(kind, arg, @intCast(doc)) == null) try drop.append(c.a, doc);
                for (drop.items) |d| set.unset(d);
                return set;
            },
        }
    }

    /// Drops the docs of `set` whose text does not match `q` (or defers
    /// the check to the ranked candidates).
    fn verify(c: *Ctx, q: *const QueryAst, set: *Set) !void {
        if (c.deferring) return c.deferCheck(c.here(.text, q, .line));
        var drop: std.ArrayList(usize) = .empty;
        var it = set.iterator(.{});
        while (it.next()) |doc| {
            if (!try c.textMatches(q, @intCast(doc))) try drop.append(c.a, doc);
        }
        for (drop.items) |d| set.unset(d);
    }

    /// Whether the title or the scope's text of `doc` matches `q`.
    fn textMatches(c: *Ctx, q: *const QueryAst, doc: u32) !bool {
        const e = c.entry(doc).?;
        return (c.scope == .all and try c.matchText(q, e.meta.title, c.case_sensitive)) or
            if (try c.scopeText(doc)) |t| try c.matchText(q, t, c.case_sensitive) else false;
    }

    /// Whether `text` matches `q` as plain text.
    fn matchText(c: *Ctx, q: *const QueryAst, text: []const u8, cs: bool) anyerror!bool {
        switch (q.*) {
            .term => |t| return contains(text, t.text, cs),
            .phrase => |words| return c.matchPhrase(words, text, cs),
            .regex => |r| {
                const re = (try c.regex(r)) orelse return false;
                return re.re.isMatch(&re.cache, .fromSlice(text));
            },
            .and_ => |items| {
                for (items) |*it| if (!try c.matchText(it, text, cs)) return false;
                return true;
            },
            .or_ => |items| {
                for (items) |*it| if (try c.matchText(it, text, cs)) return true;
                return false;
            },
            .not => |inner| return !try c.matchText(inner, text, cs),
            .op => |o| return switch (o.kind) {
                .content, .line, .block, .section, .task, .task_todo, .task_done => c.matchText(o.arg, text, cs),
                .match_case => c.matchText(o.arg, text, true),
                .ignore_case => c.matchText(o.arg, text, false),
                .tag => if (o.arg.* == .term) blk: {
                    const t = o.arg.term.text;
                    const bare = if (t.len > 0 and t[0] == '#') t[1..] else t;
                    const needle = try std.mem.concat(c.a, u8, &.{ "#", bare });
                    break :blk contains(text, needle, false);
                } else true,
                // Note-level filters, already applied around a unit test.
                .file, .path => true,
            },
            .prop => return true,
        }
    }

    fn matchPhrase(c: *Ctx, words: []const []const u8, text: []const u8, cs: bool) !bool {
        if (words.len == 0) return true;
        const joined = try std.mem.join(c.a, " ", words);
        try c.tok_a.run(c.a, joined);
        const n = c.tok_a.len();
        if (n == 0) return contains(text, joined, cs);
        try c.tok_b.run(c.a, text);
        const m = c.tok_b.len();
        if (m < n) return false;
        var i: usize = 0;
        outer: while (i + n <= m) : (i += 1) {
            for (0..n) |j| {
                const want = c.tok_a.get(j);
                const got = c.tok_b.get(i + j);
                if (!std.mem.eql(u8, want.text, got.text)) continue :outer;
                if (cs and !std.mem.eql(u8, joined[want.start..want.end], text[got.start..got.end])) continue :outer;
            }
            return true;
        }
        return false;
    }

    fn regex(c: *Ctx, pattern: []const u8) !?*Compiled {
        const key = std.hash.Wyhash.hash(@intFromBool(c.regex_ci), pattern);
        const gop = try c.regexes.getOrPut(c.a, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = null;
            var re = zg_regex.Regex.compile(c.a, pattern, .{ .case_insensitive = c.regex_ci }) catch |e| switch (e) {
                error.OutOfMemory => return e,
                else => return null,
            };
            gop.value_ptr.* = .{ .re = re, .cache = re.newCache(c.a) catch |e| {
                re.deinit(c.a);
                return e;
            } };
        }
        if (gop.value_ptr.*) |*x| return x;
        return null;
    }

    /// `file:`, `path:` and `tag:` against note metadata.
    fn metaMatch(c: *Ctx, kind: OpKind, q: *const QueryAst, e: *const Entry) anyerror!bool {
        switch (q.*) {
            .and_ => |items| {
                for (items) |*it| if (!try c.metaMatch(kind, it, e)) return false;
                return true;
            },
            .or_ => |items| {
                for (items) |*it| if (try c.metaMatch(kind, it, e)) return true;
                return false;
            },
            .not => |inner| return !try c.metaMatch(kind, inner, e),
            .op => |o| return switch (o.kind) {
                .match_case => c.metaMatchCase(kind, o.arg, e, true),
                .ignore_case => c.metaMatchCase(kind, o.arg, e, false),
                else => c.metaMatch(kind, o.arg, e),
            },
            .prop => return true,
            .term, .phrase, .regex => {},
        }
        switch (kind) {
            .file => return c.matchText(q, names.basename(e.path), c.case_sensitive),
            .path => return c.matchText(q, e.path, c.case_sensitive),
            else => {},
        }
        // Tags: a term names a tag and its nested tags.
        const want = switch (q.*) {
            .term => |t| t.text,
            .phrase => |w| try std.mem.join(c.a, " ", w),
            else => {
                for (e.meta.tags) |t| if (try c.matchText(q, t.display, c.case_sensitive)) return true;
                return false;
            },
        };
        const bare = if (want.len > 0 and want[0] == '#') want[1..] else want;
        var key: std.ArrayList(u8) = .empty;
        try tokenize.foldInto(&key, c.a, bare);
        for (e.meta.tags) |t| {
            if (std.mem.eql(u8, t.key, key.items)) return true;
            if (t.key.len > key.items.len and std.mem.startsWith(u8, t.key, key.items) and t.key[key.items.len] == '/') return true;
        }
        return false;
    }

    fn metaMatchCase(c: *Ctx, kind: OpKind, q: *const QueryAst, e: *const Entry, cs: bool) !bool {
        const saved = c.case_sensitive;
        c.case_sensitive = cs;
        defer c.case_sensitive = saved;
        return c.metaMatch(kind, q, e);
    }

    /// Whether some line, block or section of the note matches `q`.
    fn unitMatch(c: *Ctx, kind: OpKind, q: *const QueryAst, doc: u32) !bool {
        const t = (try c.noteText(doc)) orelse return false;
        const m = &c.entry(doc).?.meta;
        const body_start: usize = if (m.fm_range) |r| @min(r[1], t.len) else 0;
        var units: std.ArrayList([2]usize) = .empty;
        try splitUnits(c.a, kind, m, t, body_start, &units);
        for (units.items) |u| if (try c.matchText(q, t[u[0]..u[1]], c.case_sensitive)) return true;
        return false;
    }

    /// The first task of the wanted status whose text matches `q`.
    fn taskMatch(c: *Ctx, kind: OpKind, q: *const QueryAst, doc: u32) !?note_mod.Task {
        const m = &c.entry(doc).?.meta;
        if (m.tasks.len == 0) return null;
        const t = (try c.noteText(doc)) orelse return null;
        for (m.tasks) |task| {
            if (kind == .task_todo and task.done()) continue;
            if (kind == .task_done and !task.done()) continue;
            const r = task.text;
            if (r[1] > t.len) continue;
            if (try c.matchText(q, t[r[0]..r[1]], c.case_sensitive)) return task;
        }
        return null;
    }

    /// Folded words that score: positive terms and phrase words outside
    /// filters and negations.
    fn scoreTerms(c: *Ctx, q: *const QueryAst, out: *std.StringArrayHashMapUnmanaged(void)) !void {
        switch (q.*) {
            .term => |t| for (try c.folded(t.text)) |w| try out.put(c.a, w, {}),
            .phrase => |words| for (words) |w| for (try c.folded(w)) |x| try out.put(c.a, x, {}),
            .and_, .or_ => |items| for (items) |*it| try c.scoreTerms(it, out),
            .op => |o| switch (o.kind) {
                .file, .path, .tag => {},
                else => try c.scoreTerms(o.arg, out),
            },
            .not, .regex, .prop => {},
        }
    }

    fn snippetsFor(c: *Ctx, q: *const QueryAst, doc: u32, terms: *const std.StringHashMapUnmanaged(void), out: *Scored) !void {
        const t = (try c.noteText(doc)) orelse return;
        const m = &c.entry(doc).?.meta;
        // A task query shows the task line.
        if (findTaskOp(q)) |o| if (try c.taskMatch(o.kind, o.arg, doc)) |task| {
            out.snippets[0] = snippets.lineSnippet(t, task.text[0], task.line);
            out.n_snippets = 1;
            return;
        };
        const body_start: u32 = if (m.fm_range) |r| @min(r[1], @as(u32, @intCast(t.len))) else 0;
        out.n_snippets = try snippets.extract(c.a, &c.tok_b, t, body_start, terms, &out.snippets);
    }
};

fn findTaskOp(q: *const QueryAst) ?struct { kind: OpKind, arg: *const QueryAst } {
    switch (q.*) {
        .op => |o| switch (o.kind) {
            .task, .task_todo, .task_done => return .{ .kind = o.kind, .arg = o.arg },
            else => return findTaskOp(o.arg),
        },
        .and_, .or_ => |items| for (items) |*it| if (findTaskOp(it)) |x| return x,
        else => {},
    }
    return null;
}

/// Metadata-only nodes, evaluated first inside an AND.
fn isCheap(q: *const QueryAst) bool {
    return switch (q.*) {
        .term, .prop => true,
        .op => |o| o.kind == .file or o.kind == .path or o.kind == .tag,
        .not => |inner| isCheap(inner),
        .and_, .or_ => |items| for (items) |*it| {
            if (!isCheap(it)) break false;
        } else true,
        .phrase, .regex => false,
    };
}

fn contains(hay: []const u8, needle: []const u8, cs: bool) bool {
    if (cs) return std.mem.indexOf(u8, hay, needle) != null;
    return std.ascii.indexOfIgnoreCase(hay, needle) != null;
}

/// Byte ranges of the note's lines, blocks (paragraphs between blank
/// lines) or sections (from one heading to the next), after `start`.
pub fn splitUnits(a: Allocator, kind: OpKind, m: *const note_mod.NoteMeta, t: []const u8, start: usize, out: *std.ArrayList([2]usize)) !void {
    switch (kind) {
        .line => {
            var i = start;
            while (i <= t.len) {
                const e = std.mem.indexOfScalarPos(u8, t, i, '\n') orelse t.len;
                try out.append(a, .{ i, e });
                i = e + 1;
            }
        },
        .block => {
            var i = start;
            var block_start: ?usize = null;
            while (i < t.len) {
                const e = std.mem.indexOfScalarPos(u8, t, i, '\n') orelse t.len;
                const blank = std.mem.trim(u8, t[i..e], " \t\r").len == 0;
                if (blank) {
                    if (block_start) |b| try out.append(a, .{ b, i });
                    block_start = null;
                } else if (block_start == null) block_start = i;
                i = e + 1;
            }
            if (block_start) |b| try out.append(a, .{ b, t.len });
        },
        .section => {
            var prev = start;
            for (m.headings) |h| {
                const hs = @min(h.src[0], t.len);
                if (hs < start) continue;
                if (hs > prev) try out.append(a, .{ prev, hs });
                prev = hs;
            }
            try out.append(a, .{ prev, t.len });
        },
        else => unreachable,
    }
}

/// Whether property `name` of `m` satisfies the filter. Dates compare
/// chronologically, numbers numerically, other values as
/// case-insensitive strings; a list matches if any item does.
pub fn propMatches(m: *const note_mod.NoteMeta, name: []const u8, cmp: query.PropCmp, value: ?[]const u8) bool {
    const p = for (m.props) |*p| {
        if (std.ascii.eqlIgnoreCase(p.name, name)) break p;
    } else return false;
    switch (cmp) {
        .exists => return true,
        .is_null => return isEmpty(p.node.value),
        else => {},
    }
    const v = value orelse return false;
    return valueMatches(p.node.value, cmp, v);
}

fn isEmpty(v: frontmatter.Value) bool {
    return switch (v) {
        .null => true,
        .string => |s| s.len == 0,
        .list => |l| l.len == 0,
        else => false,
    };
}

fn valueMatches(v: frontmatter.Value, cmp: query.PropCmp, q: []const u8) bool {
    switch (v) {
        .list => |items| {
            for (items) |it| if (valueMatches(it.value, cmp, q)) return true;
            return false;
        },
        .int, .float => {
            const x: f64 = if (v == .int) @floatFromInt(v.int) else v.float;
            const y = std.fmt.parseFloat(f64, q) catch return cmp == .eq and false;
            return order(cmp, std.math.order(x, y));
        },
        .date, .datetime => {
            const d: frontmatter.Date = if (v == .date) v.date else v.datetime.date;
            const qd = frontmatter.parseDate(q[0..@min(q.len, 10)]) orelse return false;
            const ord = std.math.order(dayKey(d), dayKey(qd));
            return order(cmp, ord);
        },
        .bool => |b| return cmp == .eq and std.ascii.eqlIgnoreCase(q, if (b) "true" else "false"),
        .string, .raw => |s| {
            if (cmp == .eq) return std.ascii.eqlIgnoreCase(s, q);
            return order(cmp, orderIgnoreCase(s, q));
        },
        .null, .map => return false,
    }
}

fn order(cmp: query.PropCmp, o: std.math.Order) bool {
    return switch (cmp) {
        .eq => o == .eq,
        .lt => o == .lt,
        .gt => o == .gt,
        else => false,
    };
}

fn dayKey(d: frontmatter.Date) i64 {
    return @as(i64, d.y) * 512 + @as(i64, d.m) * 32 + d.d;
}

fn orderIgnoreCase(a: []const u8, b: []const u8) std.math.Order {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |x, y| {
        const o = std.math.order(std.ascii.toLower(x), std.ascii.toLower(y));
        if (o != .eq) return o;
    }
    return std.math.order(a.len, b.len);
}
