//! `MemoryLoader`: discovers, loads and scopes the instruction files of a
//! session (E10.F07.S01.T02) and exposes what was loaded, with token
//! estimates, for `/memory` and `/context`.
//!
//! Load order, broad to specific: managed, user (`<config>/ZIGGURO.md`,
//! `<config>/rules`), then each directory from the workspace root down to
//! the cwd (project files, then local files). Directories above the root
//! load only with `load_parents`. Files below the cwd, and path-scoped
//! rules, load on demand from `onFileTouched`. `@path` imports load
//! recursively (four hops) right after the importing file.
//!
//! All I/O blocks: call from a worker, never the UI thread. Every slice in
//! a `MemorySet` lives until the next `reloadChanged` that rebuilds it.

const std = @import("std");
const builtin = @import("builtin");
const rules = @import("rules.zig");
const imports = @import("imports.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const path_sep = std.fs.path.sep;

/// Where a memory file came from.
pub const Scope = enum { managed, user, project, project_local, nested, rule };

/// One loaded instruction file.
pub const MemoryFile = struct {
    /// Absolute path.
    path: []const u8,
    scope: Scope,
    /// The text that goes into the prompt (rule bodies without frontmatter).
    text: []const u8,
    /// The globs that activated a path-scoped rule.
    paths_globs: []const []const u8 = &.{},
    /// XxHash3 of `text`; changes invalidate the cached system prefix.
    version_hash: u64,
    /// Absolute paths this file imports (loaded right after it).
    imports: []const []const u8 = &.{},
    /// The importing file, for files loaded through `@path`.
    imported_by: ?[]const u8 = null,
    /// Estimated tokens (4 bytes per token).
    tokens: u32,
    /// The file exceeded `hard_cap_bytes` and was cut.
    truncated: bool = false,
};

/// A Cursor agent-requested rule: listed by description, read on demand.
pub const RequestedRule = struct { path: []const u8, description: []const u8 };

/// Everything loaded for a session so far.
pub const MemorySet = struct {
    files: []const MemoryFile = &.{},
    /// Agent-requested rules for the rules index in the system prompt.
    rules_index: []const RequestedRule = &.{},
    /// Warnings for `/memory` and `/doctor` (size guards, disabled imports,
    /// malformed rules).
    notes: []const []const u8 = &.{},
    /// Hash over every file's path and `version_hash`, in order.
    hash: u64 = 0,

    /// Total estimated tokens of `files`.
    pub fn tokens(s: *const MemorySet) u64 {
        var n: u64 = 0;
        for (s.files) |f| n += f.tokens;
        return n;
    }
};

/// Which other harnesses' files are honoured.
pub const Compat = struct {
    agents_md: bool = true,
    claude_md: bool = true,
    cursor_mdc: bool = true,
    claude_rules_dir: bool = true,
};

/// Approves imports that resolve outside the workspace (E16 trust). The
/// default approves nothing: such imports stay disabled with a note.
pub const Trust = struct {
    ctx: ?*anyopaque = null,
    approved: ?*const fn (ctx: ?*anyopaque, path: []const u8) bool = null,

    fn allows(t: Trust, path: []const u8) bool {
        const f = t.approved orelse return false;
        return f(t.ctx, path);
    }
};

/// Inputs to `loadInitial`. Every path is absolute.
pub const Sources = struct {
    managed_dir: ?[]const u8 = null,
    /// E15 `paths.configDir()`.
    user_dir: ?[]const u8 = null,
    /// For `@~/...` imports.
    home_dir: ?[]const u8 = null,
    workspace_roots: []const []const u8,
    cwd: []const u8,
    compat: Compat = .{},
    /// `ai.memory.loadParents`: also read directories above the workspace root.
    load_parents: bool = false,
    trust: Trust = .{},
};

/// Warn above this many lines (Claude Code recommends fewer than 200).
pub const warn_lines: usize = 200;
/// Warn above this size.
pub const warn_bytes: usize = 25 * 1024;
/// Truncate above this size.
pub const hard_cap_bytes: usize = 100 * 1024;
/// Maximum import hops.
pub const max_import_depth: u8 = 4;

const CompatKind = enum { agents, claude };

const project_names = [_]struct { []const u8, ?CompatKind }{
    .{ "ZIGGURO.md", null },
    .{ ".zigguro" ++ [1]u8{path_sep} ++ "ZIGGURO.md", null },
    .{ "AGENTS.md", .agents },
    .{ "CLAUDE.md", .claude },
    .{ ".claude" ++ [1]u8{path_sep} ++ "CLAUDE.md", .claude },
};
const local_names = [_]struct { []const u8, ?CompatKind }{
    .{ "ZIGGURO.local.md", null },
    .{ "CLAUDE.local.md", .claude },
};

/// A path-scoped rule waiting for a matching file.
const Pending = struct {
    path: []const u8,
    /// The workspace root its globs are relative to (null: any root).
    root: ?[]const u8,
    globs: []const []const u8,
    body: []const u8,
};

pub const MemoryLoader = struct {
    gpa: Allocator,
    /// Owns `src` (copied) and the replay lists; lives as long as the loader.
    cfg_arena: std.heap.ArenaAllocator,
    /// Owns the current set; replaced on reload.
    arena: std.heap.ArenaAllocator,
    src: Sources = .{ .workspace_roots = &.{}, .cwd = "" },
    files: std.ArrayList(MemoryFile) = .empty,
    notes: std.ArrayList([]const u8) = .empty,
    rules_index: std.ArrayList(RequestedRule) = .empty,
    pending: std.ArrayList(Pending) = .empty,
    /// Real paths already loaded (dedupes imports and breaks cycles).
    loaded: std.StringHashMapUnmanaged(void) = .empty,
    /// Directories already checked for memory files.
    visited: std.StringHashMapUnmanaged(void) = .empty,
    /// Replayed after a reload (in `cfg_arena`).
    touched_dirs: std.ArrayList([]const u8) = .empty,
    activated: std.ArrayList([]const u8) = .empty,
    set: MemorySet = .{},

    pub fn init(gpa: Allocator) MemoryLoader {
        return .{ .gpa = gpa, .cfg_arena = .init(gpa), .arena = .init(gpa) };
    }

    pub fn deinit(m: *MemoryLoader) void {
        m.arena.deinit();
        m.cfg_arena.deinit();
        m.* = undefined;
    }

    /// The current set.
    pub fn current(m: *const MemoryLoader) *const MemorySet {
        return &m.set;
    }

    /// Loads everything that applies at session start.
    pub fn loadInitial(m: *MemoryLoader, io: Io, src: Sources) !*const MemorySet {
        const ca = m.cfg_arena.allocator();
        var s = src;
        s.managed_dir = if (src.managed_dir) |d| try ca.dupe(u8, d) else null;
        s.user_dir = if (src.user_dir) |d| try ca.dupe(u8, d) else null;
        s.home_dir = if (src.home_dir) |d| try ca.dupe(u8, d) else null;
        const roots = try ca.alloc([]const u8, src.workspace_roots.len);
        for (roots, src.workspace_roots) |*r, x| r.* = try ca.dupe(u8, trimSep(x));
        s.workspace_roots = roots;
        s.cwd = try ca.dupe(u8, trimSep(src.cwd));
        m.src = s;
        try m.rebuild(io);
        return &m.set;
    }

    /// Loads nested memory files and path-scoped rules that apply once the
    /// agent reads, writes or edits `path` (absolute, or relative to the
    /// cwd). Returns the newly loaded files (empty when nothing changed).
    pub fn onFileTouched(m: *MemoryLoader, io: Io, path: []const u8) ![]const MemoryFile {
        const a = m.arena.allocator();
        const abs = if (std.fs.path.isAbsolute(path)) try a.dupe(u8, path) else try std.fs.path.join(a, &.{ m.src.cwd, path });
        const before = m.files.items.len;
        if (m.rootOf(abs)) |root| {
            // Every directory from the root down to the file's directory.
            const dir = std.fs.path.dirname(abs) orelse root;
            var chain: std.ArrayList([]const u8) = .empty;
            var d: []const u8 = dir;
            while (d.len >= root.len) {
                try chain.append(a, d);
                if (d.len == root.len) break;
                d = std.fs.path.dirname(d) orelse break;
            }
            var i = chain.items.len;
            while (i > 0) {
                i -= 1;
                if (m.visited.contains(chain.items[i])) continue;
                try m.touched_dirs.append(m.cfg_arena.allocator(), try m.cfg_arena.allocator().dupe(u8, chain.items[i]));
                try m.loadDir(io, chain.items[i], .nested, .nested);
            }
        }
        try m.activateFor(abs);
        if (m.files.items.len == before) return &.{};
        m.finish();
        return m.files.items[before..];
    }

    /// Handles a workspace file event. When `changed` is a loaded memory
    /// file or a memory/rule file name inside a visited directory, rebuilds
    /// the set (replaying on-demand loads) and returns whether its content
    /// changed; the next request then picks it up.
    pub fn reloadChanged(m: *MemoryLoader, io: Io, changed: []const u8) !bool {
        if (!m.affects(changed)) return false;
        const old = m.set.hash;
        try m.rebuild(io);
        for (m.touched_dirs.items) |d| if (!m.visited.contains(d)) try m.loadDir(io, d, .nested, .nested);
        for (m.activated.items) |p| for (m.pending.items) |r| if (std.mem.eql(u8, r.path, p)) try m.activate(r);
        m.finish();
        return m.set.hash != old;
    }

    fn affects(m: *const MemoryLoader, changed: []const u8) bool {
        for (m.files.items) |f| if (pathEql(f.path, changed)) return true;
        for (m.pending.items) |r| if (pathEql(r.path, changed)) return true;
        const base = std.fs.path.basename(changed);
        for (project_names ++ local_names) |n| if (pathEql(std.fs.path.basename(n[0]), base)) return true;
        return std.mem.endsWith(u8, base, ".mdc") or (std.mem.endsWith(u8, base, ".md") and std.mem.indexOf(u8, changed, "rules") != null);
    }

    fn rebuild(m: *MemoryLoader, io: Io) !void {
        m.arena.deinit();
        m.arena = .init(m.gpa);
        m.files = .empty;
        m.notes = .empty;
        m.rules_index = .empty;
        m.pending = .empty;
        m.loaded = .empty;
        m.visited = .empty;
        const a = m.arena.allocator();
        const s = m.src;

        if (s.managed_dir) |d| {
            try m.loadFile(io, try std.fs.path.join(a, &.{ d, "ZIGGURO.md" }), .managed, null, 0);
            try m.loadRulesDir(io, d, "rules", ".md", false, null);
        }
        if (s.user_dir) |d| {
            try m.loadFile(io, try std.fs.path.join(a, &.{ d, "ZIGGURO.md" }), .user, null, 0);
            try m.loadRulesDir(io, d, "rules", ".md", false, null);
        }
        const main_root = m.rootOf(s.cwd);
        if (s.load_parents) if (main_root) |root| {
            var parents: std.ArrayList([]const u8) = .empty;
            var d = std.fs.path.dirname(root);
            while (d) |x| : (d = std.fs.path.dirname(x)) try parents.append(a, x);
            var i = parents.items.len;
            while (i > 0) {
                i -= 1;
                try m.loadDir(io, parents.items[i], .project, .project_local);
            }
        };
        for (s.workspace_roots) |root| {
            const is_main = if (main_root) |r| std.mem.eql(u8, r, root) else false;
            if (is_main) {
                // Root down to the cwd.
                var chain: std.ArrayList([]const u8) = .empty;
                var d: []const u8 = s.cwd;
                while (d.len >= root.len) {
                    try chain.append(a, d);
                    if (d.len == root.len) break;
                    d = std.fs.path.dirname(d) orelse break;
                }
                var i = chain.items.len;
                while (i > 0) {
                    i -= 1;
                    try m.loadDir(io, chain.items[i], .project, .project_local);
                }
            } else try m.loadDir(io, root, .project, .project_local);
            try m.loadRulesDir(io, root, ".zigguro" ++ [1]u8{path_sep} ++ "rules", ".md", false, root);
            if (s.compat.claude_rules_dir) try m.loadRulesDir(io, root, ".claude" ++ [1]u8{path_sep} ++ "rules", ".md", false, root);
            if (s.compat.cursor_mdc) try m.loadRulesDir(io, root, ".cursor" ++ [1]u8{path_sep} ++ "rules", ".mdc", true, root);
        }
        if (main_root == null) try m.loadDir(io, s.cwd, .project, .project_local);
        m.finish();
    }

    fn finish(m: *MemoryLoader) void {
        var h: std.hash.XxHash3 = .init(0);
        for (m.files.items) |f| {
            h.update(f.path);
            h.update(std.mem.asBytes(&f.version_hash));
        }
        m.set = .{ .files = m.files.items, .rules_index = m.rules_index.items, .notes = m.notes.items, .hash = h.final() };
    }

    fn compatOn(m: *const MemoryLoader, which: ?CompatKind) bool {
        const w = which orelse return true;
        return switch (w) {
            .agents => m.src.compat.agents_md,
            .claude => m.src.compat.claude_md,
        };
    }

    /// Loads the memory files of one directory (project names, then local).
    fn loadDir(m: *MemoryLoader, io: Io, dir: []const u8, project: Scope, local: Scope) !void {
        const a = m.arena.allocator();
        try m.visited.put(a, try a.dupe(u8, dir), {});
        for (project_names) |n| if (m.compatOn(n[1])) try m.loadFile(io, try std.fs.path.join(a, &.{ dir, n[0] }), project, null, 0);
        for (local_names) |n| if (m.compatOn(n[1])) try m.loadFile(io, try std.fs.path.join(a, &.{ dir, n[0] }), if (project == .nested) .nested else local, null, 0);
    }

    /// Loads one file (if it exists) and, recursively, its imports.
    fn loadFile(m: *MemoryLoader, io: Io, path: []const u8, scope: Scope, importer: ?[]const u8, depth: u8) !void {
        const a = m.arena.allocator();
        const real = realPath(io, a, path) orelse return;
        if (m.loaded.contains(real)) return;
        const read = try readCapped(io, a, path) orelse return;
        try m.loaded.put(a, real, {});
        try m.sizeNotes(path, read);
        const index = m.files.items.len;
        try m.files.append(a, .{
            .path = path,
            .scope = scope,
            .text = read.data,
            .version_hash = std.hash.XxHash3.hash(0, read.data),
            .imported_by = importer,
            .tokens = estimateTokens(read.data.len),
            .truncated = read.truncated,
        });
        const toks = try imports.scan(a, read.data);
        if (toks.len == 0) return;
        var resolved: std.ArrayList([]const u8) = .empty;
        for (toks) |t| {
            const target = (try m.resolveImport(path, t.path)) orelse continue;
            if (depth + 1 > max_import_depth) {
                try m.notes.append(a, try std.fmt.allocPrint(a, "{s}:{d}: import @{s} skipped: more than {d} import hops", .{ path, t.line, t.path, max_import_depth }));
                continue;
            }
            if (!m.inside(target) and !m.src.trust.allows(target)) {
                try m.notes.append(a, try std.fmt.allocPrint(a, "{s}:{d}: import @{s} is outside the workspace and stays disabled until approved", .{ path, t.line, t.path }));
                continue;
            }
            try resolved.append(a, target);
            try m.loadFile(io, target, scope, path, depth + 1);
        }
        m.files.items[index].imports = resolved.items;
    }

    fn resolveImport(m: *MemoryLoader, importer: []const u8, p: []const u8) !?[]const u8 {
        const a = m.arena.allocator();
        if (std.mem.startsWith(u8, p, "~/") or std.mem.startsWith(u8, p, "~\\")) {
            const home = m.src.home_dir orelse return null;
            return try std.fs.path.resolve(a, &.{ home, p[2..] });
        }
        if (std.fs.path.isAbsolute(p)) return try std.fs.path.resolve(a, &.{p});
        const base = std.fs.path.dirname(importer) orelse return null;
        return try std.fs.path.resolve(a, &.{ base, p });
    }

    /// Inside a workspace root, the user config dir or the managed dir.
    fn inside(m: *const MemoryLoader, path: []const u8) bool {
        if (m.rootOf(path) != null) return true;
        if (m.src.user_dir) |d| if (under(d, path) != null) return true;
        if (m.src.managed_dir) |d| if (under(d, path) != null) return true;
        return false;
    }

    /// The workspace root containing `path` (the deepest one).
    fn rootOf(m: *const MemoryLoader, path: []const u8) ?[]const u8 {
        var best: ?[]const u8 = null;
        for (m.src.workspace_roots) |r| if (under(r, path) != null) {
            if (best == null or r.len > best.?.len) best = r;
        };
        return best;
    }

    fn sizeNotes(m: *MemoryLoader, path: []const u8, read: Read) !void {
        const a = m.arena.allocator();
        if (read.truncated) {
            try m.notes.append(a, try std.fmt.allocPrint(a, "{s}: larger than {d} KiB; truncated", .{ path, hard_cap_bytes / 1024 }));
            return;
        }
        const lines = std.mem.count(u8, read.data, "\n") + @intFromBool(read.data.len > 0 and read.data[read.data.len - 1] != '\n');
        if (lines > warn_lines or read.data.len > warn_bytes)
            try m.notes.append(a, try std.fmt.allocPrint(a, "{s}: {d} lines, {d} bytes; keep memory files under {d} lines and {d} KiB", .{ path, lines, read.data.len, warn_lines, warn_bytes / 1024 }));
    }

    /// Loads every rule file under `<base>/<sub>` (sorted by path).
    fn loadRulesDir(m: *MemoryLoader, io: Io, base: []const u8, sub: []const u8, ext: []const u8, mdc: bool, root: ?[]const u8) !void {
        const a = m.arena.allocator();
        const dir_path = try std.fs.path.join(a, &.{ base, sub });
        var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
        defer dir.close(io);
        var names: std.ArrayList([]const u8) = .empty;
        var w = try dir.walk(m.gpa);
        defer w.deinit();
        while (w.next(io) catch null) |e| {
            if (e.kind != .file or !std.mem.endsWith(u8, e.basename, ext)) continue;
            try names.append(a, try a.dupe(u8, e.path));
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.order(u8, x, y) == .lt;
            }
        }.lt);
        for (names.items) |n| {
            const path = try std.fs.path.join(a, &.{ dir_path, n });
            const real = realPath(io, a, path) orelse continue;
            if (m.loaded.contains(real)) continue;
            const read = try readCapped(io, a, path) orelse continue;
            try m.loaded.put(a, real, {});
            try m.sizeNotes(path, read);
            const rule = try rules.classify(a, read.data, mdc);
            if (rule.problem) |p| try m.notes.append(a, try std.fmt.allocPrint(a, "{s}: {s}", .{ path, p }));
            switch (rule.activation) {
                .always => try m.files.append(a, ruleFile(path, rule.body, &.{}, read.truncated)),
                .scoped => |globs| try m.pending.append(a, .{ .path = path, .root = root, .globs = globs, .body = rule.body }),
                .requested => |d| try m.rules_index.append(a, .{ .path = path, .description = d }),
                .manual => {},
            }
        }
    }

    fn activateFor(m: *MemoryLoader, abs: []const u8) !void {
        for (m.pending.items) |r| {
            if (m.isActive(r.path)) continue;
            const rel = if (r.root) |root| under(root, abs) orelse continue else blk: {
                const root = m.rootOf(abs) orelse continue;
                break :blk under(root, abs).?;
            };
            if (!rules.matchesAny(r.globs, rel)) continue;
            try m.activated.append(m.cfg_arena.allocator(), try m.cfg_arena.allocator().dupe(u8, r.path));
            try m.activate(r);
        }
    }

    fn isActive(m: *const MemoryLoader, path: []const u8) bool {
        for (m.files.items) |f| if (f.scope == .rule and std.mem.eql(u8, f.path, path)) return true;
        return false;
    }

    fn activate(m: *MemoryLoader, r: Pending) !void {
        if (m.isActive(r.path)) return;
        try m.files.append(m.arena.allocator(), ruleFile(r.path, r.body, r.globs, false));
    }
};

