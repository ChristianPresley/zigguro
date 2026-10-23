//! Mission Control's view-model (E13.F01.S02.T01): rows derived from a
//! `RunsView`, grouped and sorted, with workflow workers nested under
//! their workflow. Incremental: `apply` rebuilds only the rows whose run
//! revision changed (or whose review count may have), and re-sorts only
//! the groups those rows touch. Pure data; `missionControl` in
//! `zg_agents_ui` draws it.
//!
//! Within a group, runs that need attention (unread, waiting, failed or
//! interrupted) come first, then the most recent activity.

const std = @import("std");
const run = @import("../runs/run.zig");
const RunRegistry = @import("../runs/registry.zig");
const filter_mod = @import("filter.zig");

const Allocator = std.mem.Allocator;
const RunId = run.RunId;
const RunStatus = run.RunStatus;
const RunKind = run.RunKind;
const RunRecord = run.RunRecord;
const RunsView = RunRegistry.RunsView;

pub const Group = filter_mod.Group;
pub const Filter = filter_mod.Filter;
pub const Subject = filter_mod.Subject;

pub const n_groups = std.meta.fields(Group).len;

/// Review state of changesets (E12's queue): which still wait for review.
pub const ReviewCounts = struct {
    /// Changes whenever any changeset's review state does.
    version: u64 = 0,
    ctx: ?*anyopaque = null,
    pending: ?*const fn (ctx: ?*anyopaque, changeset: u64) bool = null,

    pub const none: ReviewCounts = .{};

    fn count(rc: ReviewCounts, outputs: []const run.Output) u16 {
        const f = rc.pending orelse return 0;
        var n: u16 = 0;
        for (outputs) |o| switch (o) {
            .changeset => |cs| if (f(rc.ctx, cs)) {
                n +|= 1;
            },
            else => {},
        };
        return n;
    }
};

pub const Progress = struct { done: u16, total: u16 };

pub const Row = struct {
    run: RunId,
    group: Group,
    title: []const u8,
    status: RunStatus,
    kind: RunKind,
    /// Last activity; the age shown is `now - activity_ms`.
    activity_ms: i64,
    /// The question while waiting, else the summary, else the error.
    line: []const u8,
    cost_micro: u64,
    outputs: u16,
    pending_review: u16,
    unread: bool,
    /// 1 for a workflow worker nested under its workflow.
    depth: u8 = 0,
    pinned: bool = false,
    /// Workers done of all, on a workflow with nested workers.
    progress: ?Progress = null,
    expanded: bool = false,

    pub fn ageMs(r: *const Row, now_ms: i64) i64 {
        return @max(0, now_ms - r.activity_ms);
    }

    /// Whether the row sorts before its group's quiet rows.
    pub fn needsAttention(r: *const Row) bool {
        return r.unread or switch (r.status) {
            .needs_input, .failed, .interrupted => true,
            else => false,
        };
    }
};

pub const Item = union(enum) {
    header: struct { group: Group, count: u32 },
    row: *const Row,
};

pub const Totals = struct {
    running: u32 = 0,
    needs_input: u32 = 0,
    /// The cost of runs active since the start of the (UTC) day.
    today_cost_micro: u64 = 0,
};

/// Work counters (tests and the bench check them).
pub const Stats = struct {
    rebuilt: u64 = 0,
    sorted_groups: u64 = 0,
    flattened: u64 = 0,
};

const Entry = struct {
    arena: std.heap.ArenaAllocator,
    row: Row,
    revision: u64 = 0,
    seen_revision: u64 = 0,
    gen: u32 = 0,
    has_changesets: bool = false,
    /// The workflow this worker belongs to, by id; `parent` once linked.
    parent_id: ?RunId = null,
    parent: ?*Entry = null,
    children: std.ArrayList(*Entry) = .empty,
    /// In `groups[row.group]` (top-level rows only).
    placed: bool = false,
    subject: Subject = undefined,
};

