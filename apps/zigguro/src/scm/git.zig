//! The git tab's backend (E09 IDE integration): zigguro's own git
//! (zg_git and the zg_scm git bridge), with no git program involved.
//! The tab reads status, history, branches, tags, stashes, remotes and
//! submodules through the functions below, and runs operations as git
//! command lines (`Git.run`), so the command box takes the same words a
//! terminal would. Each call opens the repository afresh, so calls on
//! different threads do not share state.
//!
//! Remotes go over HTTPS (zg_net, credential helpers), SSH (zg_git's
//! client, keys, agent and known_hosts) or the file system. Commits are
//! signed when `commit.gpgSign` asks for it (SSH keys). Not built in
//! yet: `bisect run`, and submodule add/update/sync; they report so.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_git = @import("zg_git");
const zg_scm = @import("zg_scm");
const zg_net = @import("zg_net");
const zg_editor = @import("zg_editor");
const zg_agents = @import("zg_agents");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Repository = zg_git.Repository;
const Oid = zg_git.Oid;
const bridge = zg_scm.gitbridge;
const diff = zg_editor.model.diff;

/// The outcome of one git command.
pub const Result = struct {
    /// 0 on success.
    code: u8,
    out: []u8,
    err: []u8,

    pub fn ok(r: Result) bool {
        return r.code == 0;
    }

    pub fn deinit(r: Result, gpa: Allocator) void {
        gpa.free(r.out);
        gpa.free(r.err);
    }
};

/// A working tree, and how to reach its remotes.
pub const Git = struct {
    gpa: Allocator,
    io: Io,
    /// The folder commands run in (the working tree's top, once found).
    root: []u8,
    /// The repository folder (`.git`), when `root` is in a working tree.
    git_dir: ?[]u8 = null,
    env: std.process.Environ.Map,
    /// Minutes east of UTC for new commits and reflog entries.
    tz_offset_min: i32 = 0,
    /// For HTTPS remotes (null without a runtime).
    client: ?*zg_net.http.Client = null,

    /// Git for `dir`. Finds the working tree's top and its `.git` folder
    /// when `dir` is inside one.
    pub fn init(gpa: Allocator, io: Io, rt: ?*zg_core.Runtime, env: ?*const std.process.Environ.Map, dir: []const u8) !Git {
        var g: Git = .{
            .gpa = gpa,
            .io = io,
            .root = try gpa.dupe(u8, dir),
            .env = if (env) |e| try e.clone(gpa) else .init(gpa),
        };
        errdefer gpa.free(g.root);
        errdefer g.env.deinit();
        g.tz_offset_min = localOffset(gpa, io, &g.env);
        if (rt) |r| g.client = zg_net.http.Client.init(r, .{ .environ_map = &g.env }) catch null;
        g.locate();
        return g;
    }

    pub fn deinit(g: *Git) void {
        if (g.client) |c| c.deinit();
        g.gpa.free(g.root);
        if (g.git_dir) |d| g.gpa.free(d);
        g.env.deinit();
    }

    /// Finds the working tree's top and `.git` folder (again: after
    /// `git init`).
    pub fn locate(g: *Git) void {
        const repo = (Repository.discover(g.gpa, g.io, g.root, .{ .env = &g.env }) catch return) orelse return;
        defer repo.close();
        const top = g.gpa.dupe(u8, repo.root) catch return;
        const gd = g.gpa.dupe(u8, repo.git_dir_path) catch {
            g.gpa.free(top);
            return;
        };
        g.gpa.free(g.root);
        g.root = top;
        if (g.git_dir) |d| g.gpa.free(d);
        g.git_dir = gd;
    }

    /// Whether the folder is in a git working tree.
    pub fn isRepo(g: *const Git) bool {
        return g.git_dir != null;
    }

    /// The repository, opened for one call (the caller closes it).
    pub fn open(g: *const Git) !*Repository {
        return (try Repository.discover(g.gpa, g.io, g.root, .{ .env = &g.env })) orelse error.NotARepository;
    }

    fn connector(g: *const Git) Connector {
        return .{ .git = g };
    }

    /// Which operation is half done in the repository.
    pub fn operation(g: *const Git) Op {
        const gd = g.git_dir orelse return .none;
        const checks = [_]struct { name: []const u8, op: Op }{
            .{ .name = "rebase-merge", .op = .rebase },
            .{ .name = "rebase-apply", .op = .rebase },
            .{ .name = "MERGE_HEAD", .op = .merge },
            .{ .name = "CHERRY_PICK_HEAD", .op = .cherry_pick },
            .{ .name = "REVERT_HEAD", .op = .revert },
            .{ .name = "BISECT_LOG", .op = .bisect },
        };
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        for (checks) |c| {
            const p = std.fmt.bufPrint(&buf, "{s}{c}{s}", .{ gd, std.fs.path.sep, c.name }) catch continue;
            _ = Io.Dir.cwd().statFile(g.io, p, .{}) catch continue;
            return c.op;
        }
        return .none;
    }

    /// Runs a git command line (without "git") in the working tree.
    pub fn run(g: *const Git, gpa: Allocator, args: []const []const u8) !Result {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var err: Io.Writer.Allocating = .init(gpa);
        defer err.deinit();
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const code: u8 = command(g, arena.allocator(), args, &out.writer, &err.writer) catch |e| blk: {
            err.writer.print("{s}\n", .{describe(e)}) catch {};
            break :blk 1;
        };
        const o = try out.toOwnedSlice();
        errdefer gpa.free(o);
        return .{ .code = code, .out = o, .err = try err.toOwnedSlice() };
    }

    // -- what the pages show --------------------------------------------------

    /// The branch, its upstream and the changed paths.
    pub fn status(g: *const Git, a: Allocator) !Status {
        const repo = try g.open();
        defer repo.close();
        var s: Status = .{};
        if (try repo.headRef(a)) |r| s.branch = if (std.mem.startsWith(u8, r, "refs/heads/")) r["refs/heads/".len..] else r;
        if (try repo.head()) |h| s.oid = try hexAlloc(a, h);
        if (s.branch) |b| {
            var bl = try zg_git.branch.list(repo, true);
            defer bl.deinit();
            for (bl.items) |br| if (!br.remote and std.mem.eql(u8, br.name, b)) {
                if (br.upstream) |u| s.upstream = try a.dupe(u8, shortRef(u));
                s.ahead = br.ahead orelse 0;
                s.behind = br.behind orelse 0;
            };
        }
        // No index write from a read: an operation on another thread may
        // hold the index lock (git's GIT_OPTIONAL_LOCKS=0).
        var st = try zg_git.status.status(repo, .{ .untracked = .all, .refresh = false });
        defer st.deinit();
        var list: std.ArrayList(Entry) = .empty;
        for (st.entries) |e| {
            if (e.x == .ignored) continue;
            const path = try a.dupe(u8, e.path);
            if (e.x == .untracked) {
                try list.append(a, .{ .path = path, .x = '?', .y = '?', .kind = .untracked });
                continue;
            }
            try list.append(a, .{ .path = path, .x = letter(e.x), .y = letter(e.y), .kind = if (e.isConflict()) .conflict else .changed });
        }
        s.entries = list.items;
        return s;
    }

    /// The newest `limit` commits of HEAD (`all`: of every ref), dates
    /// as "YYYY-MM-DD HH:MM".
    pub fn log(g: *const Git, a: Allocator, limit: usize, all: bool) ![]Commit {
        const repo = try g.open();
        defer repo.close();
        var starts: std.ArrayList(Oid) = .empty;
        if (all) {
            var refs = try repo.refs.iterate(a, "refs/");
            for (refs.refs) |r| if (r.value == .direct) {
                const c = zg_git.revparse.peel(repo, a, r.value.direct, .commit) catch continue;
                try starts.append(a, c);
            };
            refs.deinit();
        }
        if (try repo.head()) |h| try starts.append(a, h);
        if (starts.items.len == 0) return &.{};
        const ids = try zg_git.revwalk.log(repo, a, starts.items, &.{}, limit);
        var deco = try Decorations.load(repo, a);
        const list = try a.alloc(Commit, ids.len);
        for (ids, list) |id, *c| {
            const cm = try readCommit(repo, a, id);
            var parents: std.ArrayList(u8) = .empty;
            for (cm.parents, 0..) |p, i| {
                if (i > 0) try parents.append(a, ' ');
                try parents.appendSlice(a, try hexAlloc(a, p));
            }
            const full = try hexAlloc(a, id);
            c.* = .{
                .hash = full,
                .short = full[0..7],
                .author = cm.author.name,
                .email = cm.author.email,
                .date = try formatDate(a, cm.author, .{ .format = "%Y-%m-%d %H:%M" }),
                .refs = try deco.text(a, id),
                .parents = parents.items,
                .subject = subjectOf(cm.message),
            };
        }
        return list;
    }

    /// Local and remote-tracking branches.
    pub fn branches(g: *const Git, a: Allocator) ![]Branch {
        const repo = try g.open();
        defer repo.close();
        var bl = try zg_git.branch.list(repo, true);
        defer bl.deinit();
        const list = try a.alloc(Branch, bl.items.len);
        for (bl.items, list) |b, *o| {
            const full = try hexAlloc(a, b.target);
            const track: []const u8 = if (b.upstream != null and b.ahead == null)
                "[gone]"
            else if ((b.ahead orelse 0) > 0 and (b.behind orelse 0) > 0)
                try std.fmt.allocPrint(a, "[ahead {d}, behind {d}]", .{ b.ahead.?, b.behind.? })
            else if ((b.ahead orelse 0) > 0)
                try std.fmt.allocPrint(a, "[ahead {d}]", .{b.ahead.?})
            else if ((b.behind orelse 0) > 0)
                try std.fmt.allocPrint(a, "[behind {d}]", .{b.behind.?})
            else
                "";
            o.* = .{
                .name = try a.dupe(u8, b.name),
                .remote = b.remote,
                .head = b.head,
                .short = full[0..7],
                .upstream = if (b.upstream) |u| try a.dupe(u8, shortRef(u)) else "",
                .track = track,
                .subject = if (readCommit(repo, a, b.target)) |c| subjectOf(c.message) else |_| "",
            };
        }
        return list;
    }

    /// Tags, newest first.
    pub fn tags(g: *const Git, a: Allocator) ![]Tag {
        const repo = try g.open();
        defer repo.close();
        var tl = try zg_git.branch.tags(repo);
        defer tl.deinit();
        const Sorted = struct { tag: Tag, time: i64 };
        var list: std.ArrayList(Sorted) = .empty;
        for (tl.items) |t| {
            var subject: []const u8 = "";
            var time: i64 = 0;
            const obj = repo.odb.read(a, t.target) catch continue;
            if (obj.type == .tag) {
                const tg = zg_git.tag.parseTag(a, repo.format, obj.data) catch continue;
                subject = subjectOf(tg.message);
                if (tg.tagger) |w| time = w.time;
            } else if (obj.type == .commit) {
                const c = zg_git.commit.parseCommit(a, repo.format, obj.data) catch continue;
                subject = subjectOf(c.message);
                time = c.committer.time;
            }
            const full = try hexAlloc(a, t.target);
            try list.append(a, .{ .tag = .{ .name = try a.dupe(u8, t.name), .short = full[0..7], .subject = subject }, .time = time });
        }
        std.mem.sort(Sorted, list.items, {}, struct {
            fn lt(_: void, x: Sorted, y: Sorted) bool {
                return x.time > y.time;
            }
        }.lt);
        const out = try a.alloc(Tag, list.items.len);
        for (list.items, out) |s, *o| o.* = s.tag;
        return out;
    }

    pub fn stashes(g: *const Git, a: Allocator) ![]Stash {
        const repo = try g.open();
        defer repo.close();
        var sl = try bridge.stash.list(repo);
        defer sl.deinit();
        const out = try a.alloc(Stash, sl.items.len);
        for (sl.items, out) |s, *o| o.* = .{ .name = try std.fmt.allocPrint(a, "stash@{{{d}}}", .{s.n}), .subject = try a.dupe(u8, s.message) };
        return out;
    }

    pub fn remotes(g: *const Git, a: Allocator) ![]Remote {
        const repo = try g.open();
        defer repo.close();
        const names = try zg_git.remote.config.names(repo, a);
        var out: std.ArrayList(Remote) = .empty;
        for (names) |n| {
            const r = (try zg_git.remote.config.get(repo, a, n)) orelse continue;
            try out.append(a, .{ .name = n, .fetch = r.url, .push = r.pushUrl() });
        }
        return out.items;
    }

    /// The submodules the index records (gitlinks).
    pub fn submodules(g: *const Git, a: Allocator) ![]Submodule {
        const repo = try g.open();
        defer repo.close();
        var ix = try repo.readIndex();
        defer ix.deinit();
        var out: std.ArrayList(Submodule) = .empty;
        for (ix.entries.items) |e| {
            if (e.mode != 0o160000 or e.flags.stage != 0) continue;
            const full = try hexAlloc(a, e.oid);
            const gitfile = try std.fs.path.join(a, &.{ e.path, ".git" });
            const initialised = if (repo.work.statFile(g.io, gitfile, .{})) |_| true else |_| false;
            try out.append(a, .{ .path = try a.dupe(u8, e.path), .sha = full, .state = if (initialised) ' ' else '-', .describe = "" });
        }
        return out.items;
    }
};

