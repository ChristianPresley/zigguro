const std = @import("std");
const zg_editor = @import("zg_editor");
const controller_mod = @import("controller.zig");
const engine_mod = @import("engine.zig");
const providers = @import("providers.zig");
const context = @import("context.zig");

const testing = std.testing;
const gpa = testing.allocator;
const model = zg_editor.model;
const Document = model.document.Document;
const DecorationStore = model.decorations.store.DecorationStore;
const ChangeSet = model.edit.change_set.ChangeSet;
const Controller = controller_mod.Controller;

const text0 = "fn f() u32 {\n    re\n}\n";
const cursor = 19;

/// A provider and host the controller tests never start requests on.
const Idle = struct {
    fn provider(x: *Idle) providers.FimProvider {
        return .{ .ctx = x, .vtable = &.{ .complete = complete }, .caps = .{ .server_side_template = true } };
    }
    fn complete(_: *anyopaque, _: std.Io, _: std.mem.Allocator, _: *const context.CompletionRequest, _: providers.Sink) anyerror!void {}
    fn host(x: *Idle) engine_mod.Host {
        return .{ .ctx = x, .snapshot = snapshot, .post = post, .deliver = deliver };
    }
    fn snapshot(_: *anyopaque, _: u64, _: std.mem.Allocator) anyerror!?engine_mod.Snapshot {
        return null;
    }
    fn post(_: *anyopaque, _: *anyopaque) void {}
    fn deliver(_: *anyopaque, _: engine_mod.Delivery) void {}
};

const Fixture = struct {
    doc: *Document,
    store: DecorationStore,
    idle: Idle = .{},
    engine: engine_mod.CompletionEngine,
    c: Controller,
    req: context.CompletionRequest,
    now: u64 = 0,

    fn init(f: *Fixture, multiline: bool, opts: controller_mod.Options) !void {
        f.doc = try Document.initBytes(gpa, @enumFromInt(1), text0);
        f.store = .init(gpa, f.doc);
        _ = try f.doc.subscribe(f.store.listener());
        _ = try f.doc.subscribe(.{ .ctx = f, .onChange = onChange });
        const owner = try f.store.registerOwner("ai.ghost", 20);
        f.idle = .{};
        f.engine = .init(gpa, testing.io, f.idle.provider(), f.idle.host(), .{}, 1);
        try f.engine.open(1, 0);
        f.c = .init(gpa, f.doc, 1, &f.store, owner, &f.engine, opts);
        f.req = .{ .path = "a.zig", .language = "zig", .prefix = text0[0..cursor], .suffix = text0[cursor..], .multiline = multiline, .max_tokens = 32, .stop = &.{} };
        f.now = 0;
    }

    fn deinit(f: *Fixture) void {
        f.c.deinit();
        f.engine.deinit();
        f.store.deinit();
        f.doc.deinit();
    }

    fn onChange(ctx: *anyopaque, ev: *const model.document.ChangeEvent) void {
        const f: *Fixture = @ptrCast(@alignCast(ctx));
        f.c.onChange(ev, f.now) catch unreachable;
    }

    fn deliver(f: *Fixture, raw: []const u8, final: bool) !void {
        try f.c.onDelivery(.{
            .doc = 1,
            .version = f.doc.version,
            .request_id = 5,
            .request = &f.req,
            .at = cursor,
            .started_ns = 0,
            .text = raw,
            .hide = 0,
            .final = final,
        }, 120 * std.time.ns_per_ms);
    }

    fn insert(f: *Fixture, at: u64, text: []const u8) !void {
        var cs = try ChangeSet.fromEdits(gpa, f.doc.len(), &.{.{ .range = .{ .start = at, .end = at }, .text = text }});
        defer cs.deinit();
        try f.doc.applyChangeSet(&cs, .{ .user = 0 });
    }

    fn docText(f: *Fixture) ![]u8 {
        return f.doc.tree.copyRange(gpa, .{ .start = 0, .end = f.doc.len() });
    }
};

