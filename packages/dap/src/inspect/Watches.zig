//! Watch expressions (E07.F06.S04.T02): the workspace's list, evaluated
//! again on every stop and frame change, all at once with `context:
//! watch`. A watch the adapter does not answer within `timeout` shows as
//! `timed_out`; while the program runs every watch is `not_stopped` (its
//! last result kept for greying).
//!
//! The list persists in `<workspace-state>/debug/watches.zon`, written
//! atomically on every change. Part of an `Inspector`; UI thread only.

const Watches = @This();
const std = @import("std");
const Inspector = @import("Inspector.zig");
const Evaluator = @import("Evaluator.zig");
const persist = @import("../breakpoints/persist.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const log = std.log.scoped(.dap_watches);

pub const sub_path = "debug/watches.zon";
const file_version = 1;

pub const State = enum { pending, ok, error_, timed_out, not_stopped };

pub const WatchResult = struct {
    expr: []const u8,
    result: ?Evaluator.EvalResult = null,
    state: State = .not_stopped,
};

/// Where the list is saved.
pub const Persist = struct {
    dir: Io.Dir,
    /// Relative to `dir` (normally `sub_path` under the workspace state).
    path: []const u8 = sub_path,
};

const Meta = struct {
    /// The expression and the result's strings.
    expr: []u8,
    strings: []u8 = &.{},
    /// The evaluation this watch waits for.
    token: u64 = 0,
    deadline: Io.Timestamp = .zero,
};

gpa: Allocator,
list: std.ArrayList(WatchResult) = .empty,
meta: std.ArrayList(Meta) = .empty,
persist_to: ?Persist = null,
next_token: u64 = 1,

pub fn init(gpa: Allocator) Watches {
    return .{ .gpa = gpa };
}

pub fn deinit(w: *Watches) void {
    for (w.meta.items) |m| {
        w.gpa.free(m.expr);
        w.gpa.free(m.strings);
    }
    w.meta.deinit(w.gpa);
    w.list.deinit(w.gpa);
    w.* = undefined;
}

fn inspector(w: *Watches) *Inspector {
    return @alignCast(@fieldParentPtr("watches", w));
}

pub fn results(w: *const Watches) []const WatchResult {
    return w.list.items;
}

pub fn add(w: *Watches, expr: []const u8) void {
    const copy = w.gpa.dupe(u8, expr) catch return;
    w.meta.append(w.gpa, .{ .expr = copy }) catch return w.gpa.free(copy);
    w.list.append(w.gpa, .{ .expr = copy }) catch {
        _ = w.meta.pop();
        return w.gpa.free(copy);
    };
    w.changed();
    w.evaluateOne(w.list.items.len - 1);
}

pub fn edit(w: *Watches, i: u32, expr: []const u8) void {
    if (i >= w.list.items.len) return;
    const copy = w.gpa.dupe(u8, expr) catch return;
    const m = &w.meta.items[i];
    w.gpa.free(m.expr);
    w.gpa.free(m.strings);
    m.* = .{ .expr = copy };
    w.list.items[i] = .{ .expr = copy };
    w.changed();
    w.evaluateOne(i);
}

pub fn remove(w: *Watches, i: u32) void {
    if (i >= w.list.items.len) return;
    const m = w.meta.orderedRemove(i);
    _ = w.list.orderedRemove(i);
    w.gpa.free(m.expr);
    w.gpa.free(m.strings);
    w.changed();
}

/// Evaluates every watch in `frame`, in one batch.
pub fn reevaluate(w: *Watches, frame: i64) void {
    for (0..w.list.items.len) |i| w.evaluateIn(i, frame);
}

fn evaluateOne(w: *Watches, i: usize) void {
    w.evaluateIn(i, w.inspector().vars.frame_id);
}

fn evaluateIn(w: *Watches, i: usize, frame: ?i64) void {
    const insp = w.inspector();
    if (insp.liveGen() == null) {
        w.list.items[i].state = .not_stopped;
        return;
    }
    const m = &w.meta.items[i];
    m.token = w.next_token;
    w.next_token += 1;
    m.deadline = Io.Timestamp.now(insp.io, .awake).addDuration(insp.opts.watch_timeout);
    w.list.items[i].state = .pending;
    insp.eval.evaluate(m.expr, .watch, frame, .{ .ctx = w, .user = m.token, .func = onResult });
}

fn onResult(ctx: ?*anyopaque, token: u64, r: *const Evaluator.EvalResult) void {
    const w: *Watches = @ptrCast(@alignCast(ctx.?));
    for (w.meta.items, w.list.items) |*m, *v| {
        if (m.token != token) continue;
        if (v.state != .pending) return; // timed out, or the program ran on
        w.setResult(m, v, r) catch return;
        return;
    }
}

fn setResult(w: *Watches, m: *Meta, v: *WatchResult, r: *const Evaluator.EvalResult) Allocator.Error!void {
    const ty = r.type orelse "";
    const mem = r.memory_ref orelse "";
    const buf = try w.gpa.alloc(u8, r.value.len + ty.len + mem.len);
    @memcpy(buf[0..r.value.len], r.value);
    @memcpy(buf[r.value.len..][0..ty.len], ty);
    @memcpy(buf[r.value.len + ty.len ..], mem);
    w.gpa.free(m.strings);
    m.strings = buf;
    v.result = .{
        .value = buf[0..r.value.len],
        .type = if (r.type != null) buf[r.value.len..][0..ty.len] else null,
        .memory_ref = if (r.memory_ref != null) buf[r.value.len + ty.len ..] else null,
        .node = r.node,
        .err = r.err,
    };
    v.state = if (r.err) .error_ else .ok;
}

/// Marks watches past their deadline `timed_out`; true when any changed.
pub fn tick(w: *Watches, now: Io.Timestamp) bool {
    var any = false;
    for (w.meta.items, w.list.items) |m, *v| {
        if (v.state == .pending and now.nanoseconds >= m.deadline.nanoseconds) {
            v.state = .timed_out;
            any = true;
        }
    }
    return any;
}

/// The program runs (or the session ended).
pub fn markNotStopped(w: *Watches) void {
    for (w.list.items) |*v| v.state = .not_stopped;
}

/// Watches still waiting for the adapter.
pub fn pendingCount(w: *const Watches) usize {
    var n: usize = 0;
    for (w.list.items) |v| n += @intFromBool(v.state == .pending);
    return n;
}

// ---------------------------------------------------------------------
// Persistence.

const File = struct {
    version: u32 = file_version,
    watches: []const []const u8 = &.{},
};

/// Replaces the list with a `watches.zon` text (states `not_stopped`).
pub fn load(w: *Watches, bytes: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(w.gpa);
    defer arena.deinit();
    const z = try arena.allocator().dupeZ(u8, bytes);
    const f = try std.zon.parse.fromSliceAlloc(File, arena.allocator(), z, null, .{ .ignore_unknown_fields = true, .free_on_error = false });
    if (f.version != file_version) return error.UnsupportedVersion;
    for (w.meta.items) |m| {
        w.gpa.free(m.expr);
        w.gpa.free(m.strings);
    }
    w.meta.clearRetainingCapacity();
    w.list.clearRetainingCapacity();
    for (f.watches) |e| {
        const copy = try w.gpa.dupe(u8, e);
        errdefer w.gpa.free(copy);
        try w.meta.append(w.gpa, .{ .expr = copy });
        try w.list.append(w.gpa, .{ .expr = copy });
    }
}

/// The list as `watches.zon` text, in `a`.
pub fn encode(w: *const Watches, a: Allocator) Allocator.Error![]u8 {
    const exprs = try a.alloc([]const u8, w.list.items.len);
    defer a.free(exprs);
    for (exprs, w.list.items) |*e, v| e.* = v.expr;
    var out: Io.Writer.Allocating = .init(a);
    std.zon.stringify.serialize(File{ .watches = exprs }, .{}, &out.writer) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    return out.toOwnedSlice() catch error.OutOfMemory;
}

fn changed(w: *Watches) void {
    const p = w.persist_to orelse return;
    const text = w.encode(w.gpa) catch return;
    defer w.gpa.free(text);
    persist.writeAtomic(w.inspector().io, p.dir, p.path, text) catch |e| log.warn("cannot save the watches: {t}", .{e});
}