pub const MissionVM = struct {
    gpa: Allocator,
    entries: std.AutoHashMapUnmanaged(u128, *Entry) = .empty,
    groups: [n_groups]std.ArrayList(*Entry) = @splat(.empty),
    dirty: std.EnumSet(Group) = .initEmpty(),
    items: std.ArrayList(Item) = .empty,
    /// Workers waiting for their workflow's entry.
    orphans: std.ArrayList(*Entry) = .empty,
    filter: Filter = .{},
    filter_arena: std.heap.ArenaAllocator,
    filter_text: []const u8 = "",
    view_version: u64 = std.math.maxInt(u64),
    review_version: u64 = 0,
    gen: u32 = 0,
    primed: bool = false,
    reflatten: bool = true,
    totals: Totals = .{},
    stats: Stats = .{},

    pub fn init(gpa: Allocator) MissionVM {
        return .{ .gpa = gpa, .filter_arena = .init(gpa) };
    }

    pub fn deinit(vm: *MissionVM) void {
        var it = vm.entries.valueIterator();
        while (it.next()) |e| destroyEntry(vm.gpa, e.*);
        vm.entries.deinit(vm.gpa);
        for (&vm.groups) |*g| g.deinit(vm.gpa);
        vm.items.deinit(vm.gpa);
        vm.orphans.deinit(vm.gpa);
        vm.filter_arena.deinit();
    }

    /// Brings the rows up to date with `view`.
    pub fn apply(vm: *MissionVM, view: *const RunsView, review: ReviewCounts, now_ms: i64) Allocator.Error!void {
        const review_changed = review.version != vm.review_version;
        if (view.version != vm.view_version or review_changed) {
            try vm.sync(view, review, review_changed, now_ms);
            vm.view_version = view.version;
            vm.review_version = review.version;
            vm.primed = true;
        }
        try vm.sortDirty();
        if (vm.reflatten) try vm.flatten();
    }

    fn sync(vm: *MissionVM, view: *const RunsView, review: ReviewCounts, review_changed: bool, now_ms: i64) Allocator.Error!void {
        vm.gen +%= 1;
        var new_entries: std.ArrayList(*Entry) = .empty;
        defer new_entries.deinit(vm.gpa);
        const day_start = now_ms - @mod(now_ms, std.time.ms_per_day);
        var totals: Totals = .{};
        try vm.entries.ensureUnusedCapacity(vm.gpa, @intCast(view.runs.len));
        for (view.runs) |rec| {
            const gop = vm.entries.getOrPutAssumeCapacity(rec.id.toInt());
            if (!gop.found_existing) {
                const e = vm.gpa.create(Entry) catch |err| {
                    vm.entries.removeByPtr(gop.key_ptr);
                    return err;
                };
                e.* = .{ .arena = .init(vm.gpa), .row = undefined };
                gop.value_ptr.* = e;
                try vm.rebuild(e, rec, review, now_ms, false);
                if (!vm.primed) e.seen_revision = rec.revision;
                e.row.unread = rec.revision > e.seen_revision;
                try new_entries.append(vm.gpa, e);
            } else {
                const e = gop.value_ptr.*;
                if (e.revision != rec.revision or (review_changed and e.has_changesets))
                    try vm.rebuild(e, rec, review, now_ms, e.revision == rec.revision);
            }
            const e = gop.value_ptr.*;
            e.gen = vm.gen;
            if (rec.status.holdsSlot()) totals.running += 1;
            if (rec.status == .needs_input) totals.needs_input += 1;
            if (e.row.activity_ms >= day_start) totals.today_cost_micro += rec.cost.micros;
        }
        vm.totals = totals;

        // Runs gone from the view.
        if (vm.entries.count() > view.runs.len) {
            var gone: std.ArrayList(*Entry) = .empty;
            defer gone.deinit(vm.gpa);
            var it = vm.entries.valueIterator();
            while (it.next()) |e| if (e.*.gen != vm.gen) try gone.append(vm.gpa, e.*);
            for (gone.items) |e| try vm.drop(e);
        }

        // Link workers to their workflows (a parent is older, so it comes
        // later in the view than its workers).
        for (new_entries.items) |e| {
            if (e.parent_id != null) try vm.orphans.append(vm.gpa, e) else try vm.place(e);
        }
        var i: usize = 0;
        while (i < vm.orphans.items.len) {
            const e = vm.orphans.items[i];
            const pid = e.parent_id.?;
            if (vm.entries.get(pid.toInt())) |p| {
                if (p.parent == null) {
                    try p.children.append(vm.gpa, e);
                    e.parent = p;
                    e.row.depth = 1;
                    if (e.placed) vm.unplace(e);
                    vm.refreshProgress(p);
                    _ = vm.orphans.swapRemove(i);
                    continue;
                }
            }
            // No workflow (yet): show it at the top level.
            if (!e.placed) try vm.place(e);
            i += 1;
        }
    }

    /// Rebuilds `e` from `rec`. `same_revision`: only the review count
    /// may have changed (activity stays).
    fn rebuild(vm: *MissionVM, e: *Entry, rec: *const RunRecord, review: ReviewCounts, now_ms: i64, same_revision: bool) Allocator.Error!void {
        vm.stats.rebuilt += 1;
        const fresh = e.revision == 0;
        const old_group = if (fresh) null else @as(?Group, e.row.group);
        const old_attention = !fresh and e.row.needsAttention();
        const old_activity = if (fresh) 0 else e.row.activity_ms;
        _ = e.arena.reset(.retain_capacity);
        const a = e.arena.allocator();

        var outs: std.Io.Writer.Allocating = .init(a);
        var has_cs = false;
        for (rec.outputs) |o| {
            switch (o) {
                .changeset => |cs| {
                    has_cs = true;
                    outs.writer.print("changeset {d}\n", .{cs}) catch return error.OutOfMemory;
                },
                .artifact, .file, .task, .note => |s| outs.writer.print("{s}\n", .{s}) catch return error.OutOfMemory,
                .pr => |pr| outs.writer.print("PR #{d} {s}\n", .{ pr.number, pr.url }) catch return error.OutOfMemory,
            }
        }
        e.has_changesets = has_cs;
        const pending = review.count(rec.outputs);
        const status = rec.status;
        const group: Group = if (rec.pinned) .pinned else switch (status) {
            .needs_input => .needs_input,
            .starting, .working => .working,
            .queued, .paused => .queued_paused,
            .completed, .failed, .stopped, .interrupted => if (pending > 0) .ready_for_review else .done,
        };
        const line_src: []const u8 = if (status == .needs_input and rec.question != null)
            rec.question.?
        else if (rec.summary.len > 0)
            rec.summary
        else
            rec.error_ orelse "";
        const title = try a.dupe(u8, if (rec.spec.title.len > 0) rec.spec.title else firstLine(rec.spec.prompt, 80));
        const prompt = try a.dupe(u8, firstLine(rec.spec.prompt, 512));
        const line = try a.dupe(u8, line_src);
        const tags = try a.alloc([]const u8, rec.spec.tags.len);
        for (tags, rec.spec.tags) |*t, s| t.* = try a.dupe(u8, s);
        const origin: []const u8 = switch (rec.spec.origin) {
            .automation => |o| try a.dupe(u8, o.name),
            .workflow => |w| try a.dupe(u8, w.step),
            .task => |t| try a.dupe(u8, t.id),
            .user, .cli => if (rec.spec.kind == .workflow) title else "",
        };
        const activity: i64 = if (fresh)
            @max(rec.created_ms, @max(rec.started_ms orelse 0, rec.ended_ms orelse 0))
        else if (same_revision)
            old_activity
        else
            @max(now_ms, rec.ended_ms orelse 0);

        e.row = .{
            .run = rec.id,
            .group = group,
            .title = title,
            .status = status,
            .kind = rec.spec.kind,
            .activity_ms = activity,
            .line = line,
            .cost_micro = rec.cost.micros,
            .outputs = @intCast(@min(rec.outputs.len, std.math.maxInt(u16))),
            .pending_review = pending,
            .unread = rec.revision > e.seen_revision,
            .depth = if (e.parent != null) 1 else 0,
            .pinned = rec.pinned,
            .progress = if (fresh) null else e.row.progress,
            .expanded = if (fresh) false else e.row.expanded,
        };
        e.subject = .{
            .status = status,
            .group = group,
            .kind = rec.spec.kind,
            .title = title,
            .prompt = prompt,
            .summary = line,
            .outputs = outs.written(),
            .cost_micro = rec.cost.micros,
            .tags = tags,
            .origin = origin,
        };
        e.revision = rec.revision;
        if (fresh) {
            if (rec.spec.parent) |p| if (rec.spec.kind == .workflow_worker) {
                e.parent_id = p;
            };
            return;
        }
        vm.reflatten = true;
        if (e.parent) |p| {
            vm.refreshProgress(p);
            return;
        }
        if (!e.placed) return;
        if (old_group.? != group) {
            vm.unplaceFrom(e, old_group.?);
            try vm.place(e);
        } else if (old_attention != e.row.needsAttention() or old_activity != activity) {
            vm.dirty.insert(group);
        }
    }

    fn place(vm: *MissionVM, e: *Entry) Allocator.Error!void {
        try vm.groups[@intFromEnum(e.row.group)].append(vm.gpa, e);
        e.placed = true;
        vm.dirty.insert(e.row.group);
        vm.reflatten = true;
    }

    fn unplace(vm: *MissionVM, e: *Entry) void {
        vm.unplaceFrom(e, e.row.group);
    }

    fn unplaceFrom(vm: *MissionVM, e: *Entry, group: Group) void {
        const g = &vm.groups[@intFromEnum(group)];
        if (std.mem.indexOfScalar(*Entry, g.items, e)) |i| _ = g.orderedRemove(i);
        e.placed = false;
        vm.reflatten = true;
    }

    fn drop(vm: *MissionVM, e: *Entry) Allocator.Error!void {
        if (e.placed) vm.unplace(e);
        if (e.parent) |p| {
            if (std.mem.indexOfScalar(*Entry, p.children.items, e)) |i| _ = p.children.orderedRemove(i);
            vm.refreshProgress(p);
        }
        // Its workers go back to the top level.
        for (e.children.items) |c| {
            c.parent = null;
            c.row.depth = 0;
            try vm.place(c);
        }
        if (std.mem.indexOfScalar(*Entry, vm.orphans.items, e)) |i| _ = vm.orphans.swapRemove(i);
        _ = vm.entries.remove(e.row.run.toInt());
        destroyEntry(vm.gpa, e);
        vm.reflatten = true;
    }

    fn refreshProgress(vm: *MissionVM, p: *Entry) void {
        var done: u16 = 0;
        for (p.children.items) |c| {
            if (c.row.status.isTerminal()) done +|= 1;
        }
        p.row.progress = if (p.children.items.len == 0) null else .{ .done = done, .total = @intCast(@min(p.children.items.len, std.math.maxInt(u16))) };
        // Workers in start order.
        std.sort.pdq(*Entry, p.children.items, {}, struct {
            fn lt(_: void, a: *Entry, b: *Entry) bool {
                return a.row.run.order(b.row.run) == .lt;
            }
        }.lt);
        vm.reflatten = true;
    }

    fn sortDirty(vm: *MissionVM) Allocator.Error!void {
        var it = vm.dirty.iterator();
        while (it.next()) |g| {
            std.sort.pdq(*Entry, vm.groups[@intFromEnum(g)].items, {}, before);
            vm.stats.sorted_groups += 1;
        }
        if (vm.dirty.count() > 0) vm.reflatten = true;
        vm.dirty = .initEmpty();
    }

    fn before(_: void, a: *Entry, b: *Entry) bool {
        const aa = a.row.needsAttention();
        const ba = b.row.needsAttention();
        if (aa != ba) return aa;
        if (a.row.activity_ms != b.row.activity_ms) return a.row.activity_ms > b.row.activity_ms;
        return a.row.run.order(b.row.run) == .gt;
    }

    fn flatten(vm: *MissionVM) Allocator.Error!void {
        vm.stats.flattened += 1;
        vm.items.clearRetainingCapacity();
        const all = vm.filter.isEmpty();
        for (vm.groups, 0..) |g, gi| {
            if (g.items.len == 0) continue;
            const header_at = vm.items.items.len;
            try vm.items.append(vm.gpa, .{ .header = .{ .group = @enumFromInt(gi), .count = 0 } });
            var n: u32 = 0;
            for (g.items) |e| {
                const self_ok = all or vm.filter.matches(e.subject);
                var child_ok = false;
                if (!all and !self_ok) {
                    for (e.children.items) |c| if (vm.filter.matches(c.subject)) {
                        child_ok = true;
                        break;
                    };
                }
                if (!self_ok and !child_ok) continue;
                n += 1;
                try vm.items.append(vm.gpa, .{ .row = &e.row });
                if (!e.row.expanded and !child_ok) continue;
                for (e.children.items) |c| {
                    if (all or vm.filter.matches(c.subject)) try vm.items.append(vm.gpa, .{ .row = &c.row });
                }
            }
            if (n == 0) {
                vm.items.shrinkRetainingCapacity(header_at);
            } else vm.items.items[header_at].header.count = n;
        }
        vm.reflatten = false;
    }

    /// Group headers and rows, in display order.
    pub fn rows(vm: *const MissionVM) []const Item {
        return vm.items.items;
    }

    pub fn get(vm: *const MissionVM, id: RunId) ?*const Row {
        const e = vm.entries.get(id.toInt()) orelse return null;
        return &e.row;
    }

    /// Children of a workflow row, in start order.
    pub fn children(vm: *const MissionVM, id: RunId, out: []RunId) []RunId {
        const e = vm.entries.get(id.toInt()) orelse return out[0..0];
        const n = @min(out.len, e.children.items.len);
        for (out[0..n], e.children.items[0..n]) |*o, c| o.* = c.row.run;
        return out[0..n];
    }

    /// Filters with `f`; its strings must outlive the filter.
    pub fn setFilter(vm: *MissionVM, f: Filter) void {
        vm.filter = f;
        vm.reflatten = true;
    }

    /// Parses and keeps `text` (the filter box's contents).
    pub fn setFilterText(vm: *MissionVM, text: []const u8) Allocator.Error!void {
        _ = vm.filter_arena.reset(.retain_capacity);
        const a = vm.filter_arena.allocator();
        vm.filter_text = try a.dupe(u8, text);
        vm.filter = try filter_mod.parseFilter(vm.filter_text, a);
        vm.reflatten = true;
        try vm.flatten();
    }

    /// The user has looked at the run (attached, peeked).
    pub fn markSeen(vm: *MissionVM, id: RunId) void {
        const e = vm.entries.getPtr(id.toInt()) orelse return;
        e.*.seen_revision = e.*.revision;
        if (!e.*.row.unread) return;
        e.*.row.unread = false;
        if (e.*.placed) vm.dirty.insert(e.*.row.group);
        vm.reflatten = true;
    }

    pub fn setExpanded(vm: *MissionVM, id: RunId, on: bool) void {
        const e = vm.entries.get(id.toInt()) orelse return;
        if (e.row.expanded == on) return;
        e.row.expanded = on;
        vm.reflatten = true;
    }

    /// Re-sorts and re-flattens after `markSeen`/`setExpanded` without a
    /// new view.
    pub fn refresh(vm: *MissionVM) Allocator.Error!void {
        try vm.sortDirty();
        if (vm.reflatten) try vm.flatten();
    }

    /// The number of rows (not headers) shown.
    pub fn rowCount(vm: *const MissionVM) usize {
        var n: usize = 0;
        for (vm.items.items) |it| {
            if (it == .row) n += 1;
        }
        return n;
    }
};

fn destroyEntry(gpa: Allocator, e: *Entry) void {
    e.children.deinit(gpa);
    e.arena.deinit();
    gpa.destroy(e);
}

fn firstLine(s: []const u8, max: usize) []const u8 {
    const line = s[0 .. std.mem.indexOfScalar(u8, s, '\n') orelse s.len];
    return line[0..@min(line.len, max)];
}
