//! The review queue's view model (E12.F03.S01.T01): the rows the queue
//! panel shows, grouped and filtered, and the counts other views badge.
//! UI-agnostic; the panel and the CLI both read it.
//!
//! Rows are a flattened tree: group → changeset → file (files only for
//! expanded changesets). Per-changeset display data (label cut to 120
//! bytes, +/− lines, conflicts, the lowercase text the filter searches)
//! is computed when a queue event touches that changeset, never while
//! painting. Rows are rebuilt lazily on the next `rows()` after a change:
//! sorting and filtering n changesets is O(n log n).
//!
//! Groups: by session (default), agent, origin, top-level directory, or
//! none. Changesets applied without review in the last 24 hours form a
//! pinned group at the bottom.

const std = @import("std");
const proto = @import("zg_ai_proto");
const zg_ignore = @import("zg_ignore");
const model = @import("../model/root.zig");
const ConflictIndex = @import("../rebase/conflict_index.zig").ConflictIndex;
const SessionNames = @import("../rebase/conflict_index.zig").SessionNames;

const Allocator = std.mem.Allocator;
const ChangesetId = model.ChangesetId;
const Changeset = model.Changeset;
const OriginKind = std.meta.Tag(model.Origin);

pub const label_max = 120;
pub const auto_applied_window_ms: i64 = 24 * std.time.ms_per_hour;

pub const GroupBy = enum { session, agent, origin, path, none };

pub const StateMask = std.EnumSet(model.State);
pub const OriginMask = std.EnumSet(OriginKind);

/// `pending` and `partially_applied`.
pub const pending_like: StateMask = .initMany(&.{ .pending, .partially_applied });

pub const QueueFilter = struct {
    states: StateMask = pending_like,
    origins: ?OriginMask = null,
    /// Substring of the agent's display name (case-insensitive).
    agent: ?[]const u8 = null,
    /// E08 glob; a changeset matches when any of its files does.
    path_glob: ?[]const u8 = null,
    has_conflicts: ?bool = null,
    /// Case-insensitive substring of the label, paths or agent name.
    text: ?[]const u8 = null,
};

pub const FilterError = error{ UnknownKey, BadValue } || Allocator.Error;

/// Parses "state:pending path:src/** agent:x origin:lsp conflicts:yes
/// free text". Repeated `state:`/`origin:` keys add up; `state:all` takes
/// every state. Values and the free text are kept as written, in `arena`.
pub fn parseFilter(arena: Allocator, text: []const u8) FilterError!QueueFilter {
    var f: QueueFilter = .{};
    var states: ?StateMask = null;
    var free: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeAny(u8, text, " \t");
    while (it.next()) |tok| {
        const colon = std.mem.indexOfScalar(u8, tok, ':') orelse {
            if (free.items.len > 0) try free.append(arena, ' ');
            try free.appendSlice(arena, tok);
            continue;
        };
        const key = tok[0..colon];
        const val = tok[colon + 1 ..];
        if (val.len == 0) return error.BadValue;
        if (std.mem.eql(u8, key, "state")) {
            var s = states orelse StateMask.initEmpty();
            if (std.mem.eql(u8, val, "all")) s = .initFull() else if (std.mem.eql(u8, val, "open")) s.setUnion(pending_like) else s.insert(std.meta.stringToEnum(model.State, val) orelse return error.BadValue);
            states = s;
        } else if (std.mem.eql(u8, key, "origin")) {
            var o = f.origins orelse OriginMask.initEmpty();
            o.insert(std.meta.stringToEnum(OriginKind, val) orelse return error.BadValue);
            f.origins = o;
        } else if (std.mem.eql(u8, key, "agent")) {
            f.agent = try arena.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "path")) {
            f.path_glob = try arena.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "conflicts")) {
            f.has_conflicts = if (std.mem.eql(u8, val, "yes") or std.mem.eql(u8, val, "true")) true else if (std.mem.eql(u8, val, "no") or std.mem.eql(u8, val, "false")) false else return error.BadValue;
        } else return error.UnknownKey;
    }
    if (states) |s| f.states = s;
    if (free.items.len > 0) f.text = free.items;
    return f;
}

pub const RowKind = enum { group, changeset, file };

