//! `FsTree`: the Explorer's model (E08.F03.S01.T01): the workspace
//! folders as a tree of files and folders, read from disk lazily (a
//! folder is listed the first time it is opened) and kept fresh by
//! `refresh`, which re-lists every listed folder whose modification time
//! changed. Names sort naturally ("file2" before "file10"), folders first
//! by default. Entries `files.exclude` matches are hidden, and with
//! `respect_gitignore` so are the ones `.gitignore` ignores (through
//! zg_workspace's `IgnoreStack`, which also always hides `.git`).
//!
//! It also does the Explorer's file operations (E08.F03.S02): create,
//! rename, delete, copy and move, with name checks, then re-lists the
//! folders they touched.
//!
//! Node ids are stable across re-listing (a re-listed folder keeps the
//! ids of entries whose names did not change), so tree views keep their
//! expansion and selection. UI thread only.

const std = @import("std");
const builtin = @import("builtin");
const zg_workspace = @import("zg_workspace");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const IgnoreStack = zg_workspace.IgnoreStack;
const RootId = zg_workspace.RootId;

/// A node id (0 is none).
pub const Id = u32;

/// How siblings are ordered.
pub const SortOrder = enum { foldersFirst, mixed, filesFirst };

/// Filtering and ordering options.
pub const Options = struct {
    /// `files.exclude` patterns that are on (gitignore syntax).
    exclude: []const []const u8 = &.{ "**/.git", "**/.zig-cache" },
    respect_gitignore: bool = false,
    sort: SortOrder = .foldersFirst,
};

pub const Node = struct {
    parent: Id,
    /// The entry name; a root's absolute path.
    name: []u8,
    is_dir: bool,
    root: u16,
    /// Listed children, sorted (null: not listed yet).
    children: ?std.ArrayList(Id) = null,
    /// The folder's modification time when it was listed.
    mtime: i96 = 0,
    alive: bool = true,
};

/// Errors of the file operations.
pub const OpError = error{
    InvalidName,
    AlreadyExists,
    NotFound,
    /// A folder cannot be moved or copied into itself.
    IntoItself,
    OutOfMemory,
    Failed,
};