/// Opens connections for fetch, pull and push.
const Connector = struct {
    git: *const Git,

    fn get(c: *const Connector) zg_git.remote.fetch.Connector {
        return .{ .ctx = @constCast(c), .connect = connect };
    }

    fn connect(ctx: ?*anyopaque, repo: *Repository, url: []const u8, service: zg_git.remote.transport.Service) anyerror!zg_git.remote.transport.Connection {
        const c: *const Connector = @ptrCast(@alignCast(ctx.?));
        if (zg_git.remote.connect.kindOf(url) == .http and c.git.client == null) return error.HttpUnavailable;
        // No client is needed for SSH and local remotes; HTTP checked above.
        var d: zg_git.remote.connect.Default = .{ .client = c.git.client orelse undefined };
        return d.connector().connect(&d, repo, url, service);
    }
};

/// The system zone's offset now, in minutes (UTC when unknown).
fn localOffset(gpa: Allocator, io: Io, env: *const std.process.Environ.Map) i32 {
    var tz = zg_agents.sched.tz.TimeZone.local(io, gpa, env) catch return 0;
    defer tz.deinit(gpa);
    const now: i64 = @intCast(@divFloor(Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s));
    return @divTrunc(tz.offsetAt(now).utoff, 60);
}

/// A half-done operation the tab offers to continue or abort.
pub const Op = enum {
    none,
    merge,
    rebase,
    cherry_pick,
    revert,
    bisect,

    pub fn label(o: Op) []const u8 {
        return switch (o) {
            .none => "",
            .merge => "Merging",
            .rebase => "Rebasing",
            .cherry_pick => "Cherry-picking",
            .revert => "Reverting",
            .bisect => "Bisecting",
        };
    }

    /// The git command that continues or aborts it (`merge`, `rebase`, ...).
    pub fn command(o: Op) []const u8 {
        return switch (o) {
            .none => "",
            .merge => "merge",
            .rebase => "rebase",
            .cherry_pick => "cherry-pick",
            .revert => "revert",
            .bisect => "bisect",
        };
    }
};

// -- what the pages show ----------------------------------------------------------

/// One changed path.
pub const Entry = struct {
    path: []const u8,
    /// The path it was renamed or copied from.
    orig: ?[]const u8 = null,
    /// Index (staged) and work tree states, git's letters ('.' unchanged).
    x: u8,
    y: u8,
    kind: Kind,

    pub const Kind = enum { changed, renamed, conflict, untracked };

    pub fn staged(e: Entry) bool {
        return e.kind != .untracked and e.kind != .conflict and e.x != '.';
    }

    pub fn unstaged(e: Entry) bool {
        return e.kind != .untracked and e.kind != .conflict and e.y != '.';
    }
};

pub const Status = struct {
    /// The branch, or null when HEAD is detached.
    branch: ?[]const u8 = null,
    /// The commit HEAD names (null on an unborn branch).
    oid: ?[]const u8 = null,
    upstream: ?[]const u8 = null,
    ahead: u32 = 0,
    behind: u32 = 0,
    entries: []Entry = &.{},
};

/// One commit of the history.
pub const Commit = struct {
    hash: []const u8,
    short: []const u8,
    author: []const u8,
    email: []const u8,
    date: []const u8,
    /// Ref names pointing at it ("HEAD -> main, origin/main, tag: v1").
    refs: []const u8,
    parents: []const u8,
    subject: []const u8,
};

/// A local or remote-tracking branch.
pub const Branch = struct {
    /// "main", "origin/main".
    name: []const u8,
    remote: bool,
    head: bool,
    short: []const u8,
    upstream: []const u8,
    /// "[ahead 1, behind 2]", "[gone]" or "".
    track: []const u8,
    subject: []const u8,
};

pub const Tag = struct { name: []const u8, short: []const u8, subject: []const u8 };

pub const Stash = struct { name: []const u8, subject: []const u8 };

pub const Remote = struct { name: []const u8, fetch: []const u8, push: []const u8 };

pub const Submodule = struct {
    path: []const u8,
    sha: []const u8,
    /// ' ' checked out, '-' not initialised.
    state: u8,
    describe: []const u8,
};

fn letter(c: zg_git.status.Code) u8 {
    return if (c == .unmodified) '.' else @intFromEnum(c);
}

fn hexAlloc(a: Allocator, id: Oid) ![]const u8 {
    var b: [64]u8 = undefined;
    return a.dupe(u8, id.hex(&b));
}

/// "origin/main" for "refs/remotes/origin/main".
fn shortRef(r: []const u8) []const u8 {
    for ([_][]const u8{ "refs/heads/", "refs/remotes/", "refs/tags/" }) |p| if (std.mem.startsWith(u8, r, p)) return r[p.len..];
    return r;
}

fn subjectOf(message: []const u8) []const u8 {
    return std.mem.trimEnd(u8, std.mem.sliceTo(message, '\n'), "\r");
}

fn readCommit(repo: *Repository, a: Allocator, id: Oid) !zg_git.commit.Commit {
    const obj = try repo.odb.read(a, id);
    if (obj.type != .commit) return error.NotACommit;
    return zg_git.commit.parseCommit(a, repo.format, obj.data);
}

/// Ref names by the commit they point at, for `%D`.
const Decorations = struct {
    head_ref: ?[]const u8,
    head: ?Oid,
    names: std.AutoHashMapUnmanaged(Oid, std.ArrayList([]const u8)) = .empty,

    fn load(repo: *Repository, a: Allocator) !Decorations {
        var d: Decorations = .{ .head_ref = try repo.headRef(a), .head = try repo.head() };
        var refs = try repo.refs.iterate(a, "refs/");
        defer refs.deinit();
        for (refs.refs) |r| {
            if (r.value != .direct) continue;
            const is_tag = std.mem.startsWith(u8, r.name, "refs/tags/");
            if (!is_tag and !std.mem.startsWith(u8, r.name, "refs/heads/") and !std.mem.startsWith(u8, r.name, "refs/remotes/")) continue;
            const id = zg_git.revparse.peel(repo, a, r.value.direct, .commit) catch continue;
            const gop = try d.names.getOrPut(a, id);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            const name = if (is_tag) try std.fmt.allocPrint(a, "tag: {s}", .{shortRef(r.name)}) else try a.dupe(u8, shortRef(r.name));
            // HEAD's branch goes first, as "HEAD -> main".
            if (d.head_ref != null and std.mem.eql(u8, r.name, d.head_ref.?)) {
                try gop.value_ptr.insert(a, 0, try std.fmt.allocPrint(a, "HEAD -> {s}", .{name}));
            } else try gop.value_ptr.append(a, name);
        }
        if (d.head_ref == null) if (d.head) |h| {
            const gop = try d.names.getOrPut(a, h);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.insert(a, 0, "HEAD");
        };
        return d;
    }

    fn text(d: *Decorations, a: Allocator, id: Oid) ![]const u8 {
        const l = d.names.get(id) orelse return "";
        return std.mem.join(a, ", ", l.items);
    }
};

// -- dates --------------------------------------------------------------------------

const DateMode = union(enum) {
    /// "Thu Nov 14 22:13:20 2023 +0000".
    default,
    /// "2023-11-14".
    short,
    /// strftime-like: %Y %m %d %H %M %S %z.
    format: []const u8,
};

fn tzMinutes(tz: []const u8) i32 {
    if (tz.len != 5) return 0;
    const h = std.fmt.parseInt(i32, tz[1..3], 10) catch return 0;
    const m = std.fmt.parseInt(i32, tz[3..5], 10) catch return 0;
    const v = h * 60 + m;
    return if (tz[0] == '-') -v else v;
}

/// The ident's time in its own zone, as git's `--date` modes print it.
fn formatDate(a: Allocator, who: zg_git.commit.Ident, mode: DateMode) ![]const u8 {
    const local = who.time + @as(i64, tzMinutes(who.tz)) * 60;
    const secs: u64 = @intCast(@max(local, 0));
    const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const day = es.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    const month = md.month.numeric();
    const dom = md.day_index + 1;
    var out: std.ArrayList(u8) = .empty;
    switch (mode) {
        .short => try out.print(a, "{d}-{d:0>2}-{d:0>2}", .{ yd.year, month, dom }),
        .default => {
            const days = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
            const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
            try out.print(a, "{s} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} {d} {s}", .{ days[@intCast((day.day + 4) % 7)], months[month - 1], dom, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(), yd.year, who.tz });
        },
        .format => |f| {
            var i: usize = 0;
            while (i < f.len) : (i += 1) {
                if (f[i] != '%' or i + 1 == f.len) {
                    try out.append(a, f[i]);
                    continue;
                }
                i += 1;
                switch (f[i]) {
                    'Y' => try out.print(a, "{d}", .{yd.year}),
                    'm' => try out.print(a, "{d:0>2}", .{month}),
                    'd' => try out.print(a, "{d:0>2}", .{dom}),
                    'H' => try out.print(a, "{d:0>2}", .{ds.getHoursIntoDay()}),
                    'M' => try out.print(a, "{d:0>2}", .{ds.getMinutesIntoHour()}),
                    'S' => try out.print(a, "{d:0>2}", .{ds.getSecondsIntoMinute()}),
                    'z' => try out.appendSlice(a, who.tz),
                    '%' => try out.append(a, '%'),
                    else => |c| try out.appendSlice(a, &.{ '%', c }),
                }
            }
        },
    }
    return out.items;
}

fn parseDateMode(v: []const u8) DateMode {
    if (std.mem.eql(u8, v, "short")) return .short;
    if (std.mem.startsWith(u8, v, "format:")) return .{ .format = v["format:".len..] };
    return .default;
}

// -- command lines --------------------------------------------------------------

