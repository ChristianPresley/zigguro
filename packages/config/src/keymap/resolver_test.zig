//! Keymap and Resolver tests.

const std = @import("std");
const keys = @import("keys.zig");
const keymap_mod = @import("keymap.zig");
const resolver_mod = @import("resolver.zig");
const registry = @import("../commands/registry.zig");
const context = @import("../when/context.zig");
const zon_load = @import("../zon_load.zig");
const diag = @import("../diag.zig");
const schema = @import("../schema.zig");

const testing = std.testing;
const gpa = testing.allocator;
const Keymap = keymap_mod.Keymap;
const LayerInput = keymap_mod.LayerInput;
const Resolver = resolver_mod.Resolver;
const Resolution = resolver_mod.Resolution;
const CommandId = registry.CommandId;
const KeyInput = keys.KeyInput;
const ms = std.time.ns_per_ms;

// HID usages used below.
const key_a = 0x04;
const key_k = 0x0E;
const key_p = 0x13;
const key_s = 0x16;
const key_w = 0x1A;
const key_x = 0x1B;
const ctrl_l = 0xE0;
const shift_l = 0xE1;

const Counter = struct {
    n: u32 = 0,
    last: i64 = 0,

    fn run(ctx: ?*anyopaque, inv: *registry.Invocation) anyerror!void {
        const c: *Counter = @ptrCast(@alignCast(ctx.?));
        c.n += 1;
        if (inv.args) |a| if (a.get("n")) |n| {
            c.last = n.int;
        };
    }
};

const n_args: schema.SettingDef = .{ .key = "args", .type = .object, .properties = &.{.{ .key = "n", .type = .int }} };

const Fx = struct {
    ctx: context.ContextKeyService,
    reg: *registry.CommandRegistry,
    docs: std.ArrayList(zon_load.Doc) = .empty,
    inputs: std.ArrayList(LayerInput) = .empty,
    diags: diag.Diags,
    km: ?*Keymap = null,
    r: *Resolver,
    counter: Counter = .{},

    fn init(f: *Fx) !void {
        f.* = .{ .ctx = .init(gpa), .reg = undefined, .diags = .init(gpa), .r = undefined };
        f.reg = try registry.CommandRegistry.init(gpa, &f.ctx, .{ .io = testing.io });
        try registry.registerBuiltins(f.reg);
        const h: registry.Handler = .{ .ctx = &f.counter, .run = Counter.run };
        inline for (.{ "palette.show", "file.save", "file.open", "edit.selectAll", "kb.open", "search.everywhere", "term.close", "edit.left", "edit.inline", "pane.toggle" }) |cmd_id| {
            _ = try f.reg.register(.{ .id = cmd_id, .title = cmd_id, .handler = h, .args = &n_args, .repeat = !std.mem.eql(u8, cmd_id, "pane.toggle") });
        }
        f.r = try Resolver.init(gpa, &f.ctx, &keys.us_layout, .{ .platform = .linux });
    }

    fn deinit(f: *Fx) void {
        f.r.deinit();
        if (f.km) |k| k.deinit();
        for (f.docs.items) |*d| d.deinit();
        f.docs.deinit(gpa);
        f.inputs.deinit(gpa);
        f.diags.deinit();
        f.reg.deinit();
        f.ctx.deinit();
    }

    fn layer(f: *Fx, kind: keymap_mod.LayerKind, src: [:0]const u8) !void {
        _ = kind;
        try f.docs.append(gpa, try zon_load.loadZon(gpa, src, &f.diags));
    }

    /// Builds from the layers added so far (`kinds` in the same order).
    fn build(f: *Fx, kinds: []const keymap_mod.LayerKind) !void {
        f.inputs.clearRetainingCapacity();
        for (f.docs.items, kinds) |*d, k| try f.inputs.append(gpa, .{ .layer = k, .doc = d });
        if (f.km) |k| k.deinit();
        f.km = try Keymap.build(gpa, f.inputs.items, f.reg, &f.ctx, .linux, &f.diags);
        f.r.reload(f.km.?);
    }

    fn id(f: *Fx, name: []const u8) CommandId {
        return f.reg.lookup(name).?;
    }

    fn press(f: *Fx, usage: keys.Usage, m: keys.EventMods, t_ms: u64) Resolution {
        return f.r.resolve(&.{}, .{ .usage = usage, .mods = m, .t_ns = t_ms * ms });
    }
};