pub const FsTree = struct {
    gpa: Allocator,
    io: Io,
    nodes: std.ArrayList(Node) = .empty,
    roots: std.ArrayList(Id) = .empty,
    opts: Options = .{},
    /// Owned copies of `opts.exclude`.
    exclude_store: std.ArrayList([]u8) = .empty,
    ignore: ?*IgnoreStack = null,
    /// Bumped whenever any listing changes.
    revision: u64 = 0,

    pub fn init(gpa: Allocator, io: Io) FsTree {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(t: *FsTree) void {
        for (t.nodes.items) |*n| t.freeNode(n);
        t.nodes.deinit(t.gpa);
        t.roots.deinit(t.gpa);
        for (t.exclude_store.items) |e| t.gpa.free(e);
        t.exclude_store.deinit(t.gpa);
        if (t.ignore) |st| st.deinit();
    }

    fn freeNode(t: *FsTree, n: *Node) void {
        if (n.name.len > 0) t.gpa.free(n.name);
        n.name = &.{};
        if (n.children) |*c| c.deinit(t.gpa);
        n.children = null;
        n.alive = false;
    }

    pub fn node(t: *const FsTree, id: Id) *Node {
        return &t.nodes.items[id - 1];
    }

    pub fn get(t: *const FsTree, id: Id) ?*Node {
        if (id == 0 or id > t.nodes.items.len) return null;
        const n = &t.nodes.items[id - 1];
        return if (n.alive) n else null;
    }

    fn newNode(t: *FsTree, n: Node) !Id {
        try t.nodes.append(t.gpa, n);
        return @intCast(t.nodes.items.len);
    }

    /// Adds a workspace folder (an absolute path) and returns its node.
    pub fn addRoot(t: *FsTree, abs: []const u8) !Id {
        for (t.roots.items) |r| if (std.mem.eql(u8, t.node(r).name, abs)) return r;
        const name = try t.gpa.dupe(u8, abs);
        errdefer t.gpa.free(name);
        const id = try t.newNode(.{ .parent = 0, .name = name, .is_dir = true, .root = @intCast(t.roots.items.len) });
        try t.roots.append(t.gpa, id);
        try t.rebuildIgnore();
        t.revision +%= 1;
        return id;
    }

    /// Removes a workspace folder (not the first).
    pub fn removeRoot(t: *FsTree, id: Id) void {
        const i = std.mem.indexOfScalar(Id, t.roots.items, id) orelse return;
        if (i == 0) return;
        t.dropSubtree(id);
        _ = t.roots.orderedRemove(i);
        for (t.roots.items, 0..) |r, ri| t.setRoot(r, @intCast(ri));
        t.rebuildIgnore() catch {};
        t.revision +%= 1;
    }

    fn setRoot(t: *FsTree, id: Id, r: u16) void {
        const n = t.node(id);
        n.root = r;
        if (n.children) |c| for (c.items) |k| t.setRoot(k, r);
    }

    /// Applies new options: everything listed is listed again.
    pub fn setOptions(t: *FsTree, o: Options) !void {
        for (t.exclude_store.items) |e| t.gpa.free(e);
        t.exclude_store.clearRetainingCapacity();
        for (o.exclude) |e| try t.exclude_store.append(t.gpa, try t.gpa.dupe(u8, e));
        t.opts = .{ .exclude = @ptrCast(t.exclude_store.items), .respect_gitignore = o.respect_gitignore, .sort = o.sort };
        try t.rebuildIgnore();
        // By index: listing adds nodes.
        var i: usize = 0;
        while (i < t.nodes.items.len) : (i += 1) {
            const n = t.nodes.items[i];
            if (n.alive and n.children != null) t.list(@intCast(i + 1)) catch {};
        }
        t.revision +%= 1;
    }

    fn rebuildIgnore(t: *FsTree) !void {
        if (t.ignore) |st| st.deinit();
        t.ignore = null;
        const st = try IgnoreStack.init(t.gpa, t.io, @intCast(t.roots.items.len));
        errdefer st.deinit();
        for (t.roots.items, 0..) |r, ri| {
            const rid = RootId.of(@intCast(ri));
            const info = if (t.opts.respect_gitignore) t.readRel(r, ".git/info/exclude") else null;
            defer if (info) |b| t.gpa.free(b);
            try st.setGlobal(rid, info, null, t.opts.exclude);
            if (builtin.os.tag == .windows or builtin.os.tag == .macos) st.setCaseInsensitive(rid, true);
        }
        t.ignore = st;
    }

    fn readRel(t: *FsTree, root: Id, rel: []const u8) ?[]u8 {
        const p = std.fs.path.join(t.gpa, &.{ t.node(root).name, rel }) catch return null;
        defer t.gpa.free(p);
        return Io.Dir.cwd().readFileAlloc(t.io, p, t.gpa, .limited(1 << 20)) catch null;
    }

    /// The absolute path of `id` (caller frees).
    pub fn absPath(t: *const FsTree, id: Id) ![]u8 {
        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(t.gpa);
        var cur = id;
        while (cur != 0) {
            try parts.append(t.gpa, t.node(cur).name);
            cur = t.node(cur).parent;
        }
        std.mem.reverse([]const u8, parts.items);
        return std.fs.path.join(t.gpa, parts.items);
    }

    /// `id`'s path relative to its root, with '/' separators ("" for a root).
    pub fn relPath(t: *const FsTree, gpa: Allocator, id: Id) ![]u8 {
        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(gpa);
        var cur = id;
        while (cur != 0 and t.node(cur).parent != 0) {
            try parts.append(gpa, t.node(cur).name);
            cur = t.node(cur).parent;
        }
        std.mem.reverse([]const u8, parts.items);
        return std.mem.join(gpa, "/", parts.items);
    }

    /// The root folder of `id`.
    pub fn rootOf(t: *const FsTree, id: Id) Id {
        var cur = id;
        while (t.node(cur).parent != 0) cur = t.node(cur).parent;
        return cur;
    }

    /// `id`'s listed children, listing them first if needed.
    pub fn children(t: *FsTree, id: Id) []const Id {
        const n = t.node(id);
        if (!n.is_dir) return &.{};
        if (n.children == null) t.list(id) catch {};
        return if (t.node(id).children) |c| c.items else &.{};
    }

    fn dirMtime(t: *FsTree, abs: []const u8) i96 {
        const st = Io.Dir.cwd().statFile(t.io, abs, .{}) catch return 0;
        return st.mtime.nanoseconds;
    }

    /// Reads folder `id` from disk, keeping the ids of entries that stay.
    pub fn list(t: *FsTree, id: Id) !void {
        const abs = try t.absPath(id);
        defer t.gpa.free(abs);
        const root = t.rootOf(id);
        const rid = RootId.of(t.node(id).root);
        const rel_dir = try t.relPath(t.gpa, id);
        defer t.gpa.free(rel_dir);
        if (t.opts.respect_gitignore) if (t.ignore) |st| {
            const gi_path = try std.fs.path.join(t.gpa, &.{ abs, ".gitignore" });
            defer t.gpa.free(gi_path);
            const gi = Io.Dir.cwd().readFileAlloc(t.io, gi_path, t.gpa, .limited(1 << 20)) catch null;
            defer if (gi) |b| t.gpa.free(b);
            st.loadDir(rid, rel_dir, gi, null) catch {};
        };
        _ = root;

        var old: std.StringHashMapUnmanaged(Id) = .empty;
        defer old.deinit(t.gpa);
        if (t.node(id).children) |c| for (c.items) |k| try old.put(t.gpa, t.node(k).name, k);

        var next: std.ArrayList(Id) = .empty;
        errdefer next.deinit(t.gpa);
        var dir = Io.Dir.cwd().openDir(t.io, abs, .{ .iterate = true }) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => {
                t.setChildren(id, &next, &old, 0);
                return;
            },
            else => return error.Failed,
        };
        defer dir.close(t.io);
        var it = dir.iterate();
        while (it.next(t.io) catch null) |e| {
            var is_dir = e.kind == .directory;
            if (e.kind == .sym_link) {
                if (dir.statFile(t.io, e.name, .{})) |st| {
                    is_dir = st.kind == .directory;
                } else |_| {}
            }
            const rel = if (rel_dir.len == 0) try t.gpa.dupe(u8, e.name) else try std.mem.concat(t.gpa, u8, &.{ rel_dir, "/", e.name });
            defer t.gpa.free(rel);
            if (t.ignore) |st| if (st.isIgnoredInVisibleDir(rid, rel, is_dir).state == .ignored) continue;
            if (old.fetchRemove(e.name)) |kv| {
                const k = kv.value;
                if (t.node(k).is_dir != is_dir) {
                    t.dropSubtree(k);
                    try next.append(t.gpa, try t.newChild(id, e.name, is_dir));
                } else try next.append(t.gpa, k);
            } else try next.append(t.gpa, try t.newChild(id, e.name, is_dir));
        }
        const ctx: SortCtx = .{ .t = t };
        std.sort.pdq(Id, next.items, ctx, SortCtx.lessThan);
        t.setChildren(id, &next, &old, t.dirMtime(abs));
    }

    fn newChild(t: *FsTree, parent: Id, name: []const u8, is_dir: bool) !Id {
        const n = try t.gpa.dupe(u8, name);
        errdefer t.gpa.free(n);
        return t.newNode(.{ .parent = parent, .name = n, .is_dir = is_dir, .root = t.node(parent).root });
    }

    fn setChildren(t: *FsTree, id: Id, next: *std.ArrayList(Id), gone: *std.StringHashMapUnmanaged(Id), mtime: i96) void {
        var it = gone.valueIterator();
        while (it.next()) |k| t.dropSubtree(k.*);
        const n = t.node(id);
        // Only a different list of children is a change (not a touch).
        const same = if (n.children) |c| gone.count() == 0 and std.mem.eql(Id, c.items, next.items) else false;
        if (n.children) |*c| c.deinit(t.gpa);
        n.children = next.*;
        n.mtime = mtime;
        if (!same) t.revision +%= 1;
    }

    fn dropSubtree(t: *FsTree, id: Id) void {
        if (t.node(id).children) |c| for (c.items) |k| t.dropSubtree(k);
        t.freeNode(t.node(id));
    }

    const SortCtx = struct {
        t: *FsTree,
        fn lessThan(c: SortCtx, a: Id, b: Id) bool {
            const na = c.t.node(a);
            const nb = c.t.node(b);
            if (na.is_dir != nb.is_dir) switch (c.t.opts.sort) {
                .foldersFirst => return na.is_dir,
                .filesFirst => return !na.is_dir,
                .mixed => {},
            };
            return naturalLess(na.name, nb.name);
        }
    };

    /// Re-lists every listed folder whose modification time changed.
    /// Returns whether anything changed.
    pub fn refresh(t: *FsTree) bool {
        const before = t.revision;
        var i: usize = 0;
        while (i < t.nodes.items.len) : (i += 1) {
            const n = t.nodes.items[i];
            if (!n.alive or n.children == null) continue;
            const id: Id = @intCast(i + 1);
            const abs = t.absPath(id) catch continue;
            defer t.gpa.free(abs);
            if (t.dirMtime(abs) == n.mtime) continue;
            t.list(id) catch continue;
        }
        return t.revision != before;
    }

    /// Finds the node for absolute `abs`, listing folders on the way.
    pub fn find(t: *FsTree, abs: []const u8) ?Id {
        for (t.roots.items) |r| {
            const rp = t.node(r).name;
            if (!startsWithPath(abs, rp)) continue;
            var cur = r;
            var rest = std.mem.trimStart(u8, abs[rp.len..], "/\\");
            while (rest.len > 0) {
                const end = std.mem.indexOfAny(u8, rest, "/\\") orelse rest.len;
                const part = rest[0..end];
                cur = for (t.children(cur)) |k| {
                    if (namesEqual(t.node(k).name, part)) break k;
                } else return null;
                rest = std.mem.trimStart(u8, rest[end..], "/\\");
            }
            return cur;
        }
        return null;
    }

    // -- file operations ----------------------------------------------------

    /// Checks a new entry name.
    pub fn validName(name: []const u8) bool {
        if (name.len == 0 or name.len > 255) return false;
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
        for (name) |c| switch (c) {
            '/', '\\', 0 => return false,
            '<', '>', ':', '"', '|', '?', '*' => if (builtin.os.tag == .windows) return false,
            else => if (c < 0x20) return false,
        };
        if (builtin.os.tag == .windows and (name[name.len - 1] == '.' or name[name.len - 1] == ' ')) return false;
        return true;
    }

    /// The folder new entries go into for a selection of `id`: the node
    /// itself when it is a folder, else its parent.
    pub fn targetDir(t: *const FsTree, id: Id) Id {
        const n = t.node(id);
        return if (n.is_dir) id else n.parent;
    }

    /// The path `name` (may be nested) would have in folder `dir`
    /// (caller frees).
    pub fn childPath(t: *FsTree, dir: Id, name: []const u8) OpError![]u8 {
        if (!validName(name)) {
            // Nested paths ("src/new.zig") are allowed for creation.
            var parts = std.mem.tokenizeAny(u8, name, "/\\");
            var any = false;
            while (parts.next()) |p| {
                if (!validName(p)) return error.InvalidName;
                any = true;
            }
            if (!any) return error.InvalidName;
        }
        const base = t.absPath(dir) catch return error.OutOfMemory;
        defer t.gpa.free(base);
        return std.fs.path.join(t.gpa, &.{ base, name }) catch error.OutOfMemory;
    }

    fn exists(t: *FsTree, abs: []const u8) bool {
        _ = Io.Dir.cwd().statFile(t.io, abs, .{}) catch return false;
        return true;
    }

    /// Creates an empty file `name` (may hold '/' for new subfolders) in
    /// folder `dir`. Returns its absolute path (caller frees).
    pub fn createFile(t: *FsTree, dir: Id, name: []const u8) OpError![]u8 {
        const p = try t.childPath(dir, name);
        errdefer t.gpa.free(p);
        if (t.exists(p)) return error.AlreadyExists;
        if (std.fs.path.dirname(p)) |parent| Io.Dir.cwd().createDirPath(t.io, parent) catch return error.Failed;
        const f = Io.Dir.cwd().createFile(t.io, p, .{ .exclusive = true }) catch |e| return switch (e) {
            error.PathAlreadyExists => error.AlreadyExists,
            else => error.Failed,
        };
        f.close(t.io);
        t.relist(dir);
        return p;
    }

    /// Creates folder `name` (may be nested) in folder `dir`.
    pub fn createDir(t: *FsTree, dir: Id, name: []const u8) OpError![]u8 {
        const p = try t.childPath(dir, name);
        errdefer t.gpa.free(p);
        if (t.exists(p)) return error.AlreadyExists;
        Io.Dir.cwd().createDirPath(t.io, p) catch return error.Failed;
        t.relist(dir);
        return p;
    }

    /// Renames `id` to `name` in the same folder. Returns the new path.
    pub fn rename(t: *FsTree, id: Id, name: []const u8) OpError![]u8 {
        if (!validName(name)) return error.InvalidName;
        const n = t.node(id);
        if (n.parent == 0) return error.Failed;
        const old = t.absPath(id) catch return error.OutOfMemory;
        defer t.gpa.free(old);
        const p = try t.childPath(n.parent, name);
        errdefer t.gpa.free(p);
        // A case-only rename is allowed on case-insensitive file systems.
        if (!namesEqual(n.name, name) and t.exists(p)) return error.AlreadyExists;
        Io.Dir.cwd().rename(old, Io.Dir.cwd(), p, t.io) catch |e| return switch (e) {
            error.FileNotFound => error.NotFound,
            else => error.Failed,
        };
        t.relist(n.parent);
        return p;
    }

    /// Deletes `id` (a folder with everything in it).
    pub fn delete(t: *FsTree, id: Id) OpError!void {
        const n = t.node(id);
        if (n.parent == 0) return error.Failed;
        const parent = n.parent;
        const p = t.absPath(id) catch return error.OutOfMemory;
        defer t.gpa.free(p);
        if (n.is_dir) {
            Io.Dir.cwd().deleteTree(t.io, p) catch return error.Failed;
        } else Io.Dir.cwd().deleteFile(t.io, p) catch |e| return switch (e) {
            error.FileNotFound => error.NotFound,
            else => error.Failed,
        };
        t.relist(parent);
    }

    /// Copies or moves the entry at `src` (absolute) into folder `dir`.
    /// A copy whose name is taken becomes "name copy", "name copy 2", ...
    /// Returns the new path.
    pub fn paste(t: *FsTree, src: []const u8, dir: Id, move: bool) OpError![]u8 {
        const st = Io.Dir.cwd().statFile(t.io, src, .{}) catch return error.NotFound;
        const base = t.absPath(dir) catch return error.OutOfMemory;
        defer t.gpa.free(base);
        if (st.kind == .directory and startsWithPath(base, src)) return error.IntoItself;
        const name = std.fs.path.basename(src);
        var dest = std.fs.path.join(t.gpa, &.{ base, name }) catch return error.OutOfMemory;
        errdefer t.gpa.free(dest);
        if (move and std.mem.eql(u8, dest, src)) return dest;
        var n: u32 = 1;
        while (t.exists(dest)) : (n += 1) {
            if (move) return error.AlreadyExists;
            t.gpa.free(dest);
            const ext = std.fs.path.extension(name);
            const stem = if (st.kind == .directory) name else name[0 .. name.len - ext.len];
            const suffix = if (st.kind == .directory) "" else ext;
            const nn = if (n == 1)
                std.fmt.allocPrint(t.gpa, "{s} copy{s}", .{ stem, suffix })
            else
                std.fmt.allocPrint(t.gpa, "{s} copy {d}{s}", .{ stem, n, suffix });
            const nm = nn catch return error.OutOfMemory;
            defer t.gpa.free(nm);
            dest = std.fs.path.join(t.gpa, &.{ base, nm }) catch return error.OutOfMemory;
        }
        if (move) {
            Io.Dir.cwd().rename(src, Io.Dir.cwd(), dest, t.io) catch return error.Failed;
        } else if (st.kind == .directory) {
            copyTree(t.gpa, t.io, src, dest) catch return error.Failed;
        } else {
            Io.Dir.cwd().copyFile(src, Io.Dir.cwd(), dest, t.io, .{}) catch return error.Failed;
        }
        t.relist(dir);
        if (move) if (std.fs.path.dirname(src)) |sp| if (t.find(sp)) |sid| t.relist(sid);
        return dest;
    }

    fn relist(t: *FsTree, id: Id) void {
        if (t.get(id) == null) return;
        t.list(id) catch {};
    }
};

