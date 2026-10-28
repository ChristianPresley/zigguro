//! Call and type hierarchies against the scripted fake server
//! (hierarchy.script).

const std = @import("std");
const zg_editor = @import("zg_editor");
const Harness = @import("../Manager_test.zig").Harness;
const HierarchyService = @import("hierarchy.zig");

const testing = std.testing;
const gpa = testing.allocator;
const DocHandle = zg_editor.model.api.registry.DocHandle;

fn running(h: *Harness) bool {
    for (h.mgr.serverList()) |s| if (s.status == .running and s.sync != null and s.docs.items.len > 0 and s.sync.?.isTracked(s.docs.items[s.docs.items.len - 1])) return true;
    return false;
}

const Fx = struct {
    h: Harness,
    d: DocHandle,
    s: HierarchyService,
    loaded: std.ArrayList(u64) = .empty,

    fn init(f: *Fx) !void {
        try f.h.init("hierarchy.script", &.{});
        f.d = try f.h.open("main.zig", "fn a() void { b(); }\n");
        f.s = .init(&f.h.mgr, .noop);
        f.loaded = .empty;
        for (0..2000) |_| {
            f.h.mgr.tick();
            if (running(&f.h)) return;
            try f.h.rt.io.sleep(.fromMilliseconds(5), .awake);
        }
        return error.Timeout;
    }

    fn deinit(f: *Fx) void {
        f.h.mgr.closeDoc(f.d);
        f.h.docs.release(f.d);
        f.h.mgr.deinit();
        f.s.deinit();
        f.loaded.deinit(gpa);
        f.h.docs.deinit();
        f.h.reg.deinit();
        gpa.free(f.h.script);
        f.h.tmp.cleanup();
        _ = f.h.rt.deinit();
    }

    fn prepared(f: *Fx) !void {
        for (0..2000) |_| {
            f.h.mgr.tick();
            _ = f.s.tick();
            if (!f.s.busy()) return;
            try f.h.rt.io.sleep(.fromMilliseconds(5), .awake);
        }
        return error.Timeout;
    }

    /// Expands `id` and waits for its children.
    fn expand(f: *Fx, id: u64) ![]const u64 {
        try f.s.expand(id);
        for (0..2000) |_| {
            f.h.mgr.tick();
            _ = f.s.tick();
            try f.s.takeLoaded(&f.loaded);
            if (std.mem.indexOfScalar(u64, f.loaded.items, id) != null) return f.s.node(id).?.children.?;
            try f.h.rt.io.sleep(.fromMilliseconds(5), .awake);
        }
        return error.Timeout;
    }
};

test "hierarchy: lazy incoming/outgoing with data roundtrip byte-identical; fromRanges document semantics; recursive marker; type supertypes/subtypes; several prepared items" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();

    try testing.expect(f.s.available(.calls, f.d));
    try testing.expect(try f.s.prepare(f.d, 3, .incoming) > 0);
    try f.prepared();
    try testing.expectEqual(@as(usize, 1), f.s.roots.items.len);
    const root = f.s.roots.items[0];
    const a = f.s.node(root).?;
    try testing.expectEqualStrings("a", a.item.name);
    // The item exactly as the server sent it (field order and the
    // unknown field kept); the server checks it came back so.
    try testing.expect(std.mem.startsWith(u8, a.item.raw, "{\"data\":{\"id\":\"A\"},\"x-extra\":1,\"name\":\"a\""));
    try testing.expect(a.children == null);

    // Incoming: b calls a; the call site is in b's file.
    const kids = try f.expand(root);
    try testing.expectEqual(@as(usize, 1), kids.len);
    const b = f.s.node(kids[0]).?;
    try testing.expectEqualStrings("b", b.item.name);
    try testing.expect(std.mem.endsWith(u8, b.ranges_uri.?, "/b.zig"));
    try testing.expectEqual(@as(u32, 14), b.from_ranges[0].start.character);
    try testing.expect(!b.recursive);

    // a calls b calls a: the repeat is marked and has no children.
    const kids2 = try f.expand(kids[0]);
    const again = f.s.node(kids2[0]).?;
    try testing.expectEqualStrings("a", again.item.name);
    try testing.expect(again.recursive);
    try testing.expectEqual(@as(usize, 0), again.children.?.len);
    try f.s.expand(kids2[0]);
    try testing.expect(!f.s.node(kids2[0]).?.loading);

    // Outgoing from the same root: the call site is in a's own file.
    f.s.setDirection(.outgoing);
    try testing.expectEqual(@as(usize, 1), f.s.roots.items.len);
    const out = try f.expand(f.s.roots.items[0]);
    const to_b = f.s.node(out[0]).?;
    try testing.expectEqualStrings("b", to_b.item.name);
    try testing.expect(std.mem.endsWith(u8, to_b.ranges_uri.?, "/main.zig"));

    // Types: two items prepared are two roots.
    try testing.expect(try f.s.prepare(f.d, 3, .supertypes) > 0);
    try f.prepared();
    try testing.expectEqual(HierarchyService.Kind.types, f.s.kind);
    try testing.expectEqual(@as(usize, 2), f.s.roots.items.len);
    try testing.expectEqualStrings("T2", f.s.node(f.s.roots.items[1]).?.item.name);
    const sup = try f.expand(f.s.roots.items[0]);
    try testing.expectEqualStrings("Base", f.s.node(sup[0]).?.item.name);
    f.s.setDirection(.subtypes);
    const sub = try f.expand(f.s.roots.items[0]);
    try testing.expectEqual(@as(usize, 2), sub.len);
    try testing.expectEqualStrings("U2", f.s.node(sub[1]).?.item.name);
}
