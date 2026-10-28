//! `git fetch` (E09.F08.S01): refs mapped through the remote's refspecs,
//! a protocol v2 fetch of what is missing, remote-tracking and tag refs
//! updated with git's fast-forward rules and reflog, pruning, and
//! FETCH_HEAD for a later merge.

const std = @import("std");
const protocol = @import("protocol.zig");
const transport = @import("transport.zig");
const remote_mod = @import("remote.zig");
const refspec = @import("refspec.zig");
const revwalk = @import("../revwalk.zig");
const commit_cmd = @import("../commit_cmd.zig");
const sideband = @import("../proto/sideband.zig");
const Repository = @import("../repository.zig").Repository;
const Oid = @import("../oid.zig").Oid;
const Refspec = refspec.Refspec;
const Allocator = std.mem.Allocator;

/// Opens a connection to `url` for `service`; the transport behind it
/// (HTTPS, SSH, a local process) is the connector's choice.
pub const Connector = struct {
    ctx: ?*anyopaque = null,
    connect: *const fn (ctx: ?*anyopaque, repo: *Repository, url: []const u8, service: transport.Service) anyerror!transport.Connection,
};

pub const Options = struct {
    /// Refspecs from the command line; empty uses `remote.<name>.fetch`.
    refspecs: []const []const u8 = &.{},
    /// `--prune` / `--no-prune`; null uses the config.
    prune: ?bool = null,
    tags: ?remote_mod.TagOpt = null,
    /// `-f`: allow non-fast-forward updates for every refspec.
    force: bool = false,
    on_progress: ?sideband.ProgressFn = null,
    progress_ctx: ?*anyopaque = null,
    tz_offset_min: i32 = 0,
    /// The reflog prefix (default "fetch <remote>").
    reflog_action: ?[]const u8 = null,
};

pub const UpdateKind = enum { new_branch, new_tag, new_ref, fast_forward, forced, up_to_date, rejected, pruned };

pub const RefUpdate = struct {
    /// The remote's ref (empty for a pruned one).
    remote: []const u8,
    /// The local ref written ("" when only FETCH_HEAD records it).
    local: []const u8,
    old: ?Oid,
    new: ?Oid,
    kind: UpdateKind,
};

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    updates: []const RefUpdate = &.{},
    /// Objects received (0 when nothing was missing).
    objects: u32 = 0,

    pub fn deinit(r: *Result) void {
        r.arena.deinit();
    }

    pub fn rejected(r: Result) usize {
        var n: usize = 0;
        for (r.updates) |u| n += @intFromBool(u.kind == .rejected);
        return n;
    }
};

const Planned = struct {
    remote: protocol.RemoteRef,
    local: []const u8,
    force: bool,
    for_merge: bool,
};

