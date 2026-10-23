//! The source library (E13.F05.S01.T01): every page an agent reads during
//! research becomes one Markdown note in the vault's sources folder, with
//! its URL, title, site, dates and a content hash in the frontmatter.
//!
//! Pages arrive two ways: from the agent's own `web_fetch` calls
//! (`onWebFetch`, reusing the Markdown E10 already made, never fetching
//! twice), or through `capture` with a URL (fetched through the app's
//! fetch port, under the E16 domain policy). A page is keyed by its
//! canonical URL (canon_url.zig): the same key and content only bumps
//! `fetch_count`, new content updates the note and marks it `updated`.
//!
//! Notes are written through the E12 port: auto-applied only inside the
//! sources folder when capture mode is `always`, otherwise left pending
//! for review. The index is in memory, rebuilt from the notes'
//! frontmatter at open; there is no separate database. Captured text is
//! data: it reaches models only inside tool results and `search_result`
//! blocks (`asSearchResults`), never in a system prompt.

const std = @import("std");
const zg_ai = @import("zg_ai");
const zg_ai_proto = @import("zg_ai_proto");
const zg_frontmatter = @import("zg_frontmatter");
const runs = @import("../runs/root.zig");
const canon = @import("canon_url.zig");
const extract_mod = @import("extract.zig");
const blocks_mod = @import("blocks.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const fm = zg_frontmatter.frontmatter;
const Clock = zg_ai.ratelimit.Clock;
const RunId = runs.RunId;

pub const Block = blocks_mod.Block;
/// 32 hex characters of BLAKE3 over the dedupe key.
pub const SourceId = [32]u8;

pub const Mode = enum { always, ask, never };

pub const Config = struct {
    /// Vault-relative folder for source notes (`research.sources_dir`).
    sources_dir: []const u8 = "sources",
    /// `research.capture`: capture fetches in every run (`always`), ask
    /// for each (`ask`, notes stay pending), or only in research runs.
    capture: Mode = .always,
    /// Also capture MCP tools whose name has `fetch` in it.
    capture_mcp_fetch: bool = false,
};

pub const Fetched = struct {
    body: []const u8,
    content_type: []const u8 = "text/html",
    /// After redirects.
    final_url: ?[]const u8 = null,
};

/// Fetches a URL (the app's zg_net client under E16's domain policy).
pub const FetchPort = struct {
    ctx: *anyopaque,
    fetch: *const fn (ctx: *anyopaque, a: Allocator, url: []const u8) anyerror!Fetched,
};

pub const NoteWrite = struct {
    /// Vault-relative.
    path: []const u8,
    content: []const u8,
    /// The note's current content, for an update.
    base: ?[]const u8 = null,
    /// Apply without review (only ever inside the sources folder).
    auto_apply: bool,
    summary: []const u8,
};

pub const WriteOutcome = struct { applied: bool, changeset: ?u64 = null };

/// Writes notes as E12 changesets.
pub const NotePort = struct {
    ctx: *anyopaque,
    write: *const fn (ctx: *anyopaque, w: NoteWrite) anyerror!WriteOutcome,
};

pub const Options = struct {
    clock: Clock = .real,
    fetch: ?FetchPort = null,
    notes: NotePort,
    config: Config = .{},
};

pub const CaptureOpts = struct {
    run: ?RunId = null,
    /// Overrides the configured mode.
    mode: ?Mode = null,
    /// Already fetched HTML.
    html: ?[]const u8 = null,
    /// Already converted Markdown (E10's `web_fetch` output).
    markdown: ?[]const u8 = null,
    title: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
};

pub const CaptureKind = enum { captured, updated, duplicate, pending_approval, skipped };

pub const CaptureResult = struct {
    kind: CaptureKind,
    id: ?SourceId = null,
    path: ?[]const u8 = null,
    changeset: ?u64 = null,
};

pub const Source = struct {
    id: SourceId,
    path: []const u8,
    url: []const u8,
    canonical_url: []const u8,
    title: []const u8,
    site: []const u8,
    published: ?[]const u8 = null,
    fetched: []const u8,
    content_hash: []const u8,
    fetch_count: u32 = 1,
    captured_by: ?[]const u8 = null,
    /// Written but not yet accepted.
    pending: bool = false,
    /// The note as last written (pending notes, and a read cache).
    note: ?[]const u8 = null,
};

/// A `web_fetch` that finished (E10's PostToolUse-style event, with the
/// Markdown it produced).
pub const WebFetchEvent = struct {
    tool: []const u8 = "web_fetch",
    url: []const u8,
    markdown: []const u8,
    title: ?[]const u8 = null,
    is_error: bool = false,
    run: ?RunId = null,
    /// The run is flagged `research = true`.
    research: bool = false,
};

pub const SourceLibrary = struct {
    gpa: Allocator,
    io: Io,
    vault: Io.Dir,
    o: Options,
    mutex: Io.Mutex = .init,
    arena: std.heap.ArenaAllocator,
    index: std.AutoArrayHashMapUnmanaged(SourceId, Source) = .empty,
    /// Captures that failed in `onWebFetch` (it never throws).
    failures: u32 = 0,

    pub fn open(gpa: Allocator, io: Io, vault: Io.Dir, o: Options) !*SourceLibrary {
        const lib = try gpa.create(SourceLibrary);
        errdefer gpa.destroy(lib);
        lib.* = .{ .gpa = gpa, .io = io, .vault = vault, .o = o, .arena = .init(gpa) };
        errdefer lib.arena.deinit();
        lib.o.config.sources_dir = try lib.arena.allocator().dupe(u8, std.mem.trim(u8, o.config.sources_dir, "/"));
        try lib.rebuild();
        return lib;
    }

    pub fn close(lib: *SourceLibrary) void {
        lib.index.deinit(lib.gpa);
        lib.arena.deinit();
        lib.gpa.destroy(lib);
    }

    pub fn count(lib: *const SourceLibrary) usize {
        return lib.index.count();
    }

    pub fn get(lib: *SourceLibrary, id: SourceId) ?*const Source {
        return lib.index.getPtr(id);
    }

    /// The source captured from `url` (under any URL with the same
    /// dedupe key), if there is one.
    pub fn lookup(lib: *SourceLibrary, a: Allocator, url: []const u8) Allocator.Error!?SourceId {
        const id = canon.sourceId(try canon.dedupeKey(a, try canon.canonicalize(a, url)));
        if (lib.index.contains(id)) return id;
        for (lib.index.values()) |s| if (std.mem.eql(u8, s.url, url)) return s.id;
        return null;
    }

    /// Records the note's latest text after a write through the note
    /// port (applied or pending).
    pub fn setNote(lib: *SourceLibrary, id: SourceId, text: []const u8) Allocator.Error!void {
        const s = lib.index.getPtr(id) orelse return;
        s.note = try lib.arena.allocator().dupe(u8, text);
    }

    /// Reads every note under the sources folder into the index.
    fn rebuild(lib: *SourceLibrary) !void {
        var dir = lib.vault.openDir(lib.io, lib.o.config.sources_dir, .{ .iterate = true }) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        defer dir.close(lib.io);
        var walker = try dir.walk(lib.gpa);
        defer walker.deinit();
        const a = lib.arena.allocator();
        while (try walker.next(lib.io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".md")) continue;
            const bytes = dir.readFileAlloc(lib.io, entry.path, a, .limited(16 << 20)) catch continue;
            const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ lib.o.config.sources_dir, entry.path });
            for (path) |*c| if (c.* == '\\') {
                c.* = '/';
            };
            if (try parseNote(a, path, bytes)) |s| try lib.index.put(lib.gpa, s.id, s);
        }
    }

    // ---- capture ----

    /// Captures `url` (fetching it unless `opts` has its content).
    pub fn capture(lib: *SourceLibrary, url: []const u8, opts: CaptureOpts) !CaptureResult {
        const mode = opts.mode orelse lib.o.config.capture;
        if (mode == .never) return .{ .kind = .skipped };
        var scratch: std.heap.ArenaAllocator = .init(lib.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        var page_url = url;
        var markdown: []const u8 = undefined;
        var meta: extract_mod.Extracted = .{};
        if (opts.markdown) |md| {
            markdown = md;
            meta.title = opts.title orelse firstHeading(md) orelse "";
            meta.site = try canon.site(a, url);
        } else {
            var page: []const u8 = undefined;
            var ctype: []const u8 = opts.content_type orelse "text/html";
            if (opts.html) |h| page = h else {
                const f = lib.o.fetch orelse return error.NoFetcher;
                const got = try f.fetch(f.ctx, a, url);
                page = got.body;
                ctype = got.content_type;
                if (got.final_url) |fu| page_url = fu;
            }
            if (std.ascii.indexOfIgnoreCase(ctype, "html") != null) {
                meta = try extract_mod.extract(a, page, page_url);
                markdown = meta.markdown;
            } else if (std.ascii.startsWithIgnoreCase(ctype, "text/")) {
                markdown = page;
                meta.title = firstHeading(page) orelse "";
                meta.site = try canon.site(a, page_url);
            } else return error.UnsupportedContentType;
            if (opts.title) |t| meta.title = t;
        }
        if (meta.title.len == 0) meta.title = try canon.canonicalize(a, page_url);
        var canonical = try canon.canonicalize(a, page_url);
        // The page's own canonical link wins when it is on the same site.
        if (meta.canonical) |c| if (canon.sameSite(c, page_url)) {
            canonical = try canon.canonicalize(a, c);
        };
        const id = canon.sourceId(try canon.dedupeKey(a, canonical));
        const hash = contentHash(markdown);

        lib.mutex.lockUncancelable(lib.io);
        defer lib.mutex.unlock(lib.io);
        const today = try lib.todayDate(a);
        if (lib.index.getPtr(id)) |existing| {
            const same = std.mem.eql(u8, existing.content_hash, &hash);
            var next = existing.*;
            next.fetch_count += 1;
            next.fetched = today;
            if (!same) next.content_hash = &hash;
            const note = try renderNote(a, next, if (same) null else markdown, if (same) null else today, try lib.readNote(a, existing));
            return lib.write(a, next, note, mode, if (same) .duplicate else .updated, existing);
        }
        const path = try lib.freePath(a, meta.site, meta.title);
        var run_text: [26]u8 = undefined;
        const s: Source = .{
            .id = id,
            .path = path,
            .url = std.mem.trim(u8, url, " \t\r\n"),
            .canonical_url = canonical,
            .title = meta.title,
            .site = meta.site,
            .published = meta.published,
            .fetched = today,
            .content_hash = &hash,
            .captured_by = if (opts.run) |r| blk: {
                run_text = r.text();
                break :blk &run_text;
            } else null,
        };
        const note = try renderNote(a, s, markdown, null, null);
        return lib.write(a, s, note, mode, .captured, null);
    }

    /// Writes `note` for `s` and records it (copying into the library).
    fn write(lib: *SourceLibrary, a: Allocator, s: Source, note: []const u8, mode: Mode, kind: CaptureKind, existing: ?*Source) !CaptureResult {
        const auto = mode == .always and lib.underSources(s.path);
        const out = try lib.o.notes.write(lib.o.notes.ctx, .{
            .path = s.path,
            .content = note,
            .base = if (existing) |e| try lib.readNote(a, e) else null,
            .auto_apply = auto,
            .summary = try std.fmt.allocPrint(a, "{s} source: {s}", .{ switch (kind) {
                .captured => "Capture",
                .updated => "Update",
                else => "Recapture",
            }, s.title }),
        });
        var keep = try lib.own(s);
        keep.note = try lib.arena.allocator().dupe(u8, note);
        keep.pending = !out.applied;
        try lib.index.put(lib.gpa, s.id, keep);
        return .{
            .kind = if (!out.applied and kind == .captured) .pending_approval else kind,
            .id = s.id,
            .path = keep.path,
            .changeset = out.changeset,
        };
    }

    fn own(lib: *SourceLibrary, s: Source) !Source {
        const a = lib.arena.allocator();
        var o = s;
        o.path = try a.dupe(u8, s.path);
        o.url = try a.dupe(u8, s.url);
        o.canonical_url = try a.dupe(u8, s.canonical_url);
        o.title = try a.dupe(u8, s.title);
        o.site = try a.dupe(u8, s.site);
        o.published = if (s.published) |p| try a.dupe(u8, p) else null;
        o.fetched = try a.dupe(u8, s.fetched);
        o.content_hash = try a.dupe(u8, s.content_hash);
        o.captured_by = if (s.captured_by) |c| try a.dupe(u8, c) else null;
        return o;
    }

    /// Whether `path` is inside the sources folder (no `..`, no escape).
    pub fn underSources(lib: *const SourceLibrary, path: []const u8) bool {
        const dir = lib.o.config.sources_dir;
        if (path.len <= dir.len + 1 or !std.mem.startsWith(u8, path, dir) or path[dir.len] != '/') return false;
        var it = std.mem.splitAny(u8, path, "/\\");
        while (it.next()) |part| if (std.mem.eql(u8, part, "..") or part.len == 0) return false;
        return true;
    }

    fn todayDate(lib: *SourceLibrary, a: Allocator) ![]const u8 {
        return dateOf(a, lib.o.clock.now(lib.io));
    }

    /// `<sources>/<site>/<slug>.md`, not yet taken.
    fn freePath(lib: *SourceLibrary, a: Allocator, site_name: []const u8, title: []const u8) ![]const u8 {
        const site_dir = try safeSegment(a, site_name);
        const slug = try slugify(a, title);
        var n: u32 = 1;
        while (true) : (n += 1) {
            const path = if (n == 1)
                try std.fmt.allocPrint(a, "{s}/{s}/{s}.md", .{ lib.o.config.sources_dir, site_dir, slug })
            else
                try std.fmt.allocPrint(a, "{s}/{s}/{s}-{d}.md", .{ lib.o.config.sources_dir, site_dir, slug, n });
            if (lib.pathTaken(path)) continue;
            return path;
        }
    }

    fn pathTaken(lib: *SourceLibrary, path: []const u8) bool {
        for (lib.index.values()) |s| if (std.mem.eql(u8, s.path, path)) return true;
        lib.vault.access(lib.io, path, .{}) catch return false;
        return true;
    }

    /// The note's current text (pending notes come from memory).
    pub fn readNote(lib: *SourceLibrary, a: Allocator, s: *const Source) !?[]const u8 {
        if (s.note) |n| return n;
        return lib.vault.readFileAlloc(lib.io, s.path, a, .limited(16 << 20)) catch null;
    }

    /// E10 `tool_finished` for a fetch: captures it when the run is a
    /// research run or capture is `always`. Never fails.
    pub fn onWebFetch(lib: *SourceLibrary, ev: WebFetchEvent) void {
        if (ev.is_error or ev.markdown.len == 0) return;
        const cfg = lib.o.config;
        const is_fetch = std.mem.eql(u8, ev.tool, "web_fetch") or
            (cfg.capture_mcp_fetch and std.mem.startsWith(u8, ev.tool, "mcp__") and std.mem.indexOf(u8, ev.tool, "fetch") != null);
        if (!is_fetch or cfg.capture == .never) return;
        if (!ev.research and cfg.capture != .always) return;
        _ = lib.capture(ev.url, .{ .run = ev.run, .markdown = ev.markdown, .title = ev.title }) catch {
            lib.failures += 1;
        };
    }

    // ---- reading ----

    /// The note's passage blocks, with stable indices.
    pub fn blocks(lib: *SourceLibrary, id: SourceId, arena: Allocator) ![]const Block {
        const s = lib.get(id) orelse return error.NoSuchSource;
        const note = (try lib.readNote(arena, s)) orelse return error.NoSuchSource;
        return blocks_mod.split(arena, body(note));
    }

    /// The sources as Claude API `search_result` content blocks (one per
    /// source, its passages as text blocks, citations on).
    pub fn asSearchResults(lib: *SourceLibrary, ids: []const SourceId, arena: Allocator) ![]const zg_ai_proto.ContentBlock {
        var out: std.ArrayList(zg_ai_proto.ContentBlock) = .empty;
        for (ids) |id| {
            const s = lib.get(id) orelse continue;
            const bs = try lib.blocks(id, arena);
            try out.append(arena, .{ .provider_opaque = .{ .origin = .anthropic, .kind = "search_result", .raw_json = try searchResultJson(arena, s.url, s.title, bs) } });
        }
        return out.items;
    }

    pub const Hit = struct { id: SourceId, title: []const u8, url: []const u8, site: []const u8, score: u32 };

    /// Sources whose title, URL, site or text has every word of `query`.
    pub fn search(lib: *SourceLibrary, arena: Allocator, query: []const u8, limit: usize) ![]Hit {
        var out: std.ArrayList(Hit) = .empty;
        var words: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeAny(u8, query, " \t\n");
        while (it.next()) |w| try words.append(arena, w);
        if (words.items.len == 0) return out.items;
        for (lib.index.values()) |*s| {
            var score: u32 = 0;
            var all = true;
            const note = try lib.readNote(arena, s);
            for (words.items) |w| {
                if (std.ascii.indexOfIgnoreCase(s.title, w) != null) {
                    score += 3;
                } else if (std.ascii.indexOfIgnoreCase(s.url, w) != null or std.ascii.indexOfIgnoreCase(s.site, w) != null) {
                    score += 2;
                } else if (note != null and std.ascii.indexOfIgnoreCase(body(note.?), w) != null) {
                    score += 1;
                } else {
                    all = false;
                    break;
                }
            }
            if (all) try out.append(arena, .{ .id = s.id, .title = s.title, .url = s.url, .site = s.site, .score = score });
        }
        std.mem.sort(Hit, out.items, {}, struct {
            fn better(_: void, x: Hit, y: Hit) bool {
                return if (x.score != y.score) x.score > y.score else std.mem.order(u8, x.title, y.title) == .lt;
            }
        }.better);
        return out.items[0..@min(limit, out.items.len)];
    }
};