/// Splits a typed command line into arguments: spaces separate, quotes
/// ('…' or "…") group, a leading "git" is dropped.
pub fn splitArgs(arena: Allocator, line: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var cur: std.ArrayList(u8) = .empty;
    var in_arg = false;
    var quote: u8 = 0;
    for (line) |c| {
        if (quote != 0) {
            if (c == quote) quote = 0 else try cur.append(arena, c);
            continue;
        }
        switch (c) {
            ' ', '\t' => if (in_arg) {
                try list.append(arena, try cur.toOwnedSlice(arena));
                in_arg = false;
            },
            '"', '\'' => {
                quote = c;
                in_arg = true;
            },
            else => {
                try cur.append(arena, c);
                in_arg = true;
            },
        }
    }
    if (in_arg) try list.append(arena, try cur.toOwnedSlice(arena));
    var args = list.items;
    if (args.len > 0 and std.mem.eql(u8, args[0], "git")) args = args[1..];
    return args;
}

/// What an error means, in the words git would use.
fn describe(e: anyerror) []const u8 {
    return switch (e) {
        error.NotARepository => "fatal: not a git repository",
        error.WouldOverwrite => "error: your local changes would be overwritten; commit or stash them first",
        error.UncommittedChanges => "error: cannot rebase: you have unstaged or uncommitted changes; commit or stash them first",
        error.NothingToCommit => "nothing to commit, working tree clean",
        error.EmptyMessage => "Aborting commit due to empty commit message.",
        error.UnmergedEntries, error.UnresolvedConflicts => "error: there are unresolved conflicts; resolve them and stage the files first",
        error.IdentityUnknown => "Author identity unknown: set user.name and user.email (Settings, or git config)",
        error.MergeInProgress => "fatal: a merge is in progress; finish or abort it first",
        error.NoRebaseInProgress => "fatal: no rebase in progress",
        error.NoLocalChanges => "No local changes to save",
        error.NoSuchStash => "error: no such stash entry",
        error.NoUpstream => "There is no tracking information for the current branch; push with -u or set an upstream.",
        error.DetachedHead => "fatal: you are not currently on a branch",
        error.UnbornHead => "fatal: the branch has no commits yet",
        error.NoSuchRemote => "fatal: no such remote",
        error.RemoteExists => "error: remote already exists",
        error.DestinationNotEmpty => "fatal: destination path already exists and is not an empty directory",
        error.HttpUnavailable => "fatal: HTTPS remotes need the app's network client",
        error.SigningUnsupported => "error: only SSH signing (gpg.format = ssh) is built in",
        error.SigningKeyMissing => "error: commit.gpgSign is on but user.signingKey is not set or not found",
        error.PassphraseRequired => "error: the signing key needs a passphrase; add it to ssh-agent",
        error.NothingToMerge => "fatal: no remote branch to merge",
        error.NotBisecting => "error: We are not bisecting.",
        error.OneBadCommit => "error: 'git bisect bad' can take only one argument.",
        error.BothGoodAndBad => "error: a commit was marked both good and bad",
        error.MergeBaseIsBad => "error: the merge base is bad: the change was undone between the bad commit and the good ones",
        error.GoodNotAncestorOfBad => "error: some good commits are not ancestors of the bad one; maybe good and bad are swapped?",
        error.InvalidTerm => "error: not a valid bisect term",
        error.Unsupported => "this git command is not built into zigguro yet",
        else => @errorName(e),
    };
}

/// A parsed command line: flags, `-x value` options and positionals
/// (everything after `--` is positional).
const Args = struct {
    flags: std.StringHashMapUnmanaged([]const u8) = .empty,
    pos: std.ArrayList([]const u8) = .empty,
    after_dashdash: std.ArrayList([]const u8) = .empty,

    /// `with_value` flags take the next word (or `--x=v`).
    fn parse(a: Allocator, words: []const []const u8, with_value: []const []const u8) !Args {
        var r: Args = .{};
        var i: usize = 0;
        while (i < words.len) : (i += 1) {
            const w = words[i];
            if (std.mem.eql(u8, w, "--")) {
                try r.after_dashdash.appendSlice(a, words[i + 1 ..]);
                break;
            }
            if (w.len > 1 and w[0] == '-') {
                if (std.mem.indexOfScalar(u8, w, '=')) |eq| if (std.mem.startsWith(u8, w, "--")) {
                    try r.flags.put(a, w[0..eq], w[eq + 1 ..]);
                    continue;
                };
                const takes = for (with_value) |v| {
                    if (std.mem.eql(u8, v, w)) break true;
                } else false;
                if (takes and i + 1 < words.len) {
                    try r.flags.put(a, w, words[i + 1]);
                    i += 1;
                } else try r.flags.put(a, w, "");
                continue;
            }
            try r.pos.append(a, w);
        }
        return r;
    }

    fn has(r: *const Args, f: []const u8) bool {
        return r.flags.contains(f);
    }

    fn get(r: *const Args, f: []const u8) ?[]const u8 {
        return r.flags.get(f);
    }

    /// Positionals before and after `--`.
    fn paths(r: *const Args, a: Allocator) ![]const []const u8 {
        var l: std.ArrayList([]const u8) = .empty;
        try l.appendSlice(a, r.pos.items);
        try l.appendSlice(a, r.after_dashdash.items);
        return l.items;
    }
};

/// "stash@{2}" -> 2.
fn stashIndex(name: ?[]const u8) !usize {
    const n = name orelse return 0;
    if (std.mem.startsWith(u8, n, "stash@{") and std.mem.endsWith(u8, n, "}")) return std.fmt.parseInt(usize, n[7 .. n.len - 1], 10) catch error.NoSuchStash;
    return std.fmt.parseInt(usize, n, 10) catch error.NoSuchStash;
}

/// Runs one command; returns the exit code.
fn command(g: *const Git, a: Allocator, words_in: []const []const u8, out: *Io.Writer, err: *Io.Writer) !u8 {
    var words = words_in;
    // Global options: `-c k=v` and `--no-pager` change nothing here.
    while (words.len > 0) {
        if (std.mem.eql(u8, words[0], "-c") and words.len > 1) {
            words = words[2..];
        } else if (std.mem.eql(u8, words[0], "--no-pager")) {
            words = words[1..];
        } else break;
    }
    if (words.len == 0) return error.Unsupported;
    const cmd = words[0];
    const rest = words[1..];
    if (std.mem.eql(u8, cmd, "init")) return cmdInit(g, a, rest, out);
    if (std.mem.eql(u8, cmd, "clone")) return cmdClone(g, a, rest, out);
    if (std.mem.eql(u8, cmd, "submodule") and !(rest.len > 0 and std.mem.eql(u8, rest[0], "status"))) {
        try err.print("git {s}: not built into zigguro yet\n", .{cmd});
        return 1;
    }

    const repo = try g.open();
    defer repo.close();
    const Cmd = *const fn (*const Git, *Repository, Allocator, []const []const u8, *Io.Writer, *Io.Writer) anyerror!u8;
    const table = [_]struct { []const u8, Cmd }{
        .{ "status", cmdStatus },
        .{ "add", cmdAdd },
        .{ "rm", cmdRm },
        .{ "reset", cmdReset },
        .{ "restore", cmdRestore },
        .{ "checkout", cmdCheckout },
        .{ "switch", cmdCheckout },
        .{ "clean", cmdClean },
        .{ "commit", cmdCommit },
        .{ "diff", cmdDiff },
        .{ "show", cmdShow },
        .{ "log", cmdLog },
        .{ "branch", cmdBranch },
        .{ "tag", cmdTag },
        .{ "merge", cmdMerge },
        .{ "rebase", cmdRebase },
        .{ "cherry-pick", cmdPick },
        .{ "revert", cmdPick },
        .{ "stash", cmdStash },
        .{ "remote", cmdRemote },
        .{ "fetch", cmdFetch },
        .{ "pull", cmdPull },
        .{ "push", cmdPush },
        .{ "submodule", cmdSubmodule },
        .{ "bisect", cmdBisect },
    };
    for (table) |t| if (std.mem.eql(u8, t[0], cmd)) {
        // `revert` and `cherry-pick` share one function: pass the name.
        return t[1](g, repo, a, if (std.mem.eql(u8, cmd, "revert") or std.mem.eql(u8, cmd, "cherry-pick")) words else rest, out, err);
    };
    try err.print("git {s}: not built into zigguro yet\n", .{cmd});
    return 1;
}

fn cmdInit(g: *const Git, a: Allocator, rest: []const []const u8, out: *Io.Writer) !u8 {
    const args = try Args.parse(a, rest, &.{ "-b", "--initial-branch" });
    const dir = if (args.pos.items.len > 0) try std.fs.path.resolve(a, &.{ g.root, args.pos.items[0] }) else g.root;
    const r = try zg_git.init_repo.init(g.gpa, g.io, dir, .{
        .bare = args.has("--bare"),
        .initial_branch = args.get("-b") orelse args.get("--initial-branch"),
        .env = &g.env,
    });
    try out.print("{s} Git repository in {s}\n", .{ if (r == .created) "Initialized empty" else "Reinitialized existing", dir });
    return 0;
}

fn cmdClone(g: *const Git, a: Allocator, rest: []const []const u8, out: *Io.Writer) !u8 {
    const args = try Args.parse(a, rest, &.{ "-b", "--branch", "-o", "--origin" });
    if (args.pos.items.len == 0) return error.MissingUrl;
    const url = args.pos.items[0];
    const name = if (args.pos.items.len > 1) args.pos.items[1] else blk: {
        var base = std.mem.trimEnd(u8, url, "/\\");
        base = base[(std.mem.lastIndexOfAny(u8, base, "/\\:") orelse return error.MissingDirectory) + 1 ..];
        if (std.mem.endsWith(u8, base, ".git")) base = base[0 .. base.len - 4];
        break :blk base;
    };
    const dir = try std.fs.path.resolve(a, &.{ g.root, name });
    try out.print("Cloning into '{s}'...\n", .{name});
    var c: Connector = g.connector();
    const repo = try zg_git.init_repo.clone(g.gpa, g.io, url, dir, c.get(), .{
        .branch = args.get("-b") orelse args.get("--branch"),
        .origin = args.get("-o") orelse args.get("--origin") orelse "origin",
        .bare = args.has("--bare"),
        .env = &g.env,
        .tz_offset_min = g.tz_offset_min,
    });
    repo.close();
    return 0;
}

fn cmdStatus(_: *const Git, repo: *Repository, a: Allocator, _: []const []const u8, out: *Io.Writer, _: *Io.Writer) !u8 {
    if (try repo.headRef(a)) |r| try out.print("## {s}\n", .{shortRef(r)}) else try out.writeAll("## HEAD (no branch)\n");
    var st = try zg_git.status.status(repo, .{ .untracked = .all });
    defer st.deinit();
    for (st.entries) |e| if (e.x != .ignored) try out.print("{c}{c} {s}\n", .{ @intFromEnum(e.x), @intFromEnum(e.y), e.path });
    return 0;
}

fn cmdAdd(_: *const Git, repo: *Repository, a: Allocator, rest: []const []const u8, _: *Io.Writer, _: *Io.Writer) !u8 {
    const args = try Args.parse(a, rest, &.{});
    const paths = try args.paths(a);
    const update = args.has("-u") or args.has("--update");
    _ = try zg_git.stage.add(repo, if (paths.len == 0 and !update) &.{"."} else paths, .{ .update_only = update });
    return 0;
}

fn cmdRm(_: *const Git, repo: *Repository, a: Allocator, rest: []const []const u8, out: *Io.Writer, _: *Io.Writer) !u8 {
    const args = try Args.parse(a, rest, &.{});
    const paths = try args.paths(a);
    const n = try zg_git.stage.remove(repo, paths, .{ .cached = args.has("--cached") });
    if (!args.has("-q")) try out.print("rm: {d} path(s)\n", .{n});
    return 0;
}

