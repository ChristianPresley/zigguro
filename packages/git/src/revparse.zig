//! Revision names (E09.F07, `git rev-parse`): `HEAD`/`@`, branch, tag and
//! remote names in git's lookup order, full and abbreviated object ids,
//! `@{-N}` (the Nth branch checked out before), `<branch>@{u}`, and the
//! suffixes `~N`, `^N`, `^{commit}`, `^{tree}`, `^{}` and `:<path>`.

const std = @import("std");
const commit_mod = @import("commit.zig");
const tag_mod = @import("tag.zig");
const tree_mod = @import("tree.zig");
const loose = @import("loose.zig");
const Repository = @import("repository.zig").Repository;
const oid_mod = @import("oid.zig");
const Oid = oid_mod.Oid;
const Allocator = std.mem.Allocator;

pub const Error = error{ UnknownRevision, AmbiguousObjectName, NoUpstream };

/// The object `spec` names.
pub fn resolve(repo: *Repository, spec: []const u8) !Oid {
    var arena: std.heap.ArenaAllocator = .init(repo.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // "<rev>:<path>" names a file or directory in a commit's tree.
    if (pathSplit(spec)) |colon| {
        const base = if (colon == 0) "HEAD" else spec[0..colon];
        const tree = try peel(repo, a, try resolve(repo, base), .tree);
        return lookupPath(repo, a, tree, spec[colon + 1 ..]);
    }
    var end = spec.len;
    // Suffixes start at the first '~' or '^' after the base.
    if (std.mem.indexOfAny(u8, spec, "~^")) |i| end = i;
    var cur = try resolveBase(repo, a, spec[0..end]);
    var i = end;
    while (i < spec.len) {
        const c = spec[i];
        i += 1;
        if (c == '^' and i < spec.len and spec[i] == '{') {
            const close = std.mem.indexOfScalarPos(u8, spec, i, '}') orelse return error.UnknownRevision;
            const what = spec[i + 1 .. close];
            i = close + 1;
            cur = if (what.len == 0) try peel(repo, a, cur, .any) else if (std.mem.eql(u8, what, "commit")) try peel(repo, a, cur, .commit) else if (std.mem.eql(u8, what, "tree")) try peel(repo, a, cur, .tree) else return error.UnknownRevision;
            continue;
        }
        var n: u32 = 1;
        const ds = i;
        while (i < spec.len and std.ascii.isDigit(spec[i])) i += 1;
        if (i > ds) n = std.fmt.parseInt(u32, spec[ds..i], 10) catch return error.UnknownRevision;
        cur = try peel(repo, a, cur, .commit);
        if (c == '~') {
            var k: u32 = 0;
            while (k < n) : (k += 1) {
                const ps = try parentsOf(repo, a, cur);
                if (ps.len == 0) return error.UnknownRevision;
                cur = ps[0];
            }
        } else if (c == '^') {
            if (n == 0) continue;
            const ps = try parentsOf(repo, a, cur);
            if (n > ps.len) return error.UnknownRevision;
            cur = ps[n - 1];
        } else return error.UnknownRevision;
    }
    return cur;
}

/// The commit `spec` names (tags peeled).
pub fn resolveCommit(repo: *Repository, spec: []const u8) !Oid {
    var arena: std.heap.ArenaAllocator = .init(repo.gpa);
    defer arena.deinit();
    return peel(repo, arena.allocator(), try resolve(repo, spec), .commit);
}

/// Where ':' splits "<rev>:<path>" (not inside "@{...}").
fn pathSplit(spec: []const u8) ?usize {
    var depth: u32 = 0;
    for (spec, 0..) |c, i| switch (c) {
        '{' => depth += 1,
        '}' => depth -|= 1,
        ':' => if (depth == 0) return i,
        else => {},
    };
    return null;
}

fn resolveBase(repo: *Repository, a: Allocator, base0: []const u8) !Oid {
    var base = base0;
    if (base.len == 0 or std.mem.eql(u8, base, "@")) base = "HEAD";
    if (std.mem.indexOf(u8, base, "@{")) |at| {
        const inner = std.mem.trimEnd(u8, base[at + 2 ..], "}");
        const name = base[0..at];
        if (std.mem.eql(u8, inner, "u") or std.mem.eql(u8, inner, "upstream")) {
            const up = try upstreamRef(repo, a, if (name.len == 0) null else name);
            return (try repo.refs.resolve(up)) orelse error.NoUpstream;
        }
        if (name.len == 0 and inner.len > 1 and inner[0] == '-') {
            const n = std.fmt.parseInt(u32, inner[1..], 10) catch return error.UnknownRevision;
            const b = try previousBranch(repo, a, n);
            return resolveBase(repo, a, b);
        }
        return error.UnknownRevision;
    }
    if (try dwim(repo, a, base)) |id| return id;
    if (base.len >= 4 and base.len <= repo.format.hexLen() and isHex(base)) return byPrefix(repo, base);
    return error.UnknownRevision;
}

/// git's ref lookup order for a short name.
fn dwim(repo: *Repository, a: Allocator, name: []const u8) !?Oid {
    if (std.mem.eql(u8, name, "HEAD") or std.mem.eql(u8, name, "FETCH_HEAD") or std.mem.eql(u8, name, "ORIG_HEAD") or std.mem.eql(u8, name, "MERGE_HEAD")) {
        return repo.refs.resolve(name);
    }
    const forms = [_][]const u8{ "{s}", "refs/{s}", "refs/tags/{s}", "refs/heads/{s}", "refs/remotes/{s}", "refs/remotes/{s}/HEAD" };
    inline for (forms) |f| {
        // A full name is only taken as written when it starts with refs/.
        if (!(std.mem.eql(u8, f, "{s}") and !std.mem.startsWith(u8, name, "refs/"))) {
            const full = try std.fmt.allocPrint(a, f, .{name});
            if (repo.refs.resolve(full) catch null) |id| return id;
        }
    }
    return null;
}

/// The remote-tracking ref `branch` (default: the current one) follows.
pub fn upstreamRef(repo: *Repository, a: Allocator, branch: ?[]const u8) ![]const u8 {
    const b = branch orelse blk: {
        const r = (try repo.headRef(a)) orelse return error.NoUpstream;
        if (!std.mem.startsWith(u8, r, "refs/heads/")) return error.NoUpstream;
        break :blk r["refs/heads/".len..];
    };
    const remote = repo.config.get(try std.fmt.allocPrint(a, "branch.{s}.remote", .{b})) orelse return error.NoUpstream;
    const merge = repo.config.get(try std.fmt.allocPrint(a, "branch.{s}.merge", .{b})) orelse return error.NoUpstream;
    if (std.mem.eql(u8, remote, ".")) return merge;
    const short = if (std.mem.startsWith(u8, merge, "refs/heads/")) merge["refs/heads/".len..] else merge;
    return std.fmt.allocPrint(a, "refs/remotes/{s}/{s}", .{ remote, short });
}

/// The branch checked out `n` switches ago, from HEAD's reflog.
pub fn previousBranch(repo: *Repository, a: Allocator, n: u32) ![]const u8 {
    const text = repo.git_dir.readFileAlloc(repo.io, "logs/HEAD", a, .limited(64 << 20)) catch return error.UnknownRevision;
    var lines = std.mem.splitBackwardsScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    var k: u32 = 0;
    const marker = "\tcheckout: moving from ";
    while (lines.next()) |l| {
        const at = std.mem.indexOf(u8, l, marker) orelse continue;
        k += 1;
        if (k != n) continue;
        const rest = l[at + marker.len ..];
        const to = std.mem.indexOf(u8, rest, " to ") orelse return error.UnknownRevision;
        return rest[0..to];
    }
    return error.UnknownRevision;
}

fn isHex(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

/// The one object whose id starts with `hex`.
pub fn byPrefix(repo: *Repository, hex_in: []const u8) !Oid {
    var lower: [64]u8 = undefined;
    const hex = std.ascii.lowerString(&lower, hex_in);
    var found: ?Oid = null;
    if (hex.len == repo.format.hexLen()) return Oid.parseHex(repo.format, hex) catch error.UnknownRevision;
    // Loose objects: objects/<2>/<rest>.
    var dir_buf: [2]u8 = hex[0..2].*;
    if (repo.objects.openDir(repo.io, &dir_buf, .{ .iterate = true })) |d_| {
        var d = d_;
        defer d.close(repo.io);
        var it = d.iterate();
        while (try it.next(repo.io)) |e| {
            if (!std.mem.startsWith(u8, e.name, hex[2..])) continue;
            var full: [64]u8 = undefined;
            @memcpy(full[0..2], hex[0..2]);
            const len = @min(e.name.len, 62);
            @memcpy(full[2 .. 2 + len], e.name[0..len]);
            const id = Oid.parseHex(repo.format, full[0 .. 2 + len]) catch continue;
            if (found) |f| if (!f.eql(id)) return error.AmbiguousObjectName;
            found = id;
        }
    } else |_| {}
    // Packs: a lower bound on the prefix's bytes, then matching names.
    var key: [32]u8 = @splat(0);
    for (0..hex.len / 2) |i| key[i] = std.fmt.parseInt(u8, hex[i * 2 ..][0..2], 16) catch unreachable;
    if (hex.len % 2 == 1) key[hex.len / 2] = (std.fmt.charToDigit(hex[hex.len - 1], 16) catch unreachable) << 4;
    for (repo.odb.packs.items) |p| {
        const ix = &p.index;
        var lo: u32 = 0;
        var hi: u32 = ix.count();
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (std.mem.order(u8, ix.oidAt(mid).slice(), key[0..repo.format.len()]) == .lt) lo = mid + 1 else hi = mid;
        }
        var pos = lo;
        while (pos < ix.count()) : (pos += 1) {
            const id = ix.oidAt(pos);
            var hb: [64]u8 = undefined;
            if (!std.mem.startsWith(u8, id.hex(&hb), hex)) break;
            if (found) |f| if (!f.eql(id)) return error.AmbiguousObjectName;
            found = id;
        }
    }
    return found orelse error.UnknownRevision;
}

const PeelTo = enum { any, commit, tree };

/// Follows tags (and a commit to its tree for `.tree`).
pub fn peel(repo: *Repository, a: Allocator, id0: Oid, to: PeelTo) !Oid {
    var id = id0;
    var depth: u8 = 0;
    while (depth < 32) : (depth += 1) {
        const obj = try repo.odb.read(a, id);
        switch (obj.type) {
            .tag => id = (try tag_mod.parseTag(a, repo.format, obj.data)).object,
            .commit => return if (to == .tree) (try commit_mod.parseCommit(a, repo.format, obj.data)).tree else id,
            .tree => return if (to == .commit) error.NotACommit else id,
            else => return if (to == .any) id else error.UnknownRevision,
        }
    }
    return error.UnknownRevision;
}

fn parentsOf(repo: *Repository, a: Allocator, id: Oid) ![]const Oid {
    const obj = try repo.odb.read(a, id);
    if (obj.type != .commit) return error.NotACommit;
    return (try commit_mod.parseCommit(a, repo.format, obj.data)).parents;
}

/// The object at `path` ('/'-separated) under `tree`.
pub fn lookupPath(repo: *Repository, a: Allocator, tree: Oid, path: []const u8) !Oid {
    var cur = tree;
    var parts = std.mem.tokenizeScalar(u8, path, '/');
    while (parts.next()) |name| {
        const obj = try repo.odb.read(a, cur);
        if (obj.type != .tree) return error.UnknownRevision;
        var it = tree_mod.parseTree(repo.format, obj.data);
        cur = while (try it.next()) |e| {
            if (std.mem.eql(u8, e.name, name)) break e.oid;
        } else return error.UnknownRevision;
    }
    return cur;
}

const testing = std.testing;

test "revparse: names, suffixes, prefixes, paths, upstream and @{-1}" {
    const gpa = testing.allocator;
    const io = testing.io;
    const stage = @import("stage.zig");
    const commit_cmd = @import("commit_cmd.zig");
    const t = try stage.TestRepo.init(gpa, io);
    defer t.deinit(gpa);
    try t.env.put("GIT_COMMITTER_DATE", "@1700000000 +0000");
    var ids: [3]Oid = undefined;
    for (0..3) |i| {
        var buf: [8]u8 = undefined;
        try t.tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = try std.fmt.bufPrint(&buf, "{d}\n", .{i}) });
        _ = try stage.add(t.repo, &.{}, .{});
        var r = try commit_cmd.commit(t.repo, .{ .message = "c", .env = &t.env, .now = 1700000000 + @as(i64, @intCast(i)) });
        defer r.deinit(gpa);
        ids[i] = r.oid;
    }
    try testing.expect((try resolve(t.repo, "HEAD")).eql(ids[2]));
    try testing.expect((try resolve(t.repo, "@")).eql(ids[2]));
    try testing.expect((try resolve(t.repo, "main~2")).eql(ids[0]));
    try testing.expect((try resolve(t.repo, "HEAD^^")).eql(ids[0]));
    try testing.expect((try resolve(t.repo, "HEAD^1~1")).eql(ids[0]));
    try testing.expectError(error.UnknownRevision, resolve(t.repo, "HEAD~3"));
    var hb: [64]u8 = undefined;
    const hex = ids[1].hex(&hb);
    try testing.expect((try resolve(t.repo, hex[0..7])).eql(ids[1]));
    try testing.expect((try resolve(t.repo, hex)).eql(ids[1]));
    // A path in a commit.
    const blob = try resolve(t.repo, "HEAD~1:f.txt");
    try testing.expect(blob.eql(@import("object.zig").hashObject(.sha1, .blob, "1\n")));
    try testing.expectError(error.UnknownRevision, resolve(t.repo, "nope"));

    // Upstream through config, previous branch through the reflog.
    try t.tmp.dir.createDirPath(io, ".git/refs/remotes/origin");
    var line: [80]u8 = undefined;
    try t.tmp.dir.writeFile(io, .{ .sub_path = ".git/refs/remotes/origin/main", .data = try std.fmt.bufPrint(&line, "{s}\n", .{ids[0].hex(&hb)}) });
    try t.tmp.dir.writeFile(io, .{ .sub_path = ".git/config", .data = "[branch \"main\"]\n\tremote = origin\n\tmerge = refs/heads/main\n" });
    try t.repo.reloadConfig(.{ .env = &t.env });
    try testing.expect((try resolve(t.repo, "@{u}")).eql(ids[0]));
    try testing.expect((try resolve(t.repo, "main@{upstream}~0")).eql(ids[0]));
    const log_line = "0000000000000000000000000000000000000000 1111111111111111111111111111111111111111 A <a> 1 +0000\tcheckout: moving from main to topic\n";
    try t.tmp.dir.writeFile(io, .{ .sub_path = ".git/logs/HEAD", .data = log_line });
    try testing.expect((try resolve(t.repo, "@{-1}")).eql(ids[2]));
}
