//! Code lens (E07.F03.S02.T03): `textDocument/codeLens` for the documents
//! an editor shows, 250 ms after an edit and on
//! `workspace/codeLens/refresh`. Editors draw a row above each line that
//! has lenses (`lines`); a lens the server sent without a command is a
//! placeholder in that row until it is resolved (`codeLens/resolve`),
//! which happens only for lenses on screen. The rows never change when
//! lenses resolve, and the previous lenses stay (mapped through edits)
//! until the next answer, so the text does not jump.
//!
//! `execute` runs a lens: known run and debug commands become zigguro
//! actions (`lens_commands`), anything else goes to the server as
//! `workspace/executeCommand` from the user.

const CodeLensService = @This();
const std = @import("std");
const zg_core = @import("zg_core");
const zg_lsp = @import("zg_lsp");
const zg_editor = @import("zg_editor");
const Manager = @import("../Manager.zig");
const poller = @import("poller.zig");
const oneshot = @import("oneshot.zig");
const position = @import("position.zig");
const CommandService = @import("commands.zig");
pub const lens_commands = @import("lens_commands.zig");

const Allocator = std.mem.Allocator;
const protocol = zg_lsp.protocol;
const Client = zg_lsp.client.Client;
const DocHandle = zg_editor.model.api.registry.DocHandle;
const Document = zg_editor.model.document.Document;
const ByteRange = position.ByteRange;
const M = .@"textDocument/codeLens";
const Poll = poller.Poller(M, .code_lens);
const Resolve = oneshot.Oneshot(.@"codeLens/resolve", LensId);

pub const LensId = u64;

/// Lines `[first, end)`.
pub const LineRange = struct { first: u64, end: u64 };

pub const Lens = struct {
    id: LensId,
    /// In the document's current version.
    range: ByteRange,
    line: u64,
    /// Null while unresolved (a placeholder).
    title: ?[]const u8 = null,
    /// The command name and the whole command as JSON.
    command: ?[]const u8 = null,
    command_json: ?[]const u8 = null,
    /// The lens as sent, for `codeLens/resolve`.
    raw: ?[]const u8 = null,
    resolving: bool = false,
    client: *Client,
};

pub const Options = struct {
    debounce_ms: u64 = 250,
    waker: zg_core.runtime.Waker = .noop,
    /// `lsp.codeLens.commands`: more run/debug commands.
    mappings: []const lens_commands.LensMapping = &.{},
};

/// What `execute` did.
pub const Outcome = union(enum) {
    /// A run or debug lens: the host runs it (its command, as JSON).
    action: struct { action: lens_commands.Action, command: []const u8, command_json: []const u8 },
    /// Sent to the server.
    server,
    /// Unresolved, unknown or without a server.
    none,
};

const Entry = struct {
    arena: std.heap.ArenaAllocator,
    lenses: std.ArrayList(Lens) = .empty,
    version: u64,
    visible: ?LineRange = null,

    fn deinit(e: *Entry, gpa: Allocator) void {
        e.lenses.deinit(gpa);
        e.arena.deinit();
    }
};

gpa: Allocator,
mgr: *Manager,
poll: Poll,
resolve_req: Resolve,
opts: Options,
entries: std.AutoHashMapUnmanaged(DocHandle, Entry) = .empty,
next_id: LensId = 1,
/// Bumped when any document's lenses change.
generation: u64 = 0,

/// `s` must not move once initialized (refresh listener, hooks).
pub fn init(s: *CodeLensService, mgr: *Manager, opts: Options) Allocator.Error!void {
    s.* = .{
        .gpa = mgr.gpa,
        .mgr = mgr,
        .poll = .init(mgr, .{ .ctx = s, .apply = apply, .clear = clearHook }, .{ .debounce = .fromMilliseconds(@intCast(opts.debounce_ms)), .waker = opts.waker }),
        .resolve_req = .init(mgr.gpa, mgr.rt.io, opts.waker),
        .opts = opts,
    };
    try mgr.onRefresh(.{ .ctx = s, .func = onRefreshHook });
}

