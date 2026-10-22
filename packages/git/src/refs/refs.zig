//! The files ref store: loose refs, `packed-refs`, symrefs and per-worktree
//! refs. Shared refs live in `$GIT_COMMON_DIR` (named by the `commondir`
//! file of a linked worktree); `HEAD`, other pseudo-refs and `refs/bisect/`,
//! `refs/worktree/`, `refs/rewritten/` live in the worktree's `$GIT_DIR`.

const std = @import("std");
const oid_mod = @import("../oid.zig");
const packed_mod = @import("packed.zig");
const Oid = oid_mod.Oid;
const ObjectFormat = oid_mod.ObjectFormat;
const Allocator = std.mem.Allocator;

/// Errors from ref reads.
pub const ReadError = error{ CorruptRef, SymrefLoop } || Allocator.Error || std.Io.Dir.ReadFileAllocError ||
    packed_mod.Error;

/// A ref's stored value. `symbolic` is owned by the allocator passed to
/// `read` (see `deinit`).
pub const RefValue = union(enum) {
    /// Points at an object.
    direct: Oid,
    /// Points at another ref ("ref: refs/heads/main").
    symbolic: []const u8,

    /// Frees a symbolic target.
    pub fn deinit(v: RefValue, gpa: Allocator) void {
        switch (v) {
            .symbolic => |s| gpa.free(s),
            .direct => {},
        }
    }
};

/// One ref from `iterate`.
pub const Ref = struct {
    /// Full name (owned by the list).
    name: []const u8,
    /// Value (symbolic targets owned by the list).
    value: RefValue,
    /// Peeled object of an annotated tag, when packed-refs recorded it.
    peeled: ?Oid = null,
};

/// The result of `iterate`.
pub const RefList = struct {
    /// Refs sorted by name.
    refs: []Ref,
    arena: std.heap.ArenaAllocator,

    /// Frees the list.
    pub fn deinit(l: *RefList) void {
        l.arena.deinit();
        l.* = undefined;
    }
};

/// Options for `RefStore.open`.
pub const Options = struct {
    /// How long to wait for a contended ref lock.
    lock_timeout_ms: u32 = 1000,
    /// `core.logAllRefUpdates`: write reflogs for HEAD, branches,
    /// remote-tracking refs and notes.
    log_all_ref_updates: bool = true,
    /// fsync ref files (`core.fsync` includes refs).
    fsync: bool = false,
};

/// Whether `name` is a per-worktree ref (stored in `$GIT_DIR`).
pub fn isPerWorktree(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "refs/")) return true; // HEAD, ORIG_HEAD, ...
    for ([_][]const u8{ "refs/bisect/", "refs/worktree/", "refs/rewritten/" }) |p| {
        if (std.mem.startsWith(u8, name, p)) return true;
    }
    return false;
}

