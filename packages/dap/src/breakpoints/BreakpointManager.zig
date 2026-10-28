//! The breakpoint model (E07.F06.S03.T01): the user's breakpoints of every
//! kind, independent of sessions, kept in sync with each running session.
//!
//! - **Kinds**: source (line, column, condition, hit condition, log
//!   message, mode), function, data and instruction breakpoints.
//! - **Anchoring**: while a document is open its source breakpoints are
//!   tracked by the `LineHost` (E05 anchors in the app, `LineTracker` in
//!   tests and headless hosts), so they follow edits; the line is asked
//!   for on demand. `docClosed` freezes it, `docOpened` tracks it again,
//!   `renamed` moves breakpoints to the new path.
//! - **Sync**: `sendAll` (the session's `BreakpointSink`, after
//!   `initialized`) sends `setBreakpoints` per source with the enabled
//!   breakpoints, then function, data and instruction breakpoints and the
//!   exception filters, and waits for the answers. Responses map by index
//!   to our breakpoints and give each session its own state (verified,
//!   message, actual line, adapter id). Later changes are re-sent at once
//!   to every live session; `documentSaved` (and, with
//!   `send_on_edit = .immediate`, 300 ms after edits settle) re-sends a
//!   source with `sourceModified` when it has unsaved changes. A
//!   `breakpoint` event updates, adopts (`new`) or drops (`removed`) by
//!   adapter id.
//! - **Feature gates**: a condition, hit condition or mode the adapter
//!   does not support is stripped and the breakpoint marked `unsupported`
//!   with a message. Logpoints the adapter cannot do are not sent at all
//!   (stopping and continuing instead would surprise), nor are function,
//!   data or instruction breakpoints the adapter lacks.
//! - **Exception filters** come from the adapter's capabilities; their
//!   defaults apply the first time an adapter type is seen, and the
//!   choices (enabled, condition) are remembered per adapter type.
//! - **Persistence** (persist.zig): loaded with `load`, saved 1 s after
//!   the last change to `<workspace-state>/debug/breakpoints.zon`. Data
//!   breakpoints that cannot persist are dropped when their session ends.
//!
//! Threading: every method takes the manager's lock and may be called
//! from any thread; `sendAll` blocks (it runs on a session worker).
//! Responses and events arrive on the sessions' dispatchers. Listeners are
//! called without the lock held. The `LineHost` is called with the lock
//! held and must not call back into the manager.

const BreakpointManager = @This();
const std = @import("std");
const builtin = @import("builtin");
const zg_core = @import("zg_core");
const zg_perf = @import("zg_perf");
const protocol = @import("../gen/protocol.zig");
const DapConnection = @import("../conn/DapConnection.zig");
const DebugSession = @import("../session/DebugSession.zig");
const DebugManager = @import("../session/DebugManager.zig");
const persist = @import("persist.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Subsystem = zg_core.runtime.Subsystem;
const log = std.log.scoped(.dap_breakpoints);

pub const BpId = enum(u32) { _ };
pub const Access = persist.Access;

pub const SourceBp = struct {
    path: []const u8,
    /// 1-based. The frozen line; while tracked the host's line wins.
    line: u32,
    column: ?u32 = null,
    condition: ?[]const u8 = null,
    hit_condition: ?[]const u8 = null,
    log_message: ?[]const u8 = null,
    mode: ?[]const u8 = null,
};

pub const FunctionBp = struct {
    name: []const u8,
    condition: ?[]const u8 = null,
    hit_condition: ?[]const u8 = null,
};

pub const DataBp = struct {
    data_id: []const u8,
    description: []const u8,
    access: Access = .write,
    condition: ?[]const u8 = null,
    hit_condition: ?[]const u8 = null,
    /// False: dropped when the session that made it ends.
    can_persist: bool = true,
};

pub const InstructionBp = struct {
    reference: []const u8,
    offset: i64 = 0,
    condition: ?[]const u8 = null,
    hit_condition: ?[]const u8 = null,
};

pub const Kind = union(enum) {
    source: SourceBp,
    function: FunctionBp,
    data: DataBp,
    instruction: InstructionBp,
};

pub const Breakpoint = struct {
    /// Set by `add`.
    id: BpId = @enumFromInt(0),
    enabled: bool = true,
    kind: Kind,
};

/// A breakpoint in one session.
pub const SessionBpState = struct {
    verified: bool = false,
    message: ?[]const u8 = null,
    actual_line: ?u32 = null,
    adapter_id: ?i64 = null,
    /// Something was stripped, or it was not sent (see `message`).
    unsupported: bool = false,
};

/// A breakpoint as the UI lists it.
pub const View = struct {
    bp: Breakpoint,
    /// Some live session verified it.
    verified: bool,
    /// Some live session could not take all of it.
    unsupported: bool,
    /// Sessions are live (unverified breakpoints show hollow).
    sessions: bool,
    /// The first session's message.
    message: ?[]const u8,
    /// Adopted from the adapter (`breakpoint` event `new`).
    adopted: bool,
};

pub const ExceptionFilterState = struct {
    filter: []const u8,
    label: []const u8,
    description: ?[]const u8 = null,
    enabled: bool,
    condition: ?[]const u8 = null,
    supports_condition: bool = false,
    condition_description: ?[]const u8 = null,
};

/// Field changes for `update`; `condition = @as(?[]const u8, null)` clears.
pub const Patch = struct {
    enabled: ?bool = null,
    line: ?u32 = null,
    condition: ??[]const u8 = null,
    hit_condition: ??[]const u8 = null,
    log_message: ??[]const u8 = null,
};

/// Tracks lines of open documents through edits.
pub const LineHost = struct {
    ctx: ?*anyopaque,
    /// Starts tracking 1-based `line` of `path` if it is open; null if not.
    track: *const fn (ctx: ?*anyopaque, path: []const u8, line: u32) ?u64,
    /// The tracked line now (null: the document closed).
    line: *const fn (ctx: ?*anyopaque, handle: u64) ?u32,
    untrack: *const fn (ctx: ?*anyopaque, handle: u64) void,
    /// The open document has unsaved changes.
    dirty: *const fn (ctx: ?*anyopaque, path: []const u8) bool,
};

pub const Change = enum {
    /// Breakpoints were added, removed or changed.
    model,
    /// A session's verification state changed.
    state,
    exception_filters,
};

pub const Listener = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, change: Change) void,
};

pub const DataInfo = struct {
    /// Null: no data breakpoint can be set on the variable (`description`
    /// says why).
    data_id: ?[]const u8,
    description: []const u8,
    access_types: []const Access = &.{},
    can_persist: bool = false,
};

pub const InfoCb = struct {
    ctx: ?*anyopaque,
    /// `info` (null on failure) is valid during the call.
    func: *const fn (ctx: ?*anyopaque, info: ?DataInfo) void,
};

pub const SendOnEdit = enum { on_save, immediate };

pub const Persist = struct {
    /// The workspace state directory.
    dir: Io.Dir,
    path: []const u8 = persist.sub_path,
    /// Paths under it are saved relative.
    workspace_root: []const u8 = "",
    debounce: Io.Duration = .fromSeconds(1),
};

