//! `zg review` (E12.F03.S05.T01): the review queue of the workspace in
//! the current directory, from the terminal. It opens the same store
//! as the IDE (`.zigguro/review/`), folds it and decides through the
//! same `Applier`, so both can work on one workspace at once: each
//! writes its records to the journal and reads the other's.
//!
//! Not here yet: review comments and fix requests (`comment`, `threads`,
//! `fix`) and approvals (`approvals`, `approve`, `deny`) wait for F05;
//! `zg agent --review` and the `review` stream events come next; the
//! "file is open in zigguro" refusal needs the IDE's `doc_open` records.
//!
//! Exit codes: 0 ok, 1 usage, 2 store error, 3 conflict or base moved,
//! 4 not found, 5 partially applied.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_review = @import("zg_review");
const zg_ai = @import("zg_ai");
const render = @import("review_render.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;
const model = zg_review.model;
const apply = zg_review.apply;
const ChangesetId = model.ChangesetId;
const Changeset = model.Changeset;
const ulid = zg_ai.proto.agent_ref;

pub const Exit = enum(u8) {
    ok = 0,
    usage = 1,
    store = 2,
    conflict = 3,
    not_found = 4,
    partial = 5,
};

/// The store's directory under the workspace root.
pub const store_path = ".zigguro/review";

pub const usage =
    \\Usage: zg review <command> [args]
    \\
    \\  list [--state pending|all] [--agent SESSION] [--json]
    \\        the changesets waiting for review (all of them with --state all)
    \\  show ID [--patch] [--file PATH] [--json]
    \\        what a changeset changes; --patch adds the diff
    \\  accept ID (--all | --file PATH... | --hunk PATH:N[,N...] | --hunk PATH:*) [--yes]
    \\  reject ID (same selectors)
    \\        decide hunks (numbered from 1 as `show --patch` prints them),
    \\        whole files or the whole changeset; accepted text is written
    \\  checkpoints [--session SESSION] [--json]
    \\        the turn checkpoints, oldest first
    \\  restore CKPT [--mode agent|full] [--dry-run]
    \\        undo what review applied after a checkpoint: its session's
    \\        changes (agent, the default) or every agent's (full)
    \\  debug-dump [--from SEQ]
    \\        the store's journal records as NDJSON
    \\
    \\ID is a changeset number (`3` or `#3`); SESSION is a session id or a
    \\prefix of it. --json prints NDJSON (see apps/zg/docs/review-json.md).
    \\
    \\Exit codes: 0 ok, 1 usage, 2 store error, 3 conflict or base moved,
    \\4 not found, 5 partially applied.
    \\
;

pub const Options = struct {
    style: render.Style = .{},
    /// Asks before accepting or rejecting a whole changeset (a terminal
    /// on stdin, without --yes); null never asks.
    confirm: ?*Io.Reader = null,
};

/// `zg review` in the current directory, plain output.
pub fn run(gpa: Allocator, io: Io, args: []const []const u8, out: *Writer, err: *Writer) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const root = try std.process.currentPathAlloc(io, arena_state.allocator());
    const now = Io.Clock.real.now(io);
    return runIn(gpa, io, .cwd(), root, args, out, err, .{ .style = .{ .now_ms = @intCast(@divFloor(now.nanoseconds, std.time.ns_per_ms)) } });
}