test "controller: tab accepts when ghost visible, falls through otherwise" {
    var f: Fixture = undefined;
    try f.init(false, .{});
    defer f.deinit();
    try testing.expect(!try f.c.accept(.all, 0));
    // Post-processed on the way: the suffix overlap goes.
    try f.deliver("turn 1;\n}", true);
    try testing.expect(f.c.visible());
    try testing.expectEqualStrings("turn 1;", f.c.text());
    try testing.expect(try f.c.accept(.all, 1000));
    const t = try f.docText();
    defer gpa.free(t);
    try testing.expectEqualStrings("fn f() u32 {\n    return 1;\n}\n", t);
    try testing.expect(!f.c.visible());
    try testing.expectEqual(@as(u64, 1), f.c.stats.accepted_full);
    try testing.expectEqual(@as(u64, 1), f.c.stats.shown);
    try testing.expectEqual(@as(u32, 1), f.c.stats.latency_ms_hist[6]);
    // Accepting all asks for the next one at once.
    try testing.expectEqual(@as(?u64, 1000), f.engine.nextDeadline());
    try testing.expect(!try f.c.accept(.all, 0));
}

test "controller: word and line partial accept leave remainder" {
    var f: Fixture = undefined;
    try f.init(true, .{});
    defer f.deinit();
    try f.deliver("turn x;\n    y();", true);
    try testing.expect(try f.c.accept(.word, 0));
    try testing.expectEqualStrings("x;\n    y();", f.c.text());
    try testing.expect(try f.c.accept(.line, 0));
    try testing.expectEqualStrings("    y();", f.c.text());
    try testing.expectEqual(@as(u64, 2), f.c.stats.accepted_partial);
    try testing.expectEqual(@as(u64, 0), f.c.stats.accepted_full);
    const t = try f.docText();
    defer gpa.free(t);
    try testing.expectEqualStrings("fn f() u32 {\n    return x;\n\n}\n", t);
}

test "controller: typing through shrinks; streaming grows the ghost" {
    var f: Fixture = undefined;
    try f.init(true, .{});
    defer f.deinit();
    try f.deliver("turn", false);
    try testing.expect(!f.c.visible());
    try f.deliver("turn x;\n    y", false);
    try testing.expectEqualStrings("turn x;", f.c.text());
    try f.deliver("turn x;\n    y();", true);
    try testing.expectEqualStrings("turn x;\n    y();", f.c.text());
    try f.insert(cursor, "t");
    try testing.expectEqualStrings("urn x;\n    y();", f.c.text());
    try f.insert(cursor + 1, "q");
    try testing.expect(!f.c.visible());
}

test "controller: popup open hides ghost, restores when consistent" {
    var f: Fixture = undefined;
    try f.init(false, .{});
    defer f.deinit();
    try f.deliver("turn 1;", true);
    f.c.dismiss(.popup_opened);
    try testing.expect(!f.c.visible());
    try f.c.popupClosed();
    try testing.expectEqualStrings("turn 1;", f.c.text());

    // An edit while the popup is open: not restored.
    f.c.dismiss(.popup_opened);
    try f.insert(0, "// x\n");
    try f.c.popupClosed();
    try testing.expect(!f.c.visible());

    // The ghost wins: the popup leaves it alone.
    var g: Fixture = undefined;
    try g.init(false, .{ .ghost_wins = true });
    defer g.deinit();
    try g.deliver("turn 1;", true);
    g.c.dismiss(.popup_opened);
    try testing.expect(g.c.visible());
}

test "controller: snooze increments by 5 minutes" {
    var f: Fixture = undefined;
    try f.init(false, .{});
    defer f.deinit();
    const min = std.time.ns_per_min;
    try f.deliver("turn 1;", true);
    f.c.snooze(0);
    try testing.expect(!f.c.visible());
    try testing.expectEqual(5 * min, f.c.snooze_until_ns);
    f.c.snooze(1 * min);
    try testing.expectEqual(10 * min, f.c.snooze_until_ns);
    try testing.expectEqual(controller_mod.Status.snoozed, f.c.status(9 * min));
    try testing.expectEqual(controller_mod.Status.ready, f.c.status(10 * min));
    f.c.onFailed();
    try testing.expectEqual(controller_mod.Status.unhealthy, f.c.status(10 * min));
}
