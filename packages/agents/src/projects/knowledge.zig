//! A project's knowledge index (E13.F09.S01.T01): each knowledge item
//! resolved to workspace files, listed as `path · title · size ·
//! modified`, capped at `Limits.max_entries` entries and
//! `Limits.max_tokens` estimated tokens with a "+N more" line. File
//! contents are never inlined: agents read them with
//! `project_knowledge_read` (or `search_notes`). Files the deny policy
//! marks secret are left out; a missing folder or file is skipped with a
//! warning.
//!
//! Folders are walked here (the glob is relative to the folder); notes
//! queries and research sources go through ports (E08 and E13.F05).
//! Everything here reads the disk, so call it from a worker, never the UI
//! thread.

const std = @import("std");
const project = @import("project.zig");
const Glob = @import("../sched/glob.zig").Glob;

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Project = project.Project;

/// A file a query matched.
pub const Hit = struct { path: []const u8, title: []const u8 = "" };

/// E08 notes queries (and E13.F05 source notes): workspace-relative paths.
pub const QueryPort = struct {
    ctx: *anyopaque,
    query: *const fn (ctx: *anyopaque, arena: Allocator, q: []const u8) anyerror![]const Hit,
};

/// E16: true for paths agents must not see (secrets).
pub const DenyPort = struct {
    ctx: *anyopaque,
    denied: *const fn (ctx: *anyopaque, path: []const u8) bool,
};

pub const Env = struct {
    /// The workspace root.
    root: Io.Dir,
    notes: ?QueryPort = null,
    sources: ?QueryPort = null,
    deny: ?DenyPort = null,
};

pub const Limits = struct {
    max_entries: u32 = 200,
    max_tokens: u32 = 4_000,
    /// Files looked at per folder item (a guard against huge trees).
    max_walk: u32 = 20_000,
};

pub const Entry = struct {
    path: []const u8,
    title: []const u8,
    size: u64,
    /// Milliseconds since the Unix epoch.
    modified_ms: i64,
};

pub const KnowledgeIndex = struct {
    /// In item order; within a folder, by path. No duplicates.
    entries: []const Entry,
    /// Files left out by the caps.
    more: u32 = 0,
    warnings: []const []const u8 = &.{},
};

/// Resolves every knowledge item of `p`. Strings live in `arena`.
pub fn build(io: Io, arena: Allocator, p: *const Project, env: Env, limits: Limits) !KnowledgeIndex {
    var all: std.ArrayList(Entry) = .empty;
    var warnings: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (p.knowledge) |k| {
        switch (k) {
            .folder => |d| walkFolder(io, arena, env, d.path, d.glob, limits, &all, &seen) catch |e| switch (e) {
                error.OutOfMemory => return e,
                error.InvalidGlob => try warnings.append(arena, try std.fmt.allocPrint(arena, "invalid glob \"{s}\" for {s}", .{ d.glob, d.path })),
                else => try warnings.append(arena, try std.fmt.allocPrint(arena, "skipped folder {s}: {t}", .{ d.path, e })),
            },
            .file => |path| {
                if (seen.contains(path)) continue;
                if (try fileEntry(io, arena, env, path, null)) |en| {
                    try seen.put(arena, en.path, {});
                    try all.append(arena, en);
                } else if (!denied(env, path)) try warnings.append(arena, try std.fmt.allocPrint(arena, "missing file {s}", .{path}));
            },
            .notes_query, .source => |q| {
                const port = (if (k == .notes_query) env.notes else env.sources) orelse {
                    try warnings.append(arena, try std.fmt.allocPrint(arena, "{s} \"{s}\" skipped: not available here", .{ if (k == .notes_query) "notes query" else "sources query", q }));
                    continue;
                };
                const hits = port.query(port.ctx, arena, q) catch |e| {
                    try warnings.append(arena, try std.fmt.allocPrint(arena, "query \"{s}\" failed: {t}", .{ q, e }));
                    continue;
                };
                for (hits) |h| {
                    if (seen.contains(h.path)) continue;
                    if (try fileEntry(io, arena, env, h.path, if (h.title.len > 0) h.title else null)) |en| {
                        try seen.put(arena, en.path, {});
                        try all.append(arena, en);
                    }
                }
            },
        }
    }
    return cap(all.items, warnings.items, limits);
}

/// Applies the entry and token caps.
fn cap(all: []const Entry, warnings: []const []const u8, limits: Limits) !KnowledgeIndex {
    var tokens: u64 = 0;
    var n: usize = 0;
    var line: [512]u8 = undefined;
    while (n < all.len and n < limits.max_entries) : (n += 1) {
        var w: Io.Writer = .fixed(&line);
        writeEntry(&w, all[n]) catch {};
        const t = estimateTokens(w.buffered().len + 1);
        if (tokens + t > limits.max_tokens) break;
        tokens += t;
    }
    return .{ .entries = all[0..n], .more = @intCast(all.len - n), .warnings = warnings };
}

/// The E10 estimate (about four bytes a token).
pub fn estimateTokens(bytes: usize) u32 {
    return @intCast((bytes + 3) / 4);
}

fn denied(env: Env, path: []const u8) bool {
    const d = env.deny orelse return false;
    return d.denied(d.ctx, path);
}