/// `zg review` from `main`: colour on a terminal unless NO_COLOR is set,
/// tables as wide as COLUMNS (100 when unset), and a confirmation for
/// `--all` when stdin is a terminal.
pub fn runCli(rt: *zg_core.Runtime, min: std.process.Init.Minimal, args: []const []const u8) !u8 {
    const io = rt.io;
    var env = try min.environ.createMap(rt.gpa);
    defer env.deinit();
    var obuf: [8192]u8 = undefined;
    var out: Io.File.Writer = .init(.stdout(), io, &obuf);
    var ebuf: [1024]u8 = undefined;
    var err: Io.File.Writer = .init(.stderr(), io, &ebuf);
    var ibuf: [256]u8 = undefined;
    var in: Io.File.Reader = .init(.stdin(), io, &ibuf);
    const out_tty = Io.File.stdout().isTty(io) catch false;
    const in_tty = Io.File.stdin().isTty(io) catch false;
    var width: u16 = 100;
    if (env.get("COLUMNS")) |cols| width = std.fmt.parseInt(u16, cols, 10) catch 100;
    var arena_state: std.heap.ArenaAllocator = .init(rt.gpa);
    defer arena_state.deinit();
    const root = try std.process.currentPathAlloc(io, arena_state.allocator());
    const now = Io.Clock.real.now(io);
    return runIn(rt.gpa, io, .cwd(), root, args, &out.interface, &err.interface, .{
        .style = .{
            .color = out_tty and env.get("NO_COLOR") == null,
            .width = @max(width, 40),
            .now_ms = @intCast(@divFloor(now.nanoseconds, std.time.ns_per_ms)),
        },
        .confirm = if (in_tty and out_tty) &in.interface else null,
    });
}

/// `zg review` on the workspace at `dir` (absolute path `root`).
pub fn runIn(gpa: Allocator, io: Io, dir: Io.Dir, root: []const u8, args: []const []const u8, out: *Writer, err: *Writer, o: Options) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var c: Cmd = .{ .gpa = gpa, .arena = arena_state.allocator(), .io = io, .dir = dir, .root = root, .out = out, .err = err, .o = o };
    const code = c.dispatch(args) catch |e| switch (e) {
        error.Usage => .usage,
        else => blk: {
            err.print("zg review: {t}\n", .{e}) catch {};
            break :blk .store;
        },
    };
    out.flush() catch {};
    err.flush() catch {};
    return @intFromEnum(code);
}

/// The store folded into a queue, history and checkpoints.
const Ws = struct {
    store: *zg_review.store.ChangesetStore,
    q: *model.Queue,
    history: model.History,
    disk: apply.DirFiles,
    cps: zg_review.checkpoint.Checkpoints,
    applier: apply.Applier,
    sink: zg_review.store.store.QueueSink,

    fn open(ws: *Ws, gpa: Allocator, io: Io, dir: Io.Dir, root: []const u8) !void {
        ws.store = try .open(gpa, io, dir, store_path, .{});
        errdefer ws.store.close();
        ws.q = try model.Queue.init(gpa, io, .{ .root = root, .blobs = ws.store.blobs(), .journal = ws.store.journalPort() });
        errdefer ws.q.deinit();
        ws.history = .init(gpa, ws.store.recorder());
        ws.disk = .{ .dir = dir, .io = io };
        ws.cps = .init(gpa, io, ws.q, &ws.history, ws.disk.files(), ws.store.checkpointRecorder());
        ws.applier = .init(gpa, io, ws.q, ws.disk.files(), &ws.history);
        ws.sink = ws.store.queueSink(ws.q, &ws.history, ws.cps.sink());
        _ = try ws.store.load(ws.sink.sink());
    }

    /// Writes what was decided.
    fn flush(ws: *Ws) !void {
        try ws.store.flush();
    }

    fn close(ws: *Ws) void {
        ws.store.close();
        ws.cps.deinit();
        ws.q.deinit();
        ws.history.deinit();
    }
};

