//! The outline (E07.F04.S01.T02): a document's symbols as a tree, from
//! `textDocument/documentSymbol` or, with no server, from the syntax
//! layer's structure (`StructureLookup`). The Outline view, breadcrumbs
//! and Go to Symbol in File read it.
//!
//! The server's flat form (`SymbolInformation[]`) is nested by range
//! containment. A document's symbols are asked `debounce_ms` after its
//! last change (only for the documents `want` names). `get` never returns
//! ranges of an older version: an outline for an earlier version is mapped
//! through the edits since, and symbols whose names were edited are
//! dropped until the next answer.

const OutlineProvider = @This();
const std = @import("std");
const zg_core = @import("zg_core");
const zg_lsp = @import("zg_lsp");
const zg_editor = @import("zg_editor");
const zg_syntax = @import("zg_syntax");
const Manager = @import("../Manager.zig");
const requester = @import("request.zig");
const position = @import("position.zig");

const Allocator = std.mem.Allocator;
const protocol = zg_lsp.protocol;
const DocHandle = zg_editor.model.api.registry.DocHandle;
const Document = zg_editor.model.document.Document;
const ByteRange = position.ByteRange;
const Req = requester.Requester(.@"textDocument/documentSymbol", .document_symbol);

pub const SymbolNode = struct {
    name: []const u8,
    detail: ?[]const u8 = null,
    kind: protocol.SymbolKind,
    deprecated: bool = false,
    /// The whole declaration, in bytes.
    range: ByteRange,
    /// The name.
    selection: ByteRange,
    children: []const SymbolNode = &.{},
    /// The flat form's `containerName`.
    container: ?[]const u8 = null,
};

pub const Source = enum { lsp, structure };

pub const Outline = struct {
    arena: std.heap.ArenaAllocator,
    /// The document version the ranges are for.
    version: u64,
    roots: []const SymbolNode,
    source: Source,

    pub fn deinit(o: *Outline) void {
        o.arena.deinit();
    }

    pub const Flat = struct { node: *const SymbolNode, depth: u16 };

    /// Every symbol in document order, with its depth.
    pub fn flatten(o: *const Outline, gpa: Allocator, out: *std.ArrayList(Flat)) Allocator.Error!void {
        out.clearRetainingCapacity();
        try flattenInto(gpa, o.roots, 0, out);
    }

    fn flattenInto(gpa: Allocator, nodes: []const SymbolNode, depth: u16, out: *std.ArrayList(Flat)) Allocator.Error!void {
        for (nodes) |*n| {
            try out.append(gpa, .{ .node = n, .depth = depth });
            try flattenInto(gpa, n.children, depth +| 1, out);
        }
    }

    /// The count of symbols.
    pub fn count(o: *const Outline) usize {
        return countIn(o.roots);
    }

    fn countIn(nodes: []const SymbolNode) usize {
        var n: usize = nodes.len;
        for (nodes) |c| n += countIn(c.children);
        return n;
    }
};

/// The syntax layer's structure of a document at its current version
/// (null: none yet). The caller frees it.
pub const StructureLookup = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, h: DocHandle, gpa: Allocator) ?zg_syntax.Structure,
};

/// Told when `get(h)` has a new outline.
pub const Listener = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, h: DocHandle) void,
};

pub const Options = struct { debounce_ms: u64 = 300 };

const Entry = struct {
    /// The last answer (or structure), at its version.
    base: ?Outline = null,
    /// `base` mapped to `mapped.version`.
    mapped: ?Outline = null,
    /// The version asked about or answered (no new ask until it changes).
    asked: ?u64 = null,
    /// When the next ask is due (after the last change).
    due_ms: ?u64 = null,
    seen_version: u64 = 0,

    fn deinit(e: *Entry) void {
        if (e.base) |*b| b.deinit();
        if (e.mapped) |*m| m.deinit();
    }
};

gpa: Allocator,
mgr: *Manager,
req: Req,
opts: Options,
structure: ?StructureLookup = null,
entries: std.AutoHashMapUnmanaged(DocHandle, Entry) = .empty,
listeners: std.ArrayList(Listener) = .empty,
/// The document of the request in flight.
inflight: ?DocHandle = null,

pub fn init(mgr: *Manager, waker: zg_core.runtime.Waker, opts: Options) OutlineProvider {
    return .{ .gpa = mgr.gpa, .mgr = mgr, .req = .init(mgr, waker), .opts = opts };
}

/// Call after `Manager.deinit`.
pub fn deinit(o: *OutlineProvider) void {
    o.req.deinit();
    var it = o.entries.valueIterator();
    while (it.next()) |e| e.deinit();
    o.entries.deinit(o.gpa);
    o.listeners.deinit(o.gpa);
}

pub fn subscribe(o: *OutlineProvider, l: Listener) !void {
    try o.listeners.append(o.gpa, l);
}

fn notify(o: *OutlineProvider, h: DocHandle) void {
    for (o.listeners.items) |l| l.f(l.ctx, h);
}

