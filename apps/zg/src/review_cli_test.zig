//! `zg review` against a store written the way the IDE writes it
//! (E12.F03.S05.T01).

const std = @import("std");
const zg_review = @import("zg_review");
const review_cmd = @import("review_cmd.zig");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;
const model = zg_review.model;

const session: u128 = 0x0192_5a3c_1d2e_0000_0000_0000_0000_0001;
const hour = std.time.ms_per_hour;
const now_ms: i64 = 100 * hour;

/// A workspace with a store: what an IDE process left behind.
const Fx = struct {
    tmp: testing.TmpDir,
    out: std.Io.Writer.Allocating,
    err: std.Io.Writer.Allocating,

    fn init(fx: *Fx) void {
        fx.* = .{ .tmp = testing.tmpDir(.{}), .out = .init(gpa), .err = .init(gpa) };
    }

    fn deinit(fx: *Fx) void {
        fx.out.deinit();
        fx.err.deinit();
        fx.tmp.cleanup();
    }

    fn write(fx: *Fx, path: []const u8, bytes: []const u8) !void {
        try fx.tmp.dir.writeFile(io, .{ .sub_path = path, .data = bytes });
    }

    fn read(fx: *Fx, path: []const u8) ![]u8 {
        return fx.tmp.dir.readFileAlloc(io, path, gpa, .unlimited);
    }

    /// The IDE's side: opens the store, lets `f` submit, closes.
    fn ide(fx: *Fx, ctx: anytype, comptime f: fn (@TypeOf(ctx), *Ide) anyerror!void) !void {
        var p: Ide = undefined;
        try p.open(fx.tmp.dir);
        defer p.close();
        try f(ctx, &p);
    }

    /// Runs `zg review ARGS`; the exit code.
    fn run(fx: *Fx, args: []const []const u8) !u8 {
        fx.out.clearRetainingCapacity();
        fx.err.clearRetainingCapacity();
        return review_cmd.runIn(gpa, io, fx.tmp.dir, "/w", args, &fx.out.writer, &fx.err.writer, .{ .style = .{ .now_ms = now_ms } });
    }

    fn runStyled(fx: *Fx, args: []const []const u8, o: review_cmd.Options) !u8 {
        fx.out.clearRetainingCapacity();
        fx.err.clearRetainingCapacity();
        return review_cmd.runIn(gpa, io, fx.tmp.dir, "/w", args, &fx.out.writer, &fx.err.writer, o);
    }
};

const Ide = struct {
    store: *zg_review.store.ChangesetStore,
    q: *model.Queue,
    history: model.History,
    disk: zg_review.apply.DirFiles,
    cps: zg_review.checkpoint.Checkpoints,
    sink: zg_review.store.store.QueueSink,
    dir: std.Io.Dir,

    fn open(p: *Ide, dir: std.Io.Dir) !void {
        p.dir = dir;
        p.store = try .open(gpa, io, dir, review_cmd.store_path, .{ .process_tag = 77 });
        p.q = try model.Queue.init(gpa, io, .{ .root = "/w", .blobs = p.store.blobs(), .journal = p.store.journalPort() });
        p.history = .init(gpa, p.store.recorder());
        p.disk = .{ .dir = dir, .io = io };
        p.cps = .init(gpa, io, p.q, &p.history, p.disk.files(), p.store.checkpointRecorder());
        p.sink = p.store.queueSink(p.q, &p.history, p.cps.sink());
        _ = try p.store.load(p.sink.sink());
    }

    fn close(p: *Ide) void {
        p.store.close();
        p.cps.deinit();
        p.q.deinit();
        p.history.deinit();
    }

    /// A pending agent changeset editing `path` from `base` to `new`.
    fn edit(p: *Ide, turn: u32, label: []const u8, created_ms: i64, files: []const [3][]const u8) !model.ChangesetId {
        const b = try p.q.beginBatch(.{
            .origin = .{ .agent = .{ .ref = .{ .session = session, .agent = 0 }, .turn = turn, .model = "m" } },
            .label = label,
            .workspace = "/w",
            .created_ms = created_ms,
        });
        for (files) |f| {
            var e = try model.merge3.lineChangeSet(gpa, f[1], f[2]);
            defer e.deinit();
            try p.q.addEdit(b, f[0], f[1], null, &e);
        }
        const id = try p.q.commitBatch(b, .{});
        p.q.getMut(id).?.created_ms = created_ms;
        p.q.persist(id);
        return id;
    }
};

