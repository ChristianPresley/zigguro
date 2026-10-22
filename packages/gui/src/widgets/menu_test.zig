//! Menus and the menubar (E04.F05.S03.T02): APG keyboard behaviour,
//! mnemonics, placement, menu-aim, context menus and type-ahead.

const std = @import("std");
const geom = @import("../core/geom.zig");
const ui_mod = @import("../core/ui.zig");
const widget = @import("../core/widget.zig");
const menu = @import("menu.zig");
const menubar_mod = @import("menubar.zig");
const actions = @import("../input/actions.zig");
const TestApp = @import("../testing/test_app.zig").TestApp;

const Ui = ui_mod.Ui;
const MenuItem = menu.MenuItem;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

const recent = [_]MenuItem{
    .{ .action = .{ .label = "a.zig", .action = "file.open", .arg = "a.zig" } },
    .{ .action = .{ .label = "b.zig", .action = "file.open", .arg = "b.zig" } },
};

const edit_items = [_]MenuItem{
    .{ .header = "Clipboard" },
    .{ .action = .{ .label = "Cu&t", .action = "edit.cut", .shortcut = "Ctrl+X" } },
    .{ .action = .{ .label = "&Copy", .action = "edit.copy" } },
    .{ .action = .{ .label = "&Paste", .action = "edit.paste", .enabled = false } },
    .separator,
    .{ .action = .{ .label = "&Word Wrap", .action = "view.wrap", .checked = false } },
    .{ .submenu = .{ .label = "&Recent", .items = &recent } },
    .{ .action = .{ .label = "Select &All", .action = "edit.select_all" } },
};

const file_items = [_]MenuItem{
    .{ .action = .{ .label = "&New File", .action = "file.new" } },
    .{ .action = .{ .label = "&Open…", .action = "file.open" } },
};

const bar_entries = [_]menubar_mod.MenuBarEntry{
    .{ .label = "&File", .items = &file_items },
    .{ .label = "&Edit", .items = &edit_items },
};

/// Records actions and labels one shortcut.
const Rec = struct {
    last: [64]u8 = undefined,
    last_len: usize = 0,
    arg: [64]u8 = undefined,
    arg_len: usize = 0,
    count: u32 = 0,

    fn run(p: *anyopaque, a: actions.ActionId, arg: ?[]const u8) bool {
        const r: *Rec = @ptrCast(@alignCast(p));
        @memcpy(r.last[0..a.len], a);
        r.last_len = a.len;
        const x = arg orelse "";
        @memcpy(r.arg[0..x.len], x);
        r.arg_len = x.len;
        r.count += 1;
        return true;
    }

    fn labelFor(_: *anyopaque, a: actions.ActionId) ?[]const u8 {
        return if (std.mem.eql(u8, a, "edit.copy")) "Ctrl+C" else null;
    }

    fn lastAction(r: *const Rec) []const u8 {
        return r.last[0..r.last_len];
    }

    fn handler(r: *Rec) actions.ActionHandler {
        return .{ .ptr = r, .run = run, .label_for = labelFor };
    }
};

const Page = struct {
    bar: bool = false,
    editor_x: f32 = 10,

    pub fn build(self: *Page, ui: *Ui) void {
        ui.open(.{ .style = .{ .dir = .column, .padding = .{ .l = self.editor_x, .t = 10, .r = 10, .b = 10 }, .gap = 8, .align_items = .start } });
        defer ui.close();
        if (self.bar) menubar_mod.menubar(ui, &bar_entries, .{});
        menu.menuButton(ui, "Actions", &edit_items, .{});
        ui.open(.{ .style = .{ .w = .{ .px = 200 }, .h = .{ .px = 100 } }, .focusable = true, .label = "Editor", .test_id = "editor" });
        menu.contextMenu(ui, &edit_items, .{});
        ui.close();
    }
};

