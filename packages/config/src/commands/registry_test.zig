//! CommandRegistry tests.

const std = @import("std");
const reg_mod = @import("registry.zig");
const context = @import("../when/context.zig");
const schema = @import("../schema.zig");
const Value = @import("../value.zig").Value;

const CommandRegistry = reg_mod.CommandRegistry;
const CommandId = reg_mod.CommandId;
const Invocation = reg_mod.Invocation;
const gpa = std.testing.allocator;

const Fixture = struct {
    keys: context.ContextKeyService,
    r: *CommandRegistry,

    fn init(f: *Fixture) !void {
        f.keys = .init(gpa);
        f.r = try CommandRegistry.init(gpa, &f.keys, .{ .io = std.testing.io });
        try reg_mod.registerBuiltins(f.r);
    }

    fn deinit(f: *Fixture) void {
        f.r.deinit();
        f.keys.deinit();
    }
};

const Counter = struct {
    n: u32 = 0,
    last_arg: i64 = 0,

    fn handler(c: *Counter) reg_mod.Handler {
        return .{ .ctx = c, .run = run };
    }

    fn run(ctx: ?*anyopaque, inv: *Invocation) anyerror!void {
        const c: *Counter = @ptrCast(@alignCast(ctx.?));
        c.n += 1;
        if (inv.args) |a| if (a.get("n")) |n| {
            c.last_arg = n.int;
        };
        inv.result.setText("done");
    }
};

const n_args: schema.SettingDef = .{ .key = "args", .type = .object, .properties = &.{.{ .key = "n", .type = .int, .minimum = 0 }} };

test "registry: register/lookup/get" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var c: Counter = .{};
    const id = try f.r.register(.{ .id = "test.count", .title = "Count", .category = "Test", .handler = c.handler() });
    try std.testing.expectEqual(id, f.r.lookup("test.count").?);
    try std.testing.expectEqualStrings("Count", f.r.get(id).title);
    try std.testing.expect(f.r.lookup("nope") == null);
    try f.r.execute(id, null, .palette);
    try std.testing.expectEqual(@as(u32, 1), c.n);
    // ActionId <-> CommandId is a plain integer cast.
    const action: u32 = @intFromEnum(id);
    try std.testing.expectEqual(id, @as(CommandId, @enumFromInt(action)));
    var n: usize = 0;
    var it = f.r.iterate();
    while (it.next()) |_| n += 1;
    try std.testing.expectEqual(@as(usize, 4), n);
}

test "registry: duplicate id, invalid id, invalid when" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.r.register(.{ .id = "a.b", .title = "A" });
    try std.testing.expectError(error.DuplicateId, f.r.register(.{ .id = "a.b", .title = "A" }));
    try std.testing.expectError(error.InvalidId, f.r.register(.{ .id = "has space", .title = "A" }));
    try std.testing.expectError(error.InvalidWhen, f.r.register(.{ .id = "a.c", .title = "A", .enablement = "a &&" }));
}

test "registry: enablement blocks execute" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var c: Counter = .{};
    const id = try f.r.register(.{ .id = "editor.format", .title = "Format", .enablement = "editorTextFocus && !editorReadonly", .handler = c.handler() });
    try std.testing.expectError(error.Disabled, f.r.execute(id, null, .keybinding));
    try f.keys.setByName("editorTextFocus", .{ .bool = true });
    try f.r.execute(id, null, .keybinding);
    try std.testing.expectEqual(@as(u32, 1), c.n);
    const env: context.EvalEnv = .{ .global = &f.keys };
    try std.testing.expect(f.r.isEnabled(id, &env));
}