/// The `search_result` block for a source (documented fields: type,
/// source, title, content[] of text blocks, citations.enabled).
pub fn searchResultJson(a: Allocator, url: []const u8, title: []const u8, bs: []const Block) ![]const u8 {
    return searchResultJsonCiting(a, url, title, bs, true);
}

/// `searchResultJson` with citations on or off. The API needs every
/// search result in one request to agree.
pub fn searchResultJsonCiting(a: Allocator, url: []const u8, title: []const u8, bs: []const Block, citing: bool) ![]const u8 {
    const Text = struct { type: []const u8 = "text", text: []const u8 };
    const content = try a.alloc(Text, bs.len);
    for (bs, content) |b, *c| c.* = .{ .text = b.text };
    const R = struct {
        type: []const u8 = "search_result",
        source: []const u8,
        title: []const u8,
        content: []const Text,
        citations: struct { enabled: bool } = .{ .enabled = true },
    };
    return std.json.Stringify.valueAlloc(a, R{ .source = url, .title = title, .content = content, .citations = .{ .enabled = citing } }, .{});
}

/// The note's body: after the frontmatter and the "Captured from" line.
pub fn body(note: []const u8) []const u8 {
    var b = note;
    if (fm.findFrontmatter(note)) |loc| b = note[loc.block[1]..];
    b = std.mem.trimStart(u8, b, "\r\n");
    if (std.mem.startsWith(u8, b, "> Captured from ")) {
        const nl = std.mem.indexOfScalar(u8, b, '\n') orelse b.len;
        b = std.mem.trimStart(u8, b[nl..], "\r\n");
    }
    return b;
}