pub const Options = struct {
    host: ?LineHost = null,
    persist: ?Persist = null,
    send_on_edit: SendOnEdit = .on_save,
    edit_settle: Io.Duration = .fromMilliseconds(300),
    /// How long `sendAll` waits for the answers.
    send_timeout: Io.Duration = .fromSeconds(5),
};

const PerSession = struct {
    s: *DebugSession,
    st: SessionBpState = .{},

    fn setMessage(p: *PerSession, gpa: Allocator, msg: ?[]const u8) void {
        if (p.st.message) |old| gpa.free(old);
        p.st.message = if (msg) |m| gpa.dupe(u8, m) catch null else null;
    }
};

const Entry = struct {
    bp: Breakpoint,
    /// The breakpoint's strings, in one allocation.
    strings: []u8 = &.{},
    handle: ?u64 = null,
    states: std.ArrayList(PerSession) = .empty,
    adopted: bool = false,
    /// A "Run to Line" breakpoint, sent only to `temp_for`.
    temp_for: ?*DebugSession = null,

    fn state(e: *Entry, s: *const DebugSession) ?*PerSession {
        for (e.states.items) |*p| if (p.s == s) return p;
        return null;
    }

    fn stateFor(e: *Entry, gpa: Allocator, s: *DebugSession) Allocator.Error!*PerSession {
        if (e.state(s)) |p| return p;
        try e.states.append(gpa, .{ .s = s });
        return &e.states.items[e.states.items.len - 1];
    }

    fn dropState(e: *Entry, gpa: Allocator, s: *const DebugSession) void {
        for (e.states.items, 0..) |*p, i| if (p.s == s) {
            p.setMessage(gpa, null);
            _ = e.states.swapRemove(i);
            return;
        };
    }
};

const Filt = struct {
    adapter_type: []u8,
    filter: []u8,
    enabled: bool,
    condition: ?[]u8 = null,
};

gpa: Allocator,
io: Io,
opts: Options,
mutex: Io.Mutex = .init,
entries: std.ArrayList(*Entry) = .empty,
next_id: u32 = 1,
listeners: std.ArrayList(Listener) = .empty,
/// Sessions that got `sendAll` and have not ended.
live: std.ArrayList(*DebugSession) = .empty,
filters: std.ArrayList(Filt) = .empty,
/// Paths edited and not re-sent yet (`send_on_edit = .immediate`).
edited: std.ArrayList([]u8) = .empty,
last_edit: Io.Timestamp = .zero,
edit_timer: bool = false,
dirty: bool = false,
last_change: Io.Timestamp = .zero,
save_timer: bool = false,
saves: u32 = 0,
work: Subsystem,

pub fn init(gpa: Allocator, io: Io, opts: Options) BreakpointManager {
    return .{ .gpa = gpa, .io = io, .opts = opts, .work = .init(io) };
}

/// Saves pending changes and frees everything. After every session has
/// ended.
pub fn deinit(m: *BreakpointManager) void {
    m.work.shutdown();
    if (m.dirty) m.saveNow() catch |e| log.warn("cannot save breakpoints: {t}", .{e});
    for (m.entries.items) |e| m.freeEntry(e);
    m.entries.deinit(m.gpa);
    m.listeners.deinit(m.gpa);
    m.live.deinit(m.gpa);
    for (m.filters.items) |f| freeFilt(m.gpa, f);
    m.filters.deinit(m.gpa);
    for (m.edited.items) |p| m.gpa.free(p);
    m.edited.deinit(m.gpa);
    m.* = undefined;
}

fn freeEntry(m: *BreakpointManager, e: *Entry) void {
    if (e.handle) |h| if (m.opts.host) |host| host.untrack(host.ctx, h);
    for (e.states.items) |*p| p.setMessage(m.gpa, null);
    e.states.deinit(m.gpa);
    m.gpa.free(e.strings);
    m.gpa.destroy(e);
}

fn freeFilt(gpa: Allocator, f: Filt) void {
    gpa.free(f.adapter_type);
    gpa.free(f.filter);
    if (f.condition) |c| gpa.free(c);
}

fn lock(m: *BreakpointManager) void {
    m.mutex.lockUncancelable(m.io);
}

fn unlock(m: *BreakpointManager) void {
    m.mutex.unlock(m.io);
}

pub fn subscribe(m: *BreakpointManager, l: Listener) Allocator.Error!void {
    m.lock();
    defer m.unlock();
    try m.listeners.append(m.gpa, l);
}

fn notify(m: *BreakpointManager, change: Change) void {
    var copy: [16]Listener = undefined;
    m.lock();
    const n = @min(copy.len, m.listeners.items.len);
    @memcpy(copy[0..n], m.listeners.items[0..n]);
    m.unlock();
    for (copy[0..n]) |l| l.func(l.ctx, change);
}

// ---------------------------------------------------------------------
// The model.

fn find(m: *BreakpointManager, id: BpId) ?*Entry {
    for (m.entries.items) |e| if (e.bp.id == id) return e;
    return null;
}

fn findIndex(m: *BreakpointManager, id: BpId) ?usize {
    for (m.entries.items, 0..) |e, i| if (e.bp.id == id) return i;
    return null;
}

/// The current line of a source breakpoint.
fn lineOf(m: *BreakpointManager, e: *const Entry) u32 {
    const src = e.bp.kind.source;
    if (e.handle) |h| if (m.opts.host) |host| if (host.line(host.ctx, h)) |l| return l;
    return src.line;
}

fn optLen(s: ?[]const u8) usize {
    return if (s) |x| x.len else 0;
}

fn kindBytes(k: Kind) usize {
    return switch (k) {
        .source => |s| s.path.len + optLen(s.condition) + optLen(s.hit_condition) + optLen(s.log_message) + optLen(s.mode),
        .function => |f| f.name.len + optLen(f.condition) + optLen(f.hit_condition),
        .data => |d| d.data_id.len + d.description.len + optLen(d.condition) + optLen(d.hit_condition),
        .instruction => |i| i.reference.len + optLen(i.condition) + optLen(i.hit_condition),
    };
}

/// Copies `k`'s strings into one new allocation of `e` (`k` may point
/// at `e`'s old strings).
fn setKind(gpa: Allocator, e: *Entry, k: Kind) Allocator.Error!void {
    const buf = try gpa.alloc(u8, kindBytes(k));
    var fba: std.heap.FixedBufferAllocator = .init(buf);
    const copy = copyKind(fba.allocator(), k) catch unreachable;
    gpa.free(e.strings);
    e.strings = buf;
    e.bp.kind = copy;
}

fn dupeOpt(a: Allocator, s: ?[]const u8) Allocator.Error!?[]const u8 {
    return if (s) |x| try a.dupe(u8, x) else null;
}

