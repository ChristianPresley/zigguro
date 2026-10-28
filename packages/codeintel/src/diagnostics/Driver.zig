//! Diagnostics from the language servers into the `DiagnosticStore`
//! (E07.F02.S02.T01): pushed `textDocument/publishDiagnostics` and pulled
//! `textDocument/diagnostic` reports, one store owner per server.
//!
//! Pushes are parsed and converted on the server's reader thread and
//! applied by `tick` on the UI thread. Positions refer to the text the
//! server was sent, so the driver keeps the last few versions sent to each
//! server per document (as editor snapshots): a push for an older version
//! is mapped against that text, and the decorations carry that document
//! version so the decoration store maps the ranges forward (dropping the
//! ones whose text was edited since). A push for a version no longer kept
//! is dropped; the server sends a newer one.
//!
//! Pulls ask each open document's pull server again after edits (through
//! the shared poller), with the previous result id, and on
//! `workspace/diagnostic/refresh`. `relatedDocuments` reports are applied
//! to their documents. Servers that offer workspace pulls are also asked
//! for the whole workspace (`WorkspacePull`), which reports closed files
//! too. A server that stops loses its diagnostics.

const Driver = @This();
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zg_core = @import("zg_core");
const zg_lsp = @import("zg_lsp");
const zg_editor = @import("zg_editor");
const Manager = @import("../Manager.zig");
const poller = @import("../features/poller.zig");
const position = @import("../features/position.zig");
const Store = @import("Store.zig");
const convert = @import("convert.zig");
const SettleDetector = @import("settle.zig");
const WorkspacePull = @import("workspace_pull.zig");

const Client = zg_lsp.client.Client;
const protocol = zg_lsp.protocol;
const DocHandle = zg_editor.model.api.registry.DocHandle;
const Snapshot = zg_editor.model.snapshot.Snapshot;
const M_pull = .@"textDocument/diagnostic";
const Poll = poller.Poller(M_pull, .diagnostic_pull);

const log = std.log.scoped(.codeintel);

/// Versions remembered per server and document.
pub const history = 4;

pub const Options = struct {
    pull: Poll.Options = .{},
    settle: SettleDetector.Options = .{},
    /// Its waker defaults to `pull`'s.
    workspace: WorkspacePull.Options = .{},
};

const Incoming = struct {
    server: u32,
    key: []u8,
    version: ?i32,
    set: *Store.Set,
};

const TrackKey = struct { server: u32, h: DocHandle };

/// One document as one server knows it.
const Track = struct {
    /// Newest first.
    sent: [history]?struct { lsp: i32, snap: Snapshot } = @splat(null),
    /// The version the server last reported on (a push's, the newest
    /// sent when a push has none, or a pull's).
    reported: ?i32 = null,
    sent_ns: i96 = 0,
    report_ns: i96 = 0,
    result_id: ?[]u8 = null,

    fn deinit(t: *Track, gpa: Allocator) void {
        for (&t.sent) |*e| if (e.*) |*x| x.snap.release();
        if (t.result_id) |r| gpa.free(r);
    }
};

gpa: Allocator,
io: Io,
mgr: *Manager,
store: *Store,
settle: SettleDetector,
poll: Poll,
ws: WorkspacePull,
waker: zg_core.runtime.Waker,
inbox_mutex: Io.Mutex = .init,
inbox: std.ArrayList(Incoming) = .empty,
taken: std.ArrayList(Incoming) = .empty,
tracks: std.AutoArrayHashMapUnmanaged(TrackKey, Track) = .empty,
/// Store keys of open documents.
keys: std.AutoArrayHashMapUnmanaged(DocHandle, []u8) = .empty,
/// Build progress per server (reader threads write it).
builds_mutex: Io.Mutex = .init,
builds: std.AutoHashMapUnmanaged(u32, i96) = .empty,
/// Servers whose sets are in the store.
owners: std.AutoArrayHashMapUnmanaged(u32, void) = .empty,
/// Scratch for the settle tables.
rows: std.ArrayList(SettleDetector.Row) = .empty,
states: std.ArrayList(SettleDetector.ServerState) = .empty,
pulls: std.ArrayList([]u8) = .empty,