const Cmd = struct {
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    dir: Io.Dir,
    root: []const u8,
    out: *Writer,
    err: *Writer,
    o: Options,

    fn dispatch(c: *Cmd, args: []const []const u8) !Exit {
        if (args.len == 0) {
            try c.err.writeAll(usage);
            return .usage;
        }
        const sub = args[0];
        const rest = args[1..];
        if (isHelp(sub)) {
            try c.out.writeAll(usage);
            return .ok;
        }
        for (rest) |a| if (isHelp(a)) {
            try c.out.writeAll(usage);
            return .ok;
        };
        if (eql(sub, "list")) return c.list(rest);
        if (eql(sub, "show")) return c.show(rest);
        if (eql(sub, "accept")) return c.decide(rest, .accept);
        if (eql(sub, "reject")) return c.decide(rest, .reject);
        if (eql(sub, "checkpoints")) return c.checkpoints(rest);
        if (eql(sub, "restore")) return c.restore(rest);
        if (eql(sub, "debug-dump")) return c.debugDump(rest);
        for ([_][]const u8{ "comment", "threads", "fix", "approvals", "approve", "deny" }) |later| if (eql(sub, later)) {
            try c.err.print("zg review {s}: not available yet (review comments and approvals arrive with E12.F05)\n", .{sub});
            return .usage;
        };
        return c.usageError("unknown command {s}", .{sub});
    }

    fn usageError(c: *Cmd, comptime fmt: []const u8, args: anytype) !Exit {
        try c.err.print("zg review: " ++ fmt ++ "\n", args);
        try c.err.writeAll("Run `zg review --help` for usage.\n");
        return .usage;
    }

    fn fail(c: *Cmd, code: Exit, comptime fmt: []const u8, args: anytype) !Exit {
        try c.err.print("zg review: " ++ fmt ++ "\n", args);
        return code;
    }

    /// The workspace's store, or null (with a message) when it has none
    /// and `need` says that is an error.
    fn openWs(c: *Cmd, ws: *Ws) !bool {
        c.dir.access(c.io, store_path, .{}) catch |e| switch (e) {
            error.FileNotFound => return false,
            else => return e,
        };
        ws.open(c.gpa, c.io, c.dir, c.root) catch |e| {
            try c.err.print("zg review: cannot open {s}: {t}\n", .{ store_path, e });
            return error.StoreOpen;
        };
        return true;
    }

    fn noStore(c: *Cmd) !Exit {
        return c.fail(.not_found, "no review store in this workspace ({s})", .{store_path});
    }

    // ------------------------------------------------------------- list

    fn list(c: *Cmd, args: []const []const u8) !Exit {
        var all = false;
        var agent: ?[]const u8 = null;
        var json = false;
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (eql(a, "--json")) {
                json = true;
            } else if (eql(a, "--state")) {
                const v = value(args, &i) orelse return c.usageError("--state needs pending or all", .{});
                if (eql(v, "all")) all = true else if (!eql(v, "pending")) return c.usageError("--state is pending or all, not {s}", .{v});
            } else if (eql(a, "--agent")) {
                agent = value(args, &i) orelse return c.usageError("--agent needs a session id", .{});
            } else return c.usageError("list: unexpected {s}", .{a});
        }
        var ws: Ws = undefined;
        if (!try c.openWs(&ws)) {
            if (!json) try c.out.writeAll("No changesets.\n");
            return .ok;
        }
        defer ws.close();
        var shown: std.ArrayList(*const Changeset) = .empty;
        for (ws.q.changesets.values()) |cs| {
            if (!all and cs.state != .pending and cs.state != .partially_applied) continue;
            if (agent) |want| if (!sessionMatches(cs.prov.origin.agentRef(), want)) continue;
            try shown.append(c.arena, cs);
        }
        if (json) {
            for (shown.items) |cs| try render.jsonChangeset(c.out, cs);
        } else try render.writeTable(c.out, c.o.style, shown.items);
        return .ok;
    }

    // ------------------------------------------------------------- show

    fn show(c: *Cmd, args: []const []const u8) !Exit {
        var id: ?ChangesetId = null;
        var patch = false;
        var json = false;
        var only: ?[]const u8 = null;
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (eql(a, "--patch")) {
                patch = true;
            } else if (eql(a, "--json")) {
                json = true;
            } else if (eql(a, "--file")) {
                only = value(args, &i) orelse return c.usageError("--file needs a path", .{});
            } else if (id == null and !std.mem.startsWith(u8, a, "--")) {
                id = parseId(a) orelse return c.usageError("not a changeset id: {s}", .{a});
            } else return c.usageError("show: unexpected {s}", .{a});
        }
        const cs_id = id orelse return c.usageError("show needs a changeset id", .{});
        var ws: Ws = undefined;
        if (!try c.openWs(&ws)) return c.noStore();
        defer ws.close();
        const cs = ws.q.get(cs_id) orelse return c.fail(.not_found, "no changeset {f}", .{cs_id});
        if (only) |p| if (cs.fileIndex(p) == null) return c.fail(.not_found, "{f} does not change {s}", .{ cs_id, p });

        if (json) {
            try render.jsonChangeset(c.out, cs);
            for (cs.files) |*f| {
                if (only) |p| if (!eql(p, f.path)) continue;
                try render.jsonFile(c.out, cs, f);
                if (f.hunks.len == 0) continue;
                var base: []const []const u8 = &.{};
                var new: []const []const u8 = &.{};
                if (patch) if (try render.texts(c.arena, ws.q.blobs, f)) |t| {
                    base = try render.splitLines(c.arena, t.base);
                    new = try render.splitLines(c.arena, t.new);
                };
                for (0..f.hunks.len) |h| try render.jsonHunk(c.out, cs, f, h, if (patch) render.hunkLines(f, h, base, new) else null);
            }
            return .ok;
        }
        try render.writeSummary(c.out, c.o.style, cs);
        if (!patch) return .ok;
        for (cs.files) |*f| {
            if (only) |p| if (!eql(p, f.path)) continue;
            try c.out.writeByte('\n');
            try render.writePatch(c.out, c.arena, c.o.style, ws.q.blobs, f);
        }
        return .ok;
    }

    // ------------------------------------------------------ accept/reject

    const Selector = struct {
        file: u32,
        whole: bool = false,
        hunks: std.ArrayList(u32) = .empty,
    };

    fn decide(c: *Cmd, args: []const []const u8, how: apply.applier.Whole) !Exit {
        const verb = if (how == .accept) "accept" else "reject";
        var id: ?ChangesetId = null;
        var all = false;
        var yes = false;
        var files: std.ArrayList([]const u8) = .empty;
        var hunk_args: std.ArrayList([]const u8) = .empty;
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (eql(a, "--all")) {
                all = true;
            } else if (eql(a, "--yes") or eql(a, "-y")) {
                yes = true;
            } else if (eql(a, "--file")) {
                try files.append(c.arena, value(args, &i) orelse return c.usageError("--file needs a path", .{}));
            } else if (eql(a, "--hunk")) {
                try hunk_args.append(c.arena, value(args, &i) orelse return c.usageError("--hunk needs PATH:N[,N...] or PATH:*", .{}));
            } else if (id == null and !std.mem.startsWith(u8, a, "--")) {
                id = parseId(a) orelse return c.usageError("not a changeset id: {s}", .{a});
            } else return c.usageError("{s}: unexpected {s}", .{ verb, a });
        }
        const cs_id = id orelse return c.usageError("{s} needs a changeset id", .{verb});
        if (!all and files.items.len == 0 and hunk_args.items.len == 0)
            return c.usageError("say what to {s}: --all, --file PATH or --hunk PATH:N", .{verb});
        if (all and (files.items.len > 0 or hunk_args.items.len > 0))
            return c.usageError("--all cannot be combined with --file or --hunk", .{});
        // Parse the hunk selectors before touching the store.
        const HunkArg = struct { path: []const u8, star: bool, nums: []const u32 };
        var parsed: std.ArrayList(HunkArg) = .empty;
        for (hunk_args.items) |h| {
            const colon = std.mem.lastIndexOfScalar(u8, h, ':') orelse return c.usageError("--hunk {s}: expected PATH:N[,N...] or PATH:*", .{h});
            const path = h[0..colon];
            const spec = h[colon + 1 ..];
            if (path.len == 0 or spec.len == 0) return c.usageError("--hunk {s}: expected PATH:N[,N...] or PATH:*", .{h});
            if (eql(spec, "*")) {
                try parsed.append(c.arena, .{ .path = path, .star = true, .nums = &.{} });
                continue;
            }
            var nums: std.ArrayList(u32) = .empty;
            var it = std.mem.splitScalar(u8, spec, ',');
            while (it.next()) |n| {
                const v = std.fmt.parseInt(u32, n, 10) catch return c.usageError("--hunk {s}: {s} is not a hunk number", .{ h, n });
                if (v == 0) return c.usageError("--hunk {s}: hunks are numbered from 1", .{h});
                try nums.append(c.arena, v);
            }
            try parsed.append(c.arena, .{ .path = path, .star = false, .nums = nums.items });
        }

        var ws: Ws = undefined;
        if (!try c.openWs(&ws)) return c.noStore();
        defer ws.close();
        const cs = ws.q.get(cs_id) orelse return c.fail(.not_found, "no changeset {f}", .{cs_id});
        if (cs.state != .pending and cs.state != .partially_applied)
            return c.fail(.conflict, "{f} is {s}; there is nothing left to {s}", .{ cs_id, @tagName(cs.state), verb });

        // One selector per file.
        var sels: std.ArrayList(Selector) = .empty;
        const selFor = struct {
            fn get(arena: Allocator, all_sels: *std.ArrayList(Selector), file: u32) !*Selector {
                for (all_sels.items) |*s| if (s.file == file) return s;
                try all_sels.append(arena, .{ .file = file });
                return &all_sels.items[all_sels.items.len - 1];
            }
        }.get;
        if (all) {
            for (cs.files, 0..) |f, fi| if (isOpen(f.state)) {
                (try selFor(c.arena, &sels, @intCast(fi))).whole = true;
            };
        }
        for (files.items) |p| {
            const fi = cs.fileIndex(p) orelse return c.fail(.not_found, "{f} does not change {s}", .{ cs_id, p });
            (try selFor(c.arena, &sels, fi)).whole = true;
        }
        for (parsed.items) |h| {
            const fi = cs.fileIndex(h.path) orelse return c.fail(.not_found, "{f} does not change {s}", .{ cs_id, h.path });
            const f = &cs.files[fi];
            const s = try selFor(c.arena, &sels, fi);
            if (h.star) {
                s.whole = true;
                continue;
            }
            if (f.hunks.len == 0) return c.fail(.not_found, "{s} has no hunks to pick; use --file {s}", .{ h.path, h.path });
            for (h.nums) |n| {
                if (n > f.hunks.len) return c.fail(.not_found, "{s} has {d} open hunk{s}, not {d}", .{ h.path, f.hunks.len, if (f.hunks.len == 1) "" else "s", n });
                const hid = f.hunks[n - 1].id;
                if (std.mem.indexOfScalar(u32, s.hunks.items, hid) == null) try s.hunks.append(c.arena, hid);
            }
        }
        for (sels.items) |s| if (!isOpen(cs.files[s.file].state))
            return c.fail(.conflict, "{s} in {f} is {s} already", .{ cs.files[s.file].path, cs_id, @tagName(cs.files[s.file].state) });

        if (all and !yes) if (c.o.confirm) |r| {
            const n = render.counts(cs);
            try c.out.print("{s} all of {f} ({d} file{s}, +{d} -{d})? [y/N] ", .{ if (how == .accept) "Accept" else "Reject", cs_id, n.files, if (n.files == 1) "" else "s", n.added, n.removed });
            try c.out.flush();
            const line = (r.takeDelimiter('\n') catch null) orelse "";
            const ans = std.mem.trim(u8, line, " \t\r");
            if (!eql(ans, "y") and !eql(ans, "Y") and !eql(ans, "yes")) {
                try c.out.writeAll("Nothing changed.\n");
                return .ok;
            }
        };

        var items: std.ArrayList(apply.ApplyItem) = .empty;
        for (sels.items) |s| {
            if (s.whole) {
                try items.append(c.arena, .{ .file = s.file, .whole_file = how });
            } else if (how == .accept) {
                try items.append(c.arena, .{ .file = s.file, .input = .{ .accept = s.hunks.items } });
            } else try items.append(c.arena, .{ .file = s.file, .input = .{ .reject = s.hunks.items } });
        }

        const res = ws.applier.apply(.{ .cs = cs_id, .items = items.items }) catch |e| return c.applyError(e, cs_id);
        switch (res) {
            .failed => |f| {
                if (f.rolled_back) return c.fail(if (isConflict(f.err)) .conflict else .store, "{s} {s}: {t}; nothing was changed", .{ verb, f.path, f.err });
                ws.flush() catch {};
                return c.fail(.partial, "{s} {s}: {t}; the files before it were written and could not be rolled back", .{ verb, f.path, f.err });
            },
            .ok => |ok| {
                ws.flush() catch |e| return c.fail(.store, "the decision was applied but could not be recorded: {t}", .{e});
                const after = ws.q.get(cs_id).?;
                try c.out.print("{s} {d} hunk{s} in {d} file{s} of {f}; it is {s} now.\n", .{
                    if (how == .accept) "Accepted" else "Rejected",
                    ok.hunks,
                    if (ok.hunks == 1) "" else "s",
                    ok.files,
                    if (ok.files == 1) "" else "s",
                    cs_id,
                    @tagName(after.state),
                });
                return .ok;
            },
        }
    }

    fn applyError(c: *Cmd, e: anyerror, id: ChangesetId) !Exit {
        return switch (e) {
            error.UnknownChangeset, error.UnknownFile => c.fail(.not_found, "{f}: {t}", .{ id, e }),
            error.BaseMoved => c.fail(.conflict, "a file of {f} changed since the agent read it (base moved); review it again in zigguro or reject it", .{id}),
            error.TargetExists, error.SourceMissing, error.NotOpen, error.AlreadyDecided, error.NotLatest => c.fail(.conflict, "{f}: {t}", .{ id, e }),
            error.OutOfMemory => e,
            else => c.fail(.store, "{f}: {t}", .{ id, e }),
        };
    }

    // ------------------------------------------------- checkpoints

    fn checkpoints(c: *Cmd, args: []const []const u8) !Exit {
        var session: ?[]const u8 = null;
        var json = false;
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (eql(a, "--json")) {
                json = true;
            } else if (eql(a, "--session")) {
                session = value(args, &i) orelse return c.usageError("--session needs a session id", .{});
            } else return c.usageError("checkpoints: unexpected {s}", .{a});
        }
        var ws: Ws = undefined;
        if (!try c.openWs(&ws)) {
            if (!json) try c.out.writeAll("No checkpoints.\n");
            return .ok;
        }
        defer ws.close();
        var shown: std.ArrayList(model.Checkpoint) = .empty;
        for (ws.cps.list.items) |cp| {
            if (session) |want| if (!sessionMatches(.{ .session = cp.session }, want)) continue;
            try shown.append(c.arena, cp);
        }
        if (json) {
            for (shown.items) |cp| try render.jsonCheckpoint(c.out, cp);
        } else try render.writeCheckpoints(c.out, c.o.style, shown.items);
        return .ok;
    }

    fn restore(c: *Cmd, args: []const []const u8) !Exit {
        var id: ?u64 = null;
        var scope: zg_review.checkpoint.checkpoints.Scope = .session;
        var dry = false;
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (eql(a, "--dry-run")) {
                dry = true;
            } else if (eql(a, "--mode")) {
                const v = value(args, &i) orelse return c.usageError("--mode needs agent or full", .{});
                scope = if (eql(v, "agent")) .session else if (eql(v, "full")) .all_agents else return c.usageError("--mode is agent or full, not {s}", .{v});
            } else if (id == null and !std.mem.startsWith(u8, a, "--")) {
                id = std.fmt.parseInt(u64, a, 10) catch return c.usageError("not a checkpoint id: {s}", .{a});
            } else return c.usageError("restore: unexpected {s}", .{a});
        }
        const cp_id = id orelse return c.usageError("restore needs a checkpoint id", .{});
        var ws: Ws = undefined;
        if (!try c.openWs(&ws)) return c.noStore();
        defer ws.close();
        if (ws.cps.get(cp_id) == null) return c.fail(.not_found, "no checkpoint {d}", .{cp_id});
        const rep = ws.cps.restoreTo(c.arena, cp_id, .{ .dry_run = dry, .scope = scope }) catch |e| return c.fail(.store, "restore {d}: {t}", .{ cp_id, e });
        if (!dry) ws.flush() catch |e| return c.fail(.store, "the restore was written but could not be recorded: {t}", .{e});
        for (rep.conflicts) |cf| try c.err.print("conflict: {s} ({t})\n", .{ cf.path, cf.kind });
        if (rep.failed) |f| {
            if (f.rolled_back) return c.fail(.store, "restore {s}: {t}; nothing was changed", .{ f.path, f.err });
            return c.fail(.partial, "restore {s}: {t}; some files were written", .{ f.path, f.err });
        }
        if (rep.conflicts.len > 0) return c.fail(.conflict, "{d} file{s} changed since on the same lines; nothing was restored", .{ rep.conflicts.len, if (rep.conflicts.len == 1) "" else "s" });
        const verb = if (dry) "Would restore" else "Restored";
        try c.out.print("{s} {d} file{s} to checkpoint {d}.\n", .{ verb, rep.restored.len, if (rep.restored.len == 1) "" else "s", cp_id });
        for (rep.restored) |p| try c.out.print("  {s}\n", .{p});
        if (rep.discarded.len > 0) {
            try c.out.print("{s} {d} changeset{s} made after it:", .{ if (dry) "Would discard" else "Discarded", rep.discarded.len, if (rep.discarded.len == 1) "" else "s" });
            for (rep.discarded) |d| try c.out.print(" {f}", .{d});
            try c.out.writeByte('\n');
        }
        return .ok;
    }

    // --------------------------------------------------------- debug-dump

    fn debugDump(c: *Cmd, args: []const []const u8) !Exit {
        var from: u64 = 0;
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (eql(a, "--from")) {
                const v = value(args, &i) orelse return c.usageError("--from needs a record number", .{});
                from = std.fmt.parseInt(u64, v, 10) catch return c.usageError("not a record number: {s}", .{v});
            } else return c.usageError("debug-dump: unexpected {s}", .{a});
        }
        c.dir.access(c.io, store_path, .{}) catch |e| switch (e) {
            error.FileNotFound => return c.noStore(),
            else => return e,
        };
        const store = try zg_review.store.ChangesetStore.open(c.gpa, c.io, c.dir, store_path, .{});
        defer store.close();
        const Dump = struct {
            w: *Writer,
            from: u64,
            n: u64 = 0,
            fn on(ctx: *anyopaque, kind: zg_review.store.journal.Kind, rec: std.json.Value) anyerror!void {
                const d: *@This() = @ptrCast(@alignCast(ctx));
                defer d.n += 1;
                if (d.n < d.from) return;
                var s: std.json.Stringify = .{ .writer = d.w };
                try s.beginObject();
                try s.objectField("seq");
                try s.write(d.n);
                try s.objectField("kind");
                try s.write(std.enums.tagName(zg_review.store.journal.Kind, kind) orelse "unknown");
                try s.objectField("record");
                try s.write(rec);
                try s.endObject();
                try d.w.writeByte('\n');
            }
        };
        var d: Dump = .{ .w = c.out, .from = from };
        _ = try store.load(.{ .ctx = &d, .on = Dump.on });
        return .ok;
    }
};