fn cmdReset(g: *const Git, repo: *Repository, a: Allocator, rest: []const []const u8, out: *Io.Writer, _: *Io.Writer) !u8 {
    const args = try Args.parse(a, rest, &.{});
    const mode: ?zg_git.checkout.ResetMode = if (args.has("--soft")) .soft else if (args.has("--hard")) .hard else if (args.has("--mixed")) .mixed else null;
    if (mode == null and (args.after_dashdash.items.len > 0 or args.pos.items.len > 1)) {
        _ = try zg_git.stage.unstage(repo, try args.paths(a));
        return 0;
    }
    const rev = if (args.pos.items.len > 0) args.pos.items[0] else "HEAD";
    if (mode == null and args.pos.items.len == 0) {
        // `git reset`: unstage everything.
        _ = try zg_git.stage.unstage(repo, &.{});
        return 0;
    }
    const target = try zg_git.revparse.resolveCommit(repo, rev);
    try zg_git.checkout.reset(repo, target, mode orelse .mixed, rev, g.tz_offset_min);
    if (mode == .hard) {
        const c = try readCommit(repo, a, target);
        var hb: [64]u8 = undefined;
        try out.print("HEAD is now at {s} {s}\n", .{ target.hex(&hb)[0..7], subjectOf(c.message) });
    }
    return 0;
}

fn cmdRestore(_: *const Git, repo: *Repository, a: Allocator, rest: []const []const u8, _: *Io.Writer, _: *Io.Writer) !u8 {
    const args = try Args.parse(a, rest, &.{"--source"});
    const paths = try args.paths(a);
    if (args.has("--staged") and !args.has("--worktree")) {
        _ = try zg_git.stage.unstage(repo, paths);
        return 0;
    }
    const src: zg_git.checkout.RestoreSource = if (args.get("--source")) |s| .{ .commit = try zg_git.revparse.resolveCommit(repo, s) } else .index;
    _ = try zg_git.checkout.restore(repo, paths, src);
    return 0;
}

fn cmdCheckout(g: *const Git, repo: *Repository, a: Allocator, rest: []const []const u8, out: *Io.Writer, err: *Io.Writer) !u8 {
    const args = try Args.parse(a, rest, &.{ "-b", "-B", "-c", "-C" });
    if (args.has("--ours") or args.has("--theirs")) {
        return takeSide(repo, a, try args.paths(a), if (args.has("--ours")) 2 else 3);
    }
    // `checkout -- <paths>` (or paths that exist in the index).
    if (args.after_dashdash.items.len > 0) {
        if (args.pos.items.len > 0) {
            const c = try zg_git.revparse.resolveCommit(repo, args.pos.items[0]);
            _ = try zg_git.checkout.restore(repo, args.after_dashdash.items, .{ .commit = c });
        } else _ = try zg_git.checkout.restore(repo, args.after_dashdash.items, .index);
        return 0;
    }
    const create = args.get("-b") orelse args.get("-c");
    const force_create = args.get("-B") orelse args.get("-C");
    var target: []const u8 = if (args.pos.items.len > 0) args.pos.items[0] else "HEAD";
    if (args.has("--track") and create == null) {
        // `--track origin/x` checks out x tracking origin/x.
        if (std.mem.indexOfScalar(u8, target, '/')) |s| target = target[s + 1 ..];
    }
    var blocked: std.ArrayList([]const u8) = .empty;
    const o = zg_git.checkout.switchTo(repo, a, target, .{
        .create = create orelse force_create,
        .force_create = force_create != null,
        .detach = args.has("--detach"),
        .force = args.has("-f") or args.has("--force"),
        .conflicts = &blocked,
        .conflicts_gpa = a,
        .tz_offset_min = g.tz_offset_min,
    }) catch |e| {
        if (e == error.WouldOverwrite) {
            try err.writeAll("error: Your local changes to the following files would be overwritten by checkout:\n");
            for (blocked.items) |p| try err.print("\t{s}\n", .{p});
            try err.writeAll("Please commit your changes or stash them before you switch branches.\n");
            return 1;
        }
        return e;
    };
    if (o.branch) |b| {
        try out.print("Switched to {s}branch '{s}'\n", .{ if (create != null or force_create != null) "a new " else "", b });
        if (o.created_tracking) try out.print("branch '{s}' set up to track '{s}'.\n", .{ b, args.pos.items[0] });
    } else {
        var hb: [64]u8 = undefined;
        try out.print("HEAD is now at {s} (detached)\n", .{o.head.hex(&hb)[0..7]});
    }
    return 0;
}

/// `checkout --ours/--theirs -- <paths>`: writes that side of each
/// conflicted path to the working tree.
fn takeSide(repo: *Repository, a: Allocator, paths: []const []const u8, stage: u2) !u8 {
    _ = a;
    var ix = try repo.readIndex();
    defer ix.deinit();
    for (paths) |p| {
        const e = for (ix.entries.items) |*e| {
            if (e.flags.stage == stage and std.mem.eql(u8, e.path, p)) break e;
        } else return error.NoSuchSide;
        try zg_git.checkout.writeFile(repo, p, e.mode, e.oid);
    }
    return 0;
}

fn cmdClean(_: *const Git, repo: *Repository, a: Allocator, rest: []const []const u8, out: *Io.Writer, _: *Io.Writer) !u8 {
    // Combined short flags: -fd, -fdx.
    var dirs = false;
    var ignored = false;
    var force = false;
    var paths: std.ArrayList([]const u8) = .empty;
    var after = false;
    for (rest) |w| {
        if (!after and std.mem.eql(u8, w, "--")) {
            after = true;
            continue;
        }
        if (!after and w.len > 1 and w[0] == '-' and w[1] != '-') {
            for (w[1..]) |c| switch (c) {
                'd' => dirs = true,
                'x' => ignored = true,
                'f' => force = true,
                else => {},
            };
            continue;
        }
        if (!after and std.mem.eql(u8, w, "--force")) {
            force = true;
            continue;
        }
        try paths.append(a, w);
    }
    if (!force) return error.CleanNeedsForce;
    const removed = try zg_git.checkout.clean(repo, a, paths.items, dirs, ignored);
    for (removed) |p| try out.print("Removing {s}\n", .{p});
    return 0;
}

fn cmdCommit(g: *const Git, repo: *Repository, a: Allocator, rest: []const []const u8, out: *Io.Writer, _: *Io.Writer) !u8 {
    const args = try Args.parse(a, rest, &.{ "-m", "--message", "-F" });
    var msg: []const u8 = args.get("-m") orelse args.get("--message") orelse "";
    var cleanup: zg_git.commit_cmd.Cleanup = .whitespace;
    if (msg.len == 0) {
        // --no-edit (or nothing): the prepared message of a merge,
        // cherry-pick or revert, or the amended commit's.
        if (repo.git_dir.readFileAlloc(repo.io, "MERGE_MSG", a, .limited(1 << 20))) |m| {
            msg = m;
            cleanup = .strip;
        } else |_| if (args.has("--amend")) {
            if (try repo.head()) |h| msg = (try readCommit(repo, a, h)).message;
        }
    }
    var r = try zg_git.commit_cmd.commit(repo, .{
        .message = msg,
        .all = args.has("-a") or args.has("--all"),
        .amend = args.has("--amend"),
        .allow_empty = args.has("--allow-empty"),
        .cleanup = cleanup,
        .tz_offset_min = g.tz_offset_min,
        .sign = if (args.has("-S")) .on else if (args.has("--no-gpg-sign")) .off else .config,
    });
    defer r.deinit(repo.gpa);
    var hb: [64]u8 = undefined;
    const c = try readCommit(repo, a, r.oid);
    try out.print("[{s} {s}] {s}\n", .{ shortRef(r.ref), r.oid.hex(&hb)[0..7], subjectOf(c.message) });
    return 0;
}

// -- diffs ----------------------------------------------------------------------

const Side = struct { mode: u32, oid: Oid, data: []const u8 };

fn blob(repo: *Repository, a: Allocator, mode: u32, id: Oid) !Side {
    if (mode == 0o160000) {
        var hb: [64]u8 = undefined;
        return .{ .mode = mode, .oid = id, .data = try std.fmt.allocPrint(a, "Subproject commit {s}\n", .{id.hex(&hb)}) };
    }
    const obj = try repo.odb.read(a, id);
    return .{ .mode = mode, .oid = id, .data = obj.data };
}

const Counts = struct { add: usize = 0, del: usize = 0 };

/// One file's `git diff` text; returns the line counts for `--stat`.
fn writeFileDiff(w: *Io.Writer, a: Allocator, path: []const u8, old: ?Side, new: ?Side) !Counts {
    var hb1: [64]u8 = undefined;
    var hb2: [64]u8 = undefined;
    try w.print("diff --git a/{s} b/{s}\n", .{ path, path });
    if (old == null) try w.print("new file mode {o:0>6}\n", .{new.?.mode});
    if (new == null) try w.print("deleted file mode {o:0>6}\n", .{old.?.mode});
    if (old != null and new != null and old.?.mode != new.?.mode) try w.print("old mode {o:0>6}\nnew mode {o:0>6}\n", .{ old.?.mode, new.?.mode });
    const o_hex = if (old) |o| o.oid.hex(&hb1)[0..7] else "0000000";
    const n_hex = if (new) |n| n.oid.hex(&hb2)[0..7] else "0000000";
    if (old != null and new != null and old.?.mode == new.?.mode) try w.print("index {s}..{s} {o:0>6}\n", .{ o_hex, n_hex, new.?.mode }) else try w.print("index {s}..{s}\n", .{ o_hex, n_hex });
    const od: []const u8 = if (old) |o| o.data else "";
    const nd: []const u8 = if (new) |n| n.data else "";
    if (!zg_git.status.isText(od) or !zg_git.status.isText(nd)) {
        try w.print("Binary files {s} and {s} differ\n", .{ if (old != null) try std.fmt.allocPrint(a, "a/{s}", .{path}) else "/dev/null", if (new != null) try std.fmt.allocPrint(a, "b/{s}", .{path}) else "/dev/null" });
        return .{};
    }
    var la = try diff.LineSource.fromBytes(a, od);
    var lb = try diff.LineSource.fromBytes(a, nd);
    var d = try diff.diffLines(a, &la, &lb, .{ .intraline = .none });
    var text: Io.Writer.Allocating = .init(a);
    try diff.unified.writeUnified(&text.writer, d.edits, d.hunks, &la, &lb, .{
        if (old != null) try std.fmt.allocPrint(a, "a/{s}", .{path}) else "/dev/null",
        if (new != null) try std.fmt.allocPrint(a, "b/{s}", .{path}) else "/dev/null",
    });
    d.deinit(a);
    const body = text.written();
    try w.writeAll(body);
    var c: Counts = .{};
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |l| {
        if (std.mem.startsWith(u8, l, "+++ ") or std.mem.startsWith(u8, l, "--- ")) continue;
        if (l.len > 0 and l[0] == '+') c.add += 1;
        if (l.len > 0 and l[0] == '-') c.del += 1;
    }
    return c;
}

const FileRow = struct { path: []const u8, counts: Counts };

fn writeStat(w: *Io.Writer, rows: []const FileRow) !void {
    var width: usize = 0;
    for (rows) |r| width = @max(width, r.path.len);
    var adds: usize = 0;
    var dels: usize = 0;
    for (rows) |r| {
        try w.print(" {s}", .{r.path});
        try w.splatByteAll(' ', width - r.path.len);
        try w.print(" | {d} ", .{r.counts.add + r.counts.del});
        try w.splatByteAll('+', @min(r.counts.add, 40));
        try w.splatByteAll('-', @min(r.counts.del, 40));
        try w.writeByte('\n');
        adds += r.counts.add;
        dels += r.counts.del;
    }
    try w.print(" {d} file{s} changed, {d} insertion{s}(+), {d} deletion{s}(-)\n", .{ rows.len, if (rows.len == 1) "" else "s", adds, if (adds == 1) "" else "s", dels, if (dels == 1) "" else "s" });
}

