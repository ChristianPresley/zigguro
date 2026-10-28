//! Evaluation against `fake_dap_adapter` scripts (testdata/sessions/
//! eval_*.txt, completions.txt): contexts by capability, hover never in
//! the REPL by default, REPL results as tree roots until the resume, and
//! completions.

const std = @import("std");
const Inspector = @import("Inspector.zig");
const Evaluator = @import("Evaluator.zig");
const VariablesModel = @import("VariablesModel.zig");
const inspect_test = @import("inspect_test.zig");

const testing = std.testing;
const gpa = testing.allocator;
const Fixture = inspect_test.Fixture;

/// Keeps the last result.
const Got = struct {
    calls: u32 = 0,
    value: [64]u8 = undefined,
    len: usize = 0,
    err: bool = false,
    node: ?VariablesModel.NodeId = null,

    fn cb(g: *Got) Evaluator.EvalCb {
        return .{ .ctx = g, .func = on };
    }

    fn on(ctx: ?*anyopaque, _: u64, r: *const Evaluator.EvalResult) void {
        const g: *Got = @ptrCast(@alignCast(ctx.?));
        g.calls += 1;
        g.len = @min(r.value.len, g.value.len);
        @memcpy(g.value[0..g.len], r.value[0..g.len]);
        g.err = r.err;
        g.node = r.node;
    }

    fn text(g: *const Got) []const u8 {
        return g.value[0..g.len];
    }
};

test "eval: context fallbacks by capability" {
    {
        var f: Fixture = undefined;
        try f.init("eval_contexts_caps.txt", .{});
        defer f.deinit();
        var g: Got = .{};
        f.insp.eval.evaluate("a", .hover, 1, g.cb());
        f.insp.eval.evaluate("b", .clipboard, 1, g.cb());
        try f.insp.settle(.fromSeconds(10));
        try testing.expectEqual(@as(u32, 2), g.calls);
        try testing.expectEqualStrings("2", g.text());
        try f.finish();
    }
    // Without the capabilities (the script checks the contexts sent).
    var f: Fixture = undefined;
    try f.init("eval_contexts_plain.txt", .{});
    defer f.deinit();
    var g: Got = .{};
    f.insp.eval.evaluate("a", .hover, 1, g.cb());
    f.insp.eval.evaluate("b", .clipboard, 1, g.cb());
    f.insp.eval.evaluate("c", .repl, 1, g.cb());
    try f.insp.settle(.fromSeconds(10));
    try testing.expectEqualStrings("3", g.text());
    // hover never uses repl unless setting
    f.insp.opts.hover_with_repl = true;
    try testing.expectEqualStrings("repl", f.insp.eval.contextName(.hover));
    f.insp.eval.evaluate("d", .hover, 1, g.cb());
    try f.insp.settle(.fromSeconds(10));
    try testing.expectEqual(@as(u32, 4), g.calls);
    try testing.expect(!g.err);
    try f.finish();
}

test "eval: repl variablesReference expandable and kept until resume" {
    var f: Fixture = undefined;
    try f.init("eval_repl.txt", .{});
    defer f.deinit();
    const m = f.vars();
    var g: Got = .{};
    f.insp.eval.evaluate("s", .repl, 1, g.cb());
    try f.insp.settle(.fromSeconds(10));
    const root = g.node.?;
    try testing.expectEqualStrings("s", m.node(root).?.name);
    try testing.expectEqualStrings("S", m.node(root).?.type.?);
    m.expand(root, true);
    try f.insp.settle(.fromSeconds(10));
    _ = try f.child(root, "a");
    // After the resume the root's reference is gone: stale, no request.
    f.s.continue_(1);
    try f.fwd.settleAfter(.continued, 1);
    try testing.expect(m.children(root, null) == .stale);
    // REPL input still works while running (global scope), no root.
    f.insp.eval.evaluate("g", .repl, null, g.cb());
    try f.insp.settle(.fromSeconds(10));
    try testing.expectEqualStrings("7", g.text());
    try testing.expect(g.node == null);
    try f.finish();
}

const Items = struct {
    labels: std.ArrayList([]u8) = .empty,
    texts: std.ArrayList([]u8) = .empty,

    fn on(ctx: ?*anyopaque, items: []const Evaluator.ComplItem) void {
        const it: *Items = @ptrCast(@alignCast(ctx.?));
        for (items) |i| {
            it.labels.append(gpa, gpa.dupe(u8, i.label) catch return) catch return;
            it.texts.append(gpa, gpa.dupe(u8, i.text) catch return) catch return;
        }
    }

    fn deinit(it: *Items) void {
        for (it.labels.items) |l| gpa.free(l);
        for (it.texts.items) |l| gpa.free(l);
        it.labels.deinit(gpa);
        it.texts.deinit(gpa);
    }
};

test "completions: request columns and local ranking" {
    var f: Fixture = undefined;
    try f.init("completions.txt", .{});
    defer f.deinit();
    // Single-character triggers only.
    try testing.expectEqualStrings(".", f.insp.eval.triggerCharacters());
    var items: Items = .{};
    defer items.deinit();
    // Cursor at the end (byte 6): column 7.
    f.insp.eval.completions("foo.ba", 6, 1, .{ .ctx = &items, .func = Items.on });
    try f.insp.settle(.fromSeconds(10));
    try testing.expectEqual(@as(usize, 3), items.labels.items.len);
    try testing.expectEqualStrings("bar", items.labels.items[0]);
    try testing.expectEqualStrings("bar()", items.texts.items[0]);
    try testing.expectEqualStrings("baz_long", items.labels.items[1]);
    try testing.expectEqualStrings("bxa", items.labels.items[2]);
    try f.finish();
}
