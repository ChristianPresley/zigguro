//! Selection ranges for expand/shrink selection (E07.F03.S02.T02):
//! `textDocument/selectionRange` for every cursor, answered as one chain
//! of byte ranges per cursor, innermost first. When no server provides
//! them, or the answer comes too late (the document changed), the answer
//! says `fallback` and the editor walks its own structure's scopes
//! (`zg_syntax.Structure.selectionRanges`).

const SelectionDriver = @This();
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zg_core = @import("zg_core");
const zg_lsp = @import("zg_lsp");
const zg_editor = @import("zg_editor");
const Manager = @import("../Manager.zig");
const position = @import("position.zig");

const Client = zg_lsp.client.Client;
const protocol = zg_lsp.protocol;
const DocHandle = zg_editor.model.api.registry.DocHandle;
const M = .@"textDocument/selectionRange";

/// Bytes `[start, end)`.
pub const ByteRange = struct { start: u64, end: u64 };

/// The answer to one `request`; valid during the callback only.
pub const Answer = union(enum) {
    /// One chain per requested offset, innermost first.
    chains: []const []const ByteRange,
    /// Use the editor's own structure.
    fallback,
};

pub const Callback = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, h: DocHandle, a: Answer) void,
};

const Pending = struct {
    d: *SelectionDriver,
    h: DocHandle,
    version: u64,
    enc: position.Encoding,
    cb: Callback,
    result: Client.Result(M) = undefined,
};

gpa: Allocator,
io: Io,
mgr: *Manager,
waker: zg_core.runtime.Waker,
inbox_mutex: Io.Mutex = .init,
inbox: std.ArrayList(*Pending) = .empty,
taken: std.ArrayList(*Pending) = .empty,
outstanding: usize = 0,

pub fn init(mgr: *Manager, waker: zg_core.runtime.Waker) SelectionDriver {
    return .{ .gpa = mgr.gpa, .io = mgr.rt.io, .mgr = mgr, .waker = waker };
}

/// Call after `Manager.deinit` (pending callbacks are not called).
pub fn deinit(d: *SelectionDriver) void {
    for (d.takeInbox()) |p| d.drop(p);
    std.debug.assert(d.outstanding == 0);
    d.taken.deinit(d.gpa);
    d.inbox.deinit(d.gpa);
}

/// Asks for the selection ranges at `offsets` (bytes) of `h`; `cb` runs
/// from a later `tick`, or at once with `fallback` when no server
/// provides them.
pub fn request(d: *SelectionDriver, h: DocHandle, offsets: []const u64, cb: Callback) Allocator.Error!void {
    var servers: [1]*Manager.Server = undefined;
    const doc = d.mgr.docs.get(h);
    const uri = d.mgr.docs.uri(h);
    if (doc == null or uri == null or offsets.len == 0 or d.mgr.serversFor(h, .selection_range, &servers) == 0) {
        cb.func(cb.ctx, h, .fallback);
        return;
    }
    const c = servers[0].client.?;
    const enc = position.encodingOf(c.encoding());
    var m: position.Mapper = .{ .gpa = d.gpa, .tree = &doc.?.tree, .enc = enc };
    defer m.deinit();
    const positions = try d.gpa.alloc(protocol.Position, offsets.len);
    defer d.gpa.free(positions);
    for (offsets, positions) |off, *p| p.* = try m.positionOf(off);

    const p = try d.gpa.create(Pending);
    p.* = .{ .d = d, .h = h, .version = doc.?.version, .enc = enc, .cb = cb };
    _ = c.request(M, .{ .textDocument = .{ .uri = uri.? }, .positions = positions }, .{ .doc = d.mgr.docMatch(h) }, .{ .ctx = p, .func = onResult }) catch {
        d.gpa.destroy(p);
        cb.func(cb.ctx, h, .fallback);
        return;
    };
    d.outstanding += 1;
}

/// Delivers answers.
pub fn tick(d: *SelectionDriver) void {
    for (d.takeInbox()) |p| {
        defer d.drop(p);
        d.deliver(p) catch p.cb.func(p.cb.ctx, p.h, .fallback);
    }
    d.taken.clearRetainingCapacity();
}

fn deliver(d: *SelectionDriver, p: *Pending) !void {
    const doc = d.mgr.docs.get(p.h) orelse return;
    const value = switch (p.result) {
        .ok => |o| o.value orelse return error.Fallback,
        else => return error.Fallback,
    };
    if (doc.version != p.version) return error.Fallback;
    var arena: std.heap.ArenaAllocator = .init(d.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var m: position.Mapper = .{ .gpa = d.gpa, .tree = &doc.tree, .enc = p.enc };
    defer m.deinit();
    const chains = try a.alloc([]const ByteRange, value.len);
    for (value, chains) |sr, *chain| {
        var list: std.ArrayList(ByteRange) = .empty;
        var cur: ?*const protocol.SelectionRange = &sr;
        // Parents must contain their children; stop at the first that
        // does not (and at a silly depth).
        while (cur) |r| : (cur = r.parent) {
            const br: ByteRange = .{ .start = try m.byteOf(r.range.start), .end = try m.byteOf(r.range.end) };
            if (br.end < br.start) break;
            if (list.items.len > 0) {
                const inner = list.items[list.items.len - 1];
                if (br.start > inner.start or br.end < inner.end) break;
                if (br.start == inner.start and br.end == inner.end) continue;
            }
            try list.append(a, br);
            if (list.items.len == 256) break;
        }
        chain.* = list.items;
    }
    p.cb.func(p.cb.ctx, p.h, .{ .chains = chains });
}

fn onResult(ctx: ?*anyopaque, r: Client.Result(M)) void {
    const p: *Pending = @ptrCast(@alignCast(ctx.?));
    p.result = r;
    const d = p.d;
    {
        d.inbox_mutex.lockUncancelable(d.io);
        defer d.inbox_mutex.unlock(d.io);
        d.inbox.append(d.gpa, p) catch return;
    }
    d.waker.wake();
}

fn drop(d: *SelectionDriver, p: *Pending) void {
    p.result.deinit();
    d.gpa.destroy(p);
    d.outstanding -= 1;
}

fn takeInbox(d: *SelectionDriver) []const *Pending {
    d.inbox_mutex.lockUncancelable(d.io);
    defer d.inbox_mutex.unlock(d.io);
    std.mem.swap(std.ArrayList(*Pending), &d.inbox, &d.taken);
    return d.taken.items;
}

/// Expand: the smallest range in `chain` strictly larger than `cur`.
pub fn expand(chain: []const ByteRange, cur: ByteRange) ?ByteRange {
    for (chain) |r| {
        if (r.start <= cur.start and r.end >= cur.end and (r.start < cur.start or r.end > cur.end)) return r;
    }
    return null;
}

/// Shrink: the largest range in `chain` strictly inside `cur`.
pub fn shrink(chain: []const ByteRange, cur: ByteRange) ?ByteRange {
    var i = chain.len;
    while (i > 0) {
        i -= 1;
        const r = chain[i];
        if (r.start >= cur.start and r.end <= cur.end and (r.start > cur.start or r.end < cur.end)) return r;
    }
    return null;
}