fn copyKind(a: Allocator, k: Kind) Allocator.Error!Kind {
    return switch (k) {
        .source => |s| .{ .source = .{
            .path = try a.dupe(u8, s.path),
            .line = s.line,
            .column = s.column,
            .condition = try dupeOpt(a, s.condition),
            .hit_condition = try dupeOpt(a, s.hit_condition),
            .log_message = try dupeOpt(a, s.log_message),
            .mode = try dupeOpt(a, s.mode),
        } },
        .function => |f| .{ .function = .{
            .name = try a.dupe(u8, f.name),
            .condition = try dupeOpt(a, f.condition),
            .hit_condition = try dupeOpt(a, f.hit_condition),
        } },
        .data => |d| .{ .data = .{
            .data_id = try a.dupe(u8, d.data_id),
            .description = try a.dupe(u8, d.description),
            .access = d.access,
            .condition = try dupeOpt(a, d.condition),
            .hit_condition = try dupeOpt(a, d.hit_condition),
            .can_persist = d.can_persist,
        } },
        .instruction => |i| .{ .instruction = .{
            .reference = try a.dupe(u8, i.reference),
            .offset = i.offset,
            .condition = try dupeOpt(a, i.condition),
            .hit_condition = try dupeOpt(a, i.hit_condition),
        } },
    };
}

/// Adds under the lock; no re-send.
fn addLocked(m: *BreakpointManager, bp: Breakpoint) Allocator.Error!*Entry {
    const e = try m.gpa.create(Entry);
    errdefer m.gpa.destroy(e);
    e.* = .{ .bp = bp };
    try setKind(m.gpa, e, bp.kind);
    errdefer m.gpa.free(e.strings);
    e.bp.id = @enumFromInt(m.next_id);
    try m.entries.append(m.gpa, e);
    m.next_id += 1;
    if (e.bp.kind == .source) if (m.opts.host) |host| {
        e.handle = host.track(host.ctx, e.bp.kind.source.path, e.bp.kind.source.line);
    };
    return e;
}

pub fn add(m: *BreakpointManager, bp: Breakpoint) Allocator.Error!BpId {
    m.lock();
    const e = m.addLocked(bp) catch |err| {
        m.unlock();
        return err;
    };
    const id = e.bp.id;
    const target = targetOf(e);
    m.changedLocked();
    m.unlock();
    m.resend(target);
    m.notify(.model);
    return id;
}

pub fn remove(m: *BreakpointManager, id: BpId) void {
    m.lock();
    const i = m.findIndex(id) orelse return m.unlock();
    const e = m.entries.orderedRemove(i);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = copyTarget(targetOf(e), &path_buf);
    m.freeEntry(e);
    m.changedLocked();
    m.unlock();
    m.resend(target);
    m.notify(.model);
}

pub fn update(m: *BreakpointManager, id: BpId, patch: Patch) Allocator.Error!void {
    m.lock();
    const e = m.find(id) orelse return m.unlock();
    errdefer m.unlock();
    if (patch.enabled) |on| e.bp.enabled = on;
    // Patched in a copy pointing at the old strings and the patch's,
    // then copied into one new allocation.
    var kind = e.bp.kind;
    switch (kind) {
        .source => |*s| {
            if (patch.line) |l| {
                s.line = l;
                if (m.opts.host) |host| if (e.handle) |h| {
                    host.untrack(host.ctx, h);
                    e.handle = host.track(host.ctx, s.path, l);
                };
            }
            if (patch.condition) |c| s.condition = c;
            if (patch.hit_condition) |c| s.hit_condition = c;
            if (patch.log_message) |c| s.log_message = c;
        },
        inline else => |*k| {
            if (patch.condition) |c| k.condition = c;
            if (patch.hit_condition) |c| k.hit_condition = c;
        },
    }
    try setKind(m.gpa, e, kind);
    const target = targetOf(e);
    m.changedLocked();
    m.unlock();
    m.resend(target);
    m.notify(.model);
}

pub fn setEnabledAll(m: *BreakpointManager, on: bool) void {
    m.lock();
    for (m.entries.items) |e| if (e.temp_for == null) {
        e.bp.enabled = on;
    };
    m.changedLocked();
    m.unlock();
    m.resend(.all);
    m.notify(.model);
}

/// The gutter's breakpoint lane was clicked on 1-based `line` of `path`:
/// removes the source breakpoints there, or adds one. Returns the new
/// breakpoint, or null when one was removed.
pub fn toggleLine(m: *BreakpointManager, path: []const u8, line: u32) Allocator.Error!?BpId {
    m.lock();
    var removed = false;
    var i: usize = 0;
    while (i < m.entries.items.len) {
        const e = m.entries.items[i];
        if (e.temp_for == null and e.bp.kind == .source and std.mem.eql(u8, e.bp.kind.source.path, path) and m.lineOf(e) == line) {
            _ = m.entries.orderedRemove(i);
            m.freeEntry(e);
            removed = true;
        } else i += 1;
    }
    if (removed) {
        m.changedLocked();
        m.unlock();
        m.resend(.{ .source = path });
        m.notify(.model);
        return null;
    }
    m.unlock();
    return try m.add(.{ .kind = .{ .source = .{ .path = path, .line = line } } });
}

/// Copies of the breakpoints (current lines, strings in `a`), in order.
pub fn list(m: *BreakpointManager, a: Allocator) Allocator.Error![]View {
    m.lock();
    defer m.unlock();
    var out: std.ArrayList(View) = try .initCapacity(a, m.entries.items.len);
    for (m.entries.items) |e| if (e.temp_for == null) out.appendAssumeCapacity(try m.viewOf(a, e));
    return out.items;
}

pub fn get(m: *BreakpointManager, a: Allocator, id: BpId) Allocator.Error!?View {
    m.lock();
    defer m.unlock();
    const e = m.find(id) orelse return null;
    return try m.viewOf(a, e);
}

fn viewOf(m: *BreakpointManager, a: Allocator, e: *Entry) Allocator.Error!View {
    var bp = e.bp;
    bp.kind = try copyKind(a, e.bp.kind);
    if (bp.kind == .source) bp.kind.source.line = m.lineOf(e);
    var v: View = .{ .bp = bp, .verified = false, .unsupported = false, .sessions = m.live.items.len > 0, .message = null, .adopted = e.adopted };
    for (e.states.items) |p| {
        if (p.st.verified) v.verified = true;
        if (p.st.unsupported) v.unsupported = true;
        if (v.message == null) if (p.st.message) |msg| {
            v.message = try a.dupe(u8, msg);
        };
    }
    return v;
}

/// `id`'s state in `s` (message in `a`).
pub fn stateIn(m: *BreakpointManager, a: Allocator, id: BpId, s: *const DebugSession) Allocator.Error!?SessionBpState {
    m.lock();
    defer m.unlock();
    const e = m.find(id) orelse return null;
    const p = e.state(s) orelse return null;
    var st = p.st;
    st.message = try dupeOpt(a, p.st.message);
    return st;
}

/// The source breakpoints of `path` with their current lines (for the
/// gutter), strings in `a`.
pub fn inSource(m: *BreakpointManager, a: Allocator, path: []const u8) Allocator.Error![]View {
    m.lock();
    defer m.unlock();
    var out: std.ArrayList(View) = .empty;
    for (m.entries.items) |e| {
        if (e.temp_for != null or e.bp.kind != .source or !std.mem.eql(u8, e.bp.kind.source.path, path)) continue;
        try out.append(a, try m.viewOf(a, e));
    }
    return out.items;
}

// ---------------------------------------------------------------------
// Documents.