/// Keeps the outline of `h` current from now on.
pub fn want(o: *OutlineProvider, h: DocHandle, now_ms: u64) !void {
    const gop = try o.entries.getOrPut(o.gpa, h);
    if (!gop.found_existing) gop.value_ptr.* = .{};
    const doc = o.mgr.docs.get(h) orelse return;
    const e = gop.value_ptr;
    if (e.asked == doc.version) return;
    if (e.seen_version != doc.version or e.due_ms == null) {
        // The first ask goes at once; later ones after the typing stops.
        e.due_ms = if (e.asked == null) now_ms else now_ms + o.opts.debounce_ms;
        e.seen_version = doc.version;
    }
}

/// Forgets `h` (it closed).
pub fn forget(o: *OutlineProvider, h: DocHandle) void {
    if (o.entries.fetchRemove(h)) |kv| {
        var e = kv.value;
        e.deinit();
    }
    if (o.inflight) |d| if (std.meta.eql(d, h)) {
        o.req.cancel();
        o.inflight = null;
    };
}

/// When `tick` next needs to run, if timed.
pub fn nextDue(o: *const OutlineProvider) ?u64 {
    var best: ?u64 = null;
    var it = o.entries.valueIterator();
    while (it.next()) |e| if (e.due_ms) |d| {
        best = if (best) |b| @min(b, d) else d;
    };
    return best;
}

/// Sends due requests and takes answers; true when an outline changed.
pub fn tick(o: *OutlineProvider, now_ms: u64) bool {
    var changed = false;
    if (o.inflight) |h| for (o.req.take()) |a| {
        if (a.index != 0) continue;
        o.inflight = null;
        if (o.onAnswer(h, a)) {
            changed = true;
            o.notify(h);
        }
        break;
    };
    if (o.inflight != null) return changed;
    var it = o.entries.iterator();
    while (it.next()) |kv| {
        const e = kv.value_ptr;
        const due = e.due_ms orelse continue;
        if (now_ms < due) continue;
        e.due_ms = null;
        const h = kv.key_ptr.*;
        const doc = o.mgr.docs.get(h) orelse continue;
        e.asked = doc.version;
        if (o.req.available(h)) {
            if ((o.req.ask(h, 0, .{}) catch 0) > 0) {
                o.inflight = h;
                return changed;
            }
        }
        // No server: the structure stands in.
        if (o.fromStructure(h, doc)) {
            changed = true;
            o.notify(h);
        }
    }
    return changed;
}

fn setBase(o: *OutlineProvider, h: DocHandle, out: Outline) void {
    const e = o.entries.getPtr(h) orelse {
        var x = out;
        x.deinit();
        return;
    };
    if (e.base) |*b| b.deinit();
    if (e.mapped) |*m| m.deinit();
    e.mapped = null;
    e.base = out;
}

fn onAnswer(o: *OutlineProvider, h: DocHandle, a: *const Req.Answer) bool {
    const doc = o.mgr.docs.get(h) orelse return false;
    const v = switch (a.result) {
        .ok => |x| x.value,
        else => return o.fromStructure(h, doc),
    };
    // Positions are only meaningful in the text they were computed for.
    if (a.version != doc.version) {
        if (o.entries.getPtr(h)) |e| {
            e.asked = null;
            if (e.due_ms == null) e.due_ms = 0;
        }
        return false;
    }
    var out: Outline = .{ .arena = .init(o.gpa), .version = doc.version, .roots = &.{}, .source = .lsp };
    errdefer out.deinit();
    var m: position.Mapper = .{ .gpa = o.gpa, .tree = &doc.tree, .enc = position.encodingOf(a.client.encoding()) };
    defer m.deinit();
    out.roots = (if (v) |res| switch (res) {
        .document_symbol_array => |ds| fromHierarchy(out.arena.allocator(), &m, ds),
        .symbol_information_array => |si| fromFlat(out.arena.allocator(), &m, si),
    } else @as(anyerror![]const SymbolNode, &.{})) catch {
        out.deinit();
        return false;
    };
    o.setBase(h, out);
    return true;
}

fn fromHierarchy(a: Allocator, m: *position.Mapper, ds: []const protocol.DocumentSymbol) ![]const SymbolNode {
    const out = try a.alloc(SymbolNode, ds.len);
    for (ds, out) |d, *n| n.* = .{
        .name = try a.dupe(u8, d.name),
        .detail = if (d.detail) |x| try a.dupe(u8, x) else null,
        .kind = d.kind,
        .deprecated = isDeprecated(d.tags, d.deprecated),
        .range = try m.toRange(d.range),
        .selection = try m.toRange(d.selectionRange),
        .children = try fromHierarchy(a, m, d.children orelse &.{}),
    };
    return out;
}

fn isDeprecated(tags: ?[]const protocol.SymbolTag, flag: ?bool) bool {
    if (flag orelse false) return true;
    for (tags orelse &.{}) |t| if (t == .Deprecated) return true;
    return false;
}