pub const Row = struct {
    kind: RowKind,
    /// 0 group, 1 changeset, 2 file (0 and 1 when grouping is `none`).
    depth: u8,
    /// Owned by the model; valid until the rows are rebuilt.
    label: []const u8,
    /// The changeset (changeset and file rows).
    cs: ?ChangesetId = null,
    /// Index into the changeset's files (file rows).
    file: u32 = 0,
    files: u32 = 0,
    added: u32 = 0,
    removed: u32 = 0,
    conflicts: u32 = 0,
    created_ms: i64 = 0,
    expanded: bool = false,
    /// Group rows: the changesets under it.
    count: u32 = 0,
};

pub const SessionCount = struct { session: u128, changesets: u32, hunks: u32 };

pub const Counts = struct {
    pending_changesets: u32 = 0,
    /// Undecided hunks of open changesets.
    pending_hunks: u32 = 0,
    /// Open changesets with a conflict (on a hunk or with another
    /// changeset).
    conflicts: u32 = 0,
    /// E12.F05 approvals; not counted yet.
    approvals: u32 = 0,
    per_session: []const SessionCount = &.{},
};

pub const Options = struct {
    group_by: GroupBy = .session,
    conflicts: ?*const ConflictIndex = null,
    names: ?SessionNames = null,
    /// The clock for "recently auto-applied"; null uses the queue's Io.
    now_ms: ?*const fn () i64 = null,
};

/// What the model keeps per changeset.
const Entry = struct {
    id: ChangesetId,
    state: model.State,
    origin: OriginKind,
    session: ?u128,
    agent: u32,
    auto_applied: bool,
    created_ms: i64,
    decided_ms: ?i64,
    label: []const u8,
    /// Lowercase label, paths and agent name, for the text filter.
    hay: []const u8,
    agent_name: []const u8,
    agent_lower: []const u8,
    paths: []const []const u8,
    files: u32,
    added: u32,
    removed: u32,
    hunks_open: u32,
    conflicts: u32,
    arena: std.heap.ArenaAllocator,
};

