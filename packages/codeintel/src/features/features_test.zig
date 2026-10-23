//! Folding, selection range and document link tests against the fake
//! server.

const std = @import("std");
const zg_editor = @import("zg_editor");
const FoldingDriver = @import("folding.zig");
const SelectionDriver = @import("selection.zig");
const LinkDriver = @import("links.zig");
const Harness = @import("../Manager_test.zig").Harness;

const testing = std.testing;
const DocHandle = zg_editor.model.api.registry.DocHandle;

/// Ticks the manager and `tick` until `done` (10 s at most).
fn pump(h: *Harness, ctx: anytype, comptime tick: fn (@TypeOf(ctx)) void, comptime done: fn (@TypeOf(ctx)) bool) !void {
    for (0..2000) |_| {
        h.mgr.tick();
        tick(ctx);
        if (done(ctx)) return;
        try h.rt.io.sleep(.fromMilliseconds(5), .awake);
    }
    for (h.mgr.serverList()) |s| {
        std.debug.print("timeout: {s} {t}\n", .{ s.def.id, s.status });
        if (s.proc) |pr| {
            var tail: std.ArrayList(u8) = .empty;
            defer tail.deinit(testing.allocator);
            pr.stderrTail(&tail, 20) catch {};
            std.debug.print("stderr:\n{s}\n", .{tail.items});
        }
    }
    return error.Timeout;
}

const FoldCtx = struct {
    d: *FoldingDriver,
    doc: DocHandle,
    fn tick(c: *FoldCtx) void {
        _ = c.d.tick();
    }
    fn hasFolds(c: *FoldCtx) bool {
        return c.d.folds(c.doc) != null;
    }
    fn fellBack(c: *FoldCtx) bool {
        const st = c.d.poll.states.get(c.doc).?;
        return c.d.poll.sent == 2 and st.inflight == null and c.d.folds(c.doc) == null;
    }
};

test "folding: kinds, collapsedText and order; refresh; error falls back" {
    var h: Harness = undefined;
    try h.init("folding.script", &.{});
    var d: FoldingDriver = undefined;
    try d.init(&h.mgr, .{});
    const doc = try h.open("main.zig", "a\n" ** 12);
    defer {
        d.untrack(doc);
        h.mgr.closeDoc(doc);
        h.docs.release(doc);
        h.deinit();
        d.deinit();
    }
    try d.track(doc);
    var c: FoldCtx = .{ .d = &d, .doc = doc };
    try pump(&h, &c, FoldCtx.tick, FoldCtx.hasFolds);
    const f = d.folds(doc).?;
    // The empty range (5-5) is dropped; outer before inner on ties.
    try testing.expectEqual(@as(usize, 4), f.len);
    try testing.expectEqual(@as(u32, 0), f[0].range.start_line);
    try testing.expectEqual(.imports, f[0].range.kind);
    try testing.expectEqual(@as(u32, 9), f[1].range.end_line);
    try testing.expectEqual(.block, f[1].range.kind);
    try testing.expectEqualStrings("{...}", f[1].collapsed_text.?);
    try testing.expectEqual(.region, f[2].range.kind);
    try testing.expectEqual(.comment, f[3].range.kind);
    // The server's refresh asks again; its error leaves the editor's own
    // structure in charge.
    try pump(&h, &c, FoldCtx.tick, FoldCtx.fellBack);
    try testing.expect(d.folds(doc) == null);
}

const SelCtx = struct {
    d: *SelectionDriver,
    got: ?[]const []const SelectionDriver.ByteRange = null,
    arena: std.heap.ArenaAllocator,
    fallback: bool = false,

    fn cb(c: *SelCtx) SelectionDriver.Callback {
        return .{ .ctx = c, .func = onAnswer };
    }
    fn onAnswer(ctx: *anyopaque, _: DocHandle, a: SelectionDriver.Answer) void {
        const c: *SelCtx = @ptrCast(@alignCast(ctx));
        switch (a) {
            .fallback => c.fallback = true,
            .chains => |chains| {
                const al = c.arena.allocator();
                const out = al.alloc([]const SelectionDriver.ByteRange, chains.len) catch unreachable;
                for (chains, out) |x, *o| o.* = al.dupe(SelectionDriver.ByteRange, x) catch unreachable;
                c.got = out;
            },
        }
    }
    fn tick(c: *SelCtx) void {
        c.d.tick();
    }
    fn done(c: *SelCtx) bool {
        return c.got != null or c.fallback;
    }
};

