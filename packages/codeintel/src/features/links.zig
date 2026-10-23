//! Document links (E07.F03.S02.T02): `textDocument/documentLink` for
//! tracked documents (asked again after edits), kept as byte ranges for
//! the editor to underline. `open` follows a link: it resolves it first
//! (`documentLink/resolve`) when the server left the target out, then
//! hands `file:` and `http(s):` targets to the opener; `command:` targets
//! only when the command is on the allowlist, other schemes never.

const LinkDriver = @This();
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zg_lsp = @import("zg_lsp");
const zg_editor = @import("zg_editor");
const Manager = @import("../Manager.zig");
const poller = @import("poller.zig");
const position = @import("position.zig");

const Client = zg_lsp.client.Client;
const protocol = zg_lsp.protocol;
const DocHandle = zg_editor.model.api.registry.DocHandle;
const M = .@"textDocument/documentLink";
const M_resolve = .@"documentLink/resolve";

const log = std.log.scoped(.codeintel);

pub const Link = struct {
    start: u64,
    end: u64,
    target: ?[]const u8,
    tooltip: ?[]const u8,
    /// The server's link as sent, for `documentLink/resolve`.
    raw: []const u8,
};

pub const TargetKind = enum { file, web, command };

/// Opens followed links (the editor, the browser, the command registry).
pub const Opener = struct {
    ctx: *anyopaque,
    open: *const fn (ctx: *anyopaque, kind: TargetKind, target: []const u8) void,
};

pub const Options = struct {
    poll: poller.Poller(M, .document_link).Options = .{},
    /// Commands `command:` links may run.
    command_allowlist: []const []const u8 = &.{},
};

const Set = struct { arena: std.heap.ArenaAllocator, links: []const Link };

const Resolving = struct {
    d: *LinkDriver,
    h: DocHandle,
    version: u64,
    result: Client.Result(M_resolve) = undefined,
};

gpa: Allocator,
io: Io,
opener: Opener,
allowlist: []const []const u8,
poll: poller.Poller(M, .document_link),
sets: std.AutoHashMapUnmanaged(DocHandle, Set) = .empty,
inbox_mutex: Io.Mutex = .init,
inbox: std.ArrayList(*Resolving) = .empty,
taken: std.ArrayList(*Resolving) = .empty,
outstanding: usize = 0,

pub fn init(d: *LinkDriver, mgr: *Manager, opener: Opener, opts: Options) void {
    d.* = .{
        .gpa = mgr.gpa,
        .io = mgr.rt.io,
        .opener = opener,
        .allowlist = opts.command_allowlist,
        .poll = .init(mgr, .{ .ctx = d, .apply = apply, .clear = clearHook }, opts.poll),
    };
}

/// Call after `Manager.deinit`.
pub fn deinit(d: *LinkDriver) void {
    d.poll.deinit();
    for (d.takeInbox()) |r| d.drop(r);
    std.debug.assert(d.outstanding == 0);
    d.taken.deinit(d.gpa);
    d.inbox.deinit(d.gpa);
    var it = d.sets.valueIterator();
    while (it.next()) |s| s.arena.deinit();
    d.sets.deinit(d.gpa);
}

pub fn track(d: *LinkDriver, h: DocHandle) Allocator.Error!void {
    try d.poll.track(h);
}

pub fn untrack(d: *LinkDriver, h: DocHandle) void {
    d.poll.untrack(h);
    d.clear(h);
}

/// Applies results, sends due requests, follows resolved links; true when
/// the links shown changed.
pub fn tick(d: *LinkDriver) bool {
    for (d.takeInbox()) |r| {
        defer d.drop(r);
        d.followResolved(r);
    }
    d.taken.clearRetainingCapacity();
    return d.poll.tick();
}

pub fn nextDue(d: *const LinkDriver) ?i96 {
    return d.poll.nextDue();
}

/// `h`'s links, in document order.
pub fn links(d: *const LinkDriver, h: DocHandle) []const Link {
    const s = d.sets.getPtr(h) orelse return &.{};
    return s.links;
}

/// The link under byte `off`, if any.
pub fn linkAt(d: *const LinkDriver, h: DocHandle, off: u64) ?usize {
    for (d.links(h), 0..) |l, i| if (l.start <= off and off < l.end) return i;
    return null;
}

