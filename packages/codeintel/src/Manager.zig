//! The language server manager (E07.F01.S03.T01): starts servers lazily
//! when the first matching document opens, one per (definition, root),
//! keeps each server's documents in sync through its own `LspSync`, routes
//! feature requests to the right clients and notices crashes.
//!
//! Threads: every public function runs on the UI thread. Executable
//! lookup, root detection and server start-up run on workers; they report
//! back through an inbox that `tick` drains (call it once per frame; the
//! waker asks for one). Spawning and freeing servers stays on workers too
//! because `ServerProcess` blocks.
//!
//! Restarting crashed servers (backoff, re-sync) is `restart.zig`'s job and
//! comes later; a crashed server keeps its documents so a restart can
//! track them again.

const Manager = @This();
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zg_core = @import("zg_core");
const zg_lsp = @import("zg_lsp");
const zg_editor = @import("zg_editor");
const Registry = @import("registry/Registry.zig");
const routing = @import("registry/routing.zig");
const sink_mod = @import("sync/sink.zig");

const Client = zg_lsp.client.Client;
const ServerProcess = zg_lsp.client.ServerProcess;
const DocMatch = zg_lsp.client.doc_selector.DocMatch;
const api = zg_editor.model.api;
const DocumentRegistry = api.registry.DocumentRegistry;
const DocHandle = api.registry.DocHandle;
const LspSync = api.lsp_sync.LspSync;
const ServerDef = Registry.ServerDef;
const Feature = Registry.Feature;

const log = std.log.scoped(.codeintel);

pub const Options = struct {
    /// Workspace folder paths, absolute. Roots never go above the folder
    /// that holds the document.
    workspace_folders: []const []const u8 = &.{},
    /// The environment for PATH lookup and the servers (null: the
    /// manager sees an empty one and children inherit ours).
    env: ?*const std.process.Environ.Map = null,
    /// The E16 spawn policy applied to every server.
    policy: ?*const ServerProcess.SpawnPolicy = null,
    /// Asks the UI thread for a `tick`.
    waker: zg_core.runtime.Waker = .noop,
    init_timeout: Io.Duration = .fromSeconds(30),
    client_version: []const u8 = "0.0.0",
};

pub const Status = enum {
    starting,
    running,
    /// The executable was not found; `def.install_hint` says how to get it.
    missing,
    /// Spawning or `initialize` failed; see `Server.err`.
    failed,
    crashed,
};

/// One server instance. Owned by the manager; pointers stay valid until
/// `deinit`.
pub const Server = struct {
    mgr: *Manager,
    def: *const ServerDef,
    root: []u8,
    /// The resolved executable (empty when missing).
    exe: []u8,
    status: Status,
    err: ?anyerror = null,
    /// Set by the start task; the UI reads them after `ready`.
    proc: ?*ServerProcess = null,
    client: ?*Client = null,
    /// Valid while running.
    sink: sink_mod.Sink = undefined,
    sync: ?LspSync = null,
    /// Documents attached to this server, tracked while it runs.
    docs: std.ArrayList(DocHandle) = .empty,
    /// Start-up strings (argv, URIs, initialization options).
    arena: std.heap.ArenaAllocator,

    fn hasDoc(s: *const Server, h: DocHandle) bool {
        return indexOfDoc(s.docs.items, h) != null;
    }
};

const OpenDoc = struct { lang: []u8 };

/// Worker -> UI messages.
const Msg = union(enum) {
    attach: struct { h: DocHandle, def: *const ServerDef, root: []u8, exe: ?[]u8 },
    ready: *Server,
    failed: struct { server: *Server, err: anyerror },
    crashed: *Server,
};

gpa: Allocator,
rt: *zg_core.Runtime,
reg: *Registry,
docs: *DocumentRegistry,
opts: Options,
empty_env: std.process.Environ.Map,
sub: zg_core.runtime.Subsystem,
/// Guards `reg`'s executable cache (workers resolve in parallel).
reg_mutex: Io.Mutex = .init,
inbox_mutex: Io.Mutex = .init,
inbox: std.ArrayList(Msg) = .empty,
/// The batch `tick` is handling (swapped with `inbox`).
taken: std.ArrayList(Msg) = .empty,
servers: std.ArrayList(*Server) = .empty,
open: std.AutoHashMapUnmanaged(DocHandle, OpenDoc) = .empty,
closing: std.atomic.Value(bool) = .init(false),

/// `m` must not move once a document is open.
pub fn init(m: *Manager, rt: *zg_core.Runtime, reg: *Registry, docs: *DocumentRegistry, opts: Options) void {
    m.* = .{
        .gpa = rt.gpa,
        .rt = rt,
        .reg = reg,
        .docs = docs,
        .opts = opts,
        .empty_env = .init(rt.gpa),
        .sub = .init(rt.io),
    };
}

