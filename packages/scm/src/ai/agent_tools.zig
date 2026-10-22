//! zg_scm's tools for agents (E10.F06.S03.T01, E09 side). zg_scm sits on
//! zg_ai's layer, so like zg_mcp it is generic over zg_ai's foreign-tool
//! contract; the app instantiates it with `zg_ai.tools.adapters.foreign`:
//!
//! ```zig
//! const X = zg_scm.ai.agent_tools.ToolExporter(zg_ai.tools.adapters.foreign);
//! var x: X = .{ .src = .{ .gpa = gpa, .io = io, .repo_dir = repo_dir, .store = store, .index = ix } };
//! services.scm = &.{x.exporter()};
//! ```
//!
//! Tools: `scm_log` (a revset, newest first), `scm_show` (one commit and
//! its changed paths), `scm_status` (the workspace's working-copy commit,
//! its bookmarks and the lanes), `scm_op_log`, and with a landing queue
//! `scm_lane_submit`. Submitting a lane only asks for review: nothing
//! lands without a human's approval, and no workspace file changes, so it
//! is not a mutating tool. Each call loads the repo at its latest
//! operation. Results are MCP `CallToolResult` JSON with one text block;
//! bad input comes back as `isError` so the model can correct itself.

const std = @import("std");
const id_mod = @import("../store/id.zig");
const object = @import("../store/object.zig");
const store_mod = @import("../store/store.zig");
const index_mod = @import("../graph/index.zig");
const revset = @import("../graph/revset.zig");
const op_mod = @import("../oplog/operation.zig");
const repo_mod = @import("../oplog/repo.zig");
const undo_mod = @import("../oplog/undo.zig");
const landing = @import("landing.zig");
const ObjectId = id_mod.ObjectId;
const Repo = repo_mod.Repo;
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Source = struct {
    gpa: Allocator,
    io: Io,
    /// The repository directory (`.zg/repo`).
    repo_dir: Io.Dir,
    store: *store_mod.Store,
    index: *index_mod.CommitIndex,
    landing: ?*landing.LandingQueue = null,
    /// Whose working copy `@` and `scm_status` mean.
    workspace: []const u8 = "default",
    repo_opts: repo_mod.Options = .{},
};

const max_limit = 200;

const log_schema =
    \\{"type":"object","properties":{"revset":{"type":"string","description":"Revset to list, e.g. \"trunk()..@\" or \"lane(x)\". Default: the 20 latest ancestors of @."},"limit":{"type":"integer","minimum":1,"maximum":200}},"additionalProperties":false}
;
const show_schema =
    \\{"type":"object","properties":{"rev":{"type":"string","description":"A revset naming one commit: an ID prefix, change ID, bookmark or @."}},"required":["rev"],"additionalProperties":false}
;
const empty_schema =
    \\{"type":"object","properties":{},"additionalProperties":false}
;
const op_log_schema =
    \\{"type":"object","properties":{"limit":{"type":"integer","minimum":1,"maximum":200}},"additionalProperties":false}
;
const submit_schema =
    \\{"type":"object","properties":{"lane":{"type":"string"},"target":{"type":"string","description":"Bookmark to land on (default main)."},"strategy":{"type":"string","enum":["rebase","squash"]}},"required":["lane"],"additionalProperties":false}
;