fn copyTree(gpa: Allocator, io: Io, src: []const u8, dest: []const u8) !void {
    try Io.Dir.cwd().createDirPath(io, dest);
    var dir = try Io.Dir.cwd().openDir(io, src, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        const s = try std.fs.path.join(gpa, &.{ src, e.name });
        defer gpa.free(s);
        const d = try std.fs.path.join(gpa, &.{ dest, e.name });
        defer gpa.free(d);
        if (e.kind == .directory) try copyTree(gpa, io, s, d) else try Io.Dir.cwd().copyFile(s, Io.Dir.cwd(), d, io, .{});
    }
}

fn isSep(c: u8) bool {
    return c == '/' or c == '\\';
}

/// Whether `path` is `prefix` or inside it.
pub fn startsWithPath(path: []const u8, prefix: []const u8) bool {
    if (path.len < prefix.len) return false;
    const head = path[0..prefix.len];
    const same = if (builtin.os.tag == .windows) std.ascii.eqlIgnoreCase(head, prefix) else std.mem.eql(u8, head, prefix);
    if (!same) return false;
    return path.len == prefix.len or isSep(path[prefix.len]) or (prefix.len > 0 and isSep(prefix[prefix.len - 1]));
}

fn namesEqual(a: []const u8, b: []const u8) bool {
    return if (builtin.os.tag == .windows or builtin.os.tag == .macos) std.ascii.eqlIgnoreCase(a, b) else std.mem.eql(u8, a, b);
}

