//! `git pull` on a git repository (E09.F09.S01.T01): fetches the
//! current branch's upstream remote, then merges or rebases onto what
//! FETCH_HEAD marks for merging, following `pull.rebase`,
//! `branch.<name>.rebase` and `pull.ff`.

const std = @import("std");
const git = @import("zg_git");
const common = @import("common.zig");
const merge_mod = @import("merge.zig");
const rebase_mod = @import("rebase.zig");
const Repository = git.Repository;
const Oid = git.oid.Oid;
const Allocator = std.mem.Allocator;
const fetch_mod = git.remote.fetch;

pub const Mode = enum { merge, rebase };
pub const Ff = enum { allow, only, never };

pub const Options = struct {
    /// null: `branch.<name>.rebase`, then `pull.rebase` (default merge).
    mode: ?Mode = null,
    /// null: `pull.ff` (default allow).
    ff: ?Ff = null,
    /// The reflog prefix git uses: "pull" plus the command's arguments.
    reflog_action: []const u8 = "pull",
    tz_offset_min: i32 = 0,
    blocked: common.Blocked = .{},
    signing: common.Signing = .{},
    on_progress: ?git.proto.sideband.ProgressFn = null,
    progress_ctx: ?*anyopaque = null,
};

pub const Result = struct {
    inner: common.Result,
    /// Objects fetched.
    objects: usize = 0,
    mode: Mode = .merge,

    pub fn deinit(r: *Result) void {
        r.inner.deinit();
    }
};

fn configBool(repo: *Repository, key: []const u8) ?bool {
    const v = repo.config.get(key) orelse return null;
    // "merges" and "interactive" also mean rebase.
    if (std.ascii.eqlIgnoreCase(v, "merges") or std.ascii.eqlIgnoreCase(v, "interactive") or std.ascii.eqlIgnoreCase(v, "i") or std.ascii.eqlIgnoreCase(v, "m")) return true;
    return repo.config.getBool(key);
}

/// Pulls into the current branch.
pub fn pull(repo: *Repository, connector: fetch_mod.Connector, opts: Options) !Result {
    var arena: std.heap.ArenaAllocator = .init(repo.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const branch = (try common.branchName(repo, a)) orelse return error.DetachedHead;
    var kb: [512]u8 = undefined;
    const remote = repo.config.get(try std.fmt.bufPrint(&kb, "branch.{s}.remote", .{branch})) orelse "origin";
    if (repo.config.get(try std.fmt.bufPrint(&kb, "branch.{s}.merge", .{branch})) == null) return error.NoUpstream;
    const mode = opts.mode orelse blk: {
        const r = configBool(repo, try std.fmt.bufPrint(&kb, "branch.{s}.rebase", .{branch})) orelse configBool(repo, "pull.rebase") orelse false;
        break :blk if (r) Mode.rebase else Mode.merge;
    };
    const ff = opts.ff orelse blk: {
        const v = repo.config.get("pull.ff") orelse break :blk Ff.allow;
        if (std.ascii.eqlIgnoreCase(v, "only")) break :blk Ff.only;
        break :blk if (repo.config.getBool("pull.ff") orelse true) Ff.allow else Ff.never;
    };

    var fr = try fetch_mod.fetch(repo, remote, .{ .reflog_action = opts.reflog_action, .on_progress = opts.on_progress, .progress_ctx = opts.progress_ctx }, connector);
    defer fr.deinit();
    const objects = fr.objects;

    const target, const what = try forMerge(repo, a);
    var hb: [64]u8 = undefined;
    const hex = try a.dupe(u8, target.hex(&hb));
    var res: Result = .{ .inner = undefined, .objects = objects, .mode = mode };
    switch (mode) {
        .rebase => res.inner = try rebase_mod.rebase(repo, hex, .{
            .tz_offset_min = opts.tz_offset_min,
            .blocked = opts.blocked,
            .signing = opts.signing,
            .reflog_action = opts.reflog_action,
        }),
        .merge => {
            const into: []const u8 = if (std.mem.eql(u8, branch, "main") or std.mem.eql(u8, branch, "master")) "" else try std.fmt.allocPrint(a, " into {s}", .{branch});
            res.inner = try merge_mod.merge(repo, hex, .{
                .ff = switch (ff) {
                    .allow => .allow,
                    .only => .only,
                    .never => .never,
                },
                .message = try std.fmt.allocPrint(a, "Merge {s}{s}\n", .{ what, into }),
                .tz_offset_min = opts.tz_offset_min,
                .blocked = opts.blocked,
                .signing = opts.signing,
                .reflog_action = opts.reflog_action,
                .label = hex,
            });
        },
    }
    return res;
}

/// The first FETCH_HEAD entry not marked not-for-merge, and its
/// description ("branch 'main' of <url>").
fn forMerge(repo: *Repository, a: Allocator) !struct { Oid, []const u8 } {
    const text = repo.git_dir.readFileAlloc(repo.io, "FETCH_HEAD", a, .limited(16 << 20)) catch return error.NothingToMerge;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        const id_s = fields.next() orelse continue;
        const flag = fields.next() orelse continue;
        const desc = fields.rest();
        if (flag.len != 0) continue;
        const id = Oid.parseHex(repo.format, id_s) catch continue;
        return .{ id, desc };
    }
    return error.NothingToMerge;
}
