//! Rename (E07.F04.S02.T02): `begin` asks `textDocument/prepareRename`
//! when the server supports it (a range, a range with a placeholder, or
//! "default behavior": the word at the caret), else takes the word at the
//! caret; a null answer or an error is shown and no input opens. `commit`
//! sends `textDocument/rename` with the new name and applies the edit
//! through the workspace edit engine (`.force_review` previews it in the
//! review queue).

const RenameService = @This();
const std = @import("std");
const zg_core = @import("zg_core");
const zg_lsp = @import("zg_lsp");
const zg_editor = @import("zg_editor");
const Manager = @import("../Manager.zig");
const requester = @import("request.zig");
const position = @import("position.zig");
const HoverService = @import("hover.zig");
const Engine = @import("../edits/Engine.zig");
const plan_mod = @import("../edits/plan.zig");

const Allocator = std.mem.Allocator;
const protocol = zg_lsp.protocol;
const Client = zg_lsp.client.Client;
const DocHandle = zg_editor.model.api.registry.DocHandle;
const ByteRange = position.ByteRange;
const Prep = requester.Requester(.@"textDocument/prepareRename", .prepare_rename);
const Ren = requester.Requester(.@"textDocument/rename", .rename);

pub const State = union(enum) {
    idle,
    preparing: struct { h: DocHandle },
    /// The input can open over `range` (bytes at `version`), prefilled
    /// with `placeholder`.
    ready: struct { h: DocHandle, range: ByteRange, version: u64, placeholder: []const u8 },
    renaming: struct { h: DocHandle, mode: Engine.Mode, origin: Engine.Origin },
    /// A message to show.
    failed: []const u8,
    done: Engine.Outcome,
};

gpa: Allocator,
mgr: *Manager,
engine: *Engine,
prep: Prep,
ren: Ren,
state: State = .idle,
/// Owns the placeholder or the failure message.
text: std.ArrayList(u8) = .empty,
/// Bumped when `state` changes.
generation: u64 = 0,

pub fn init(mgr: *Manager, engine: *Engine, waker: zg_core.runtime.Waker) RenameService {
    return .{ .gpa = mgr.gpa, .mgr = mgr, .engine = engine, .prep = .init(mgr, waker), .ren = .init(mgr, waker) };
}

/// Call after `Manager.deinit`.
pub fn deinit(r: *RenameService) void {
    r.prep.deinit();
    r.ren.deinit();
    r.text.deinit(r.gpa);
}

fn set(r: *RenameService, st: State) void {
    r.state = st;
    r.generation += 1;
}

fn fail(r: *RenameService, comptime fmt: []const u8, args: anytype) void {
    r.text.clearRetainingCapacity();
    r.text.print(r.gpa, fmt, args) catch {};
    r.set(.{ .failed = r.text.items });
}

/// Whether a server can rename in `h`.
pub fn available(r: *RenameService, h: DocHandle) bool {
    return r.ren.available(h);
}

/// Starts a rename at byte `offset` of `h`.
pub fn begin(r: *RenameService, h: DocHandle, offset: u64) !void {
    r.cancel();
    if (!r.ren.available(h)) return r.fail("No language server can rename here.", .{});
    if (r.prep.available(h)) {
        if (try r.prep.ask(h, offset, .{}) > 0) return r.set(.{ .preparing = .{ .h = h } });
    }
    try r.readyAt(h, HoverService.wordAt(r.mgr.docs.get(h) orelse return, offset));
}

fn readyAt(r: *RenameService, h: DocHandle, range: ByteRange) !void {
    const doc = r.mgr.docs.get(h) orelse return r.set(.idle);
    if (range.end <= range.start) return r.fail("The element can't be renamed.", .{});
    r.text.clearRetainingCapacity();
    const t = try doc.tree.copyRange(r.gpa, range);
    defer r.gpa.free(t);
    try r.text.appendSlice(r.gpa, t);
    r.set(.{ .ready = .{ .h = h, .range = range, .version = doc.version, .placeholder = r.text.items } });
}