/// Natural, case-insensitive order: digit runs compare by value.
pub fn naturalLess(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        if (std.ascii.isDigit(a[i]) and std.ascii.isDigit(b[j])) {
            var ie = i;
            while (ie < a.len and std.ascii.isDigit(a[ie])) ie += 1;
            var je = j;
            while (je < b.len and std.ascii.isDigit(b[je])) je += 1;
            const da = std.mem.trimStart(u8, a[i..ie], "0");
            const db = std.mem.trimStart(u8, b[j..je], "0");
            if (da.len != db.len) return da.len < db.len;
            switch (std.mem.order(u8, da, db)) {
                .lt => return true,
                .gt => return false,
                .eq => {},
            }
            i = ie;
            j = je;
            continue;
        }
        const ca = std.ascii.toLower(a[i]);
        const cb = std.ascii.toLower(b[j]);
        if (ca != cb) return ca < cb;
        i += 1;
        j += 1;
    }
    if (a.len - i != b.len - j) return a.len - i < b.len - j;
    // Equal ignoring case: a stable tie-break.
    return std.mem.lessThan(u8, a, b);
}

const testing = std.testing;

fn names(t: *FsTree, id: Id, buf: *std.ArrayList(u8)) ![]const u8 {
    buf.clearRetainingCapacity();
    for (t.children(id), 0..) |k, i| {
        if (i > 0) try buf.append(testing.allocator, ' ');
        try buf.appendSlice(testing.allocator, t.node(k).name);
        if (t.node(k).is_dir) try buf.append(testing.allocator, '/');
    }
    return buf.items;
}