/// `path` opened: its source breakpoints are tracked from now.
pub fn docOpened(m: *BreakpointManager, path: []const u8) void {
    m.lock();
    defer m.unlock();
    const host = m.opts.host orelse return;
    for (m.entries.items) |e| {
        if (e.bp.kind != .source or e.handle != null or !std.mem.eql(u8, e.bp.kind.source.path, path)) continue;
        e.handle = host.track(host.ctx, path, e.bp.kind.source.line);
    }
}

/// `path` closes: the tracked lines are frozen.
pub fn docClosed(m: *BreakpointManager, path: []const u8) void {
    m.lock();
    defer m.unlock();
    const host = m.opts.host orelse return;
    var changed = false;
    for (m.entries.items) |e| {
        if (e.bp.kind != .source or !std.mem.eql(u8, e.bp.kind.source.path, path)) continue;
        const h = e.handle orelse continue;
        if (host.line(host.ctx, h)) |l| {
            if (l != e.bp.kind.source.line) changed = true;
            e.bp.kind.source.line = l;
        }
        host.untrack(host.ctx, h);
        e.handle = null;
    }
    if (changed) m.changedLocked();
}

/// `old` was renamed to `new`.
pub fn renamed(m: *BreakpointManager, old: []const u8, new: []const u8) Allocator.Error!void {
    m.lock();
    var any = false;
    for (m.entries.items) |e| {
        if (e.bp.kind != .source or !std.mem.eql(u8, e.bp.kind.source.path, old)) continue;
        var kind = e.bp.kind;
        kind.source.path = new;
        try setKind(m.gpa, e, kind);
        any = true;
    }
    if (any) m.changedLocked();
    m.unlock();
    if (!any) return;
    m.resend(.{ .source = old });
    m.resend(.{ .source = new });
    m.notify(.model);
}

/// `path` was saved: re-sends its breakpoints to the live sessions.
pub fn documentSaved(m: *BreakpointManager, path: []const u8) void {
    m.resend(.{ .source = path });
}

/// `path` was edited. With `send_on_edit = .immediate` its breakpoints
/// are re-sent once edits settle.
pub fn documentEdited(m: *BreakpointManager, path: []const u8) void {
    if (m.opts.send_on_edit != .immediate) return;
    m.lock();
    defer m.unlock();
    m.last_edit = Io.Timestamp.now(m.io, .awake);
    for (m.edited.items) |p| {
        if (std.mem.eql(u8, p, path)) break;
    } else {
        const copy = m.gpa.dupe(u8, path) catch return;
        m.edited.append(m.gpa, copy) catch return m.gpa.free(copy);
    }
    if (!m.edit_timer) {
        m.edit_timer = true;
        m.work.spawnLoop(editLoop, .{m}) catch {
            m.edit_timer = false;
        };
    }
}

fn editLoop(m: *BreakpointManager) Io.Cancelable!void {
    while (true) {
        m.lock();
        const due = m.last_edit.addDuration(m.opts.edit_settle);
        const now = Io.Timestamp.now(m.io, .awake);
        if (now.nanoseconds >= due.nanoseconds) {
            const paths = m.edited;
            m.edited = .empty;
            m.edit_timer = false;
            m.unlock();
            var ps = paths;
            defer ps.deinit(m.gpa);
            for (ps.items) |p| {
                m.resend(.{ .source = p });
                m.gpa.free(p);
            }
            return;
        }
        m.unlock();
        try m.io.sleep(.fromNanoseconds(@intCast(due.nanoseconds - now.nanoseconds)), .awake);
        zg_perf.idle.noteWake("dap.breakpoints.edit_settle", .timer);
    }
}

// ---------------------------------------------------------------------
// Sync.

const Target = union(enum) {
    all,
    source: []const u8,
    function,
    data,
    instruction,
    exceptions,
};

fn targetOf(e: *const Entry) Target {
    return switch (e.bp.kind) {
        .source => |s| .{ .source = s.path },
        .function => .function,
        .data => .data,
        .instruction => .instruction,
    };
}

fn copyTarget(t: Target, buf: []u8) Target {
    return switch (t) {
        .source => |p| blk: {
            const n = @min(p.len, buf.len);
            @memcpy(buf[0..n], p[0..n]);
            break :blk .{ .source = buf[0..n] };
        },
        else => t,
    };
}

/// Counts the answers `sendAll` waits for.
const Waiter = struct {
    gpa: Allocator,
    io: Io,
    refs: std.atomic.Value(u32) = .init(1),
    pending: std.atomic.Value(u32) = .init(0),
    event: Io.Event = .unset,

    fn expect(w: *Waiter) void {
        _ = w.refs.fetchAdd(1, .acq_rel);
        _ = w.pending.fetchAdd(1, .acq_rel);
    }

    fn done(w: *Waiter) void {
        if (w.pending.fetchSub(1, .acq_rel) == 1) w.event.set(w.io);
        w.release();
    }

    fn release(w: *Waiter) void {
        if (w.refs.fetchSub(1, .acq_rel) == 1) w.gpa.destroy(w);
    }
};

const ReqKind = enum { source, function, data, instruction, exceptions };

/// A sent `set*Breakpoints` request: our breakpoints by index.
const Req = struct {
    m: *BreakpointManager,
    s: *DebugSession,
    kind: ReqKind,
    ids: []BpId,
    waiter: ?*Waiter,

    fn destroy(r: *Req) void {
        if (r.waiter) |w| w.done();
        r.m.gpa.free(r.ids);
        r.m.gpa.destroy(r);
    }
};

const msg_condition = "condition ignored: adapter does not support conditional breakpoints";
const msg_hit = "hit count ignored: adapter does not support hit conditional breakpoints";
const msg_log = "logpoint not set: adapter does not support logpoints";
const msg_mode = "mode ignored: adapter does not support it";
const msg_function = "adapter does not support function breakpoints";
const msg_data = "adapter does not support data breakpoints";
const msg_instruction = "adapter does not support instruction breakpoints";

fn supports(v: ?bool) bool {
    return v orelse false;
}

fn hasMode(caps: protocol.Capabilities, mode: []const u8) bool {
    for (caps.breakpointModes orelse return false) |bm| if (std.mem.eql(u8, bm.mode, mode)) return true;
    return false;
}

/// Sends `s` everything and waits for the answers (the sink's `sendAll`).
pub fn sendAll(m: *BreakpointManager, s: *DebugSession) void {
    m.lock();
    for (m.live.items) |x| {
        if (x == s) break;
    } else m.live.append(m.gpa, s) catch {};
    m.unlock();
    var arena: std.heap.ArenaAllocator = .init(m.gpa);
    defer arena.deinit();
    const paths = m.sourcePaths(arena.allocator()) catch &.{};

    const w = m.gpa.create(Waiter) catch return;
    w.* = .{ .gpa = m.gpa, .io = m.io };
    defer w.release();
    for (paths) |p| m.sendSource(s, p, w);
    m.sendKind(s, .function, w);
    m.sendKind(s, .data, w);
    m.sendKind(s, .instruction, w);
    m.sendExceptions(s, w);
    if (w.pending.load(.acquire) > 0)
        w.event.waitTimeout(m.io, .{ .duration = .{ .raw = m.opts.send_timeout, .clock = .awake } }) catch {};
    m.notify(.state);
}