/// `d` must not move. Call before the first `Manager.openDoc`.
pub fn init(d: *Driver, mgr: *Manager, store: *Store, opts: Options) Allocator.Error!void {
    d.* = .{
        .gpa = mgr.gpa,
        .io = mgr.rt.io,
        .mgr = mgr,
        .store = store,
        .settle = .init(mgr.gpa, mgr.rt.io, store, so: {
            var o = opts.settle;
            if (o.waker.ctx == null) o.waker = opts.pull.waker;
            break :so o;
        }),
        .poll = .init(mgr, .{ .ctx = d, .apply = applyPull, .clear = clearPull, .prepare = preparePull }, opts.pull),
        .ws = .init(mgr, ws: {
            var o = opts.workspace;
            if (o.waker.ctx == null) o.waker = opts.pull.waker;
            break :ws o;
        }),
        .waker = opts.pull.waker,
    };
    mgr.setDiagnosticsHooks(.{ .ctx = d, .publish = onPublish, .sent = onSent });
    try mgr.onRefresh(.{ .ctx = d, .func = onRefresh });
    try mgr.progress.subscribe(.{ .ctx = d, .func = onProgress });
}

/// Call after `Manager.deinit` (no pushes or answers arrive after it).
pub fn deinit(d: *Driver) void {
    d.poll.deinit();
    d.ws.deinit();
    for (d.takeInbox()) |x| freeIncoming(d.gpa, x);
    d.taken.deinit(d.gpa);
    d.inbox.deinit(d.gpa);
    for (d.tracks.values()) |*t| t.deinit(d.gpa);
    d.tracks.deinit(d.gpa);
    d.settle.deinit();
    for (d.keys.values()) |k| d.gpa.free(k);
    d.keys.deinit(d.gpa);
    d.builds.deinit(d.gpa);
    d.owners.deinit(d.gpa);
    d.rows.deinit(d.gpa);
    d.states.deinit(d.gpa);
    for (d.pulls.items) |k| d.gpa.free(k);
    d.pulls.deinit(d.gpa);
}

/// The detector behind `zg_ai`'s `FileTools.diagnostics`.
pub fn settleDetector(d: *Driver) *SettleDetector {
    return &d.settle;
}

/// The store key of open document `h`.
pub fn keyOfDoc(d: *Driver, h: DocHandle) ?[]const u8 {
    if (d.keys.get(h)) |k| return k;
    const uri = d.mgr.docs.uri(h) orelse return null;
    const k = d.store.keyOf(d.gpa, uri) catch return null;
    d.keys.put(d.gpa, h, k) catch {
        d.gpa.free(k);
        return null;
    };
    return k;
}

/// Applies pushes and pull results, asks for due pulls and publishes the
/// changes; call once per frame after `Manager.tick`. True when the store
/// changed.
pub fn tick(d: *Driver) bool {
    for (d.takeInbox()) |x| d.applyPush(x) catch |e| log.debug("diagnostics: {t}", .{e});
    d.taken.clearRetainingCapacity();
    d.syncDocs();
    d.urgePulls();
    _ = d.poll.tick();
    d.ws.tick(d.nowNs(), .{ .ctx = d, .full = onWorkspaceFull });
    d.dropStopped();
    const before = d.store.current.generation;
    d.store.commit();
    d.updateSettle();
    return d.store.current.generation != before;
}

pub fn nextDue(d: *const Driver) ?i96 {
    const a = d.poll.nextDue();
    const b = d.ws.nextDue();
    if (a == null) return b;
    if (b == null) return a;
    return @min(a.?, b.?);
}

/// The workspace pulls (tests).
pub fn workspacePull(d: *Driver) *WorkspacePull {
    return &d.ws;
}

// ------------------------------------------------------------------ push

/// Reader thread: parse and convert, then queue for the UI.
fn onPublish(ctx: *anyopaque, server: u32, params: []const u8) void {
    const d: *Driver = @ptrCast(@alignCast(ctx));
    d.queuePush(server, params) catch |e| log.debug("publishDiagnostics: {t}", .{e});
}

fn queuePush(d: *Driver, server: u32, params: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(d.gpa);
    defer arena.deinit();
    const p = try convert.parsePush(arena.allocator(), params);
    const set = try Store.Set.create(d.gpa, .{ .server = server });
    errdefer set.destroy();
    try convert.fromLsp(set, p.diagnostics);
    const key = try d.store.keyOf(d.gpa, p.uri);
    errdefer d.gpa.free(key);
    {
        d.inbox_mutex.lockUncancelable(d.io);
        defer d.inbox_mutex.unlock(d.io);
        try d.inbox.append(d.gpa, .{ .server = server, .key = key, .version = p.version, .set = set });
    }
    d.waker.wake();
}

