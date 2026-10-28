//! `git submodule` (E09.F07): add, init, update, sync, deinit and
//! status, laid out the way git lays submodules out: the module's
//! repository in `$GIT_COMMON_DIR/modules/<name>` with `core.worktree`
//! pointing back at the working tree, a `gitdir:` file at `<path>/.git`,
//! `.gitmodules` (name, path, url) in the superproject and
//! `submodule.<name>.url`/`.active` in its config. Relative URLs
//! (`./x`, `../x`) are taken against the superproject's default remote,
//! or its folder when it has none. `foreach`, `--recursive` and the
//! update modes other than checkout are not supported.

const std = @import("std");
const config_mod = @import("config.zig");
const init_repo = @import("init.zig");
const fetch_mod = @import("remote/fetch.zig");
const checkout = @import("checkout.zig");
const stage = @import("stage.zig");
const status_mod = @import("status.zig");
const worktree = @import("worktree.zig");
const index_mod = @import("index/index.zig");
const tree_mod = @import("tree.zig");
const revparse = @import("revparse.zig");
const Repository = @import("repository.zig").Repository;
const Oid = @import("oid.zig").Oid;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;

/// One `[submodule "<name>"]` of `.gitmodules`.
pub const Module = struct {
    name: []const u8,
    path: []const u8,
    url: ?[]const u8 = null,
    branch: ?[]const u8 = null,
};

pub const Options = struct {
    env: ?*const std.process.Environ.Map = null,
    tz_offset_min: i32 = 0,
    /// Gets git's stderr lines ("Cloning into '<path>'...").
    err: ?*Writer = null,
};

/// The modules `.gitmodules` in the working tree lists (owned by `a`).
pub fn list(repo: *Repository, a: Allocator) ![]Module {
    const text = repo.work.readFileAlloc(repo.io, ".gitmodules", a, .limited(1 << 20)) catch |e| switch (e) {
        error.FileNotFound => return &.{},
        else => return e,
    };
    var c = config_mod.Config.init(a);
    try c.parse(text, ".gitmodules", .local, 0);
    var out: std.ArrayList(Module) = .empty;
    for (try c.subsections(a, "submodule")) |name| {
        const path = c.get(try key(a, name, "path")) orelse continue;
        try out.append(a, .{ .name = name, .path = path, .url = c.get(try key(a, name, "url")), .branch = c.get(try key(a, name, "branch")) });
    }
    return out.items;
}

fn key(a: Allocator, name: []const u8, k: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "submodule.{s}.{s}", .{ name, k });
}

/// The modules whose path is in `paths` (all when empty).
fn select(a: Allocator, mods: []const Module, paths: []const []const u8) ![]const Module {
    if (paths.len == 0) return mods;
    var out: std.ArrayList(Module) = .empty;
    for (paths) |p_in| {
        const p = std.mem.trimEnd(u8, p_in, "/");
        for (mods) |m| if (std.mem.eql(u8, m.path, p)) {
            try out.append(a, m);
            break;
        } else return error.NoSuchSubmodule;
    }
    return out.items;
}

/// `url` made absolute: `./x` and `../x` against the superproject's
/// default remote's URL, or its folder.
pub fn resolveUrl(repo: *Repository, a: Allocator, url: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, url, "./") and !std.mem.startsWith(u8, url, "../")) return url;
    var base: []const u8 = repo.root;
    const remote = blk: {
        if (try repo.headRef(a)) |r| if (std.mem.startsWith(u8, r, "refs/heads/")) {
            if (repo.config.get(try std.fmt.allocPrint(a, "branch.{s}.remote", .{r["refs/heads/".len..]}))) |rm| break :blk rm;
        };
        break :blk "origin";
    };
    if (repo.config.get(try std.fmt.allocPrint(a, "remote.{s}.url", .{remote}))) |u| base = u;
    base = std.mem.trimEnd(u8, base, "/");
    var rest = url;
    while (true) {
        if (std.mem.startsWith(u8, rest, "./")) {
            rest = rest[2..];
        } else if (std.mem.startsWith(u8, rest, "../")) {
            rest = rest[3..];
            // Up one: past the last '/' (or the ':' of host:path).
            const cut = std.mem.lastIndexOfAny(u8, base, "/:") orelse return error.InvalidUrl;
            base = base[0..cut];
        } else break;
    }
    const sep: []const u8 = if (base.len > 0 and base[base.len - 1] == ':') "" else "/";
    return std.fmt.allocPrint(a, "{s}{s}{s}", .{ base, sep, rest });
}

fn modulesDir(repo: *Repository, a: Allocator, name: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ repo.common_dir_path, "modules", name });
}