pub fn fetch(repo: *Repository, remote_name: []const u8, opts: Options, connector: Connector) !Result {
    var res: Result = .{ .arena = .init(repo.gpa) };
    errdefer res.deinit();
    const a = res.arena.allocator();
    const rem = (try remote_mod.get(repo, a, remote_name)) orelse return error.NoSuchRemote;
    const cmdline = opts.refspecs.len > 0;
    var specs: std.ArrayList(Refspec) = .empty;
    for (opts.refspecs) |s| try specs.append(a, try expandShort(a, try refspec.parse(s)));
    if (!cmdline) try specs.appendSlice(a, rem.fetch);
    const tags = opts.tags orelse rem.tags;

    const conn = try connector.connect(connector.ctx, repo, rem.url, .upload_pack);
    defer conn.close();
    const adv = try protocol.readAdvertisement(a, conn);
    if (adv.format != repo.format) return error.ObjectFormatMismatch;
    var prefixes: std.ArrayList([]const u8) = .empty;
    for (specs.items) |s| if (!s.negative) try prefixes.append(a, s.prefix());
    if (tags != .none) try prefixes.append(a, "refs/tags/");
    const refs = try protocol.lsRefs(a, conn, &adv, prefixes.items);

    // Which local ref each remote ref goes to.
    var planned: std.ArrayList(Planned) = .empty;
    const merge_ref = try mergeRef(repo, a, remote_name);
    for (refs) |r| {
        if (r.unborn or std.mem.eql(u8, r.name, "HEAD")) continue;
        if (excluded(specs.items, r.name)) continue;
        for (specs.items) |s| {
            if (s.negative or !s.matches(r.name)) continue;
            const local = if (s.dst.len > 0) (try s.map(a, r.name)).? else "";
            const for_merge = if (cmdline) true else if (merge_ref) |m| std.mem.eql(u8, m, r.name) else false;
            try planned.append(a, .{ .remote = r, .local = local, .force = s.force or opts.force, .for_merge = for_merge });
            break;
        }
    }
    if (tags == .all) for (refs) |r| {
        if (!std.mem.startsWith(u8, r.name, "refs/tags/")) continue;
        if (alreadyPlanned(planned.items, r.name)) continue;
        try planned.append(a, .{ .remote = r, .local = r.name, .force = opts.force, .for_merge = false });
    };

    var wants: std.ArrayList(Oid) = .empty;
    var want_set: std.AutoHashMapUnmanaged(Oid, void) = .empty;
    for (planned.items) |p| {
        if (repo.odb.exists(p.remote.oid) or (try want_set.getOrPut(a, p.remote.oid)).found_existing) continue;
        try wants.append(a, p.remote.oid);
    }
    if (try protocol.fetchPack(repo, a, conn, &adv, wants.items, .{ .on_progress = opts.on_progress, .progress_ctx = opts.progress_ctx, .include_tag = tags != .none })) |p| res.objects = p.count;
    protocol.endSession(conn, &adv);

    // Tags that now point into what we have.
    if (tags == .auto) for (refs) |r| {
        if (!std.mem.startsWith(u8, r.name, "refs/tags/") or std.mem.endsWith(u8, r.name, "^{}")) continue;
        if (alreadyPlanned(planned.items, r.name)) continue;
        if ((try repo.refs.resolve(r.name)) != null) continue;
        if (!repo.odb.exists(r.oid)) continue;
        try planned.append(a, .{ .remote = r, .local = r.name, .force = false, .for_merge = false });
    };

    const action = opts.reflog_action orelse try std.fmt.allocPrint(a, "fetch {s}", .{remote_name});
    const now: i64 = @intCast(@divFloor(std.Io.Timestamp.now(repo.io, .real).nanoseconds, std.time.ns_per_s));
    const who = try commit_cmd.ident(repo, a, repo.envMap(), .committer, now, opts.tz_offset_min);
    var updates: std.ArrayList(RefUpdate) = .empty;
    var tx = repo.refs.transaction();
    defer tx.deinit();
    var any = false;
    for (planned.items) |p| {
        if (p.local.len == 0) {
            try updates.append(a, .{ .remote = p.remote.name, .local = "", .old = null, .new = p.remote.oid, .kind = .new_ref });
            continue;
        }
        const old = try repo.refs.resolve(p.local);
        const new = p.remote.oid;
        const is_tag = std.mem.startsWith(u8, p.local, "refs/tags/");
        const kind: UpdateKind = if (old) |o| blk: {
            if (o.eql(new)) break :blk .up_to_date;
            if (is_tag) break :blk if (p.force) .forced else .rejected;
            if (try isCommitAncestor(repo, o, new)) break :blk .fast_forward;
            break :blk if (p.force) .forced else .rejected;
        } else if (is_tag) .new_tag else if (std.mem.startsWith(u8, p.local, "refs/remotes/") or std.mem.startsWith(u8, p.local, "refs/heads/")) .new_branch else .new_ref;
        try updates.append(a, .{ .remote = p.remote.name, .local = p.local, .old = old, .new = new, .kind = kind });
        const what: ?[]const u8 = switch (kind) {
            .new_branch => "storing head",
            .new_tag => "storing tag",
            .new_ref => "storing ref",
            .fast_forward => "fast-forward",
            .forced => "forced-update",
            else => null,
        };
        if (what) |w| {
            try tx.update(p.local, .{ .direct = new }, if (old) |o| .{ .oid = o } else .absent, try std.fmt.allocPrint(a, "{s}: {s}", .{ action, w }), who);
            any = true;
        }
    }

    if (opts.prune orelse rem.prune) {
        for (specs.items) |s| {
            if (s.negative or s.dst.len == 0 or !s.isGlob()) continue;
            const dst_spec: Refspec = .{ .src = s.dst };
            var local = try repo.refs.iterate(repo.gpa, dst_spec.prefix());
            defer local.deinit();
            for (local.refs) |l| {
                if (!dst_spec.matches(l.name) or l.value != .direct) continue;
                if (stillOnRemote(a, s, refs, l.name)) continue;
                try tx.delete(l.name, null, "");
                try updates.append(a, .{ .remote = "", .local = try a.dupe(u8, l.name), .old = l.value.direct, .new = null, .kind = .pruned });
                any = true;
            }
        }
    }
    if (any) try tx.commit();
    try writeFetchHead(repo, a, rem.url, planned.items);
    res.updates = updates.items;
    return res;
}