const parse_base = "fn a() void {}\nfn b() void {}\nfn c() void {}\nfn d() void {}\nfn e() void {}\nfn f() void {}\nfn g() void {}\nfn h() void {}\nfn i() void {}\nfn j() void {}\n";
const parse_new = "fn a() u8 {}\nfn b() void {}\nfn c() void {}\nfn d() void {}\nfn e() void {}\nfn f() void {}\nfn g() void {}\nfn h() void {}\nfn i() void {}\nfn j() void {}\nfn k() void {}\n";

/// Two pending changesets and an applied one.
fn seed(fx: *Fx) !void {
    try fx.write("parse.zig", parse_base);
    try fx.write("README.md", "# demo\n");
    try fx.ide({}, struct {
        fn f(_: void, p: *Ide) !void {
            _ = try p.edit(1, "Turn 1: parser", now_ms - 2 * hour, &.{.{ "parse.zig", parse_base, parse_new }});
            _ = try p.edit(2, "Turn 2: readme", now_ms - 5 * std.time.ms_per_min, &.{.{ "README.md", "# demo\n", "# demo\n\nUsage.\n" }});
            const id = try p.edit(3, "Turn 3: done", now_ms - 3 * std.time.ms_per_day, &.{.{ "notes.txt", "", "x\n" }});
            const cs = p.q.getMut(id).?;
            try model.transition(cs, .applied);
            p.q.persist(id);
        }
    }.f);
}

test "review_cli: list/show golden (plain, json, color)" {
    var fx: Fx = undefined;
    fx.init();
    defer fx.deinit();
    try seed(&fx);

    try testing.expectEqual(@as(u8, 0), try fx.run(&.{"list"}));
    try testing.expectEqualStrings(
        \\ID     STATE             FILES +/-          AGE  ORIGIN           LABEL
        \\#1     pending               1 +2 -1         2h  agent 01J9D3     Turn 1: parser
        \\#2     pending               1 +2 -0         5m  agent 01J9D3     Turn 2: readme
        \\
    , fx.out.written());

    try testing.expectEqual(@as(u8, 0), try fx.run(&.{ "list", "--state", "all", "--json" }));
    try testing.expectEqualStrings(
        \\{"type":"changeset","id":1,"state":"pending","label":"Turn 1: parser","origin":"agent","session":"01J9D3R79E0000000000000001","agent":0,"turn":1,"rationale":null,"created_ms":352800000,"decided_ms":null,"auto_applied":false,"checkpoint":null,"files":1,"added":2,"removed":1,"hunks":2}
        \\
    , fx.out.written()[0 .. std.mem.indexOfScalar(u8, fx.out.written(), '\n').? + 1]);
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, fx.out.written(), "\n"));

    try testing.expectEqual(@as(u8, 0), try fx.run(&.{ "show", "#1", "--patch" }));
    try testing.expectEqualStrings(
        \\#1 Turn 1: parser  pending
        \\origin: agent, session 01J9D3R79E0000000000000001, turn 1, model m
        \\created 2h ago; 1 file, +2 -1, 2 hunks open
        \\  M parse.zig  pending  +2 -1, 2 hunks
        \\
        \\--- a/parse.zig
        \\+++ b/parse.zig
        \\@@ -1,4 +1,4 @@ hunk 1 [pending]
        \\-fn a() void {}
        \\+fn a() u8 {}
        \\ fn b() void {}
        \\ fn c() void {}
        \\ fn d() void {}
        \\@@ -8,3 +8,4 @@ hunk 2 [pending]
        \\ fn h() void {}
        \\ fn i() void {}
        \\ fn j() void {}
        \\+fn k() void {}
        \\
    , fx.out.written());

    try testing.expectEqual(@as(u8, 0), try fx.run(&.{ "show", "2", "--json", "--patch" }));
    var lines = std.mem.splitScalar(u8, fx.out.written(), '\n');
    try testing.expect(std.mem.startsWith(u8, lines.next().?, "{\"type\":\"changeset\",\"id\":2,"));
    try testing.expectEqualStrings(
        \\{"type":"file","changeset":2,"path":"README.md","op":"modify","from":null,"state":"pending","binary":false,"added":2,"removed":0,"hunks":1}
    , lines.next().?);
    try testing.expectEqualStrings(
        \\{"type":"hunk","changeset":2,"path":"README.md","hunk":1,"state":"pending","base_start":2,"base_count":0,"new_start":2,"new_count":2,"conflict":null,"removed_lines":[],"added_lines":["","Usage."]}
    , lines.next().?);

    try testing.expectEqual(@as(u8, 0), try fx.runStyled(&.{ "show", "2", "--patch" }, .{ .style = .{ .color = true, .now_ms = now_ms } }));
    try testing.expect(std.mem.indexOf(u8, fx.out.written(), "\x1b[32m+Usage.\x1b[0m\n") != null);
    try testing.expect(std.mem.indexOf(u8, fx.out.written(), "\x1b[36m@@ -1,1 +1,3 @@\x1b[0m hunk 1 [pending]\n") != null);

    // Tables are cut to the terminal's width.
    try testing.expectEqual(@as(u8, 0), try fx.runStyled(&.{"list"}, .{ .style = .{ .width = 40, .now_ms = now_ms } }));
    var it = std.mem.splitScalar(u8, fx.out.written(), '\n');
    while (it.next()) |l| try testing.expect(l.len <= 40);
}