const Fixture = struct {
    page: Page = .{},
    rec: Rec = .{},
    t: *TestApp = undefined,

    fn init(f: *Fixture, size: geom.Size) !void {
        f.t = try TestApp.init(std.testing.allocator, .{ .root = .of(&f.page), .size = size });
        f.t.win.action_handler = f.rec.handler();
        _ = f.t.settle();
    }

    fn deinit(f: *Fixture) void {
        f.t.deinit();
    }

    /// The accessible name of the focused node.
    fn focusName(f: *Fixture) []const u8 {
        const w = f.t.win;
        const n = w.focus;
        if (n.isNone() or !w.store.valid(n)) return "";
        const vt = widget.vtable(w.store.hot.items(.kind)[n.index]);
        const a = vt.a11y orelse return "";
        const props = w.store.props(n) orelse return "";
        var dummy: u8 = 0;
        const st: *anyopaque = w.store.hot.items(.state)[n.index] orelse @ptrCast(&dummy);
        return a(props, st).name;
    }

    fn menus(f: *Fixture) usize {
        return f.t.count(.{ .test_id = "menu" });
    }

    fn openFromKeyboard(f: *Fixture) !void {
        _ = try menu.openMenu(f.t.win, &edit_items, .{ .node = f.t.find(.{ .test_id = "editor" }).? }, .{ .keyboard = true });
        _ = f.t.settle();
    }

    fn key(f: *Fixture, k: anytype, cp: u21) void {
        f.t.win.dispatch(.{ .key = .{ .key = k, .codepoint = cp } });
        _ = f.t.settle();
    }
};

test "APG menu keyboard script" {
    var f: Fixture = .{};
    try f.init(.{ .w = 800, .h = 600 });
    defer f.deinit();
    f.t.win.setFocus(f.t.find(.{ .test_id = "editor" }).?, true);
    try f.openFromKeyboard();
    // First item focused (headers are skipped).
    try expectEqualStrings("Cut", f.focusName());
    f.t.press(.arrow_down, .{});
    try expectEqualStrings("Copy", f.focusName());
    // Disabled items and separators are skipped.
    f.t.press(.arrow_down, .{});
    try expectEqualStrings("Word Wrap", f.focusName());
    f.t.press(.end, .{});
    try expectEqualStrings("Select All", f.focusName());
    // Down wraps to the first item.
    f.t.press(.arrow_down, .{});
    try expectEqualStrings("Cut", f.focusName());
    f.t.press(.arrow_up, .{});
    try expectEqualStrings("Select All", f.focusName());
    f.t.press(.home, .{});
    try expectEqualStrings("Cut", f.focusName());
    // Right opens a submenu with its first item focused; Left goes back.
    f.t.press(.end, .{});
    f.t.press(.arrow_up, .{});
    try expectEqualStrings("Recent", f.focusName());
    f.t.press(.arrow_right, .{});
    try expectEqual(@as(usize, 2), f.menus());
    try expectEqualStrings("a.zig", f.focusName());
    f.t.press(.arrow_left, .{});
    try expectEqual(@as(usize, 1), f.menus());
    try expectEqualStrings("Recent", f.focusName());
    // Escape in a submenu closes only that level.
    f.t.press(.arrow_right, .{});
    f.t.press(.arrow_down, .{});
    f.t.press(.escape, .{});
    try expectEqual(@as(usize, 1), f.menus());
    try expectEqualStrings("Recent", f.focusName());
    // Enter on a submenu item runs it, closes everything, restores focus.
    f.t.press(.enter, .{});
    f.t.press(.arrow_down, .{});
    f.t.press(.enter, .{});
    try expectEqualStrings("file.open", f.rec.lastAction());
    try expectEqualStrings("b.zig", f.rec.arg[0..f.rec.arg_len]);
    try expectEqual(@as(usize, 0), f.menus());
    try expectEqualStrings("Editor", f.focusName());
    // Escape at the top level closes the menu.
    try f.openFromKeyboard();
    f.t.press(.escape, .{});
    try expectEqual(@as(usize, 0), f.menus());
    try expectEqualStrings("Editor", f.focusName());
    // Tab closes the menu and moves on.
    try f.openFromKeyboard();
    f.t.press(.tab, .{});
    try expectEqual(@as(usize, 0), f.menus());
}

test "shortcut labels come from the props or the action handler" {
    var f: Fixture = .{};
    try f.init(.{ .w = 800, .h = 600 });
    defer f.deinit();
    try f.openFromKeyboard();
    try expectEqualStrings("Ctrl+X", rowProps(&f, "Cut").shortcut);
    try expectEqualStrings("Ctrl+C", rowProps(&f, "Copy").shortcut);
    try expectEqualStrings("", rowProps(&f, "Select All").shortcut);
}

fn rowProps(f: *Fixture, name: []const u8) *const menu.MenuRow.Props {
    const n = f.t.find(.{ .name = name, .role = .menuitem }).?;
    return @ptrCast(@alignCast(f.t.win.store.props(n).?));
}

