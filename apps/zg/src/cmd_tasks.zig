//! `zg tasks gh` (E13.F03.S03.T02): the task board's GitHub Issues sync
//! from the command line, the same engine the app runs.
//!
//! `pull` imports open issues and brings remote changes down, `push` sends
//! local changes of linked tasks, `publish ID` creates an issue for a task
//! (only ever on request), and `status` reads the sync state without the
//! network. The token comes from `GITHUB_TOKEN` or `GH_TOKEN`; the
//! repository from `--repo` or the state of an earlier sync.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_ai = @import("zg_ai");
const zg_net = @import("zg_net");
const zg_agents = @import("zg_agents");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const tasks = zg_agents.tasks;
const github = tasks.github;

pub const usage_text =
    \\Usage: zg tasks gh pull [--json]
    \\       zg tasks gh push [--json]
    \\       zg tasks gh publish ID [--json]
    \\       zg tasks gh status [--json]
    \\
    \\Options: --repo OWNER/NAME (default: the repository of the last sync)
    \\         --label NAME      only sync issues with this label (repeatable)
    \\         --workspace DIR   (default: the current directory)
    \\
    \\Tasks live in .zigguro/tasks (see docs/formats/tasks.md). The token
    \\comes from GITHUB_TOKEN or GH_TOKEN. Conflicts (a field changed on
    \\both sides) are left for review and counted, never overwritten.
    \\
;

pub const Cmd = enum { pull, push, publish, status };

pub fn run(rt: *zg_core.Runtime, min: std.process.Init.Minimal, argv: []const [:0]const u8) !u8 {
    var obuf: [16 * 1024]u8 = undefined;
    var ebuf: [2048]u8 = undefined;
    var out_w: Io.File.Writer = .init(.stdout(), rt.io, &obuf);
    var err_w: Io.File.Writer = .init(.stderr(), rt.io, &ebuf);
    defer out_w.interface.flush() catch {};
    defer err_w.interface.flush() catch {};
    var arena: std.heap.ArenaAllocator = .init(rt.gpa);
    defer arena.deinit();
    var env = try min.environ.createMap(arena.allocator());
    const token = env.get("GITHUB_TOKEN") orelse env.get("GH_TOKEN") orelse "";
    const client = try zg_net.http.Client.init(rt, .{ .environ_map = &env });
    defer client.deinit();
    var net: zg_ai.transport.ZgNet = .{ .client = client };
    return runIn(rt, net.transport(), token, argv, &out_w.interface, &err_w.interface);
}

/// `zg tasks ARGV` over `transport` with `token`.
pub fn runIn(rt: *zg_core.Runtime, transport: zg_ai.Transport, token: []const u8, argv: []const [:0]const u8, out: *Io.Writer, err: *Io.Writer) !u8 {
    const gpa = rt.gpa;
    const io = rt.io;
    if (argv.len == 0 or !std.mem.eql(u8, argv[0], "gh") or argv.len == 1 or std.mem.eql(u8, argv[1], "--help") or std.mem.eql(u8, argv[1], "-h")) {
        const asked = argv.len >= 2 and (std.mem.eql(u8, argv[1], "--help") or std.mem.eql(u8, argv[1], "-h"));
        try (if (asked) out else err).writeAll(usage_text);
        return if (asked) 0 else 2;
    }
    const cmd = std.meta.stringToEnum(Cmd, argv[1]) orelse return usage(err);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var json = false;
    var workspace: []const u8 = ".";
    var repo_text: ?[]const u8 = null;
    var labels: std.ArrayList([]const u8) = .empty;
    var pos: std.ArrayList([]const u8) = .empty;
    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, arg, "--workspace") or std.mem.eql(u8, arg, "--repo") or std.mem.eql(u8, arg, "--label")) {
            i += 1;
            if (i >= argv.len) return usage(err);
            if (arg[2] == 'w') workspace = argv[i] else if (arg[2] == 'r') repo_text = argv[i] else try labels.append(a, argv[i]);
        } else try pos.append(a, arg);
    }
    if (pos.items.len != @as(usize, if (cmd == .publish) 1 else 0)) return usage(err);

    var ws = Io.Dir.cwd().openDir(io, workspace, .{}) catch |e| {
        try err.print("zg tasks: cannot open {s}: {t}\n", .{ workspace, e });
        return 1;
    };
    defer ws.close(io);
    const store = try tasks.TaskStore.open(gpa, io, ws, .{});
    defer store.close();
    const saved = github.state.load(io, a, store.state) catch |e| {
        try err.print("zg tasks: cannot read {s}/{s}: {t}\n", .{ store.o.state_rel, github.state.file_name, e });
        return 1;
    };
    const slug = repo_text orelse if (saved.repo.len > 0) saved.repo else {
        try err.writeAll("zg tasks: which repository? Pass --repo OWNER/NAME the first time.\n");
        return 2;
    };
    const slash = std.mem.indexOfScalar(u8, slug, '/') orelse return usage(err);
    const repo: github.Repo = .{ .owner = slug[0..slash], .name = slug[slash + 1 ..] };
    if (!repo.isValid()) {
        try err.print("zg tasks: not a repository: {s}\n", .{slug});
        return 2;
    }

    var tok = token;
    var client: github.GitHubClient = .init(io, transport, .fixed(&tok), .{});
    var engine: github.SyncEngine = .init(gpa, io, &client, store, store.state, .{ .repo = repo, .labels_filter = labels.items }, .{ .rt = rt });
    if (cmd != .status and token.len == 0) {
        try err.writeAll("zg tasks: set GITHUB_TOKEN (or GH_TOKEN) to a token that can read and write the repository's issues\n");
        return 1;
    }
    switch (cmd) {
        .pull, .push => {
            const r = (if (cmd == .pull) engine.pull() else engine.push()) catch |e| return fail(err, &client, e);
            if (json) {
                try std.json.Stringify.value(r, .{}, out);
                try out.writeByte('\n');
            } else try out.print("{s}: {d} imported, {d} updated here, {d} updated on GitHub, {d} conflicts, {d} skipped ({d} requests)\n", .{
                @tagName(cmd), r.created, r.updated_local, r.updated_remote, r.conflicts, r.skipped, r.requests,
            });
            return if (r.conflicts > 0) 3 else 0;
        },
        .publish => {
            const id = tasks.ids.parse(pos.items[0]) orelse return usage(err);
            const n = engine.publish(id) catch |e| return fail(err, &client, e);
            if (json) {
                try std.json.Stringify.value(.{ .task = tasks.ids.format(id).slice(), .number = n, .github = try std.fmt.allocPrint(a, "{s}#{d}", .{ slug, n }) }, .{}, out);
                try out.writeByte('\n');
            } else try out.print("{s} published as {s}#{d}\n", .{ tasks.ids.format(id).slice(), slug, n });
            return 0;
        },
        .status => {
            const s = try engine.status(a);
            if (json) {
                try std.json.Stringify.value(s, .{}, out);
                try out.writeByte('\n');
            } else try out.print("{s}: {d} linked tasks, {d} to push, {d} conflicts; last pull {s}\n", .{
                s.repo, s.linked, s.pending_push, s.conflicts, s.last_pull_iso orelse "never",
            });
            return 0;
        },
    }
}