test "review_cli: accept hunk selectors parse and apply" {
    var fx: Fx = undefined;
    fx.init();
    defer fx.deinit();
    try seed(&fx);

    // Hunk 2 only: k is added, a stays.
    try testing.expectEqual(@as(u8, 0), try fx.run(&.{ "accept", "1", "--hunk", "parse.zig:2" }));
    try testing.expectEqualStrings("Accepted 1 hunk in 1 file of #1; it is partially_applied now.\n", fx.out.written());
    {
        const got = try fx.read("parse.zig");
        defer gpa.free(got);
        try testing.expect(std.mem.startsWith(u8, got, "fn a() void {}\n"));
        try testing.expect(std.mem.endsWith(u8, got, "fn k() void {}\n"));
    }
    // What is left is renumbered: one hunk, which the next process sees.
    try testing.expectEqual(@as(u8, 4), try fx.run(&.{ "accept", "1", "--hunk", "parse.zig:2" }));
    try testing.expectEqualStrings("zg review: parse.zig has 1 open hunk, not 2\n", fx.err.written());
    try testing.expectEqual(@as(u8, 0), try fx.run(&.{ "reject", "1", "--hunk", "parse.zig:*" }));
    try testing.expectEqualStrings("Rejected 1 hunk in 1 file of #1; it is applied now.\n", fx.out.written());
    {
        const got = try fx.read("parse.zig");
        defer gpa.free(got);
        try testing.expect(std.mem.startsWith(u8, got, "fn a() void {}\n"));
    }

    // Whole changeset, then it is closed.
    try testing.expectEqual(@as(u8, 0), try fx.run(&.{ "accept", "#2", "--all", "--yes" }));
    {
        const got = try fx.read("README.md");
        defer gpa.free(got);
        try testing.expectEqualStrings("# demo\n\nUsage.\n", got);
    }
    try testing.expectEqual(@as(u8, 0), try fx.run(&.{"list"}));
    try testing.expectEqualStrings("No changesets.\n", fx.out.written());

    // The IDE folds the CLI's decisions.
    try fx.ide({}, struct {
        fn f(_: void, p: *Ide) !void {
            try testing.expectEqual(model.State.applied, p.q.get(@enumFromInt(1)).?.state);
            try testing.expectEqual(model.State.applied, p.q.get(@enumFromInt(2)).?.state);
            try testing.expect(p.history.items().len >= 2);
        }
    }.f);
}

