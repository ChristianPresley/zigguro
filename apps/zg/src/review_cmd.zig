//! `zg review` (E12.F03.S05.T01): the review queue of the workspace in
//! the current directory, from the terminal. It opens the same store
//! as the IDE (`.zigguro/review/`), folds it and decides through the
//! same `Applier`, so both can work on one workspace at once: each
//! writes its records to the journal and reads the other's.
//!
//! Approvals (`approvals`, `approve`, `deny`) are the requests another
//! process (the IDE) waits on: an answer is appended to the store, and
//! that process takes it when it next reads the journal (the IDE: within
//! a second).
//!
//! Not here yet: review comments and fix requests (`comment`, `threads`,
//! `fix`) wait for F05.S01;
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
    \\  approvals [--all] [--json]
    \\        the requests waiting for approval (all of them with --all)
    \\  approve AID [--session | --always [RULE] | --edit TEXT]
    \\        allow a request once (default), for the session, always (saving
    \\        RULE, else the suggested rule) or with an edited input
    \\  deny AID [--reason TEXT]
    \\  debug-dump [--from SEQ]
    \\        the store's journal records as NDJSON
    \\  policy explain PATH [--op OP] [--from OLD] [--origin ORIGIN] [--tool NAME]
    \\        [--agent NAME] [--mode MODE] [--lines N]
    \\        what the edit policy (.zigguro/settings.zon `review`) decides for
    \\        a change to PATH, and why
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
    /// Approval requests as recorded (pending ones stay pending).
    approvals: zg_review.approvals.ApprovalBroker,

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
        ws.approvals = .init(gpa, io, .{});
        errdefer ws.approvals.deinit();
        ws.sink.approvals = ws.approvals.mirrorSink();
        _ = try ws.store.load(ws.sink.sink());
    }

    /// Writes what was decided.
    fn flush(ws: *Ws) !void {
        try ws.store.flush();
    }

    fn close(ws: *Ws) void {
        ws.store.close();
        ws.approvals.deinit();
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
        if (eql(sub, "policy")) return c.policyCmd(rest);
        if (eql(sub, "approvals")) return c.approvalsCmd(rest);
        if (eql(sub, "approve")) return c.answerCmd(rest, true);
        if (eql(sub, "deny")) return c.answerCmd(rest, false);
        for ([_][]const u8{ "comment", "threads", "fix" }) |later| if (eql(sub, later)) {
            try c.err.print("zg review {s}: not available yet (review comments arrive with E12.F05.S01)\n", .{sub});
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

    // -------------------------------------------------------- approvals

    fn approvalsCmd(c: *Cmd, args: []const []const u8) !Exit {
        var all = false;
        var json = false;
        for (args) |a| {
            if (eql(a, "--json")) {
                json = true;
            } else if (eql(a, "--all")) {
                all = true;
            } else return c.usageError("approvals: unexpected {s}", .{a});
        }
        var ws: Ws = undefined;
        if (!try c.openWs(&ws)) {
            if (!json) try c.out.writeAll("No approval requests.\n");
            return .ok;
        }
        defer ws.close();
        const items = try ws.approvals.list(c.arena, .{ .answered = all });
        if (json) {
            for (items) |*it| {
                try zg_review.approvals.writeRecord(c.out, it);
                try c.out.writeByte('\n');
            }
            return .ok;
        }
        if (items.len == 0) {
            try c.out.writeAll(if (all) "No approval requests.\n" else "No approval requests waiting.\n");
            return .ok;
        }
        var age_buf: [16]u8 = undefined;
        for (items) |*it| {
            try c.out.print("{f}  {s: <16}  {s: >4}  {f}  {s}", .{ it.id, @tagName(it.state), render.ageText(&age_buf, c.o.style.now_ms, it.req.created_ms), it.req.actor, it.req.title });
            if (it.req.command) |cmd| try c.out.print(": {s}", .{cmd});
            try c.out.writeByte('\n');
            for (it.req.risk) |r| try c.out.print("      ! {s}\n", .{r});
        }
        return .ok;
    }

    /// `approve` (allow) or `deny`: appends the answer for the process
    /// that waits on the request.
    fn answerCmd(c: *Cmd, args: []const []const u8, allow: bool) !Exit {
        const ap = zg_review.approvals;
        var id: ?ap.ApprovalId = null;
        var how: enum { once, session, always, edit } = .once;
        var text: ?[]const u8 = null;
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (allow and eql(a, "--session")) {
                how = .session;
            } else if (allow and eql(a, "--always")) {
                how = .always;
                if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "--")) {
                    i += 1;
                    text = args[i];
                }
            } else if (allow and eql(a, "--edit")) {
                how = .edit;
                text = value(args, &i) orelse return c.usageError("--edit needs the edited input", .{});
            } else if (!allow and eql(a, "--reason")) {
                text = value(args, &i) orelse return c.usageError("--reason needs a text", .{});
            } else if (id == null and !std.mem.startsWith(u8, a, "--")) {
                const digits = if (std.mem.startsWith(u8, a, "!")) a[1..] else a;
                id = @enumFromInt(std.fmt.parseInt(u64, digits, 10) catch return c.usageError("not an approval id: {s}", .{a}));
            } else return c.usageError("{s}: unexpected {s}", .{ if (allow) "approve" else "deny", a });
        }
        const aid = id orelse return c.usageError("{s} needs an approval id (see `zg review approvals`)", .{if (allow) "approve" else "deny"});
        var ws: Ws = undefined;
        if (!try c.openWs(&ws)) return c.noStore();
        defer ws.close();
        var it = ws.approvals.get(aid) orelse return c.fail(.not_found, "no approval request {f}", .{aid});
        if (it.state != .pending) return c.fail(.conflict, "{f} is already {s}", .{ aid, @tagName(it.state) });
        const r = &it.req;
        const answer: zg_review.approvals.Answer = if (!allow) .{ .deny = text orelse "denied from the CLI" } else switch (how) {
            .once => .allow_once,
            .session => .{ .allow_session = r.rule_suggestion orelse r.command orelse r.title },
            .always => .{ .allow_always = text orelse r.rule_suggestion orelse return c.usageError("{f} has no suggested rule: give one after --always", .{aid}) },
            .edit => blk: {
                if (!r.editable) return c.fail(.conflict, "{f} cannot be edited", .{aid});
                if (r.command == null and !(std.json.validate(c.arena, text.?) catch false)) return c.usageError("the edited input must be JSON", .{});
                break :blk .{ .edit = text.? };
            },
        };
        it.state = .of(answer);
        it.answer = answer;
        it.answered_by = "cli";
        it.answered_ms = Io.Clock.real.now(c.io).toMilliseconds();
        var aw: Writer.Allocating = .init(c.arena);
        try zg_review.approvals.writeRecord(&aw.writer, &it);
        try ws.store.append(.approval, aw.written());
        try ws.flush();
        try c.out.print("{f} {s}.\n", .{ aid, it.state.label() });
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

    // ------------------------------------------------------ policy explain

    fn policyCmd(c: *Cmd, args: []const []const u8) !Exit {
        if (args.len == 0 or !eql(args[0], "explain")) return c.usageError("policy: the command is `policy explain PATH`", .{});
        const pol = zg_review.policy;
        var subject: pol.rules.Subject = .{ .path = "", .op = .modify, .origin = .agent, .changed_lines = null };
        var mode: pol.policy.Mode = .default;
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (eql(a, "--op")) {
                const v = value(args, &i) orelse return c.usageError("--op needs create, modify, delete, rename or mode", .{});
                subject.op = std.meta.stringToEnum(pol.rules.Op, v) orelse return c.usageError("--op is create, modify, delete, rename or mode, not {s}", .{v});
            } else if (eql(a, "--from")) {
                subject.from = value(args, &i) orelse return c.usageError("--from needs the old path", .{});
            } else if (eql(a, "--origin")) {
                const v = value(args, &i) orelse return c.usageError("--origin needs an origin", .{});
                subject.origin = std.meta.stringToEnum(pol.rules.OriginKind, v) orelse return c.usageError("unknown origin {s}", .{v});
            } else if (eql(a, "--tool")) {
                subject.tool = value(args, &i) orelse return c.usageError("--tool needs a name", .{});
            } else if (eql(a, "--agent")) {
                subject.agent = value(args, &i) orelse return c.usageError("--agent needs a name", .{});
            } else if (eql(a, "--mode")) {
                const v = value(args, &i) orelse return c.usageError("--mode needs a permission mode", .{});
                mode = std.meta.stringToEnum(pol.policy.Mode, v) orelse return c.usageError("--mode is default, accept_edits, plan, dont_ask or bypass, not {s}", .{v});
            } else if (eql(a, "--lines")) {
                const v = value(args, &i) orelse return c.usageError("--lines needs a number", .{});
                subject.changed_lines = std.fmt.parseInt(u32, v, 10) catch return c.usageError("not a line count: {s}", .{v});
            } else if (subject.path.len == 0 and !std.mem.startsWith(u8, a, "--")) {
                subject.path = a;
            } else return c.usageError("policy explain: unexpected {s}", .{a});
        }
        if (subject.path.len == 0) return c.usageError("policy explain needs a path", .{});
        if (subject.op == .rename and subject.from == null) return c.usageError("--op rename needs --from OLD", .{});

        var diags: std.ArrayList(pol.rules.Diagnostic) = .empty;
        const settings = try pol.rules.loadWorkspace(c.arena, c.io, c.dir, &diags);
        const p = try pol.ReviewPolicy.init(c.gpa, settings);
        defer p.deinit();
        for (diags.items) |d| try c.err.print("warning: {s}\n", .{d.message});
        for (p.diagnostics) |d| if (d.rule) |r| try c.err.print("warning: rule {d} ignored: {s}\n", .{ r, d.message }) else try c.err.print("warning: {s}\n", .{d.message});

        const Probe = struct {
            mode: pol.policy.Mode,
            fn probe(_: *anyopaque, _: ?u128, _: []const u8, _: pol.rules.Op) pol.policy.ProbeResult {
                return .{ .kind = .ask, .layer = .default };
            }
            fn modeOf(ctx: *anyopaque, _: ?u128) pol.policy.Mode {
                const self: *@This() = @ptrCast(@alignCast(ctx));
                return self.mode;
            }
        };
        var probe: Probe = .{ .mode = mode };
        const v = p.decide(.{ .origin = subject.origin, .tool = subject.tool, .agent_name = subject.agent, .security = .{ .ctx = &probe, .probe = Probe.probe, .mode = Probe.modeOf } }, subject);
        try c.out.print("{s}: {s}\n", .{ subject.path, switch (v.action) {
            .auto_apply => "auto-apply",
            .review => "review",
            .deny => "deny",
        } });
        try c.out.print("  step: {s} ({s})\n", .{ @tagName(v.step), v.reason });
        if (v.rule) |r| if (r < settings.rules.len) {
            const rc = settings.rules[r];
            try c.out.print("  rule {d}: action {s}, paths", .{ r, @tagName(rc.action) });
            for (rc.paths) |g| try c.out.print(" {s}", .{g});
            if (rc.tools.len > 0) {
                try c.out.writeAll(", tools");
                for (rc.tools) |t| try c.out.print(" {s}", .{t});
            }
            if (rc.agents.len > 0) {
                try c.out.writeAll(", agents");
                for (rc.agents) |t| try c.out.print(" {s}", .{t});
            }
            if (rc.origins.len > 0) {
                try c.out.writeAll(", origins");
                for (rc.origins) |o| try c.out.print(" {s}", .{@tagName(o)});
            }
            if (rc.ops.len > 0) {
                try c.out.writeAll(", ops");
                for (rc.ops) |o| try c.out.print(" {s}", .{@tagName(o)});
            }
            if (rc.max_changed_lines) |m| try c.out.print(", at most {d} changed lines", .{m});
            try c.out.writeByte('\n');
        };
        try c.out.print("  ({d} rule{s} in {s}; E16 permissions are not consulted here)\n", .{ settings.rules.len, if (settings.rules.len == 1) "" else "s", pol.rules.workspace_settings });
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