fn exists(io: Io, path: []const u8) bool {
    _ = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

/// `count` copies of "../".
fn ups(a: Allocator, count: usize) ![]const u8 {
    const s = try a.alloc(u8, count * 3);
    for (0..count) |i| @memcpy(s[i * 3 ..][0..3], "../");
    return s;
}

fn depth(path: []const u8) usize {
    var n: usize = 1;
    for (path) |c| if (c == '/') {
        n += 1;
    };
    return n;
}

/// Points `<path>/.git` at the module's repository and the repository's
/// `core.worktree` back at `<path>`, with relative paths as git writes
/// them.
fn connect(repo: *Repository, a: Allocator, m: Module, gitdir: []const u8) !void {
    const io = repo.io;
    const default_gd = try std.fs.path.join(a, &.{ repo.root, ".git" });
    const plain = std.mem.eql(u8, repo.common_dir_path, default_gd);
    const gitfile = if (plain)
        try std.fmt.allocPrint(a, "gitdir: {s}.git/modules/{s}\n", .{ try ups(a, depth(m.path)), m.name })
    else
        try std.fmt.allocPrint(a, "gitdir: {s}\n", .{gitdir});
    try repo.work.writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ m.path, ".git" }), .data = gitfile });
    const wt = if (plain)
        try std.fmt.allocPrint(a, "{s}{s}", .{ try ups(a, depth(m.name) + 2), m.path })
    else
        try std.fs.path.join(a, &.{ repo.root, m.path });
    try config_mod.setValue(a, io, try std.fs.path.join(a, &.{ gitdir, "config" }), "core.worktree", wt);
}

/// Clones `url` for module `m` into its own repository under
/// `modules/<name>` with the working tree at its path; returns the
/// checked-out commit.
fn cloneModule(repo: *Repository, a: Allocator, m: Module, url: []const u8, connector: fetch_mod.Connector, opts: Options) !Oid {
    const io = repo.io;
    const abs = try std.fs.path.join(a, &.{ repo.root, m.path });
    if (opts.err) |w| try w.print("Cloning into '{s}'...\n", .{abs});
    const sub = try init_repo.clone(repo.gpa, io, url, abs, connector, .{ .env = opts.env, .tz_offset_min = opts.tz_offset_min, .branch = m.branch });
    const head = (try sub.head()) orelse Oid.zero(repo.format);
    sub.close();
    // Move the repository next to the superproject's.
    const gitdir = try modulesDir(repo, a, m.name);
    if (std.fs.path.dirname(gitdir)) |parent| try Io.Dir.cwd().createDirPath(io, parent);
    try Io.Dir.cwd().rename(try std.fs.path.join(a, &.{ abs, ".git" }), Io.Dir.cwd(), gitdir, io);
    try connect(repo, a, m, gitdir);
    if (opts.err) |w| try w.writeAll("done.\n");
    return head;
}

pub const AddOptions = struct {
    name: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    common: Options = .{},
};

/// `git submodule add [-b <branch>] [--name <name>] <url> [<path>]`:
/// clones, records it in `.gitmodules` and the config, and stages
/// `.gitmodules` and the submodule.
pub fn add(repo: *Repository, gpa: Allocator, url: []const u8, path_in: ?[]const u8, connector: fetch_mod.Connector, opts: AddOptions) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const io = repo.io;
    const path = if (path_in) |p| std.mem.trim(u8, p, "/") else blk: {
        var base = std.mem.trimEnd(u8, url, "/");
        base = base[(std.mem.lastIndexOfAny(u8, base, "/:") orelse return error.MissingPath) + 1 ..];
        if (std.mem.endsWith(u8, base, ".git")) base = base[0 .. base.len - 4];
        break :blk base;
    };
    if (path.len == 0) return error.MissingPath;
    var ix = try repo.readIndex();
    defer ix.deinit();
    if (ix.find(path, 0) != null or ix.hasUnder(path)) return error.AlreadyInIndex;
    const name = opts.name orelse path;
    const m: Module = .{ .name = name, .path = path, .url = url, .branch = opts.branch };
    if (exists(io, try modulesDir(repo, a, name))) return error.ModuleDirExists;
    const resolved = try resolveUrl(repo, a, url);
    const head = try cloneModule(repo, a, m, resolved, connector, opts.common);

    const gm = try std.fs.path.join(a, &.{ repo.root, ".gitmodules" });
    try config_mod.setValue(a, io, gm, try key(a, name, "path"), path);
    try config_mod.setValue(a, io, gm, try key(a, name, "url"), url);
    if (opts.branch) |b| try config_mod.setValue(a, io, gm, try key(a, name, "branch"), b);
    const cfg = try std.fs.path.join(a, &.{ repo.git_dir_path, "config" });
    try config_mod.setValue(a, io, cfg, try key(a, name, "url"), resolved);
    try config_mod.setValue(a, io, cfg, try key(a, name, "active"), "true");
    try repo.reloadConfig(.{ .env = opts.common.env });

    _ = try stage.addInto(repo, &ix, &.{".gitmodules"}, .{});
    try ix.add(.{ .mode = tree_mod.mode_gitlink, .oid = head, .path = path });
    try repo.writeIndex(&ix);
}

