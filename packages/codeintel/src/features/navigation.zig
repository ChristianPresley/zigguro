//! Navigation (E07.F04.S01.T01): go to definition, declaration, type
//! definition and implementation, and find references, asked of every
//! server routed for the request. Answers (`Location`, `Location[]` or
//! `LocationLink[]`; links use `targetSelectionRange` for the caret and
//! `targetRange` for context) become `Target`s, united across servers
//! (duplicates by URI and start dropped) and sorted: the asking document
//! first, then by path, then by position.
//!
//! Targets keep LSP positions with their server's encoding: most are in
//! files that are not open, so the editor converts them to bytes once it
//! has the text (`Target.byteIn`). Results for an older version of the
//! asking document are dropped; asking again forgets the last request.
//!
//! `History` is the back/forward list of places (file, offset) the
//! editor jumped from and to.

const NavService = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const zg_core = @import("zg_core");
const zg_lsp = @import("zg_lsp");
const zg_editor = @import("zg_editor");
const Manager = @import("../Manager.zig");
const position = @import("position.zig");
const request = @import("request.zig");

const protocol = zg_lsp.protocol;
const DocHandle = zg_editor.model.api.registry.DocHandle;

pub const Kind = enum { definition, declaration, type_definition, implementation, references };

/// One place to go.
pub const Target = struct {
    /// The URI as the server sent it.
    uri: []const u8,
    /// Its file path, when it is a `file:` URI.
    path: ?[]const u8,
    /// Where the caret goes.
    selection: protocol.Range,
    /// The whole symbol (for previews).
    range: protocol.Range,
    /// Columns are in this encoding.
    enc: position.Encoding,

    /// The byte offset of `p` in `line_text` (the target line's text).
    pub fn columnIn(t: Target, line_text: []const u8) usize {
        return zg_core.utf8.columnToByte(line_text, t.selection.start.character, t.enc);
    }
};

/// What a request found.
pub const Results = struct {
    kind: Kind,
    /// The document asked from.
    origin: DocHandle,
    targets: []const Target,
    /// Every server answered.
    complete: bool,
};

const Def = request.Requester(.@"textDocument/definition", .definition);
const Decl = request.Requester(.@"textDocument/declaration", .declaration);
const TypeDef = request.Requester(.@"textDocument/typeDefinition", .type_definition);
const Impl = request.Requester(.@"textDocument/implementation", .implementation);
const Refs = request.Requester(.@"textDocument/references", .references);

gpa: Allocator,
mgr: *Manager,
def: Def,
decl: Decl,
type_def: TypeDef,
impl: Impl,
refs: Refs,
arena: std.heap.ArenaAllocator,
targets: std.ArrayList(Target) = .empty,
asked: ?struct { kind: Kind, h: DocHandle, version: u64, uri: []const u8 } = null,
/// Bumped when `results` change.
generation: u64 = 0,

pub fn init(n: *NavService, mgr: *Manager, waker: zg_core.runtime.Waker) void {
    n.* = .{
        .gpa = mgr.gpa,
        .mgr = mgr,
        .def = .init(mgr, waker),
        .decl = .init(mgr, waker),
        .type_def = .init(mgr, waker),
        .impl = .init(mgr, waker),
        .refs = .init(mgr, waker),
        .arena = .init(mgr.gpa),
    };
}

/// Call after `Manager.deinit`.
pub fn deinit(n: *NavService) void {
    n.def.deinit();
    n.decl.deinit();
    n.type_def.deinit();
    n.impl.deinit();
    n.refs.deinit();
    n.targets.deinit(n.gpa);
    n.arena.deinit();
}

/// Whether a server provides `kind` for `h`.
pub fn available(n: *NavService, kind: Kind, h: DocHandle) bool {
    return switch (kind) {
        .definition => n.def.available(h),
        .declaration => n.decl.available(h),
        .type_definition => n.type_def.available(h),
        .implementation => n.impl.available(h),
        .references => n.refs.available(h),
    };
}