/// Follows link `i` of `h` (Ctrl+Click).
pub fn open(d: *LinkDriver, h: DocHandle, i: usize) void {
    const ls = d.links(h);
    if (i >= ls.len) return;
    const l = ls[i];
    if (l.target) |t| return d.follow(t);
    const st = d.poll.states.get(h) orelse return;
    const c = st.client orelse return;
    var arena: std.heap.ArenaAllocator = .init(d.gpa);
    defer arena.deinit();
    const link = std.json.parseFromSliceLeaky(protocol.DocumentLink, arena.allocator(), l.raw, .{ .ignore_unknown_fields = true }) catch return;
    const r = d.gpa.create(Resolving) catch return;
    r.* = .{ .d = d, .h = h, .version = st.applied orelse 0 };
    _ = c.request(M_resolve, link, .{}, .{ .ctx = r, .func = onResolved }) catch {
        d.gpa.destroy(r);
        return;
    };
    d.outstanding += 1;
}

/// The kind of `target`, or null when links may not open it.
pub fn classify(target: []const u8, allowlist: []const []const u8) ?TargetKind {
    const colon = std.mem.indexOfScalar(u8, target, ':') orelse return null;
    const scheme = target[0..colon];
    if (std.ascii.eqlIgnoreCase(scheme, "file")) return .file;
    if (std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "https")) return .web;
    if (std.ascii.eqlIgnoreCase(scheme, "command")) {
        const rest = target[colon + 1 ..];
        const name = rest[0 .. std.mem.indexOfScalar(u8, rest, '?') orelse rest.len];
        for (allowlist) |a| if (std.mem.eql(u8, a, name)) return .command;
    }
    return null;
}

fn follow(d: *LinkDriver, target: []const u8) void {
    const kind = classify(target, d.allowlist) orelse {
        log.info("link target not allowed: {s}", .{target});
        return;
    };
    d.opener.open(d.opener.ctx, kind, target);
}

fn followResolved(d: *LinkDriver, r: *Resolving) void {
    switch (r.result) {
        .ok => |o| if (o.value.target) |t| d.follow(t),
        else => {},
    }
}

fn onResolved(ctx: ?*anyopaque, res: Client.Result(M_resolve)) void {
    const r: *Resolving = @ptrCast(@alignCast(ctx.?));
    r.result = res;
    const d = r.d;
    {
        d.inbox_mutex.lockUncancelable(d.io);
        defer d.inbox_mutex.unlock(d.io);
        d.inbox.append(d.gpa, r) catch return;
    }
    d.poll.opts.waker.wake();
}

fn drop(d: *LinkDriver, r: *Resolving) void {
    r.result.deinit();
    d.gpa.destroy(r);
    d.outstanding -= 1;
}

fn takeInbox(d: *LinkDriver) []const *Resolving {
    d.inbox_mutex.lockUncancelable(d.io);
    defer d.inbox_mutex.unlock(d.io);
    std.mem.swap(std.ArrayList(*Resolving), &d.inbox, &d.taken);
    return d.taken.items;
}

fn clear(d: *LinkDriver, h: DocHandle) void {
    var kv = d.sets.fetchRemove(h) orelse return;
    kv.value.arena.deinit();
}

fn clearHook(ctx: *anyopaque, h: DocHandle) void {
    const d: *LinkDriver = @ptrCast(@alignCast(ctx));
    d.clear(h);
}

fn apply(ctx: *anyopaque, h: DocHandle, c: *Client, value: ?[]const protocol.DocumentLink) bool {
    const d: *LinkDriver = @ptrCast(@alignCast(ctx));
    const doc = d.poll.mgr.docs.get(h) orelse return false;
    var set: Set = .{ .arena = .init(d.gpa), .links = &.{} };
    set.links = d.mapLinks(set.arena.allocator(), &doc.tree, position.encodingOf(c.encoding()), value orelse &.{}) catch {
        set.arena.deinit();
        return false;
    };
    d.clear(h);
    d.sets.put(d.gpa, h, set) catch {
        set.arena.deinit();
    };
    return true;
}

fn mapLinks(d: *LinkDriver, a: Allocator, tree: *const zg_editor.model.buffer.piece_tree.PieceTree, enc: position.Encoding, in: []const protocol.DocumentLink) ![]const Link {
    var m: position.Mapper = .{ .gpa = d.gpa, .tree = tree, .enc = enc };
    defer m.deinit();
    var out: std.ArrayList(Link) = .empty;
    for (in) |l| {
        const s = try m.byteOf(l.range.start);
        const e = try m.byteOf(l.range.end);
        if (e <= s) continue;
        try out.append(a, .{
            .start = s,
            .end = e,
            .target = if (l.target) |t| try a.dupe(u8, t) else null,
            .tooltip = if (l.tooltip) |t| try a.dupe(u8, t) else null,
            .raw = try std.json.Stringify.valueAlloc(a, l, .{}),
        });
    }
    std.mem.sort(Link, out.items, {}, struct {
        fn lt(_: void, x: Link, y: Link) bool {
            return x.start < y.start;
        }
    }.lt);
    return out.items;
}
