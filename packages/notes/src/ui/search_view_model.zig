//! The note search view's state (E08.F06.S03.T02): the query (parsed on
//! every keystroke for error spans), ranked results from a `Retriever`
//! run off the UI thread, the selection, and saved searches.
//!
//! Threads: the model lives on the UI thread. `setQuery` bumps an atomic
//! generation and spawns a job that waits out the debounce, retrieves the
//! top `detail_rows` notes (shown at once), then the top `k`, resolving
//! their rows; a job whose generation is stale (a newer query was typed)
//! drops its work. Each step parks its result in the shared slot and
//! `Notify`s the UI, whose `sync` adopts it.

const std = @import("std");
const zg_notes = @import("zg_notes");
const zg_ai_proto = @import("zg_ai_proto");
const ports = @import("ports.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const FileId = zg_notes.FileId;
const NoteIndex = zg_notes.NoteIndex;
const Retriever = zg_notes.search.Retriever;
const Scored = zg_notes.search.Scored;
const query_mod = zg_notes.search.query;
const ContentSource = zg_notes.index.mentions.ContentSource;

/// One snippet line of a result, its highlights relative to `text`.
pub const SnippetLine = struct {
    text: []const u8,
    /// The snippet's bytes in the note.
    range: [2]u32,
    /// 0-based line of `range[0]`.
    line: u32,
    highlights: []const [2]u32,
};

pub const ResultRow = struct {
    note: FileId,
    score: f32,
    /// `score` over the top score, in (0, 1].
    relevance: f32,
    title: []const u8,
    path: []const u8,
    /// Tags as written, without `#`.
    tags: []const []const u8,
    /// Empty past `Options.detail_rows`.
    snippets: []const SnippetLine,
};

pub const ParseError = struct { msg: []const u8, span: [2]u32 };

pub const Options = struct {
    gpa: Allocator,
    io: Io,
    ix: *NoteIndex,
    /// The ranking backend (BM25F, or `hybrid` behind one). It and `ix`
    /// must outlive jobs still running when the model is freed.
    retriever: Retriever,
    /// Note bytes, for snippet text.
    content: ContentSource,
    spawn: ?ports.Spawn = null,
    notify: ?ports.Notify = null,
    open: ?ports.OpenPort = null,
    debounce_ms: u32 = 80,
    k: u32 = 200,
    /// Rows whose snippet lines are read (the rest show title and path).
    detail_rows: usize = 50,
};

/// `ContextRef.search` values from this view carry this scope prefix
/// (the agent's context resolver searches notes, not the workspace).
pub const context_scope = "notes:";

pub const NoteSearchViewModel = struct {
    o: Options,
    /// The query as typed.
    query: std.ArrayList(u8) = .empty,
    parse_arena: std.heap.ArenaAllocator,
    err: ?ParseError = null,
    /// The shown results and the query they answer.
    shown: Published,
    /// A job for the current query is in flight.
    running: bool = false,
    selected: usize = 0,
    /// Bumped when `shown` changes (views reset scroll and announce).
    version: u32 = 0,
    shared: *Shared,

    pub fn init(o: Options) !*NoteSearchViewModel {
        const m = try o.gpa.create(NoteSearchViewModel);
        errdefer o.gpa.destroy(m);
        const sh = try o.gpa.create(Shared);
        sh.* = .{ .gpa = o.gpa, .io = o.io, .notify = o.notify };
        m.* = .{ .o = o, .parse_arena = .init(o.gpa), .shown = .empty(o.gpa), .shared = sh };
        return m;
    }

    pub fn deinit(m: *NoteSearchViewModel) void {
        const sh = m.shared;
        _ = sh.gen.fetchAdd(1, .acq_rel);
        sh.mutex.lockUncancelable(sh.io);
        sh.notify = null;
        if (sh.pending) |*p| p.deinit();
        sh.pending = null;
        sh.mutex.unlock(sh.io);
        sh.release();
        m.shown.deinit();
        m.query.deinit(m.o.gpa);
        m.parse_arena.deinit();
        m.o.gpa.destroy(m);
    }

    /// The query changed: parses it at once and, when it parses, starts
    /// a debounced retrieval that supersedes any older one. On a parse
    /// error the previous results stay (dimmed).
    pub fn setQuery(m: *NoteSearchViewModel, text: []const u8) void {
        m.setQueryErr(text) catch |e| {
            m.err = .{ .msg = @errorName(e), .span = .{ 0, 0 } };
        };
    }

    fn setQueryErr(m: *NoteSearchViewModel, text: []const u8) !void {
        if (std.mem.eql(u8, text, m.query.items)) return;
        m.query.clearRetainingCapacity();
        try m.query.appendSlice(m.o.gpa, text);
        const gen = m.shared.gen.fetchAdd(1, .acq_rel) + 1;
        _ = m.parse_arena.reset(.retain_capacity);
        m.err = null;
        switch (query_mod.parseQuery(m.parse_arena.allocator(), text)) {
            .err => |e| {
                m.err = .{ .msg = e.msg, .span = e.span };
                m.running = false;
                return;
            },
            .ok => {},
        }
        if (std.mem.trim(u8, text, " \t").len == 0) {
            m.running = false;
            try m.adopt(.empty(m.o.gpa));
            return;
        }
        const sh = m.shared;
        const j = try m.o.gpa.create(Job);
        errdefer m.o.gpa.destroy(j);
        j.* = .{ .sh = sh, .o = m.o, .gen = gen, .text = try m.o.gpa.dupe(u8, text) };
        _ = sh.refs.fetchAdd(1, .monotonic);
        m.running = true;
        if (m.o.spawn) |s| s.run(s.ctx, Job.run, j) else Job.run(j);
        try m.sync();
    }

    /// Adopts a finished job's results; call on the UI thread before
    /// building.
    pub fn sync(m: *NoteSearchViewModel) !void {
        const sh = m.shared;
        sh.mutex.lockUncancelable(sh.io);
        const p = sh.pending;
        sh.pending = null;
        sh.mutex.unlock(sh.io);
        const got = p orelse return;
        if (got.gen != sh.gen.load(.acquire)) {
            var x = got;
            x.deinit();
            return;
        }
        m.running = !got.final;
        try m.adopt(got);
    }

    fn adopt(m: *NoteSearchViewModel, p: Published) !void {
        // More rows for the same query keep the selection.
        const same = std.mem.eql(u8, p.query, m.shown.query);
        m.shown.deinit();
        m.shown = p;
        m.selected = if (same) @min(m.selected, p.rows.len -| 1) else 0;
        m.version +%= 1;
    }

    pub fn results(m: *const NoteSearchViewModel) []const Scored {
        return m.shown.scored;
    }

    pub fn rows(m: *const NoteSearchViewModel) []const ResultRow {
        return m.shown.rows;
    }

    pub fn parseError(m: *const NoteSearchViewModel) ?ParseError {
        return m.err;
    }

    /// The retriever failed for the shown query.
    pub fn failure(m: *const NoteSearchViewModel) ?[]const u8 {
        return m.shown.failed;
    }

    /// The shown results answer an older query (a parse error, or a newer
    /// query still running): the view dims them.
    pub fn stale(m: *const NoteSearchViewModel) bool {
        return m.err != null or !std.mem.eql(u8, m.query.items, m.shown.query);
    }

    pub fn select(m: *NoteSearchViewModel, i: usize) void {
        const n = m.shown.rows.len;
        if (n == 0) return;
        m.selected = @min(i, n - 1);
    }

    pub fn moveSelection(m: *NoteSearchViewModel, delta: isize) void {
        const n = m.shown.rows.len;
        if (n == 0) return;
        const cur: isize = @intCast(m.selected);
        m.selected = @intCast(std.math.clamp(cur + delta, 0, @as(isize, @intCast(n - 1))));
    }

    /// The best snippet's range in the selected note (the first snippet
    /// is the best-scoring one).
    pub fn bestRange(r: ResultRow) ?[2]u32 {
        if (r.snippets.len == 0) return null;
        return r.snippets[0].range;
    }

    /// Opens the selected note at its best snippet.
    pub fn openSelected(m: *NoteSearchViewModel, to_side: bool) void {
        if (m.selected >= m.shown.rows.len) return;
        const r = m.shown.rows[m.selected];
        if (m.o.open) |p| p.open(p.ctx, r.path, bestRange(r), to_side);
    }

    /// The search as agent context: `.search` with the query text,
    /// scoped to notes (borrows the query; valid until the next
    /// `setQuery`).
    pub fn attachToAgent(m: *NoteSearchViewModel) zg_ai_proto.ContextRef {
        const a = m.parse_arena.allocator();
        const s = std.mem.concat(a, u8, &.{ context_scope, m.query.items }) catch context_scope;
        return .{ .search = s };
    }

    /// A job's results, owned by its arena.
    const Published = struct {
        arena: std.heap.ArenaAllocator,
        gen: u64 = 0,
        query: []const u8 = "",
        scored: []const Scored = &.{},
        rows: []const ResultRow = &.{},
        failed: ?[]const u8 = null,
        /// The job publishes nothing after this.
        final: bool = true,

        fn empty(gpa: Allocator) Published {
            return .{ .arena = .init(gpa) };
        }

        fn deinit(p: *Published) void {
            p.arena.deinit();
        }
    };

    /// The slot jobs publish into, owned by the model and each job.
    const Shared = struct {
        refs: std.atomic.Value(u32) = .init(1),
        gen: std.atomic.Value(u64) = .init(0),
        gpa: Allocator,
        io: Io,
        mutex: Io.Mutex = .init,
        pending: ?Published = null,
        notify: ?ports.Notify,
        /// Jobs that found a newer query and dropped their work.
        dropped: std.atomic.Value(u32) = .init(0),

        fn release(sh: *Shared) void {
            if (sh.refs.fetchSub(1, .acq_rel) != 1) return;
            if (sh.pending) |*p| p.deinit();
            sh.gpa.destroy(sh);
        }

        fn current(sh: *Shared, gen: u64) bool {
            return sh.gen.load(.acquire) == gen;
        }
    };

    /// Jobs dropped because a newer query superseded them.
    pub fn droppedJobs(m: *const NoteSearchViewModel) u32 {
        return m.shared.dropped.load(.acquire);
    }

    /// One debounced retrieval; frees itself.
    const Job = struct {
        sh: *Shared,
        o: Options,
        gen: u64,
        text: []u8,

        fn run(arg: *anyopaque) void {
            const j: *Job = @ptrCast(@alignCast(arg));
            const sh = j.sh;
            defer {
                sh.gpa.free(j.text);
                sh.gpa.destroy(j);
                sh.release();
            }
            if (j.o.debounce_ms > 0 and j.o.spawn != null) {
                j.o.io.sleep(.fromMilliseconds(j.o.debounce_ms), .awake) catch {};
            }
            if (!sh.current(j.gen)) {
                _ = sh.dropped.fetchAdd(1, .acq_rel);
                return;
            }
            // The first rows render at once; the rest follow.
            const first = @min(j.o.k, @as(u32, @intCast(@max(j.o.detail_rows, 1))));
            const n = j.step(first) orelse return;
            if (n < first or first >= j.o.k) return;
            _ = j.step(j.o.k);
        }

        /// Retrieves the top `k` and publishes them; the count, or null
        /// when superseded.
        fn step(j: *Job, k: u32) ?usize {
            const sh = j.sh;
            var p: Published = .empty(sh.gpa);
            p.gen = j.gen;
            j.fill(&p, k) catch |e| {
                p.deinit();
                p = .empty(sh.gpa);
                p.gen = j.gen;
                p.query = p.arena.allocator().dupe(u8, j.text) catch "";
                p.failed = @errorName(e);
            };
            const n = p.scored.len;
            p.final = k >= j.o.k or n < k or p.failed != null;
            sh.mutex.lockUncancelable(sh.io);
            if (!sh.current(j.gen)) {
                sh.mutex.unlock(sh.io);
                _ = sh.dropped.fetchAdd(1, .acq_rel);
                p.deinit();
                return null;
            }
            if (sh.pending) |*old| old.deinit();
            sh.pending = p;
            const notify = sh.notify;
            sh.mutex.unlock(sh.io);
            ports.Notify.call(notify);
            return if (p.failed != null) 0 else n;
        }

        fn fill(j: *Job, p: *Published, k: u32) !void {
            const a = p.arena.allocator();
            p.query = try a.dupe(u8, j.text);
            const ast = switch (query_mod.parseQuery(a, j.text)) {
                .ok => |q| q,
                .err => |e| {
                    p.failed = e.msg;
                    return;
                },
            };
            // Retrievers allocate results in the index's allocator.
            var got: std.ArrayList(Scored) = .empty;
            defer got.deinit(j.o.ix.gpa);
            try j.o.retriever.retrieve(j.o.retriever.ctx, &ast, j.text, k, &got);
            if (!j.sh.current(j.gen)) return;
            p.scored = try a.dupe(Scored, got.items);
            p.rows = try resolveRows(a, j.o, p.scored);
        }
    };
};

/// Rows for `scored`: title, path and tags from the index, snippet text
/// for the first `o.detail_rows`.
fn resolveRows(a: Allocator, o: Options, scored: []const Scored) ![]const ResultRow {
    const view = try o.ix.reader();
    defer view.release();
    const top = if (scored.len > 0) scored[0].score else 1;
    var out: std.ArrayList(ResultRow) = try .initCapacity(a, scored.len);
    for (scored, 0..) |s, i| {
        const e = view.entry(s.note) orelse continue;
        var tags: std.ArrayList([]const u8) = .empty;
        for (e.meta.tags) |t| {
            const seen = for (tags.items) |x| {
                if (std.ascii.eqlIgnoreCase(x, t.display)) break true;
            } else false;
            if (!seen) try tags.append(a, t.display);
        }
        var snips: []const SnippetLine = &.{};
        if (i < o.detail_rows and s.n_snippets > 0) {
            // Only the snippet lines are kept, not the note.
            if (try o.content.read(o.content.ctx, o.gpa, s.note, e.path)) |text| {
                defer o.gpa.free(text);
                snips = try snippetLines(a, text, s);
            }
        }
        out.appendAssumeCapacity(.{
            .note = s.note,
            .score = s.score,
            .relevance = if (top > 0) std.math.clamp(s.score / top, 0, 1) else 1,
            .title = e.meta.title,
            .path = e.path,
            .tags = tags.items,
            .snippets = snips,
        });
    }
    return out.items;
}

fn snippetLines(a: Allocator, text: []const u8, s: Scored) ![]const SnippetLine {
    var out: std.ArrayList(SnippetLine) = .empty;
    for (s.snippets[0..s.n_snippets]) |sn| {
        if (sn.range[1] > text.len or sn.range[0] > sn.range[1]) continue;
        const base = sn.range[0];
        const body = try a.dupe(u8, std.mem.trimEnd(u8, text[base..sn.range[1]], "\r\n"));
        const hl = try a.alloc([2]u32, sn.n_highlights);
        for (sn.highlights[0..sn.n_highlights], hl) |h, *o| {
            const lo = @min(h[0] -| base, body.len);
            o.* = .{ @intCast(lo), @intCast(@min(@max(h[1] -| base, lo), body.len)) };
        }
        try out.append(a, .{ .text = body, .range = sn.range, .line = sn.line, .highlights = hl });
    }
    return out.items;
}

/// A saved search.
pub const Saved = struct { name: []const u8, query: []const u8 };

/// Saved searches of one vault, in `<storage>/notes/saved_searches.zon`.
pub const SavedSearches = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    items: std.ArrayList(Saved) = .empty,

    pub const file = "notes/saved_searches.zon";

    const File = struct { searches: []const Saved = &.{} };

    pub fn init(gpa: Allocator) SavedSearches {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    pub fn deinit(s: *SavedSearches) void {
        s.items.deinit(s.gpa);
        s.arena.deinit();
    }

    /// Reads the file from `storage`; a missing or unreadable file is an
    /// empty list.
    pub fn load(s: *SavedSearches, io: Io, storage: Io.Dir) !void {
        s.items.clearRetainingCapacity();
        const a = s.arena.allocator();
        const bytes = storage.readFileAlloc(io, file, a, .limited(1 << 20)) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return,
        };
        const src = try a.dupeZ(u8, bytes);
        const f = std.zon.parse.fromSliceAlloc(File, a, src, null, .{ .ignore_unknown_fields = true, .free_on_error = false }) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ParseZon => return,
        };
        try s.items.appendSlice(s.gpa, f.searches);
    }

    /// Writes the list to `storage` (atomically).
    pub fn save(s: *const SavedSearches, io: Io, storage: Io.Dir) !void {
        var out: Io.Writer.Allocating = .init(s.gpa);
        defer out.deinit();
        std.zon.stringify.serialize(File{ .searches = s.items.items }, .{}, &out.writer) catch return error.OutOfMemory;
        try out.writer.writeByte('\n');
        try storage.createDirPath(io, std.fs.path.dirname(file).?);
        var af = try storage.createFileAtomic(io, file, .{ .replace = true });
        defer af.deinit(io);
        try af.file.writeStreamingAll(io, out.written());
        try af.replace(io);
    }

    /// Adds (or renames the entry with the same query).
    pub fn put(s: *SavedSearches, name: []const u8, query: []const u8) !void {
        const a = s.arena.allocator();
        const n = try a.dupe(u8, name);
        for (s.items.items) |*it| if (std.mem.eql(u8, it.query, query)) {
            it.name = n;
            return;
        };
        try s.items.append(s.gpa, .{ .name = n, .query = try a.dupe(u8, query) });
    }

    pub fn remove(s: *SavedSearches, i: usize) void {
        if (i < s.items.items.len) _ = s.items.orderedRemove(i);
    }
};
