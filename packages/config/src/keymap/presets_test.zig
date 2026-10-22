//! Preset and VS Code import tests.

const std = @import("std");
const keys = @import("keys.zig");
const keyspec = @import("keyspec.zig");
const keymap_mod = @import("keymap.zig");
const presets = @import("presets.zig");
const import_vscode = @import("import_vscode.zig");
const resolver_mod = @import("resolver.zig");
const registry = @import("../commands/registry.zig");
const context = @import("../when/context.zig");
const zon_load = @import("../zon_load.zig");
const diag = @import("../diag.zig");

const testing = std.testing;
const gpa = testing.allocator;

/// Every command id the presets use, registered as stubs.
fn registerPresetCommands(reg: *registry.CommandRegistry) !void {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(gpa);
    inline for (.{ presets.Preset.vscode, .jetbrains, .sublime }) |p| {
        var d = diag.Diags.init(gpa);
        defer d.deinit();
        var doc = try zon_load.loadZon(gpa, presets.presetSource(p).?, &d);
        defer doc.deinit();
        for (doc.root.v.array) |e| {
            const c = e.get("command").?.v.string;
            if (c.len == 0 or c[0] == '-') continue;
            if (reg.lookup(c) != null or seen.contains(c)) continue;
            try seen.put(gpa, c, {});
            _ = try reg.register(.{ .id = try reg.arena.allocator().dupe(u8, c), .title = "stub" });
        }
    }
}

const Fx = struct {
    ctx: context.ContextKeyService,
    reg: *registry.CommandRegistry,
    docs: std.ArrayList(zon_load.Doc) = .empty,
    diags: diag.Diags,
    km: ?*keymap_mod.Keymap = null,

    fn init(f: *Fx) !void {
        f.* = .{ .ctx = .init(gpa), .reg = undefined, .diags = .init(gpa) };
        try context.registerStandard(&f.ctx, .linux);
        f.reg = try registry.CommandRegistry.init(gpa, &f.ctx, .{ .io = testing.io });
        try registry.registerBuiltins(f.reg);
    }

    fn deinit(f: *Fx) void {
        if (f.km) |k| k.deinit();
        for (f.docs.items) |*d| d.deinit();
        f.docs.deinit(gpa);
        f.diags.deinit();
        f.reg.deinit();
        f.ctx.deinit();
    }

    fn build(f: *Fx, p: presets.Preset, plat: keyspec.Platform) !void {
        var inputs: std.ArrayList(keymap_mod.LayerInput) = .empty;
        defer inputs.deinit(gpa);
        for (presets.presetLayers(p)) |src| try f.docs.append(gpa, zon_load.loadZon(gpa, src, &f.diags) catch |e| {
            for (f.diags.items()) |d| std.debug.print("DIAG {d}: {s}\n", .{ d.span.start, d.message });
            return e;
        });
        for (f.docs.items) |*d| try inputs.append(gpa, .{ .layer = .preset, .doc = d });
        f.km = try keymap_mod.Keymap.build(gpa, inputs.items, f.reg, &f.ctx, plat, &f.diags);
    }
};

test "presets: all load without diagnostics on every platform" {
    inline for (.{ presets.Preset.vscode, .jetbrains, .sublime }) |p| {
        inline for (.{ keyspec.Platform.linux, .windows, .macos }) |plat| {
            var f: Fx = undefined;
            try f.init();
            defer f.deinit();
            try registerPresetCommands(f.reg);
            try f.build(p, plat);
            if (f.diags.items().len != 0) {
                for (f.diags.items()) |d| std.debug.print("{t}/{t}: {s}\n", .{ p, plat, d.message });
                return error.TestUnexpectedResult;
            }
            try testing.expect(f.km.?.bindings.len > 10);
        }
    }
    try testing.expectEqual(@as(usize, 0), presets.presetLayers(.none).len);
}

test "presets: no duplicate spec+when within a preset file" {
    inline for (.{ presets.Preset.vscode, .jetbrains, .sublime }) |p| {
        var d = diag.Diags.init(gpa);
        defer d.deinit();
        var doc = try zon_load.loadZon(gpa, presets.presetSource(p).?, &d);
        defer doc.deinit();
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(gpa);
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        for (doc.root.v.array) |e| {
            const cmd = e.get("command").?.v.string;
            if (cmd.len > 0 and cmd[0] == '-') continue;
            const when = if (e.get("when")) |w| w.v.string else "";
            const k = try std.fmt.allocPrint(arena.allocator(), "{s}|{s}", .{ e.get("key").?.v.string, when });
            if (seen.contains(k)) {
                std.debug.print("{t}: duplicate {s}\n", .{ p, k });
                return error.TestUnexpectedResult;
            }
            try seen.put(gpa, k, {});
        }
    }
}

