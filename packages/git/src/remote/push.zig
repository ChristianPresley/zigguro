//! `git push` (E09.F08.S01): refspecs resolved against local and remote
//! refs, git's fast-forward and tag rules, a thin pack of what the
//! remote lacks, `report-status`, and the remote-tracking refs and
//! upstream settings updated afterwards.

const std = @import("std");
const protocol = @import("protocol.zig");
const objects = @import("objects.zig");
const remote_mod = @import("remote.zig");
const refspec = @import("refspec.zig");
const fetch_mod = @import("fetch.zig");
const revwalk = @import("../revwalk.zig");
const revparse = @import("../revparse.zig");
const commit_cmd = @import("../commit_cmd.zig");
const checkout = @import("../checkout.zig");
const pack_writer = @import("../pack/writer.zig");
const sideband = @import("../proto/sideband.zig");
const Repository = @import("../repository.zig").Repository;
const Oid = @import("../oid.zig").Oid;
const Refspec = refspec.Refspec;
const Allocator = std.mem.Allocator;

pub const Options = struct {
    /// Refspecs; empty pushes the current branch to the same name.
    refspecs: []const []const u8 = &.{},
    /// `-f`.
    force: bool = false,
    /// `--force-with-lease`: refuse unless the remote ref still has the
    /// value of our remote-tracking ref.
    force_with_lease: bool = false,
    /// `--tags`: every local tag too.
    tags: bool = false,
    /// `-u`: set each pushed branch's upstream.
    set_upstream: bool = false,
    /// `--atomic`, when the server supports it.
    atomic: bool = false,
    dry_run: bool = false,
    on_progress: ?sideband.ProgressFn = null,
    progress_ctx: ?*anyopaque = null,
    tz_offset_min: i32 = 0,
};

pub const Status = enum { new, fast_forward, forced, deleted, up_to_date, rejected_non_ff, rejected_fetch_first, rejected_tag_exists, rejected_stale, remote_rejected };

pub const RefResult = struct {
    local: []const u8,
    remote: []const u8,
    old: ?Oid,
    new: ?Oid,
    status: Status,
    /// The server's reason for `remote_rejected`.
    reason: ?[]const u8 = null,

    pub fn ok(r: RefResult) bool {
        return switch (r.status) {
            .new, .fast_forward, .forced, .deleted, .up_to_date => true,
            else => false,
        };
    }
};

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    refs: []const RefResult = &.{},

    pub fn deinit(r: *Result) void {
        r.arena.deinit();
    }

    pub fn allOk(r: Result) bool {
        for (r.refs) |x| if (!x.ok()) return false;
        return true;
    }
};

const Want = struct { local: []const u8, src: ?Oid, dst: []const u8, force: bool };

