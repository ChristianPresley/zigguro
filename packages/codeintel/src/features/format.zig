//! Formatting (E07.F04.S02.T03): the whole document, ranges, and on
//! type. The first routed server with the capability formats (routing
//! sends formatting to one server only).
//!
//! `ranges` uses `textDocument/rangesFormatting` (3.18) when the server
//! has `rangesSupport`, else one `rangeFormatting` per range, last range
//! first, so earlier ranges stay where they were. `onType` asks on the
//! server's trigger characters. Every result is applied through the
//! workspace edit engine as a single-document edit, and only when the
//! document is still at the version the request was made for (an answer
//! for older text is dropped).

const FormatService = @This();
const std = @import("std");
const zg_core = @import("zg_core");
const zg_lsp = @import("zg_lsp");
const zg_editor = @import("zg_editor");
const Manager = @import("../Manager.zig");
const requester = @import("request.zig");
const position = @import("position.zig");
const Engine = @import("../edits/Engine.zig");
const plan_mod = @import("../edits/plan.zig");

const Allocator = std.mem.Allocator;
const protocol = zg_lsp.protocol;
const Client = zg_lsp.client.Client;
const DocHandle = zg_editor.model.api.registry.DocHandle;
const ByteRange = position.ByteRange;
const DocReq = requester.Requester(.@"textDocument/formatting", .formatting);
const RangeReq = requester.Requester(.@"textDocument/rangeFormatting", .range_formatting);
const RangesReq = requester.Requester(.@"textDocument/rangesFormatting", .ranges_formatting);
const TypeReq = requester.Requester(.@"textDocument/onTypeFormatting", .on_type_formatting);

/// The formatting options of a document (its tab size and so on).
pub const OptionsLookup = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, h: DocHandle) protocol.FormattingOptions,
};

pub const default_options: protocol.FormattingOptions = .{ .tabSize = 4, .insertSpaces = true };

const Job = union(enum) {
    idle,
    document: struct { h: DocHandle, origin: Engine.Origin },
    ranges: struct { h: DocHandle, origin: Engine.Origin },
    /// Per-range fallback: `left` ranges still to format (the last one is
    /// in flight).
    range: struct { h: DocHandle, origin: Engine.Origin, left: usize },
    on_type: struct { h: DocHandle },
};

gpa: Allocator,
mgr: *Manager,
engine: *Engine,
options: ?OptionsLookup = null,
doc_req: DocReq,
range_req: RangeReq,
ranges_req: RangesReq,
type_req: TypeReq,
job: Job = .idle,
/// The per-range fallback's ranges, sorted by start.
queue: std.ArrayList(ByteRange) = .empty,
/// The last failure's message, until the next request or `tick`.
failure: std.ArrayList(u8) = .empty,
/// Bumped when a job finishes.
generation: u64 = 0,
/// Edits applied (tests).
applied: u32 = 0,

pub fn init(mgr: *Manager, engine: *Engine, waker: zg_core.runtime.Waker) FormatService {
    return .{
        .gpa = mgr.gpa,
        .mgr = mgr,
        .engine = engine,
        .doc_req = .init(mgr, waker),
        .range_req = .init(mgr, waker),
        .ranges_req = .init(mgr, waker),
        .type_req = .init(mgr, waker),
    };
}

/// Call after `Manager.deinit`.
pub fn deinit(f: *FormatService) void {
    f.doc_req.deinit();
    f.range_req.deinit();
    f.ranges_req.deinit();
    f.type_req.deinit();
    f.queue.deinit(f.gpa);
    f.failure.deinit(f.gpa);
}

fn optionsOf(f: *FormatService, h: DocHandle) protocol.FormattingOptions {
    return if (f.options) |o| o.f(o.ctx, h) else default_options;
}

/// Whether a server can format all of `h`.
pub fn canFormat(f: *FormatService, h: DocHandle) bool {
    return f.doc_req.available(h);
}

