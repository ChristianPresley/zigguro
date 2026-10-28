//! `git init` and `git clone` (E09.F07): a new repository laid out the
//! way git lays it out (without the sample hooks), and a clone that
//! fetches every branch of a remote, records `origin`, and checks out
//! the branch the remote's HEAD names with its upstream set.

const std = @import("std");
const Repository = @import("repository.zig").Repository;
const ObjectFormat = @import("oid.zig").ObjectFormat;
const config_mod = @import("config.zig");
const reflog = @import("refs/reflog.zig");
const Oid = @import("oid.zig").Oid;
const commit_cmd = @import("commit_cmd.zig");
const checkout = @import("checkout.zig");
const remote_mod = @import("remote/remote.zig");
const fetch_mod = @import("remote/fetch.zig");
const connect = @import("remote/connect.zig");
const sideband = @import("proto/sideband.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const InitOptions = struct {
    bare: bool = false,
    /// `-b`; null uses `init.defaultBranch`, else "master".
    initial_branch: ?[]const u8 = null,
    format: ObjectFormat = .sha1,
    /// Environment for the user's config (`init.defaultBranch`).
    env: ?*const std.process.Environ.Map = null,
};

pub const exclude_template =
    \\# git ls-files --others --exclude-from=.git/info/exclude
    \\# Lines that start with '#' are comments.
    \\# For a project mostly in C, the following would be a good set of
    \\# exclude patterns (uncomment them if you want to use them):
    \\# *.[oa]
    \\# *~
    \\
;

pub const description_template = "Unnamed repository; edit this file 'description' to name the repository.\n";

/// What `init` did.
pub const Initialized = enum { created, reinitialized };

/// `git init [--bare] [-b <branch>] <dir>`: creates `dir` (absolute) as
/// needed. An existing repository there is left as it is.
pub fn init(gpa: Allocator, io: Io, dir: []const u8, opts: InitOptions) !Initialized {
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, dir);
    const gd_path = if (opts.bare) try gpa.dupe(u8, dir) else try std.fs.path.join(gpa, &.{ dir, ".git" });
    defer gpa.free(gd_path);
    try cwd.createDirPath(io, gd_path);
    var gd = try cwd.openDir(io, gd_path, .{});
    defer gd.close(io);
    if (gd.statFile(io, "HEAD", .{})) |_| return .reinitialized else |_| {}
    for ([_][]const u8{ "objects/info", "objects/pack", "refs/heads", "refs/tags", "info", "hooks", "branches" }) |d| try gd.createDirPath(io, d);
    try gd.writeFile(io, .{ .sub_path = "description", .data = description_template });
    try gd.writeFile(io, .{ .sub_path = "info/exclude", .data = exclude_template });
    var cfg: std.ArrayList(u8) = .empty;
    defer cfg.deinit(gpa);
    try cfg.print(gpa, "[core]\n\trepositoryformatversion = {d}\n\tfilemode = {s}\n\tbare = {s}\n", .{
        @as(u8, if (opts.format == .sha1) 0 else 1),
        if (@import("builtin").os.tag == .windows) "false" else "true",
        if (opts.bare) "true" else "false",
    });
    if (!opts.bare) try cfg.appendSlice(gpa, "\tlogallrefupdates = true\n");
    if (@import("builtin").os.tag == .windows) try cfg.appendSlice(gpa, "\tsymlinks = false\n\tignorecase = true\n");
    if (opts.format != .sha1) try cfg.print(gpa, "[extensions]\n\tobjectformat = {s}\n", .{opts.format.name()});
    try gd.writeFile(io, .{ .sub_path = "config", .data = cfg.items });

    var c = config_mod.Config.load(gpa, io, .{
        .env = opts.env,
        .home = if (opts.env) |e| e.get("HOME") orelse e.get("USERPROFILE") else null,
        .xdg_config_home = if (opts.env) |e| e.get("XDG_CONFIG_HOME") else null,
    }) catch config_mod.Config.init(gpa);
    defer c.deinit();
    // The user's config decides the first branch's name.
    const branch = opts.initial_branch orelse c.get("init.defaultbranch") orelse "master";
    const head = try std.fmt.allocPrint(gpa, "ref: refs/heads/{s}\n", .{branch});
    defer gpa.free(head);
    try gd.writeFile(io, .{ .sub_path = "HEAD", .data = head });
    return .created;
}

pub const CloneOptions = struct {
    /// `-o`.
    origin: []const u8 = "origin",
    /// `-b`: this branch instead of the remote's HEAD.
    branch: ?[]const u8 = null,
    bare: bool = false,
    env: ?*const std.process.Environ.Map = null,
    tz_offset_min: i32 = 0,
    on_progress: ?sideband.ProgressFn = null,
    progress_ctx: ?*anyopaque = null,
};

