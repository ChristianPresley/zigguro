//! `zg update` (E17.F04.S01.T02): check for, download and inspect updates
//! with the same pipeline the GUI runs in the background, and apply a
//! staged update now (E17.F04.S02.T01; zigguro also applies it at its
//! next start). Switching channels waits for E15's settings editor (set
//! `update.channel` in the settings file).
//!
//! Exit 0 on success, 1 when the check failed, 2 on a usage error.

const std = @import("std");
const builtin = @import("builtin");
const zg_core = @import("zg_core");
const zg_net = @import("zg_net");
const zg_release = @import("zg_release");
const zg_update = @import("zg_update");
const zg_crash = @import("zg_crash");

const Io = std.Io;
const Status = zg_update.Status;

pub const usage =
    \\Usage: zg update check [--json]      look for an update (no download)
    \\       zg update download [--json]   check, download and stage it
    \\       zg update status [--json]     what is staged, without network
    \\       zg update apply               swap in the staged update (Linux)
    \\
    \\The feed is the product's update feed for this build's channel;
    \\ZIGGURO_UPDATE_FEED overrides it (a URL template with {channel}).
    \\
;

pub fn run(rt: *zg_core.Runtime, min: std.process.Init.Minimal, argv: []const []const u8) !u8 {
    const io = rt.io;
    const gpa = rt.gpa;
    var obuf: [4096]u8 = undefined;
    var out_w: Io.File.Writer = .init(.stdout(), io, &obuf);
    const out = &out_w.interface;
    defer out.flush() catch {};

    if (argv.len == 0 or std.mem.eql(u8, argv[0], "--help") or std.mem.eql(u8, argv[0], "-h")) {
        try out.writeAll(usage);
        return if (argv.len == 0) 2 else 0;
    }
    const sub = argv[0];
    var json = false;
    for (argv[1..]) |a| {
        if (std.mem.eql(u8, a, "--json")) json = true else {
            try out.print("zg update: unknown argument {s}\n{s}", .{ a, usage });
            return 2;
        }
    }

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = try min.environ.createMap(gpa);
    defer env.deinit();

    var state_buf: [std.fs.max_path_bytes]u8 = undefined;
    const state_dir = zg_crash.paths.stateDir(min.environ, &state_buf) orelse {
        try out.writeAll("zg update: no state directory (set ZIGGURO_STATE_DIR)\n");
        return 1;
    };
    const exe_dir = try std.process.executableDirPathAlloc(io, arena);
    const layout = zg_update.layout.detect(exe_dir, builtin.os.tag);

    if (std.mem.eql(u8, sub, "status")) return status(arena, io, out, layout, state_dir, json);
    if (std.mem.eql(u8, sub, "apply")) return apply(arena, io, out, layout);
    const download = if (std.mem.eql(u8, sub, "download")) true else if (std.mem.eql(u8, sub, "check")) false else {
        try out.print("zg update: unknown command {s}\n{s}", .{ sub, usage });
        return 2;
    };

    const bi = &zg_release.current;
    var keys: std.ArrayList(zg_release.minisign.PublicKey) = .empty;
    for (zg_release.product.release_keys) |k| try keys.append(arena, try zg_release.minisign.PublicKey.parse(k));
    const feeds: []const []const u8 = if (env.get("ZIGGURO_UPDATE_FEED")) |f| try arena.dupe([]const u8, &.{f}) else zg_release.product.update_feeds;

    var src: HttpOnDemand = .{ .rt = rt, .env = &env };
    defer src.deinit();
    var u: zg_update.Updater = .init(gpa, io, .{
        .mode = if (bi.update_mode == .disabled) .none else .manual,
        .channel = @tagName(bi.channel),
        .feed_urls = feeds,
        .layout = layout,
        .keys = keys.items,
        .current = bi.version,
        .target = bi.target,
        .build_epoch = bi.source_date_epoch,
        .state_dir = state_dir,
        .download = download,
    }, src.source());
    defer u.deinit();
    const s = u.check(true);
    try printStatus(out, s, json);
    return if (s == .failed) 1 else 0;
}