/// BLAKE3 of the Markdown with line-end spaces and blank-line runs
/// normalized and link targets left out (the same page fetched under
/// another URL resolves its relative links differently), as 32 hex
/// characters.
pub fn contentHash(markdown: []const u8) [32]u8 {
    var h = std.crypto.hash.Blake3.init(.{});
    var blank = false;
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, markdown, " \t\r\n"), '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        if (line.len == 0) {
            blank = true;
            continue;
        }
        if (blank) h.update("\n");
        blank = false;
        var rest = line;
        while (std.mem.indexOf(u8, rest, "](")) |at| {
            h.update(rest[0 .. at + 2]);
            const close = std.mem.indexOfScalarPos(u8, rest, at + 2, ')') orelse rest.len;
            rest = rest[close..];
        }
        h.update(rest);
        h.update("\n");
    }
    var out: [16]u8 = undefined;
    h.final(&out);
    return std.fmt.bytesToHex(out, .lower);
}

fn firstHeading(md: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, md, '\n');
    while (it.next()) |l| {
        const t = std.mem.trim(u8, l, " \t\r");
        if (t.len > 2 and t[0] == '#') return std.mem.trim(u8, std.mem.trimStart(u8, t, "#"), " ");
    }
    return null;
}

/// `YYYY-MM-DD` (UTC) of a Unix time in ms.
pub fn dateOf(a: Allocator, ms: i64) ![]const u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(0, @divFloor(ms, 1000))) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}", .{ yd.year, md.month.numeric(), md.day_index + 1 });
}