test "space toggles checkbox without closing" {
    var f: Fixture = .{};
    try f.init(.{ .w = 800, .h = 600 });
    defer f.deinit();
    try f.openFromKeyboard();
    f.key(.key_w, 'w');
    try expectEqualStrings("Word Wrap", f.focusName());
    f.t.press(.space, .{});
    try expectEqualStrings("view.wrap", f.rec.lastAction());
    try expectEqual(@as(usize, 1), f.menus());
    try expectEqual(menu.Check.on, rowProps(&f, "Word Wrap").check);
    // Enter on it toggles and closes.
    f.t.press(.enter, .{});
    try expectEqual(@as(u32, 2), f.rec.count);
    try expectEqual(@as(usize, 0), f.menus());
}

test "mnemonics activate directly when shown" {
    var f: Fixture = .{};
    try f.init(.{ .w = 800, .h = 600 });
    defer f.deinit();
    _ = try menu.openMenu(f.t.win, &edit_items, .{ .pointer = .{ .x = 50, .y = 50 } }, .{ .keyboard = true, .mnemonics = true });
    _ = f.t.settle();
    f.key(.key_t, 't');
    try expectEqualStrings("edit.cut", f.rec.lastAction());
    try expectEqual(@as(usize, 0), f.menus());
}

test "pointer: hover opens submenus, click runs, outside press closes all" {
    var f: Fixture = .{};
    try f.init(.{ .w = 800, .h = 600 });
    defer f.deinit();
    try f.t.click(.{ .name = "Actions" });
    try expectEqual(@as(usize, 1), f.menus());
    try f.t.hover(.{ .name = "Recent" });
    try expectEqual(@as(usize, 2), f.menus());
    try f.t.hover(.{ .name = "a.zig" });
    try expectEqual(@as(usize, 2), f.menus());
    // Hovering a sibling far from the submenu closes it.
    const sel = try f.t.rectOf(.{ .name = "Select All" });
    f.t.moveTo(.{ .x = sel.x + 5, .y = sel.y + sel.h / 2 });
    try expectEqual(@as(usize, 1), f.menus());
    try f.t.hover(.{ .name = "Recent" });
    try expectEqual(@as(usize, 2), f.menus());
    // A press outside closes both levels.
    f.t.win.dispatch(.{ .pointer_down = .{ .pos = .{ .x = 790, .y = 590 } } });
    f.t.win.dispatch(.{ .pointer_up = .{ .pos = .{ .x = 790, .y = 590 } } });
    _ = f.t.settle();
    try expectEqual(@as(usize, 0), f.menus());
    // Clicking an item runs it.
    try f.t.click(.{ .name = "Actions" });
    try f.t.click(.{ .name = "Copy" });
    try expectEqualStrings("edit.copy", f.rec.lastAction());
    try expectEqual(@as(usize, 0), f.menus());
}

test "menu-aim keeps the submenu on a diagonal, switches after a rest" {
    var f: Fixture = .{};
    try f.init(.{ .w = 800, .h = 600 });
    defer f.deinit();
    try f.t.click(.{ .name = "Actions" });
    // Recent's submenu opens to the right of Recent.
    try f.t.hover(.{ .name = "Recent" });
    const rec_r = try f.t.rectOf(.{ .name = "Recent" });
    const sub = try f.t.rectOf(.{ .name = "a.zig" });
    try expect(sub.x >= rec_r.right() - 1);
    // Head down-right across "Select All" towards the submenu.
    const sel = try f.t.rectOf(.{ .name = "Select All" });
    var p: geom.Vec2 = .{ .x = rec_r.right() - 40, .y = rec_r.y + rec_r.h / 2 };
    f.t.moveTo(p);
    while (p.y < sel.y + sel.h / 2) {
        f.t.app.now_ms += 10;
        p = .{ .x = p.x + 4, .y = p.y + 3 };
        f.t.moveTo(p);
    }
    try expect(f.t.win.hitTest(p).eql(f.t.find(.{ .name = "Select All" }).?));
    try expectEqual(@as(usize, 2), f.menus());
    // The pointer rests on "Select All": after 300 ms it takes over.
    f.t.advance(100);
    try expectEqual(@as(usize, 2), f.menus());
    f.t.advance(250);
    try expectEqual(@as(usize, 1), f.menus());
    try expectEqualStrings("Select All", f.focusName());
}