pub fn push(repo: *Repository, remote_name: []const u8, opts: Options, connector: fetch_mod.Connector) !Result {
    var res: Result = .{ .arena = .init(repo.gpa) };
    errdefer res.deinit();
    const a = res.arena.allocator();
    const rem = (try remote_mod.get(repo, a, remote_name)) orelse return error.NoSuchRemote;

    const conn = try connector.connect(connector.ctx, repo, rem.pushUrl(), .receive_pack);
    defer conn.close();
    const adv = try protocol.readAdvertisement(a, conn);
    if (adv.format != repo.format) return error.ObjectFormatMismatch;

    var wants: std.ArrayList(Want) = .empty;
    if (opts.refspecs.len == 0 and !opts.tags) {
        const head = (try repo.headRef(a)) orelse return error.DetachedHead;
        try wants.append(a, .{ .local = head, .src = try repo.refs.resolve(head) orelse return error.UnbornHead, .dst = head, .force = opts.force });
    }
    for (opts.refspecs) |text| try wants.append(a, try resolveSpec(repo, a, try refspec.parse(text), opts.force));
    if (opts.tags) {
        var tags = try repo.refs.iterate(repo.gpa, "refs/tags/");
        defer tags.deinit();
        for (tags.refs) |t| if (t.value == .direct) try wants.append(a, .{ .local = try a.dupe(u8, t.name), .src = t.value.direct, .dst = try a.dupe(u8, t.name), .force = opts.force });
    }

    var results: std.ArrayList(RefResult) = .empty;
    var commands: std.ArrayList(protocol.Command) = .empty;
    var tips: std.ArrayList(Oid) = .empty;
    const zero = Oid.zero(repo.format);
    for (wants.items) |w| {
        const old = remoteValue(adv.refs, w.dst);
        var r: RefResult = .{ .local = w.local, .remote = w.dst, .old = old, .new = w.src, .status = .new };
        if (w.src == null) {
            if (old == null) continue; // deleting what is not there
            r.status = .deleted;
        } else if (old) |o| {
            if (o.eql(w.src.?)) {
                r.status = .up_to_date;
            } else if (opts.force_with_lease) {
                const tracking = try trackingRef(a, rem, w.dst);
                const expect = if (tracking) |t| try repo.refs.resolve(t) else null;
                r.status = if (expect != null and expect.?.eql(o)) .forced else .rejected_stale;
            } else if (std.mem.startsWith(u8, w.dst, "refs/tags/")) {
                r.status = if (w.force) .forced else .rejected_tag_exists;
            } else if (!repo.odb.exists(o)) {
                r.status = if (w.force) .forced else .rejected_fetch_first;
            } else if (try isAncestor(repo, o, w.src.?)) {
                r.status = .fast_forward;
            } else r.status = if (w.force) .forced else .rejected_non_ff;
        }
        try results.append(a, r);
        if (!r.ok() or r.status == .up_to_date) continue;
        try commands.append(a, .{ .ref = w.dst, .old = old orelse zero, .new = w.src orelse zero });
        if (w.src) |s| try tips.append(a, s);
    }
    res.refs = results.items;
    if (commands.items.len == 0 or opts.dry_run) {
        // An empty command list tells receive-pack there is nothing to do.
        try @import("../proto/pktline.zig").PktWriter.init(conn.writer()).flush();
        try conn.endRequest();
        return res;
    }
    if (opts.atomic and !adv.caps.has("atomic")) return error.AtomicUnsupported;

    var pack_bytes: []const u8 = "";
    if (tips.items.len > 0) {
        var haves: std.ArrayList(Oid) = .empty;
        for (adv.refs) |r| try haves.append(a, r.oid);
        const p = try objects.plan(repo, a, tips.items, haves.items);
        var pw: pack_writer.PackWriter = .init(repo.gpa, repo.odb, repo.format);
        defer pw.deinit();
        for (p.send) |it| try pw.add(it.id, .{ .path = it.path });
        var aw: std.Io.Writer.Allocating = .init(a);
        _ = try pw.finish(&aw.writer, .{ .thin_bases = p.thin_bases, .ofs_delta = adv.caps.has("ofs-delta") });
        pack_bytes = aw.written();
    }
    const report = try protocol.sendPack(a, conn, &adv, commands.items, pack_bytes, opts.on_progress, opts.progress_ctx);
    if (!report.unpack_ok) return error.RemoteUnpackFailed;
    for (report.refs) |st| {
        if (st.err == null) continue;
        for (results.items) |*r| if (std.mem.eql(u8, r.remote, st.ref)) {
            r.status = .remote_rejected;
            r.reason = st.err;
        };
    }

    // Remote-tracking refs and upstreams for what went through.
    const now: i64 = @intCast(@divFloor(std.Io.Timestamp.now(repo.io, .real).nanoseconds, std.time.ns_per_s));
    const who = try commit_cmd.ident(repo, a, repo.envMap(), .committer, now, opts.tz_offset_min);
    var tx = repo.refs.transaction();
    defer tx.deinit();
    var any = false;
    for (results.items) |r| {
        if (!r.ok() or r.status == .up_to_date) continue;
        const t = (try trackingRef(a, rem, r.remote)) orelse continue;
        if (r.new) |n| try tx.update(t, .{ .direct = n }, null, "update by push", who) else if ((try repo.refs.resolve(t)) != null) try tx.delete(t, null, "");
        any = true;
    }
    if (any) try tx.commit();
    if (opts.set_upstream) for (results.items) |r| {
        if (!r.ok() or r.new == null or !std.mem.startsWith(u8, r.local, "refs/heads/") or !std.mem.startsWith(u8, r.remote, "refs/heads/")) continue;
        const t = (try trackingRef(a, rem, r.remote)) orelse continue;
        try checkout.setUpstream(repo, r.local["refs/heads/".len..], t);
    };
    return res;
}

fn resolveSpec(repo: *Repository, a: Allocator, s: Refspec, force: bool) !Want {
    if (s.src.len == 0) {
        // ":dst" deletes.
        return .{ .local = "", .src = null, .dst = try fullDst(repo, a, s.dst, null), .force = true };
    }
    const local = try localName(repo, a, s.src);
    const src = try revparse.resolve(repo, s.src);
    const dst = if (s.dst.len > 0) try fullDst(repo, a, s.dst, local) else local orelse return error.DestinationRequired;
    return .{ .local = local orelse "", .src = src, .dst = dst, .force = force or s.force };
}

/// The full local ref `src` names, if it names one.
fn localName(repo: *Repository, a: Allocator, src: []const u8) !?[]const u8 {
    if (std.mem.startsWith(u8, src, "refs/")) return if ((try repo.refs.resolve(src)) != null) src else null;
    if (std.mem.eql(u8, src, "HEAD")) return repo.headRef(a);
    for ([_][]const u8{ "refs/heads/", "refs/tags/" }) |pre| {
        const full = try std.fmt.allocPrint(a, "{s}{s}", .{ pre, src });
        if ((try repo.refs.resolve(full)) != null) return full;
    }
    return null;
}

/// A short destination takes the kind of the source (branch or tag).
fn fullDst(repo: *Repository, a: Allocator, dst: []const u8, local: ?[]const u8) ![]const u8 {
    _ = repo;
    if (std.mem.startsWith(u8, dst, "refs/")) return dst;
    const kind = if (local) |l| (if (std.mem.startsWith(u8, l, "refs/tags/")) "refs/tags/" else "refs/heads/") else "refs/heads/";
    return std.fmt.allocPrint(a, "{s}{s}", .{ kind, dst });
}

fn remoteValue(refs: []const protocol.RemoteRef, name: []const u8) ?Oid {
    for (refs) |r| if (std.mem.eql(u8, r.name, name)) return r.oid;
    return null;
}

/// The remote-tracking ref the remote's fetch refspecs map `remote_ref`
/// to.
fn trackingRef(a: Allocator, rem: remote_mod.Remote, remote_ref: []const u8) !?[]const u8 {
    for (rem.fetch) |s| {
        if (s.negative or s.dst.len == 0) continue;
        if (try s.map(a, remote_ref)) |m| return m;
    }
    return null;
}

fn isAncestor(repo: *Repository, old: Oid, new: Oid) !bool {
    return revwalk.isAncestor(repo, old, new) catch |e| switch (e) {
        error.NotACommit => false,
        else => e,
    };
}