test "review_cli: exit codes table" {
    var fx: Fx = undefined;
    fx.init();
    defer fx.deinit();

    const Case = struct { args: []const []const u8, code: u8 };
    // No store yet.
    for ([_]Case{
        .{ .args = &.{"list"}, .code = 0 },
        .{ .args = &.{"checkpoints"}, .code = 0 },
        .{ .args = &.{ "show", "1" }, .code = 4 },
        .{ .args = &.{ "accept", "1", "--all" }, .code = 4 },
        .{ .args = &.{"debug-dump"}, .code = 4 },
    }) |c| try testing.expectEqual(c.code, try fx.run(c.args));
    // Nothing was created by reading.
    try testing.expectError(error.FileNotFound, fx.tmp.dir.access(io, ".zigguro", .{}));

    try seed(&fx);
    for ([_]Case{
        .{ .args = &.{}, .code = 1 },
        .{ .args = &.{"--help"}, .code = 0 },
        .{ .args = &.{ "accept", "--help" }, .code = 0 },
        .{ .args = &.{"frobnicate"}, .code = 1 },
        .{ .args = &.{ "show", "x" }, .code = 1 },
        .{ .args = &.{ "list", "--state", "maybe" }, .code = 1 },
        .{ .args = &.{ "accept", "1" }, .code = 1 },
        .{ .args = &.{ "accept", "1", "--all", "--file", "parse.zig" }, .code = 1 },
        .{ .args = &.{ "accept", "1", "--hunk", "parse.zig" }, .code = 1 },
        .{ .args = &.{ "accept", "1", "--hunk", "parse.zig:0" }, .code = 1 },
        .{ .args = &.{ "comment", "1", "parse.zig:3", "why?" }, .code = 1 },
        .{ .args = &.{ "show", "9" }, .code = 4 },
        .{ .args = &.{ "show", "1", "--file", "nope.zig" }, .code = 4 },
        .{ .args = &.{ "accept", "1", "--file", "nope.zig" }, .code = 4 },
        .{ .args = &.{ "accept", "1", "--hunk", "parse.zig:3" }, .code = 4 },
        .{ .args = &.{ "restore", "42" }, .code = 4 },
        // Applied already.
        .{ .args = &.{ "accept", "3", "--all" }, .code = 3 },
        .{ .args = &.{ "show", "1" }, .code = 0 },
    }) |c| {
        const got = try fx.run(c.args);
        if (got != c.code) std.debug.print("zg review {s}: exit {d}, want {d}\n{s}", .{ if (c.args.len > 0) c.args[0] else "", got, c.code, fx.err.written() });
        try testing.expectEqual(c.code, got);
    }

    // The base moved: someone edited README.md since the agent read it.
    try fx.write("README.md", "# demo (edited)\n");
    try testing.expectEqual(@as(u8, 3), try fx.run(&.{ "accept", "2", "--all" }));
    try testing.expect(std.mem.indexOf(u8, fx.err.written(), "base moved") != null);
    const kept = try fx.read("README.md");
    defer gpa.free(kept);
    try testing.expectEqualStrings("# demo (edited)\n", kept);
}

test "review_cli: confirmation before deciding a whole changeset" {
    var fx: Fx = undefined;
    fx.init();
    defer fx.deinit();
    try seed(&fx);
    var no: std.Io.Reader = .fixed("n\n");
    try testing.expectEqual(@as(u8, 0), try fx.runStyled(&.{ "reject", "2", "--all" }, .{ .style = .{ .now_ms = now_ms }, .confirm = &no }));
    try testing.expectEqualStrings("Reject all of #2 (1 file, +2 -0)? [y/N] Nothing changed.\n", fx.out.written());
    var yes: std.Io.Reader = .fixed("y\n");
    try testing.expectEqual(@as(u8, 0), try fx.runStyled(&.{ "reject", "2", "--all" }, .{ .style = .{ .now_ms = now_ms }, .confirm = &yes }));
    try testing.expect(std.mem.endsWith(u8, fx.out.written(), "it is rejected now.\n"));
    const kept = try fx.read("README.md");
    defer gpa.free(kept);
    try testing.expectEqualStrings("# demo\n", kept);
}