/// Re-sends `t` to every live session.
fn resend(m: *BreakpointManager, t: Target) void {
    var buf: [16]*DebugSession = undefined;
    m.lock();
    const n = @min(buf.len, m.live.items.len);
    @memcpy(buf[0..n], m.live.items[0..n]);
    m.unlock();
    for (buf[0..n]) |s| m.resendTo(s, t);
}

fn resendTo(m: *BreakpointManager, s: *DebugSession, t: Target) void {
    switch (t) {
        .all => {
            var arena: std.heap.ArenaAllocator = .init(m.gpa);
            defer arena.deinit();
            for (m.sourcePaths(arena.allocator()) catch &.{}) |p| m.sendSource(s, p, null);
            m.sendKind(s, .function, null);
            m.sendKind(s, .data, null);
            m.sendKind(s, .instruction, null);
            m.sendExceptions(s, null);
        },
        .source => |p| m.sendSource(s, p, null),
        .function => m.sendKind(s, .function, null),
        .data => m.sendKind(s, .data, null),
        .instruction => m.sendKind(s, .instruction, null),
        .exceptions => m.sendExceptions(s, null),
    }
}

fn sourcePaths(m: *BreakpointManager, a: Allocator) Allocator.Error![]const []const u8 {
    m.lock();
    defer m.unlock();
    var out: std.ArrayList([]const u8) = .empty;
    for (m.entries.items) |e| {
        if (e.bp.kind != .source) continue;
        const p = e.bp.kind.source.path;
        for (out.items) |q| {
            if (std.mem.eql(u8, p, q)) break;
        } else try out.append(a, try a.dupe(u8, p));
    }
    return out.items;
}

const WireSourceBp = struct {
    line: u32,
    column: ?u32 = null,
    condition: ?[]const u8 = null,
    hitCondition: ?[]const u8 = null,
    logMessage: ?[]const u8 = null,
    mode: ?[]const u8 = null,
};

