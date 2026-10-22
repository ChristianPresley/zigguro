//! `zg agent --review` (E12.F03.S05.T01): agent edits go through the
//! IDE's `ReviewGlue`, so each turn's changes become one pending
//! changeset in the workspace's review store instead of landing on disk.
//!
//! - `defer` (the default): the changesets stay pending; their ids are
//!   printed at the end of the run for `zg review`.
//! - `interactive` (a terminal on stdin and stderr): at the end of the
//!   run each pending changeset is offered for accept, reject, view or
//!   skip. `v` pipes the patch through `$PAGER` when it is set.
//! - `apply`: edits land at once and are recorded as auto-applied
//!   changesets, as in the IDE without review mode.
//!
//! The agent reads its own pending changes back (the glue's agent view).
//! `policy` waits for review policies in the glue; the `review` events of
//! `zg.stream/1` come later.

const std = @import("std");
const zg_ai = @import("zg_ai");
const zg_review = @import("zg_review");
const ReviewGlue = @import("zg_review_glue").ReviewGlue;
const render = @import("review_render.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const model = zg_review.model;

pub const Mode = enum { @"defer", interactive, apply };

pub const help =
    \\
    \\Review:
    \\  --review defer|interactive|apply
    \\        defer (default): each turn's edits wait in the workspace's
    \\        review queue (`zg review list`); interactive: ask about each
    \\        one when the run ends; apply: write them at once
    \\
;

/// `argv` without `--review MODE` (or `--review=MODE`), and the mode.
pub const Parsed = struct { mode: Mode, rest: []const [:0]const u8 };

pub fn parseFlag(arena: Allocator, argv: []const [:0]const u8) error{ Usage, OutOfMemory }!Parsed {
    var mode: Mode = .@"defer";
    var rest: std.ArrayList([:0]const u8) = .empty;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        const v: []const u8 = if (std.mem.eql(u8, a, "--review")) blk: {
            i += 1;
            if (i >= argv.len) return error.Usage;
            break :blk argv[i];
        } else if (std.mem.startsWith(u8, a, "--review=")) a["--review=".len..] else {
            try rest.append(arena, a);
            continue;
        };
        mode = std.meta.stringToEnum(Mode, v) orelse return error.Usage;
    }
    return .{ .mode = mode, .rest = rest.items };
}