/// Call after `Manager.deinit`.
pub fn deinit(s: *CodeLensService) void {
    s.poll.deinit();
    s.resolve_req.deinit();
    var it = s.entries.valueIterator();
    while (it.next()) |e| e.deinit(s.gpa);
    s.entries.deinit(s.gpa);
}

/// Lines `[first, end)` of `h` are on screen: its lenses are kept current
/// and the visible unresolved ones are resolved.
pub fn onViewport(s: *CodeLensService, h: DocHandle, visible: LineRange) Allocator.Error!void {
    if (!s.poll.isTracked(h)) try s.poll.track(h);
    const doc = s.mgr.docs.get(h) orelse return;
    const gop = try s.entries.getOrPut(s.gpa, h);
    if (!gop.found_existing) gop.value_ptr.* = .{ .arena = .init(s.gpa), .version = doc.version };
    const e = gop.value_ptr;
    e.visible = visible;
    s.resolveVisible(e);
}

/// Forgets `h` (it closed).
pub fn forget(s: *CodeLensService, h: DocHandle) void {
    s.poll.untrack(h);
    s.clear(h);
}

/// `workspace/codeLens/refresh`: every shown document is asked again.
pub fn onRefresh(s: *CodeLensService, _: *Manager.Server) void {
    s.poll.refresh();
}

fn onRefreshHook(ctx: *anyopaque, server: *Manager.Server, f: Manager.RefreshFeature) void {
    const s: *CodeLensService = @ptrCast(@alignCast(ctx));
    if (f == .code_lens) s.onRefresh(server);
}

/// The earliest debounced request (`.awake` nanoseconds), if any.
pub fn nextDue(s: *const CodeLensService) ?i96 {
    return s.poll.nextDue();
}

/// Takes answers and sends due requests; true when lenses changed.
pub fn tick(s: *CodeLensService) bool {
    const g = s.generation;
    _ = s.poll.tick();
    for (s.resolve_req.take()) |a| s.onResolved(a);
    return s.generation != g;
}

/// The lenses of `h` in its current version, by line.
pub fn lenses(s: *CodeLensService, h: DocHandle) []const Lens {
    const e = s.entries.getPtr(h) orelse return &.{};
    const doc = s.mgr.docs.get(h) orelse return &.{};
    s.sync(e, doc);
    return e.lenses.items;
}

/// The lines that have a lens row, ascending (one row each, resolved or
/// not).
pub fn lines(s: *CodeLensService, h: DocHandle, gpa: Allocator, out: *std.ArrayList(u64)) Allocator.Error!void {
    out.clearRetainingCapacity();
    for (s.lenses(h)) |l| {
        if (out.items.len > 0 and out.items[out.items.len - 1] == l.line) continue;
        try out.append(gpa, l.line);
    }
}

/// Runs lens `id` of `h`.
pub fn execute(s: *CodeLensService, h: DocHandle, id: LensId, commands: *CommandService) !Outcome {
    for (s.lenses(h)) |l| if (l.id == id) {
        const name = l.command orelse return .none;
        const json = l.command_json orelse return .none;
        if (lens_commands.lookup(s.opts.mappings, name)) |act| return .{ .action = .{ .action = act, .command = name, .command_json = json } };
        const server = for (s.mgr.serverList()) |sv| {
            if (sv.client == l.client and sv.status == .running) break sv;
        } else return .none;
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const cmd = try std.json.parseFromSliceLeaky(protocol.Command, arena.allocator(), json, .{ .ignore_unknown_fields = true });
        try commands.execute(server, cmd, null);
        return .server;
    };
    return .none;
}

fn canResolve(c: *Client) bool {
    const caps = c.caps() orelse return false;
    const p = caps.raw.codeLensProvider orelse return false;
    return p.resolveProvider orelse false;
}

fn resolveVisible(s: *CodeLensService, e: *Entry) void {
    const vis = e.visible orelse return;
    for (e.lenses.items) |*l| {
        if (l.title != null or l.resolving or l.line < vis.first or l.line >= vis.end) continue;
        const raw = l.raw orelse continue;
        if (!canResolve(l.client)) continue;
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const lens = std.json.parseFromSliceLeaky(protocol.CodeLens, arena.allocator(), raw, .{ .ignore_unknown_fields = true }) catch continue;
        s.resolve_req.send(l.client, lens, .{}, l.id) catch continue;
        l.resolving = true;
    }
}