/// `git submodule init [<path>...]`: copies each URL from `.gitmodules`
/// into the config (resolved) and marks the module active.
pub fn initModules(repo: *Repository, gpa: Allocator, paths: []const []const u8, opts: Options) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg = try std.fs.path.join(a, &.{ repo.git_dir_path, "config" });
    var changed = false;
    for (try select(a, try list(repo, a), paths)) |m| {
        if (repo.config.get(try key(a, m.name, "url")) != null) continue;
        const url = try resolveUrl(repo, a, m.url orelse return error.NoUrl);
        try config_mod.setValue(a, repo.io, cfg, try key(a, m.name, "active"), "true");
        try config_mod.setValue(a, repo.io, cfg, try key(a, m.name, "url"), url);
        // git says this on stderr.
        if (opts.err) |w| try w.print("Submodule '{s}' ({s}) registered for path '{s}'\n", .{ m.name, url, m.path });
        changed = true;
    }
    if (changed) try repo.reloadConfig(.{ .env = opts.env });
}

pub const UpdateOptions = struct {
    /// `--init`.
    init: bool = false,
    /// `--recursive`: the submodules' own submodules too.
    recursive: bool = false,
    common: Options = .{},
    /// Where this repository sits in the outermost one (for messages).
    prefix: []const u8 = "",
};

/// `git submodule update [--init] [<path>...]`: clones what is missing
/// and checks out (detached) the commit the superproject records.
pub fn update(repo: *Repository, gpa: Allocator, paths: []const []const u8, connector: fetch_mod.Connector, opts: UpdateOptions, out: *Writer) !void {
    if (opts.init) try initModules(repo, gpa, paths, opts.common);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const io = repo.io;
    var ix = try repo.readIndex();
    defer ix.deinit();
    var hb: [64]u8 = undefined;
    for (try select(a, try list(repo, a), paths)) |m| {
        const url = repo.config.get(try key(a, m.name, "url")) orelse continue;
        const i = ix.find(m.path, 0) orelse continue;
        const want = ix.entries.items[i].oid;
        if (ix.entries.items[i].mode != tree_mod.mode_gitlink) continue;
        const abs = try std.fs.path.join(a, &.{ repo.root, m.path });
        const gitdir = try modulesDir(repo, a, m.name);
        var fresh = false;
        if (!exists(io, try std.fs.path.join(a, &.{ abs, ".git" }))) {
            try Io.Dir.cwd().createDirPath(io, abs);
            if (exists(io, gitdir)) {
                try connect(repo, a, m, gitdir);
            } else _ = try cloneModule(repo, a, m, url, connector, opts.common);
            fresh = true;
        }
        const sub = try Repository.open(repo.gpa, io, abs, gitdir, .{ .env = opts.common.env });
        defer sub.close();
        const head = try sub.head();
        if (fresh or head == null or !head.?.eql(want)) {
            _ = try checkout.switchTo(sub, a, want.hex(&hb), .{ .detach = true, .force = fresh, .tz_offset_min = opts.common.tz_offset_min });
            try out.print("Submodule path '{s}{s}': checked out '{s}'\n", .{ opts.prefix, m.path, want.hex(&hb) });
        }
        if (opts.recursive) {
            var inner = opts;
            inner.prefix = try std.fmt.allocPrint(a, "{s}{s}/", .{ opts.prefix, m.path });
            try update(sub, gpa, &.{}, connector, inner, out);
        }
    }
}

/// `git submodule sync [<path>...]`: the config's URL and the module's
/// remote follow `.gitmodules`.
pub fn sync(repo: *Repository, gpa: Allocator, paths: []const []const u8, opts: Options, out: *Writer) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const io = repo.io;
    const cfg = try std.fs.path.join(a, &.{ repo.git_dir_path, "config" });
    for (try select(a, try list(repo, a), paths)) |m| {
        if (repo.config.get(try key(a, m.name, "url")) == null) continue;
        const url = try resolveUrl(repo, a, m.url orelse continue);
        try out.print("Synchronizing submodule url for '{s}'\n", .{m.path});
        try config_mod.setValue(a, io, cfg, try key(a, m.name, "url"), url);
        const abs = try std.fs.path.join(a, &.{ repo.root, m.path });
        if (!exists(io, try std.fs.path.join(a, &.{ abs, ".git" }))) continue;
        const sub = try Repository.open(repo.gpa, io, abs, try modulesDir(repo, a, m.name), .{ .env = opts.env });
        defer sub.close();
        const remote = blk: {
            if (try sub.headRef(a)) |r| if (std.mem.startsWith(u8, r, "refs/heads/")) {
                if (sub.config.get(try std.fmt.allocPrint(a, "branch.{s}.remote", .{r["refs/heads/".len..]}))) |rm| break :blk rm;
            };
            break :blk "origin";
        };
        try config_mod.setValue(a, io, try std.fs.path.join(a, &.{ sub.git_dir_path, "config" }), try std.fmt.allocPrint(a, "remote.{s}.url", .{remote}), url);
    }
    try repo.reloadConfig(.{ .env = opts.env });
}