test "submenu flips to side with room" {
    var f: Fixture = .{ .page = .{ .editor_x = 560 } };
    try f.init(.{ .w = 800, .h = 600 });
    defer f.deinit();
    try f.t.click(.{ .name = "Actions" });
    try f.t.hover(.{ .name = "Recent" });
    const parent = try f.t.rectOf(.{ .name = "Recent" });
    const sub = try f.t.rectOf(.{ .name = "a.zig" });
    try expect(sub.right() <= parent.x + 1);
}

test "context menu at the pointer flips up and left near the corner" {
    var f: Fixture = .{ .page = .{ .editor_x = 590 } };
    try f.init(.{ .w = 800, .h = 200 });
    defer f.deinit();
    const ed = try f.t.rectOf(.{ .test_id = "editor" });
    const p: geom.Vec2 = .{ .x = ed.right() - 5, .y = ed.bottom() - 5 };
    f.t.win.dispatch(.{ .pointer_move = .{ .pos = p } });
    f.t.win.dispatch(.{ .pointer_down = .{ .pos = p, .button = .right } });
    f.t.win.dispatch(.{ .pointer_up = .{ .pos = p, .button = .right } });
    _ = f.t.settle();
    try expectEqual(@as(usize, 1), f.menus());
    const m = try f.t.rectOf(.{ .test_id = "menu" });
    try std.testing.expectApproxEqAbs(p.x, m.right(), 0.01);
    try expect(m.bottom() <= p.y + 0.01 or m.y <= 8.01);
    try expect(m.x >= 8 and m.bottom() <= 192.01);
}

test "context menu via Shift+F10 positions at node" {
    var f: Fixture = .{};
    try f.init(.{ .w = 800, .h = 600 });
    defer f.deinit();
    const ed_node = f.t.find(.{ .test_id = "editor" }).?;
    f.t.win.setFocus(ed_node, true);
    f.t.press(.f10, .{ .shift = true });
    try expectEqual(@as(usize, 1), f.menus());
    const ed = try f.t.rectOf(.{ .test_id = "editor" });
    const m = try f.t.rectOf(.{ .test_id = "menu" });
    try std.testing.expectApproxEqAbs(ed.x, m.x, 0.01);
    try std.testing.expectApproxEqAbs(ed.bottom(), m.y, 0.01);
    // Opened from the keyboard: the first item has focus.
    try expectEqualStrings("Cut", f.focusName());
    f.t.press(.escape, .{});
    try expect(f.t.win.focus.eql(ed_node));
    // The Menu key works too.
    f.t.press(.context_menu, .{});
    try expectEqual(@as(usize, 1), f.menus());
}

test "long menu scrolls and typeahead" {
    var labels: [60][16]u8 = undefined;
    var items: [60]MenuItem = undefined;
    for (&items, &labels, 0..) |*it, *buf, i| {
        const s = std.fmt.bufPrint(buf, "{s} {d}", .{ if (i == 45) "Zebra" else "Item", i }) catch unreachable;
        it.* = .{ .action = .{ .label = s, .action = "pick" } };
    }
    var f: Fixture = .{};
    try f.init(.{ .w = 400, .h = 300 });
    defer f.deinit();
    _ = try menu.openMenu(f.t.win, &items, .{ .pointer = .{ .x = 20, .y = 20 } }, .{ .keyboard = true });
    _ = f.t.settle();
    const m = try f.t.rectOf(.{ .test_id = "menu" });
    try expect(m.bottom() <= 292.01);
    try expectEqualStrings("Item 0", f.focusName());
    f.t.press(.end, .{});
    _ = f.t.settle();
    try expectEqualStrings("Item 59", f.focusName());
    const last = try f.t.rectOf(.{ .name = "Item 59" });
    try expect(last.bottom() <= m.bottom() + 0.01);
    // Type-ahead: "z" finds Zebra; "it" then finds the next Item.
    f.key(.key_z, 'z');
    try expectEqualStrings("Zebra 45", f.focusName());
    f.t.app.now_ms += 2000;
    f.key(.key_i, 'i');
    try expectEqualStrings("Item 46", f.focusName());
    f.key(.key_t, 't');
    try expectEqualStrings("Item 46", f.focusName());
    const z = try f.t.rectOf(.{ .name = "Item 46" });
    try expect(z.y >= m.y - 0.01 and z.bottom() <= m.bottom() + 0.01);
}