/// Diffs two trees (null: empty), writing the patch and/or the stat.
fn diffTrees(repo: *Repository, a: Allocator, w: *Io.Writer, old_tree: ?Oid, new_tree: Oid, patch: bool, stat: bool) !void {
    const old_files = if (old_tree) |t| try zg_git.status.flattenTree(repo, a, t) else &.{};
    const new_files = try zg_git.status.flattenTree(repo, a, new_tree);
    var map: std.StringArrayHashMapUnmanaged([2]?zg_git.status.TreeFile) = .empty;
    for (old_files) |f| (try map.getOrPutValue(a, f.path, .{ null, null })).value_ptr[0] = f;
    for (new_files) |f| (try map.getOrPutValue(a, f.path, .{ null, null })).value_ptr[1] = f;
    const keys = map.keys();
    std.mem.sort([]const u8, keys, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    map.reIndex(a) catch {};
    var rows: std.ArrayList(FileRow) = .empty;
    var patch_text: Io.Writer.Allocating = .init(a);
    for (keys) |k| {
        const pair = map.get(k).?;
        if (pair[0] != null and pair[1] != null and pair[0].?.oid.eql(pair[1].?.oid) and pair[0].?.mode == pair[1].?.mode) continue;
        const o: ?Side = if (pair[0]) |f| try blob(repo, a, f.mode, f.oid) else null;
        const n: ?Side = if (pair[1]) |f| try blob(repo, a, f.mode, f.oid) else null;
        const c = try writeFileDiff(&patch_text.writer, a, k, o, n);
        try rows.append(a, .{ .path = k, .counts = c });
    }
    if (stat and rows.items.len > 0) {
        try writeStat(w, rows.items);
        if (patch) try w.writeByte('\n');
    }
    if (patch) try w.writeAll(patch_text.written());
}

fn cmdDiff(_: *const Git, repo: *Repository, a: Allocator, rest: []const []const u8, out: *Io.Writer, _: *Io.Writer) !u8 {
    const args = try Args.parse(a, rest, &.{});
    const cached = args.has("--cached") or args.has("--staged");
    var paths = try args.paths(a);
    if (paths.len == 1 and std.mem.eql(u8, paths[0], ".")) paths = &.{};
    var ix = try repo.readIndex();
    defer ix.deinit();
    var st = try zg_git.status.status(repo, .{ .untracked = .no, .refresh = false, .pathspec = paths });
    defer st.deinit();
    const head_tree: ?Oid = if (try repo.head()) |h| try repo.treeOf(h) else null;
    for (st.entries) |e| {
        if (cached and !(e.x != .unmodified and e.x != .untracked)) continue;
        if (!cached and !(e.y != .unmodified and e.y != .untracked)) continue;
        const in_index = for (ix.entries.items) |*ie| {
            if (ie.flags.stage == 0 and std.mem.eql(u8, ie.path, e.path)) break ie;
        } else null;
        const idx_side: ?Side = if (in_index) |ie| try blob(repo, a, ie.mode, ie.oid) else null;
        if (cached) {
            const old: ?Side = if (head_tree) |t| blk: {
                const id = zg_git.revparse.lookupPath(repo, a, t, e.path) catch break :blk null;
                break :blk try blob(repo, a, if (e.head_mode != 0) e.head_mode else 0o100644, id);
            } else null;
            _ = try writeFileDiff(out, a, e.path, old, idx_side);
        } else {
            const data: ?[]const u8 = repo.work.readFileAlloc(repo.io, e.path, a, .limited(64 << 20)) catch null;
            const new: ?Side = if (data) |d| .{ .mode = if (e.worktree_mode != 0) e.worktree_mode else 0o100644, .oid = zg_git.object.hashObject(repo.format, .blob, d), .data = d } else null;
            _ = try writeFileDiff(out, a, e.path, idx_side, new);
        }
    }
    return 0;
}

fn writeHeader(w: *Io.Writer, a: Allocator, id: Oid, c: zg_git.commit.Commit, fuller: bool) !void {
    var hb: [64]u8 = undefined;
    try w.print("commit {s}\n", .{id.hex(&hb)});
    if (c.parents.len > 1) {
        try w.writeAll("Merge:");
        for (c.parents) |p| try w.print(" {s}", .{p.hex(&hb)[0..7]});
        try w.writeByte('\n');
    }
    if (fuller) {
        try w.print("Author:     {s} <{s}>\nAuthorDate: {s}\nCommit:     {s} <{s}>\nCommitDate: {s}\n", .{ c.author.name, c.author.email, try formatDate(a, c.author, .default), c.committer.name, c.committer.email, try formatDate(a, c.committer, .default) });
    } else {
        try w.print("Author: {s} <{s}>\nDate:   {s}\n", .{ c.author.name, c.author.email, try formatDate(a, c.author, .default) });
    }
    try w.writeByte('\n');
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, c.message, "\n"), '\n');
    while (lines.next()) |l| try w.print("    {s}\n", .{l});
    try w.writeByte('\n');
}

fn cmdShow(_: *const Git, repo: *Repository, a: Allocator, rest: []const []const u8, out: *Io.Writer, _: *Io.Writer) !u8 {
    const args = try Args.parse(a, rest, &.{});
    const rev = if (args.pos.items.len > 0) args.pos.items[0] else "HEAD";
    const fuller = if (args.get("--format") orelse args.get("--pretty")) |f| std.mem.eql(u8, f, "fuller") else false;
    const stat = args.has("--stat");
    const patch = args.has("--patch") or args.has("-p") or !stat;
    var id = try zg_git.revparse.resolve(repo, rev);
    var obj = try repo.odb.read(a, id);
    if (obj.type == .tag) {
        const t = try zg_git.tag.parseTag(a, repo.format, obj.data);
        try out.print("tag {s}\n", .{t.name});
        if (t.tagger) |w| try out.print("Tagger: {s} <{s}>\nDate:   {s}\n", .{ w.name, w.email, try formatDate(a, w, .default) });
        try out.print("\n{s}\n", .{std.mem.trimEnd(u8, t.message, "\n")});
        id = try zg_git.revparse.peel(repo, a, id, .commit);
        obj = try repo.odb.read(a, id);
    }
    if (obj.type != .commit) {
        try out.writeAll(obj.data);
        return 0;
    }
    const c = try zg_git.commit.parseCommit(a, repo.format, obj.data);
    try writeHeader(out, a, id, c, fuller);
    // Merges show nothing by default, as git's combined diff would be.
    if (c.parents.len <= 1) try diffTrees(repo, a, out, if (c.parents.len == 1) try repo.treeOf(c.parents[0]) else null, c.tree, patch, stat);
    return 0;
}

fn cmdLog(_: *const Git, repo: *Repository, a: Allocator, rest: []const []const u8, out: *Io.Writer, _: *Io.Writer) !u8 {
    const args = try Args.parse(a, rest, &.{"-n"});
    const limit: usize = if (args.get("-n")) |n| std.fmt.parseInt(usize, n, 10) catch 100 else if (args.get("--max-count")) |n| std.fmt.parseInt(usize, n, 10) catch 100 else 1000;
    const date: DateMode = if (args.get("--date")) |d| parseDateMode(d) else .default;
    const format = args.get("--format") orelse args.get("--pretty");
    var starts: std.ArrayList(Oid) = .empty;
    if (args.has("--all")) {
        var refs = try repo.refs.iterate(a, "refs/");
        for (refs.refs) |r| if (r.value == .direct) {
            const c = zg_git.revparse.peel(repo, a, r.value.direct, .commit) catch continue;
            try starts.append(a, c);
        };
        refs.deinit();
    }
    for (args.pos.items) |p| try starts.append(a, try zg_git.revparse.resolveCommit(repo, p));
    if (starts.items.len == 0) try starts.append(a, (try repo.head()) orelse return error.UnbornHead);
    const ids = try zg_git.revwalk.log(repo, a, starts.items, &.{}, limit);
    var deco = try Decorations.load(repo, a);
    for (ids) |id| {
        const c = try readCommit(repo, a, id);
        if (format) |f| {
            try formatCommit(out, a, f, id, c, date, &deco);
            try out.writeByte('\n');
        } else try writeHeader(out, a, id, c, false);
    }
    return 0;
}

/// `--format` placeholders: %H %h %P %p %an %ae %ad %cn %ce %cd %D %s %b
/// %n %%, and %xNN.
fn formatCommit(w: *Io.Writer, a: Allocator, f: []const u8, id: Oid, c: zg_git.commit.Commit, date: DateMode, deco: *Decorations) !void {
    const fmt = if (std.mem.startsWith(u8, f, "format:")) f[7..] else if (std.mem.startsWith(u8, f, "tformat:")) f[8..] else f;
    var hb: [64]u8 = undefined;
    var i: usize = 0;
    while (i < fmt.len) : (i += 1) {
        if (fmt[i] != '%' or i + 1 >= fmt.len) {
            try w.writeByte(fmt[i]);
            continue;
        }
        const rest = fmt[i + 1 ..];
        const two = if (rest.len >= 2) rest[0..2] else rest;
        if (std.mem.eql(u8, two, "an")) try w.writeAll(c.author.name) else if (std.mem.eql(u8, two, "ae")) try w.writeAll(c.author.email) else if (std.mem.eql(u8, two, "ad")) try w.writeAll(try formatDate(a, c.author, date)) else if (std.mem.eql(u8, two, "cn")) try w.writeAll(c.committer.name) else if (std.mem.eql(u8, two, "ce")) try w.writeAll(c.committer.email) else if (std.mem.eql(u8, two, "cd")) try w.writeAll(try formatDate(a, c.committer, date)) else if (rest[0] == 'x' and rest.len >= 3) {
            try w.writeByte(std.fmt.parseInt(u8, rest[1..3], 16) catch '?');
            i += 3;
            continue;
        } else {
            switch (rest[0]) {
                'H' => try w.writeAll(id.hex(&hb)),
                'h' => try w.writeAll(id.hex(&hb)[0..7]),
                'P', 'p' => for (c.parents, 0..) |p, k| {
                    if (k > 0) try w.writeByte(' ');
                    try w.writeAll(if (rest[0] == 'P') p.hex(&hb) else p.hex(&hb)[0..7]);
                },
                'D' => try w.writeAll(try deco.text(a, id)),
                's' => try w.writeAll(subjectOf(c.message)),
                'b' => {
                    const nl = std.mem.indexOf(u8, c.message, "\n\n");
                    if (nl) |n| try w.writeAll(c.message[n + 2 ..]);
                },
                'n' => try w.writeByte('\n'),
                '%' => try w.writeByte('%'),
                else => try w.writeAll(fmt[i .. i + 2]),
            }
            i += 1;
            continue;
        }
        i += 2;
    }
}

// -- branches, tags, stashes, remotes ----------------------------------------------------

