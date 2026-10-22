//! Virtual views over the workspace (E12.F02.S01.T01): what a file reads
//! as once some pending changes are taken, without writing anything.
//!
//! - `disk`: the workspace as it is (an open document's text when a
//!   `DocSource` has one).
//! - `agent`: disk plus one session's open changes: its edits, creates,
//!   renames and deletes. Subagents share their session's view unless
//!   `subagents_share_view` is off.
//! - `changeset`: disk plus one changeset (its "after" side).
//! - `all_pending`: disk plus every open change.
//!
//! Changes compose in submission order. A text change whose base is not
//! the text underneath (the rebase has not caught up) is merged three
//! ways onto it, keeping the proposal where they collide, and the read is
//! marked `stale`.
//!
//! The queue belongs to its owner thread, so these run there; the disk
//! and document reads go through the `Files` and `DocSource` ports.

const std = @import("std");
const model = @import("../model/root.zig");
const files_mod = @import("../apply/files.zig");

const Allocator = std.mem.Allocator;
const ChangesetId = model.ChangesetId;
const Changeset = model.Changeset;
const FileChange = model.FileChange;
const Files = files_mod.Files;

pub const ViewSpec = union(enum) {
    disk,
    /// `AgentRef.session` and `.agent` (0: the main agent).
    agent: struct { session: u128, agent: u32 = 0 },
    changeset: ChangesetId,
    all_pending,
};

/// Open documents (E05's DocumentRegistry in the app): their current text
/// replaces the disk's.
pub const DocSource = struct {
    ctx: *anyopaque,
    /// The open document's text for `path`, in `arena`; null when closed.
    snapshot: *const fn (ctx: *anyopaque, arena: Allocator, path: []const u8) anyerror!?[]const u8,
};

pub const EntryKind = enum { file, directory };

pub const DirEntry = struct {
    name: []const u8,
    kind: EntryKind,
};

/// Directory listings of the disk (E08's PathStore snapshot in the app).
pub const Lister = struct {
    ctx: *anyopaque,
    /// The entries of workspace-relative `dir` ("" is the root), in
    /// `arena`; empty when it does not exist.
    list: *const fn (ctx: *anyopaque, arena: Allocator, dir: []const u8) anyerror![]const DirEntry,
};

pub const Options = struct {
    /// Subagents see their session's pending changes, and it theirs.
    subagents_share_view: bool = true,
};

pub const Read = struct {
    text: []const u8,
    executable: bool,
    /// The text underneath the view's changes (disk or open document);
    /// null when there is no file there.
    base: ?model.BaseRef,
    /// The view's changesets that changed this path, in order.
    includes_pending: []const ChangesetId,
    /// Open changesets outside the view that touch this path.
    others_pending: []const ChangesetId,
    /// A change was made against other text and was merged onto it.
    stale: bool,
};

pub const Stat = struct {
    size: u64,
    executable: bool,
    /// The view changes this path.
    pending: bool,
};