test "review_cli: checkpoints, restore and debug-dump" {
    var fx: Fx = undefined;
    fx.init();
    defer fx.deinit();
    try fx.write("parse.zig", parse_base);
    try fx.ide({}, struct {
        fn f(_: void, p: *Ide) !void {
            _ = p.cps.create(.{ .session = session }, 1, "Turn 1: parser");
            _ = try p.edit(1, "Turn 1: parser", now_ms - hour, &.{.{ "parse.zig", parse_base, parse_new }});
        }
    }.f);
    try testing.expectEqual(@as(u8, 0), try fx.run(&.{ "accept", "1", "--all" }));

    try testing.expectEqual(@as(u8, 0), try fx.run(&.{"checkpoints"}));
    try testing.expect(std.mem.startsWith(u8, fx.out.written(), "ID      AGE  SESSION    TURN  LABEL\n1 "));
    try testing.expect(std.mem.endsWith(u8, fx.out.written(), "01J9D3        1  Turn 1: parser\n"));
    try testing.expectEqual(@as(u8, 0), try fx.run(&.{ "checkpoints", "--session", "01j9d3", "--json" }));
    try testing.expect(std.mem.startsWith(u8, fx.out.written(), "{\"type\":\"checkpoint\",\"id\":1,\"session\":\"01J9D3"));
    try testing.expectEqual(@as(u8, 0), try fx.run(&.{ "checkpoints", "--session", "7ZZZ" }));
    try testing.expectEqualStrings("No checkpoints.\n", fx.out.written());

    try testing.expectEqual(@as(u8, 0), try fx.run(&.{ "restore", "1", "--dry-run" }));
    try testing.expectEqualStrings("Would restore 1 file to checkpoint 1.\n  parse.zig\n", fx.out.written());
    {
        const got = try fx.read("parse.zig");
        defer gpa.free(got);
        try testing.expectEqualStrings(parse_new, got);
    }
    try testing.expectEqual(@as(u8, 0), try fx.run(&.{ "restore", "1" }));
    {
        const got = try fx.read("parse.zig");
        defer gpa.free(got);
        try testing.expectEqualStrings(parse_base, got);
    }

    try testing.expectEqual(@as(u8, 0), try fx.run(&.{"debug-dump"}));
    const all = std.mem.count(u8, fx.out.written(), "\n");
    try testing.expect(all >= 4);
    try testing.expect(std.mem.startsWith(u8, fx.out.written(), "{\"seq\":0,\"kind\":"));
    try testing.expectEqual(@as(u8, 0), try fx.run(&.{ "debug-dump", "--from", "2" }));
    try testing.expectEqual(all - 2, std.mem.count(u8, fx.out.written(), "\n"));
    try testing.expect(std.mem.startsWith(u8, fx.out.written(), "{\"seq\":2,"));
}

test "review_cli: runs next to the IDE on one store" {
    var fx: Fx = undefined;
    fx.init();
    defer fx.deinit();
    try fx.write("README.md", "# demo\n");
    var p: Ide = undefined;
    try p.open(fx.tmp.dir);
    defer p.close();
    _ = try p.edit(1, "Turn 1: readme", now_ms, &.{.{ "README.md", "# demo\n", "# demo\n\nUsage.\n" }});
    try p.store.flush();

    // The CLI decides while the IDE still has the store open...
    try testing.expectEqual(@as(u8, 0), try fx.run(&.{ "accept", "1", "--all" }));
    // ...and the IDE picks the decision up from the journal.
    _ = try p.store.tail(p.sink.sink());
    try testing.expectEqual(model.State.applied, p.q.get(@enumFromInt(1)).?.state);
    // The IDE's next changeset gets a new id, which the CLI sees.
    _ = try p.edit(2, "Turn 2: more", now_ms, &.{.{ "README.md", "# demo\n\nUsage.\n", "# demo\n\nUsage.\nMore.\n" }});
    try p.store.flush();
    try testing.expectEqual(@as(u8, 0), try fx.run(&.{ "show", "2" }));
    try testing.expect(std.mem.startsWith(u8, fx.out.written(), "#2 Turn 2: more  pending\n"));
}

