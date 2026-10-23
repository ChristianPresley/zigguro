//! zg_workspace's read-only tools for agents (E08.F08.S02.T01):
//! `list_dir`, `glob` and `find_files` over the PathStore snapshot.
//! Ignored and setting-excluded entries are left out (`glob` can include
//! ignored ones). Paths are root-relative, prefixed with the root's name
//! in multi-root workspaces. Results are MCP `CallToolResult` JSON capped
//! at `max_output` bytes, with `truncated` and a hint when cut.
//!
//! `find_files` ranks with a subsequence scorer until the E08.F04
//! FuzzyEngine lands; `grep` (E08.F05 `searchBlocking`) and `find_symbol`
//! (the symbol index) come with those engines.
//!
//! ```zig
//! const X = zg_workspace.ai.tools.ToolExporter(zg_ai.tools.adapters.foreign);
//! var x: X = .{ .src = .{ .store = ps, .roots = &.{.{ .id = .of(0), .name = "app" }} } };
//! services.workspace = &.{x.exporter()};
//! ```

const std = @import("std");
const path_store = @import("../paths/path_store.zig");
const globset = @import("zg_ignore");
const ids = @import("../ids.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const FileId = ids.FileId;
const RootId = ids.RootId;
const Snapshot = path_store.Snapshot;

pub const schemas = struct {
    pub const list_dir = @embedFile("schemas/list_dir.json");
    pub const glob = @embedFile("schemas/glob.json");
    pub const find_files = @embedFile("schemas/find_files.json");
};

/// E16 path policy: null allows, else the reason for refusing. Paths are
/// as the tools print them.
pub const PathPolicy = struct {
    ctx: *anyopaque,
    check: *const fn (ctx: *anyopaque, path: []const u8, write: bool) ?[]const u8,
};

pub const Root = struct { id: RootId, name: []const u8 };

pub const Source = struct {
    store: *path_store.PathStore,
    roots: []const Root,
    policy: ?PathPolicy = null,
    max_output: usize = 32 << 10,
};

/// `Foreign` is `zg_ai.tools.adapters.foreign` (or a test double with the
/// same declarations). Must not move after `exporter`.
pub fn ToolExporter(comptime Foreign: type) type {
    return struct {
        const Self = @This();

        src: Source,

        pub fn exporter(self: *Self) Foreign.Exporter {
            return .{ .name = "workspace", .kind = .workspace, .ctx = self, .list = list, .call = call };
        }

        fn list(ctx: *anyopaque, arena: Allocator) anyerror![]const Foreign.ForeignTool {
            _ = ctx;
            return arena.dupe(Foreign.ForeignTool, &.{
                .{ .name = "list_dir", .description = "List a workspace folder (up to 3 levels), without ignored files.", .input_schema_json = schemas.list_dir, .read_only = true },
                .{ .name = "glob", .description = "Workspace files matching a glob such as src/**/*.zig, in path order.", .input_schema_json = schemas.glob, .read_only = true },
                .{ .name = "find_files", .description = "Fuzzy-find files by name or partial path, best matches first.", .input_schema_json = schemas.find_files, .read_only = true },
            });
        }

        fn call(ctx: *anyopaque, io: Io, arena: Allocator, tool: []const u8, input_json: []const u8) anyerror!Foreign.Result {
            _ = io;
            const self: *Self = @ptrCast(@alignCast(ctx));
            const r = try run(&self.src, arena, tool, input_json);
            return .{ .json = r.json };
        }
    };
}

pub const Output = struct { json: []const u8, is_error: bool = false };

/// Runs `tool` and wraps its output as a `CallToolResult`.
pub fn run(src: *const Source, arena: Allocator, tool: []const u8, input_json: []const u8) !Output {
    var msg: []const u8 = "";
    const input = if (input_json.len == 0) "{}" else input_json;
    const snap = src.store.snapshot();
    defer snap.release();
    const body: ?[]const u8 = blk: {
        const r = if (std.mem.eql(u8, tool, "list_dir"))
            listDir(src, snap, arena, input, &msg)
        else if (std.mem.eql(u8, tool, "glob"))
            glob(src, snap, arena, input, &msg)
        else if (std.mem.eql(u8, tool, "find_files"))
            findFiles(src, snap, arena, input, &msg)
        else
            return error.UnknownTool;
        break :blk r catch |e| switch (e) {
            error.OutOfMemory => return e,
            error.BadInput => null,
        };
    };
    const text = body orelse msg;
    const Block = struct { type: []const u8 = "text", text: []const u8 };
    const R = struct { content: []const Block, isError: bool };
    return .{ .json = try std.json.Stringify.valueAlloc(arena, R{ .content = &.{.{ .text = text }}, .isError = body == null }, .{}), .is_error = body == null };
}

const Error = error{ OutOfMemory, BadInput };

fn bad(arena: Allocator, msg: *[]const u8, comptime fmt: []const u8, args: anytype) error{BadInput} {
    msg.* = std.fmt.allocPrint(arena, fmt, args) catch "invalid input";
    return error.BadInput;
}

fn parse(comptime T: type, arena: Allocator, input: []const u8, msg: *[]const u8) Error!T {
    return std.json.parseFromSliceLeaky(T, arena, input, .{}) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => bad(arena, msg, "the arguments do not match the tool's schema", .{}),
    };
}