pub const OverlayFs = struct {
    q: *const model.Queue,
    files: Files,
    docs: ?DocSource = null,
    lister: ?Lister = null,
    o: Options = .{},

    /// `path` as `view` sees it; null when it does not exist there.
    /// Allocated in `arena`.
    pub fn read(fs: *const OverlayFs, arena: Allocator, view: ViewSpec, path: []const u8) !?Read {
        var cur = try fs.underlying(arena, path);
        const base: ?model.BaseRef = if (cur) |c| .of(c.bytes) else null;
        var includes: std.ArrayList(ChangesetId) = .empty;
        var others: std.ArrayList(ChangesetId) = .empty;
        var stale = false;
        for (fs.q.changesets.values()) |cs| {
            if (!isOpenCs(cs.state)) continue;
            const shown = fs.visible(view, cs);
            for (cs.files) |*fc| {
                if (!isOpenFile(fc.state) or !touches(fc, path)) continue;
                const l = if (shown) &includes else &others;
                if (std.mem.indexOfScalar(ChangesetId, l.items, cs.id) == null) try l.append(arena, cs.id);
                if (shown) cur = try fs.applyFile(arena, fc, path, cur, &stale);
            }
        }
        const c = cur orelse return null;
        return .{
            .text = c.bytes,
            .executable = c.executable,
            .base = base,
            .includes_pending = includes.items,
            .others_pending = others.items,
            .stale = stale,
        };
    }

    pub fn stat(fs: *const OverlayFs, arena: Allocator, view: ViewSpec, path: []const u8) !?Stat {
        const r = try fs.read(arena, view, path) orelse return null;
        return .{ .size = r.text.len, .executable = r.executable, .pending = r.includes_pending.len > 0 };
    }

    /// The entries of `dir` ("" is the root) in `view`, sorted by name:
    /// the disk's, plus pending creates and rename targets (and the
    /// directories they need), minus pending deletes and rename sources.
    pub fn listDir(fs: *const OverlayFs, arena: Allocator, view: ViewSpec, dir: []const u8) ![]DirEntry {
        var map: std.StringArrayHashMapUnmanaged(EntryKind) = .empty;
        if (fs.lister) |l| for (try l.list(l.ctx, arena, dir)) |e| try map.put(arena, e.name, e.kind);
        if (view != .disk) for (fs.q.changesets.values()) |cs| {
            if (!isOpenCs(cs.state) or !fs.visible(view, cs)) continue;
            for (cs.files) |*fc| {
                if (!isOpenFile(fc.state)) continue;
                switch (fc.op) {
                    .create => try addUnder(arena, &map, dir, fc.path),
                    .rename => |r| {
                        hideUnder(&map, dir, r.from);
                        try addUnder(arena, &map, dir, fc.path);
                    },
                    .delete => hideUnder(&map, dir, fc.path),
                    .modify, .set_executable => {},
                }
            }
        };
        const out = try arena.alloc(DirEntry, map.count());
        for (map.keys(), map.values(), out) |k, v, *o| o.* = .{ .name = k, .kind = v };
        std.mem.sort(DirEntry, out, {}, struct {
            fn lt(_: void, a: DirEntry, b: DirEntry) bool {
                return std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.lt);
        return out;
    }

    /// Whether `cs` is part of `view`.
    pub fn visible(fs: *const OverlayFs, view: ViewSpec, cs: *const Changeset) bool {
        return switch (view) {
            .disk => false,
            .all_pending => true,
            .changeset => |id| cs.id == id,
            .agent => |a| blk: {
                const r = cs.prov.origin.agentRef() orelse break :blk false;
                break :blk r.session == a.session and (fs.o.subagents_share_view or r.agent == a.agent);
            },
        };
    }

    const Cur = files_mod.Entry;

    fn underlying(fs: *const OverlayFs, arena: Allocator, path: []const u8) !?Cur {
        const disk = try fs.files.read(arena, path);
        if (fs.docs) |d| if (try d.snapshot(d.ctx, arena, path)) |text|
            return .{ .bytes = text, .executable = if (disk) |e| e.executable else false };
        return disk;
    }

    /// `cur` after `fc`, for `path`.
    fn applyFile(fs: *const OverlayFs, arena: Allocator, fc: *const FileChange, path: []const u8, cur: ?Cur, stale: *bool) !?Cur {
        switch (fc.op) {
            .delete => return null,
            .rename => |r| if (!std.mem.eql(u8, fc.path, path)) {
                std.debug.assert(std.mem.eql(u8, r.from, path));
                return null;
            },
            .set_executable => |on| {
                var c = cur orelse return null;
                c.executable = on;
                return c;
            },
            .create, .modify => {},
        }
        // The text the change starts from.
        const src: ?Cur = switch (fc.op) {
            .rename => |r| try fs.underlying(arena, r.from),
            else => cur,
        };
        const exec = switch (fc.op) {
            .create => |c| c.executable,
            else => if (src) |s| s.executable else false,
        };
        switch (fc.content) {
            .none => {
                if (src == null) stale.* = true;
                return src;
            },
            .binary => |b| {
                const bytes = try fs.q.blobs.get(arena, b.new) orelse return error.MissingBlob;
                if (!sameBase(b.base, src)) stale.* = true;
                return .{ .bytes = bytes, .executable = exec };
            },
            .text => |t| {
                const want: ?model.BlobHash = if (t.base) |b| b.hash else null;
                if (sameBase(want, src)) {
                    const from: []const u8 = if (src) |s| s.bytes else "";
                    return .{ .bytes = try t.edits.applyToSlice(arena, from), .executable = exec };
                }
                stale.* = true;
                const base: []const u8 = if (want) |h| try fs.q.blobs.get(arena, h) orelse return error.MissingBlob else "";
                const proposed = try t.edits.applyToSlice(arena, base);
                const now: []const u8 = if (src) |s| s.bytes else "";
                const m = try model.merge3.merge(arena, base, now, proposed, .{ .prefer = .theirs });
                return .{ .bytes = m.text, .executable = exec };
            },
        }
    }
};

/// Whether `src` is the text a change with base `want` was made against
/// (null: no file).
fn sameBase(want: ?model.BlobHash, src: ?files_mod.Entry) bool {
    const w = want orelse return src == null;
    const s = src orelse return false;
    return std.mem.eql(u8, &model.blobHash(s.bytes), &w);
}

fn touches(fc: *const FileChange, path: []const u8) bool {
    if (std.mem.eql(u8, fc.path, path)) return true;
    return fc.op == .rename and std.mem.eql(u8, fc.op.rename.from, path);
}

/// Adds the entry `path` puts in `dir`: the file itself, or the first
/// directory on the way to it.
fn addUnder(arena: Allocator, map: *std.StringArrayHashMapUnmanaged(EntryKind), dir: []const u8, path: []const u8) !void {
    const rest = under(dir, path) orelse return;
    if (std.mem.indexOfScalar(u8, rest, '/')) |i| {
        const g = try map.getOrPut(arena, rest[0..i]);
        g.value_ptr.* = .directory;
    } else try map.put(arena, rest, .file);
}

fn hideUnder(map: *std.StringArrayHashMapUnmanaged(EntryKind), dir: []const u8, path: []const u8) void {
    const rest = under(dir, path) orelse return;
    if (std.mem.indexOfScalar(u8, rest, '/') != null) return;
    _ = map.orderedRemove(rest);
}

/// `path` relative to `dir`, when it is inside it.
fn under(dir: []const u8, path: []const u8) ?[]const u8 {
    if (dir.len == 0) return path;
    if (!std.mem.startsWith(u8, path, dir) or path.len <= dir.len + 1 or path[dir.len] != '/') return null;
    return path[dir.len + 1 ..];
}

fn isOpenCs(s: model.State) bool {
    return s == .pending or s == .partially_applied;
}

fn isOpenFile(s: model.FileState) bool {
    return s == .pending or s == .partially_applied;
}