/// Sends the rename (state `.ready`).
pub fn commit(r: *RenameService, new_name: []const u8, mode: Engine.Mode, origin: Engine.Origin) !void {
    const st = switch (r.state) {
        .ready => |x| x,
        else => return error.NotReady,
    };
    const doc = r.mgr.docs.get(st.h) orelse return r.set(.idle);
    const range = position.mapResultRange(doc, st.version, st.range, .shrink) orelse return r.fail("The symbol was edited away.", .{});
    if (try r.ren.ask(st.h, range.start, .{ .newName = new_name }) == 0) return r.fail("No language server can rename here.", .{});
    r.set(.{ .renaming = .{ .h = st.h, .mode = mode, .origin = origin } });
}

/// Ends the rename (Escape).
pub fn cancel(r: *RenameService) void {
    r.prep.cancel();
    r.ren.cancel();
    if (r.state != .idle) r.set(.idle);
}

fn serverOf(r: *RenameService, c: *Client) ?*Manager.Server {
    for (r.mgr.serverList()) |s| if (s.client == c) return s;
    return null;
}

/// Applies answers; true when `state` changed.
pub fn tick(r: *RenameService) bool {
    const g = r.generation;
    switch (r.state) {
        .preparing => |p| for (r.prep.take()) |a| {
            if (a.index != 0) continue;
            r.onPrepared(p.h, a);
            break;
        },
        .renaming => |rn| for (r.ren.take()) |a| {
            if (a.index != 0) continue;
            r.onRenamed(rn.mode, rn.origin, a);
            break;
        },
        else => {},
    }
    return r.generation != g;
}

fn onPrepared(r: *RenameService, h: DocHandle, a: *const Prep.Answer) void {
    const doc = r.mgr.docs.get(h) orelse return r.set(.idle);
    const v = switch (a.result) {
        .ok => |o| o.value,
        .lsp_error => |e| return r.fail("{s}", .{e.message}),
        else => return r.fail("The element can't be renamed.", .{}),
    };
    const res = v orelse return r.fail("The element can't be renamed.", .{});
    var m: position.Mapper = .{ .gpa = r.gpa, .tree = &doc.tree, .enc = position.encodingOf(a.client.encoding()) };
    defer m.deinit();
    const range, const placeholder: ?[]const u8 = switch (res) {
        .range => |rg| .{ m.toRange(rg) catch return r.fail("Out of memory.", .{}), null },
        .prepare_rename_placeholder => |pp| .{ m.toRange(pp.range) catch return r.fail("Out of memory.", .{}), pp.placeholder },
        .prepare_rename_default_behavior => .{ HoverService.wordAt(doc, a.offset), null },
    };
    // The answer is for the version asked about: map it to now.
    const now = position.mapResultRange(doc, a.version, range, .shrink) orelse return r.fail("The symbol was edited away.", .{});
    if (placeholder) |ph| {
        r.text.clearRetainingCapacity();
        r.text.appendSlice(r.gpa, ph) catch {};
        r.set(.{ .ready = .{ .h = h, .range = now, .version = doc.version, .placeholder = r.text.items } });
    } else r.readyAt(h, now) catch r.fail("Out of memory.", .{});
}

fn onRenamed(r: *RenameService, mode: Engine.Mode, origin: Engine.Origin, a: *const Ren.Answer) void {
    const v = switch (a.result) {
        .ok => |o| o.value,
        .lsp_error => |e| return r.fail("{s}", .{e.message}),
        else => return r.fail("Rename failed ({s}).", .{@tagName(a.result)}),
    };
    const edit = v orelse return r.fail("No result.", .{});
    const s = r.serverOf(a.client) orelse return r.fail("The language server stopped.", .{});
    var why: plan_mod.Failure = .{ .index = 0, .err = error.Unknown };
    var p = r.engine.plan(&edit, Engine.sourceOf(s), "Rename", &why) catch
        return r.fail("Rename failed: {s}.", .{plan_mod.reason(why.err)});
    defer p.deinit();
    const out = r.engine.apply(&p, origin, mode) catch |e| return r.fail("Rename failed: {s}.", .{plan_mod.reason(e)});
    switch (out) {
        .failed => |f| r.fail("Rename failed: {s}.", .{f.reason}),
        else => r.set(.{ .done = out }),
    }
}
