//! Remotes as `git remote` manages them (E09.F08): `remote.<name>.url`,
//! `pushurl`, `fetch` and `push` refspecs, `tagOpt` and `prune`; adding,
//! removing, renaming and changing URLs, with the remote-tracking refs
//! and `branch.<b>.remote` settings that go with them.

const std = @import("std");
const config_mod = @import("../config.zig");
const refspec = @import("refspec.zig");
const Repository = @import("../repository.zig").Repository;
const Refspec = refspec.Refspec;
const Allocator = std.mem.Allocator;

pub const TagOpt = enum {
    /// Tags pointing into fetched history (git's default).
    auto,
    /// `--tags`: every tag.
    all,
    /// `--no-tags`.
    none,
};

pub const Remote = struct {
    name: []const u8,
    url: []const u8,
    push_url: ?[]const u8 = null,
    fetch: []const Refspec,
    push: []const Refspec = &.{},
    tags: TagOpt = .auto,
    prune: bool = false,

    pub fn pushUrl(r: Remote) []const u8 {
        return r.push_url orelse r.url;
    }
};

/// The remote `name`, or null when it is not configured. Strings live
/// in `a`.
pub fn get(repo: *Repository, a: Allocator, name: []const u8) !?Remote {
    const url_key = try std.fmt.allocPrint(a, "remote.{s}.url", .{name});
    const url = repo.config.get(url_key) orelse return null;
    var fetch: std.ArrayList(Refspec) = .empty;
    for (try repo.config.getAll(a, try std.fmt.allocPrint(a, "remote.{s}.fetch", .{name}))) |v| try fetch.append(a, try refspec.parse(try a.dupe(u8, v)));
    var push: std.ArrayList(Refspec) = .empty;
    for (try repo.config.getAll(a, try std.fmt.allocPrint(a, "remote.{s}.push", .{name}))) |v| try push.append(a, try refspec.parse(try a.dupe(u8, v)));
    const tag_opt = repo.config.get(try std.fmt.allocPrint(a, "remote.{s}.tagopt", .{name}));
    const prune = repo.config.getBool(try std.fmt.allocPrint(a, "remote.{s}.prune", .{name})) orelse
        (repo.config.getBool("fetch.prune") orelse false);
    return .{
        .name = try a.dupe(u8, name),
        .url = try a.dupe(u8, url),
        .push_url = if (repo.config.get(try std.fmt.allocPrint(a, "remote.{s}.pushurl", .{name}))) |p| try a.dupe(u8, p) else null,
        .fetch = fetch.items,
        .push = push.items,
        .tags = if (tag_opt) |t| (if (std.mem.eql(u8, t, "--tags")) .all else if (std.mem.eql(u8, t, "--no-tags")) .none else .auto) else .auto,
        .prune = prune,
    };
}

/// Configured remote names, in config order.
pub fn names(repo: *Repository, a: Allocator) ![]const []const u8 {
    const subs = try repo.config.subsections(a, "remote");
    var out: std.ArrayList([]const u8) = .empty;
    for (subs) |s| if (repo.config.get(try std.fmt.allocPrint(a, "remote.{s}.url", .{s})) != null) try out.append(a, s);
    return out.items;
}

fn configPath(repo: *Repository, a: Allocator) ![]const u8 {
    return std.fs.path.join(a, &.{ repo.common_dir_path, "config" });
}

fn validName(name: []const u8) bool {
    if (name.len == 0 or std.mem.indexOfAny(u8, name, " \t\n\\\"/:*?[~^") != null) return false;
    return !std.mem.startsWith(u8, name, "-") and !std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..");
}