fn applyPush(d: *Driver, x: Incoming) !void {
    defer d.gpa.free(x.key);
    var set: ?*Store.Set = x.set;
    errdefer if (set) |s| s.destroy();
    const servers = d.mgr.serverList();
    if (x.server >= servers.len or servers[x.server].status != .running) return set.?.destroy();
    const s = servers[x.server];
    const now = d.nowNs();
    if (d.docOf(s, x.key)) |h| if (d.tracks.getPtr(.{ .server = x.server, .h = h })) |t| {
        const sent = pick(t, x.version) orelse {
            // Older than anything kept: wait for the next push.
            set.?.destroy();
            return;
        };
        try convert.mapBytes(d.gpa, set.?, &sent.snap.tree, position.encodingOf(s.client.?.encoding()), sent.snap.version);
        t.reported = x.version orelse if (t.sent[0]) |n| n.lsp else null;
        t.report_ns = now;
    };
    try d.owners.put(d.gpa, x.server, {});
    const owned = set;
    set = null;
    try d.store.replace(x.key, .{ .server = x.server }, owned);
}

/// The sent version `version` (null: the newest).
fn pick(t: *Track, version: ?i32) ?*@typeInfo(@TypeOf(t.sent[0])).optional.child {
    for (&t.sent) |*e| if (e.*) |*x| if (version == null or x.lsp == version.?) return x;
    return null;
}

/// The open document of `s` with store key `key`.
fn docOf(d: *Driver, s: *Manager.Server, key: []const u8) ?DocHandle {
    for (s.docs.items) |h| if (d.keyOfDoc(h)) |k| if (std.mem.eql(u8, k, key)) return h;
    return null;
}

/// UI thread, in `Manager.tick`: `server` was sent version `version`.
fn onSent(ctx: *anyopaque, s: *Manager.Server, h: DocHandle, version: i32) void {
    const d: *Driver = @ptrCast(@alignCast(ctx));
    const doc = d.mgr.docs.get(h) orelse return;
    const gop = d.tracks.getOrPut(d.gpa, .{ .server = s.id, .h = h }) catch return;
    if (!gop.found_existing) gop.value_ptr.* = .{};
    const t = gop.value_ptr;
    if (t.sent[history - 1]) |*old| old.snap.release();
    std.mem.copyBackwards(@TypeOf(t.sent[0]), t.sent[1..], t.sent[0 .. history - 1]);
    t.sent[0] = .{ .lsp = version, .snap = doc.snapshot() };
    t.sent_ns = d.nowNs();
}

// ------------------------------------------------------------------ pull

fn onRefresh(ctx: *anyopaque, _: *Manager.Server, f: Manager.RefreshFeature) void {
    const d: *Driver = @ptrCast(@alignCast(ctx));
    if (f != .diagnostic) return;
    d.poll.refresh();
    d.ws.refresh();
}

fn onWorkspaceFull(ctx: *anyopaque, s: *Manager.Server, uri: []const u8, items: []const protocol.Diagnostic) void {
    const d: *Driver = @ptrCast(@alignCast(ctx));
    const c = s.client orelse return;
    d.applyRelated(s, uri, position.encodingOf(c.encoding()), items) catch |e| log.debug("workspace diagnostics: {t}", .{e});
}

fn serverOf(d: *Driver, c: *Client) ?*Manager.Server {
    for (d.mgr.serverList()) |s| if (s.client == c) return s;
    return null;
}

fn preparePull(ctx: *anyopaque, h: DocHandle, c: *Client, params: *protocol.DocumentDiagnosticParams) void {
    const d: *Driver = @ptrCast(@alignCast(ctx));
    const s = d.serverOf(c) orelse return;
    const t = d.tracks.getPtr(.{ .server = s.id, .h = h }) orelse return;
    params.previousResultId = t.result_id;
}

fn clearPull(_: *anyopaque, _: DocHandle) void {
    // An error keeps what is shown; a stopped server is cleared by
    // `dropStopped`.
}

fn applyPull(ctx: *anyopaque, h: DocHandle, c: *Client, value: protocol.DocumentDiagnosticReport) bool {
    const d: *Driver = @ptrCast(@alignCast(ctx));
    d.applyReport(h, c, value) catch |e| log.debug("diagnostic pull: {t}", .{e});
    return false;
}

