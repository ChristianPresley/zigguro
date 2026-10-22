//! TreeView (E04.F04.S02.T02).

const std = @import("std");
const ui_mod = @import("../core/ui.zig");
const view_mod = @import("../core/view.zig");
const tree = @import("tree_view.zig");
const TestApp = @import("../testing/test_app.zig").TestApp;

const Ui = ui_mod.Ui;
const TreeView = tree.TreeView;
const TreeSource = tree.TreeSource;
const ChildCount = tree.ChildCount;
const LoadDone = tree.LoadDone;
const testing = std.testing;

/// src/{main.zig, lib/{a.zig, b.zig}}, docs/{readme.md}, build.zig.
/// `lazy` makes docs load its children.
const Files = struct {
    lazy: bool = false,
    loaded: bool = false,
    pending: ?LoadDone = null,
    big: u32 = 0,

    const Node = struct { label: []const u8, kids: []const u64 = &.{}, dir: bool = false };
    const nodes = [_]Node{
        .{ .label = "" },
        .{ .label = "src", .kids = &.{ 3, 4 }, .dir = true },
        .{ .label = "docs", .kids = &.{5}, .dir = true },
        .{ .label = "main.zig" },
        .{ .label = "lib", .kids = &.{ 6, 7 }, .dir = true },
        .{ .label = "readme.md" },
        .{ .label = "a.zig" },
        .{ .label = "b.zig" },
        .{ .label = "build.zig" },
    };
    const roots = [_]u64{ 1, 2, 8 };

    fn rootCount(p: *anyopaque) u32 {
        const f: *Files = @ptrCast(@alignCast(p));
        return if (f.big > 0) f.big else roots.len;
    }
    fn childCount(p: *anyopaque, node: u64) ChildCount {
        const f: *Files = @ptrCast(@alignCast(p));
        if (node >= nodes.len) return .leaf;
        const n = nodes[node];
        if (!n.dir) return .leaf;
        if (node == 2 and f.lazy and !f.loaded) return .unknown_loading;
        return .{ .known = @intCast(n.kids.len) };
    }
    fn child(p: *anyopaque, parent: ?u64, i: u32) u64 {
        const f: *Files = @ptrCast(@alignCast(p));
        if (parent) |q| return nodes[q].kids[i];
        return if (f.big > 0) 100 + i else roots[i];
    }
    fn load(p: *anyopaque, _: u64, done: LoadDone) void {
        const f: *Files = @ptrCast(@alignCast(p));
        f.pending = done;
    }
    fn label(_: *anyopaque, node: u64) []const u8 {
        return if (node < nodes.len) nodes[node].label else "row";
    }
    const vt: TreeSource.VTable = .{ .root_count = rootCount, .child_count = childCount, .child = child, .load = load, .label = label };

    fn source(f: *Files) TreeSource {
        return .{ .ptr = f, .vtable = &vt };
    }
};

const Page = struct {
    tv: *TreeView,
    pub fn build(p: *Page, ui: *Ui) void {
        ui.open(.{ .style = .{ .w = .{ .px = 300 }, .h = .{ .px = 200 }, .dir = .column } });
        defer ui.close();
        p.tv.build(ui);
    }
};

const Opened = struct {
    node: ?u64 = null,
    fn f(ctx: *anyopaque, node: u64) void {
        const o: *Opened = @ptrCast(@alignCast(ctx));
        o.node = node;
    }
};

fn activeLabel(tv: *TreeView) []const u8 {
    return Files.label(undefined, tv.active.?);
}

