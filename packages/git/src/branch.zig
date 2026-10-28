//! Branches and tags (E09.F09.S01.T03): `git branch` (list with
//! upstream and ahead/behind, create, delete, rename, set or unset the
//! upstream) and `git tag` (lightweight and annotated, delete, list).

const std = @import("std");
const commit_mod = @import("commit.zig");
const tag_mod = @import("tag.zig");
const config_mod = @import("config.zig");
const revparse = @import("revparse.zig");
const revwalk = @import("revwalk.zig");
const commit_cmd = @import("commit_cmd.zig");
const refname = @import("refs/refname.zig");
const Repository = @import("repository.zig").Repository;
const Oid = @import("oid.zig").Oid;
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Branch = struct {
    /// Short name ("main", or "origin/main" for a remote branch).
    name: []const u8,
    /// Full ref name.
    ref: []const u8,
    remote: bool,
    head: bool,
    target: Oid,
    /// The remote-tracking ref this branch follows, if any.
    upstream: ?[]const u8 = null,
    /// null when there is no upstream or it is gone.
    ahead: ?u32 = null,
    behind: ?u32 = null,
};

pub const BranchList = struct {
    arena: std.heap.ArenaAllocator,
    items: []Branch,

    pub fn deinit(l: *BranchList) void {
        l.arena.deinit();
    }
};

/// Local branches, then remote ones (without `<remote>/HEAD`), sorted.
/// `counts` fills ahead/behind against each upstream.
pub fn list(repo: *Repository, counts: bool) !BranchList {
    var out: BranchList = .{ .arena = .init(repo.gpa), .items = &.{} };
    errdefer out.deinit();
    const a = out.arena.allocator();
    const head_ref = try repo.headRef(a);
    var items: std.ArrayList(Branch) = .empty;
    for ([_][]const u8{ "refs/heads/", "refs/remotes/" }) |prefix| {
        var refs = try repo.refs.iterate(repo.gpa, prefix);
        defer refs.deinit();
        for (refs.refs) |r| {
            const name = r.name[prefix.len..];
            if (std.mem.endsWith(u8, name, "/HEAD")) continue;
            const target = switch (r.value) {
                .direct => |id| id,
                .symbolic => |s| (repo.refs.resolve(s) catch null) orelse continue,
            };
            var b: Branch = .{
                .name = try a.dupe(u8, name),
                .ref = try a.dupe(u8, r.name),
                .remote = prefix[5] == 'r',
                .head = head_ref != null and std.mem.eql(u8, head_ref.?, r.name),
                .target = target,
            };
            if (!b.remote) if (revparse.upstreamRef(repo, a, b.name)) |up| {
                b.upstream = up;
                if (counts) if (try repo.refs.resolve(up)) |uid| {
                    const ab = try revwalk.aheadBehind(repo, target, uid);
                    b.ahead = ab.ahead;
                    b.behind = ab.behind;
                };
            } else |_| {};
            try items.append(a, b);
        }
    }
    out.items = items.items;
    return out;
}

fn who(repo: *Repository, a: Allocator) !commit_mod.Ident {
    const now: i64 = @intCast(@divFloor(Io.Timestamp.now(repo.io, .real).nanoseconds, std.time.ns_per_s));
    return commit_cmd.ident(repo, a, repo.envMap(), .committer, now, 0);
}