/// See the file comment.
pub const RefStore = struct {
    gpa: Allocator,
    io: std.Io,
    format: ObjectFormat,
    /// The worktree's `$GIT_DIR` (borrowed).
    git_dir: std.Io.Dir,
    /// `$GIT_COMMON_DIR`; equal to `git_dir` in the main worktree.
    common_dir: std.Io.Dir,
    owns_common: bool,
    opts: Options,

    /// Opens the ref store of `git_dir` (borrowed). Fails with
    /// `error.UnsupportedRefStorage` on reftable repositories.
    pub fn open(gpa: Allocator, io: std.Io, git_dir: std.Io.Dir, fmt: ObjectFormat, opts: Options) !RefStore {
        var common = git_dir;
        var owns = false;
        if (git_dir.readFileAlloc(io, "commondir", gpa, .limited(4096))) |text| {
            defer gpa.free(text);
            const p = std.mem.trim(u8, text, " \r\n");
            common = if (std.fs.path.isAbsolute(p)) try std.Io.Dir.openDirAbsolute(io, p, .{}) else try git_dir.openDir(io, p, .{});
            owns = true;
        } else |e| switch (e) {
            error.FileNotFound => {},
            else => |x| return x,
        }
        errdefer if (owns) common.close(io);
        if (common.access(io, "reftable", .{})) |_| {
            return error.UnsupportedRefStorage;
        } else |_| {}
        return .{ .gpa = gpa, .io = io, .format = fmt, .git_dir = git_dir, .common_dir = common, .owns_common = owns, .opts = opts };
    }

    /// Closes the common dir if this store opened it.
    pub fn close(rs: *RefStore) void {
        if (rs.owns_common) rs.common_dir.close(rs.io);
        rs.* = undefined;
    }

    /// Directory holding the loose file and reflog of `name`.
    pub fn dirFor(rs: *const RefStore, name: []const u8) std.Io.Dir {
        return if (isPerWorktree(name)) rs.git_dir else rs.common_dir;
    }

    /// Parses a loose ref file.
    pub fn parseLoose(gpa: Allocator, fmt: ObjectFormat, text: []const u8) (error{CorruptRef} || Allocator.Error)!RefValue {
        const s = std.mem.trimEnd(u8, text, " \r\n");
        if (std.mem.startsWith(u8, s, "ref:")) {
            const target = std.mem.trim(u8, s[4..], " \t");
            if (target.len == 0) return error.CorruptRef;
            return .{ .symbolic = try gpa.dupe(u8, target) };
        }
        if (s.len < fmt.hexLen()) return error.CorruptRef;
        // git ignores anything after the hex (e.g. FETCH_HEAD annotations).
        if (s.len > fmt.hexLen() and !std.ascii.isWhitespace(s[fmt.hexLen()])) return error.CorruptRef;
        return .{ .direct = Oid.parseHex(fmt, s[0..fmt.hexLen()]) catch return error.CorruptRef };
    }

    fn readLoose(rs: *RefStore, gpa: Allocator, name: []const u8) ReadError!?RefValue {
        const text = rs.dirFor(name).readFileAlloc(rs.io, name, gpa, .limited(4096)) catch |e| switch (e) {
            error.FileNotFound, error.IsDir, error.NotDir => return null,
            else => |x| return x,
        };
        defer gpa.free(text);
        return try parseLoose(gpa, rs.format, text);
    }

    /// Reads one ref without following symrefs; loose wins over packed.
    pub fn read(rs: *RefStore, gpa: Allocator, name: []const u8) ReadError!?RefValue {
        if (try rs.readLoose(gpa, name)) |v| return v;
        if (isPerWorktree(name)) return null;
        var p = try packed_mod.PackedRefs.load(rs.gpa, rs.io, rs.common_dir, rs.format);
        defer p.deinit(rs.gpa);
        if (p.find(name)) |r| return .{ .direct = r.oid };
        return null;
    }

    /// Follows symrefs (at most 5 levels) to an object ID; null when the
    /// chain ends at a missing ref (an unborn branch).
    pub fn resolve(rs: *RefStore, name: []const u8) ReadError!?Oid {
        var buf: [2][256]u8 = undefined;
        var cur: []const u8 = name;
        var depth: usize = 0;
        while (depth <= 5) : (depth += 1) {
            const v = (try rs.read(rs.gpa, cur)) orelse return null;
            switch (v) {
                .direct => |id| return id,
                .symbolic => |target| {
                    defer rs.gpa.free(target);
                    if (target.len > 256) return error.CorruptRef;
                    const slot = &buf[depth % 2];
                    @memcpy(slot[0..target.len], target);
                    cur = slot[0..target.len];
                },
            }
        }
        return error.SymrefLoop;
    }

    /// Follows symrefs and returns the final ref name (which may not exist
    /// yet, e.g. HEAD on an unborn branch).
    pub fn resolveName(rs: *RefStore, gpa: Allocator, name: []const u8) ReadError![]u8 {
        var cur = try gpa.dupe(u8, name);
        errdefer gpa.free(cur);
        var depth: usize = 0;
        while (depth <= 5) : (depth += 1) {
            const v = (try rs.read(gpa, cur)) orelse return cur;
            switch (v) {
                .direct => return cur,
                .symbolic => |target| {
                    gpa.free(cur);
                    cur = @constCast(target);
                },
            }
        }
        return error.SymrefLoop;
    }

    /// All refs whose name starts with `prefix` (e.g. "refs/heads/" or ""),
    /// merged from loose files (both directories) and packed-refs, sorted.
    /// HEAD and other top-level pseudo-refs are not listed.
    pub fn iterate(rs: *RefStore, gpa: Allocator, prefix: []const u8) !RefList {
        var list: RefList = .{ .refs = &.{}, .arena = .init(gpa) };
        errdefer list.arena.deinit();
        const a = list.arena.allocator();
        var out: std.ArrayList(Ref) = .empty;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(gpa);
        for ([_]std.Io.Dir{ rs.git_dir, rs.common_dir }, 0..) |dir, k| {
            if (k == 1 and rs.owns_common == false) break; // same directory
            var refs_dir = dir.openDir(rs.io, "refs", .{ .iterate = true }) catch |e| switch (e) {
                error.FileNotFound => continue,
                else => |x| return x,
            };
            defer refs_dir.close(rs.io);
            var walker = try refs_dir.walk(gpa);
            defer walker.deinit();
            while (try walker.next(rs.io)) |e| {
                if (e.kind != .file) continue;
                if (std.mem.endsWith(u8, e.basename, ".lock")) continue;
                const name = try std.fmt.allocPrint(a, "refs/{s}", .{e.path});
                if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, name, std.fs.path.sep, '/');
                if (!std.mem.startsWith(u8, name, prefix)) continue;
                // Per-worktree refs come from $GIT_DIR only, shared ones from the common dir only.
                if (rs.owns_common and isPerWorktree(name) != (k == 0)) continue;
                if (seen.contains(name)) continue;
                const text = e.dir.readFileAlloc(rs.io, e.basename, gpa, .limited(4096)) catch continue;
                defer gpa.free(text);
                const v = parseLoose(a, rs.format, text) catch continue; // git skips broken refs too
                try seen.put(gpa, name, {});
                try out.append(a, .{ .name = name, .value = v });
            }
        }
        var p = try packed_mod.PackedRefs.load(gpa, rs.io, rs.common_dir, rs.format);
        defer p.deinit(gpa);
        for (p.refs) |r| {
            if (!std.mem.startsWith(u8, r.name, prefix)) continue;
            if (seen.contains(r.name)) continue;
            try out.append(a, .{ .name = try a.dupe(u8, r.name), .value = .{ .direct = r.oid }, .peeled = r.peeled });
        }
        std.mem.sort(Ref, out.items, {}, struct {
            fn lt(_: void, x: Ref, y: Ref) bool {
                return std.mem.order(u8, x.name, y.name) == .lt;
            }
        }.lt);
        list.refs = out.items;
        return list;
    }

    /// Starts an atomic multi-ref update.
    pub fn transaction(rs: *RefStore) @import("transaction.zig").RefTransaction {
        return .init(rs);
    }
};