/// Whether a server can format ranges of `h`.
pub fn canFormatRanges(f: *FormatService, h: DocHandle) bool {
    return f.ranges_req.available(h) or f.range_req.available(h);
}

/// Whether a job is in flight.
pub fn busy(f: *const FormatService) bool {
    return f.job != .idle;
}

/// Forgets the job in flight.
pub fn cancel(f: *FormatService) void {
    f.doc_req.cancel();
    f.range_req.cancel();
    f.ranges_req.cancel();
    f.type_req.cancel();
    f.queue.clearRetainingCapacity();
    f.finish();
}

fn finish(f: *FormatService) void {
    if (f.job == .idle) return;
    f.job = .idle;
    f.generation += 1;
}

fn fail(f: *FormatService, comptime fmt: []const u8, args: anytype) void {
    f.failure.clearRetainingCapacity();
    f.failure.print(f.gpa, fmt, args) catch {};
}

/// Formats all of `h`.
pub fn document(f: *FormatService, h: DocHandle, origin: Engine.Origin) !void {
    f.cancel();
    f.failure.clearRetainingCapacity();
    if (try f.doc_req.ask(h, 0, .{ .options = f.optionsOf(h) }) == 0) return f.fail("No language server can format this file.", .{});
    f.job = .{ .document = .{ .h = h, .origin = origin } };
}

/// Formats byte ranges `rs` of `h` ("format selection", "format modified
/// lines").
pub fn ranges(f: *FormatService, h: DocHandle, rs: []const ByteRange, origin: Engine.Origin) !void {
    f.cancel();
    f.failure.clearRetainingCapacity();
    if (rs.len == 0) return;
    const opts = f.optionsOf(h);
    if (f.ranges_req.available(h)) {
        const doc = f.mgr.docs.get(h) orelse return;
        var cs: [1]*Client = undefined;
        if (f.mgr.clientsFor(h, .ranges_formatting, &cs) == 0) return;
        var m: position.Mapper = .{ .gpa = f.gpa, .tree = &doc.tree, .enc = position.encodingOf(cs[0].encoding()) };
        defer m.deinit();
        const prs = try f.gpa.alloc(protocol.Range, rs.len);
        defer f.gpa.free(prs);
        for (rs, prs) |r, *p| p.* = try m.fromRange(.{ .start = @min(r.start, doc.len()), .end = @min(r.end, doc.len()) });
        if (try f.ranges_req.ask(h, 0, .{ .ranges = prs, .options = opts }) > 0) {
            f.job = .{ .ranges = .{ .h = h, .origin = origin } };
            return;
        }
    }
    if (!f.range_req.available(h)) return f.fail("No language server can format a selection of this file.", .{});
    try f.queue.appendSlice(f.gpa, rs);
    std.sort.block(ByteRange, f.queue.items, {}, struct {
        fn lt(_: void, a: ByteRange, b: ByteRange) bool {
            return a.start < b.start;
        }
    }.lt);
    f.job = .{ .range = .{ .h = h, .origin = origin, .left = f.queue.items.len } };
    try f.nextRange();
}

fn nextRange(f: *FormatService) !void {
    const j = &f.job.range;
    if (j.left == 0) return f.finish();
    j.left -= 1;
    const r = f.queue.items[j.left];
    if (try f.range_req.askRange(j.h, r, .{ .options = f.optionsOf(j.h) }) == 0) f.finish();
}

/// Whether typing `ch` in `h` asks for on-type formatting.
pub fn triggers(f: *FormatService, h: DocHandle, ch: u21) bool {
    var cs: [1]*Client = undefined;
    if (f.mgr.clientsFor(h, .on_type_formatting, &cs) == 0) return false;
    const o = (cs[0].caps() orelse return false).raw.documentOnTypeFormattingProvider orelse return false;
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(ch, &buf) catch return false;
    if (std.mem.eql(u8, o.firstTriggerCharacter, buf[0..n])) return true;
    for (o.moreTriggerCharacter orelse &.{}) |t| if (std.mem.eql(u8, t, buf[0..n])) return true;
    return false;
}