/// Creates the HTTP client only when the updater asks for it.
const HttpOnDemand = struct {
    rt: *zg_core.Runtime,
    env: *const std.process.Environ.Map,
    client: ?*zg_net.http.Client = null,

    fn source(h: *HttpOnDemand) zg_update.updater.HttpSource {
        return .{ .ctx = h, .get = get };
    }

    fn get(ctx: ?*anyopaque) anyerror!*zg_net.http.Client {
        const h: *HttpOnDemand = @ptrCast(@alignCast(ctx.?));
        if (h.client == null) h.client = try zg_net.http.Client.init(h.rt, .{ .environ_map = h.env });
        return h.client.?;
    }

    fn deinit(h: *HttpOnDemand) void {
        if (h.client) |c| c.deinit();
    }
};

fn status(arena: std.mem.Allocator, io: Io, out: *Io.Writer, layout: zg_update.layout.Layout, state_dir: []const u8, json: bool) !u8 {
    const st = try zg_update.updater.loadState(arena, io, state_dir);
    var root = Io.Dir.cwd().openDir(io, layout.root, .{}) catch null;
    defer if (root) |*r| r.close(io);
    const staged = if (root) |r| zg_update.stage.readStaged(arena, io, r) else null;
    const cur = zg_release.current.version_string;
    if (json) {
        try out.print("{{\"current\":\"{s}\",\"install_kind\":\"{t}\",\"last_check_unix\":{d},\"staged\":", .{ cur, layout.kind, st.last_check_unix });
        if (staged) |s| try out.print("\"{s}\"}}\n", .{s.version}) else try out.writeAll("null}\n");
        return 0;
    }
    try out.print("current: {s} ({t} install)\n", .{ cur, layout.kind });
    if (st.last_check_unix == 0) try out.writeAll("last check: never\n") else try out.print("last check: {d} (unix)\n", .{st.last_check_unix});
    if (staged) |s| try out.print("staged: {s}, applies on restart\n", .{s.version}) else try out.writeAll("staged: none\n");
    return 0;
}

fn apply(arena: std.mem.Allocator, io: Io, out: *Io.Writer, layout: zg_update.layout.Layout) !u8 {
    if (!layout.kind.managed()) {
        try out.print("zg update: not a managed install ({t}); nothing to apply\n", .{layout.kind});
        return 1;
    }
    if (builtin.os.tag == .windows) {
        // The running binaries live inside `app/`: the setup helper swaps
        // after they exit (E17.F02).
        try out.writeAll("zg update: on Windows the update applies when zigguro restarts\n");
        return 1;
    }
    var root = try Io.Dir.cwd().openDir(io, layout.root, .{});
    defer root.close(io);
    const now: i64 = @intCast(@divFloor(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
    const outcome = try zg_update.swap.applyStaged(arena, io, root, zg_release.current.version_string, now);
    try out.print("{s}\n", .{switch (outcome) {
        .applied => "update applied; restart zigguro to use it",
        .nothing_staged => "no update is staged",
        .recovered_forward => "finished an interrupted update; restart zigguro to use it",
        .recovered_backward => "undid an interrupted update",
    }});
    return 0;
}

fn printStatus(out: *Io.Writer, s: Status, json: bool) !void {
    if (json) {
        try out.print("{{\"status\":\"{t}\"", .{s});
        switch (s) {
            .available, .downloading, .ready => |i| try out.print(",\"version\":\"{s}\",\"critical\":{},\"notes_url\":\"{s}\"", .{ i.version(), i.critical, i.notesUrl() }),
            .failed => |f| try out.print(",\"error\":\"{t}\",\"network\":{}", .{ f.err, f.network }),
            .disabled => |r| try out.print(",\"reason\":\"{t}\"", .{r}),
            else => {},
        }
        try out.writeAll("}\n");
        return;
    }
    switch (s) {
        .up_to_date => try out.print("zigguro {s} is up to date\n", .{zg_release.current.version_string}),
        .available => |i| try out.print("update available: {s}{s}\n{s}\n", .{ i.version(), if (i.critical) " (critical)" else "", i.notesUrl() }),
        .ready => |i| try out.print("update {s} is downloaded and applies on restart\n", .{i.version()}),
        .failed => |f| try out.print("update check failed: {t}\n", .{f.err}),
        .disabled => |r| try out.print("updates are disabled ({t})\n", .{r}),
        else => try out.print("{t}\n", .{s}),
    }
}