/// Asks for `kind` at byte `offset` of `h` (references include the
/// declaration when `include_decl`). Returns the servers asked.
pub fn go(n: *NavService, kind: Kind, h: DocHandle, offset: u64, include_decl: bool) !u8 {
    n.cancel();
    const doc = n.mgr.docs.get(h) orelse return 0;
    const uri = n.mgr.docs.uri(h) orelse return 0;
    n.asked = .{ .kind = kind, .h = h, .version = doc.version, .uri = try n.arena.allocator().dupe(u8, uri) };
    return switch (kind) {
        .definition => n.def.ask(h, offset, .{}),
        .declaration => n.decl.ask(h, offset, .{}),
        .type_definition => n.type_def.ask(h, offset, .{}),
        .implementation => n.impl.ask(h, offset, .{}),
        .references => n.refs.ask(h, offset, .{ .context = protocol.ReferenceContext{ .includeDeclaration = include_decl } }),
    };
}

/// Forgets the request and its results.
pub fn cancel(n: *NavService) void {
    n.def.cancel();
    n.decl.cancel();
    n.type_def.cancel();
    n.impl.cancel();
    n.refs.cancel();
    const had = n.asked != null or n.targets.items.len > 0;
    n.asked = null;
    n.targets.clearRetainingCapacity();
    _ = n.arena.reset(.retain_capacity);
    if (had) n.generation += 1;
}

/// The current request's results, once a server answered.
pub fn results(n: *const NavService) ?Results {
    const a = n.asked orelse return null;
    return .{ .kind = a.kind, .origin = a.h, .targets = n.targets.items, .complete = n.complete() };
}

fn complete(n: *const NavService) bool {
    const a = n.asked orelse return true;
    return switch (a.kind) {
        .definition => n.def.done(),
        .declaration => n.decl.done(),
        .type_definition => n.type_def.done(),
        .implementation => n.impl.done(),
        .references => n.refs.done(),
    };
}

/// Applies answers; true when `results` changed (also when the last
/// server answered, so callers can act on complete results).
pub fn tick(n: *NavService) bool {
    const a = n.asked orelse return false;
    const before = n.targets.items.len;
    const was_complete = n.complete();
    switch (a.kind) {
        .definition => n.collect(Def, &n.def),
        .declaration => n.collect(Decl, &n.decl),
        .type_definition => n.collect(TypeDef, &n.type_def),
        .implementation => n.collect(Impl, &n.impl),
        .references => n.collect(Refs, &n.refs),
    }
    const changed = n.targets.items.len != before or (!was_complete and n.complete());
    if (n.targets.items.len != before) n.sortTargets();
    if (changed) n.generation += 1;
    return changed;
}

fn collect(n: *NavService, comptime R: type, r: *R) void {
    const a = n.asked.?;
    for (r.take()) |ans| {
        const doc = n.mgr.docs.get(ans.h) orelse continue;
        if (doc.version != a.version or ans.version != a.version) continue;
        const v = switch (ans.result) {
            .ok => |o| o.value orelse continue,
            else => continue,
        };
        const enc = position.encodingOf(ans.client.encoding());
        n.addAll(v, enc) catch continue;
    }
}

fn addAll(n: *NavService, v: anytype, enc: position.Encoding) Allocator.Error!void {
    const T = @TypeOf(v);
    if (T == []const protocol.Location) {
        for (v) |l| try n.add(l.uri, l.range, l.range, enc);
        return;
    }
    switch (v) {
        inline else => |inner| {
            const I = @TypeOf(inner);
            if (I == []const protocol.LocationLink) {
                for (inner) |l| try n.add(l.targetUri, l.targetSelectionRange, l.targetRange, enc);
            } else switch (inner) {
                .location => |l| try n.add(l.uri, l.range, l.range, enc),
                .location_array => |ls| for (ls) |l| try n.add(l.uri, l.range, l.range, enc),
            }
        },
    }
}

