//! `IgnoreStack`: every ignore source of a workspace combined with git's
//! precedence into one `isIgnored` query per path.
//!
//! Precedence, highest first (the first source with a matching line decides,
//! and within one file the last matching line wins):
//!   1. settings `files.exclude` globs (ignore only, no negation)
//!   2. `.zgignore` in the path's directory, then each ancestor up to the root
//!   3. `.gitignore`, the same way (deeper files win)
//!   4. `.git/info/exclude`
//!   5. `core.excludesFile`
//!   6. built-in rules: `.hg/`, `.svn/`, `.zigguro/cache/`, `.DS_Store`
//!
//! Hard ignores sit above all of them: `.git` (at any depth), `.zg/` and
//! `/.zigguro/review/` are never visible, whatever a negation or setting says
//! (the E12 review store relies on this).
//!
//! The parent-excluded rule of gitignore(5) holds: when any ancestor
//! directory is ignored the path is ignored, so a file under an ignored
//! directory cannot be re-included. `isIgnored` checks ancestors itself;
//! `isIgnoredInVisibleDir` skips that for callers (the scanner) that only ask
//! about entries of directories already known to be visible.
//!
//! Thread safety: queries take a shared lock, `loadDir`/`unloadDir`/
//! `setGlobal` an exclusive one, so watch-filter callbacks on other threads
//! may query while the watch pipeline reloads an ignore file.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zg_ignore = @import("zg_ignore");
const RootId = @import("../ids.zig").RootId;

const Rule = zg_ignore.Rule;
const RuleList = zg_ignore.RuleList;

/// The answer to an ignore query.
pub const Verdict = struct {
    /// `.none`: no rule matched; `.ignored`/`.included`: the deciding rule
    /// ignores or (by negation) re-includes the path.
    state: State,
    /// The deciding rule, if any.
    rule: ?*const Rule = null,
    /// Root-relative directory of the ignore file that holds `rule`
    /// (`""` for root-level and global sources). Valid until the next reload.
    base: []const u8 = "",
    /// Whether the verdict came from a hard ignore that nothing can undo.
    hard: bool = false,

    /// Verdict states.
    pub const State = enum { none, ignored, included };

    /// Whether the path is hidden.
    pub fn isIgnored(v: Verdict) bool {
        return v.state == .ignored;
    }
};

/// The watcher filter shape E01 (`zg_platform.fswatch.IgnoreFilter`)
/// consumes: thread-safe, answers for root-relative paths.
pub const WatchFilter = struct {
    /// Opaque context passed back to `isIgnored`.
    ctx: *anyopaque,
    /// Returns true when the path must not be watched or reported.
    isIgnored: *const fn (ctx: *anyopaque, rel_path: []const u8, is_dir: bool) bool,
};

const Level = struct {
    arena: std.heap.ArenaAllocator,
    dir: []const u8,
    gitignore: RuleList = .empty,
    zgignore: RuleList = .empty,
};

const RootState = struct {
    stack: *IgnoreStack,
    root: RootId,
    casefold: bool = false,
    globals: ?*Level = null,
    settings: RuleList = .empty,
    info_exclude: RuleList = .empty,
    core_excludes: RuleList = .empty,
    levels: std.StringHashMapUnmanaged(*Level) = .empty,
};

const hard_lines = ".git\n.zg/\n/.zigguro/review/\n";
const builtin_lines = ".hg/\n.svn/\n/.zigguro/cache/\n.DS_Store\n";