/// A node with its parent, before the tree is built.
const Tmp = struct { node: SymbolNode, parent: ?u32 = null };

fn fromFlat(a: Allocator, m: *position.Mapper, si: []const protocol.SymbolInformation) ![]const SymbolNode {
    const tmp = try a.alloc(Tmp, si.len);
    for (si, tmp) |s, *t| {
        const r = try m.toRange(s.location.range);
        t.* = .{ .node = .{
            .name = try a.dupe(u8, s.name),
            .kind = s.kind,
            .deprecated = isDeprecated(s.tags, s.deprecated),
            .range = r,
            .selection = r,
            .container = if (s.containerName) |c| try a.dupe(u8, c) else null,
        } };
    }
    return nestByContainment(a, tmp);
}

fn byStart(_: void, x: Tmp, y: Tmp) bool {
    if (x.node.range.start != y.node.range.start) return x.node.range.start < y.node.range.start;
    return x.node.range.end > y.node.range.end;
}

/// Sorts by start (outer first) and nests each node in the innermost
/// earlier node containing it.
pub fn nestByContainment(a: Allocator, tmp: []Tmp) ![]const SymbolNode {
    std.sort.block(Tmp, tmp, {}, byStart);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(a);
    for (tmp, 0..) |*t, i| {
        while (stack.items.len > 0) {
            const top = tmp[stack.items[stack.items.len - 1]].node.range;
            if (t.node.range.start >= top.start and t.node.range.end <= top.end) break;
            _ = stack.pop();
        }
        t.parent = if (stack.items.len > 0) stack.items[stack.items.len - 1] else null;
        try stack.append(a, @intCast(i));
    }
    return materialize(a, tmp, null);
}

/// The children of `parent` (document order kept), recursively. Nodes
/// come before their descendants in `tmp`.
fn materialize(a: Allocator, tmp: []const Tmp, parent: ?u32) ![]const SymbolNode {
    var n: usize = 0;
    for (tmp) |t| if (t.parent == parent) {
        n += 1;
    };
    const out = try a.alloc(SymbolNode, n);
    var k: usize = 0;
    for (tmp, 0..) |t, i| if (t.parent == parent) {
        out[k] = t.node;
        out[k].children = try materialize(a, tmp, @intCast(i));
        k += 1;
    };
    return out;
}

fn fromStructure(o: *OutlineProvider, h: DocHandle, doc: *const Document) bool {
    const lk = o.structure orelse return false;
    var st = lk.f(lk.ctx, h, o.gpa) orelse return false;
    defer st.deinit();
    var out: Outline = .{ .arena = .init(o.gpa), .version = st.version, .roots = &.{}, .source = .structure };
    out.roots = structureTree(out.arena.allocator(), st.outline()) catch {
        out.deinit();
        return false;
    };
    _ = doc;
    o.setBase(h, out);
    return true;
}

/// The structure's symbols (parents first) as a tree.
pub fn structureTree(a: Allocator, syms: []const zg_syntax.Symbol) ![]const SymbolNode {
    const tmp = try a.alloc(Tmp, syms.len);
    for (syms, tmp) |s, *t| t.* = .{
        .node = .{
            .name = try a.dupe(u8, s.name),
            .kind = @enumFromInt(s.kind.lspKind()),
            .range = .{ .start = s.range.start, .end = s.range.end },
            .selection = .{ .start = s.selection.start, .end = s.selection.end },
        },
        .parent = s.parent,
    };
    return materialize(a, tmp, null);
}

/// The outline of `h` at its current version, if any.
pub fn get(o: *OutlineProvider, h: DocHandle) ?*const Outline {
    const e = o.entries.getPtr(h) orelse return null;
    const doc = o.mgr.docs.get(h) orelse return null;
    const b = &(e.base orelse return null);
    if (b.version == doc.version) return b;
    if (e.mapped) |*m| if (m.version == doc.version) return m;
    if (e.mapped) |*m| m.deinit();
    e.mapped = null;
    var out: Outline = .{ .arena = .init(o.gpa), .version = doc.version, .roots = &.{}, .source = b.source };
    out.roots = mapNodes(out.arena.allocator(), doc, b.version, b.roots) catch {
        out.deinit();
        return null;
    };
    e.mapped = out;
    return &e.mapped.?;
}

fn mapNodes(a: Allocator, doc: *const Document, from: u64, nodes: []const SymbolNode) ![]const SymbolNode {
    var out: std.ArrayList(SymbolNode) = .empty;
    for (nodes) |n| {
        // A body edited inside keeps its symbol; an edited name drops it.
        const r = position.mapResultRange(doc, from, n.range, .shrink) orelse continue;
        const s = position.mapResultRange(doc, from, n.selection, .drop) orelse continue;
        var c = n;
        c.range = r;
        c.selection = s;
        c.children = try mapNodes(a, doc, from, n.children);
        try out.append(a, c);
    }
    return out.items;
}