fn add(n: *NavService, uri: []const u8, sel: protocol.Range, range: protocol.Range, enc: position.Encoding) Allocator.Error!void {
    for (n.targets.items) |t| {
        if (std.mem.eql(u8, t.uri, uri) and t.selection.start.line == sel.start.line and t.selection.start.character == sel.start.character) return;
    }
    const a = n.arena.allocator();
    const path: ?[]const u8 = zg_lsp.uri.pathFromUri(a, uri) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    try n.targets.append(n.gpa, .{ .uri = try a.dupe(u8, uri), .path = path, .selection = sel, .range = range, .enc = enc });
}

fn sortTargets(n: *NavService) void {
    const origin = n.asked.?.uri;
    std.mem.sort(Target, n.targets.items, origin, struct {
        fn lt(o: []const u8, x: Target, y: Target) bool {
            const xo = std.mem.eql(u8, x.uri, o);
            const yo = std.mem.eql(u8, y.uri, o);
            if (xo != yo) return xo;
            switch (std.mem.order(u8, x.path orelse x.uri, y.path orelse y.uri)) {
                .lt => return true,
                .gt => return false,
                .eq => {},
            }
            if (x.selection.start.line != y.selection.start.line) return x.selection.start.line < y.selection.start.line;
            return x.selection.start.character < y.selection.start.character;
        }
    }.lt);
}

/// Places the editor jumped between, for back and forward (Alt+Left,
/// Alt+Right). Offsets are bytes in the file at the time; the editor
/// clamps them.
pub const History = struct {
    gpa: Allocator,
    entries: std.ArrayList(Entry) = .empty,
    /// Entries before `pos` are behind; `pos` and after are ahead.
    pos: usize = 0,

    pub const Entry = struct { path: []u8, offset: u64 };
    pub const Loc = struct { path: []const u8, offset: u64 };

    /// Most places kept.
    pub const max = 50;

    pub fn init(gpa: Allocator) History {
        return .{ .gpa = gpa };
    }

    pub fn deinit(h: *History) void {
        for (h.entries.items) |e| h.gpa.free(e.path);
        h.entries.deinit(h.gpa);
    }

    /// Records a jump from `from` (the forward list is dropped).
    pub fn push(h: *History, from: Loc) Allocator.Error!void {
        for (h.entries.items[h.pos..]) |e| h.gpa.free(e.path);
        h.entries.shrinkRetainingCapacity(h.pos);
        if (h.entries.items.len > 0) {
            const last = h.entries.items[h.entries.items.len - 1];
            if (std.mem.eql(u8, last.path, from.path) and last.offset == from.offset) return;
        }
        if (h.entries.items.len == max) {
            h.gpa.free(h.entries.orderedRemove(0).path);
        }
        try h.entries.append(h.gpa, .{ .path = try h.gpa.dupe(u8, from.path), .offset = from.offset });
        h.pos = h.entries.items.len;
    }

    /// The place before `here` (which becomes the way forward), if any.
    pub fn back(h: *History, here: Loc) Allocator.Error!?Loc {
        if (h.pos == 0) return null;
        if (h.pos == h.entries.items.len) {
            // Remember where we were, so forward comes back here.
            try h.entries.append(h.gpa, .{ .path = try h.gpa.dupe(u8, here.path), .offset = here.offset });
        } else {
            const e = &h.entries.items[h.pos];
            if (!std.mem.eql(u8, e.path, here.path)) {
                h.gpa.free(e.path);
                e.path = try h.gpa.dupe(u8, here.path);
            }
            e.offset = here.offset;
        }
        h.pos -= 1;
        const e = h.entries.items[h.pos];
        return .{ .path = e.path, .offset = e.offset };
    }

    /// The place after the current one, if any.
    pub fn forward(h: *History) ?Loc {
        if (h.pos + 1 >= h.entries.items.len) return null;
        h.pos += 1;
        const e = h.entries.items[h.pos];
        return .{ .path = e.path, .offset = e.offset };
    }
};