test "selection: chains per cursor, expand and shrink" {
    var h: Harness = undefined;
    try h.init("selection.script", &.{});
    var d: SelectionDriver = .init(&h.mgr, .noop);
    var c: SelCtx = .{ .d = &d, .arena = .init(testing.allocator) };
    defer c.arena.deinit();
    const doc = try h.open("main.zig", "const a = 1;\nfoo()\n");
    defer {
        h.mgr.closeDoc(doc);
        h.docs.release(doc);
        h.deinit();
        d.deinit();
    }
    // Wait for the server before asking.
    for (0..2000) |_| {
        h.mgr.tick();
        if (h.server("fake")) |s| if (s.status == .running) break;
        try h.rt.io.sleep(.fromMilliseconds(5), .awake);
    }
    try d.request(doc, &.{ 6, 15 }, c.cb());
    try pump(&h, &c, SelCtx.tick, SelCtx.done);
    const chains = c.got.?;
    try testing.expectEqual(@as(usize, 2), chains.len);
    const R = SelectionDriver.ByteRange;
    try testing.expectEqualSlices(R, &.{ .{ .start = 6, .end = 7 }, .{ .start = 0, .end = 12 }, .{ .start = 0, .end = 19 } }, chains[0]);
    try testing.expectEqualSlices(R, &.{ .{ .start = 15, .end = 16 }, .{ .start = 13, .end = 18 }, .{ .start = 0, .end = 19 } }, chains[1]);
    try testing.expectEqual(R{ .start = 6, .end = 7 }, SelectionDriver.expand(chains[0], .{ .start = 6, .end = 6 }).?);
    try testing.expectEqual(R{ .start = 0, .end = 12 }, SelectionDriver.expand(chains[0], .{ .start = 6, .end = 7 }).?);
    try testing.expect(SelectionDriver.expand(chains[0], .{ .start = 0, .end = 19 }) == null);
    try testing.expectEqual(R{ .start = 0, .end = 12 }, SelectionDriver.shrink(chains[0], .{ .start = 0, .end = 19 }).?);
    try testing.expectEqual(R{ .start = 13, .end = 18 }, SelectionDriver.shrink(chains[1], .{ .start = 0, .end = 19 }).?);
}

const LinkCtx = struct {
    d: *LinkDriver,
    doc: DocHandle,
    opened: std.ArrayList(u8) = .empty,

    fn opener(c: *LinkCtx) LinkDriver.Opener {
        return .{ .ctx = c, .open = onOpen };
    }
    fn onOpen(ctx: *anyopaque, kind: LinkDriver.TargetKind, target: []const u8) void {
        const c: *LinkCtx = @ptrCast(@alignCast(ctx));
        c.opened.print(testing.allocator, "{t} {s};", .{ kind, target }) catch unreachable;
    }
    fn tick(c: *LinkCtx) void {
        _ = c.d.tick();
    }
    fn hasLinks(c: *LinkCtx) bool {
        return c.d.links(c.doc).len > 0;
    }
    fn resolved(c: *LinkCtx) bool {
        return std.mem.indexOf(u8, c.opened.items, "file ") != null;
    }
};

test "links: byte ranges, resolve on click, command allowlist" {
    var h: Harness = undefined;
    try h.init("links.script", &.{});
    var d: LinkDriver = undefined;
    var c: LinkCtx = .{ .d = &d, .doc = undefined };
    defer c.opened.deinit(testing.allocator);
    d.init(&h.mgr, c.opener(), .{ .command_allowlist = &.{"zig.build"} });
    c.doc = try h.open("main.zig", "// ziglang.org\nb.zig\nbld1 bad1\n");
    var sel: SelectionDriver = .init(&h.mgr, .noop);
    defer {
        d.untrack(c.doc);
        h.mgr.closeDoc(c.doc);
        h.docs.release(c.doc);
        h.deinit();
        d.deinit();
        sel.deinit();
    }
    try d.track(c.doc);
    try pump(&h, &c, LinkCtx.tick, LinkCtx.hasLinks);
    const ls = d.links(c.doc);
    try testing.expectEqual(@as(usize, 4), ls.len);
    try testing.expectEqual(@as(u64, 3), ls[0].start);
    try testing.expectEqual(@as(?usize, 1), d.linkAt(c.doc, 17));
    try testing.expectEqual(@as(?usize, null), d.linkAt(c.doc, 0));

    d.open(c.doc, 0);
    d.open(c.doc, 2);
    d.open(c.doc, 3);
    try testing.expectEqualStrings("web https://ziglang.org;command command:zig.build;", c.opened.items);
    d.open(c.doc, 1);
    try pump(&h, &c, LinkCtx.tick, LinkCtx.resolved);
    try testing.expect(std.mem.endsWith(u8, c.opened.items, "file file:///w/b.zig;"));

    // No selection ranges from this server: the editor's own structure.
    var sc: SelCtx = .{ .d = &sel, .arena = .init(testing.allocator) };
    defer sc.arena.deinit();
    try sel.request(c.doc, &.{0}, sc.cb());
    try testing.expect(sc.fallback);
}

test "links: classify" {
    const allow = &[_][]const u8{"a.b"};
    try testing.expectEqual(LinkDriver.TargetKind.web, LinkDriver.classify("HTTPS://x", allow).?);
    try testing.expectEqual(LinkDriver.TargetKind.file, LinkDriver.classify("file:///x", allow).?);
    try testing.expectEqual(LinkDriver.TargetKind.command, LinkDriver.classify("command:a.b?%5B%5D", allow).?);
    try testing.expect(LinkDriver.classify("command:a.c", allow) == null);
    try testing.expect(LinkDriver.classify("javascript:alert(1)", allow) == null);
    try testing.expect(LinkDriver.classify("no-scheme", allow) == null);
}
