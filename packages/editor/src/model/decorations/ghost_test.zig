//! Tests for ghost text: typing-through, partial accept and decorations.

const std = @import("std");
const store_mod = @import("store.zig");
const ghost_mod = @import("ghost.zig");
const pt = @import("../buffer/piece_tree.zig");
const ChangeSet = @import("../edit/change_set.zig").ChangeSet;
const document = @import("../document.zig");

const testing = std.testing;
const Document = document.Document;
const DecorationStore = store_mod.DecorationStore;
const GhostText = ghost_mod.GhostText;

const Fixture = struct {
    doc: *Document,
    store: DecorationStore,
    ghost: ?GhostText = null,
    last: ?ghost_mod.TypeResult = null,
    owner: store_mod.OwnerId = undefined,

    fn init(f: *Fixture, text: []const u8) !void {
        f.ghost = null;
        f.last = null;
        f.doc = try Document.initBytes(testing.allocator, @enumFromInt(1), text);
        f.store = .init(testing.allocator, f.doc);
        _ = try f.doc.subscribe(f.store.listener());
        _ = try f.doc.subscribe(.{ .ctx = f, .onChange = onChange });
        f.owner = try f.store.registerOwner("ai.ghost", 20);
    }

    fn deinit(f: *Fixture) void {
        if (f.ghost) |*g| g.deinit();
        f.store.deinit();
        f.doc.deinit();
    }

    fn onChange(ctx: *anyopaque, ev: *const document.ChangeEvent) void {
        const f: *Fixture = @ptrCast(@alignCast(ctx));
        if (f.ghost) |*g| f.last = g.onType(ev) catch unreachable;
    }

    fn show(f: *Fixture, at: u64, text: []const u8) !void {
        f.ghost = try GhostText.show(testing.allocator, f.doc, &f.store, at, text, .{ .request_id = 9, .source = f.owner });
    }

    fn insert(f: *Fixture, at: u64, text: []const u8) !void {
        var cs = try ChangeSet.fromEdits(testing.allocator, f.doc.len(), &.{.{ .range = .{ .start = at, .end = at }, .text = text }});
        defer cs.deinit();
        try f.doc.applyChangeSet(&cs, .{ .user = 0 });
    }

    fn docText(f: *Fixture) ![]u8 {
        return f.doc.tree.copyRange(testing.allocator, .{ .start = 0, .end = f.doc.len() });
    }

    /// The inline text shown, or null.
    fn shown(f: *Fixture) !?[]const u8 {
        var out: std.ArrayList(store_mod.DecoRef) = .empty;
        defer out.deinit(testing.allocator);
        try f.store.query(.{ .start = 0, .end = f.doc.len() }, .initOne(.inline_after), testing.allocator, &out);
        if (out.items.len == 0) return null;
        try testing.expectEqual(@as(usize, 1), out.items.len);
        try testing.expectEqual(f.ghost.?.at, out.items[0].range.start);
        return out.items[0].deco.kind.inline_after.text;
    }
};

test "ghost: typing-through shrinks and dismisses on mismatch" {
    var f: Fixture = undefined;
    try f.init("fn main() {\n    \n}\n");
    defer f.deinit();
    try f.show(16, "std.debug.print");
    try testing.expectEqualStrings("std.debug.print", (try f.shown()).?);
    try f.insert(16, "s");
    try testing.expectEqual(ghost_mod.TypeResult.kept_shrunk, f.last.?);
    try f.insert(17, "td");
    try testing.expectEqualStrings(".debug.print", (try f.shown()).?);
    try testing.expectEqual(@as(u64, 19), f.ghost.?.at);
    // An edit elsewhere keeps it and moves the anchor.
    try f.insert(0, "// x\n");
    try testing.expectEqual(ghost_mod.TypeResult.kept, f.last.?);
    try testing.expectEqual(@as(u64, 24), f.ghost.?.at);
    try testing.expectEqualStrings(".debug.print", (try f.shown()).?);
    // Typing something else dismisses (case-sensitive).
    try f.insert(24, ".D");
    try testing.expectEqual(ghost_mod.TypeResult.dismissed, f.last.?);
    try testing.expect(try f.shown() == null);
}

test "ghost: accept word/line/all undo groups" {
    var f: Fixture = undefined;
    try f.init("x\n");
    defer f.deinit();
    try f.show(1, " = compute(a, b);\nreturn x;\nend");
    const v0 = f.doc.version;
    try testing.expectEqual(@as(u64, 4), try f.ghost.?.accept(.word)); // " = "
    try testing.expectEqual(v0 + 1, f.doc.version);
    try testing.expectEqualStrings("compute(a, b);", (try f.shown()).?);
    _ = try f.ghost.?.accept(.word); // "compute"
    _ = try f.ghost.?.accept(.line); // "(a, b);\n"
    try testing.expectEqual(v0 + 3, f.doc.version);
    try testing.expectEqualStrings("return x;", (try f.shown()).?);
    const caret = try f.ghost.?.accept(.all);
    try testing.expectEqual(v0 + 4, f.doc.version);
    const t = try f.docText();
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("x = compute(a, b);\nreturn x;\nend\n", t);
    try testing.expectEqual(@as(u64, t.len - 1), caret);
    try testing.expect(!f.ghost.?.visible);
    try testing.expectEqual(@as(usize, 0), f.store.count());
}

test "ghost: auto-closed paren consumes ghost paren" {
    var f: Fixture = undefined;
    try f.init("call\n");
    defer f.deinit();
    try f.show(4, "(a, b)");
    // Smart edit inserts "()" with the caret between.
    try f.insert(4, "()");
    try testing.expectEqual(ghost_mod.TypeResult.kept_shrunk, f.last.?);
    try testing.expectEqualStrings("a, b", (try f.shown()).?);
    try testing.expectEqual(@as(u64, 5), f.ghost.?.at);
    _ = try f.ghost.?.accept(.all);
    const t = try f.docText();
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("call(a, b)\n", t);
}

test "ghost: multi-line ghost is inline plus block" {
    var f: Fixture = undefined;
    try f.init("{\n}\n");
    defer f.deinit();
    try f.show(1, "\n    one();\n    two();");
    var out: std.ArrayList(store_mod.DecoRef) = .empty;
    defer out.deinit(testing.allocator);
    try f.store.query(.{ .start = 0, .end = 4 }, .initFull(), testing.allocator, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    var rows: u32 = 0;
    for (out.items) |d| switch (d.deco.kind) {
        .block_below => |b| rows = b.rows,
        .inline_after => |t| try testing.expectEqualStrings("", t.text),
        else => return error.UnexpectedKind,
    };
    try testing.expectEqual(@as(u32, 2), rows);
    var it = f.ghost.?.lines();
    try testing.expectEqualStrings("", it.next().?);
    try testing.expectEqualStrings("    one();", it.next().?);
}

test "ghost: replace range is replaced on accept" {
    var f: Fixture = undefined;
    try f.init("pri");
    defer f.deinit();
    f.ghost = try GhostText.show(testing.allocator, f.doc, &f.store, 3, "println", .{ .request_id = 1, .source = f.owner, .replace_range = .{ .start = 0, .end = 3 } });
    _ = try f.ghost.?.accept(.all);
    const t = try f.docText();
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("println", t);
}