test "tree view: APG arrows open, close and walk the tree" {
    const gpa = testing.allocator;
    var files: Files = .{};
    var opened: Opened = .{};
    var tv = try TreeView.init(gpa, files.source(), .{ .label = "Explorer", .on_open = .{ .ctx = &opened, .f = Opened.f } });
    defer tv.deinit();
    var page: Page = .{ .tv = &tv };
    const t = try TestApp.init(gpa, .{ .root = view_mod.AnyView.of(&page) });
    defer t.deinit();
    _ = t.settle();
    t.win.setFocus(tv.node, true);
    _ = t.settle();

    try testing.expectEqualStrings("src", activeLabel(&tv));
    t.press(.arrow_right, .{}); // open src
    _ = t.settle();
    try testing.expectEqual(@as(usize, 5), tv.flat.len());
    try testing.expectEqualStrings("src", activeLabel(&tv));
    t.press(.arrow_right, .{}); // to main.zig
    t.press(.arrow_down, .{}); // lib
    t.press(.arrow_right, .{}); // open lib
    t.press(.arrow_right, .{}); // a.zig
    _ = t.settle();
    try testing.expectEqualStrings("a.zig", activeLabel(&tv));
    try testing.expectEqualSlices(u64, &.{6}, tv.selection());

    const sem = try t.semanticsSnapshot(gpa);
    defer gpa.free(sem);
    try testing.expect(std.mem.indexOf(u8, sem, "tree \"Explorer\" focused") != null);
    try testing.expect(std.mem.indexOf(u8, sem, "treeitem \"lib\" expanded=true level=2") != null);
    try testing.expect(std.mem.indexOf(u8, sem, "treeitem \"a.zig\" selected level=3") != null);
    try testing.expect(std.mem.indexOf(u8, sem, "treeitem \"docs\" expanded=false level=1") != null);

    t.press(.arrow_left, .{}); // a.zig is a leaf: to lib
    try testing.expectEqualStrings("lib", activeLabel(&tv));
    t.press(.arrow_left, .{}); // close lib
    try testing.expectEqual(@as(usize, 5), tv.flat.len());
    t.press(.arrow_left, .{}); // to src
    t.press(.arrow_left, .{}); // close src
    try testing.expectEqual(@as(usize, 3), tv.flat.len());
    t.press(.end, .{});
    try testing.expectEqualStrings("build.zig", activeLabel(&tv));
    t.press(.enter, .{});
    try testing.expectEqual(@as(?u64, 8), opened.node);
    t.press(.home, .{});
    try testing.expectEqualStrings("src", activeLabel(&tv));
    t.press(.arrow_right, .{});
    try testing.expectEqual(@as(usize, 5), tv.flat.len());
    // `*` opens every sibling.
    t.typeText("*");
    _ = t.settle();
    try testing.expect(tv.flat.isExpanded(2));
}

test "tree view: multi-select with Shift, Ctrl, Space and Ctrl+A" {
    const gpa = testing.allocator;
    var files: Files = .{};
    var tv = try TreeView.init(gpa, files.source(), .{ .multi = true });
    defer tv.deinit();
    var page: Page = .{ .tv = &tv };
    const t = try TestApp.init(gpa, .{ .root = view_mod.AnyView.of(&page) });
    defer t.deinit();
    _ = t.settle();
    t.win.setFocus(tv.node, true);
    _ = try tv.expandRow(0);
    _ = t.settle();
    t.press(.arrow_down, .{}); // main.zig
    t.press(.arrow_down, .{ .shift = true }); // + lib
    try testing.expectEqualSlices(u64, &.{ 3, 4 }, tv.selection());
    t.press(.arrow_down, .{ .ctrl = true }); // to docs, selection kept
    try testing.expectEqualStrings("docs", activeLabel(&tv));
    try testing.expectEqual(@as(usize, 2), tv.selection().len);
    t.press(.space, .{ .ctrl = true }); // + docs
    try testing.expectEqual(@as(usize, 3), tv.selection().len);
    t.press(.space, .{ .ctrl = true }); // - docs
    try testing.expectEqual(@as(usize, 2), tv.selection().len);
    t.press(.key_a, .{ .ctrl = true });
    try testing.expectEqual(tv.flat.len(), tv.selection().len);
    t.press(.escape, .{});
    try testing.expectEqual(@as(usize, 0), tv.selection().len);
}

test "tree view: type-ahead finds rows by label" {
    const gpa = testing.allocator;
    var files: Files = .{};
    var tv = try TreeView.init(gpa, files.source(), .{});
    defer tv.deinit();
    var page: Page = .{ .tv = &tv };
    const t = try TestApp.init(gpa, .{ .root = view_mod.AnyView.of(&page) });
    defer t.deinit();
    _ = t.settle();
    t.win.setFocus(tv.node, true);
    _ = try tv.expandRow(0);
    _ = t.settle();
    t.typeText("b");
    try testing.expectEqualStrings("build.zig", activeLabel(&tv));
    t.advance(typeaheadPause());
    t.typeText("l");
    try testing.expectEqualStrings("lib", activeLabel(&tv));
    t.advance(typeaheadPause());
    t.typeText("d");
    try testing.expectEqualStrings("docs", activeLabel(&tv));
    t.advance(typeaheadPause());
    t.typeText("m");
    t.typeText("a");
    try testing.expectEqualStrings("main.zig", activeLabel(&tv));
}