/// Combined ignore state for every root of a workspace.
pub const IgnoreStack = struct {
    gpa: Allocator,
    io: std.Io,
    lock: std.Io.RwLock = .init,
    roots: []RootState,
    builtin_arena: std.heap.ArenaAllocator,
    hard: RuleList,
    builtin: RuleList,
    /// Directory verdict cache (see `DirCache`).
    dir_cache: DirCache = .{},

    /// Creates a stack for `root_count` roots with only the built-in rules.
    pub fn init(gpa: Allocator, io: std.Io, root_count: u16) !*IgnoreStack {
        const st = try gpa.create(IgnoreStack);
        errdefer gpa.destroy(st);
        st.* = .{
            .gpa = gpa,
            .io = io,
            .roots = try gpa.alloc(RootState, root_count),
            .builtin_arena = .init(gpa),
            .hard = undefined,
            .builtin = undefined,
        };
        const a = st.builtin_arena.allocator();
        st.hard = try zg_ignore.parseRules(a, hard_lines, .builtin);
        st.builtin = try zg_ignore.parseRules(a, builtin_lines, .builtin);
        for (st.roots, 0..) |*r, i| r.* = .{ .stack = st, .root = .of(@intCast(i)) };
        return st;
    }

    /// Frees every level.
    pub fn deinit(st: *IgnoreStack) void {
        for (st.roots) |*r| {
            var it = r.levels.valueIterator();
            while (it.next()) |l| freeLevel(st.gpa, l.*);
            r.levels.deinit(st.gpa);
            if (r.globals) |g| freeLevel(st.gpa, g);
        }
        st.gpa.free(st.roots);
        st.builtin_arena.deinit();
        st.gpa.destroy(st);
    }

    /// Adds a root slot (for `Workspace.addRoot`) and returns its id.
    pub fn addRoot(st: *IgnoreStack) !RootId {
        st.lock.lockUncancelable(st.io);
        defer st.lock.unlock(st.io);
        st.dir_cache.invalidate();
        const n = st.roots.len;
        const grown = try st.gpa.realloc(st.roots, n + 1);
        st.roots = grown;
        st.roots[n] = .{ .stack = st, .root = .of(@intCast(n)) };
        return .of(@intCast(n));
    }

    /// Marks a root case-insensitive (its filesystem folds case).
    pub fn setCaseInsensitive(st: *IgnoreStack, root: RootId, yes: bool) void {
        st.lock.lockUncancelable(st.io);
        defer st.lock.unlock(st.io);
        st.dir_cache.invalidate();
        st.roots[root.index()].casefold = yes;
    }

    /// Replaces a root's global sources: the bytes of `.git/info/exclude` and
    /// `core.excludesFile` (null when absent) and the `files.exclude` globs.
    pub fn setGlobal(st: *IgnoreStack, root: RootId, git_info_exclude: ?[]const u8, core_excludes: ?[]const u8, settings_globs: []const []const u8) !void {
        const lvl = try st.gpa.create(Level);
        lvl.* = .{ .arena = .init(st.gpa), .dir = "" };
        errdefer freeLevel(st.gpa, lvl);
        const a = lvl.arena.allocator();
        const info = if (git_info_exclude) |b| try zg_ignore.parseRules(a, b, .git_info_exclude) else RuleList.empty;
        const core = if (core_excludes) |b| try zg_ignore.parseRules(a, b, .core_excludes_file) else RuleList.empty;
        var rules: std.ArrayList(Rule) = .empty;
        for (settings_globs, 0..) |g, i| {
            var expanded: std.ArrayList([]const u8) = .empty;
            try zg_ignore.expandBraces(a, g, &expanded);
            for (expanded.items) |e| {
                var p = e;
                if (std.mem.startsWith(u8, p, "./")) p = try std.mem.concat(a, u8, &.{ "/", p[2..] });
                // Settings only ignore: a leading '!' is part of the name.
                if (p.len > 0 and p[0] == '!') p = try std.mem.concat(a, u8, &.{ "\\", p });
                if (try zg_ignore.parseLine(a, p, .setting_files_exclude, @intCast(i + 1))) |r| try rules.append(a, r);
            }
        }
        const settings = try zg_ignore.indexRules(a, rules.items);

        st.lock.lockUncancelable(st.io);
        st.dir_cache.invalidate();
        const r = &st.roots[root.index()];
        const old = r.globals;
        r.globals = lvl;
        r.info_exclude = info;
        r.core_excludes = core;
        r.settings = settings;
        st.lock.unlock(st.io);
        if (old) |o| freeLevel(st.gpa, o);
    }

    /// Loads (or replaces) the ignore files of `rel_dir` (root-relative,
    /// `""` for the root) from their bytes. Both null unloads the level.
    pub fn loadDir(st: *IgnoreStack, root: RootId, rel_dir: []const u8, gitignore: ?[]const u8, zgignore: ?[]const u8) !void {
        if (gitignore == null and zgignore == null) return st.unloadDir(root, rel_dir);
        const lvl = try st.gpa.create(Level);
        lvl.* = .{ .arena = .init(st.gpa), .dir = "" };
        errdefer freeLevel(st.gpa, lvl);
        const a = lvl.arena.allocator();
        lvl.dir = try a.dupe(u8, rel_dir);
        if (gitignore) |b| lvl.gitignore = try zg_ignore.parseRules(a, b, .gitignore);
        if (zgignore) |b| lvl.zgignore = try zg_ignore.parseRules(a, b, .zgignore);

        st.lock.lockUncancelable(st.io);
        st.dir_cache.invalidate();
        const r = &st.roots[root.index()];
        const gop = r.levels.getOrPut(st.gpa, lvl.dir) catch |err| {
            st.lock.unlock(st.io);
            return err;
        };
        const old: ?*Level = if (gop.found_existing) gop.value_ptr.* else null;
        gop.key_ptr.* = lvl.dir;
        gop.value_ptr.* = lvl;
        st.lock.unlock(st.io);
        if (old) |o| freeLevel(st.gpa, o);
    }

    /// Drops the ignore files of `rel_dir`.
    pub fn unloadDir(st: *IgnoreStack, root: RootId, rel_dir: []const u8) void {
        st.lock.lockUncancelable(st.io);
        st.dir_cache.invalidate();
        const r = &st.roots[root.index()];
        const old = r.levels.fetchRemove(rel_dir);
        st.lock.unlock(st.io);
        if (old) |kv| freeLevel(st.gpa, kv.value);
    }

    /// Whether `rel_path` is ignored, applying the parent-excluded rule.
    pub fn isIgnored(st: *const IgnoreStack, root: RootId, rel_path: []const u8, is_dir: bool) Verdict {
        const self = @constCast(st);
        self.lock.lockSharedUncancelable(st.io);
        defer self.lock.unlockShared(st.io);
        const r = &st.roots[root.index()];
        if (std.mem.lastIndexOfScalar(u8, rel_path, '/')) |slash| {
            if (st.dirIgnoredLocked(r, rel_path[0..slash])) {
                // Rare: find the ancestor rule for the caller.
                var i: usize = 0;
                while (std.mem.indexOfScalarPos(u8, rel_path, i, '/')) |s| : (i = s + 1) {
                    const v = st.verdictLocked(r, rel_path[0..s], true);
                    if (v.state == .ignored) return v;
                }
            }
        }
        return st.verdictLocked(r, rel_path, is_dir);
    }

    /// Fast boolean form of `isIgnored` (no rule attribution).
    pub fn isIgnoredFast(st: *const IgnoreStack, root: RootId, rel_path: []const u8, is_dir: bool) bool {
        const self = @constCast(st);
        self.lock.lockSharedUncancelable(st.io);
        defer self.lock.unlockShared(st.io);
        const r = &st.roots[root.index()];
        if (std.mem.lastIndexOfScalar(u8, rel_path, '/')) |slash| {
            if (st.dirIgnoredLocked(r, rel_path[0..slash])) return true;
        }
        return st.verdictLocked(r, rel_path, is_dir).state == .ignored;
    }

    /// Whether directory `dir` is ignored, ancestors included; cached.
    fn dirIgnoredLocked(st: *const IgnoreStack, r: *const RootState, dir: []const u8) bool {
        const h = DirCache.hash(r.root, dir, r.casefold);
        const self = @constCast(st);
        if (self.dir_cache.get(h)) |v| return v;
        var ignored = false;
        if (std.mem.lastIndexOfScalar(u8, dir, '/')) |slash| ignored = st.dirIgnoredLocked(r, dir[0..slash]);
        if (!ignored) ignored = st.verdictLocked(r, dir, true).state == .ignored;
        self.dir_cache.put(h, ignored);
        return ignored;
    }

    /// Like `isIgnored`, for a path whose parent directory is known to be
    /// visible (the scanner's case): ancestors are not re-checked.
    pub fn isIgnoredInVisibleDir(st: *const IgnoreStack, root: RootId, rel_path: []const u8, is_dir: bool) Verdict {
        const self = @constCast(st);
        self.lock.lockSharedUncancelable(st.io);
        defer self.lock.unlockShared(st.io);
        return st.verdictLocked(&st.roots[root.index()], rel_path, is_dir);
    }

    /// A human-readable reason, e.g. "ignored by .gitignore:12 `build/`".
    /// Caller owns the result.
    pub fn explain(st: *const IgnoreStack, root: RootId, rel_path: []const u8, is_dir: bool, gpa: Allocator) ![]u8 {
        const self = @constCast(st);
        self.lock.lockSharedUncancelable(st.io);
        defer self.lock.unlockShared(st.io);
        const r = &st.roots[root.index()];
        var v: Verdict = .{ .state = .none };
        var ancestor: ?[]const u8 = null;
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, rel_path, i, '/')) |slash| : (i = slash + 1) {
            const av = st.verdictLocked(r, rel_path[0..slash], true);
            if (av.state == .ignored) {
                v = av;
                ancestor = rel_path[0..slash];
                break;
            }
        }
        if (ancestor == null) v = st.verdictLocked(r, rel_path, is_dir);
        const rule = v.rule orelse return gpa.dupe(u8, "not ignored");
        const verb = if (v.state == .ignored) "ignored" else "included";
        const file = sourceFile(rule.source);
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;
        if (ancestor) |a| try w.print("ignored because its parent directory {s}/ is ", .{a}) else try w.print("{s} ", .{verb});
        if (v.hard) {
            try w.print("by the built-in hard rule `{s}`", .{rule.text});
        } else if (rule.source == .builtin) {
            try w.print("by the built-in rule `{s}`", .{rule.text});
        } else if (rule.source == .setting_files_exclude) {
            try w.print("by the files.exclude setting `{s}`", .{rule.text});
        } else if (v.base.len > 0) {
            try w.print("by {s}/{s}:{d} `{s}`", .{ v.base, file, rule.line, rule.text });
        } else {
            try w.print("by {s}:{d} `{s}`", .{ file, rule.line, rule.text });
        }
        return out.toOwnedSlice();
    }

    /// The thread-safe watcher filter for `root`.
    pub fn asWatchFilter(st: *IgnoreStack, root: RootId) WatchFilter {
        return .{ .ctx = &st.roots[root.index()], .isIgnored = watchIsIgnored };
    }

    fn watchIsIgnored(ctx: *anyopaque, rel_path: []const u8, is_dir: bool) bool {
        const r: *RootState = @ptrCast(@alignCast(ctx));
        return r.stack.isIgnoredFast(r.root, rel_path, is_dir);
    }

    fn verdictLocked(st: *const IgnoreStack, r: *const RootState, rel: []const u8, is_dir: bool) Verdict {
        const fold = r.casefold;
        if (st.hard.match(rel, is_dir, fold)) |h| return .{ .state = .ignored, .rule = h.rule, .hard = true };
        if (r.settings.match(rel, is_dir, fold)) |h| return .{ .state = .ignored, .rule = h.rule };
        if (r.levels.count() > 0) {
            // The levels on the path's directory chain, deepest first.
            var chain: [max_chain]*const Level = undefined;
            var subs: [max_chain][]const u8 = undefined;
            var n: usize = 0;
            var dir_end: ?usize = std.mem.lastIndexOfScalar(u8, rel, '/');
            if (r.levels.count() <= small_levels) {
                // Few ignore files: test each for being an ancestor directory
                // instead of hashing every ancestor of the path.
                var it = r.levels.valueIterator();
                while (it.next()) |lp| {
                    const lvl = lp.*;
                    const parent = if (dir_end) |e| rel[0..e] else "";
                    const is_anc = lvl.dir.len == 0 or (std.mem.startsWith(u8, parent, lvl.dir) and (parent.len == lvl.dir.len or parent[lvl.dir.len] == '/'));
                    if (!is_anc) continue;
                    // Insert keeping deepest-first order.
                    var k = n;
                    while (k > 0 and chain[k - 1].dir.len < lvl.dir.len) : (k -= 1) {
                        chain[k] = chain[k - 1];
                        subs[k] = subs[k - 1];
                    }
                    chain[k] = lvl;
                    subs[k] = if (lvl.dir.len == 0) rel else rel[lvl.dir.len + 1 ..];
                    n += 1;
                }
                return st.chainVerdict(r, rel, is_dir, chain[0..n], subs[0..n]);
            }
            while (n < max_chain) {
                const dir = if (dir_end) |e| rel[0..e] else "";
                if (r.levels.get(dir)) |lvl| {
                    chain[n] = lvl;
                    subs[n] = if (dir_end) |e| rel[e + 1 ..] else rel;
                    n += 1;
                }
                const e = dir_end orelse break;
                dir_end = std.mem.lastIndexOfScalar(u8, rel[0..e], '/');
            }
            return st.chainVerdict(r, rel, is_dir, chain[0..n], subs[0..n]);
        }
        return st.chainVerdict(r, rel, is_dir, &.{}, &.{});
    }

    fn chainVerdict(st: *const IgnoreStack, r: *const RootState, rel: []const u8, is_dir: bool, chain: []const *const Level, subs: []const []const u8) Verdict {
        const fold = r.casefold;
        for (chain, subs) |lvl, sub| {
            if (lvl.zgignore.match(sub, is_dir, fold)) |h| return fromHit(h, lvl.dir);
        }
        for (chain, subs) |lvl, sub| {
            if (lvl.gitignore.match(sub, is_dir, fold)) |h| return fromHit(h, lvl.dir);
        }
        if (r.info_exclude.match(rel, is_dir, fold)) |h| return fromHit(h, "");
        if (r.core_excludes.match(rel, is_dir, fold)) |h| return fromHit(h, "");
        if (st.builtin.match(rel, is_dir, fold)) |h| return fromHit(h, "");
        return .{ .state = .none };
    }
};