/// The printed path of `id` (root name first in multi-root workspaces).
fn display(src: *const Source, snap: *const Snapshot, arena: Allocator, id: FileId) ![]const u8 {
    var buf: [4096]u8 = undefined;
    const rel = snap.pathOf(id, &buf);
    if (src.roots.len <= 1) return arena.dupe(u8, rel);
    const r = snap.rootOf(id) orelse return arena.dupe(u8, rel);
    for (src.roots) |root| if (root.id == r) {
        return if (rel.len == 0) arena.dupe(u8, root.name) else std.fmt.allocPrint(arena, "{s}/{s}", .{ root.name, rel });
    };
    return arena.dupe(u8, rel);
}

/// The root and root-relative path a printed path names.
fn resolve(src: *const Source, path: []const u8) ?struct { root: RootId, rel: []const u8 } {
    const p = std.mem.trim(u8, path, "/");
    if (src.roots.len == 0) return null;
    if (src.roots.len == 1) return .{ .root = src.roots[0].id, .rel = p };
    const slash = std.mem.indexOfScalar(u8, p, '/') orelse p.len;
    for (src.roots) |r| if (std.mem.eql(u8, r.name, p[0..slash]))
        return .{ .root = r.id, .rel = if (slash < p.len) p[slash + 1 ..] else "" };
    return null;
}

fn hiddenNode(info: path_store.NodeInfo, include_ignored: bool) bool {
    return info.flags.excluded_by_setting or (info.flags.ignored and !include_ignored);
}

fn denied(src: *const Source, path: []const u8) ?[]const u8 {
    const p = src.policy orelse return null;
    return p.check(p.ctx, path, false);
}

/// `{"items": [...], "truncated": bool}`, cut to fit `cap` bytes.
fn boundedList(arena: Allocator, comptime T: type, items: []const T, cut_early: bool, cap: usize, hint: []const u8) ![]const u8 {
    var n = items.len;
    while (true) {
        const truncated = cut_early or n < items.len;
        const s = try std.json.Stringify.valueAlloc(arena, .{ .items = items[0..n], .truncated = truncated, .hint = if (truncated) hint else null }, .{ .emit_null_optional_fields = false });
        if (s.len <= cap or n == 0) return s;
        n = n * 3 / 4;
    }
}

const Entry = struct { path: []const u8, type: []const u8, size: ?u64 = null, depth: u8 };