test "presets: jetbrains shift shift and sublime moves the agent pane" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try registerPresetCommands(f.reg);
    try f.build(.jetbrains, .linux);
    const r = try resolver_mod.Resolver.init(gpa, &f.ctx, &keys.us_layout, .{ .platform = .linux });
    defer r.deinit();
    r.reload(f.km.?);
    const sh: keys.EventMods = .{ .shift = true };
    _ = r.resolve(&.{}, .{ .usage = 0xE1, .mods = sh, .t_ns = 0 });
    _ = r.resolve(&.{}, .{ .usage = 0xE1, .action = .release, .t_ns = 10 });
    _ = r.resolve(&.{}, .{ .usage = 0xE1, .mods = sh, .t_ns = 100 });
    const res = r.resolve(&.{}, .{ .usage = 0xE1, .action = .release, .t_ns = 110 });
    try testing.expectEqualStrings("quickOpen.everything", f.reg.get(res.action.id).id);
    try testing.expectEqualStrings("Ctrl+Shift+A", r.labelFor(f.reg.lookup("workbench.showCommands").?, &.{}).?);

    var g: Fx = undefined;
    try g.init();
    defer g.deinit();
    try registerPresetCommands(g.reg);
    try g.build(.sublime, .linux);
    const r2 = try resolver_mod.Resolver.init(gpa, &g.ctx, &keys.us_layout, .{ .platform = .linux });
    defer r2.deinit();
    r2.reload(g.km.?);
    try testing.expectEqualStrings("Ctrl+Alt+L", r2.labelFor(g.reg.lookup("agent.togglePane").?, null).?);
}

test "presets: choices and vim passthrough source" {
    try testing.expectEqual(@as(usize, 5), presets.choices().len);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const src = try presets.vimPassthroughSource(arena.allocator(), &.{ "mod+shift+p", "mod+q" }, struct {
        fn f(k: []const u8) ?[]const u8 {
            return if (std.mem.eql(u8, k, "mod+shift+p")) "workbench.showCommands" else null;
        }
    }.f);
    var d = diag.Diags.init(gpa);
    defer d.deinit();
    var doc = try zon_load.loadZon(gpa, src, &d);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 1), doc.root.v.array.len);
    try testing.expectEqualStrings("vim.mode != insert", doc.root.v.array[0].get("when").?.v.string);
}

test "import: comments, removals, chords, scan codes, unmapped, when and conflicts" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try registerPresetCommands(f.reg);
    try f.build(.vscode, .linux);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const src =
        \\// my keybindings
        \\[
        \\  { "key": "ctrl+shift+alt+k", "command": "editor.action.commentLine", "when": "editorTextFocus && !editorReadonly" },
        \\  { "key": "ctrl+d", "command": "-editor.action.addSelectionToNextFindMatch" },
        \\  { "key": "ctrl+k ctrl+x", "command": "workbench.action.closeAllEditors" },
        \\  { "key": "ctrl+[Slash]", "command": "editor.action.blockComment" },
        \\  { "key": "ctrl+e", "command": "extension.someThing" },
        \\  { "key": "ctrl+b", "command": "workbench.action.files.save", },
        \\  { "key": "alt+x", "command": "editor.action.rename", "when": "inlineSuggestionVisible || myExtFocus" },
        \\  { "key": "ctrl+[Nope]", "command": "undo" },
        \\  { "key": "ctrl+u", "command": "cursorUndo", "when": "a &&" },
        \\  { "key": "ctrl+alt+g", "command": "workbench.action.gotoLine", "args": { "line": 3 } },
        \\]
    ;
    const items = try import_vscode.importVsCodeKeybindings(arena.allocator(), src, .linux, f.km.?, &f.ctx);
    try testing.expectEqual(@as(usize, 10), items.len);
    try testing.expectEqual(import_vscode.Status.mapped, items[0].status);
    try testing.expectEqualStrings("ctrl+alt+shift+k", items[0].key);
    try testing.expectEqualStrings("editor.toggleLineComment", items[0].zigguro.?);
    try testing.expectEqualStrings("-editor.addSelectionToNextMatch", items[1].zigguro.?);
    try testing.expectEqualStrings("ctrl+k ctrl+x", items[2].key);
    try testing.expectEqualStrings("ctrl+[Slash]", items[3].key);
    try testing.expectEqual(import_vscode.Status.unmapped, items[4].status);
    try testing.expectEqual(import_vscode.Status.conflict, items[5].status);
    try testing.expectEqualStrings("replaces workbench.toggleSidebar", items[5].note);
    try testing.expectEqualStrings("ghostVisible || myExtFocus", items[6].when.?);
    try testing.expect(std.mem.indexOf(u8, items[6].note, "myExtFocus") != null);
    try testing.expectEqual(import_vscode.Status.invalid_key, items[7].status);
    try testing.expectEqual(import_vscode.Status.invalid_when, items[8].status);
    try testing.expectEqualStrings(".{ .line = 3 }", items[9].args.?);

    // Appending keeps the file loadable and adds the accepted entries.
    const existing =
        \\.{
        \\    .{ .key = "ctrl+q", .command = "noop" }
        \\}
    ;
    const merged = try import_vscode.appendImported(arena.allocator(), existing, items);
    var d = diag.Diags.init(gpa);
    defer d.deinit();
    var doc = try zon_load.loadZon(gpa, try arena.allocator().dupeZ(u8, merged), &d);
    defer doc.deinit();
    // 1 existing + 7 accepted (mapped or conflict).
    try testing.expectEqual(@as(usize, 8), doc.root.v.array.len);
    const fresh = try import_vscode.appendImported(arena.allocator(), "", items[0..1]);
    var doc2 = try zon_load.loadZon(gpa, try arena.allocator().dupeZ(u8, fresh), &d);
    defer doc2.deinit();
    try testing.expectEqual(@as(usize, 1), doc2.root.v.array.len);
    try testing.expectEqual(@as(usize, 0), d.errorCount());
}

test "import: command map is large enough" {
    try testing.expect(import_vscode.command_map.keys().len >= 150);
}