/// A lock-free, direct-mapped cache of "is this directory ignored (ancestors
/// included)". Readers fill it under the shared lock; every writer bumps the
/// epoch under the exclusive lock, which invalidates all entries at once.
/// Each slot packs the top 48 bits of the path hash, a 15-bit epoch and the
/// verdict bit; the slot index uses the low bits, so 61 hash bits are checked.
const DirCache = struct {
    slots: [slot_count]std.atomic.Value(u64) = @splat(.init(0)),
    epoch: u64 = 1,

    const slot_count = 8192;
    const epoch_mask = 0x7fff;

    fn hash(root: RootId, dir: []const u8, fold: bool) u64 {
        var h: u64 = 0xcbf29ce484222325 ^ @as(u64, root.index());
        for (dir) |c| {
            h ^= if (fold) std.ascii.toLower(c) else c;
            h *%= 0x100000001b3;
        }
        // Final avalanche so the low (slot) bits depend on every byte.
        h ^= h >> 33;
        h *%= 0xff51afd7ed558ccd;
        h ^= h >> 33;
        return h;
    }

    fn get(c: *DirCache, h: u64) ?bool {
        const v = c.slots[h % slot_count].load(.monotonic);
        if (v == 0 or (v >> 16) != (h >> 16) or ((v >> 1) & epoch_mask) != c.epoch) return null;
        return v & 1 == 1;
    }

    fn put(c: *DirCache, h: u64, ignored: bool) void {
        const v = (h & ~@as(u64, 0xffff)) | (c.epoch << 1) | @intFromBool(ignored);
        c.slots[h % slot_count].store(v, .monotonic);
    }

    /// Writers only (exclusive lock held).
    fn invalidate(c: *DirCache) void {
        c.epoch = (c.epoch + 1) & epoch_mask;
        if (c.epoch == 0) {
            // Wrapped: old entries could alias the new epoch; clear them.
            for (&c.slots) |*s| s.store(0, .monotonic);
            c.epoch = 1;
        }
    }
};

/// Deepest directory chain consulted for per-directory ignore files.
const max_chain = 128;
/// Up to this many ignore-file directories per root are scanned linearly.
const small_levels = 16;

fn fromHit(h: zg_ignore.Hit, base: []const u8) Verdict {
    return .{ .state = if (h.rule.negate) .included else .ignored, .rule = h.rule, .base = base };
}

fn sourceFile(s: zg_ignore.Source) []const u8 {
    return switch (s) {
        .gitignore => ".gitignore",
        .zgignore => ".zgignore",
        .git_info_exclude => ".git/info/exclude",
        .core_excludes_file => "core.excludesFile",
        .setting_files_exclude => "files.exclude",
        .builtin => "built-in",
    };
}

fn freeLevel(gpa: Allocator, l: *Level) void {
    l.arena.deinit();
    gpa.destroy(l);
}