fn fail(err: *Io.Writer, client: *const github.GitHubClient, e: anyerror) !u8 {
    const why = client.lastError();
    switch (e) {
        error.AlreadyLinked => try err.writeAll("zg tasks: the task is already linked to an issue\n"),
        error.TaskNotFound => try err.writeAll("zg tasks: no such task\n"),
        error.RepoChanged => try err.writeAll("zg tasks: this workspace syncs with another repository (see `zg tasks gh status`)\n"),
        else => if (why.len > 0) try err.print("zg tasks: {s}\n", .{why}) else try err.print("zg tasks: {t}\n", .{e}),
    }
    return 1;
}

fn usage(err: *Io.Writer) !u8 {
    try err.writeAll(usage_text);
    return 2;
}

test "zg tasks gh pull, publish and status" {
    const testing = std.testing;
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(ws);
    var fake: github.fake.FakeGitHub = .init(testing.allocator);
    defer fake.deinit();
    _ = fake.add(.{ .title = "From GitHub", .labels = &.{"bug"} });
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var errs: Io.Writer.Allocating = .init(testing.allocator);
    defer errs.deinit();

    // The first sync needs the repository.
    try testing.expectEqual(2, try runIn(&rt, fake.transport(), "t", &.{ "gh", "pull", "--workspace", ws }, &out.writer, &errs.writer));
    try testing.expectEqual(0, try runIn(&rt, fake.transport(), "t", &.{ "gh", "pull", "--json", "--repo", "octo/demo", "--workspace", ws }, &out.writer, &errs.writer));
    try testing.expectEqualStrings("{\"created\":1,\"updated_local\":0,\"updated_remote\":0,\"conflicts\":0,\"skipped\":0,\"requests\":1}\n", out.written());
    out.clearRetainingCapacity();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".zigguro/tasks/T-0002-local.md", .data = "---\nid: T-0002\ntitle: Local\nstatus: ready\n---\n# Local\n" });
    try testing.expectEqual(0, try runIn(&rt, fake.transport(), "t", &.{ "gh", "publish", "T-0002", "--workspace", ws }, &out.writer, &errs.writer));
    try testing.expectEqualStrings("T-0002 published as octo/demo#2\n", out.written());
    out.clearRetainingCapacity();
    try testing.expectEqual(1, try runIn(&rt, fake.transport(), "t", &.{ "gh", "publish", "T-0002", "--workspace", ws }, &out.writer, &errs.writer));

    try testing.expectEqual(0, try runIn(&rt, fake.transport(), "", &.{ "gh", "status", "--json", "--workspace", ws }, &out.writer, &errs.writer));
    try testing.expect(std.mem.startsWith(u8, out.written(), "{\"repo\":\"octo/demo\",\"linked\":2,"));
    // No token, no network.
    try testing.expectEqual(1, try runIn(&rt, fake.transport(), "", &.{ "gh", "push", "--workspace", ws }, &out.writer, &errs.writer));
}