/// Shuts every server down (`shutdown`/`exit`, then terminate) and waits
/// for the workers. Blocks; call at exit.
pub fn deinit(m: *Manager) void {
    m.closing.store(true, .release);
    // Starting servers clean up after themselves once they see `closing`.
    for (m.servers.items) |s| if (s.status == .running) m.retire(s);
    m.sub.join() catch {};
    // Servers whose start finished after `closing` was set.
    for (m.takeInbox()) |msg| switch (msg) {
        .attach => |a| m.freeAttach(a),
        .ready => |s| m.retire(s),
        .failed, .crashed => {},
    };
    m.sub.join() catch {};
    m.freeTaken();
    m.inbox.deinit(m.gpa);
    m.taken.deinit(m.gpa);
    for (m.servers.items) |s| {
        s.docs.deinit(m.gpa);
        s.arena.deinit();
        m.gpa.free(s.root);
        m.gpa.free(s.exe);
        m.gpa.destroy(s);
    }
    m.servers.deinit(m.gpa);
    var it = m.open.valueIterator();
    while (it.next()) |d| m.gpa.free(d.lang);
    m.open.deinit(m.gpa);
    m.empty_env.deinit();
}

fn env(m: *Manager) *const std.process.Environ.Map {
    return m.opts.env orelse &m.empty_env;
}

/// The servers, in start order (for status displays).
pub fn serverList(m: *const Manager) []const *Server {
    return m.servers.items;
}

// ------------------------------------------------------------- documents

/// Attaches `h` to every enabled server for `language_id` and its path,
/// starting servers as needed. Opening a document twice does nothing.
pub fn openDoc(m: *Manager, h: DocHandle, language_id: []const u8) !void {
    if (m.open.contains(h)) return;
    const kind = m.docs.kind(h) orelse return error.StaleHandle;
    const path: ?[]const u8 = if (kind == .file) m.docs.name(h) else null;
    var defs: std.ArrayList(*const ServerDef) = .empty;
    defer defs.deinit(m.gpa);
    try m.reg.defsForDoc(language_id, path, &defs, m.gpa);

    const lang = try m.gpa.dupe(u8, language_id);
    errdefer m.gpa.free(lang);
    try m.open.put(m.gpa, h, .{ .lang = lang });
    errdefer _ = m.open.remove(h);
    if (defs.items.len == 0) return;

    const job = try m.gpa.create(ResolveJob);
    errdefer m.gpa.destroy(job);
    job.* = .{
        .mgr = m,
        .h = h,
        .path = if (path) |p| try m.gpa.dupe(u8, p) else null,
        .defs = try defs.toOwnedSlice(m.gpa),
    };
    m.sub.spawn(resolveTask, .{job});
}

/// Detaches `h` from its servers (`didClose` where it was tracked).
pub fn closeDoc(m: *Manager, h: DocHandle) void {
    const kv = m.open.fetchRemove(h) orelse return;
    m.gpa.free(kv.value.lang);
    for (m.servers.items) |s| {
        const i = indexOfDoc(s.docs.items, h) orelse continue;
        _ = s.docs.swapRemove(i);
        if (s.sync) |*sy| sy.untrack(h);
    }
}

/// Sends `didSave` to the servers tracking `h`.
pub fn saved(m: *Manager, h: DocHandle) void {
    for (m.servers.items) |s| if (s.sync) |*sy| if (sy.isTracked(h)) sy.saved(h);
}

/// Drains worker reports, then flushes pending edits to every running
/// server. Call once per frame.
pub fn tick(m: *Manager) void {
    for (m.takeInbox()) |msg| switch (msg) {
        .attach => |a| m.onAttach(a),
        .ready => |s| m.onReady(s),
        .failed => |f| m.onFailed(f.server, f.err),
        .crashed => |s| m.onCrashed(s),
    };
    m.freeTaken();
    for (m.servers.items) |s| if (s.sync) |*sy| sy.flush();
}

/// The running clients that `f` goes to for `h`, per `routing`; writes a
/// prefix of `out` and returns its length.
pub fn clientsFor(m: *Manager, h: DocHandle, f: Feature, out: []*Client) usize {
    const od = m.open.get(h) orelse return 0;
    const kind = m.docs.kind(h) orelse return 0;
    const match: DocMatch = .{
        .language_id = od.lang,
        .scheme = if (kind == .file) "file" else "untitled",
        .path = if (kind == .file) m.docs.name(h) else null,
    };
    const C = routing.Candidate(*Client);
    var buf: [16]C = undefined;
    var n: usize = 0;
    for (m.servers.items) |s| {
        if (s.status != .running or !s.hasDoc(h) or n == buf.len) continue;
        const c = s.client.?;
        const caps = c.caps() orelse continue;
        buf[n] = .{ .def = s.def, .ctx = c, .supports = caps.supports(f, match) };
        n += 1;
    }
    return routing.select(*Client, f, buf[0..n], out);
}