/// `Foreign` is `zg_ai.tools.adapters.foreign` (or a test double with the
/// same declarations). Must not move after `exporter`.
pub fn ToolExporter(comptime Foreign: type) type {
    return struct {
        const Self = @This();

        src: Source,

        pub fn exporter(self: *Self) Foreign.Exporter {
            return .{ .name = "scm", .kind = .scm, .ctx = self, .list = list, .call = call };
        }

        fn list(ctx: *anyopaque, arena: Allocator) anyerror![]const Foreign.ForeignTool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            var out: std.ArrayList(Foreign.ForeignTool) = .empty;
            try out.appendSlice(arena, &.{
                .{ .name = "scm_log", .description = "List commits matching a revset, newest first: short commit ID, change ID, author and subject.", .input_schema_json = log_schema, .read_only = true },
                .{ .name = "scm_show", .description = "Show one commit: IDs, parents, author, full description and the paths it changed against its first parent.", .input_schema_json = show_schema, .read_only = true },
                .{ .name = "scm_status", .description = "The working-copy commit of this workspace with its changed paths, the bookmarks on it, and every lane with its status.", .input_schema_json = empty_schema, .read_only = true },
                .{ .name = "scm_op_log", .description = "Recent repository operations, newest first (who did what; each can be undone).", .input_schema_json = op_log_schema, .read_only = true },
            });
            if (self.src.landing != null) {
                try out.append(arena, .{ .name = "scm_lane_submit", .description = "Submit a lane for landing. It goes to human review first; after approval it is rebased onto the target, checked and landed. Returns the ticket state.", .input_schema_json = submit_schema });
            }
            return out.items;
        }

        fn call(ctx: *anyopaque, io: Io, arena: Allocator, tool: []const u8, input_json: []const u8) anyerror!Foreign.Result {
            _ = io;
            const self: *Self = @ptrCast(@alignCast(ctx));
            var text: Io.Writer.Allocating = .init(arena);
            const ok = self.run(arena, tool, input_json, &text.writer) catch |e| switch (e) {
                error.OutOfMemory => return e,
                else => blk: {
                    text.clearRetainingCapacity();
                    try text.writer.print("{s} failed: {t}", .{ tool, e });
                    break :blk false;
                },
            };
            return .{ .json = try resultJson(arena, text.written(), !ok) };
        }

        /// False when the input was bad (the text says why).
        fn run(self: *Self, arena: Allocator, tool: []const u8, input_json: []const u8, w: *Io.Writer) !bool {
            const Input = struct {
                revset: ?[]const u8 = null,
                rev: ?[]const u8 = null,
                limit: ?u32 = null,
                lane: ?[]const u8 = null,
                target: ?[]const u8 = null,
                strategy: ?landing.Strategy = null,
            };
            const in = std.json.parseFromSliceLeaky(Input, arena, if (input_json.len == 0) "{}" else input_json, .{}) catch {
                try w.writeAll("The arguments are not valid for this tool (check names and types against its schema).");
                return false;
            };
            const limit: u32 = @min(in.limit orelse 20, max_limit);
            if (std.mem.eql(u8, tool, "scm_lane_submit")) {
                const q = self.src.landing orelse return error.UnknownTool;
                const lane = in.lane orelse {
                    try w.writeAll("`lane` is required.");
                    return false;
                };
                const tk = q.submit(lane, .{ .target_bookmark = in.target orelse "main", .strategy = in.strategy orelse .rebase }) catch |e| switch (e) {
                    error.UnknownLane, error.AlreadySubmitted => {
                        try w.print("Cannot submit lane {s}: {t}.", .{ lane, e });
                        return false;
                    },
                    else => return e,
                };
                try w.print("Lane {s}: ticket {d}, {t}", .{ lane, tk.id, tk.state });
                if (tk.review != 0) try w.print(" (review {d})", .{tk.review});
                try w.writeAll(if (tk.state == .in_review) ". It lands after a human approves it.\n" else ".\n");
                return true;
            }

            const repo = try Repo.load(self.src.gpa, self.src.io, self.src.repo_dir, self.src.store, self.src.repo_opts, .head);
            defer repo.close();
            const ix = self.src.index;
            try ix.ensureIndexed(repo.view().heads);
            for (repo.view().wc_commits) |wc| try ix.ensureIndexed(&.{wc.commit});

            if (std.mem.eql(u8, tool, "scm_log")) {
                const src = in.revset orelse "ancestors(@, 20)";
                const positions = (try self.eval(arena, repo, src, limit, w)) orelse return false;
                if (positions.len == 0) try w.writeAll("(no commits)\n");
                for (positions) |p| try self.oneLine(arena, repo, ix.entry(p).id, w);
                return true;
            }
            if (std.mem.eql(u8, tool, "scm_show")) {
                const rev = in.rev orelse {
                    try w.writeAll("`rev` is required.");
                    return false;
                };
                const positions = (try self.eval(arena, repo, rev, 2, w)) orelse return false;
                if (positions.len != 1) {
                    try w.print("`{s}` names {s} commits; give one.", .{ rev, if (positions.len == 0) "no" else "several" });
                    return false;
                }
                try self.show(arena, repo, ix.entry(positions[0]).id, w);
                return true;
            }
            if (std.mem.eql(u8, tool, "scm_status")) {
                try self.status(arena, repo, w);
                return true;
            }
            if (std.mem.eql(u8, tool, "scm_op_log")) {
                var ol = try undo_mod.opLog(repo, self.src.gpa, repo.op(), limit);
                defer ol.deinit();
                for (ol.entries) |e| {
                    var buf: [64]u8 = undefined;
                    try w.print("{s} {s} {s}: {s}\n", .{ e.id.short(&buf, 12), @tagName(e.meta.actor.kind), e.meta.user, e.meta.description });
                }
                return true;
            }
            return error.UnknownTool;
        }

        /// The first `limit` commits of `src`, or null after writing the
        /// parse or resolution error.
        fn eval(self: *Self, arena: Allocator, repo: *Repo, src: []const u8, limit: u32, w: *Io.Writer) !?[]const index_mod.Pos {
            const ix = self.src.index;
            const view = ix.acquire();
            defer view.release();
            const ctx: revset.EvalContext = .{ .graph = view, .view = repo.view(), .store = repo.store, .io = self.src.io, .workspace = self.src.workspace };
            var diag: revset.ParseError = .{};
            var it = revset.evaluate(self.src.gpa, &ctx, src, &diag) catch |e| switch (e) {
                error.OutOfMemory => return e,
                else => {
                    try w.print("Revset `{s}`: {t}", .{ src, e });
                    if (diag.message.len > 0) try w.print(": {s}", .{diag.message});
                    if (diag.suggestion) |s| try w.print(" (did you mean {s}?)", .{s});
                    return null;
                },
            };
            defer it.deinit();
            const got = try it.collect(self.src.gpa, limit);
            defer self.src.gpa.free(got);
            return try arena.dupe(index_mod.Pos, got);
        }

        fn readChange(arena: Allocator, repo: *Repo, id: ObjectId) !object.Change {
            return op_mod.read(object.Change, repo.store, arena, id);
        }

        fn oneLine(_: *Self, arena: Allocator, repo: *Repo, id: ObjectId, w: *Io.Writer) !void {
            const c = try readChange(arena, repo, id);
            var buf: [64]u8 = undefined;
            const conflict: []const u8 = if (c.tree() == null) " (conflict)" else "";
            try w.print("{s} {f} {s} {s}{s}\n", .{ id.short(&buf, 12), c.change_id, c.author.email, subject(c.description), conflict });
        }

        fn show(_: *Self, arena: Allocator, repo: *Repo, id: ObjectId, w: *Io.Writer) !void {
            const c = try readChange(arena, repo, id);
            var buf: [64]u8 = undefined;
            try w.print("commit {s}\nchange {f}\nauthor {s} <{s}>\n", .{ id.hex(&buf), c.change_id, c.author.name, c.author.email });
            for (c.parents) |p| try w.print("parent {s}\n", .{p.short(&buf, 12)});
            if (c.tree() == null) try w.writeAll("state  conflicted\n");
            try w.print("\n{s}\n", .{if (c.description.len == 0) "(no description)" else c.description});
            try changedPaths(arena, repo, c, w);
        }

        fn status(self: *Self, arena: Allocator, repo: *Repo, w: *Io.Writer) !void {
            const v = repo.view();
            var buf: [64]u8 = undefined;
            if (v.wcCommit(self.src.workspace)) |wc| {
                const c = try readChange(arena, repo, wc);
                try w.print("working copy ({s}): {s} {f} {s}\n", .{ self.src.workspace, wc.short(&buf, 12), c.change_id, subject(c.description) });
                for (v.bookmarks) |b| {
                    if (b.target.asNormal()) |t| if (t.eql(wc)) try w.print("bookmark {s}\n", .{b.name});
                }
                try changedPaths(arena, repo, c, w);
            } else try w.print("no working-copy commit for workspace {s}\n", .{self.src.workspace});
            if (v.lanes.len > 0) try w.writeAll("\nlanes:\n");
            for (v.lanes) |l| {
                try w.print("  {s} ({s}, owner {s}): {s}", .{ l.name, l.workspace, l.owner, l.status });
                if (landing.laneState(arena, l)) |st| {
                    try w.print(", ticket {d} {t}", .{ st.ticket, st.state });
                    if (st.reason.len > 0) try w.print(": {s}", .{subject(st.reason)});
                }
                try w.writeByte('\n');
            }
        }
    };
}