/// "main" on the command line means refs/heads/main (or a tag).
fn expandShort(a: Allocator, s: Refspec) !Refspec {
    var r = s;
    if (!std.mem.startsWith(u8, r.src, "refs/") and !std.mem.eql(u8, r.src, "HEAD") and r.src.len > 0) {
        r.src = try std.fmt.allocPrint(a, "refs/heads/{s}", .{r.src});
    }
    if (r.dst.len > 0 and !std.mem.startsWith(u8, r.dst, "refs/")) r.dst = try std.fmt.allocPrint(a, "refs/heads/{s}", .{r.dst});
    return r;
}

fn excluded(specs: []const Refspec, name: []const u8) bool {
    for (specs) |s| if (s.negative and s.matches(name)) return true;
    return false;
}

fn alreadyPlanned(planned: []const Planned, name: []const u8) bool {
    for (planned) |p| if (std.mem.eql(u8, p.remote.name, name)) return true;
    return false;
}

fn isCommitAncestor(repo: *Repository, old: Oid, new: Oid) !bool {
    return revwalk.isAncestor(repo, old, new) catch |e| switch (e) {
        error.NotACommit => false,
        else => e,
    };
}

fn stillOnRemote(a: Allocator, s: Refspec, refs: []const protocol.RemoteRef, local: []const u8) bool {
    for (refs) |r| {
        const mapped = (s.map(a, r.name) catch return true) orelse continue;
        if (std.mem.eql(u8, mapped, local)) return true;
    }
    return false;
}

/// The remote ref the current branch merges from this remote.
fn mergeRef(repo: *Repository, a: Allocator, remote_name: []const u8) !?[]const u8 {
    const head = (try repo.headRef(a)) orelse return null;
    if (!std.mem.startsWith(u8, head, "refs/heads/")) return null;
    const b = head["refs/heads/".len..];
    const r = repo.config.get(try std.fmt.allocPrint(a, "branch.{s}.remote", .{b})) orelse return null;
    if (!std.mem.eql(u8, r, remote_name)) return null;
    return repo.config.get(try std.fmt.allocPrint(a, "branch.{s}.merge", .{b}));
}

/// FETCH_HEAD: for-merge entries first, then the rest marked
/// not-for-merge, as `git pull` reads them.
fn writeFetchHead(repo: *Repository, a: Allocator, url: []const u8, planned: []const Planned) !void {
    var out: std.ArrayList(u8) = .empty;
    const clean_url = try displayUrl(a, url);
    for ([_]bool{ true, false }) |pass| for (planned) |p| {
        if (p.for_merge != pass) continue;
        const n = p.remote.name;
        var hb: [64]u8 = undefined;
        const desc = if (std.mem.startsWith(u8, n, "refs/heads/"))
            try std.fmt.allocPrint(a, "branch '{s}' of ", .{n["refs/heads/".len..]})
        else if (std.mem.startsWith(u8, n, "refs/tags/"))
            try std.fmt.allocPrint(a, "tag '{s}' of ", .{n["refs/tags/".len..]})
        else
            try std.fmt.allocPrint(a, "'{s}' of ", .{n});
        try out.print(a, "{s}\t{s}\t{s}{s}\n", .{ p.remote.oid.hex(&hb), if (p.for_merge) "" else "not-for-merge", desc, clean_url });
    };
    try repo.git_dir.writeFile(repo.io, .{ .sub_path = "FETCH_HEAD", .data = out.items });
}

/// The URL as git shows it in FETCH_HEAD and merge messages: no
/// credentials, no trailing slash or ".git".
pub fn displayUrl(a: Allocator, url: []const u8) ![]const u8 {
    var u = url;
    var out: std.ArrayList(u8) = .empty;
    if (std.mem.indexOf(u8, u, "://")) |scheme_end| {
        const rest = u[scheme_end + 3 ..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        if (std.mem.lastIndexOfScalar(u8, rest[0..slash], '@')) |at| {
            try out.appendSlice(a, u[0 .. scheme_end + 3]);
            u = rest[at + 1 ..];
        }
    }
    try out.appendSlice(a, u);
    var s: []const u8 = std.mem.trimEnd(u8, out.items, "/");
    if (std.mem.endsWith(u8, s, ".git")) s = s[0 .. s.len - 4];
    return std.mem.trimEnd(u8, s, "/");
}

test "displayUrl drops credentials and .git" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("https://github.com/o/r", try displayUrl(a, "https://u:tok@github.com/o/r.git/"));
    try std.testing.expectEqualStrings("../srv", try displayUrl(a, "../srv/"));
}