test "registry: args schema validation (ok/err)" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var c: Counter = .{};
    const id = try f.r.register(.{ .id = "t.args", .title = "Args", .args = &n_args, .handler = c.handler() });
    const ok: Value = .{ .object = &.{.{ .key = "n", .value = .{ .int = 5 } }} };
    try f.r.execute(id, ok, .api);
    try std.testing.expectEqual(@as(i64, 5), c.last_arg);
    const bad: Value = .{ .object = &.{.{ .key = "n", .value = .{ .int = -1 } }} };
    try std.testing.expectError(error.InvalidArgs, f.r.execute(id, bad, .api));
    const noargs = try f.r.register(.{ .id = "t.noargs", .title = "No args", .handler = c.handler() });
    try std.testing.expectError(error.InvalidArgs, f.r.execute(noargs, ok, .api));
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const res = try f.r.executeJson(arena.allocator(), id, "{\"n\": 7}", .{ .agent = .{ .session = 1, .tool_call = 2 } });
    try std.testing.expectEqualStrings("done", res.text.?);
    try std.testing.expectEqual(@as(i64, 7), c.last_arg);
}

test "registry: runCommands sequence and error stop" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var c: Counter = .{};
    _ = try f.r.register(.{ .id = "t.count", .title = "Count", .handler = c.handler() });
    const run = f.r.lookup("workbench.runCommands").?;
    const seq: Value = .{ .object = &.{.{ .key = "commands", .value = .{ .array = &.{
        .{ .object = &.{.{ .key = "id", .value = .{ .string = "t.count" } }} },
        .{ .object = &.{.{ .key = "id", .value = .{ .string = "t.count" } }} },
        .{ .object = &.{.{ .key = "id", .value = .{ .string = "missing.cmd" } }} },
        .{ .object = &.{.{ .key = "id", .value = .{ .string = "t.count" } }} },
    } } }} };
    try std.testing.expectError(error.UnknownCommand, f.r.execute(run, seq, .macro));
    try std.testing.expectEqual(@as(u32, 2), c.n);
    const by_id = f.r.lookup("workbench.runCommandById").?;
    try f.r.execute(by_id, .{ .object = &.{.{ .key = "id", .value = .{ .string = "t.count" } }} }, .api);
    try std.testing.expectEqual(@as(u32, 3), c.n);
}

test "registry: recursion depth guard" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const Rec = struct {
        fn run(_: ?*anyopaque, inv: *Invocation) anyerror!void {
            return inv.registry.execute(inv.id, null, .macro);
        }
    };
    const id = try f.r.register(.{ .id = "t.loop", .title = "Loop", .handler = .{ .ctx = null, .run = Rec.run } });
    try std.testing.expectError(error.Canceled, f.r.execute(id, null, .api));
    try std.testing.expectEqual(@as(u32, 0), f.r.depth);
}

const FakeHost = struct {
    activations: u32 = 0,
    fn activator(h: *FakeHost) reg_mod.Activator {
        return .{ .ctx = h, .activate = act };
    }
    fn act(ctx: ?*anyopaque, _: CommandId) void {
        const h: *FakeHost = @ptrCast(@alignCast(ctx.?));
        h.activations += 1;
    }
};

const Done = struct {
    ok: u32 = 0,
    failed: u32 = 0,
    fn completion(d: *Done) reg_mod.Completion {
        return .{ .ctx = d, .cb = cb };
    }
    fn cb(ctx: ?*anyopaque, err: ?anyerror, _: ?*const reg_mod.Result) void {
        const d: *Done = @ptrCast(@alignCast(ctx.?));
        if (err == null) d.ok += 1 else d.failed += 1;
    }
};

test "registry: lazy activation queues and replays" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var host: FakeHost = .{};
    var c: Counter = .{};
    const id = try f.r.registerLazy(.{ .id = "ext.hello", .title = "Hello", .args = &n_args, .source = .{ .extension = "hello" } }, host.activator());
    try f.r.execute(id, null, .palette);
    try f.r.execute(id, .{ .object = &.{.{ .key = "n", .value = .{ .int = 3 } }} }, .palette);
    try std.testing.expectEqual(@as(u32, 1), host.activations);
    try std.testing.expectEqual(@as(u32, 0), c.n);
    f.r.setHandler(id, c.handler());
    try std.testing.expectEqual(@as(u32, 2), c.n);
    try std.testing.expectEqual(@as(i64, 3), c.last_arg);
    try f.r.execute(id, null, .palette);
    try std.testing.expectEqual(@as(u32, 3), c.n);
}