/// `ch` was typed in `h`, the caret now at byte `pos`.
pub fn onType(f: *FormatService, h: DocHandle, ch: u21, pos: u64) !void {
    if (!f.triggers(h, ch)) return;
    // A whole-file or range format in flight wins.
    if (f.job != .idle and f.job != .on_type) return;
    f.type_req.cancel();
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(ch, &buf) catch return;
    if (try f.type_req.ask(h, pos, .{ .ch = buf[0..n], .options = f.optionsOf(h) }) > 0) f.job = .{ .on_type = .{ .h = h } };
}

/// Applies answers; true when a job finished.
pub fn tick(f: *FormatService) bool {
    const g = f.generation;
    switch (f.job) {
        .idle => {},
        .document => |j| for (f.doc_req.take()) |a| {
            f.onEdits(j.h, a.version, a.client, j.origin, "Format Document", a.result);
            f.finish();
            break;
        },
        .ranges => |j| for (f.ranges_req.take()) |a| {
            f.onEdits(j.h, a.version, a.client, j.origin, "Format Selection", a.result);
            f.finish();
            break;
        },
        .range => |j| for (f.range_req.take()) |a| {
            f.onEdits(j.h, a.version, a.client, j.origin, "Format Selection", a.result);
            if (f.failure.items.len > 0) {
                f.queue.clearRetainingCapacity();
                f.finish();
            } else f.nextRange() catch f.finish();
            break;
        },
        .on_type => |j| for (f.type_req.take()) |a| {
            // Typing goes on meanwhile: a stale answer is dropped quietly.
            f.onEdits(j.h, a.version, a.client, .user, "Format on Type", a.result);
            f.failure.clearRetainingCapacity();
            f.finish();
            break;
        },
    }
    return f.generation != g;
}

fn onEdits(f: *FormatService, h: DocHandle, version: u64, c: *Client, origin: Engine.Origin, label: []const u8, result: anytype) void {
    const edits: []const protocol.TextEdit = switch (result) {
        .ok => |o| o.value orelse return,
        .lsp_error => |e| return f.fail("{s}", .{e.message}),
        .canceled, .content_modified => return,
        else => return f.fail("Formatting failed ({s}).", .{@tagName(result)}),
    };
    const doc = f.mgr.docs.get(h) orelse return;
    if (doc.version != version) return f.fail("The file changed while it was being formatted.", .{});
    const s = serverOf(f.mgr, c) orelse return f.fail("The language server stopped.", .{});
    const out = applyTextEdits(f.engine, f.mgr, h, s, edits, label, origin) catch |e| return f.fail("{s} failed: {s}.", .{ label, plan_mod.reason(e) });
    switch (out) {
        .failed => |x| f.fail("{s} failed: {s}.", .{ label, x.reason }),
        else => f.applied += 1,
    }
}

pub fn serverOf(m: *Manager, c: *Client) ?*Manager.Server {
    for (m.serverList()) |s| if (s.client == c) return s;
    return null;
}

/// Applies a server's `edits` to `h` through the engine, as one
/// document's edit.
pub fn applyTextEdits(engine: *Engine, m: *Manager, h: DocHandle, s: *Manager.Server, edits: []const protocol.TextEdit, label: []const u8, origin: Engine.Origin) !Engine.Outcome {
    if (edits.len == 0) return .{ .applied = .{ .undo_id = 0 } };
    const uri = m.docs.uri(h) orelse return error.NotOpen;
    var changes: std.json.ArrayHashMap([]const protocol.TextEdit) = .{};
    defer changes.map.deinit(m.gpa);
    try changes.map.put(m.gpa, uri, edits);
    const edit: protocol.WorkspaceEdit = .{ .changes = changes };
    var why: plan_mod.Failure = .{ .index = 0, .err = error.Unknown };
    var p = engine.plan(&edit, Engine.sourceOf(s), label, &why) catch return why.err;
    defer p.deinit();
    return engine.apply(&p, origin, .auto);
}