/// A file-name slug: lowercase ASCII letters and digits joined by `-`,
/// at most 60 characters.
pub fn slugify(a: Allocator, title: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var dash = false;
    for (title) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            if (dash and out.items.len > 0) try out.append(a, '-');
            dash = false;
            if (out.items.len >= 60) break;
            try out.append(a, std.ascii.toLower(c));
        } else dash = true;
    }
    var s: []const u8 = out.items[0..@min(out.items.len, 60)];
    s = std.mem.trimEnd(u8, s, "-");
    return if (s.len == 0) "page" else s;
}

/// A host as one safe path segment.
fn safeSegment(a: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        const l = std.ascii.toLower(c);
        try out.append(a, if (std.ascii.isAlphanumeric(l) or l == '.' or l == '-') l else '-');
    }
    const t = std.mem.trim(u8, out.items, ".-");
    return if (t.len == 0) "unknown" else t;
}

/// A YAML double-quoted scalar.
fn quoted(w: *Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r', '\t' => try w.writeByte(' '),
        else => if (c < 0x20) try w.writeByte(' ') else try w.writeByte(c),
    };
    try w.writeByte('"');
}

fn isDate(s: []const u8) bool {
    return s.len == 10 and fm.parseDate(s) != null;
}

/// The note for `s`: frontmatter, the capture line and `markdown` (or,
/// when null, the body of `old`). `updated` adds that property.
pub fn renderNote(a: Allocator, s: Source, markdown: ?[]const u8, updated: ?[]const u8, old: ?[]const u8) ![]const u8 {
    var out: Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.writeAll("---\nurl: ");
    try quoted(w, s.url);
    try w.writeAll("\ncanonical_url: ");
    try quoted(w, s.canonical_url);
    try w.writeAll("\ntitle: ");
    try quoted(w, s.title);
    try w.writeAll("\nsite: ");
    try quoted(w, s.site);
    if (s.published) |p| {
        try w.writeAll("\npublished: ");
        // A date when it is one (the date part of a date-time), else text.
        if (p.len >= 10 and isDate(p[0..10])) try w.writeAll(p[0..10]) else try quoted(w, p);
    }
    try w.print("\nfetched: {s}\n", .{s.fetched});
    if (updated) |u| try w.print("updated: {s}\n", .{u});
    try w.writeAll("content_hash: ");
    try quoted(w, s.content_hash);
    // Text, so the note keeps to text, list and date properties.
    try w.print("\nfetch_count: \"{d}\"\n", .{s.fetch_count});
    if (s.captured_by) |c| {
        try w.writeAll("captured_by: ");
        try quoted(w, c);
        try w.writeByte('\n');
    }
    try w.writeAll("tags:\n  - source\n---\n");
    const capture_date = s.fetched;
    const text = markdown orelse if (old) |o| body(o) else "";
    try w.print("> Captured from <{s}> on {s}\n\n{s}\n", .{ s.url, capture_date, std.mem.trim(u8, text, " \r\n") });
    return out.written();
}

