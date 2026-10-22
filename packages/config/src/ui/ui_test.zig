//! The keymap adapter and command palette in a headless zg_gui window
//! (E15.F04.S01.T02, E15.F03.S02.T01).

const std = @import("std");
const zg_gui = @import("zg_gui");
const keys = @import("../keymap/keys.zig");
const keymap_mod = @import("../keymap/keymap.zig");
const resolver_mod = @import("../keymap/resolver.zig");
const registry = @import("../commands/registry.zig");
const context = @import("../when/context.zig");
const zon_load = @import("../zon_load.zig");
const diag = @import("../diag.zig");
const schema = @import("../schema.zig");
const adapter_mod = @import("keymap_adapter.zig");
const palette_mod = @import("palette/provider.zig");

const testing = std.testing;
const gpa = testing.allocator;
const Ui = zg_gui.Ui;
const TestApp = zg_gui.testing.TestApp;
const TextBuffer = zg_gui.w.text_field.TextBuffer;

/// A text field inside an "editorFocus" context, and a plain button.
const Page = struct {
    buf: TextBuffer,

    pub fn build(self: *Page, ui: *Ui) void {
        ui.open(.{ .style = .{ .padding = .all(10), .gap = 8 } });
        defer ui.close();
        ui.open(.{ .key_context = "editorFocus editorTextFocus langId=zig" });
        _ = zg_gui.w.text_field.textField(ui, .{ .buffer = &self.buf, .a11y_label = "editor" });
        ui.close();
        _ = zg_gui.w.controls.button(ui, .{ .label = "Plain" });
    }
};

const Rec = struct {
    runs: [16]struct { id: []const u8, n: i64, origin: std.meta.Tag(registry.Origin) } = undefined,
    len: usize = 0,

    fn run(ctx: ?*anyopaque, inv: *registry.Invocation) anyerror!void {
        const r: *Rec = @ptrCast(@alignCast(ctx.?));
        var n: i64 = 0;
        if (inv.args) |a| if (a.get("n")) |v| {
            n = v.int;
        };
        r.runs[r.len] = .{ .id = inv.registry.get(inv.id).id, .n = n, .origin = std.meta.activeTag(inv.origin) };
        r.len += 1;
    }

    fn last(r: *const Rec) ?[]const u8 {
        return if (r.len > 0) r.runs[r.len - 1].id else null;
    }
};

const n_args: schema.SettingDef = .{ .key = "args", .type = .object, .properties = &.{.{ .key = "n", .type = .int }} };

const keymap_src =
    \\.{
    \\    .{ .key = "mod+shift+p", .command = "workbench.showCommands" },
    \\    .{ .key = "mod+s", .command = "file.save", .args = .{ .n = 7 } },
    \\    .{ .key = "mod+f", .command = "editor.find", .when = "editorFocus" },
    \\    .{ .key = "mod+l", .command = "editor.zigOnly", .when = "langId == zig" },
    \\    .{ .key = "mod+k mod+s", .command = "keys.open" },
    \\    .{ .key = "mod+k x", .command = "chord.x" },
    \\    .{ .key = "mod+j", .command = "panel.toggle" },
    \\    .{ .key = "mod+j mod+j", .command = "panel.maximize" },
    \\}
;