test "review_cli: policy explain golden" {
    var fx: Fx = undefined;
    fx.init();
    defer fx.deinit();
    try fx.tmp.dir.createDirPath(io, ".zigguro");
    try fx.write(".zigguro/settings.zon",
        \\.{ .review = .{ .rules = .{
        \\    .{ .paths = .{"**/*.lock"}, .action = .review_required },
        \\    .{ .paths = .{"docs/**"}, .max_changed_lines = 50, .action = .auto_accept },
        \\} } }
    );
    try testing.expectEqual(@as(u8, 0), try fx.run(&.{ "policy", "explain", "docs/a.md", "--lines", "10" }));
    try testing.expectEqualStrings(
        \\docs/a.md: auto-apply
        \\  step: rule (an auto_accept rule matched)
        \\  rule 1: action auto_accept, paths docs/**, at most 50 changed lines
        \\  (2 rules in .zigguro/settings.zon; E16 permissions are not consulted here)
        \\
    , fx.out.written());
    try testing.expectEqual(@as(u8, 0), try fx.run(&.{ "policy", "explain", "docs/a.md" }));
    try testing.expect(std.mem.startsWith(u8, fx.out.written(), "docs/a.md: review\n  step: default"));
    try testing.expectEqual(@as(u8, 0), try fx.run(&.{ "policy", "explain", "build.zig", "--mode", "accept_edits" }));
    try testing.expect(std.mem.startsWith(u8, fx.out.written(), "build.zig: review\n  step: protected_path"));
    try testing.expectEqual(@as(u8, 0), try fx.run(&.{ "policy", "explain", "src/x.zig", "--mode", "plan" }));
    try testing.expect(std.mem.startsWith(u8, fx.out.written(), "src/x.zig: deny\n"));
    try testing.expectEqual(@as(u8, 1), try fx.run(&.{ "policy", "explain", "a", "--op", "rename" }));
    try testing.expectEqual(@as(u8, 1), try fx.run(&.{ "policy", "list" }));
}

test "review_cli: approvals list, approve and deny reach the waiting process" {
    var fx: Fx = undefined;
    fx.init();
    defer fx.deinit();
    try std.testing.expectEqual(@as(u8, 0), try fx.run(&.{"approvals"}));
    try testing.expectEqualStrings("No approval requests.\n", fx.out.written());

    // The IDE asks twice and waits.
    var p: Ide = undefined;
    try p.open(fx.tmp.dir);
    defer p.close();
    var b: zg_review.approvals.ApprovalBroker = .init(gpa, io, .{});
    defer b.deinit();
    b.bind(p.store.approvalRecorder(), 77 << 32);
    p.sink.approvals = b.remoteSink();
    const req: zg_review.approvals.ApprovalRequest = .{
        .kind = .command,
        .actor = .{ .agent = .{ .session = "s1", .agent = "main" } },
        .title = "Run command",
        .detail_json = "{\"command\":\"make\"}",
        .command = "make",
        .risk = &.{"Runs a program on this machine."},
        .rule_suggestion = "run_command(make)",
        .editable = true,
        .created_ms = now_ms - 2 * std.time.ms_per_min,
    };
    const a = try b.present(req);
    var tool = req;
    tool.kind = .mcp_tool;
    tool.title = "Call MCP tool github.create_issue";
    tool.command = null;
    tool.risk = &.{};
    tool.rule_suggestion = null;
    tool.created_ms = now_ms - std.time.ms_per_min;
    const t = try b.present(tool);
    try p.store.flush();

    try testing.expectEqual(@as(u8, 0), try fx.run(&.{"approvals"}));
    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "{f}  pending             2m  agent:s1/main  Run command: make\n      ! Runs a program on this machine.\n", .{a});
    try testing.expect(std.mem.startsWith(u8, fx.out.written(), line));
    try testing.expectEqual(@as(u8, 0), try fx.run(&.{ "approvals", "--json" }));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, fx.out.written(), "\n"));
    try testing.expect(std.mem.indexOf(u8, fx.out.written(), "\"state\":\"pending\"") != null);

    var id_buf: [32]u8 = undefined;
    const a_id = try std.fmt.bufPrint(&id_buf, "{d}", .{@intFromEnum(a)});
    try testing.expectEqual(@as(u8, 0), try fx.run(&.{ "approve", a_id, "--session" }));
    try testing.expect(std.mem.endsWith(u8, fx.out.written(), "Allowed for the session.\n"));
    // Answered: a second answer is a conflict; unknown ids are not found.
    try testing.expectEqual(@as(u8, 3), try fx.run(&.{ "approve", a_id }));
    try testing.expectEqual(@as(u8, 4), try fx.run(&.{ "deny", "!12345" }));
    try testing.expectEqual(@as(u8, 1), try fx.run(&.{"approve"}));
    var t_buf: [32]u8 = undefined;
    const t_id = try std.fmt.bufPrint(&t_buf, "!{d}", .{@intFromEnum(t)});
    // A tool's edited input must be JSON; it has no rule to save.
    try testing.expectEqual(@as(u8, 1), try fx.run(&.{ "approve", t_id, "--edit", "{nope" }));
    try testing.expectEqual(@as(u8, 1), try fx.run(&.{ "approve", t_id, "--always" }));
    try testing.expectEqual(@as(u8, 0), try fx.run(&.{ "deny", t_id, "--reason", "wrong repo" }));
    try testing.expectEqual(@as(u8, 0), try fx.run(&.{"approvals"}));
    try testing.expectEqualStrings("No approval requests waiting.\n", fx.out.written());
    try testing.expectEqual(@as(u8, 0), try fx.run(&.{ "approvals", "--all" }));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, fx.out.written(), "agent:s1/main"));

    // The IDE reads the journal: its waiters get the answers.
    _ = try p.store.tail(p.sink.sink());
    try testing.expectEqualStrings("run_command(make)", (try b.await(a, io)).allow_session);
    try testing.expectEqualStrings("wrong repo", (try b.await(t, io)).deny);
    try testing.expectEqualStrings("cli", b.get(t).?.answered_by.?);
}