test "menubar alt mnemonics" {
    var f: Fixture = .{ .page = .{ .bar = true } };
    try f.init(.{ .w = 800, .h = 600 });
    defer f.deinit();
    const ed = f.t.find(.{ .test_id = "editor" }).?;
    f.t.win.setFocus(ed, true);
    // Alt+F opens File with its first item focused.
    f.t.win.dispatch(.{ .key = .{ .key = .alt_left, .mods = .{ .alt = true } } });
    f.t.win.dispatch(.{ .key = .{ .key = .key_f, .mods = .{ .alt = true } } });
    f.t.win.dispatch(.{ .key = .{ .key = .alt_left, .action = .release } });
    _ = f.t.settle();
    try expectEqual(@as(usize, 1), f.menus());
    try expectEqualStrings("New File", f.focusName());
    // Right moves to the Edit menu.
    f.t.press(.arrow_right, .{});
    try expectEqual(@as(usize, 1), f.menus());
    try expectEqualStrings("Cut", f.focusName());
    // Left goes back to File.
    f.t.press(.arrow_left, .{});
    try expectEqualStrings("New File", f.focusName());
    f.t.press(.escape, .{});
    try expectEqual(@as(usize, 0), f.menus());
    try expect(f.t.win.focus.eql(ed));
    // Alt alone focuses the first entry; Right, Down opens Edit.
    f.t.win.dispatch(.{ .key = .{ .key = .alt_left, .mods = .{ .alt = true } } });
    f.t.win.dispatch(.{ .key = .{ .key = .alt_left, .action = .release } });
    _ = f.t.settle();
    try expectEqualStrings("File", f.focusName());
    f.t.press(.arrow_right, .{});
    try expectEqualStrings("Edit", f.focusName());
    f.t.press(.arrow_down, .{});
    try expectEqualStrings("Cut", f.focusName());
    f.t.press(.escape, .{});
    try expectEqual(@as(usize, 0), f.menus());
    // Escape on the bar returns focus to the editor.
    try expectEqualStrings("Edit", f.focusName());
    f.t.press(.escape, .{});
    try expect(f.t.win.focus.eql(ed));
}

test "menubar: click toggles, hover switches while open" {
    var f: Fixture = .{ .page = .{ .bar = true } };
    try f.init(.{ .w = 800, .h = 600 });
    defer f.deinit();
    try f.t.click(.{ .name = "File" });
    try expectEqual(@as(usize, 1), f.menus());
    try expect(f.t.find(.{ .name = "New File" }) != null);
    try f.t.hover(.{ .name = "Edit" });
    try expectEqual(@as(usize, 1), f.menus());
    try expect(f.t.find(.{ .name = "Cut" }) != null);
    // Clicking the open entry closes its menu.
    try f.t.click(.{ .name = "Edit" });
    try expectEqual(@as(usize, 0), f.menus());
    // And clicking it again opens it.
    try f.t.click(.{ .name = "Edit" });
    try expectEqual(@as(usize, 1), f.menus());
    // Moving onto File switches to it, so the click that follows closes it.
    try f.t.click(.{ .name = "File" });
    try expectEqual(@as(usize, 0), f.menus());
    // A press elsewhere closes an open menu and reaches what is under it.
    try f.t.click(.{ .name = "File" });
    try f.t.click(.{ .test_id = "editor" });
    try expectEqual(@as(usize, 0), f.menus());
    try expect(f.t.win.focus.eql(f.t.find(.{ .test_id = "editor" }).?));
}

test "menu open frame budget smoke" {
    var items: [50]MenuItem = undefined;
    for (&items) |*it| it.* = .{ .action = .{ .label = "Menu item", .action = "x", .shortcut = "Ctrl+K" } };
    var f: Fixture = .{};
    try f.init(.{ .w = 800, .h = 600 });
    defer f.deinit();
    const h = try menu.openMenu(f.t.win, &items, .{ .pointer = .{ .x = 10, .y = 10 } }, .{});
    _ = f.t.settle();
    try expect(h.isOpen(f.t.win));
    try expectEqual(@as(usize, 50), f.t.count(.{ .role = .menuitem }));
    h.close(f.t.win);
    _ = f.t.settle();
    try expect(!h.isOpen(f.t.win));
}

test "a menu left open is freed with its window" {
    var f: Fixture = .{};
    try f.init(.{ .w = 800, .h = 600 });
    try f.openFromKeyboard();
    f.t.press(.end, .{});
    f.t.press(.arrow_up, .{});
    f.t.press(.arrow_right, .{});
    try expectEqual(@as(usize, 2), f.menus());
    f.deinit();
}
