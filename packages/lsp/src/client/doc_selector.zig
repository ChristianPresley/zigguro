//! LSP document-selector matching.
//!
//! A `DocumentFilter` matches a document when every field it has matches:
//! `language` and `scheme` by equality, `pattern` by glob. A string pattern
//! is matched against the document's full path and, so that patterns like
//! `src/**/*.zig` work, against its path relative to each workspace root.
//! A 3.18 `RelativePattern` is matched against the path relative to its
//! `baseUri`. A selector matches when any filter does. Notebook cell
//! filters never match (notebooks are a non-goal).
//!
//! Paths are matched with `/` separators; `\` is normalized first. Globs
//! are compiled once per selector (`CompiledSelector`) so `matches` does
//! not allocate.

const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("../gen/protocol.zig");
const glob = @import("../proto/glob.zig");
const uri = @import("../proto/uri.zig");

/// The document facts a selector looks at.
pub const DocMatch = struct {
    language_id: []const u8,
    scheme: []const u8,
    /// Absolute filesystem path, if the document has one.
    path: ?[]const u8,
};

const Pattern = struct {
    glob: glob.Glob,
    /// Normalized base path of a `RelativePattern`.
    base: ?[]const u8,
};

const Filter = struct {
    language: ?[]const u8,
    scheme: ?[]const u8,
    pattern: ?Pattern,
    /// A notebook filter: never matches.
    never: bool,
};

/// A selector with its globs compiled.
pub const CompiledSelector = struct {
    arena: std.heap.ArenaAllocator,
    filters: []Filter,
    /// Normalized workspace roots for string patterns.
    roots: []const []const u8,

    /// Compiles `sel`. `roots` are absolute workspace folder paths.
    pub fn init(gpa: Allocator, sel: protocol.DocumentSelector, roots: []const []const u8, opts: glob.GlobOptions) !CompiledSelector {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const filters = try a.alloc(Filter, sel.len);
        for (sel, filters) |df, *f| f.* = try compileFilter(a, df, opts);
        const norm_roots = try a.alloc([]const u8, roots.len);
        for (roots, norm_roots) |r, *o| o.* = try normalizeDir(a, r);
        return .{ .arena = arena, .filters = filters, .roots = norm_roots };
    }

    pub fn deinit(s: *CompiledSelector) void {
        // Globs live in the arena.
        s.arena.deinit();
        s.* = undefined;
    }

    /// Whether any filter matches `doc`.
    pub fn matches(s: *const CompiledSelector, doc: DocMatch) bool {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        return s.matchesNormalized(normalizeDoc(doc, &buf));
    }

    /// `matches` for a document from `normalizeDoc`, so callers testing
    /// many selectors normalize the path once.
    pub fn matchesNormalized(s: *const CompiledSelector, doc: DocMatch) bool {
        for (s.filters) |f| if (filterMatches(f, doc, doc.path, s.roots)) return true;
        return false;
    }
};

/// `doc` with its path's `\` turned into `/` (in `buf`). A path longer
/// than `buf` is dropped, so pattern filters do not match it.
pub fn normalizeDoc(doc: DocMatch, buf: []u8) DocMatch {
    var out = doc;
    if (doc.path) |p| out.path = normalizeInto(p, buf);
    return out;
}

fn compileFilter(a: Allocator, df: protocol.DocumentFilter, opts: glob.GlobOptions) !Filter {
    const tdf = switch (df) {
        .text_document_filter => |t| t,
        .notebook_cell_text_document_filter => return .{ .language = null, .scheme = null, .pattern = null, .never = true },
    };
    return switch (tdf) {
        inline else => |t| .{
            .language = t.language,
            .scheme = t.scheme,
            .pattern = if (optionalPattern(t.pattern)) |p| try compilePattern(a, p, opts) else null,
            .never = false,
        },
    };
}

/// The pattern of any filter variant (required in one, optional in the
/// others).
fn optionalPattern(p: anytype) ?protocol.GlobPattern {
    return p;
}

fn compilePattern(a: Allocator, p: protocol.GlobPattern, opts: glob.GlobOptions) !Pattern {
    switch (p) {
        .pattern => |s| return .{ .glob = try glob.Glob.compile(a, s, opts), .base = null },
        .relative_pattern => |rp| {
            const base_uri = switch (rp.baseUri) {
                .workspace_folder => |wf| wf.uri,
                .uri => |u| u,
            };
            const base_path = (uri.pathFromUri(a, base_uri) catch null) orelse return error.InvalidBaseUri;
            return .{ .glob = try glob.Glob.compile(a, rp.pattern, opts), .base = try normalizeDir(a, base_path) };
        },
    }
}

/// `p` with `\` turned into `/`, in `buf` (or `p` itself when it has no
/// `\`); null if it does not fit.
fn normalizeInto(p: []const u8, buf: []u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, p, '\\') == null) return p;
    if (p.len > buf.len) return null;
    for (p, buf[0..p.len]) |c, *o| o.* = if (c == '\\') '/' else c;
    return buf[0..p.len];
}

/// A directory path normalized for prefix tests: `/` separators and a
/// trailing `/`.
fn normalizeDir(a: Allocator, p: []const u8) ![]const u8 {
    const trailing = p.len > 0 and (p[p.len - 1] == '/' or p[p.len - 1] == '\\');
    const out = try a.alloc(u8, p.len + @intFromBool(!trailing));
    for (p, out[0..p.len]) |c, *o| o.* = if (c == '\\') '/' else c;
    if (!trailing) out[p.len] = '/';
    return out;
}

/// `path` relative to directory `dir` (both normalized), or null.
fn relativeTo(path: []const u8, dir: []const u8) ?[]const u8 {
    if (path.len <= dir.len) return null;
    if (!startsWithPath(path, dir)) return null;
    return path[dir.len..];
}

/// Prefix test that ignores ASCII case for a Windows drive letter.
fn startsWithPath(path: []const u8, prefix: []const u8) bool {
    if (path.len < prefix.len) return false;
    if (prefix.len >= 2 and prefix[1] == ':') {
        return std.ascii.toLower(path[0]) == std.ascii.toLower(prefix[0]) and std.mem.startsWith(u8, path[1..], prefix[1..]);
    }
    return std.mem.startsWith(u8, path, prefix);
}

fn filterMatches(f: Filter, doc: DocMatch, path: ?[]const u8, roots: []const []const u8) bool {
    if (f.never) return false;
    if (f.language) |l| if (!std.mem.eql(u8, l, doc.language_id)) return false;
    if (f.scheme) |s| if (!std.mem.eql(u8, s, doc.scheme)) return false;
    const pat = f.pattern orelse return true;
    const p = path orelse return false;
    if (pat.base) |base| {
        const rel = relativeTo(p, base) orelse return false;
        return pat.glob.match(rel);
    }
    if (pat.glob.match(p)) return true;
    for (roots) |r| if (relativeTo(p, r)) |rel| if (pat.glob.match(rel)) return true;
    return false;
}

/// One-shot `CompiledSelector` match (compiles `sel` each call).
pub fn matchSelector(gpa: Allocator, sel: protocol.DocumentSelector, doc: DocMatch, roots: []const []const u8) !bool {
    var cs = try CompiledSelector.init(gpa, sel, roots, .{});
    defer cs.deinit();
    return cs.matches(doc);
}