fn applyReport(d: *Driver, h: DocHandle, c: *Client, value: protocol.DocumentDiagnosticReport) !void {
    const s = d.serverOf(c) orelse return;
    const key = d.keyOfDoc(h) orelse return;
    const enc = position.encodingOf(c.encoding());
    var result_id: ?[]const u8 = null;
    switch (value) {
        .related_full_document_diagnostic_report => |r| {
            try d.applyFull(s, key, h, enc, r.items);
            result_id = r.resultId;
            if (r.relatedDocuments) |rel| for (rel.map.keys(), rel.map.values()) |uri, v| switch (v) {
                .full_document_diagnostic_report => |f| try d.applyRelated(s, uri, enc, f.items),
                .unchanged_document_diagnostic_report => {},
            };
        },
        .related_unchanged_document_diagnostic_report => |r| {
            result_id = r.resultId;
            if (r.relatedDocuments) |rel| for (rel.map.keys(), rel.map.values()) |uri, v| switch (v) {
                .full_document_diagnostic_report => |f| try d.applyRelated(s, uri, enc, f.items),
                .unchanged_document_diagnostic_report => {},
            };
        },
    }
    const t = d.tracks.getPtr(.{ .server = s.id, .h = h }) orelse return;
    // Pulls answer for the current text (older answers are asked again).
    t.reported = if (t.sent[0]) |n| n.lsp else null;
    t.report_ns = d.nowNs();
    if (t.result_id) |old| d.gpa.free(old);
    t.result_id = if (result_id) |r| try d.gpa.dupe(u8, r) else null;
}

/// A full report for `key` (open document `h`, if any) at its current
/// text.
fn applyFull(d: *Driver, s: *Manager.Server, key: []const u8, h: ?DocHandle, enc: position.Encoding, items: []const protocol.Diagnostic) !void {
    const set = try Store.Set.create(d.gpa, .{ .server = s.id });
    errdefer set.destroy();
    try convert.fromLsp(set, items);
    if (h) |hd| if (d.mgr.docs.get(hd)) |doc| try convert.mapBytes(d.gpa, set, &doc.tree, enc, doc.version);
    try d.owners.put(d.gpa, s.id, {});
    try d.store.replace(key, .{ .server = s.id }, set);
}

fn applyRelated(d: *Driver, s: *Manager.Server, uri: []const u8, enc: position.Encoding, items: []const protocol.Diagnostic) !void {
    const key = try d.store.keyOf(d.gpa, uri);
    defer d.gpa.free(key);
    try d.applyFull(s, key, d.openDocOfKey(key), enc, items);
}

fn openDocOfKey(d: *Driver, key: []const u8) ?DocHandle {
    var it = d.mgr.open.keyIterator();
    while (it.next()) |h| if (d.keyOfDoc(h.*)) |k| if (std.mem.eql(u8, k, key)) return h.*;
    return null;
}

// ------------------------------------------------------------ upkeep

/// Pulls follow the manager's open documents; closed documents lose
/// their tracks and keys.
fn syncDocs(d: *Driver) void {
    var it = d.mgr.open.keyIterator();
    while (it.next()) |h| if (!d.poll.isTracked(h.*)) {
        d.poll.track(h.*) catch {};
        d.mapOpened(h.*);
    };
    var i: usize = d.poll.states.count();
    while (i > 0) {
        i -= 1;
        const h = d.poll.states.keys()[i];
        if (!d.mgr.open.contains(h)) d.poll.untrack(h);
    }
    i = d.tracks.count();
    while (i > 0) {
        i -= 1;
        const k = d.tracks.keys()[i];
        const servers = d.mgr.serverList();
        const gone = !d.mgr.open.contains(k.h) or k.server >= servers.len or servers[k.server].status != .running;
        if (!gone) continue;
        d.tracks.values()[i].deinit(d.gpa);
        d.tracks.swapRemoveAt(i);
    }
}

/// A document just opened: sets reported while it was closed (workspace
/// pulls, related documents) have LSP positions only; give them byte
/// ranges at its text, which is what the server saw on disk.
fn mapOpened(d: *Driver, h: DocHandle) void {
    const key = d.keyOfDoc(h) orelse return;
    const b = d.store.current.bucket(key) orelse return;
    const doc = d.mgr.docs.get(h) orelse return;
    var mapped: std.ArrayList(*Store.Set) = .empty;
    defer mapped.deinit(d.gpa);
    for (b.sets) |old| {
        if (old.version != null or old.owner != .server) continue;
        const servers = d.mgr.serverList();
        const id = old.owner.server;
        if (id >= servers.len) continue;
        const c = servers[id].client orelse continue;
        const set = convert.copySet(d.gpa, old) catch return;
        convert.mapBytes(d.gpa, set, &doc.tree, position.encodingOf(c.encoding()), doc.version) catch {
            set.destroy();
            continue;
        };
        mapped.append(d.gpa, set) catch {
            set.destroy();
            continue;
        };
    }
    // After the walk: replacing changes the bucket.
    for (mapped.items) |set| d.store.replace(key, set.owner, set) catch {};
}