/// `git submodule deinit [-f] <path>...`: empties the working tree and
/// forgets the config (the repository under `modules/` stays).
pub fn deinitModules(repo: *Repository, gpa: Allocator, paths: []const []const u8, force: bool, opts: Options, out: *Writer) !void {
    if (paths.len == 0) return error.MissingPath;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const io = repo.io;
    const cfg = try std.fs.path.join(a, &.{ repo.git_dir_path, "config" });
    for (try select(a, try list(repo, a), paths)) |m| {
        const abs = try std.fs.path.join(a, &.{ repo.root, m.path });
        if (exists(io, try std.fs.path.join(a, &.{ abs, ".git" }))) {
            if (!force) {
                const sub = try Repository.open(repo.gpa, io, abs, try modulesDir(repo, a, m.name), .{ .env = opts.env });
                defer sub.close();
                var st = try status_mod.status(sub, .{});
                defer st.deinit();
                for (st.entries) |e| if (e.x != .untracked) return error.LocalModifications;
            }
            var d = try Io.Dir.cwd().openDir(io, abs, .{ .iterate = true });
            defer d.close(io);
            var names: std.ArrayList([]const u8) = .empty;
            var it = d.iterate();
            while (try it.next(io)) |e| try names.append(a, try a.dupe(u8, e.name));
            for (names.items) |n| try d.deleteTree(io, n);
            try out.print("Cleared directory '{s}'\n", .{m.path});
        }
        if (repo.config.get(try key(a, m.name, "url")) != null) {
            try config_mod.renameSection(a, io, cfg, "submodule", m.name, null);
            try out.print("Submodule '{s}' ({s}) unregistered for path '{s}'\n", .{ m.name, m.url orelse "", m.path });
        }
    }
    try repo.reloadConfig(.{ .env = opts.env });
}

/// `git submodule status`: one line per submodule in the index: '-' not
/// checked out, '+' at another commit than recorded, 'U' conflicted.
pub fn status(repo: *Repository, gpa: Allocator, out: *Writer) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var ix = try repo.readIndex();
    defer ix.deinit();
    var hb: [64]u8 = undefined;
    for (ix.entries.items) |e| {
        if (e.mode != tree_mod.mode_gitlink) continue;
        if (e.flags.stage != 0) {
            if (e.flags.stage == 2) try out.print("U{s} {s}\n", .{ Oid.zero(repo.format).hex(&hb), e.path });
            continue;
        }
        const abs = try std.fs.path.join(a, &.{ repo.root, e.path });
        const found = try worktree.discover(a, repo.io, abs);
        // Not checked out: the folder belongs to the superproject.
        const disc = if (found) |d| (if (std.mem.eql(u8, d.root, abs)) d else null) else null;
        if (disc == null) {
            try out.print("-{s} {s}\n", .{ e.oid.hex(&hb), e.path });
            continue;
        }
        const head = (try worktree.headId(a, repo.io, &disc.?)) orelse e.oid;
        const sub = try Repository.open(repo.gpa, repo.io, abs, disc.?.git_dir, .{ .env = repo.env });
        defer sub.close();
        try out.print("{c}{s} {s} ({s})\n", .{ @as(u8, if (head.eql(e.oid)) ' ' else '+'), head.hex(&hb), e.path, try describe(sub, a, head) });
    }
}

/// A name for `id` the way `git submodule status` finds one: a tag at it,
/// a branch at it ("heads/main"), a remote branch, else its short id.
fn describe(repo: *Repository, a: Allocator, id: Oid) ![]const u8 {
    for ([_][]const u8{ "refs/tags/", "refs/heads/", "refs/remotes/" }) |prefix| {
        var l = try repo.refs.iterate(a, prefix);
        defer l.deinit();
        for (l.refs) |r| {
            const target = revparse.resolveCommit(repo, r.name) catch continue;
            if (!target.eql(id)) continue;
            if (std.mem.eql(u8, prefix, "refs/tags/")) return a.dupe(u8, r.name[prefix.len..]);
            return a.dupe(u8, r.name["refs/".len..]);
        }
    }
    var hb: [64]u8 = undefined;
    return a.dupe(u8, id.hex(&hb)[0..7]);
}
