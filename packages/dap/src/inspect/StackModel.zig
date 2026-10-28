//! Call stacks (E07.F06.S04.T01): frames per thread, paged with
//! `stackTrace {startFrame, levels}`, and the selected frame, which drives
//! the scopes, the editor reveal and (later) the watches.
//!
//! After a stop the stopped thread's first page comes from the session's
//! prefetch; the frame to select is the first with a source and a
//! `normal` hint (`subtle` and `label` frames are skipped), else the top.
//! While the program runs the old frames stay (greyed by the UI) until
//! the next stop replaces them. Part of an `Inspector`; UI thread only.

const StackModel = @This();
const std = @import("std");
const Inspector = @import("Inspector.zig");
const Channel = @import("Channel.zig");

const Allocator = std.mem.Allocator;

pub const Hint = enum { normal, label, subtle };

pub const SourceRef = struct {
    path: ?[]const u8 = null,
    name: ?[]const u8 = null,
    /// `sourceReference` (> 0): the text comes from the `source` request.
    reference: ?i64 = null,
    /// The source's `presentationHint` is `deemphasize`.
    deemphasize: bool = false,
};

pub const FrameRow = struct {
    id: i64,
    name: []const u8,
    source: ?SourceRef,
    line: u32,
    column: u32,
    hint: Hint,
    can_restart: bool,
    ip_ref: ?[]const u8,
    /// `moduleId` as text (adapters use numbers or strings).
    module: ?[]const u8,
};

pub const Selection = struct { thread: i64, frame: i64 };

const Thread = struct {
    id: i64,
    /// Rows and their strings; replaced by a new first page.
    arena: std.heap.ArenaAllocator,
    rows: std.ArrayList(FrameRow) = .empty,
    total: ?u32 = null,
    /// The generation the rows belong to.
    gen: u64 = 0,
    /// A page request is out.
    loading: bool = false,
    complete: bool = false,
    /// The next first page re-selects the frame at `selected_index`
    /// (after an `invalidated` event).
    reselect: bool = false,
};

gpa: Allocator,
threads: std.ArrayList(*Thread) = .empty,
selected_: ?Selection = null,
/// The selected frame's index in its thread.
selected_index: u32 = 0,

pub fn init(gpa: Allocator) StackModel {
    return .{ .gpa = gpa };
}

pub fn deinit(m: *StackModel) void {
    for (m.threads.items) |t| {
        t.arena.deinit();
        m.gpa.destroy(t);
    }
    m.threads.deinit(m.gpa);
    m.* = undefined;
}

fn inspector(m: *StackModel) *Inspector {
    return @fieldParentPtr("stack", m);
}

fn find(m: *const StackModel, thread: i64) ?*Thread {
    for (m.threads.items) |t| if (t.id == thread) return t;
    return null;
}

fn ensure(m: *StackModel, thread: i64) Allocator.Error!*Thread {
    if (m.find(thread)) |t| return t;
    const t = try m.gpa.create(Thread);
    errdefer m.gpa.destroy(t);
    t.* = .{ .id = thread, .arena = .init(m.gpa) };
    try m.threads.append(m.gpa, t);
    return t;
}

/// The frames known for `thread` (possibly of an earlier stop while the
/// program runs).
pub fn frames(m: *const StackModel, thread: i64) []const FrameRow {
    const t = m.find(thread) orelse return &.{};
    return t.rows.items;
}

/// `totalFrames`, or the count once the last page arrived; null while
/// unknown.
pub fn total(m: *const StackModel, thread: i64) ?u32 {
    const t = m.find(thread) orelse return null;
    if (t.total) |n| return n;
    if (t.complete) return @intCast(t.rows.items.len);
    return null;
}

/// All frames of `thread` are loaded.
pub fn complete(m: *const StackModel, thread: i64) bool {
    const t = m.find(thread) orelse return false;
    return t.complete;
}

/// Loads `count` more frames of `thread` (its first page when it has none
/// from this stop).
pub fn loadMore(m: *StackModel, thread: i64, count: u32) void {
    const insp = m.inspector();
    const gen = insp.liveGen() orelse return;
    const t = m.ensure(thread) catch return;
    if (t.loading) return;
    if (t.gen == gen and t.complete) return;
    const start: u32 = if (t.gen == gen) @intCast(t.rows.items.len) else 0;
    m.request(t, start, count);
}

fn request(m: *StackModel, t: *Thread, start: u32, count: u32) void {
    const insp = m.inspector();
    var buf: [128]u8 = undefined;
    const args = std.fmt.bufPrint(&buf, "{{\"threadId\":{d},\"startFrame\":{d},\"levels\":{d}}}", .{ t.id, start, count }) catch unreachable;
    if (insp.send("stackTrace", args, .{ .kind = .stack_page, .a = @bitCast(t.id), .b = start, .c = count })) t.loading = true;
}

/// Asks for `thread`'s first page again and re-selects the same frame
/// index when it arrives (`invalidated` with `stacks`).
pub fn refresh(m: *StackModel, thread: i64) void {
    const t = m.ensure(thread) catch return;
    t.reselect = true;
    t.loading = false;
    m.request(t, 0, m.inspector().opts.page);
}