fn cmdBranch(_: *const Git, repo: *Repository, a: Allocator, rest: []const []const u8, out: *Io.Writer, _: *Io.Writer) !u8 {
    const args = try Args.parse(a, rest, &.{ "-u", "--set-upstream-to" });
    const pos = args.pos.items;
    if (args.has("-m") or args.has("-M")) {
        if (pos.len == 2) try zg_git.branch.rename(repo, pos[0], pos[1], args.has("-M")) else if (pos.len == 1) {
            const cur = (try repo.headRef(a)) orelse return error.DetachedHead;
            try zg_git.branch.rename(repo, shortRef(cur), pos[0], args.has("-M"));
        } else return error.MissingBranchName;
        return 0;
    }
    if (args.has("-d") or args.has("-D") or args.has("--delete")) {
        const force = args.has("-D") or args.has("-f");
        for (pos) |b| {
            if (args.has("-r")) try zg_git.branch.deleteRemoteTracking(repo, b) else try zg_git.branch.delete(repo, b, force);
            try out.print("Deleted branch {s}\n", .{b});
        }
        return 0;
    }
    if (args.get("-u") orelse args.get("--set-upstream-to")) |up| {
        const b = if (pos.len > 0) pos[0] else shortRef((try repo.headRef(a)) orelse return error.DetachedHead);
        try zg_git.branch.setUpstream(repo, b, up);
        return 0;
    }
    if (args.has("--unset-upstream")) {
        const b = if (pos.len > 0) pos[0] else shortRef((try repo.headRef(a)) orelse return error.DetachedHead);
        try zg_git.branch.setUpstream(repo, b, null);
        return 0;
    }
    if (pos.len > 0) {
        _ = try zg_git.branch.create(repo, pos[0], if (pos.len > 1) pos[1] else "HEAD", args.has("-f"));
        return 0;
    }
    var bl = try zg_git.branch.list(repo, false);
    defer bl.deinit();
    for (bl.items) |b| if (!b.remote or args.has("-a") or args.has("-r")) {
        if (b.remote and !args.has("-a") and !args.has("-r")) continue;
        if (!b.remote and args.has("-r")) continue;
        try out.print("{s} {s}\n", .{ if (b.head) "*" else " ", b.name });
    };
    return 0;
}

fn cmdTag(g: *const Git, repo: *Repository, a: Allocator, rest: []const []const u8, out: *Io.Writer, _: *Io.Writer) !u8 {
    const args = try Args.parse(a, rest, &.{ "-m", "--message" });
    const pos = args.pos.items;
    if (args.has("-d") or args.has("--delete")) {
        for (pos) |t| {
            try zg_git.branch.deleteTag(repo, t);
            try out.print("Deleted tag '{s}'\n", .{t});
        }
        return 0;
    }
    if (pos.len == 0 or args.has("-l") or args.has("--list")) {
        var tl = try zg_git.branch.tags(repo);
        defer tl.deinit();
        for (tl.items) |t| try out.print("{s}\n", .{t.name});
        return 0;
    }
    // `-a <name> <message>` also takes the message as a word, as the tab
    // asks for it.
    var msg: ?[]const u8 = args.get("-m") orelse args.get("--message");
    var rev: []const u8 = if (pos.len > 1) pos[1] else "HEAD";
    if (msg == null and args.has("-a")) {
        if (pos.len < 2) return error.EmptyMessage;
        msg = pos[1];
        rev = if (pos.len > 2) pos[2] else "HEAD";
    }
    _ = try zg_git.branch.createTag(repo, pos[0], rev, msg, args.has("-f"), g.tz_offset_min);
    return 0;
}

fn cmdStash(g: *const Git, repo: *Repository, a: Allocator, rest: []const []const u8, out: *Io.Writer, err: *Io.Writer) !u8 {
    const sub = if (rest.len > 0 and rest[0][0] != '-') rest[0] else "push";
    const tail = if (rest.len > 0 and rest[0][0] != '-') rest[1..] else rest;
    const args = try Args.parse(a, tail, &.{ "-m", "--message" });
    const name: ?[]const u8 = if (args.pos.items.len > 0) args.pos.items[args.pos.items.len - 1] else null;
    if (std.mem.eql(u8, sub, "push") or std.mem.eql(u8, sub, "save")) {
        _ = bridge.stash.push(repo, .{
            .message = args.get("-m") orelse args.get("--message"),
            .include_untracked = args.has("-u") or args.has("--include-untracked"),
            .keep_index = args.has("-k") or args.has("--keep-index"),
            .tz_offset_min = g.tz_offset_min,
        }) catch |e| {
            if (e == error.NoLocalChanges) {
                try out.writeAll("No local changes to save\n");
                return 0;
            }
            return e;
        };
        try out.writeAll("Saved working directory and index state\n");
        return 0;
    }
    if (std.mem.eql(u8, sub, "list")) {
        var sl = try bridge.stash.list(repo);
        defer sl.deinit();
        for (sl.items) |s| try out.print("stash@{{{d}}}: {s}\n", .{ s.n, s.message });
        return 0;
    }
    if (std.mem.eql(u8, sub, "apply") or std.mem.eql(u8, sub, "pop")) {
        const n = try stashIndex(name);
        var r = if (std.mem.eql(u8, sub, "pop")) try bridge.stash.pop(repo, .{ .n = n, .tz_offset_min = g.tz_offset_min }) else try bridge.stash.apply(repo, .{ .n = n, .tz_offset_min = g.tz_offset_min });
        defer r.deinit();
        return conflictsOut(r, err);
    }
    if (std.mem.eql(u8, sub, "drop")) {
        const n = try stashIndex(name);
        try bridge.stash.drop(repo, n);
        try out.print("Dropped stash@{{{d}}}\n", .{n});
        return 0;
    }
    if (std.mem.eql(u8, sub, "clear")) {
        try bridge.stash.clear(repo);
        return 0;
    }
    if (std.mem.eql(u8, sub, "show")) {
        const n = try stashIndex(name);
        var sl = try bridge.stash.list(repo);
        defer sl.deinit();
        if (n >= sl.items.len) return error.NoSuchStash;
        const c = try readCommit(repo, a, sl.items[n].oid);
        try diffTrees(repo, a, out, try repo.treeOf(c.parents[0]), c.tree, args.has("-p") or args.has("--patch"), args.has("--stat") or !(args.has("-p") or args.has("--patch")));
        return 0;
    }
    if (std.mem.eql(u8, sub, "branch")) {
        // `stash branch <name> [<stash>]`: a branch at the stash's base,
        // checked out, the stash applied and dropped.
        if (args.pos.items.len == 0) return error.MissingBranchName;
        const n = try stashIndex(if (args.pos.items.len > 1) args.pos.items[1] else null);
        var sl = try bridge.stash.list(repo);
        defer sl.deinit();
        if (n >= sl.items.len) return error.NoSuchStash;
        const c = try readCommit(repo, a, sl.items[n].oid);
        var hb: [64]u8 = undefined;
        _ = try zg_git.checkout.switchTo(repo, a, try a.dupe(u8, c.parents[0].hex(&hb)), .{ .create = args.pos.items[0], .tz_offset_min = g.tz_offset_min });
        var r = try bridge.stash.pop(repo, .{ .n = n, .tz_offset_min = g.tz_offset_min });
        defer r.deinit();
        try out.print("Switched to a new branch '{s}'\n", .{args.pos.items[0]});
        return conflictsOut(r, err);
    }
    try err.print("git stash {s}: not built into zigguro yet\n", .{sub});
    return 1;
}

fn conflictsOut(r: bridge.common.Result, err: *Io.Writer) !u8 {
    if (r.kind != .conflicted) return 0;
    for (r.conflicts) |p| try err.print("CONFLICT (content): Merge conflict in {s}\n", .{p});
    return 1;
}

fn cmdRemote(g: *const Git, repo: *Repository, a: Allocator, rest: []const []const u8, out: *Io.Writer, err: *Io.Writer) !u8 {
    const R = zg_git.remote.config;
    const sub = if (rest.len > 0 and rest[0][0] != '-') rest[0] else "";
    const args = try Args.parse(a, if (sub.len > 0) rest[1..] else rest, &.{});
    const pos = args.pos.items;
    if (sub.len == 0) {
        for (try R.names(repo, a)) |n| {
            const r = (try R.get(repo, a, n)) orelse continue;
            if (args.has("-v")) try out.print("{s}\t{s} (fetch)\n{s}\t{s} (push)\n", .{ n, r.url, n, r.pushUrl() }) else try out.print("{s}\n", .{n});
        }
        return 0;
    }
    if (std.mem.eql(u8, sub, "add")) {
        if (pos.len < 2) return error.MissingUrl;
        try R.add(repo, pos[0], pos[1]);
        return 0;
    }
    if (std.mem.eql(u8, sub, "rename")) {
        if (pos.len < 2) return error.MissingRemoteName;
        try R.rename(repo, pos[0], pos[1]);
        return 0;
    }
    if (std.mem.eql(u8, sub, "set-url")) {
        if (pos.len < 2) return error.MissingUrl;
        try R.setUrl(repo, pos[0], pos[1], args.has("--push"));
        return 0;
    }
    if (std.mem.eql(u8, sub, "remove") or std.mem.eql(u8, sub, "rm")) {
        if (pos.len < 1) return error.MissingRemoteName;
        try R.remove(repo, pos[0]);
        return 0;
    }
    if (std.mem.eql(u8, sub, "prune")) {
        for (pos) |n| try fetchOne(g, repo, a, n, true, out);
        return 0;
    }
    if (std.mem.eql(u8, sub, "show")) {
        if (pos.len < 1) return error.MissingRemoteName;
        const r = (try R.get(repo, a, pos[0])) orelse return error.NoSuchRemote;
        try out.print("* remote {s}\n  Fetch URL: {s}\n  Push  URL: {s}\n", .{ pos[0], r.url, r.pushUrl() });
        var bl = try zg_git.branch.list(repo, false);
        defer bl.deinit();
        const prefix = try std.fmt.allocPrint(a, "{s}/", .{pos[0]});
        try out.writeAll("  Remote branches:\n");
        for (bl.items) |b| if (b.remote and std.mem.startsWith(u8, b.name, prefix)) try out.print("    {s}\n", .{b.name[prefix.len..]});
        try out.writeAll("  Local branches configured for 'git pull':\n");
        for (bl.items) |b| if (!b.remote) if (b.upstream) |u| if (std.mem.startsWith(u8, shortRef(u), prefix)) try out.print("    {s} merges with remote {s}\n", .{ b.name, shortRef(u)[prefix.len..] });
        return 0;
    }
    try err.print("git remote {s}: not built into zigguro yet\n", .{sub});
    return 1;
}

fn fetchOne(g: *const Git, repo: *Repository, a: Allocator, name: []const u8, prune: ?bool, out: *Io.Writer) !void {
    var c: Connector = g.connector();
    var r = try zg_git.remote.fetch.fetch(repo, name, .{ .prune = prune, .tz_offset_min = g.tz_offset_min }, c.get());
    defer r.deinit();
    const rem = (try zg_git.remote.config.get(repo, a, name)) orelse return;
    var shown = false;
    for (r.updates) |u| {
        const what: []const u8 = switch (u.kind) {
            .new_branch => "* [new branch]",
            .new_tag => "* [new tag]",
            .new_ref => "* [new ref]",
            .fast_forward => "  fast-forward",
            .forced => "+ forced update",
            .rejected => "! [rejected]",
            .pruned => "- [deleted]",
            .up_to_date => continue,
        };
        if (!shown) try out.print("From {s}\n", .{rem.url});
        shown = true;
        try out.print(" {s}  {s} -> {s}\n", .{ what, shortRef(u.remote), shortRef(u.local) });
    }
}

fn cmdFetch(g: *const Git, repo: *Repository, a: Allocator, rest: []const []const u8, out: *Io.Writer, _: *Io.Writer) !u8 {
    const args = try Args.parse(a, rest, &.{});
    const prune: ?bool = if (args.has("--prune") or args.has("-p")) true else if (args.has("--no-prune")) false else null;
    if (args.has("--all")) {
        for (try zg_git.remote.config.names(repo, a)) |n| try fetchOne(g, repo, a, n, prune, out);
        return 0;
    }
    const name = if (args.pos.items.len > 0) args.pos.items[0] else blk: {
        const b = (try repo.headRef(a)) orelse break :blk "origin";
        var kb: [512]u8 = undefined;
        break :blk repo.config.get(try std.fmt.bufPrint(&kb, "branch.{s}.remote", .{shortRef(b)})) orelse "origin";
    };
    try fetchOne(g, repo, a, name, prune, out);
    return 0;
}