pub const QueueModel = struct {
    gpa: Allocator,
    q: *model.Queue,
    o: Options,
    listener: model.events.ListenerId,
    entries: std.AutoArrayHashMapUnmanaged(ChangesetId, *Entry) = .empty,
    filter: QueueFilter = .{},
    glob: ?zg_ignore.GlobSet = null,
    filter_arena: std.heap.ArenaAllocator,
    expanded: std.AutoHashMapUnmanaged(ChangesetId, void) = .empty,
    collapsed_groups: std.StringHashMapUnmanaged(void) = .empty,
    row_arena: std.heap.ArenaAllocator,
    rows_: std.ArrayList(Row) = .empty,
    counts_: Counts = .{},
    dirty: bool = true,
    /// Bumped on every change the rows show; the panel repaints on it.
    version: u64 = 0,

    pub fn init(gpa: Allocator, q: *model.Queue, o: Options) !*QueueModel {
        const m = try gpa.create(QueueModel);
        errdefer gpa.destroy(m);
        m.* = .{ .gpa = gpa, .q = q, .o = o, .listener = undefined, .filter_arena = .init(gpa), .row_arena = .init(gpa) };
        errdefer m.free();
        for (q.changesets.keys()) |id| try m.refresh(id);
        m.listener = try q.subscribe(.{ .ctx = m, .on = onEvent });
        return m;
    }

    pub fn deinit(m: *QueueModel) void {
        m.q.unsubscribe(m.listener);
        m.free();
        m.gpa.destroy(m);
    }

    fn free(m: *QueueModel) void {
        for (m.entries.values()) |e| m.dropEntry(e);
        m.entries.deinit(m.gpa);
        if (m.glob) |*g| g.deinit();
        m.filter_arena.deinit();
        m.expanded.deinit(m.gpa);
        var it = m.collapsed_groups.keyIterator();
        while (it.next()) |k| m.gpa.free(k.*);
        m.collapsed_groups.deinit(m.gpa);
        m.rows_.deinit(m.gpa);
        m.row_arena.deinit();
    }

    fn dropEntry(m: *QueueModel, e: *Entry) void {
        e.arena.deinit();
        m.gpa.destroy(e);
    }

    // ------------------------------------------------------ settings

    /// Replaces the filter (copied). An invalid `path_glob` matches
    /// nothing and is reported.
    pub fn setFilter(m: *QueueModel, f: QueueFilter) error{ OutOfMemory, InvalidPattern, TooManyExpansions }!void {
        _ = m.filter_arena.reset(.retain_capacity);
        const a = m.filter_arena.allocator();
        var nf = f;
        if (f.agent) |s| nf.agent = try std.ascii.allocLowerString(a, s);
        if (f.text) |s| nf.text = try std.ascii.allocLowerString(a, s);
        if (f.path_glob) |s| nf.path_glob = try a.dupe(u8, s);
        if (m.glob) |*g| g.deinit();
        m.glob = null;
        m.filter = nf;
        m.touch();
        if (nf.path_glob) |p| m.glob = try zg_ignore.GlobSet.compile(m.gpa, p, .{});
    }

    pub fn setGroupBy(m: *QueueModel, g: GroupBy) void {
        m.o.group_by = g;
        m.touch();
    }

    /// Expands or collapses the changeset or group of row `i`.
    pub fn toggle(m: *QueueModel, i: usize) !void {
        const rs = m.rows();
        if (i >= rs.len) return;
        const r = rs[i];
        switch (r.kind) {
            .changeset => if (m.expanded.remove(r.cs.?)) {} else try m.expanded.put(m.gpa, r.cs.?, {}),
            .group => if (m.collapsed_groups.fetchRemove(r.label)) |kv| m.gpa.free(kv.key) else {
                const k = try m.gpa.dupe(u8, r.label);
                m.collapsed_groups.put(m.gpa, k, {}) catch |e| {
                    m.gpa.free(k);
                    return e;
                };
            },
            .file => return,
        }
        m.touch();
    }

    fn touch(m: *QueueModel) void {
        m.dirty = true;
        m.version +%= 1;
    }

    // ------------------------------------------------------ reading

    /// The visible rows, rebuilt if anything changed.
    pub fn rows(m: *QueueModel) []const Row {
        if (m.dirty) m.rebuild() catch |e| {
            std.log.scoped(.zg_review).warn("queue model: {t}; rows unchanged", .{e});
        };
        return m.rows_.items;
    }

    pub fn counts(m: *QueueModel) Counts {
        _ = m.rows();
        return m.counts_;
    }

    // ------------------------------------------------------ events

    fn onEvent(ctx: *anyopaque, ev: *const model.Event) void {
        const m: *QueueModel = @ptrCast(@alignCast(ctx));
        const id = switch (ev.*) {
            .submitted, .updated, .removed => |id| id,
            .state => |s| s.cs,
            .applied => |a| a.cs,
        };
        m.refresh(id) catch std.log.scoped(.zg_review).warn("queue model: out of memory while updating {f}", .{id});
        // A sibling's conflicts may have changed too; they are counted
        // again on rebuild.
        m.touch();
    }

    /// Computes the display data of `id` again (removes it when gone).
    fn refresh(m: *QueueModel, id: ChangesetId) !void {
        if (m.entries.fetchSwapRemove(id)) |kv| m.dropEntry(kv.value);
        const cs = m.q.get(id) orelse {
            _ = m.expanded.remove(id);
            return;
        };
        if (cs.state == .open_batch) return;
        const e = try m.gpa.create(Entry);
        e.arena = .init(m.gpa);
        errdefer m.dropEntry(e);
        const a = e.arena.allocator();
        const ref = cs.prov.origin.agentRef();
        const name: []const u8 = blk: {
            if (ref) |r| if (m.o.names) |n| if (n.name(n.ctx, r.session)) |s| break :blk try a.dupe(u8, s);
            break :blk "";
        };
        var added: u32 = 0;
        var removed: u32 = 0;
        var open_hunks: u32 = 0;
        var conflicts: u32 = 0;
        const paths = try a.alloc([]const u8, cs.files.len);
        var hay: std.ArrayList(u8) = .empty;
        try appendLower(a, &hay, cs.prov.label);
        try appendLower(a, &hay, name);
        for (cs.files, paths) |*f, *p| {
            p.* = try a.dupe(u8, f.path);
            try appendLower(a, &hay, f.path);
            const n = f.countLines();
            added += n.added;
            removed += n.removed;
            for (f.hunks) |h| {
                if (h.decision == .undecided) open_hunks += 1;
                if (h.conflict != null) conflicts += 1;
            }
        }
        e.* = .{
            .id = id,
            .state = cs.state,
            .origin = std.meta.activeTag(cs.prov.origin),
            .session = if (ref) |r| r.session else null,
            .agent = if (ref) |r| r.agent else 0,
            .auto_applied = cs.auto_applied,
            .created_ms = cs.created_ms,
            .decided_ms = cs.decided_ms,
            .label = try a.dupe(u8, cut(cs.prov.label, label_max)),
            .hay = hay.items,
            .agent_name = name,
            .agent_lower = try std.ascii.allocLowerString(a, name),
            .paths = paths,
            .files = @intCast(cs.files.len),
            .added = added,
            .removed = removed,
            .hunks_open = open_hunks,
            .conflicts = conflicts,
            .arena = e.arena,
        };
        try m.entries.put(m.gpa, id, e);
    }

    // ------------------------------------------------------ rows

    fn nowMs(m: *const QueueModel) i64 {
        if (m.o.now_ms) |f| return f();
        const now = std.Io.Clock.real.now(m.q.io);
        return @intCast(@divFloor(now.nanoseconds, std.time.ns_per_ms));
    }

    fn conflictsOf(m: *const QueueModel, e: *const Entry) u32 {
        var n = e.conflicts;
        if (m.o.conflicts) |ci| n += @intCast(ci.conflictsOf(e.id).len);
        return n;
    }

    /// The filter's other terms apply to the pinned group too; only its
    /// states do not.
    fn passes(m: *const QueueModel, e: *const Entry, states: bool) bool {
        const f = &m.filter;
        if (states and !f.states.contains(e.state)) return false;
        if (f.origins) |o| if (!o.contains(e.origin)) return false;
        if (f.agent) |s| if (std.mem.indexOf(u8, e.agent_lower, s) == null) return false;
        if (f.has_conflicts) |want| if ((m.conflictsOf(e) > 0) != want) return false;
        if (f.path_glob != null) {
            const g = &(m.glob orelse return false);
            for (e.paths) |p| {
                if (g.matches(p)) break;
            } else return false;
        }
        if (f.text) |t| if (std.mem.indexOf(u8, e.hay, t) == null) return false;
        return true;
    }

    const Sorted = struct { e: *const Entry, key: []const u8, pinned: bool };

    fn rebuild(m: *QueueModel) !void {
        _ = m.row_arena.reset(.retain_capacity);
        const a = m.row_arena.allocator();
        m.rows_.clearRetainingCapacity();
        const now = m.nowMs();

        // Counts cover every open changeset, whatever the filter.
        var c: Counts = .{};
        var per: std.ArrayList(SessionCount) = .empty;
        for (m.entries.values()) |e| {
            if (!pending_like.contains(e.state)) continue;
            c.pending_changesets += 1;
            c.pending_hunks += e.hunks_open;
            if (m.conflictsOf(e) > 0) c.conflicts += 1;
            const s = e.session orelse continue;
            for (per.items) |*p| {
                if (p.session == s) {
                    p.changesets += 1;
                    p.hunks += e.hunks_open;
                    break;
                }
            } else try per.append(a, .{ .session = s, .changesets = 1, .hunks = e.hunks_open });
        }
        c.per_session = per.items;
        m.counts_ = c;

        var list: std.ArrayList(Sorted) = .empty;
        for (m.entries.values()) |e| {
            const recent_auto = e.auto_applied and e.state == .applied and now - (e.decided_ms orelse e.created_ms) <= auto_applied_window_ms;
            if (recent_auto) {
                if (!m.passes(e, false)) continue;
                try list.append(a, .{ .e = e, .key = "Recently auto-applied (last 24 h)", .pinned = true });
                continue;
            }
            if (!m.passes(e, true)) continue;
            try list.append(a, .{ .e = e, .key = try m.groupKey(a, e), .pinned = false });
        }
        // Newest group first (by its newest changeset), newest first within.
        var newest: std.StringHashMapUnmanaged(*const Entry) = .empty;
        for (list.items) |s| {
            const g = try newest.getOrPut(a, s.key);
            if (!g.found_existing or newer(s.e, g.value_ptr.*)) g.value_ptr.* = s.e;
        }
        const Ctx = struct {
            newest: *const std.StringHashMapUnmanaged(*const Entry),
            fn lt(ctx: @This(), x: Sorted, y: Sorted) bool {
                if (x.pinned != y.pinned) return y.pinned;
                if (!std.mem.eql(u8, x.key, y.key)) return newer(ctx.newest.get(x.key).?, ctx.newest.get(y.key).?);
                return newer(x.e, y.e);
            }
        };
        std.mem.sort(Sorted, list.items, Ctx{ .newest = &newest }, Ctx.lt);

        const grouped = m.o.group_by != .none;
        var i: usize = 0;
        while (i < list.items.len) {
            var j = i + 1;
            while (j < list.items.len and std.mem.eql(u8, list.items[j].key, list.items[i].key)) j += 1;
            const show_header = grouped or list.items[i].pinned;
            const collapsed = show_header and m.collapsed_groups.contains(list.items[i].key);
            if (show_header) try m.rows_.append(m.gpa, .{ .kind = .group, .depth = 0, .label = list.items[i].key, .count = @intCast(j - i), .expanded = !collapsed });
            const d: u8 = if (show_header) 1 else 0;
            if (!collapsed) for (list.items[i..j]) |s| try m.addChangeset(s.e, d);
            i = j;
        }
        m.dirty = false;
    }

    fn addChangeset(m: *QueueModel, e: *const Entry, depth: u8) !void {
        const open = m.expanded.contains(e.id);
        try m.rows_.append(m.gpa, .{
            .kind = .changeset,
            .depth = depth,
            .label = e.label,
            .cs = e.id,
            .files = e.files,
            .added = e.added,
            .removed = e.removed,
            .conflicts = m.conflictsOf(e),
            .created_ms = e.created_ms,
            .expanded = open,
        });
        if (!open) return;
        const cs = m.q.get(e.id) orelse return;
        for (cs.files, 0..) |*f, fi| {
            const n = f.countLines();
            var cf: u32 = 0;
            for (f.hunks) |h| cf += @intFromBool(h.conflict != null);
            try m.rows_.append(m.gpa, .{ .kind = .file, .depth = depth + 1, .label = e.paths[fi], .cs = e.id, .file = @intCast(fi), .added = n.added, .removed = n.removed, .conflicts = cf, .created_ms = e.created_ms });
        }
    }

    fn groupKey(m: *const QueueModel, a: Allocator, e: *const Entry) ![]const u8 {
        return switch (m.o.group_by) {
            .none => "",
            .origin => originTitle(e.origin),
            .path => blk: {
                if (e.paths.len == 0) break :blk "(no files)";
                const p = e.paths[0];
                break :blk if (std.mem.indexOfScalar(u8, p, '/')) |k| p[0 .. k + 1] else "(workspace root)";
            },
            .session, .agent => blk: {
                const s = e.session orelse break :blk originTitle(e.origin);
                const id = proto.agent_ref.format(s);
                const who = if (e.agent_name.len > 0) e.agent_name else "Session";
                if (m.o.group_by == .agent and e.agent > 0)
                    break :blk try std.fmt.allocPrint(a, "{s} {s}… / subagent {d}", .{ who, id[20..], e.agent });
                break :blk try std.fmt.allocPrint(a, "{s} {s}…", .{ who, id[20..] });
            },
        };
    }
};

/// Later created first; ids break ties (they grow with submission).
fn newer(x: *const Entry, y: *const Entry) bool {
    if (x.created_ms != y.created_ms) return x.created_ms > y.created_ms;
    return @intFromEnum(x.id) > @intFromEnum(y.id);
}

pub fn originTitle(o: OriginKind) []const u8 {
    return switch (o) {
        .agent => "Agent",
        .inline_edit => "Inline edit",
        .lsp => "LSP",
        .search_replace => "Search/Replace",
        .notes => "Notes",
        .scm_proposal => "SCM",
        .code_review => "Code review",
        .user_bulk => "Bulk edit",
    };
}

fn appendLower(a: Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    if (s.len == 0) return;
    if (out.items.len > 0) try out.append(a, '\n');
    const start = out.items.len;
    try out.appendSlice(a, s);
    for (out.items[start..]) |*ch| ch.* = std.ascii.toLower(ch.*);
}

/// `s` cut to at most `max` bytes on a UTF-8 boundary.
fn cut(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var n = max;
    while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
    return s[0..n];
}
