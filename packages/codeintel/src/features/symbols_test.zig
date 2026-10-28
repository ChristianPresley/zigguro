//! The outline and workspace symbols against the scripted fake server
//! (symbols.script), and the tree builders.

const std = @import("std");
const zg_lsp = @import("zg_lsp");
const zg_editor = @import("zg_editor");
const zg_syntax = @import("zg_syntax");
const Harness = @import("../Manager_test.zig").Harness;
const OutlineProvider = @import("symbols.zig");
const WorkspaceSymbols = @import("workspace_symbols.zig");

const testing = std.testing;
const gpa = testing.allocator;
const DocHandle = zg_editor.model.api.registry.DocHandle;
const ChangeSet = zg_editor.model.edit.change_set.ChangeSet;

fn running(h: *Harness) bool {
    for (h.mgr.serverList()) |s| if (s.status == .running and s.sync != null and s.docs.items.len > 0 and s.sync.?.isTracked(s.docs.items[s.docs.items.len - 1])) return true;
    return false;
}

const Fx = struct {
    h: Harness,
    d: DocHandle,
    outline: OutlineProvider,
    ws: WorkspaceSymbols,
    heard_n: u32 = 0,
    now: u64 = 0,

    fn init(f: *Fx) !void {
        try f.h.init("symbols.script", &.{});
        f.d = try f.h.open("main.zig", "const S = struct {\n    fn f() void {}\n};\n\nfn g() void {}\n");
        f.outline = .init(&f.h.mgr, .noop, .{ .debounce_ms = 300 });
        f.ws = .init(&f.h.mgr, .noop, .{});
        f.heard_n = 0;
        f.now = 0;
        try f.outline.subscribe(.{ .ctx = f, .f = heard });
        for (0..2000) |_| {
            f.h.mgr.tick();
            if (running(&f.h)) return;
            try f.h.rt.io.sleep(.fromMilliseconds(5), .awake);
        }
        return error.Timeout;
    }

    fn heard(ctx: *anyopaque, _: DocHandle) void {
        const f: *Fx = @ptrCast(@alignCast(ctx));
        f.heard_n += 1;
    }

    fn deinit(f: *Fx) void {
        f.h.mgr.closeDoc(f.d);
        f.h.docs.release(f.d);
        f.h.mgr.deinit();
        f.outline.deinit();
        f.ws.deinit();
        f.h.docs.deinit();
        f.h.reg.deinit();
        gpa.free(f.h.script);
        f.h.tmp.cleanup();
        _ = f.h.rt.deinit();
    }

    /// Ticks (the clock moving 50 ms a step) until `pred`.
    fn until(f: *Fx, comptime pred: fn (*Fx) bool) !void {
        for (0..2000) |_| {
            f.h.mgr.tick();
            _ = f.outline.tick(f.now);
            _ = f.ws.tick(f.now);
            if (pred(f)) return;
            f.now += 50;
            try f.h.rt.io.sleep(.fromMilliseconds(5), .awake);
        }
        return error.Timeout;
    }
};

fn heardOnce(f: *Fx) bool {
    return f.heard_n >= 1;
}

fn heardTwice(f: *Fx) bool {
    return f.heard_n >= 2;
}

fn wsDone(f: *Fx) bool {
    return f.ws.complete() and f.ws.hits().len > 0;
}

fn resolved(f: *Fx) bool {
    return f.ws.resolved != null;
}

test "symbols: flat to tree by containment, version mapping drops edited names, hierarchy; workspace symbols dedup and resolve on pick" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();

    try f.outline.want(f.d, f.now);
    try f.until(heardOnce);
    const o = f.outline.get(f.d).?;
    try testing.expectEqual(OutlineProvider.Source.lsp, o.source);
    try testing.expectEqual(@as(usize, 2), o.roots.len);
    try testing.expectEqualStrings("S", o.roots[0].name);
    try testing.expect(o.roots[0].deprecated);
    try testing.expectEqual(@as(usize, 1), o.roots[0].children.len);
    try testing.expectEqualStrings("f", o.roots[0].children[0].name);
    try testing.expectEqualStrings("S", o.roots[0].children[0].container.?);
    try testing.expectEqualStrings("g", o.roots[1].name);
    try testing.expectEqual(@as(usize, 3), o.count());

    // Typing inside g's line (its flat range is its selection): g goes
    // until the next answer; S and f stay.
    const doc = f.h.docs.get(f.d).?;
    const at: u64 = 43 + 3;
    var cs = try ChangeSet.fromEdits(gpa, doc.len(), &.{.{ .range = .{ .start = at, .end = at }, .text = "x" }});
    defer cs.deinit();
    try doc.applyChangeSet(&cs, .{ .user = 0 });
    const m = f.outline.get(f.d).?;
    try testing.expectEqual(doc.version, m.version);
    try testing.expectEqual(@as(usize, 1), m.roots.len);
    try testing.expectEqual(@as(usize, 2), m.count());

    try f.outline.want(f.d, f.now);
    try testing.expect(f.outline.nextDue().? >= f.now + 300);
    try f.until(heardTwice);
    const o2 = f.outline.get(f.d).?;
    try testing.expectEqual(@as(usize, 2), o2.roots.len);
    try testing.expectEqualStrings("struct", o2.roots[0].detail.?);
    try testing.expectEqual(@as(u64, 6), o2.roots[0].selection.start);
    try testing.expectEqualStrings("xg", o2.roots[1].name);
    var flat: std.ArrayList(OutlineProvider.Outline.Flat) = .empty;
    defer flat.deinit(gpa);
    try o2.flatten(gpa, &flat);
    try testing.expectEqual(@as(usize, 3), flat.items.len);
    try testing.expectEqualStrings("f", flat.items[1].node.name);
    try testing.expectEqual(@as(u16, 1), flat.items[1].depth);

    // Workspace symbols: debounced, deduplicated; the bare-URI one is
    // resolved when picked.
    try testing.expect(f.ws.available());
    try f.ws.query("f", f.now);
    try testing.expect(f.ws.nextDue().? == f.now + 100);
    try f.until(wsDone);
    try testing.expectEqual(@as(usize, 2), f.ws.hits().len);
    try testing.expect(f.ws.hits()[0].range == null);
    try f.ws.pick(1);
    const ready = f.ws.takeResolved().?;
    try testing.expectEqualStrings("fmt", ready.name);
    try f.ws.pick(0);
    try testing.expect(f.ws.takeResolved() == null);
    try f.until(resolved);
    const r = f.ws.takeResolved().?;
    try testing.expectEqual(@as(u32, 1), r.range.?.start.line);
    try testing.expectEqual(@as(u32, 7), r.range.?.start.character);
}

test "symbols: structure fallback tree and containment nesting" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const syms = [_]zg_syntax.Symbol{
        .{ .name = "S", .kind = .@"struct", .range = .{ .start = 0, .end = 40 }, .selection = .{ .start = 6, .end = 7 } },
        .{ .name = "f", .kind = .function, .range = .{ .start = 20, .end = 30 }, .selection = .{ .start = 23, .end = 24 }, .parent = 0 },
        .{ .name = "g", .kind = .function, .range = .{ .start = 42, .end = 50 }, .selection = .{ .start = 45, .end = 46 } },
    };
    const t = try OutlineProvider.structureTree(a, &syms);
    try testing.expectEqual(@as(usize, 2), t.len);
    try testing.expectEqualStrings("f", t[0].children[0].name);
    try testing.expectEqual(@as(u32, 12), @intFromEnum(t[1].kind));
}