fn typeaheadPause() u64 {
    return tree.typeahead_ms + 1;
}

test "tree view: children that load show a placeholder until done" {
    const gpa = testing.allocator;
    var files: Files = .{ .lazy = true };
    var tv = try TreeView.init(gpa, files.source(), .{});
    defer tv.deinit();
    var page: Page = .{ .tv = &tv };
    const t = try TestApp.init(gpa, .{ .root = view_mod.AnyView.of(&page) });
    defer t.deinit();
    _ = t.settle();
    t.win.setFocus(tv.node, true);
    t.press(.arrow_down, .{}); // docs
    t.press(.arrow_right, .{});
    _ = t.settle();
    try testing.expectEqual(@as(usize, 4), tv.flat.len());
    try testing.expect(tv.flat.rows.items[2].flags.placeholder);
    try testing.expect(t.find(.{ .role = .treeitem, .name = "Loading\u{2026}" }) != null);
    // Down skips the placeholder.
    t.press(.arrow_down, .{});
    try testing.expectEqualStrings("build.zig", activeLabel(&tv));
    files.loaded = true;
    files.pending.?.call(2);
    _ = t.settle();
    try testing.expectEqual(@as(usize, 4), tv.flat.len());
    try testing.expect(t.find(.{ .role = .treeitem, .name = "readme.md" }) != null);
    try testing.expect(t.find(.{ .role = .treeitem, .name = "Loading\u{2026}" }) == null);
}

test "tree view: clicks select, chevrons toggle, double click opens" {
    const gpa = testing.allocator;
    var files: Files = .{};
    var opened: Opened = .{};
    var tv = try TreeView.init(gpa, files.source(), .{ .expand_on_click = false, .on_open = .{ .ctx = &opened, .f = Opened.f } });
    defer tv.deinit();
    var page: Page = .{ .tv = &tv };
    const t = try TestApp.init(gpa, .{ .root = view_mod.AnyView.of(&page) });
    defer t.deinit();
    _ = t.settle();
    try t.click(.{ .role = .treeitem, .name = "docs" });
    _ = t.settle();
    try testing.expectEqualSlices(u64, &.{2}, tv.selection());
    try testing.expect(!tv.flat.isExpanded(2));
    try testing.expect(t.win.focus.eql(tv.node));
    // The chevron sits at the row's left edge for a root.
    const r = try t.rectOf(.{ .role = .treeitem, .name = "src" });
    t.moveTo(.{ .x = r.x + 4, .y = r.y + r.h / 2 });
    t.win.dispatch(.{ .pointer_down = .{ .pos = .{ .x = r.x + 4, .y = r.y + r.h / 2 } } });
    t.win.dispatch(.{ .pointer_up = .{ .pos = .{ .x = r.x + 4, .y = r.y + r.h / 2 } } });
    _ = t.settle();
    try testing.expect(tv.flat.isExpanded(1));
    try t.doubleClick(.{ .role = .treeitem, .name = "main.zig" });
    try testing.expectEqual(@as(?u64, 3), opened.node);
}

test "tree view: a hundred thousand rows build only the visible ones" {
    const gpa = testing.allocator;
    var files: Files = .{ .big = 100_000 };
    var tv = try TreeView.init(gpa, files.source(), .{});
    defer tv.deinit();
    var page: Page = .{ .tv = &tv };
    const t = try TestApp.init(gpa, .{ .root = view_mod.AnyView.of(&page) });
    defer t.deinit();
    _ = t.settle();
    t.win.setFocus(tv.node, true);
    try testing.expect(t.count(.{ .role = .treeitem }) < 30);
    t.press(.end, .{});
    _ = t.settle();
    try testing.expectEqual(@as(?u64, 100 + 99_999), tv.active);
    try testing.expect(t.count(.{ .role = .treeitem }) < 30);
    try testing.expect(t.win.scrollOffset(tv.list).y > 0);
}