fn ruleFile(path: []const u8, body: []const u8, globs: []const []const u8, truncated: bool) MemoryFile {
    return .{ .path = path, .scope = .rule, .text = body, .paths_globs = globs, .version_hash = std.hash.XxHash3.hash(0, body), .tokens = estimateTokens(body.len), .truncated = truncated };
}

/// Rough token estimate used for `/memory` (4 bytes per token).
pub fn estimateTokens(bytes: usize) u32 {
    return @intCast(@min((bytes + 3) / 4, std.math.maxInt(u32)));
}

const Read = struct { data: []const u8, truncated: bool };

/// Reads at most `hard_cap_bytes` of `path`; null when it does not exist.
fn readCapped(io: Io, a: Allocator, path: []const u8) !?Read {
    const f = Io.Dir.cwd().openFile(io, path, .{}) catch |e| switch (e) {
        error.FileNotFound, error.NotDir, error.IsDir, error.AccessDenied, error.PermissionDenied, error.BadPathName, error.SymLinkLoop, error.NameTooLong => return null,
        else => return e,
    };
    defer f.close(io);
    const len = f.length(io) catch return null;
    const want: usize = @intCast(@min(len, hard_cap_bytes + 1));
    const buf = try a.alloc(u8, want);
    const n = f.readPositionalAll(io, buf, 0) catch return null;
    if (n > hard_cap_bytes) {
        // Cut at the last newline inside the cap, then mark it.
        const cut = if (std.mem.lastIndexOfScalar(u8, buf[0..hard_cap_bytes], '\n')) |i| i + 1 else hard_cap_bytes;
        const out = try std.mem.concat(a, u8, &.{ buf[0..cut], "\n[truncated: file exceeds 100 KiB]\n" });
        return .{ .data = out, .truncated = true };
    }
    return .{ .data = buf[0..n], .truncated = false };
}