/// Selects `frame` of `thread`: its scopes become the variables' roots,
/// the editor reveals it and a source without a path is fetched.
pub fn select(m: *StackModel, thread: i64, frame: i64) void {
    const insp = m.inspector();
    const gen = insp.liveGen() orelse return;
    const t = m.find(thread) orelse return;
    if (t.gen != gen) return;
    for (t.rows.items, 0..) |*row, i| if (row.id == frame) {
        m.selected_index = @intCast(i);
        insp.selectRow(thread, row, null);
        return;
    };
}

pub fn selected(m: *const StackModel) ?Selection {
    return m.selected_;
}

/// The selected frame's row.
pub fn selectedRow(m: *const StackModel) ?*const FrameRow {
    const sel = m.selected_ orelse return null;
    const t = m.find(sel.thread) orelse return null;
    for (t.rows.items) |*r| if (r.id == sel.frame) return r;
    return null;
}

/// The frame to select after a stop.
pub fn autoSelect(m: *const StackModel, thread: i64) ?u32 {
    const rows = m.frames(thread);
    for (rows, 0..) |r, i| {
        const src = r.source orelse continue;
        if (src.path == null and (src.reference orelse 0) <= 0) continue;
        if (r.hint != .normal or src.deemphasize) continue;
        return @intCast(i);
    }
    return if (rows.len > 0) 0 else null;
}

/// A `stackTrace` page for `thread` from `start` (`count` asked).
/// Returns the thread when the frame at `selected_index` should be
/// selected again.
pub fn applyPage(m: *StackModel, thread: i64, start: u32, count: u32, gen: u64, ok: bool, body: []const u8) Allocator.Error!?*Thread {
    const t = try m.ensure(thread);
    t.loading = false;
    if (!ok) {
        if (t.gen == gen) t.complete = true;
        return null;
    }
    if (start == 0) {
        var arena: std.heap.ArenaAllocator = .init(m.gpa);
        errdefer arena.deinit();
        var rows: std.ArrayList(FrameRow) = .empty;
        const got = try parse(arena.allocator(), body, &rows);
        t.arena.deinit();
        t.arena = arena;
        t.rows = rows;
        t.gen = gen;
        t.total = got.total;
        t.complete = got.n < count or (got.total != null and rows.items.len >= got.total.?);
        if (t.reselect) {
            t.reselect = false;
            return t;
        }
        return null;
    }
    if (t.gen != gen or start != t.rows.items.len) return null;
    const got = try parse(t.arena.allocator(), body, &t.rows);
    if (got.total) |n| t.total = n;
    t.complete = got.n < count or (t.total != null and t.rows.items.len >= t.total.?);
    return null;
}

/// The row to re-select on `t` after a refresh.
pub fn reselectRow(m: *StackModel, t: *Thread) ?*const FrameRow {
    if (t.rows.items.len == 0) return null;
    const i = @min(m.selected_index, t.rows.items.len - 1);
    m.selected_index = @intCast(i);
    return &t.rows.items[i];
}

/// Forgets everything (the session ended).
pub fn clear(m: *StackModel) void {
    for (m.threads.items) |t| {
        t.arena.deinit();
        m.gpa.destroy(t);
    }
    m.threads.clearRetainingCapacity();
    m.selected_ = null;
    m.selected_index = 0;
}

const Body = struct {
    stackFrames: []const Frame = &.{},
    totalFrames: ?i64 = null,

    const Frame = struct {
        id: i64,
        name: []const u8 = "",
        line: i64 = 0,
        column: i64 = 0,
        source: ?struct {
            path: ?[]const u8 = null,
            name: ?[]const u8 = null,
            sourceReference: ?i64 = null,
            presentationHint: ?[]const u8 = null,
        } = null,
        presentationHint: ?[]const u8 = null,
        canRestart: ?bool = null,
        instructionPointerReference: ?[]const u8 = null,
        moduleId: ?std.json.Value = null,
    };
};

/// Appends the frames of a `stackTrace` body to `rows`, all in `a`.
fn parse(a: Allocator, body: []const u8, rows: *std.ArrayList(FrameRow)) Allocator.Error!struct { n: usize, total: ?u32 } {
    const b = std.json.parseFromSliceLeaky(Body, a, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .n = 0, .total = null },
    };
    try rows.ensureUnusedCapacity(a, b.stackFrames.len);
    for (b.stackFrames) |f| {
        const hint: Hint = if (f.presentationHint) |h|
            (if (std.mem.eql(u8, h, "label")) .label else if (std.mem.eql(u8, h, "subtle")) .subtle else .normal)
        else
            .normal;
        rows.appendAssumeCapacity(.{
            .id = f.id,
            .name = f.name,
            .source = if (f.source) |s| .{
                .path = s.path,
                .name = s.name,
                .reference = s.sourceReference,
                .deemphasize = if (s.presentationHint) |h| std.mem.eql(u8, h, "deemphasize") else false,
            } else null,
            .line = std.math.cast(u32, f.line) orelse 0,
            .column = std.math.cast(u32, f.column) orelse 0,
            .hint = hint,
            .can_restart = f.canRestart orelse false,
            .ip_ref = f.instructionPointerReference,
            .module = if (f.moduleId) |v| switch (v) {
                .string => |s| s,
                .integer => |n| try std.fmt.allocPrint(a, "{d}", .{n}),
                else => null,
            } else null,
        });
    }
    const t: ?u32 = if (b.totalFrames) |n| (if (n > 0) std.math.cast(u32, n) else null) else null;
    return .{ .n = b.stackFrames.len, .total = t };
}