fn cmdPull(g: *const Git, repo: *Repository, a: Allocator, rest: []const []const u8, out: *Io.Writer, err: *Io.Writer) !u8 {
    const args = try Args.parse(a, rest, &.{});
    var c: Connector = g.connector();
    var action: std.ArrayList(u8) = .empty;
    try action.appendSlice(a, "pull");
    for (rest) |w| try action.print(a, " {s}", .{w});
    var r = try bridge.pull.pull(repo, c.get(), .{
        .mode = if (args.has("--rebase") or args.has("-r")) .rebase else if (args.has("--no-rebase")) .merge else null,
        .ff = if (args.has("--ff-only")) .only else if (args.has("--no-ff")) .never else null,
        .reflog_action = action.items,
        .tz_offset_min = g.tz_offset_min,
    });
    defer r.deinit();
    switch (r.inner.kind) {
        .up_to_date => try out.writeAll("Already up to date.\n"),
        .fast_forward => try out.writeAll("Fast-forward\n"),
        .committed => try out.writeAll(if (r.mode == .rebase) "Successfully rebased.\n" else "Merge made by the 'ort' strategy.\n"),
        else => {},
    }
    return conflictsOut(r.inner, err);
}

fn cmdPush(g: *const Git, repo: *Repository, a: Allocator, rest: []const []const u8, out: *Io.Writer, err: *Io.Writer) !u8 {
    const args = try Args.parse(a, rest, &.{});
    const pos = args.pos.items;
    const remote = if (pos.len > 0) pos[0] else blk: {
        const b = (try repo.headRef(a)) orelse return error.DetachedHead;
        var kb: [512]u8 = undefined;
        break :blk repo.config.get(try std.fmt.bufPrint(&kb, "branch.{s}.pushremote", .{shortRef(b)})) orelse
            repo.config.get(try std.fmt.bufPrint(&kb, "branch.{s}.remote", .{shortRef(b)})) orelse "origin";
    };
    var specs: std.ArrayList([]const u8) = .empty;
    for (if (pos.len > 1) pos[1..] else &.{}) |s| {
        if (args.has("--delete") or args.has("-d")) {
            // A tag we have is deleted as a tag, anything else as a branch.
            const t = try std.fmt.allocPrint(a, "refs/tags/{s}", .{s});
            try specs.append(a, if (!std.mem.startsWith(u8, s, "refs/") and (try repo.refs.resolve(t)) != null) try std.fmt.allocPrint(a, ":{s}", .{t}) else try std.fmt.allocPrint(a, ":{s}", .{s}));
        } else try specs.append(a, s);
    }
    var c: Connector = g.connector();
    var r = try zg_git.remote.push.push(repo, remote, .{
        .refspecs = specs.items,
        .force = args.has("-f") or args.has("--force"),
        .force_with_lease = args.has("--force-with-lease"),
        .tags = args.has("--tags"),
        .set_upstream = args.has("-u") or args.has("--set-upstream"),
        .atomic = args.has("--atomic"),
        .tz_offset_min = g.tz_offset_min,
    }, c.get());
    defer r.deinit();
    const rem = (try zg_git.remote.config.get(repo, a, remote)) orelse return error.NoSuchRemote;
    try out.print("To {s}\n", .{rem.pushUrl()});
    var bad = false;
    for (r.refs) |x| {
        const what: []const u8 = switch (x.status) {
            .new => "* [new]",
            .fast_forward => "  ",
            .forced => "+ (forced)",
            .deleted => "- [deleted]",
            .up_to_date => "= [up to date]",
            .rejected_non_ff => "! [rejected] (non-fast-forward)",
            .rejected_fetch_first => "! [rejected] (fetch first)",
            .rejected_tag_exists => "! [rejected] (already exists)",
            .rejected_stale => "! [rejected] (stale info)",
            .remote_rejected => "! [remote rejected]",
        };
        if (!x.ok()) bad = true;
        try (if (x.ok()) out else err).print(" {s} {s} -> {s}\n", .{ what, shortRef(x.local), shortRef(x.remote) });
    }
    if (bad) {
        try err.writeAll("error: failed to push some refs; pull first if the remote has new commits\n");
        return 1;
    }
    return 0;
}

// -- merge, rebase, cherry-pick, revert ------------------------------------------------------

fn resultOut(r: bridge.common.Result, out: *Io.Writer, err: *Io.Writer) !u8 {
    switch (r.kind) {
        .up_to_date => try out.writeAll("Already up to date.\n"),
        .fast_forward => try out.writeAll("Fast-forward\n"),
        .committed => try out.writeAll("Done.\n"),
        .applied => try out.writeAll("Applied; not committed.\n"),
        .conflicted => {
            for (r.conflicts) |p| try err.print("CONFLICT (content): Merge conflict in {s}\n", .{p});
            try err.writeAll("Resolve the conflicts, stage the files, then continue (or abort).\n");
            return 1;
        },
    }
    return 0;
}

fn blockedOut(blocked: []const []const u8, err: *Io.Writer) !u8 {
    try err.writeAll("error: Your local changes to the following files would be overwritten:\n");
    for (blocked) |p| try err.print("\t{s}\n", .{p});
    try err.writeAll("Please commit your changes or stash them first.\n");
    return 1;
}

fn cmdMerge(g: *const Git, repo: *Repository, a: Allocator, rest: []const []const u8, out: *Io.Writer, err: *Io.Writer) !u8 {
    const args = try Args.parse(a, rest, &.{ "-m", "--message" });
    if (args.has("--abort")) {
        try bridge.merge.abort(repo);
        return 0;
    }
    if (args.has("--continue")) return cmdCommit(g, repo, a, &.{"--no-edit"}, out, err);
    if (args.pos.items.len == 0) return error.NothingToMerge;
    var blocked: std.ArrayList([]const u8) = .empty;
    var r = bridge.merge.merge(repo, args.pos.items[0], .{
        .ff = if (args.has("--ff-only")) .only else if (args.has("--no-ff")) .never else .allow,
        .commit = !args.has("--no-commit"),
        .message = args.get("-m") orelse args.get("--message"),
        .tz_offset_min = g.tz_offset_min,
        .blocked = .{ .list = &blocked, .gpa = a },
    }) catch |e| {
        if (e == error.WouldOverwrite) return blockedOut(blocked.items, err);
        return e;
    };
    defer r.deinit();
    if (r.kind == .committed) {
        try out.writeAll("Merge made by the 'ort' strategy.\n");
        return 0;
    }
    return resultOut(r, out, err);
}

fn cmdRebase(g: *const Git, repo: *Repository, a: Allocator, rest: []const []const u8, out: *Io.Writer, err: *Io.Writer) !u8 {
    const args = try Args.parse(a, rest, &.{"--onto"});
    const opts: bridge.rebase.Options = .{ .onto = args.get("--onto"), .tz_offset_min = g.tz_offset_min };
    if (args.has("--abort")) {
        try bridge.rebase.abort(repo);
        return 0;
    }
    if (args.has("-i") or args.has("--interactive")) {
        try err.writeAll("Interactive rebase needs an editor; reorder commits with cherry-pick instead.\n");
        return 1;
    }
    var r = if (args.has("--continue"))
        try bridge.rebase.continueRebase(repo, opts)
    else if (args.has("--skip"))
        try bridge.rebase.skip(repo, opts)
    else blk: {
        const up = if (args.pos.items.len > 0) args.pos.items[0] else "@{u}";
        break :blk try bridge.rebase.rebase(repo, up, opts);
    };
    defer r.deinit();
    if (r.kind == .committed) {
        try out.writeAll("Successfully rebased.\n");
        return 0;
    }
    return resultOut(r, out, err);
}

/// `cherry-pick` and `revert` (`words[0]` says which).
fn cmdPick(g: *const Git, repo: *Repository, a: Allocator, words: []const []const u8, out: *Io.Writer, err: *Io.Writer) !u8 {
    const is_revert = std.mem.eql(u8, words[0], "revert");
    const args = try Args.parse(a, words[1..], &.{ "-m", "--mainline" });
    if (args.has("--abort")) {
        try bridge.pick.abort(repo);
        return 0;
    }
    if (args.has("--continue")) return cmdCommit(g, repo, a, &.{"--no-edit"}, out, err);
    if (args.has("--skip")) {
        const head = (try repo.head()) orelse return error.UnbornHead;
        try zg_git.checkout.reset(repo, head, .hard, "HEAD", g.tz_offset_min);
        bridge.common.clearState(repo);
        return 0;
    }
    if (args.pos.items.len == 0) return error.MissingCommit;
    var blocked: std.ArrayList([]const u8) = .empty;
    const mainline: ?u32 = if (args.get("-m") orelse args.get("--mainline")) |m| std.fmt.parseInt(u32, m, 10) catch null else null;
    const opts: bridge.pick.Options = .{
        .commit = !(args.has("-n") or args.has("--no-commit")),
        .mainline = mainline,
        .tz_offset_min = g.tz_offset_min,
        .blocked = .{ .list = &blocked, .gpa = a },
    };
    for (args.pos.items) |rev| {
        var r = (if (is_revert) bridge.pick.revert(repo, rev, opts) else bridge.pick.cherryPick(repo, rev, opts)) catch |e| {
            if (e == error.WouldOverwrite) return blockedOut(blocked.items, err);
            return e;
        };
        defer r.deinit();
        const code = try resultOut(r, out, err);
        if (code != 0) return code;
    }
    return 0;
}

fn cmdBisect(g: *const Git, repo: *Repository, a: Allocator, rest: []const []const u8, out: *Io.Writer, err: *Io.Writer) !u8 {
    const bisect = zg_git.bisect;
    if (rest.len == 0) return error.Unsupported;
    const sub = rest[0];
    const args = rest[1..];
    var next: bisect.Next = .waiting;
    if (std.mem.eql(u8, sub, "start")) {
        var t: bisect.Terms = .{};
        var revs: std.ArrayList([]const u8) = .empty;
        for (args) |w| {
            if (std.mem.startsWith(u8, w, "--term-new=") or std.mem.startsWith(u8, w, "--term-bad=")) {
                t.bad = w[11..];
            } else if (std.mem.startsWith(u8, w, "--term-old=") or std.mem.startsWith(u8, w, "--term-good=")) {
                t.good = w[std.mem.indexOfScalar(u8, w, '=').? + 1 ..];
            } else if (std.mem.eql(u8, w, "--")) {
                break;
            } else if (std.mem.startsWith(u8, w, "-")) {
                try err.print("git bisect start {s}: not built into zigguro yet\n", .{w});
                return 1;
            } else try revs.append(a, w);
        }
        next = try bisect.start(repo, g.gpa, .{
            .bad = if (revs.items.len > 0) revs.items[0] else null,
            .goods = if (revs.items.len > 1) revs.items[1..] else &.{},
            .terms = t,
            .tz_offset_min = g.tz_offset_min,
        }, out);
    } else if (std.mem.eql(u8, sub, "reset")) {
        try bisect.reset(repo, g.gpa, if (args.len > 0) args[0] else null, g.tz_offset_min, null);
        return 0;
    } else if (std.mem.eql(u8, sub, "log")) {
        const l = try bisect.readLog(repo, a);
        try out.writeAll(l);
        return 0;
    } else if (std.mem.eql(u8, sub, "terms")) {
        if (!bisect.inProgress(repo)) return error.NotBisecting;
        const t = try bisect.terms(repo, a);
        try out.print("Your current terms are {s} for the old state\nand {s} for the new state.\n", .{ t.good, t.bad });
        return 0;
    } else if (std.mem.eql(u8, sub, "skip")) {
        next = try bisect.mark(repo, g.gpa, .skip, args, g.tz_offset_min, out);
    } else {
        if (!bisect.inProgress(repo)) return error.NotBisecting;
        const t = try bisect.terms(repo, a);
        const default_terms = std.mem.eql(u8, t.bad, "bad") and std.mem.eql(u8, t.good, "good");
        const m: bisect.Mark = if (std.mem.eql(u8, sub, t.bad) or (default_terms and std.mem.eql(u8, sub, "new")))
            .bad
        else if (std.mem.eql(u8, sub, t.good) or (default_terms and std.mem.eql(u8, sub, "old")))
            .good
        else {
            try err.print("git bisect {s}: not built into zigguro yet\n", .{sub});
            return 1;
        };
        next = try bisect.mark(repo, g.gpa, m, args, g.tz_offset_min, out);
    }
    switch (next) {
        // git shows the commit the way `git show --stat` does.
        .found => |id| {
            var hb: [64]u8 = undefined;
            return cmdShow(g, repo, a, &.{ "--stat", id.hex(&hb) }, out, err);
        },
        .only_skipped => return 2,
        else => return 0,
    }
}