/// The server running `def_id` for `h`, if any.
pub fn serverFor(m: *Manager, h: DocHandle, def_id: []const u8) ?*Server {
    for (m.servers.items) |s| {
        if (std.mem.eql(u8, s.def.id, def_id) and s.hasDoc(h)) return s;
    }
    return null;
}

// ------------------------------------------------------------ UI handlers

fn onAttach(m: *Manager, a: @FieldType(Msg, "attach")) void {
    defer m.freeAttach(a);
    if (!m.open.contains(a.h)) return;
    const s = for (m.servers.items) |s| {
        if (s.def == a.def and std.mem.eql(u8, s.root, a.root)) break s;
    } else m.newServer(a) catch |err| {
        log.warn("{s}: {t}", .{ a.def.id, err });
        return;
    };
    if (s.status == .missing) return;
    s.docs.append(m.gpa, a.h) catch return;
    if (s.sync) |*sy| m.track(sy, a.h);
}

fn newServer(m: *Manager, a: @FieldType(Msg, "attach")) !*Server {
    const s = try m.gpa.create(Server);
    errdefer m.gpa.destroy(s);
    const root = try m.gpa.dupe(u8, a.root);
    errdefer m.gpa.free(root);
    const exe = try m.gpa.dupe(u8, a.exe orelse "");
    errdefer m.gpa.free(exe);
    s.* = .{
        .mgr = m,
        .def = a.def,
        .root = root,
        .exe = exe,
        .status = if (a.exe == null) .missing else .starting,
        .arena = .init(m.gpa),
    };
    try m.servers.append(m.gpa, s);
    if (a.exe == null) {
        log.info("{s} not found on PATH", .{a.def.id});
        return s;
    }
    m.sub.spawnLoop(startTask, .{s}) catch |err| {
        s.status = .failed;
        s.err = err;
    };
    return s;
}

fn onReady(m: *Manager, s: *Server) void {
    const c = s.client.?;
    s.status = .running;
    if (c.state() != .running) return m.onCrashed(s);
    s.sink = .init(m.gpa, .client(c));
    const caps = c.caps().?;
    const enc: zg_core.utf8.Encoding = switch (c.encoding()) {
        .utf8 => .utf8,
        .utf16 => .utf16,
        .utf32 => .utf32,
    };
    const kind: api.lsp_sync.SyncKind = switch (caps.sync_kind) {
        .None => .none,
        .Full => .full,
        .Incremental => .incremental,
        _ => .full,
    };
    s.sync = .init(m.gpa, m.docs, enc, kind, s.sink.lspSink());
    s.sync.?.include_text_on_save = caps.save_include_text;
    for (s.docs.items) |h| m.track(&s.sync.?, h);
}

fn track(m: *Manager, sy: *LspSync, h: DocHandle) void {
    const od = m.open.get(h) orelse return;
    sy.track(h, od.lang) catch |err| log.warn("track: {t}", .{err});
}

fn onFailed(m: *Manager, s: *Server, err: anyerror) void {
    _ = m;
    s.status = .failed;
    s.err = err;
    log.info("{s} failed to start: {t}", .{ s.def.id, err });
}

fn onCrashed(m: *Manager, s: *Server) void {
    // A crash before `ready` is noticed when `ready` arrives.
    if (s.status != .running) return;
    log.info("{s} crashed", .{s.def.id});
    m.detach(s);
    s.status = .crashed;
    m.retire(s);
}

/// Stops syncing `s` without sending anything.
fn detach(m: *Manager, s: *Server) void {
    _ = m;
    if (s.sync) |*sy| {
        sy.deinit();
        s.sync = null;
        s.sink.deinit();
    }
}

/// Hands `s`'s client and process to a worker to shut down and free.
fn retire(m: *Manager, s: *Server) void {
    m.detach(s);
    const c = s.client orelse return;
    const p = s.proc.?;
    s.client = null;
    s.proc = null;
    m.sub.spawn(reapTask, .{ c, p });
}

// ---------------------------------------------------------------- inbox

fn push(m: *Manager, msg: Msg) void {
    {
        m.inbox_mutex.lockUncancelable(m.rt.io);
        defer m.inbox_mutex.unlock(m.rt.io);
        m.inbox.append(m.gpa, msg) catch {
            log.err("inbox: out of memory", .{});
            return;
        };
    }
    m.opts.waker.wake();
}

fn takeInbox(m: *Manager) []const Msg {
    m.inbox_mutex.lockUncancelable(m.rt.io);
    defer m.inbox_mutex.unlock(m.rt.io);
    std.mem.swap(std.ArrayList(Msg), &m.inbox, &m.taken);
    return m.taken.items;
}