/// The canonical path for dedupe and cycle checks (the input when the
/// platform cannot resolve it); null when the file does not exist.
fn realPath(io: Io, a: Allocator, path: []const u8) ?[]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = Io.Dir.realPathFileAbsolute(io, path, &buf) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => return null,
        else => return a.dupe(u8, path) catch null,
    };
    return a.dupe(u8, buf[0..n]) catch null;
}

fn trimSep(p: []const u8) []const u8 {
    var s = p;
    while (s.len > 1 and (s[s.len - 1] == '/' or s[s.len - 1] == '\\')) s = s[0 .. s.len - 1];
    return s;
}

fn charEql(x: u8, y: u8) bool {
    if (builtin.os.tag == .windows) {
        const nx = if (x == '\\') '/' else std.ascii.toLower(x);
        const ny = if (y == '\\') '/' else std.ascii.toLower(y);
        return nx == ny;
    }
    return x == y;
}

fn pathEql(x: []const u8, y: []const u8) bool {
    if (x.len != y.len) return false;
    for (x, y) |p, q| if (!charEql(p, q)) return false;
    return true;
}

/// `path` relative to `root` when it is `root` itself or below it.
fn under(root: []const u8, path: []const u8) ?[]const u8 {
    if (path.len < root.len) return null;
    if (!pathEql(root, path[0..root.len])) return null;
    if (path.len == root.len) return "";
    const c = path[root.len];
    if (c == '/' or c == '\\') return path[root.len + 1 ..];
    if (root.len > 0 and (root[root.len - 1] == '/' or root[root.len - 1] == '\\')) return path[root.len..];
    return null;
}

test "under" {
    try std.testing.expectEqualStrings("a/b", under("/r", "/r/a/b").?);
    try std.testing.expectEqualStrings("", under("/r", "/r").?);
    try std.testing.expect(under("/r", "/rx/a") == null);
}
