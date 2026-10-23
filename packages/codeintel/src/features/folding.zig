//! Folding ranges from the language server (E07.F03.S02.T02): asked 300
//! ms after an edit, on `workspace/foldingRange/refresh` (3.18) and when
//! the server changes, and mapped to zg_syntax `FoldRange`s. While a
//! document has no server result (no server, an error, a `null` answer)
//! `folds` returns null and the editor uses its own structure; the fold
//! map keeps collapsed state by anchor, so replacing the ranges keeps what
//! the user folded.

const FoldingDriver = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const zg_lsp = @import("zg_lsp");
const zg_editor = @import("zg_editor");
const zg_syntax = @import("zg_syntax");
const Manager = @import("../Manager.zig");
const poller = @import("poller.zig");

const Client = zg_lsp.client.Client;
const protocol = zg_lsp.protocol;
const DocHandle = zg_editor.model.api.registry.DocHandle;
const M = .@"textDocument/foldingRange";

/// The ranges kept per document (we advertise `rangeLimit` 5000).
pub const range_limit = 5000;

/// One fold: lines and kind, and the text to show while folded (3.17).
pub const Fold = struct { range: zg_syntax.FoldRange, collapsed_text: ?[]const u8 = null };

const Set = struct {
    arena: std.heap.ArenaAllocator,
    folds: []const Fold,
};

pub const Options = poller.Poller(M, .folding_range).Options;

gpa: Allocator,
poll: poller.Poller(M, .folding_range),
sets: std.AutoHashMapUnmanaged(DocHandle, Set) = .empty,

/// `d` must not move once initialized (refresh listener, hooks).
pub fn init(d: *FoldingDriver, mgr: *Manager, opts: Options) Allocator.Error!void {
    d.* = .{ .gpa = mgr.gpa, .poll = .init(mgr, .{ .ctx = d, .apply = apply, .clear = clearHook }, opts) };
    try mgr.onRefresh(.{ .ctx = d, .func = onRefresh });
}

/// Call after `Manager.deinit`.
pub fn deinit(d: *FoldingDriver) void {
    d.poll.deinit();
    var it = d.sets.valueIterator();
    while (it.next()) |s| s.arena.deinit();
    d.sets.deinit(d.gpa);
}

pub fn track(d: *FoldingDriver, h: DocHandle) Allocator.Error!void {
    try d.poll.track(h);
}

pub fn untrack(d: *FoldingDriver, h: DocHandle) void {
    d.poll.untrack(h);
    d.clear(h);
}

/// Applies results, sends due requests; true when folds changed.
pub fn tick(d: *FoldingDriver) bool {
    return d.poll.tick();
}

pub fn nextDue(d: *const FoldingDriver) ?i96 {
    return d.poll.nextDue();
}

/// The server's folds for `h`, sorted by start line; null: use the
/// editor's own structure.
pub fn folds(d: *const FoldingDriver, h: DocHandle) ?[]const Fold {
    const s = d.sets.getPtr(h) orelse return null;
    return s.folds;
}

fn onRefresh(ctx: *anyopaque, _: *Manager.Server, f: Manager.RefreshFeature) void {
    const d: *FoldingDriver = @ptrCast(@alignCast(ctx));
    if (f == .folding_range) d.poll.refresh();
}

fn clear(d: *FoldingDriver, h: DocHandle) void {
    var kv = d.sets.fetchRemove(h) orelse return;
    kv.value.arena.deinit();
}

fn clearHook(ctx: *anyopaque, h: DocHandle) void {
    const d: *FoldingDriver = @ptrCast(@alignCast(ctx));
    d.clear(h);
}

fn apply(ctx: *anyopaque, h: DocHandle, _: *Client, value: ?[]const protocol.FoldingRange) bool {
    const d: *FoldingDriver = @ptrCast(@alignCast(ctx));
    const ranges = value orelse {
        const had = d.sets.contains(h);
        d.clear(h);
        return had;
    };
    var set: Set = .{ .arena = .init(d.gpa), .folds = &.{} };
    const out = mapRanges(set.arena.allocator(), ranges) catch {
        set.arena.deinit();
        return false;
    };
    set.folds = out;
    d.clear(h);
    d.sets.put(d.gpa, h, set) catch {
        set.arena.deinit();
        return true;
    };
    return true;
}

/// LSP ranges to folds: drops empty and inverted ranges, keeps at most
/// `range_limit`, sorts by start line (outer first on ties).
pub fn mapRanges(a: Allocator, ranges: []const protocol.FoldingRange) Allocator.Error![]const Fold {
    var out: std.ArrayList(Fold) = .empty;
    for (ranges) |r| {
        if (r.endLine <= r.startLine) continue;
        if (out.items.len == range_limit) break;
        try out.append(a, .{
            .range = .{ .start_line = r.startLine, .end_line = r.endLine, .kind = kindOf(r.kind) },
            .collapsed_text = if (r.collapsedText) |t| try a.dupe(u8, t) else null,
        });
    }
    std.mem.sort(Fold, out.items, {}, struct {
        fn lt(_: void, x: Fold, y: Fold) bool {
            if (x.range.start_line != y.range.start_line) return x.range.start_line < y.range.start_line;
            return x.range.end_line > y.range.end_line;
        }
    }.lt);
    return out.items;
}

fn kindOf(k: ?protocol.FoldingRangeKind) zg_syntax.structure.structure.FoldKind {
    const kind = k orelse return .block;
    return switch (kind) {
        .known => |e| switch (e) {
            .Comment => .comment,
            .Imports => .imports,
            .Region => .region,
        },
        .other => .block,
    };
}