fn propText(bytes: []const u8, root: *const fm.Node, name: []const u8) ?[]const u8 {
    const n = fm.get(root, name) orelse return null;
    return switch (n.value) {
        .string => |s| s,
        .null, .list, .map => null,
        .raw => |r| r,
        else => bytes[n.src[0]..n.src[1]],
    };
}

/// The index entry of a source note, or null when it is not one.
pub fn parseNote(a: Allocator, path: []const u8, bytes: []const u8) !?Source {
    const loc = fm.findFrontmatter(bytes) orelse return null;
    const root = fm.parseRange(a, bytes, loc.body, null) catch return null;
    const url = propText(bytes, &root, "url") orelse return null;
    const canonical = propText(bytes, &root, "canonical_url") orelse try canon.canonicalize(a, url);
    const count = if (propText(bytes, &root, "fetch_count")) |c| std.fmt.parseInt(u32, std.mem.trim(u8, c, " \""), 10) catch 1 else 1;
    return .{
        .id = canon.sourceId(try canon.dedupeKey(a, canonical)),
        .path = path,
        .url = url,
        .canonical_url = canonical,
        .title = propText(bytes, &root, "title") orelse path,
        .site = propText(bytes, &root, "site") orelse try canon.site(a, url),
        .published = propText(bytes, &root, "published"),
        .fetched = propText(bytes, &root, "fetched") orelse "",
        .content_hash = propText(bytes, &root, "content_hash") orelse "",
        .fetch_count = count,
        .captured_by = propText(bytes, &root, "captured_by"),
    };
}