fn expectAction(f: *Fx, res: Resolution, name: []const u8) !void {
    switch (res) {
        .action => |a| try testing.expectEqualStrings(name, f.reg.get(a.id).id),
        else => {
            std.debug.print("expected action {s}, got {any}\n", .{ name, res });
            return error.TestUnexpectedResult;
        },
    }
}

const ctrl: keys.EventMods = .{ .ctrl = true };
const ctrl_shift: keys.EventMods = .{ .ctrl = true, .shift = true };

test "resolver: single stroke, unbound and logical vs physical" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try f.layer(.builtin_default,
        \\.{
        \\    .{ .key = "mod+shift+p", .command = "palette.show" },
        \\    .{ .key = "ctrl+[KeyA]", .command = "edit.selectAll" },
        \\}
    );
    try f.build(&.{.builtin_default});
    try testing.expectEqual(@as(usize, 0), f.diags.errorCount());
    try expectAction(&f, f.press(key_p, ctrl_shift, 0), "palette.show");
    try expectAction(&f, f.press(key_a, ctrl, 0), "edit.selectAll");
    try testing.expect(f.press(key_s, ctrl, 0) == .none);
    try testing.expect(f.press(key_p, .{}, 0) == .none);
}

test "keymap: layer priority, removal and disable" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try f.layer(.user,
        \\.{
        \\    .{ .key = "ctrl+s", .command = "file.open" },
        \\    .{ .key = "ctrl+a", .command = "-edit.selectAll" },
        \\    .{ .key = "", .command = "-kb.open" },
        \\    .{ .key = "ctrl+w", .command = null, .when = "terminalFocus" },
        \\    .{ .key = "ctrl+x", .command = "noop" },
        \\}
    );
    try f.layer(.builtin_default,
        \\.{
        \\    .{ .key = "ctrl+s", .command = "file.save" },
        \\    .{ .key = "ctrl+a", .command = "edit.selectAll" },
        \\    .{ .key = "ctrl+o", .command = "kb.open" },
        \\    .{ .key = "ctrl+p", .command = "kb.open" },
        \\    .{ .key = "ctrl+w", .command = "term.close" },
        \\}
    );
    // Inputs given user-first: the build sorts by layer.
    try f.build(&.{ .user, .builtin_default });
    try testing.expectEqual(@as(usize, 0), f.diags.errorCount());
    try expectAction(&f, f.press(key_s, ctrl, 0), "file.open");
    try testing.expect(f.press(key_a, ctrl, 0) == .none);
    try testing.expect(f.press(0x12, ctrl, 0) == .none); // ctrl+o removed
    try testing.expect(f.press(key_p, ctrl, 0) == .none); // ctrl+p removed
    // Disabled only in the terminal: passes through there, fires elsewhere.
    const term: []const context.KeyContext = &.{.{ .name = "terminalFocus" }};
    try testing.expect(f.r.resolve(term, .{ .usage = key_w, .mods = ctrl }) == .none);
    try expectAction(&f, f.press(key_w, ctrl, 0), "term.close");
    // noop swallows.
    try expectAction(&f, f.press(key_x, ctrl, 0), "noop");
}

test "resolver: chords, mismatch and escape" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try f.layer(.builtin_default,
        \\.{
        \\    .{ .key = "mod+k mod+s", .command = "kb.open" },
        \\    .{ .key = "mod+k mod+p mod+s", .command = "file.save" },
        \\}
    );
    try f.build(&.{.builtin_default});
    const p = f.press(key_k, ctrl, 0);
    try testing.expectEqualStrings("Ctrl+K", p.pending);
    try testing.expect(f.r.deadline() == null); // no exact prefix: waits forever
    try expectAction(&f, f.press(key_s, ctrl, 5000), "kb.open");
    try testing.expect(!f.r.isPending());

    // Three strokes.
    _ = f.press(key_k, ctrl, 0);
    try testing.expectEqualStrings("Ctrl+K, Ctrl+P", f.press(key_p, ctrl, 1).pending);
    try expectAction(&f, f.press(key_s, ctrl, 2), "file.save");

    // Mismatch swallows with a message.
    _ = f.press(key_k, ctrl, 0);
    const m = f.press(key_x, .{}, 1);
    try testing.expectEqualStrings("(Ctrl+K, X) is not a command", m.swallow);
    try testing.expect(!f.r.isPending());

    // Passthrough option.
    f.r.setOptions(.{ .platform = .linux, .mismatch = .passthrough });
    _ = f.press(key_k, ctrl, 0);
    try testing.expect(f.press(key_x, .{}, 1) == .none);

    // Escape cancels.
    _ = f.press(key_k, ctrl, 0);
    try testing.expect(f.press(keys.escape, .{}, 1) == .swallow);
    try testing.expect(!f.r.isPending());
    try testing.expect(f.press(key_s, ctrl, 2) == .none);
}