test "registry: activation timeout fails queued" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var host: FakeHost = .{};
    var done: Done = .{};
    const id = try f.r.registerLazy(.{ .id = "ext.slow", .title = "Slow" }, host.activator());
    f.r.post(id, null, .palette, done.completion());
    f.r.drainPosted();
    try std.testing.expectEqual(@as(u32, 1), done.ok); // queued, not yet failed
    f.r.records.items[@intFromEnum(id) - 1].queued.items[0].done = done.completion();
    f.r.tick(std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds + 11 * std.time.ns_per_s);
    try std.testing.expectEqual(@as(u32, 1), done.failed);
    try std.testing.expectEqual(@as(usize, 0), f.r.records.items[@intFromEnum(id) - 1].queued.items.len);
}

test "registry: unregisterSource tombstones" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const id = try f.r.register(.{ .id = "ext.a", .title = "A", .source = .{ .extension = "x" } });
    _ = try f.r.register(.{ .id = "ext.b", .title = "B", .source = .{ .extension = "y" } });
    const g = f.r.generation();
    f.r.unregisterSource(.{ .extension = "x" });
    try std.testing.expect(f.r.lookup("ext.a") == null);
    try std.testing.expect(f.r.lookup("ext.b") != null);
    try std.testing.expectError(error.UnknownCommand, f.r.execute(id, null, .api));
    try std.testing.expect(f.r.generation() > g);
    const again = try f.r.register(.{ .id = "ext.a", .title = "A", .source = .{ .extension = "x" } });
    try std.testing.expect(again != id);
}

test "registry: post from worker thread completes" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var c: Counter = .{};
    var done: Done = .{};
    const id = try f.r.register(.{ .id = "t.count", .title = "Count", .handler = c.handler() });
    const T = struct {
        fn run(r: *CommandRegistry, cid: CommandId, d: *Done) void {
            for (0..10) |_| r.post(cid, null, .api, d.completion());
        }
    };
    const th = try std.Thread.spawn(.{}, T.run, .{ f.r, id, &done });
    th.join();
    f.r.drainPosted();
    try std.testing.expectEqual(@as(u32, 10), c.n);
    try std.testing.expectEqual(@as(u32, 10), done.ok);
}

test "registry: history ring order" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var c: Counter = .{};
    const a = try f.r.register(.{ .id = "t.a", .title = "A", .handler = c.handler() });
    const b = try f.r.register(.{ .id = "t.b", .title = "B", .handler = c.handler() });
    try f.r.execute(a, null, .palette);
    try f.r.execute(b, null, .keybinding);
    var buf: [4]reg_mod.HistoryEntry = undefined;
    const h = f.r.history(&buf);
    try std.testing.expectEqual(@as(usize, 2), h.len);
    try std.testing.expectEqual(b, h[0].id);
    try std.testing.expectEqual(std.meta.Tag(reg_mod.Origin).keybinding, h[0].origin_tag);
    try std.testing.expectEqual(a, h[1].id);
}

test "registry: executeArgText interned hit and miss parse" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var c: Counter = .{};
    const id = try f.r.register(.{ .id = "t.args", .title = "Args", .args = &n_args, .handler = c.handler() });
    const text = ".{ .n = 4 }";
    try f.r.internArgs(text, .{ .object = &.{.{ .key = "n", .value = .{ .int = 9 } }} });
    try f.r.executeArgText(id, text, .keybinding);
    try std.testing.expectEqual(@as(i64, 9), c.last_arg); // the interned value, not a parse
    const other = try gpa.dupe(u8, ".{ .n = 4 }");
    defer gpa.free(other);
    try f.r.executeArgText(id, other, .keybinding);
    try std.testing.expectEqual(@as(i64, 4), c.last_arg);
    try std.testing.expectEqual(@as(u32, 1), f.r.arg_text_cache.count());
    try f.r.executeArgText(id, null, .keybinding);
}