const Fx = struct {
    ctx: context.ContextKeyService,
    reg: *registry.CommandRegistry,
    doc: zon_load.Doc,
    diags: diag.Diags,
    km: *keymap_mod.Keymap,
    r: *resolver_mod.Resolver,
    page: Page,
    t: *TestApp,
    adapter: adapter_mod.KeymapAdapter,
    palette: palette_mod.PaletteProvider,
    rec: Rec = .{},

    fn init(f: *Fx) !void {
        f.rec = .{};
        f.ctx = .init(gpa);
        f.diags = .init(gpa);
        f.reg = try registry.CommandRegistry.init(gpa, &f.ctx, .{ .io = testing.io });
        try registry.registerBuiltins(f.reg);
        const h: registry.Handler = .{ .ctx = &f.rec, .run = Rec.run };
        inline for (.{ "file.save", "editor.find", "editor.zigOnly", "keys.open", "chord.x", "panel.toggle", "panel.maximize" }) |id| {
            _ = try f.reg.register(.{ .id = id, .title = id, .handler = h, .args = &n_args, .category = if (std.mem.eql(u8, id, "file.save")) "File" else null });
        }
        _ = try f.reg.register(.{ .id = "secret.hidden", .title = "Hidden", .palette = .hidden, .handler = h });
        _ = try f.reg.register(.{ .id = "editor.only", .title = "Editor Only", .palette_when = "editorFocus", .handler = h });
        f.page = .{ .buf = try .init(gpa, "") };
        f.t = try TestApp.init(gpa, .{ .root = .of(&f.page), .size = .{ .w = 800, .h = 600 } });
        f.r = try resolver_mod.Resolver.init(gpa, &f.ctx, &keys.us_layout, .{ .platform = .linux });
        f.adapter = .init(gpa, f.reg, f.r, f.t.win);
        f.adapter.install();
        f.palette = .init(gpa, f.reg, &f.adapter);
        try f.palette.registerCommands();
        f.doc = try zon_load.loadZon(gpa, keymap_src, &f.diags);
        f.km = try keymap_mod.Keymap.build(gpa, &.{.{ .layer = .builtin_default, .doc = &f.doc }}, f.reg, &f.ctx, .linux, &f.diags);
        f.r.reload(f.km);
        _ = f.t.settle();
    }

    fn deinit(f: *Fx) void {
        f.palette.handle.close(f.t.win);
        f.adapter.deinit();
        f.t.deinit();
        f.palette.deinit();
        f.r.deinit();
        f.km.deinit();
        f.doc.deinit();
        f.page.buf.deinit();
        f.reg.deinit();
        f.diags.deinit();
        f.ctx.deinit();
    }

    fn focusEditor(f: *Fx) !void {
        try f.t.click(.{ .role = .textbox });
    }

    /// A character key as the platform sends it: the key, then its text.
    fn typeKey(f: *Fx, key: zg_gui.input.event.KeyPress, text: []const u8) void {
        f.t.win.dispatch(.{ .key = key });
        f.t.win.dispatch(.{ .text = text });
        var up = key;
        up.action = .release;
        f.t.win.dispatch(.{ .key = up });
        _ = f.t.settle();
    }
};

test "adapter: a binding runs its command with its args through the registry" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try testing.expectEqual(@as(usize, 0), f.diags.errorCount());
    f.t.press(.key_s, .{ .ctrl = true });
    try testing.expectEqualStrings("file.save", f.rec.last().?);
    try testing.expectEqual(@as(i64, 7), f.rec.runs[0].n);
    try testing.expectEqual(.keybinding, f.rec.runs[0].origin);
}

test "adapter: when-clauses see the focus path's key contexts" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    f.t.press(.key_f, .{ .ctrl = true });
    f.t.press(.key_l, .{ .ctrl = true });
    try testing.expectEqual(@as(usize, 0), f.rec.len);
    try f.focusEditor();
    f.t.press(.key_f, .{ .ctrl = true });
    try testing.expectEqualStrings("editor.find", f.rec.last().?);
    f.t.press(.key_l, .{ .ctrl = true });
    try testing.expectEqualStrings("editor.zigOnly", f.rec.last().?);
    const st = f.adapter.contexts();
    try testing.expectEqual(@as(usize, 2), st.len);
    try testing.expectEqualStrings("editorFocus", st[0].name);
    try testing.expectEqualStrings("editorTextFocus", st[1].name);
    try testing.expectEqualStrings("langId", st[1].attrs[0].key);
}

test "adapter: a chord's second stroke is not typed into the focused field" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try f.focusEditor();
    f.t.press(.key_k, .{ .ctrl = true });
    try testing.expectEqualStrings("Ctrl+K", f.adapter.status().?);
    f.typeKey(.{ .key = .key_x, .codepoint = 'x' }, "x");
    try testing.expectEqualStrings("chord.x", f.rec.last().?);
    try testing.expectEqualStrings("", f.page.buf.slice());
    try testing.expect(f.adapter.status() == null);
    // Typing works again afterwards.
    f.typeKey(.{ .key = .key_y, .codepoint = 'y' }, "y");
    try testing.expectEqualStrings("y", f.page.buf.slice());
}