/// Clears the sets of servers that stopped or crashed.
fn dropStopped(d: *Driver) void {
    const servers = d.mgr.serverList();
    var i: usize = d.owners.count();
    while (i > 0) {
        i -= 1;
        const id = d.owners.keys()[i];
        if (id < servers.len and servers[id].status == .running) continue;
        d.store.clearOwner(.{ .server = id }) catch continue;
        d.owners.swapRemoveAt(i);
    }
}

/// Publishes per-document activity to the settle detector, then frees
/// the keys of closed documents (the detector borrowed them until now).
fn updateSettle(d: *Driver) void {
    d.rows.clearRetainingCapacity();
    d.states.clearRetainingCapacity();
    for (d.tracks.keys(), d.tracks.values()) |k, t| {
        const key = d.keyOfDoc(k.h) orelse continue;
        const newest = t.sent[0] orelse continue;
        const doc = d.mgr.docs.get(k.h) orelse continue;
        d.rows.append(d.gpa, .{
            .key = key,
            .server = k.server,
            .sent = newest.lsp,
            .sent_ns = t.sent_ns,
            .reported = t.reported,
            .report_ns = t.report_ns,
            .dirty = doc.version != newest.snap.version,
        }) catch return;
    }
    {
        d.builds_mutex.lockUncancelable(d.io);
        defer d.builds_mutex.unlock(d.io);
        for (d.mgr.serverList()) |s| {
            var st: SettleDetector.ServerState = .{
                .id = s.id,
                .status = switch (s.status) {
                    .starting => .starting,
                    .running => .running,
                    .crashed => .crashed,
                    else => .down,
                },
                .progress = d.mgr.progress.activeCount(s.id),
            };
            if (d.builds.get(s.id)) |end| {
                st.builds = true;
                st.build_end_ns = end;
            }
            st.setName(s.def.id);
            d.states.append(d.gpa, st) catch return;
        }
    }
    d.settle.set(d.rows.items, d.states.items) catch return;
    var i: usize = d.keys.count();
    while (i > 0) {
        i -= 1;
        if (d.mgr.open.contains(d.keys.keys()[i])) continue;
        d.gpa.free(d.keys.values()[i]);
        d.keys.swapRemoveAt(i);
    }
}

/// Pulls the agent waits on go out now, not after the debounce.
fn urgePulls(d: *Driver) void {
    d.settle.takePulls(&d.pulls) catch {};
    defer {
        for (d.pulls.items) |k| d.gpa.free(k);
        d.pulls.clearRetainingCapacity();
    }
    for (d.pulls.items) |key| {
        var it = d.mgr.open.keyIterator();
        while (it.next()) |h| if (d.keyOfDoc(h.*)) |k| if (std.mem.eql(u8, k, key)) d.poll.urge(h.*);
    }
}

/// Reader threads: remembers when a server's build progress (ZLS
/// build-on-save) ends; such a server's diagnostics wait for it.
fn onProgress(ctx: ?*anyopaque, e: zg_lsp.client.progress.ProgressEvent) void {
    const d: *Driver = @ptrCast(@alignCast(ctx.?));
    const title = e.title orelse return;
    if (std.ascii.indexOfIgnoreCase(title, "build") == null) return;
    d.builds_mutex.lockUncancelable(d.io);
    defer d.builds_mutex.unlock(d.io);
    const gop = d.builds.getOrPut(d.gpa, e.server) catch return;
    if (!gop.found_existing) gop.value_ptr.* = 0;
    if (e.kind == .end) gop.value_ptr.* = d.nowNs();
}

fn nowNs(d: *const Driver) i96 {
    return Io.Clock.Timestamp.now(d.io, .awake).raw.nanoseconds;
}

fn takeInbox(d: *Driver) []const Incoming {
    d.inbox_mutex.lockUncancelable(d.io);
    defer d.inbox_mutex.unlock(d.io);
    std.mem.swap(std.ArrayList(Incoming), &d.inbox, &d.taken);
    return d.taken.items;
}

fn freeIncoming(gpa: Allocator, x: Incoming) void {
    x.set.destroy();
    gpa.free(x.key);
}