/// `git clone <url> <dir>`: `dir` (absolute) must be missing or empty.
/// Returns the new repository (the caller closes it). On failure the
/// folder is left for the caller to remove.
pub fn clone(gpa: Allocator, io: Io, url_in: []const u8, dir: []const u8, connector: fetch_mod.Connector, opts: CloneOptions) !*Repository {
    const cwd = Io.Dir.cwd();
    if (cwd.openDir(io, dir, .{ .iterate = true })) |d_const| {
        var d = d_const;
        defer d.close(io);
        var it = d.iterate();
        if (try it.next(io) != null) return error.DestinationNotEmpty;
    } else |_| {}
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // A local path is recorded absolute, as git does.
    const url = if (connect.kindOf(url_in) == .local and !std.mem.startsWith(u8, url_in, "file://"))
        try std.fs.path.resolve(a, &.{ try cwd.realPathFileAlloc(io, ".", a), url_in })
    else
        url_in;

    // Clone into a repository without a working tree first: init, then
    // the remote, then fetch.
    _ = try init(gpa, io, dir, .{ .bare = opts.bare, .initial_branch = "master", .env = opts.env });
    const gd_path = if (opts.bare) dir else try std.fs.path.join(a, &.{ dir, ".git" });
    const repo = try Repository.open(gpa, io, dir, gd_path, .{ .env = opts.env });
    errdefer repo.close();
    try remote_mod.add(repo, opts.origin, url);
    const msg = try std.fmt.allocPrint(a, "clone: from {s}", .{url});
    var fr = try fetch_mod.fetch(repo, opts.origin, .{
        .remote_head = true,
        .reflog_action = msg,
        .reflog_verbatim = true,
        .fetch_head = false,
        .tz_offset_min = opts.tz_offset_min,
        .on_progress = opts.on_progress,
        .progress_ctx = opts.progress_ctx,
    }, connector);
    defer fr.deinit();
    // git clone writes the remote-tracking refs without reflogs.
    for (fr.updates) |u| if (std.mem.startsWith(u8, u.local, "refs/remotes/")) {
        const lp = try std.fmt.allocPrint(a, "logs/{s}", .{u.local});
        repo.git_dir.deleteFile(io, lp) catch {};
    };

    const now: i64 = @intCast(@divFloor(Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s));
    const who = try commit_cmd.ident(repo, a, repo.envMap(), .committer, now, opts.tz_offset_min);
    // The branch to check out: -b, else what the remote's HEAD names.
    const head_ref: ?[]const u8 = if (opts.branch) |b| try std.fmt.allocPrint(a, "refs/heads/{s}", .{b}) else fr.head;
    const short = if (head_ref) |h| (if (std.mem.startsWith(u8, h, "refs/heads/")) h["refs/heads/".len..] else h) else "master";
    const tracking = try std.fmt.allocPrint(a, "refs/remotes/{s}/{s}", .{ opts.origin, short });
    const tip = try repo.refs.resolve(tracking);
    if (opts.branch != null and tip == null) return error.RemoteBranchNotFound;
    const local = try std.fmt.allocPrint(a, "refs/heads/{s}", .{short});
    // origin/HEAD follows the remote's HEAD, whatever -b checked out.
    if (fr.head) |h| if (std.mem.startsWith(u8, h, "refs/heads/")) {
        const rt = try std.fmt.allocPrint(a, "refs/remotes/{s}/{s}", .{ opts.origin, h["refs/heads/".len..] });
        if (try repo.refs.resolve(rt)) |rt_tip| {
            var tx = repo.refs.transaction();
            defer tx.deinit();
            const rh = try std.fmt.allocPrint(a, "refs/remotes/{s}/HEAD", .{opts.origin});
            try tx.update(rh, .{ .symbolic = rt }, null, msg, who);
            try tx.commit();
            // Symbolic updates are not logged by the transaction.
            var aw: Io.Writer.Allocating = .init(a);
            try reflog.formatLine(&aw.writer, Oid.zero(repo.format), rt_tip, who, msg);
            try reflog.append(io, repo.git_dir, rh, aw.written());
        }
    };
    if (tip) |t| {
        {
            var tx = repo.refs.transaction();
            defer tx.deinit();
            try tx.update(local, .{ .direct = t }, .absent, msg, who);
            try tx.commit();
        }
        if (!opts.bare) try checkout.setUpstream(repo, short, tracking);
        try checkout.setHead(repo, .{ .symbolic = local }, null, t, who, msg);
        if (!opts.bare) try checkout.moveTree(repo, null, t, true, null, null);
    } else {
        // An empty remote: HEAD names its unborn branch, upstream set.
        if (!opts.bare) try checkout.setUpstream(repo, short, tracking);
        const text = try std.fmt.allocPrint(a, "ref: {s}\n", .{local});
        try repo.git_dir.writeFile(io, .{ .sub_path = "HEAD", .data = text });
    }
    return repo;
}