test "fs_tree: natural order" {
    try testing.expect(naturalLess("file2", "file10"));
    try testing.expect(!naturalLess("file10", "file2"));
    try testing.expect(naturalLess("a", "B"));
    try testing.expect(naturalLess("x1", "x01a"));
}

test "fs_tree: lists lazily, sorts, hides excluded and keeps ids" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    for ([_][]const u8{ "b10.txt", "b2.txt", "A.md", "src/main.zig", "src/lib/x.zig", "zig-out/bin/app", ".zig-cache/h/1", "build.log" }) |p| {
        if (std.fs.path.dirname(p)) |d| try tmp.dir.createDirPath(io, d);
        try tmp.dir.writeFile(io, .{ .sub_path = p, .data = "x" });
    }
    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "*.log\nzig-out/\n" });
    const root_abs = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root_abs);

    var t: FsTree = .init(testing.allocator, io);
    defer t.deinit();
    const r = try t.addRoot(root_abs);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try testing.expectEqualStrings("src/ zig-out/ .gitignore A.md b2.txt b10.txt build.log", try names(&t, r, &buf));

    const src = t.children(r)[0];
    try testing.expectEqualStrings("lib/ main.zig", try names(&t, src, &buf));

    // .gitignore, mixed order.
    try t.setOptions(.{ .respect_gitignore = true, .sort = .mixed });
    try testing.expectEqualStrings(".gitignore A.md b2.txt b10.txt src/", try names(&t, r, &buf));
    try testing.expectEqual(src, t.children(r)[4]);
    try testing.expect(t.node(src).children != null);

    // Changes on disk show after refresh.
    try tmp.dir.writeFile(io, .{ .sub_path = "c.txt", .data = "" });
    // The clock may not tick between listing and the write.
    t.node(r).mtime = 0;
    try testing.expect(t.refresh());
    try testing.expectEqualStrings(".gitignore A.md b2.txt b10.txt c.txt src/", try names(&t, r, &buf));

    // find lists the way down.
    const x = try std.fs.path.join(testing.allocator, &.{ root_abs, "src", "lib", "x.zig" });
    defer testing.allocator.free(x);
    const xid = t.find(x).?;
    try testing.expectEqualStrings("x.zig", t.node(xid).name);
    const rel = try t.relPath(testing.allocator, xid);
    defer testing.allocator.free(rel);
    try testing.expectEqualStrings("src/lib/x.zig", rel);
}