fn freeTaken(m: *Manager) void {
    m.taken.clearRetainingCapacity();
}

fn freeAttach(m: *Manager, a: @FieldType(Msg, "attach")) void {
    m.gpa.free(a.root);
    if (a.exe) |e| m.gpa.free(e);
}

// ---------------------------------------------------------------- workers

const ResolveJob = struct {
    mgr: *Manager,
    h: DocHandle,
    path: ?[]u8,
    defs: []*const ServerDef,
};

/// Resolves each definition's executable and root, then reports.
fn resolveTask(job: *ResolveJob) Io.Cancelable!void {
    const m = job.mgr;
    defer {
        if (job.path) |p| m.gpa.free(p);
        m.gpa.free(job.defs);
        m.gpa.destroy(job);
    }
    const io = m.rt.io;
    for (job.defs) |def| {
        const exe: ?[]u8 = blk: {
            m.reg_mutex.lockUncancelable(io);
            defer m.reg_mutex.unlock(io);
            const found = m.reg.resolveExecutable(io, def, m.env()) catch return;
            const f = found orelse break :blk null;
            // Servers run in their root, so a relative path must not stay relative.
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const abs = if (std.fs.path.isAbsolute(f)) f else buf[0 .. Io.Dir.cwd().realPathFile(io, f, &buf) catch break :blk null];
            break :blk m.gpa.dupe(u8, abs) catch return;
        };
        const root_src: []const u8 = if (job.path) |p|
            Registry.findRoot(io, def, p, m.opts.workspace_folders)
        else if (m.opts.workspace_folders.len > 0)
            m.opts.workspace_folders[0]
        else
            "";
        const root = m.gpa.dupe(u8, root_src) catch {
            if (exe) |e| m.gpa.free(e);
            return;
        };
        m.push(.{ .attach = .{ .h = job.h, .def = def, .root = root, .exe = exe } });
    }
}

/// Spawns the server, wires a client and waits for `initialize`.
fn startTask(s: *Server) Io.Cancelable!void {
    const m = s.mgr;
    start(s) catch |e| {
        if (s.client) |c| {
            c.shutdown();
            c.deinit();
        }
        if (s.proc) |p| p.deinit();
        s.client = null;
        s.proc = null;
        if (e == error.Canceled) return error.Canceled;
        m.push(.{ .failed = .{ .server = s, .err = e } });
        return;
    };
    m.push(.{ .ready = s });
}

fn start(s: *Server) !void {
    const m = s.mgr;
    const a = s.arena.allocator();
    const def = s.def;
    const argv = try a.alloc([]const u8, def.command.len);
    argv[0] = s.exe;
    @memcpy(argv[1..], def.command[1..]);
    s.proc = try ServerProcess.start(m.rt, .{
        .argv = argv,
        .cwd = if (s.root.len > 0) s.root else null,
        .base_env = m.opts.env,
        .name = def.id,
    }, m.opts.policy, ServerProcess.default_stderr_cap);

    var folders: []const zg_lsp.protocol.WorkspaceFolder = &.{};
    var root_uri: ?[]const u8 = null;
    if (s.root.len > 0) {
        const u = try zg_lsp.uri.uriFromPath(a, s.root);
        root_uri = u;
        folders = try a.dupe(zg_lsp.protocol.WorkspaceFolder, &.{.{ .uri = u, .name = std.fs.path.basename(s.root) }});
    }
    const init_opts: ?std.json.Value = if (def.initialization_options) |text|
        try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{})
    else
        null;
    s.client = try Client.create(m.rt, s.proc.?, .{
        .client_version = m.opts.client_version,
        .root_uri = root_uri,
        .workspace_folders = folders,
        .roots = if (s.root.len > 0) try a.dupe([]const u8, &.{s.root}) else &.{},
        .initialization_options = init_opts,
        .init_timeout = m.opts.init_timeout,
    });
    try s.client.?.subscribe(.{ .ctx = s, .on_state = onClientState });
    try s.client.?.start();
    try s.client.?.waitInitialized(m.opts.init_timeout);
    if (m.closing.load(.acquire)) return error.Canceled;
}

fn onClientState(ctx: ?*anyopaque, _: *Client, st: zg_lsp.client.Client.ClientState) void {
    const s: *Server = @ptrCast(@alignCast(ctx.?));
    if (st == .crashed and !s.mgr.closing.load(.acquire)) s.mgr.push(.{ .crashed = s });
}

/// Shuts a client down and frees it with its process.
fn reapTask(c: *Client, p: *ServerProcess) Io.Cancelable!void {
    c.shutdown();
    c.deinit();
    p.deinit();
}

fn indexOfDoc(items: []const DocHandle, h: DocHandle) ?usize {
    for (items, 0..) |x, i| if (std.meta.eql(x, h)) return i;
    return null;
}