test "resolver: exact prefix with timeout and early fire" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try f.layer(.builtin_default,
        \\.{
        \\    .{ .key = "mod+k", .command = "edit.inline" },
        \\    .{ .key = "mod+k mod+s", .command = "kb.open" },
        \\    .{ .key = "mod+s", .command = "file.save" },
        \\}
    );
    try f.build(&.{.builtin_default});
    try testing.expect(f.press(key_k, ctrl, 100) == .pending);
    try testing.expectEqual(@as(?u64, (100 + 1000) * ms), f.r.deadline());
    try testing.expect(f.r.onTimer(500 * ms) == null);
    try expectAction(&f, f.r.onTimer(1100 * ms).?, "edit.inline");
    try testing.expect(!f.r.isPending());

    // Continue in time.
    _ = f.press(key_k, ctrl, 0);
    try expectAction(&f, f.press(key_s, ctrl, 10), "kb.open");

    // A key that does not continue fires the prefix and is then processed.
    _ = f.press(key_k, ctrl, 0);
    try expectAction(&f, f.press(key_a, .{}, 10), "edit.inline");
    try testing.expect(f.r.takeDeferred().? == .none);
}

test "resolver: repeat and double tap" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try f.layer(.preset,
        \\.{
        \\    .{ .key = "shift shift", .command = "search.everywhere" },
        \\    .{ .key = "left", .command = "edit.left" },
        \\    .{ .key = "ctrl+b", .command = "pane.toggle" },
        \\}
    );
    try f.build(&.{.preset});
    const left = 0x50;
    try expectAction(&f, f.r.resolve(&.{}, .{ .usage = left, .action = .repeat }), "edit.left");
    try testing.expect(f.r.resolve(&.{}, .{ .usage = 0x05, .mods = ctrl, .action = .repeat }) == .none);
    try expectAction(&f, f.press(0x05, ctrl, 0), "pane.toggle");

    const sh: keys.EventMods = .{ .shift = true };
    try testing.expect(f.r.resolve(&.{}, .{ .usage = shift_l, .mods = sh, .t_ns = 0 }) == .none);
    try testing.expect(f.r.resolve(&.{}, .{ .usage = shift_l, .action = .release, .t_ns = 50 * ms }) == .none);
    try testing.expect(f.r.resolve(&.{}, .{ .usage = shift_l, .mods = sh, .t_ns = 120 * ms }) == .none);
    try expectAction(&f, f.r.resolve(&.{}, .{ .usage = shift_l, .action = .release, .t_ns = 180 * ms }), "search.everywhere");

    // Too slow.
    _ = f.r.resolve(&.{}, .{ .usage = shift_l, .mods = sh, .t_ns = 1000 * ms });
    _ = f.r.resolve(&.{}, .{ .usage = shift_l, .action = .release, .t_ns = 1010 * ms });
    _ = f.r.resolve(&.{}, .{ .usage = shift_l, .mods = sh, .t_ns = 1500 * ms });
    try testing.expect(f.r.resolve(&.{}, .{ .usage = shift_l, .action = .release, .t_ns = 1510 * ms }) == .none);

    // A key in between resets.
    _ = f.r.resolve(&.{}, .{ .usage = shift_l, .mods = sh, .t_ns = 3000 * ms });
    _ = f.r.resolve(&.{}, .{ .usage = shift_l, .action = .release, .t_ns = 3010 * ms });
    _ = f.r.resolve(&.{}, .{ .usage = key_a, .t_ns = 3020 * ms });
    _ = f.r.resolve(&.{}, .{ .usage = shift_l, .mods = sh, .t_ns = 3030 * ms });
    try testing.expect(f.r.resolve(&.{}, .{ .usage = shift_l, .action = .release, .t_ns = 3040 * ms }) == .none);

    // Shift held as a modifier for another key is not a tap.
    _ = f.r.resolve(&.{}, .{ .usage = shift_l, .mods = sh, .t_ns = 5000 * ms });
    _ = f.r.resolve(&.{}, .{ .usage = key_a, .mods = sh, .t_ns = 5010 * ms });
    _ = f.r.resolve(&.{}, .{ .usage = shift_l, .action = .release, .t_ns = 5020 * ms });
    _ = f.r.resolve(&.{}, .{ .usage = shift_l, .mods = sh, .t_ns = 5030 * ms });
    try testing.expect(f.r.resolve(&.{}, .{ .usage = shift_l, .action = .release, .t_ns = 5040 * ms }) == .none);
    _ = ctrl_l;
}

