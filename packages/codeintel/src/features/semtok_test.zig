//! SemTokDriver tests: the fake server's scripts check each request and
//! the overlay shows what the answers say.

const std = @import("std");
const zg_editor = @import("zg_editor");
const zg_syntax = @import("zg_syntax");
const SemTokDriver = @import("semtok.zig");
const Harness = @import("../Manager_test.zig").Harness;

const testing = std.testing;
const api = zg_editor.model.api;
const DocHandle = api.registry.DocHandle;
const DocumentSyntax = zg_editor.model.syntax.DocumentSyntax;
const Document = zg_editor.model.document.Document;
const ChangeEvent = zg_editor.model.document.ChangeEvent;
const ChangeSet = zg_editor.model.edit.change_set.ChangeSet;
const pt = zg_editor.model.buffer.piece_tree;

/// One document's highlighting, following its edits.
const Fixture = struct {
    h: *Harness,
    d: DocHandle,
    reg: zg_syntax.Registry,
    names: zg_syntax.HighlightNames,
    ds: DocumentSyntax,
    drv: SemTokDriver,

    fn init(f: *Fixture, h: *Harness, name: []const u8, text: []const u8, opts: SemTokDriver.Options) !void {
        const gpa = testing.allocator;
        f.h = h;
        f.d = try h.open(name, text);
        const doc = h.docs.get(f.d).?;
        f.reg = try zg_syntax.defaultRegistry(gpa);
        f.names = .init(gpa);
        f.ds = try .init(gpa, f.reg.get(.zig).?, &f.reg, &doc.tree, doc.version);
        _ = try doc.subscribe(.{ .ctx = f, .onChange = onChange });
        try f.drv.init(&h.mgr, &f.names, .{ .ctx = f, .get = get }, opts);
        try f.drv.track(f.d);
    }

    /// Shuts the manager down first (see `SemTokDriver.deinit`).
    fn deinit(f: *Fixture) void {
        f.h.docs.release(f.d);
        f.h.deinit();
        f.drv.deinit();
        f.ds.deinit();
        f.names.deinit();
        f.reg.deinit(testing.allocator);
    }

    fn onChange(ctx: *anyopaque, ev: *const ChangeEvent) void {
        const f: *Fixture = @ptrCast(@alignCast(ctx));
        f.ds.onChange(ev, &f.h.docs.get(f.d).?.tree, null) catch @panic("oom");
    }

    fn get(ctx: *anyopaque, d: DocHandle) ?*DocumentSyntax {
        const f: *Fixture = @ptrCast(@alignCast(ctx));
        return if (std.meta.eql(d, f.d)) &f.ds else null;
    }

    /// Ticks both until `pred` holds (10 s at most).
    fn waitFor(f: *Fixture, ctx: anytype, comptime pred: fn (*Fixture, @TypeOf(ctx)) bool) !void {
        for (0..2000) |_| {
            f.h.mgr.tick();
            _ = f.drv.tick();
            if (pred(f, ctx)) return;
            try f.h.rt.io.sleep(.fromMilliseconds(5), .awake);
        }
        const st = f.drv.states.get(f.d).?;
        std.debug.print("timeout: sent={any} inflight={} applied={?} ver={} servers={}\n", .{ f.drv.sent, st.inflight != null, st.applied, f.h.docs.get(f.d).?.version, f.h.mgr.serverList().len });
        for (f.h.mgr.serverList()) |s| std.debug.print("  {s} {t}\n", .{ s.def.id, s.status });
        return error.Timeout;
    }

    fn sentIs(f: *Fixture, want: [3]u32) bool {
        const st = f.drv.states.get(f.d).?;
        return std.mem.eql(u32, &f.drv.sent, &want) and st.inflight == null;
    }

    fn appliedNow(f: *Fixture, _: void) bool {
        const st = f.drv.states.get(f.d).?;
        return st.inflight == null and st.applied == f.h.docs.get(f.d).?.version;
    }

    /// The highlight name of the semantic token at `line`, `col`.
    fn nameAt(f: *Fixture, line: u64, col: u32) []const u8 {
        const o = &(f.ds.semantic orelse return "");
        for (o.lineTokens(line)) |t| if (t.start <= col and col < t.end) return f.names.name(t.hl);
        return "";
    }

    fn edit(f: *Fixture, a: usize, b: usize, text: []const u8) !void {
        const doc = f.h.docs.get(f.d).?;
        var cs = try ChangeSet.fromEdits(testing.allocator, doc.len(), &.{pt.Edit{ .range = .{ .start = a, .end = b }, .text = text }});
        defer cs.deinit();
        try doc.applyChangeSet(&cs, .{ .user = 0 });
    }
};

fn sentIs(f: *Fixture, want: [3]u32) bool {
    return f.sentIs(want);
}

test "semtok: full, delta, refresh keeps tokens on null, ContentModified retried" {
    var h: Harness = undefined;
    try h.init("semtok_session.script", &.{});
    var f: Fixture = undefined;
    try f.init(&h, "main.zig", "const a = 1;\n", .{ .debounce = .fromMilliseconds(1) });
    defer f.deinit();
    f.drv.onViewport(f.d, .{ .first = 0, .end = 1 });

    try f.waitFor({}, Fixture.appliedNow);
    try testing.expectEqualStrings("variable.readonly", f.nameAt(0, 6));

    // An edit: the delta turns `a` into a function. The server then asks
    // for a refresh, which re-requests the visible document in full; its
    // null answer keeps the tokens.
    try f.edit(6, 7, "b");
    try f.waitFor([3]u32{ 2, 1, 0 }, sentIs);
    try testing.expect(Fixture.appliedNow(&f, {}));
    try testing.expectEqualStrings("function", f.nameAt(0, 6));

    // ContentModified on the next delta: one retry, in full.
    try f.edit(6, 7, "c");
    try f.waitFor([3]u32{ 3, 2, 0 }, sentIs);
    try f.waitFor({}, Fixture.appliedNow);
    try testing.expectEqualStrings("variable", f.nameAt(0, 6));
}

test "semtok: range mode for huge docs follows the viewport" {
    var h: Harness = undefined;
    try h.init("semtok_range.script", &.{});
    var f: Fixture = undefined;
    const text = "fn\n" ** 100;
    try f.init(&h, "big.zig", text, .{ .range_threshold_lines = 10 });
    defer f.deinit();
    f.drv.onViewport(f.d, .{ .first = 40, .end = 50 });
    try f.waitFor([3]u32{ 0, 0, 1 }, sentIs);
    try testing.expectEqualStrings("function", f.nameAt(30, 0));
    // Lines already covered need nothing new.
    f.drv.onViewport(f.d, .{ .first = 35, .end = 55 });
    for (0..10) |_| _ = f.drv.tick();
    try testing.expectEqual(@as(u32, 1), f.drv.sent[2]);
    f.drv.onViewport(f.d, .{ .first = 80, .end = 90 });
    try f.waitFor([3]u32{ 0, 0, 2 }, sentIs);
    try testing.expectEqualStrings("function", f.nameAt(75, 0));
}

test "semtok: disabling clears the overlay" {
    var h: Harness = undefined;
    try h.init("semtok_once.script", &.{});
    var f: Fixture = undefined;
    try f.init(&h, "main.zig", "const a = 1;\n", .{});
    defer f.deinit();
    try f.waitFor({}, Fixture.appliedNow);
    try testing.expect(f.ds.semantic != null);
    f.drv.setEnabled(false);
    try testing.expect(f.ds.semantic == null);
    for (0..10) |_| _ = f.drv.tick();
    try testing.expectEqual(@as(u32, 1), f.drv.sent[0]);
}