/// `git branch <name> [<start>]` (`force`: move an existing branch).
pub fn create(repo: *Repository, name: []const u8, start: []const u8, force: bool) !Oid {
    var arena: std.heap.ArenaAllocator = .init(repo.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const full = try std.fmt.allocPrint(a, "refs/heads/{s}", .{name});
    if (!refname.checkRefFormat(full, .{}) or std.mem.startsWith(u8, name, "-") or std.mem.eql(u8, name, "HEAD")) return error.InvalidBranchName;
    const target = try revparse.resolveCommit(repo, if (start.len == 0) "HEAD" else start);
    if (force) if (try repo.headRef(a)) |h| if (std.mem.eql(u8, h, full)) return error.BranchIsCheckedOut;
    var tx = repo.refs.transaction();
    defer tx.deinit();
    try tx.update(full, .{ .direct = target }, if (force) null else .absent, try std.fmt.allocPrint(a, "branch: Created from {s}", .{if (start.len == 0) "HEAD" else start}), try who(repo, a));
    tx.commit() catch |e| return if (e == error.RefExists) error.BranchExists else e;
    return target;
}

/// `git branch -d` (`force`: `-D`). Without `force` the branch must be
/// merged into its upstream, or into HEAD when it has none.
pub fn delete(repo: *Repository, name: []const u8, force: bool) !void {
    var arena: std.heap.ArenaAllocator = .init(repo.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const full = try std.fmt.allocPrint(a, "refs/heads/{s}", .{name});
    const tip = (try repo.refs.resolve(full)) orelse return error.BranchNotFound;
    if (try repo.headRef(a)) |h| if (std.mem.eql(u8, h, full)) return error.BranchIsCheckedOut;
    if (!force) {
        const into: ?Oid = if (revparse.upstreamRef(repo, a, name)) |up| try repo.refs.resolve(up) else |_| try repo.head();
        if (into) |i| {
            if (!try revwalk.isAncestor(repo, tip, i)) return error.BranchNotMerged;
        } else return error.BranchNotMerged;
    }
    var tx = repo.refs.transaction();
    defer tx.deinit();
    try tx.delete(full, .{ .oid = tip }, "branch: deleted");
    try tx.commit();
    try dropBranchConfig(repo, name);
}

/// `git push <remote> --delete` is the remote side; this drops a remote
/// branch's tracking ref only (`git branch -dr`).
pub fn deleteRemoteTracking(repo: *Repository, name: []const u8) !void {
    var buf: [512]u8 = undefined;
    const full = try std.fmt.bufPrint(&buf, "refs/remotes/{s}", .{name});
    var tx = repo.refs.transaction();
    defer tx.deinit();
    try tx.delete(full, null, "branch: deleted");
    try tx.commit();
}

fn configPath(repo: *Repository, a: Allocator) ![]const u8 {
    return std.fs.path.join(a, &.{ repo.common_dir_path, "config" });
}

fn dropBranchConfig(repo: *Repository, name: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(repo.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg = try configPath(repo, a);
    for ([_][]const u8{ "remote", "merge", "rebase", "pushremote" }) |k| {
        if (repo.config.get(try std.fmt.allocPrint(a, "branch.{s}.{s}", .{ name, k })) == null) continue;
        try config_mod.setValue(repo.gpa, repo.io, cfg, try std.fmt.allocPrint(a, "branch.{s}.{s}", .{ name, k }), null);
    }
    try repo.reloadConfig(.{ .env = repo.env });
}

/// `git branch -m <old> <new>` (`force`: `-M`): moves the ref, its
/// reflog and its config, and HEAD when it points there.
pub fn rename(repo: *Repository, old: []const u8, new: []const u8, force: bool) !void {
    var arena: std.heap.ArenaAllocator = .init(repo.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const from = try std.fmt.allocPrint(a, "refs/heads/{s}", .{old});
    const to = try std.fmt.allocPrint(a, "refs/heads/{s}", .{new});
    if (!refname.checkRefFormat(to, .{}) or std.mem.startsWith(u8, new, "-")) return error.InvalidBranchName;
    const tip = (try repo.refs.resolve(from)) orelse return error.BranchNotFound;
    const id = try who(repo, a);
    const msg = try std.fmt.allocPrint(a, "Branch: renamed {s} to {s}", .{ from, to });
    // Keep the history of the old name.
    const old_log = try std.fmt.allocPrint(a, "logs/{s}", .{from});
    const new_log = try std.fmt.allocPrint(a, "logs/{s}", .{to});
    const log_text = repo.refs.common_dir.readFileAlloc(repo.io, old_log, a, .limited(64 << 20)) catch "";
    var tx = repo.refs.transaction();
    defer tx.deinit();
    try tx.delete(from, .{ .oid = tip }, msg);
    try tx.update(to, .{ .direct = tip }, if (force) null else .absent, msg, id);
    tx.commit() catch |e| return if (e == error.RefExists) error.BranchExists else e;
    if (log_text.len > 0) {
        const now = repo.refs.common_dir.readFileAlloc(repo.io, new_log, a, .limited(64 << 20)) catch "";
        if (std.fs.path.dirnamePosix(new_log)) |d| try repo.refs.common_dir.createDirPath(repo.io, d);
        try repo.refs.common_dir.writeFile(repo.io, .{ .sub_path = new_log, .data = try std.mem.concat(a, u8, &.{ log_text, now }) });
    }
    if (try repo.headRef(a)) |h| if (std.mem.eql(u8, h, from)) {
        var htx = repo.refs.transaction();
        defer htx.deinit();
        try htx.update("HEAD", .{ .symbolic = to }, null, msg, id);
        try htx.commit();
    };
    // branch.<old>.* becomes branch.<new>.*.
    const cfg = try configPath(repo, a);
    for ([_][]const u8{ "remote", "merge", "rebase", "pushremote" }) |k| {
        const v = repo.config.get(try std.fmt.allocPrint(a, "branch.{s}.{s}", .{ old, k })) orelse continue;
        const val = try a.dupe(u8, v);
        try config_mod.setValue(repo.gpa, repo.io, cfg, try std.fmt.allocPrint(a, "branch.{s}.{s}", .{ new, k }), val);
        try config_mod.setValue(repo.gpa, repo.io, cfg, try std.fmt.allocPrint(a, "branch.{s}.{s}", .{ old, k }), null);
    }
    try repo.reloadConfig(.{ .env = repo.env });
}

/// `git branch -u <remote>/<branch> [<name>]`, or `--unset-upstream`
/// when `upstream` is null.
pub fn setUpstream(repo: *Repository, name: []const u8, upstream: ?[]const u8) !void {
    if (upstream) |u| {
        var buf: [512]u8 = undefined;
        const full = if (std.mem.startsWith(u8, u, "refs/remotes/")) u else try std.fmt.bufPrint(&buf, "refs/remotes/{s}", .{u});
        if ((try repo.refs.resolve(full)) == null) return error.UpstreamNotFound;
        return @import("checkout.zig").setUpstream(repo, name, full);
    }
    try dropBranchConfig(repo, name);
}

// -- tags -----------------------------------------------------------------

pub const Tag = struct { name: []const u8, target: Oid, annotated: bool };

pub const TagList = struct {
    arena: std.heap.ArenaAllocator,
    items: []Tag,

    pub fn deinit(l: *TagList) void {
        l.arena.deinit();
    }
};

pub fn tags(repo: *Repository) !TagList {
    var out: TagList = .{ .arena = .init(repo.gpa), .items = &.{} };
    errdefer out.deinit();
    const a = out.arena.allocator();
    var refs = try repo.refs.iterate(repo.gpa, "refs/tags/");
    defer refs.deinit();
    var items: std.ArrayList(Tag) = .empty;
    for (refs.refs) |r| {
        const id = switch (r.value) {
            .direct => |x| x,
            .symbolic => continue,
        };
        const hdr = repo.odb.readHeader(id) catch continue;
        const target = r.peeled orelse (revparse.peel(repo, a, id, .any) catch id);
        try items.append(a, .{ .name = try a.dupe(u8, r.name["refs/tags/".len..]), .target = target, .annotated = hdr.type == .tag });
    }
    out.items = items.items;
    return out;
}

/// `git tag [-a -m <message>] <name> [<rev>]` (`force`: `-f`).
pub fn createTag(repo: *Repository, name: []const u8, rev: []const u8, message: ?[]const u8, force: bool, tz_offset_min: i32) !Oid {
    var arena: std.heap.ArenaAllocator = .init(repo.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const full = try std.fmt.allocPrint(a, "refs/tags/{s}", .{name});
    if (!refname.checkRefFormat(full, .{})) return error.InvalidTagName;
    const target = try revparse.resolve(repo, if (rev.len == 0) "HEAD" else rev);
    var value = target;
    if (message) |m| {
        if (repo.config.getBool("tag.gpgsign") orelse false) return error.SigningUnsupported;
        const hdr = try repo.odb.readHeader(target);
        const now: i64 = @intCast(@divFloor(Io.Timestamp.now(repo.io, .real).nanoseconds, std.time.ns_per_s));
        const tagger = try commit_cmd.ident(repo, a, repo.envMap(), .committer, now, tz_offset_min);
        const body = try commit_cmd.cleanMessage(a, m, .strip, '#');
        const t: tag_mod.Tag = .{ .object = target, .type = hdr.type, .name = name, .tagger = tagger, .message = body };
        var aw: std.Io.Writer.Allocating = .init(a);
        try tag_mod.serializeTag(&t, &aw.writer);
        value = try repo.odb.writeLoose(.tag, aw.written());
    }
    var tx = repo.refs.transaction();
    defer tx.deinit();
    try tx.update(full, .{ .direct = value }, if (force) null else .absent, "", try who(repo, a));
    tx.commit() catch |e| return if (e == error.RefExists) error.TagExists else e;
    return value;
}

pub fn deleteTag(repo: *Repository, name: []const u8) !void {
    var buf: [512]u8 = undefined;
    const full = try std.fmt.bufPrint(&buf, "refs/tags/{s}", .{name});
    if ((try repo.refs.resolve(full)) == null) return error.TagNotFound;
    var tx = repo.refs.transaction();
    defer tx.deinit();
    try tx.delete(full, null, "");
    try tx.commit();
}