fn subject(description: []const u8) []const u8 {
    const first = std.mem.sliceTo(description, '\n');
    return if (first.len == 0) "(no description)" else first;
}

/// "A path", "M path", "D path" lines for `c` against its first parent.
fn changedPaths(arena: Allocator, repo: *Repo, c: object.Change, w: *Io.Writer) !void {
    const tree = c.tree() orelse return;
    const base: ?ObjectId = if (c.parents.len == 0) null else (try op_mod.read(object.Change, repo.store, arena, c.parents[0])).tree();
    var n: usize = 0;
    try w.writeAll("\nchanged:\n");
    try diffTrees(arena, repo, "", base, tree, w, &n);
    if (n == 0) try w.writeAll("  (nothing)\n");
}

fn readTree(arena: Allocator, repo: *Repo, id: ?ObjectId) !object.Tree {
    const t = id orelse return .{ .entries = &.{} };
    return op_mod.read(object.Tree, repo.store, arena, t);
}

fn diffTrees(arena: Allocator, repo: *Repo, prefix: []const u8, a_id: ?ObjectId, b_id: ?ObjectId, w: *Io.Writer, n: *usize) !void {
    if (a_id != null and b_id != null and a_id.?.eql(b_id.?)) return;
    const a = try readTree(arena, repo, a_id);
    const b = try readTree(arena, repo, b_id);
    var names: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (a.entries) |e| try names.put(arena, e.name, {});
    for (b.entries) |e| try names.put(arena, e.name, {});
    names.sort(struct {
        keys: []const []const u8,
        pub fn lessThan(s: @This(), x: usize, y: usize) bool {
            return std.mem.order(u8, s.keys[x], s.keys[y]) == .lt;
        }
    }{ .keys = names.keys() });
    for (names.keys()) |name| {
        const x = a.find(name);
        const y = b.find(name);
        if (x != null and y != null and x.?.kind == y.?.kind and x.?.id.eql(y.?.id)) continue;
        const path = if (prefix.len == 0) name else try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, name });
        const xd = x != null and x.?.kind == .tree;
        const yd = y != null and y.?.kind == .tree;
        if (xd or yd) {
            // A directory on either side: recurse; a file replaced by a
            // directory (or back) also lists the file.
            if (x != null and !xd) try line(w, n, "D", path);
            if (y != null and !yd) try line(w, n, "A", path);
            try diffTrees(arena, repo, path, if (xd) x.?.id else null, if (yd) y.?.id else null, w, n);
            continue;
        }
        try line(w, n, if (x == null) "A" else if (y == null) "D" else "M", path);
    }
}

fn line(w: *Io.Writer, n: *usize, tag: []const u8, path: []const u8) !void {
    n.* += 1;
    try w.print("  {s} {s}\n", .{ tag, path });
}

/// An MCP `CallToolResult` with one text block.
fn resultJson(arena: Allocator, text: []const u8, is_error: bool) ![]const u8 {
    const Block = struct { type: []const u8 = "text", text: []const u8 };
    const R = struct { content: []const Block, isError: bool };
    return std.json.Stringify.valueAlloc(arena, R{ .content = &.{.{ .text = text }}, .isError = is_error }, .{});
}