fn cmdSubmodule(_: *const Git, repo: *Repository, a: Allocator, rest: []const []const u8, out: *Io.Writer, _: *Io.Writer) !u8 {
    _ = rest;
    var ix = try repo.readIndex();
    defer ix.deinit();
    var hb: [64]u8 = undefined;
    for (ix.entries.items) |e| {
        if (e.mode != 0o160000 or e.flags.stage != 0) continue;
        const gitfile = try std.fs.path.join(a, &.{ e.path, ".git" });
        const initialised = if (repo.work.statFile(repo.io, gitfile, .{})) |_| true else |_| false;
        try out.print("{c}{s} {s}\n", .{ @as(u8, if (initialised) ' ' else '-'), e.oid.hex(&hb), e.path });
    }
    return 0;
}

// -- tests --------------------------------------------------------------------

const testing = std.testing;

test "git: command lines" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try splitArgs(a, "git commit -m \"two words\" --amend");
    try testing.expectEqual(@as(usize, 4), args.len);
    try testing.expectEqualStrings("two words", args[2]);
    const p = try Args.parse(a, &.{ "-m", "msg", "--amend", "x", "--", "a b" }, &.{"-m"});
    try testing.expectEqualStrings("msg", p.get("-m").?);
    try testing.expect(p.has("--amend"));
    try testing.expectEqualStrings("x", p.pos.items[0]);
    try testing.expectEqualStrings("a b", p.after_dashdash.items[0]);
    try testing.expectEqual(@as(usize, 2), try stashIndex("stash@{2}"));
}

test "git: dates in the ident's own zone" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const who: zg_git.commit.Ident = .{ .name = "A", .email = "a@x", .time = 1700000000, .tz = "+0100" };
    try testing.expectEqualStrings("2023-11-14 23:13", try formatDate(a, who, .{ .format = "%Y-%m-%d %H:%M" }));
    try testing.expectEqualStrings("2023-11-14", try formatDate(a, who, .short));
    try testing.expectEqualStrings("Tue Nov 14 23:13:20 2023 +0100", try formatDate(a, who, .default));
}

/// A temporary repository made through the native commands.
fn testRepo(tmp: *testing.TmpDir, env: *std.process.Environ.Map) !Git {
    const io = testing.io;
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    // Never find the repository the test folder sits in.
    try env.put("GIT_CEILING_DIRECTORIES", std.fs.path.dirname(root).?);
    try env.put("HOME", root);
    try env.put("GIT_CONFIG_NOSYSTEM", "1");
    try env.put("GIT_AUTHOR_NAME", "Test");
    try env.put("GIT_AUTHOR_EMAIL", "t@example.com");
    try env.put("GIT_COMMITTER_NAME", "Test");
    try env.put("GIT_COMMITTER_EMAIL", "t@example.com");
    var g = try Git.init(testing.allocator, io, null, env, root);
    errdefer g.deinit();
    if (g.isRepo()) return error.SkipZigTest;
    const r = try g.run(testing.allocator, &.{ "init", "-q", "-b", "main" });
    defer r.deinit(testing.allocator);
    try testing.expect(r.ok());
    g.locate();
    return g;
}

fn expectRun(g: *const Git, args: []const []const u8) !void {
    const r = try g.run(testing.allocator, args);
    defer r.deinit(testing.allocator);
    if (!r.ok()) std.debug.print("git {s}: {s}{s}\n", .{ args[0], r.out, r.err });
    try testing.expect(r.ok());
}

test "git: a repository's status, commits, branches, tags and stash, natively" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    var g = try testRepo(&tmp, &env);
    defer g.deinit();
    try testing.expect(g.isRepo());
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one\n" });
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const s1 = try g.status(a);
    try testing.expectEqualStrings("main", s1.branch.?);
    try testing.expect(s1.oid == null);
    try testing.expectEqual(@as(usize, 1), s1.entries.len);
    try testing.expectEqual(Entry.Kind.untracked, s1.entries[0].kind);

    try expectRun(&g, &.{ "add", "--", "a.txt" });
    const s2 = try g.status(a);
    try testing.expect(s2.entries[0].staged());
    try expectRun(&g, &.{ "commit", "-m", "First" });
    try expectRun(&g, &.{ "branch", "topic" });
    try expectRun(&g, &.{ "tag", "v1" });
    try expectRun(&g, &.{ "tag", "-a", "v2", "Release two" });

    const commits = try g.log(a, 10, false);
    try testing.expectEqual(@as(usize, 1), commits.len);
    try testing.expectEqualStrings("First", commits[0].subject);
    try testing.expect(std.mem.indexOf(u8, commits[0].refs, "HEAD -> main") != null);
    try testing.expect(std.mem.indexOf(u8, commits[0].refs, "tag: v1") != null);
    const branches = try g.branches(a);
    try testing.expectEqual(@as(usize, 2), branches.len);
    try testing.expect(branches[0].head);
    const tg = try g.tags(a);
    try testing.expectEqual(@as(usize, 2), tg.len);

    // An unstaged change shows in the diff, then goes into a stash.
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "two\n" });
    const d = try g.run(gpa, &.{ "diff", "--", "a.txt" });
    defer d.deinit(gpa);
    try testing.expect(std.mem.indexOf(u8, d.out, "-one\n+two\n") != null);
    try expectRun(&g, &.{ "stash", "push", "-m", "wip" });
    const st = try g.stashes(a);
    try testing.expectEqual(@as(usize, 1), st.len);
    try testing.expectEqualStrings("stash@{0}", st[0].name);
    try testing.expectEqual(Op.none, g.operation());
    try expectRun(&g, &.{ "stash", "pop", "stash@{0}" });
    try expectRun(&g, &.{ "commit", "-a", "-m", "Second" });
    const show = try g.run(gpa, &.{ "show", "--stat", "--patch", "--format=fuller", "HEAD" });
    defer show.deinit(gpa);
    try testing.expect(std.mem.indexOf(u8, show.out, "a.txt | 2 +-") != null);

    // A conflicting merge stops, and --abort puts things back.
    try expectRun(&g, &.{ "checkout", "topic" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "three\n" });
    try expectRun(&g, &.{ "commit", "-a", "-m", "Topic" });
    try expectRun(&g, &.{ "checkout", "main" });
    const m = try g.run(gpa, &.{ "merge", "--no-edit", "topic" });
    defer m.deinit(gpa);
    try testing.expect(!m.ok());
    try testing.expectEqual(Op.merge, g.operation());
    try expectRun(&g, &.{ "merge", "--abort" });
    try testing.expectEqual(Op.none, g.operation());

    // A missing branch fails with a message.
    const bad = try g.run(gpa, &.{ "checkout", "no-such-branch" });
    defer bad.deinit(gpa);
    try testing.expect(!bad.ok());
    try testing.expect(bad.err.len > 0);
    const unknown = try g.run(gpa, &.{ "bisect", "run", "make" });
    defer unknown.deinit(gpa);
    try testing.expect(!unknown.ok());
}

test "git: bisect finds the first bad commit" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    var g = try testRepo(&tmp, &env);
    defer g.deinit();
    // c1..c6; the bug ("bad") arrives in c4.
    for (1..7) |i| {
        var buf: [16]u8 = undefined;
        try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = if (i >= 4) "bad\n" else "good\n" });
        try tmp.dir.writeFile(io, .{ .sub_path = "n.txt", .data = try std.fmt.bufPrint(&buf, "{d}\n", .{i}) });
        try expectRun(&g, &.{ "add", "-A" });
        try expectRun(&g, &.{ "commit", "-q", "-m", try std.fmt.bufPrint(&buf, "c{d}", .{i}) });
    }
    try expectRun(&g, &.{ "bisect", "start", "HEAD", "HEAD~5" });
    try testing.expectEqual(Op.bisect, g.operation());
    var steps: usize = 0;
    const found = while (steps < 10) : (steps += 1) {
        const text = try tmp.dir.readFileAlloc(io, "f.txt", gpa, .limited(64));
        defer gpa.free(text);
        const r = try g.run(gpa, &.{ "bisect", if (std.mem.eql(u8, text, "bad\n")) "bad" else "good" });
        defer r.deinit(gpa);
        try testing.expect(r.ok());
        if (std.mem.indexOf(u8, r.out, "is the first bad commit")) |_| {
            try testing.expect(std.mem.indexOf(u8, r.out, "    c4\n") != null);
            break true;
        }
    } else false;
    try testing.expect(found);
    const log = try g.run(gpa, &.{ "bisect", "log" });
    defer log.deinit(gpa);
    try testing.expect(std.mem.indexOf(u8, log.out, "# first bad commit: [") != null);
    try expectRun(&g, &.{ "bisect", "reset" });
    try testing.expectEqual(Op.none, g.operation());
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const st = try g.status(arena.allocator());
    try testing.expectEqualStrings("main", st.branch.?);
}

test "git: clone, fetch, pull and push over a local remote" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    var g = try testRepo(&tmp, &env);
    defer g.deinit();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one\n" });
    try expectRun(&g, &.{ "add", "-A", "--", "." });
    try expectRun(&g, &.{ "commit", "-m", "First" });

    // A clone next to it, inside the same folder.
    try expectRun(&g, &.{ "clone", g.root, "copy" });
    const copy_dir = try std.fs.path.join(gpa, &.{ g.root, "copy" });
    defer gpa.free(copy_dir);
    var c = try Git.init(gpa, io, null, &env, copy_dir);
    defer c.deinit();
    try testing.expect(c.isRepo());
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const cs = try c.status(a);
    try testing.expectEqualStrings("origin/main", cs.upstream.?);

    // The clone commits and pushes; the original pulls it back... into
    // a branch that is not checked out there (a push to the checked-out
    // branch is refused, as git refuses it).
    try expectRun(&c, &.{ "checkout", "-b", "feature" });
    try tmp.dir.writeFile(io, .{ .sub_path = "copy/b.txt", .data = "b\n" });
    try expectRun(&c, &.{ "add", "--", "b.txt" });
    try expectRun(&c, &.{ "commit", "-m", "Feature" });
    try expectRun(&c, &.{ "push", "-u", "origin", "feature" });
    const cs2 = try c.status(a);
    try testing.expectEqualStrings("origin/feature", cs2.upstream.?);
    try expectRun(&c, &.{ "fetch", "--all", "--prune" });
    try expectRun(&c, &.{"pull"});
    const remotes = try c.remotes(a);
    try testing.expectEqual(@as(usize, 1), remotes.len);
}