test "adapter: a mismatched chord is swallowed with a message" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try f.focusEditor();
    f.t.press(.key_k, .{ .ctrl = true });
    f.typeKey(.{ .key = .key_z, .codepoint = 'z' }, "z");
    try testing.expectEqual(@as(usize, 0), f.rec.len);
    try testing.expectEqualStrings("", f.page.buf.slice());
    try testing.expect(std.mem.indexOf(u8, f.adapter.status().?, "is not a command") != null);
}

test "adapter: a prefix conflict fires the shorter binding from a window timer" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    f.t.press(.key_j, .{ .ctrl = true });
    try testing.expectEqual(@as(usize, 0), f.rec.len);
    try testing.expect(f.t.win.nextDeadline() != null);
    f.t.advance(999);
    try testing.expectEqual(@as(usize, 0), f.rec.len);
    f.t.advance(1);
    try testing.expectEqualStrings("panel.toggle", f.rec.last().?);
    try testing.expect(f.t.win.nextDeadline() == null);
    // Continuing in time runs the longer one.
    f.t.press(.key_j, .{ .ctrl = true });
    f.t.press(.key_j, .{ .ctrl = true });
    try testing.expectEqualStrings("panel.maximize", f.rec.last().?);
    try testing.expectEqual(@as(usize, 2), f.rec.len);
}

test "adapter: menus run actions through the registry and get key labels" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const h = f.t.win.action_handler.?;
    try testing.expectEqualStrings("Ctrl+S", h.labelFor("file.save").?);
    try testing.expectEqualStrings("Ctrl+K, Ctrl+S", h.labelFor("keys.open").?);
    try testing.expect(h.labelFor("secret.hidden") == null);
    try testing.expect(f.t.win.dispatchAction("file.save", ".{ .n = 3 }"));
    try testing.expectEqual(@as(i64, 3), f.rec.runs[0].n);
    try testing.expectEqual(.menu, f.rec.runs[0].origin);
    try testing.expect(!f.t.win.dispatchAction("no.such.command", null));
}

fn paletteHas(f: *Fx, label: []const u8) bool {
    for (f.palette.items()) |it| if (std.mem.eql(u8, it.label, label)) return true;
    return false;
}

test "palette: lists visible commands with key hints and runs the pick" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    f.t.press(.key_p, .{ .ctrl = true, .shift = true });
    try testing.expect(f.t.find(.{ .test_id = "command_palette" }) != null);
    try testing.expect(paletteHas(&f, "File: file.save"));
    try testing.expect(paletteHas(&f, "View: Show All Commands"));
    try testing.expect(!paletteHas(&f, "Hidden"));
    // Not opened from the editor: its palette_when is false.
    try testing.expect(!paletteHas(&f, "Editor Only"));
    for (f.palette.items()) |it| if (std.mem.eql(u8, it.label, "File: file.save")) {
        try testing.expectEqualStrings("Ctrl+S", it.keybinding.?);
    };
    f.t.typeText("save");
    f.t.press(.enter, .{});
    try testing.expectEqualStrings("file.save", f.rec.last().?);
    try testing.expectEqual(.palette, f.rec.runs[f.rec.len - 1].origin);
    try testing.expect(f.t.find(.{ .test_id = "command_palette" }) == null);
    // The pick is remembered.
    try testing.expectEqual(@as(?u8, 0), f.palette.mru.rank(@intFromEnum(f.reg.lookup("file.save").?)));
}

test "palette: opened from the editor lists editor commands" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try f.focusEditor();
    f.t.press(.key_p, .{ .ctrl = true, .shift = true });
    try testing.expect(paletteHas(&f, "Editor Only"));
    f.t.press(.escape, .{});
    try testing.expect(f.t.find(.{ .test_id = "command_palette" }) == null);
    try testing.expectEqual(@as(usize, 0), f.rec.len);
}