fn listDir(src: *const Source, snap: *const Snapshot, arena: Allocator, input: []const u8, msg: *[]const u8) Error![]const u8 {
    const In = struct { path: []const u8, depth: u8 = 1 };
    const in = try parse(In, arena, input, msg);
    if (in.depth < 1 or in.depth > 3) return bad(arena, msg, "depth must be 1 to 3", .{});
    if (std.mem.indexOf(u8, in.path, "..") != null or std.mem.indexOfScalar(u8, in.path, '\\') != null)
        return bad(arena, msg, "invalid path \"{s}\": use a workspace-relative path", .{in.path});
    var out: std.ArrayList(Entry) = .empty;
    if (src.roots.len > 1 and std.mem.trim(u8, in.path, "/").len == 0) {
        for (src.roots) |r| try out.append(arena, .{ .path = r.name, .type = "dir", .depth = 1 });
        return boundedList(arena, Entry, out.items, false, src.max_output, "list one root at a time");
    }
    const at = resolve(src, in.path) orelse return bad(arena, msg, "no folder {s}", .{in.path});
    const dir = snap.lookup(at.root, at.rel) orelse return bad(arena, msg, "no folder {s}", .{in.path});
    if (!snap.info(dir).isDir()) return bad(arena, msg, "{s} is a file", .{in.path});
    if (denied(src, try display(src, snap, arena, dir))) |reason| return bad(arena, msg, "access to {s} denied: {s}", .{ in.path, reason });
    try walk(src, snap, arena, dir, 1, in.depth, &out);
    return boundedList(arena, Entry, out.items, false, src.max_output, "use a smaller depth or a subfolder");
}

fn walk(src: *const Source, snap: *const Snapshot, arena: Allocator, dir: FileId, depth: u8, max: u8, out: *std.ArrayList(Entry)) Error!void {
    for (snap.children(dir)) |kid| {
        const info = snap.info(kid);
        if (hiddenNode(info, false)) continue;
        const p = try display(src, snap, arena, kid);
        if (denied(src, p) != null) continue;
        const is_dir = info.isDir();
        try out.append(arena, .{ .path = p, .type = if (is_dir) "dir" else "file", .size = if (is_dir or info.flags.stat_pending) null else info.size, .depth = depth });
        if (is_dir and depth < max) try walk(src, snap, arena, kid, depth + 1, max, out);
    }
}