/// The glue for one `zg agent` run.
pub const Review = struct {
    glue: *ReviewGlue,
    mode: Mode,
    /// Changesets with this id or larger came from this run.
    first: u64,

    pub fn init(gpa: Allocator, io: Io, cwd: []const u8, mode: Mode) !Review {
        const g = try ReviewGlue.create(gpa, io, cwd, .{ .persist = true });
        g.mode = if (mode == .apply) .auto_apply else .review;
        return .{ .glue = g, .mode = mode, .first = g.q.next_id.load(.monotonic) };
    }

    pub fn deinit(r: *Review) void {
        r.glue.destroy();
    }

    /// The pending changesets this run made.
    fn pending(r: *Review, arena: Allocator) ![]const model.ChangesetId {
        var out: std.ArrayList(model.ChangesetId) = .empty;
        for (r.glue.q.changesets.values()) |cs| {
            if (@intFromEnum(cs.id) < r.first) continue;
            if (cs.state == .pending or cs.state == .partially_applied) try out.append(arena, cs.id);
        }
        return out.items;
    }

    /// After the run: lists what waits for review, or asks about each
    /// changeset when `interactive` and `in` (a terminal) is given.
    pub fn finish(r: *Review, io: Io, environ: *const std.process.Environ.Map, err: *Io.Writer, in: ?*Io.Reader, style: render.Style) !void {
        var arena_state: std.heap.ArenaAllocator = .init(r.glue.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const g = r.glue;
        g.mutex.lockUncancelable(io);
        defer g.mutex.unlock(io);
        const ids = try r.pending(arena);
        if (ids.len == 0) return;
        if (r.mode == .interactive) if (in) |reader| return r.ask(arena, io, environ, ids, err, reader, style);
        try err.print("zg agent: {d} changeset{s} wait{s} for review:", .{ ids.len, if (ids.len == 1) "" else "s", if (ids.len == 1) "s" else "" });
        for (ids) |id| try err.print(" {f}", .{id});
        try err.writeAll(" (zg review show ID --patch; zg review accept ID --all)\n");
        try err.flush();
    }

    fn ask(r: *Review, arena: Allocator, io: Io, environ: *const std.process.Environ.Map, ids: []const model.ChangesetId, err: *Io.Writer, in: *Io.Reader, style: render.Style) !void {
        const g = r.glue;
        for (ids) |id| {
            while (true) {
                const cs = g.q.get(id) orelse break;
                try err.writeByte('\n');
                try render.writeSummary(err, style, cs);
                try err.writeAll("[a]ccept, [r]eject, [v]iew, [s]kip? ");
                try err.flush();
                const line = (in.takeDelimiter('\n') catch return) orelse return;
                const ans = std.mem.trim(u8, line, " \t\r");
                const act: ?ReviewGlue.Action = if (ans.len == 0) null else switch (std.ascii.toLower(ans[0])) {
                    'a' => .accept,
                    'r' => .reject,
                    'v' => {
                        try r.view(arena, io, environ, cs, err, style);
                        continue;
                    },
                    's' => break,
                    else => null,
                };
                const a = act orelse continue;
                switch (try g.actLocked(arena, id, a)) {
                    .ok => try err.print("{f} {s}.\n", .{ id, @tagName(g.q.get(id).?.state) }),
                    .refused => |x| try err.print("{f} not {s}: {s}{s}{s}.\n", .{ id, if (a == .accept) "accepted" else "rejected", x.path, if (x.path.len > 0) " " else "", x.reason }),
                    .failed => |x| try err.print("{f}: {s}: {t}.\n", .{ id, x.path, x.err }),
                }
                break;
            }
        }
        try err.flush();
    }

    /// The patch, through `$PAGER` when set.
    fn view(r: *Review, arena: Allocator, io: Io, environ: *const std.process.Environ.Map, cs: *const model.Changeset, err: *Io.Writer, style: render.Style) !void {
        var aw: Io.Writer.Allocating = .init(arena);
        for (cs.files) |*f| try render.writePatch(&aw.writer, arena, style, r.glue.q.blobs, f);
        const pager = environ.get("PAGER") orelse "";
        if (pager.len > 0) paged: {
            var child = std.process.spawn(io, .{ .argv = &.{pager}, .stdin = .pipe }) catch break :paged;
            child.stdin.?.writeStreamingAll(io, aw.written()) catch {};
            child.stdin.?.close(io);
            child.stdin = null;
            _ = child.wait(io) catch {};
            return;
        }
        try err.writeAll(aw.written());
    }
};

test "review hooks: --review is taken out of the agent's flags" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const p = try parseFlag(a, &.{ "-p", "hi", "--review", "interactive", "--bare" });
    try std.testing.expectEqual(Mode.interactive, p.mode);
    try std.testing.expectEqual(@as(usize, 3), p.rest.len);
    try std.testing.expectEqualStrings("--bare", p.rest[2]);
    try std.testing.expectEqual(Mode.apply, (try parseFlag(a, &.{"--review=apply"})).mode);
    try std.testing.expectEqual(Mode.@"defer", (try parseFlag(a, &.{"-p"})).mode);
    try std.testing.expectError(error.Usage, parseFlag(a, &.{"--review"}));
    try std.testing.expectError(error.Usage, parseFlag(a, &.{ "--review", "policy" }));
}

test "review hooks: a held turn is listed, then accepted interactively" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one\n" });
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var r: Review = try .init(gpa, io, root, .interactive);
    defer r.deinit();
    const fs = r.glue.files();
    const agent: zg_ai.proto.AgentRef = .{ .session = 7 };
    const abs = (try fs.resolve(io, arena, "a.txt")).abs;
    _ = try fs.propose(io, arena, abs, .{ .str_replace = .{ .old = "one", .new = "ONE" } }, .{ .agent = agent, .turn = 1, .tool = "edit_file", .tool_call_id = "t" });
    _ = try fs.endTurn(io, agent, 1);
    try std.testing.expectEqualStrings("one\n", try tmp.dir.readFileAlloc(io, "a.txt", arena, .limited(64)));

    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    var err: Io.Writer.Allocating = .init(gpa);
    defer err.deinit();
    // No terminal: listed.
    try r.finish(io, &env, &err.writer, null, .{});
    try std.testing.expect(std.mem.endsWith(u8, err.written(), "zg agent: 1 changeset waits for review: #1 (zg review show ID --patch; zg review accept ID --all)\n"));
    // View (printed: no PAGER), then accept.
    err.clearRetainingCapacity();
    var in: Io.Reader = .fixed("v\na\n");
    try r.finish(io, &env, &err.writer, &in, .{});
    try std.testing.expect(std.mem.indexOf(u8, err.written(), "+ONE\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, err.written(), "#1 applied.\n"));
    try std.testing.expectEqualStrings("ONE\n", try tmp.dir.readFileAlloc(io, "a.txt", arena, .limited(64)));
}