/// `git remote add <name> <url>`.
pub fn add(repo: *Repository, name: []const u8, url: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(repo.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    if (!validName(name)) return error.InvalidRemoteName;
    if (repo.config.subsections(a, "remote")) |subs| {
        for (subs) |s| if (std.mem.eql(u8, s, name)) return error.RemoteExists;
    } else |e| return e;
    const cfg = try configPath(repo, a);
    try config_mod.setValue(repo.gpa, repo.io, cfg, try std.fmt.allocPrint(a, "remote.{s}.url", .{name}), url);
    try config_mod.addValue(repo.gpa, repo.io, cfg, try std.fmt.allocPrint(a, "remote.{s}.fetch", .{name}), try refspec.defaultFetch(a, name));
    try repo.reloadConfig(.{ .env = repo.env });
}

/// `git remote set-url [--push] <name> <url>`.
pub fn setUrl(repo: *Repository, name: []const u8, url: []const u8, push: bool) !void {
    var arena: std.heap.ArenaAllocator = .init(repo.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    if ((try get(repo, a, name)) == null) return error.NoSuchRemote;
    try config_mod.setValue(repo.gpa, repo.io, try configPath(repo, a), try std.fmt.allocPrint(a, "remote.{s}.{s}", .{ name, if (push) "pushurl" else "url" }), url);
    try repo.reloadConfig(.{ .env = repo.env });
}

/// `git remote remove <name>`: the config section, its remote-tracking
/// refs, and branches' upstream settings that name it.
pub fn remove(repo: *Repository, name: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(repo.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const r = (try get(repo, a, name)) orelse return error.NoSuchRemote;
    const cfg = try configPath(repo, a);
    try config_mod.renameSection(repo.gpa, repo.io, cfg, "remote", name, null);
    for (try repo.config.subsections(a, "branch")) |b| {
        const key = try std.fmt.allocPrint(a, "branch.{s}.remote", .{b});
        const v = repo.config.get(key) orelse continue;
        if (!std.mem.eql(u8, v, name)) continue;
        try config_mod.setValue(repo.gpa, repo.io, cfg, key, null);
        const merge_key = try std.fmt.allocPrint(a, "branch.{s}.merge", .{b});
        if (repo.config.get(merge_key) != null) try config_mod.setValue(repo.gpa, repo.io, cfg, merge_key, null);
    }
    try repo.reloadConfig(.{ .env = repo.env });
    // Every ref a fetch refspec of this remote writes.
    var refs = try repo.refs.iterate(repo.gpa, "refs/remotes/");
    defer refs.deinit();
    var tx = repo.refs.transaction();
    defer tx.deinit();
    var any = false;
    for (refs.refs) |ref| {
        for (r.fetch) |spec| {
            if (spec.negative or spec.dst.len == 0) continue;
            const dst: Refspec = .{ .src = spec.dst };
            if (!dst.matches(ref.name)) continue;
            try tx.delete(ref.name, null, "remote: remove");
            any = true;
            break;
        }
    }
    if (any) try tx.commit();
}

/// `git remote rename <old> <new>`: the section, default fetch refspecs,
/// remote-tracking refs and branch upstreams move to the new name.
pub fn rename(repo: *Repository, old: []const u8, new: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(repo.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    if (!validName(new)) return error.InvalidRemoteName;
    const r = (try get(repo, a, old)) orelse return error.NoSuchRemote;
    if ((try get(repo, a, new)) != null) return error.RemoteExists;
    const cfg = try configPath(repo, a);
    try config_mod.renameSection(repo.gpa, repo.io, cfg, "remote", old, new);
    const old_default = try refspec.defaultFetch(a, old);
    const fetch_key = try std.fmt.allocPrint(a, "remote.{s}.fetch", .{new});
    var rewritten = false;
    for (try repo.config.getAll(a, try std.fmt.allocPrint(a, "remote.{s}.fetch", .{old}))) |v| {
        if (std.mem.eql(u8, v, old_default)) rewritten = true;
    }
    if (rewritten) {
        // Rewrite the default refspec, keep the others as they were.
        const values = try repo.config.getAll(a, try std.fmt.allocPrint(a, "remote.{s}.fetch", .{old}));
        try config_mod.setValue(repo.gpa, repo.io, cfg, fetch_key, null);
        for (values) |v| try config_mod.addValue(repo.gpa, repo.io, cfg, fetch_key, if (std.mem.eql(u8, v, old_default)) try refspec.defaultFetch(a, new) else v);
    }
    for (try repo.config.subsections(a, "branch")) |b| {
        const key = try std.fmt.allocPrint(a, "branch.{s}.remote", .{b});
        const v = repo.config.get(key) orelse continue;
        if (std.mem.eql(u8, v, old)) try config_mod.setValue(repo.gpa, repo.io, cfg, key, new);
    }
    try repo.reloadConfig(.{ .env = repo.env });

    if (!rewritten) return;
    _ = r;
    const old_prefix = try std.fmt.allocPrint(a, "refs/remotes/{s}/", .{old});
    var refs = try repo.refs.iterate(repo.gpa, old_prefix);
    defer refs.deinit();
    if (refs.refs.len == 0) return;
    var tx = repo.refs.transaction();
    defer tx.deinit();
    const who = try @import("../commit_cmd.zig").ident(repo, a, repo.envMap(), .committer, @intCast(@divFloor(std.Io.Timestamp.now(repo.io, .real).nanoseconds, std.time.ns_per_s)), 0);
    for (refs.refs) |ref| {
        const to = try std.fmt.allocPrint(a, "refs/remotes/{s}/{s}", .{ new, ref.name[old_prefix.len..] });
        switch (ref.value) {
            .direct => |id| try tx.update(to, .{ .direct = id }, null, try std.fmt.allocPrint(a, "remote: renamed {s} to {s}", .{ ref.name, to }), who),
            .symbolic => |target| {
                const t = if (std.mem.startsWith(u8, target, old_prefix)) try std.fmt.allocPrint(a, "refs/remotes/{s}/{s}", .{ new, target[old_prefix.len..] }) else target;
                try tx.update(to, .{ .symbolic = t }, null, "", who);
            },
        }
        try tx.delete(ref.name, null, "");
    }
    try tx.commit();
}