/// Sends `setBreakpoints` for `path` to `s`.
fn sendSource(m: *BreakpointManager, s: *DebugSession, path: []const u8, w: ?*Waiter) void {
    var arena: std.heap.ArenaAllocator = .init(m.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const caps = s.caps();
    var ids: std.ArrayList(BpId) = .empty;
    defer ids.deinit(m.gpa);
    var bps: std.ArrayList(WireSourceBp) = .empty;
    var lines: std.ArrayList(u32) = .empty;
    m.lock();
    for (m.entries.items) |e| {
        if (e.bp.kind != .source or !std.mem.eql(u8, e.bp.kind.source.path, path)) continue;
        if (e.temp_for) |t| if (t != s) continue;
        if (!e.bp.enabled) {
            e.dropState(m.gpa, s);
            continue;
        }
        const src = e.bp.kind.source;
        const ps = e.stateFor(m.gpa, s) catch continue;
        ps.st.unsupported = false;
        var msg: ?[]const u8 = null;
        if (src.log_message != null and !supports(caps.supportsLogPoints)) {
            ps.st = .{ .unsupported = true };
            ps.setMessage(m.gpa, msg_log);
            continue;
        }
        var wire: WireSourceBp = .{ .line = m.lineOf(e), .column = src.column, .condition = src.condition, .hitCondition = src.hit_condition, .logMessage = src.log_message, .mode = src.mode };
        if (wire.condition != null and !supports(caps.supportsConditionalBreakpoints)) {
            wire.condition = null;
            msg = msg_condition;
        }
        if (wire.hitCondition != null and !supports(caps.supportsHitConditionalBreakpoints)) {
            wire.hitCondition = null;
            msg = msg orelse msg_hit;
        }
        if (wire.mode) |md| if (!hasMode(caps, md)) {
            wire.mode = null;
            msg = msg orelse msg_mode;
        };
        ps.st.unsupported = msg != null;
        ps.setMessage(m.gpa, msg);
        ids.append(m.gpa, e.bp.id) catch continue;
        bps.append(a, wire) catch {
            _ = ids.pop();
            continue;
        };
        lines.append(a, wire.line) catch {};
    }
    m.unlock();
    const dirty = if (m.opts.host) |h| h.dirty(h.ctx, path) else false;
    const Args = struct {
        source: struct { name: []const u8, path: []const u8 },
        breakpoints: []const WireSourceBp,
        lines: []const u32,
        sourceModified: bool,
    };
    const args: Args = .{
        .source = .{ .name = std.fs.path.basename(path), .path = path },
        .breakpoints = bps.items,
        .lines = lines.items,
        .sourceModified = dirty,
    };
    const json = std.json.Stringify.valueAlloc(a, args, .{ .emit_null_optional_fields = false }) catch return;
    m.sendReq(s, "setBreakpoints", json, .source, ids.items, w);
}

fn sendReq(m: *BreakpointManager, s: *DebugSession, command: []const u8, json: []const u8, kind: ReqKind, ids: []const BpId, w: ?*Waiter) void {
    const r = m.gpa.create(Req) catch return;
    const owned = m.gpa.dupe(BpId, ids) catch {
        m.gpa.destroy(r);
        return;
    };
    if (w) |x| x.expect();
    r.* = .{ .m = m, .s = s, .kind = kind, .ids = owned, .waiter = w };
    if (!s.sendRequest(command, json, .{ .ctx = r, .func = onResponse })) r.destroy();
}

const WireFunctionBp = struct { name: []const u8, condition: ?[]const u8 = null, hitCondition: ?[]const u8 = null };
const WireDataBp = struct { dataId: []const u8, accessType: Access, condition: ?[]const u8 = null, hitCondition: ?[]const u8 = null };
const WireInstructionBp = struct { instructionReference: []const u8, offset: i64, condition: ?[]const u8 = null, hitCondition: ?[]const u8 = null };

/// Sends function, data or instruction breakpoints (when the adapter has
/// them; else marks them unsupported). Sent when there are some.
fn sendKind(m: *BreakpointManager, s: *DebugSession, comptime kind: ReqKind, w: ?*Waiter) void {
    const tag = switch (kind) {
        .function => .function,
        .data => .data,
        .instruction => .instruction,
        else => unreachable,
    };
    const Wire = switch (kind) {
        .function => WireFunctionBp,
        .data => WireDataBp,
        .instruction => WireInstructionBp,
        else => unreachable,
    };
    const caps = s.caps();
    const ok = switch (kind) {
        .function => supports(caps.supportsFunctionBreakpoints),
        .data => supports(caps.supportsDataBreakpoints),
        .instruction => supports(caps.supportsInstructionBreakpoints),
        else => unreachable,
    };
    const unsupported_msg = switch (kind) {
        .function => msg_function,
        .data => msg_data,
        .instruction => msg_instruction,
        else => unreachable,
    };
    var arena: std.heap.ArenaAllocator = .init(m.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var ids: std.ArrayList(BpId) = .empty;
    defer ids.deinit(m.gpa);
    var wires: std.ArrayList(Wire) = .empty;
    var any = false;
    m.lock();
    for (m.entries.items) |e| {
        if (e.bp.kind != tag) continue;
        any = true;
        if (!e.bp.enabled) {
            e.dropState(m.gpa, s);
            continue;
        }
        const ps = e.stateFor(m.gpa, s) catch continue;
        if (!ok) {
            ps.st = .{ .unsupported = true };
            ps.setMessage(m.gpa, unsupported_msg);
            continue;
        }
        var msg: ?[]const u8 = null;
        var wire: Wire = switch (kind) {
            .function => .{ .name = e.bp.kind.function.name, .condition = e.bp.kind.function.condition, .hitCondition = e.bp.kind.function.hit_condition },
            .data => .{ .dataId = e.bp.kind.data.data_id, .accessType = e.bp.kind.data.access, .condition = e.bp.kind.data.condition, .hitCondition = e.bp.kind.data.hit_condition },
            .instruction => .{ .instructionReference = e.bp.kind.instruction.reference, .offset = e.bp.kind.instruction.offset, .condition = e.bp.kind.instruction.condition, .hitCondition = e.bp.kind.instruction.hit_condition },
            else => unreachable,
        };
        if (wire.condition != null and !supports(caps.supportsConditionalBreakpoints)) {
            wire.condition = null;
            msg = msg_condition;
        }
        if (wire.hitCondition != null and !supports(caps.supportsHitConditionalBreakpoints)) {
            wire.hitCondition = null;
            msg = msg orelse msg_hit;
        }
        ps.st.unsupported = msg != null;
        ps.setMessage(m.gpa, msg);
        ids.append(m.gpa, e.bp.id) catch continue;
        wires.append(a, wire) catch {
            _ = ids.pop();
        };
    }
    m.unlock();
    if (!ok or !any) return;
    const command = switch (kind) {
        .function => "setFunctionBreakpoints",
        .data => "setDataBreakpoints",
        .instruction => "setInstructionBreakpoints",
        else => unreachable,
    };
    const json = std.json.Stringify.valueAlloc(a, .{ .breakpoints = wires.items }, .{ .emit_null_optional_fields = false }) catch return;
    m.sendReq(s, command, json, kind, ids.items, w);
}

fn onResponse(ctx: ?*anyopaque, res: DapConnection.RawResult) void {
    const r: *Req = @ptrCast(@alignCast(ctx.?));
    defer r.destroy();
    defer res.deinit();
    const m = r.m;
    if (r.kind == .exceptions) return;
    const o = switch (res) {
        .ok => |o| o,
        .failed => |o| {
            m.lock();
            for (r.ids) |id| if (m.find(id)) |e| if (e.state(r.s)) |p| {
                p.st.verified = false;
                p.setMessage(m.gpa, o.errorText());
            };
            m.unlock();
            m.notify(.state);
            return;
        },
        else => return,
    };
    const Body = struct { breakpoints: []const protocol.Breakpoint = &.{} };
    const body = o.response.body orelse return;
    const parsed = std.json.parseFromSliceLeaky(Body, o.arena.allocator(), body.bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return;
    m.lock();
    for (r.ids, 0..) |id, i| {
        if (i >= parsed.breakpoints.len) break;
        const b = parsed.breakpoints[i];
        const e = m.find(id) orelse continue;
        const p = e.stateFor(m.gpa, r.s) catch continue;
        applyWire(m.gpa, p, b);
    }
    m.unlock();
    m.notify(.state);
}

/// Copies an adapter breakpoint into `p` (keeping our own unsupported
/// message).
fn applyWire(gpa: Allocator, p: *PerSession, b: protocol.Breakpoint) void {
    p.st.verified = b.verified;
    p.st.adapter_id = b.id orelse p.st.adapter_id;
    p.st.actual_line = if (b.line) |l| (if (l > 0) @intCast(l) else null) else p.st.actual_line;
    if (!p.st.unsupported) p.setMessage(gpa, b.message);
}

// ---------------------------------------------------------------------
// The `breakpoint` event.

/// A `breakpoint` event body from `s` (JSON text).
pub fn onEvent(m: *BreakpointManager, s: *DebugSession, body: []const u8) void {
    var arena: std.heap.ArenaAllocator = .init(m.gpa);
    defer arena.deinit();
    const Body = struct { reason: []const u8, breakpoint: protocol.Breakpoint };
    const b = std.json.parseFromSliceLeaky(Body, arena.allocator(), body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return;
    const reason = b.reason;
    const bp = b.breakpoint;
    m.lock();
    var change: Change = .state;
    const existing: ?*Entry = if (bp.id) |aid| for (m.entries.items) |e| {
        if (e.state(s)) |p| if (p.st.adapter_id == aid) break e;
    } else null else null;
    if (std.mem.eql(u8, reason, "removed")) {
        if (existing) |e| {
            if (e.adopted) {
                for (m.entries.items, 0..) |x, i| if (x == e) {
                    _ = m.entries.orderedRemove(i);
                    break;
                };
                m.freeEntry(e);
                change = .model;
                m.changedLocked();
            } else e.dropState(m.gpa, s);
        }
    } else if (existing) |e| {
        if (e.state(s)) |p| applyWire(m.gpa, p, bp);
    } else if (std.mem.eql(u8, reason, "new")) adopt: {
        const src = bp.source orelse break :adopt;
        const path = src.path orelse break :adopt;
        const line = bp.line orelse break :adopt;
        if (line <= 0) break :adopt;
        const e = m.addLocked(.{ .kind = .{ .source = .{ .path = path, .line = @intCast(line) } } }) catch break :adopt;
        e.adopted = true;
        const p = e.stateFor(m.gpa, s) catch break :adopt;
        applyWire(m.gpa, p, bp);
        change = .model;
        m.changedLocked();
    }
    m.unlock();
    m.notify(change);
}

// ---------------------------------------------------------------------
// Sessions.

/// `s` ended: forgets its states, its "Run to Line" breakpoint and the
/// data breakpoints that cannot persist.
pub fn sessionEnded(m: *BreakpointManager, s: *DebugSession) void {
    m.lock();
    for (m.live.items, 0..) |x, i| if (x == s) {
        _ = m.live.swapRemove(i);
        break;
    };
    var model = false;
    var i: usize = 0;
    while (i < m.entries.items.len) {
        const e = m.entries.items[i];
        e.dropState(m.gpa, s);
        const drop = e.temp_for == s or (e.bp.kind == .data and !e.bp.kind.data.can_persist);
        if (drop) {
            _ = m.entries.orderedRemove(i);
            if (e.temp_for == null) model = true;
            m.freeEntry(e);
        } else i += 1;
    }
    if (model) m.changedLocked();
    m.unlock();
    m.notify(if (model) .model else .state);
}

/// Sets the hidden breakpoint of "Run to Line" for `s`.
pub fn setTemp(m: *BreakpointManager, s: *DebugSession, src: DebugSession.SourceRef, line: u32) bool {
    const path = src.path orelse return false;
    m.lock();
    const e = m.addLocked(.{ .kind = .{ .source = .{ .path = path, .line = line } } }) catch {
        m.unlock();
        return false;
    };
    e.temp_for = s;
    m.unlock();
    m.sendSource(s, path, null);
    return true;
}

/// Removes `s`'s "Run to Line" breakpoint.
pub fn clearTemp(m: *BreakpointManager, s: *DebugSession) void {
    var arena: std.heap.ArenaAllocator = .init(m.gpa);
    defer arena.deinit();
    var paths: std.ArrayList([]const u8) = .empty;
    m.lock();
    var i: usize = 0;
    while (i < m.entries.items.len) {
        const e = m.entries.items[i];
        if (e.temp_for == s) {
            paths.append(arena.allocator(), arena.allocator().dupe(u8, e.bp.kind.source.path) catch "") catch {};
            _ = m.entries.orderedRemove(i);
            m.freeEntry(e);
        } else i += 1;
    }
    m.unlock();
    for (paths.items) |p| m.sendSource(s, p, null);
}

/// The `BreakpointSink` sessions use.
pub fn sink(m: *BreakpointManager) DebugManager.BreakpointSink {
    return .{ .ctx = m, .sendAll = sinkSendAll, .onEvent = sinkEvent, .setTemp = sinkSetTemp, .clearTemp = sinkClearTemp, .onEnd = sinkEnd };
}

fn sinkSendAll(ctx: ?*anyopaque, s: *DebugSession) void {
    const m: *BreakpointManager = @ptrCast(@alignCast(ctx.?));
    m.sendAll(s);
}

fn sinkEvent(ctx: ?*anyopaque, s: *DebugSession, body: []const u8) void {
    const m: *BreakpointManager = @ptrCast(@alignCast(ctx.?));
    m.onEvent(s, body);
}

fn sinkSetTemp(ctx: ?*anyopaque, s: *DebugSession, src: DebugSession.SourceRef, line: u32) bool {
    const m: *BreakpointManager = @ptrCast(@alignCast(ctx.?));
    return m.setTemp(s, src, line);
}

fn sinkClearTemp(ctx: ?*anyopaque, s: *DebugSession) void {
    const m: *BreakpointManager = @ptrCast(@alignCast(ctx.?));
    m.clearTemp(s);
}

fn sinkEnd(ctx: ?*anyopaque, s: *DebugSession) void {
    const m: *BreakpointManager = @ptrCast(@alignCast(ctx.?));
    m.sessionEnded(s);
}

// ---------------------------------------------------------------------
// Exception filters.

fn findFilt(m: *BreakpointManager, adapter_type: []const u8, filter: []const u8) ?*Filt {
    for (m.filters.items) |*f| if (std.mem.eql(u8, f.adapter_type, adapter_type) and std.mem.eql(u8, f.filter, filter)) return f;
    return null;
}

fn rememberFilt(m: *BreakpointManager, adapter_type: []const u8, filter: []const u8, enabled: bool, condition: ?[]const u8) Allocator.Error!*Filt {
    if (m.findFilt(adapter_type, filter)) |f| return f;
    const t = try m.gpa.dupe(u8, adapter_type);
    errdefer m.gpa.free(t);
    const fl = try m.gpa.dupe(u8, filter);
    errdefer m.gpa.free(fl);
    const c = if (condition) |x| try m.gpa.dupe(u8, x) else null;
    try m.filters.append(m.gpa, .{ .adapter_type = t, .filter = fl, .enabled = enabled, .condition = c });
    return &m.filters.items[m.filters.items.len - 1];
}

/// The exception filters `s`'s adapter offers, with the choices for its
/// type (defaults the first time), strings in `a`.
pub fn exceptionFilters(m: *BreakpointManager, a: Allocator, s: *DebugSession) Allocator.Error![]ExceptionFilterState {
    const caps = s.caps();
    const offered = caps.exceptionBreakpointFilters orelse return &.{};
    var out: std.ArrayList(ExceptionFilterState) = try .initCapacity(a, offered.len);
    m.lock();
    defer m.unlock();
    var added = false;
    for (offered) |f| {
        const known = m.findFilt(s.cfg.type, f.filter) != null;
        const st = try m.rememberFilt(s.cfg.type, f.filter, f.default orelse false, null);
        if (!known) added = true;
        out.appendAssumeCapacity(.{
            .filter = try a.dupe(u8, f.filter),
            .label = try a.dupe(u8, f.label),
            .description = try dupeOpt(a, f.description),
            .enabled = st.enabled,
            .condition = try dupeOpt(a, st.condition),
            .supports_condition = f.supportsCondition orelse false,
            .condition_description = try dupeOpt(a, f.conditionDescription),
        });
    }
    if (added) m.changedLocked();
    return out.items;
}

/// Turns exception filter `filter` of `adapter_type` on or off (and sets
/// its condition), then re-sends the filters to the sessions of that type.
pub fn setExceptionFilter(m: *BreakpointManager, adapter_type: []const u8, filter: []const u8, enabled: bool, condition: ?[]const u8) Allocator.Error!void {
    m.lock();
    {
        errdefer m.unlock();
        const f = try m.rememberFilt(adapter_type, filter, enabled, condition);
        f.enabled = enabled;
        const c = if (condition) |x| try m.gpa.dupe(u8, x) else null;
        if (f.condition) |old| m.gpa.free(old);
        f.condition = c;
        m.changedLocked();
    }
    var buf: [16]*DebugSession = undefined;
    var n: usize = 0;
    for (m.live.items) |s| if (n < buf.len and std.mem.eql(u8, s.cfg.type, adapter_type)) {
        buf[n] = s;
        n += 1;
    };
    m.unlock();
    for (buf[0..n]) |s| m.sendExceptions(s, null);
    m.notify(.exception_filters);
}

/// Sends `setExceptionBreakpoints` when the adapter offers filters:
/// enabled filters in `filters`, those with a condition in
/// `filterOptions` when `supportsExceptionFilterOptions`.
fn sendExceptions(m: *BreakpointManager, s: *DebugSession, w: ?*Waiter) void {
    const caps = s.caps();
    const offered = caps.exceptionBreakpointFilters orelse return;
    if (offered.len == 0) return;
    var arena: std.heap.ArenaAllocator = .init(m.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const states = m.exceptionFilters(a, s) catch return;
    const options = supports(caps.supportsExceptionFilterOptions);
    const Opt = struct { filterId: []const u8, condition: []const u8 };
    var filters: std.ArrayList([]const u8) = .empty;
    var opts: std.ArrayList(Opt) = .empty;
    for (states) |f| {
        if (!f.enabled) continue;
        if (options and f.supports_condition and f.condition != null and f.condition.?.len > 0) {
            opts.append(a, .{ .filterId = f.filter, .condition = f.condition.? }) catch return;
        } else filters.append(a, f.filter) catch return;
    }
    const json = if (options)
        std.json.Stringify.valueAlloc(a, .{ .filters = filters.items, .filterOptions = opts.items }, .{}) catch return
    else
        std.json.Stringify.valueAlloc(a, .{ .filters = filters.items }, .{}) catch return;
    m.sendReq(s, "setExceptionBreakpoints", json, .exceptions, &.{}, w);
}

// ---------------------------------------------------------------------
// Data breakpoints.

/// Asks `s` whether variable `name` of container `var_ref` can get a data
/// breakpoint ("Break when value changes"); `cb` runs on the dispatcher.
pub fn dataBreakpointInfo(m: *BreakpointManager, s: *DebugSession, var_ref: i64, name: []const u8, cb: InfoCb) void {
    if (!supports(s.caps().supportsDataBreakpoints)) return cb.func(cb.ctx, null);
    var arena: std.heap.ArenaAllocator = .init(m.gpa);
    defer arena.deinit();
    const json = std.json.Stringify.valueAlloc(arena.allocator(), .{ .variablesReference = var_ref, .name = name }, .{}) catch return cb.func(cb.ctx, null);
    const c = m.gpa.create(InfoReq) catch return cb.func(cb.ctx, null);
    c.* = .{ .gpa = m.gpa, .cb = cb };
    if (!s.sendRequest("dataBreakpointInfo", json, .{ .ctx = c, .func = InfoReq.done })) {
        m.gpa.destroy(c);
        cb.func(cb.ctx, null);
    }
}

const InfoReq = struct {
    gpa: Allocator,
    cb: InfoCb,

    fn done(ctx: ?*anyopaque, res: DapConnection.RawResult) void {
        const c: *InfoReq = @ptrCast(@alignCast(ctx.?));
        defer c.gpa.destroy(c);
        defer res.deinit();
        const o = switch (res) {
            .ok => |o| o,
            else => return c.cb.func(c.cb.ctx, null),
        };
        const Body = struct {
            dataId: ?[]const u8 = null,
            description: []const u8 = "",
            accessTypes: []const []const u8 = &.{},
            canPersist: bool = false,
        };
        const a = o.arena.allocator();
        const body = o.response.body orelse return c.cb.func(c.cb.ctx, null);
        const b = std.json.parseFromSliceLeaky(Body, a, body.bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return c.cb.func(c.cb.ctx, null);
        var access: std.ArrayList(Access) = .empty;
        for (b.accessTypes) |t| if (std.meta.stringToEnum(Access, t)) |x| access.append(a, x) catch {};
        c.cb.func(c.cb.ctx, .{ .data_id = b.dataId, .description = b.description, .access_types = access.items, .can_persist = b.canPersist });
    }
};

// ---------------------------------------------------------------------
// Persistence.

/// Adds the breakpoints and filter choices of a breakpoints.zon text
/// (paths made absolute against `persist.workspace_root`). Tracking
/// starts when documents open.
pub fn load(m: *BreakpointManager, bytes: []const u8) persist.DecodeError!void {
    var arena: std.heap.ArenaAllocator = .init(m.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try persist.decode(a, bytes);
    const root = if (m.opts.persist) |p| p.workspace_root else "";
    m.lock();
    defer m.unlock();
    try m.entries.ensureUnusedCapacity(m.gpa, f.breakpoints.len);
    const host = m.opts.host;
    m.opts.host = null; // lazily: anchors are made when documents open
    defer m.opts.host = host;
    for (f.breakpoints) |sb| {
        const kind: Kind = switch (sb.kind) {
            .source => .{ .source = .{
                .path = try persist.absolutize(a, root, sb.path orelse continue, builtin.os.tag),
                .line = sb.line orelse continue,
                .column = sb.column,
                .condition = sb.condition,
                .hit_condition = sb.hit_condition,
                .log_message = sb.log_message,
                .mode = sb.mode,
            } },
            .function => .{ .function = .{ .name = sb.name orelse continue, .condition = sb.condition, .hit_condition = sb.hit_condition } },
            .data => .{ .data = .{ .data_id = sb.data_id orelse continue, .description = sb.description orelse "", .access = sb.access orelse .write, .condition = sb.condition, .hit_condition = sb.hit_condition } },
            .instruction => .{ .instruction = .{ .reference = sb.reference orelse continue, .offset = sb.offset orelse 0, .condition = sb.condition, .hit_condition = sb.hit_condition } },
        };
        _ = try m.addLocked(.{ .enabled = sb.enabled, .kind = kind });
    }
    for (f.exception_filters) |sf| {
        const x = try m.rememberFilt(sf.adapter_type, sf.filter, sf.enabled, sf.condition);
        x.enabled = sf.enabled;
    }
}

/// The breakpoints.zon text of the current state.
pub fn encode(m: *BreakpointManager, gpa: Allocator) Allocator.Error![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const root = if (m.opts.persist) |p| p.workspace_root else "";
    m.lock();
    var saved: std.ArrayList(persist.Saved) = try .initCapacity(a, m.entries.items.len);
    for (m.entries.items) |e| {
        if (e.temp_for != null or e.adopted) continue;
        saved.appendAssumeCapacity(switch (e.bp.kind) {
            .source => |s| .{ .kind = .source, .enabled = e.bp.enabled, .path = try persist.relativize(a, root, s.path), .line = m.lineOf(e), .column = s.column, .condition = s.condition, .hit_condition = s.hit_condition, .log_message = s.log_message, .mode = s.mode },
            .function => |f| .{ .kind = .function, .enabled = e.bp.enabled, .name = f.name, .condition = f.condition, .hit_condition = f.hit_condition },
            .data => |d| if (!d.can_persist) continue else .{ .kind = .data, .enabled = e.bp.enabled, .data_id = d.data_id, .description = d.description, .access = d.access, .condition = d.condition, .hit_condition = d.hit_condition },
            .instruction => |i| .{ .kind = .instruction, .enabled = e.bp.enabled, .reference = i.reference, .offset = i.offset, .condition = i.condition, .hit_condition = i.hit_condition },
        });
    }
    var filts: std.ArrayList(persist.SavedFilter) = try .initCapacity(a, m.filters.items.len);
    for (m.filters.items) |f| filts.appendAssumeCapacity(.{ .adapter_type = f.adapter_type, .filter = f.filter, .enabled = f.enabled, .condition = f.condition });
    // Encode before unlocking: the strings are the entries'.
    defer m.unlock();
    const text = try persist.encode(a, .{ .breakpoints = saved.items, .exception_filters = filts.items });
    return gpa.dupe(u8, text);
}

/// Marks the state changed and schedules a save. Under the lock.
fn changedLocked(m: *BreakpointManager) void {
    const p = m.opts.persist orelse return;
    m.dirty = true;
    m.last_change = Io.Timestamp.now(m.io, .awake);
    if (m.save_timer) return;
    m.save_timer = true;
    m.work.spawnLoop(saveLoop, .{ m, p.debounce }) catch {
        m.save_timer = false;
    };
}

fn saveLoop(m: *BreakpointManager, debounce: Io.Duration) Io.Cancelable!void {
    while (true) {
        m.lock();
        const due = m.last_change.addDuration(debounce);
        const now = Io.Timestamp.now(m.io, .awake);
        if (now.nanoseconds >= due.nanoseconds) {
            m.save_timer = false;
            m.unlock();
            m.saveNow() catch |e| log.warn("cannot save breakpoints: {t}", .{e});
            return;
        }
        m.unlock();
        try m.io.sleep(.fromNanoseconds(@intCast(due.nanoseconds - now.nanoseconds)), .awake);
        zg_perf.idle.noteWake("dap.breakpoints.save", .timer);
    }
}

/// Writes breakpoints.zon now (atomically).
pub fn saveNow(m: *BreakpointManager) !void {
    const p = m.opts.persist orelse return;
    m.lock();
    m.dirty = false;
    m.unlock();
    const text = try m.encode(m.gpa);
    defer m.gpa.free(text);
    try persist.writeAtomic(m.io, p.dir, p.path, text);
    m.lock();
    m.saves += 1;
    m.unlock();
}