test "fs_tree: file operations" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const gpa = testing.allocator;
    try tmp.dir.createDirPath(io, "docs");
    try tmp.dir.writeFile(io, .{ .sub_path = "docs/a.md", .data = "hello" });
    const root_abs = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root_abs);
    var t: FsTree = .init(gpa, io);
    defer t.deinit();
    const r = try t.addRoot(root_abs);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    _ = try names(&t, r, &buf);

    gpa.free(try t.createFile(r, "new.zig"));
    try testing.expectError(error.AlreadyExists, t.createFile(r, "new.zig"));
    try testing.expectError(error.InvalidName, t.createFile(r, ".."));
    gpa.free(try t.createFile(r, "src/deep/file.zig"));
    gpa.free(try t.createDir(r, "empty"));
    try testing.expectEqualStrings("docs/ empty/ src/ new.zig", try names(&t, r, &buf));

    const nz = t.children(r)[3];
    gpa.free(try t.rename(nz, "renamed.zig"));
    try testing.expectEqualStrings("docs/ empty/ src/ renamed.zig", try names(&t, r, &buf));
    // The renamed entry keeps nothing of the old id; the folder keeps its ids.
    const docs = t.children(r)[0];

    // Copy a file twice: "a copy.md", then "a copy 2.md".
    const a = try std.fs.path.join(gpa, &.{ root_abs, "docs", "a.md" });
    defer gpa.free(a);
    gpa.free(try t.paste(a, docs, false));
    gpa.free(try t.paste(a, docs, false));
    try testing.expectEqualStrings("a copy 2.md a copy.md a.md", try names(&t, docs, &buf));
    // Copy a folder into another one, then move it back.
    const docs_abs = try t.absPath(docs);
    defer gpa.free(docs_abs);
    const empty = t.children(r)[1];
    try testing.expectError(error.IntoItself, t.paste(docs_abs, docs, false));
    const copied = try t.paste(docs_abs, empty, false);
    defer gpa.free(copied);
    try testing.expectEqualStrings("docs/", try names(&t, empty, &buf));
    gpa.free(try t.paste(copied, r, false));
    try testing.expectEqualStrings("docs/ docs copy/ empty/ src/ renamed.zig", try names(&t, r, &buf));

    // Move.
    const ren = try std.fs.path.join(gpa, &.{ root_abs, "renamed.zig" });
    defer gpa.free(ren);
    gpa.free(try t.paste(ren, t.children(r)[3], true));
    try testing.expectEqualStrings("docs/ docs copy/ empty/ src/", try names(&t, r, &buf));

    // Delete a folder with contents.
    try t.delete(t.children(r)[1]);
    try testing.expectEqualStrings("docs/ empty/ src/", try names(&t, r, &buf));
}

test "fs_tree: several roots" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const gpa = testing.allocator;
    try tmp.dir.createDirPath(io, "one");
    try tmp.dir.createDirPath(io, "two/sub");
    const base = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(base);
    const one = try std.fs.path.join(gpa, &.{ base, "one" });
    defer gpa.free(one);
    const two = try std.fs.path.join(gpa, &.{ base, "two" });
    defer gpa.free(two);
    var t: FsTree = .init(gpa, io);
    defer t.deinit();
    _ = try t.addRoot(one);
    const r2 = try t.addRoot(two);
    try testing.expectEqual(r2, try t.addRoot(two));
    try testing.expectEqual(@as(usize, 1), t.children(r2).len);
    const sub = try std.fs.path.join(gpa, &.{ two, "sub" });
    defer gpa.free(sub);
    try testing.expect(t.find(sub) != null);
    t.removeRoot(r2);
    try testing.expectEqual(@as(usize, 1), t.roots.items.len);
    try testing.expect(t.find(sub) == null);
}