test "keymap: args are interned and executed without parsing" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try f.layer(.user,
        \\.{ .{ .key = "ctrl+1", .command = "file.open", .args = .{ .n = 3 } } }
    );
    try f.build(&.{.user});
    const res = f.press(0x1E, ctrl, 0);
    try expectAction(&f, res, "file.open");
    try testing.expectEqualStrings(".{ .n = 3 }", res.action.arg.?);
    try f.reg.executeArgText(res.action.id, res.action.arg, .keybinding);
    try testing.expectEqual(@as(i64, 3), f.counter.last);
}

test "resolver: labels, shadowing, continuations and late registration" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try f.layer(.builtin_default,
        \\.{
        \\    .{ .key = "mod+shift+p", .command = "palette.show" },
        \\    .{ .key = "f1", .command = "palette.show" },
        \\    .{ .key = "mod+s", .command = "file.save" },
        \\    .{ .key = "mod+k mod+s", .command = "kb.open" },
        \\    .{ .key = "mod+k mod+o", .command = "file.open" },
        \\    .{ .key = "mod+e", .command = "ext.late" },
        \\}
    );
    try f.layer(.user,
        \\.{ .{ .key = "f1", .command = "file.save", .when = "editorFocus" } }
    );
    try f.build(&.{ .builtin_default, .user });
    try testing.expect(f.diags.contains("'ext.late' is not registered"));
    // f1 is only shadowed under editorFocus, so the later f1 binding still labels palette.show.
    try testing.expectEqualStrings("F1", f.r.labelFor(f.id("palette.show"), null).?);
    try testing.expectEqualStrings("F1", f.r.labelFor(f.id("file.save"), &.{.{ .name = "editorFocus" }}).?);
    try testing.expectEqualStrings("Ctrl+S", f.r.labelFor(f.id("file.save"), &.{}).?);
    try testing.expectEqualStrings("Ctrl+K, Ctrl+S", f.r.labelFor(f.id("kb.open"), null).?);
    try testing.expect(f.r.labelFor(f.id("term.close"), null) == null);

    _ = f.press(key_k, ctrl, 0);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var conts: std.ArrayList(resolver_mod.Continuation) = .empty;
    try f.r.continuations(arena.allocator(), &.{}, &conts);
    try testing.expectEqual(@as(usize, 2), conts.items.len);
    var saw_s = false;
    for (conts.items) |c| if (std.mem.eql(u8, c.label, "Ctrl+S")) {
        saw_s = true;
        try testing.expectEqualStrings("kb.open", c.command);
    };
    try testing.expect(saw_s);
    _ = f.press(keys.escape, .{}, 1);

    // The extension registers later: the binding comes alive.
    try testing.expect(f.press(0x08, ctrl, 0) == .none);
    _ = try f.reg.register(.{ .id = "ext.late", .title = "Late" });
    try expectAction(&f, f.press(0x08, ctrl, 0), "ext.late");
}

test "keymap: diagnostics point into the file" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const src =
        \\.{
        \\    .{ .key = "ctrl+[Nope]", .command = "file.save" },
        \\    .{ .key = "ctrl+s", .command = "file.save", .when = "a &&" },
        \\    .{ .command = "file.save" },
        \\    .{ .key = "ctrl+q", .command = "-nothing" },
        \\    .{ .key = "ctrl+s", .command = "file.save", .bogus = 1 },
        \\}
    ;
    try f.layer(.user, src);
    try f.build(&.{.user});
    const items = f.diags.items();
    try testing.expect(items.len >= 5);
    try testing.expectEqualStrings("[Nope]", items[0].span.slice(src));
    try testing.expect(f.diags.contains("no 'key'"));
    try testing.expect(f.diags.contains("matches no binding"));
    try testing.expect(f.diags.contains("unknown keybinding field 'bogus'"));
    try testing.expectEqual(@as(usize, 1), f.km.?.bindings.len);
}