fn glob(src: *const Source, snap: *const Snapshot, arena: Allocator, input: []const u8, msg: *[]const u8) Error![]const u8 {
    const In = struct { pattern: []const u8, root: ?[]const u8 = null, limit: u32 = 500, include_ignored: bool = false };
    const in = try parse(In, arena, input, msg);
    var gs = globset.GlobSet.compile(arena, in.pattern, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return bad(arena, msg, "invalid glob \"{s}\": {t}", .{ in.pattern, e }),
    };
    defer gs.deinit();
    const limit = @min(@max(in.limit, 1), 2000);
    var out: std.ArrayList([]const u8) = .empty;
    var more = false;
    var buf: [4096]u8 = undefined;
    for (src.roots) |r| {
        if (in.root) |want| if (!std.mem.eql(u8, want, r.name)) continue;
        const top = snap.rootDir(r.id) orelse continue;
        // Depth-first in name order, pruning folders nothing can match in.
        var stack: std.ArrayList(FileId) = .empty;
        try stack.append(arena, top);
        while (stack.pop()) |dir| {
            const kids = snap.children(dir);
            var i = kids.len;
            while (i > 0) {
                i -= 1;
                const kid = kids[i];
                const info = snap.info(kid);
                if (hiddenNode(info, in.include_ignored)) continue;
                const rel = snap.pathOf(kid, &buf);
                if (info.isDir()) {
                    if (gs.matchesDirPrefix(rel) != .no) try stack.append(arena, kid);
                } else if (gs.matches(rel)) {
                    const p = try display(src, snap, arena, kid);
                    if (denied(src, p) == null) try out.append(arena, p);
                }
            }
        }
    }
    std.mem.sort([]const u8, out.items, {}, lessStr);
    if (out.items.len > limit) {
        out.items.len = limit;
        more = true;
    }
    return boundedList(arena, []const u8, out.items, more, src.max_output, "narrow the pattern or pass `root`");
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

const Hit = struct { path: []const u8, score: i32 };

fn findFiles(src: *const Source, snap: *const Snapshot, arena: Allocator, input: []const u8, msg: *[]const u8) Error![]const u8 {
    const In = struct { query: []const u8, limit: u32 = 50 };
    const in = try parse(In, arena, input, msg);
    const q = std.mem.trim(u8, in.query, " ");
    if (q.len == 0) return bad(arena, msg, "`query` is empty", .{});
    var need: u64 = 0;
    for (q) |c| need |= path_store.FlatNames.maskOf(c);
    const flat = snap.flatNames();
    const limit = @min(@max(in.limit, 1), 200);
    const Cand = struct { i: u32, score: i32 };
    var cands: std.ArrayList(Cand) = .empty;
    for (flat.ids, 0..) |id, i| {
        if (flat.char_mask[i] & need != need) continue;
        const p = flat.path(i);
        const s = fuzzyScore(q, p, flat.basename_start[i]) orelse continue;
        if (hiddenNode(snap.info(id), false)) continue;
        try cands.append(arena, .{ .i = @intCast(i), .score = s });
    }
    std.mem.sort(Cand, cands.items, flat, struct {
        fn lt(f: *const path_store.FlatNames, a: Cand, b: Cand) bool {
            if (a.score != b.score) return a.score > b.score;
            const pa = f.path(a.i);
            const pb = f.path(b.i);
            if (pa.len != pb.len) return pa.len < pb.len;
            return std.mem.lessThan(u8, pa, pb);
        }
    }.lt);
    var out: std.ArrayList(Hit) = .empty;
    for (cands.items) |c| {
        if (out.items.len == limit) break;
        const p = try display(src, snap, arena, flat.ids[c.i]);
        if (denied(src, p) != null) continue;
        try out.append(arena, .{ .path = p, .score = c.score });
    }
    return boundedList(arena, Hit, out.items, false, src.max_output, "lower `limit`");
}

/// A subsequence match of `q` in `path` (ASCII case-insensitive), or null.
/// Rewards matches in the basename, at segment or word starts and in
/// runs; an exact basename stem match scores highest.
pub fn fuzzyScore(q: []const u8, path: []const u8, base_start: usize) ?i32 {
    const base = path[@min(base_start, path.len)..];
    const stem = if (std.mem.lastIndexOfScalar(u8, base, '.')) |d| (if (d > 0) base[0..d] else base) else base;
    if (std.ascii.eqlIgnoreCase(q, stem) or std.ascii.eqlIgnoreCase(q, base)) return 1000 - @as(i32, @intCast(@min(path.len, 500)));
    // Prefer matching the basename: try it alone first.
    if (std.mem.indexOfScalar(u8, q, '/') == null) if (subseq(q, base)) |s| return s + 200;
    return subseq(q, path);
}

fn subseq(q: []const u8, text: []const u8) ?i32 {
    var score: i32 = 0;
    var ti: usize = 0;
    var prev_hit: ?usize = null;
    for (q) |qc| {
        const want = std.ascii.toLower(qc);
        while (ti < text.len and std.ascii.toLower(text[ti]) != want) ti += 1;
        if (ti == text.len) return null;
        score += 10;
        if (ti == 0 or isBoundary(text[ti - 1], text[ti])) score += 15;
        if (prev_hit) |p| {
            if (p + 1 == ti) score += 20 else score -= @intCast(@min(ti - p, 10));
        }
        prev_hit = ti;
        ti += 1;
    }
    return score - @as(i32, @intCast(@min(text.len / 8, 20)));
}

fn isBoundary(prev: u8, cur: u8) bool {
    return switch (prev) {
        '/', '.', '_', '-', ' ' => true,
        'a'...'z' => cur >= 'A' and cur <= 'Z',
        else => false,
    };
}