// ---------------------------------------------------------------- helpers

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn isHelp(a: []const u8) bool {
    return eql(a, "--help") or eql(a, "-h") or eql(a, "help");
}

/// The argument after `args[i.*]`, advancing `i`.
fn value(args: []const []const u8, i: *usize) ?[]const u8 {
    if (i.* + 1 >= args.len) return null;
    i.* += 1;
    return args[i.*];
}

/// "3" or "#3".
pub fn parseId(s: []const u8) ?ChangesetId {
    const digits = if (std.mem.startsWith(u8, s, "#")) s[1..] else s;
    const n = std.fmt.parseInt(u64, digits, 10) catch return null;
    return if (n == 0) null else @enumFromInt(n);
}

/// Whether `want` (a session id or a prefix of one, any case) names the
/// session of `ref`.
fn sessionMatches(ref: ?zg_ai.proto.AgentRef, want: []const u8) bool {
    const r = ref orelse return false;
    const id = ulid.format(r.session);
    return want.len <= id.len and std.ascii.startsWithIgnoreCase(&id, want);
}

fn isOpen(s: model.FileState) bool {
    return s == .pending or s == .partially_applied;
}

fn isConflict(e: anyerror) bool {
    return e == error.BaseMoved or e == error.TargetExists or e == error.SourceMissing;
}