/// Maps `e` through the edits since its version (a lens follows its
/// text; one whose text was deleted goes).
fn sync(s: *CodeLensService, e: *Entry, doc: *const Document) void {
    if (e.version == doc.version) return;
    var keep: usize = 0;
    for (e.lenses.items) |l| {
        const r = position.mapResultRange(doc, e.version, l.range, .shrink) orelse continue;
        var y = l;
        y.range = r;
        y.line = doc.tree.lineOf(r.start);
        e.lenses.items[keep] = y;
        keep += 1;
    }
    e.lenses.shrinkRetainingCapacity(keep);
    e.version = doc.version;
    s.generation += 1;
}

fn clear(s: *CodeLensService, h: DocHandle) void {
    var kv = s.entries.fetchRemove(h) orelse return;
    kv.value.deinit(s.gpa);
    s.generation += 1;
}

fn clearHook(ctx: *anyopaque, h: DocHandle) void {
    const s: *CodeLensService = @ptrCast(@alignCast(ctx));
    s.clear(h);
}

fn apply(ctx: *anyopaque, h: DocHandle, c: *Client, value: ?[]const protocol.CodeLens) bool {
    const s: *CodeLensService = @ptrCast(@alignCast(ctx));
    const doc = s.mgr.docs.get(h) orelse return false;
    var e: Entry = .{ .arena = .init(s.gpa), .version = doc.version };
    s.fill(&e, doc, c, value orelse &.{}) catch {
        e.deinit(s.gpa);
        return false;
    };
    if (s.entries.getPtr(h)) |old| {
        e.visible = old.visible;
        old.deinit(s.gpa);
        old.* = e;
    } else s.entries.put(s.gpa, h, e) catch {
        e.deinit(s.gpa);
        return false;
    };
    s.generation += 1;
    s.resolveVisible(s.entries.getPtr(h).?);
    return true;
}

fn fill(s: *CodeLensService, e: *Entry, doc: *const Document, c: *Client, got: []const protocol.CodeLens) !void {
    const a = e.arena.allocator();
    var m: position.Mapper = .{ .gpa = s.gpa, .tree = &doc.tree, .enc = position.encodingOf(c.encoding()) };
    defer m.deinit();
    for (got) |x| {
        const r = m.toRange(x.range) catch continue;
        if (r.start > doc.len()) continue;
        var l: Lens = .{ .id = s.next_id, .range = r, .line = doc.tree.lineOf(r.start), .client = c };
        s.next_id += 1;
        if (x.command) |cmd| try setCommand(a, &l, cmd) else l.raw = try std.json.Stringify.valueAlloc(a, x, .{});
        try e.lenses.append(s.gpa, l);
    }
    std.sort.block(Lens, e.lenses.items, {}, struct {
        fn lt(_: void, p: Lens, q: Lens) bool {
            return if (p.line != q.line) p.line < q.line else p.range.start < q.range.start;
        }
    }.lt);
}

fn setCommand(a: Allocator, l: *Lens, cmd: protocol.Command) !void {
    l.title = try a.dupe(u8, cmd.title);
    l.command = try a.dupe(u8, cmd.command);
    l.command_json = try std.json.Stringify.valueAlloc(a, cmd, .{});
    l.raw = null;
}

fn onResolved(s: *CodeLensService, a: *const Resolve.Answer) void {
    var it = s.entries.valueIterator();
    while (it.next()) |e| for (e.lenses.items) |*l| if (l.id == a.tag) {
        l.resolving = false;
        switch (a.result) {
            .ok => |o| if (o.value.command) |cmd| {
                setCommand(e.arena.allocator(), l, cmd) catch return;
                s.generation += 1;
            } else {
                // Nothing to show: keep the placeholder, ask no more.
                l.raw = null;
            },
            else => l.raw = null,
        }
        return;
    };
}