fn walkFolder(io: Io, arena: Allocator, env: Env, folder: []const u8, pattern: []const u8, limits: Limits, out: *std.ArrayList(Entry), seen: *std.StringHashMapUnmanaged(void)) !void {
    var g = try Glob.compile(arena, pattern);
    defer g.deinit(arena);
    var dir = try env.root.openDir(io, folder, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    var paths: std.ArrayList([]const u8) = .empty;
    var looked: u32 = 0;
    while (try walker.next(io)) |e| {
        if (e.kind != .file) continue;
        looked += 1;
        if (looked > limits.max_walk) break;
        const rel = try arena.dupe(u8, e.path);
        for (rel) |*c| if (c.* == '\\') {
            c.* = '/';
        };
        if (!g.match(rel)) continue;
        try paths.append(arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ std.mem.trimEnd(u8, folder, "/"), rel }));
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    for (paths.items) |path| {
        if (seen.contains(path)) continue;
        if (try fileEntry(io, arena, env, path, null)) |en| {
            try seen.put(arena, en.path, {});
            try out.append(arena, en);
        }
    }
}

/// Null when the file is missing or denied.
fn fileEntry(io: Io, arena: Allocator, env: Env, path: []const u8, title: ?[]const u8) !?Entry {
    if (!project.relPath(path) or denied(env, path)) return null;
    const st = env.root.statFile(io, path, .{}) catch return null;
    if (st.kind != .file) return null;
    return .{
        .path = try arena.dupe(u8, path),
        .title = if (title) |t| try arena.dupe(u8, t) else try titleOf(io, arena, env.root, path),
        .size = st.size,
        .modified_ms = @intCast(@divFloor(st.mtime.nanoseconds, std.time.ns_per_ms)),
    };
}

/// A Markdown file's frontmatter `title:` or first `# ` heading, else the
/// file name.
fn titleOf(io: Io, arena: Allocator, root: Io.Dir, path: []const u8) ![]const u8 {
    const base = std.fs.path.basenamePosix(path);
    if (!std.mem.endsWith(u8, path, ".md")) return arena.dupe(u8, base);
    var buf: [2048]u8 = undefined;
    const f = root.openFile(io, path, .{}) catch return arena.dupe(u8, base);
    defer f.close(io);
    const n = f.readPositionalAll(io, &buf, 0) catch return arena.dupe(u8, base);
    const head = buf[0..n];
    var lines = std.mem.splitScalar(u8, head, '\n');
    var in_fm = false;
    var first = true;
    while (lines.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t\r");
        if (first and std.mem.eql(u8, l, "---")) {
            in_fm = true;
            first = false;
            continue;
        }
        first = false;
        if (in_fm) {
            if (std.mem.eql(u8, l, "---")) {
                in_fm = false;
                continue;
            }
            if (std.mem.startsWith(u8, l, "title:")) {
                const t = std.mem.trim(u8, l["title:".len..], " \"'");
                if (t.len > 0) return arena.dupe(u8, t);
            }
            continue;
        }
        if (std.mem.startsWith(u8, l, "# ")) return arena.dupe(u8, std.mem.trim(u8, l[2..], " "));
    }
    return arena.dupe(u8, base);
}

pub fn writeEntry(w: *Io.Writer, e: Entry) Io.Writer.Error!void {
    try w.print("- {s} · {s} · {f} · ", .{ e.path, e.title, size(e.size) });
    try writeDate(w, e.modified_ms);
}

/// The index as the context section shows it.
pub fn render(w: *Io.Writer, idx: *const KnowledgeIndex) Io.Writer.Error!void {
    if (idx.entries.len == 0 and idx.more == 0) {
        try w.writeAll("(no knowledge files)\n");
        return;
    }
    for (idx.entries) |e| {
        try writeEntry(w, e);
        try w.writeByte('\n');
    }
    if (idx.more > 0) try w.print("+{d} more\n", .{idx.more});
    try w.writeAll("\nThe contents are not included: read a file with project_knowledge_read, or search notes with search_notes.\n");
}

const Size = struct {
    n: u64,
    pub fn format(s: Size, w: *Io.Writer) Io.Writer.Error!void {
        if (s.n < 1024) return w.print("{d} B", .{s.n});
        if (s.n < 1024 * 1024) return w.print("{d} KB", .{(s.n + 512) / 1024});
        return w.print("{d}.{d} MB", .{ s.n / (1024 * 1024), (s.n % (1024 * 1024)) * 10 / (1024 * 1024) });
    }
};

fn size(n: u64) Size {
    return .{ .n = n };
}

/// `YYYY-MM-DD` (UTC).
fn writeDate(w: *Io.Writer, ms: i64) Io.Writer.Error!void {
    const secs: u64 = @intCast(@max(0, @divFloor(ms, 1000)));
    const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    try w.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ day.year, md.month.numeric(), md.day_index + 1 });
}

/// Whether `path` belongs to one of `p`'s knowledge items (the read tool's
/// check); ignores the caps.
pub fn contains(arena: Allocator, p: *const Project, env: Env, path: []const u8) !bool {
    if (!project.relPath(path) or denied(env, path)) return false;
    for (p.knowledge) |k| switch (k) {
        .file => |f| if (std.mem.eql(u8, f, path)) return true,
        .folder => |d| {
            const prefix = std.mem.trimEnd(u8, d.path, "/");
            if (path.len > prefix.len + 1 and std.mem.startsWith(u8, path, prefix) and path[prefix.len] == '/') {
                var g = try Glob.compile(arena, d.glob);
                defer g.deinit(arena);
                if (g.match(path[prefix.len + 1 ..])) return true;
            }
        },
        .notes_query, .source => |q| {
            const port = (if (k == .notes_query) env.notes else env.sources) orelse continue;
            const hits = port.query(port.ctx, arena, q) catch continue;
            for (hits) |h| if (std.mem.eql(u8, h.path, path)) return true;
        },
    };
    return false;
}
