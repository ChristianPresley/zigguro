//! The Modules view (E07.F07.S01.T03): the active session's loaded
//! modules (executables and shared libraries), from `module` events and
//! the `modules` request, in the adapter's order.
//!
//! A row shows the module's name, then its symbol status, version and
//! address range when the adapter gives them; optimized and user code are
//! marked. The right-click menu copies the module's path.
//!
//! `update` rebuilds the rows from a snapshot when the modules changed
//! (not per frame). UI thread only.

const std = @import("std");
const zg_gui = @import("zg_gui");

const Allocator = std.mem.Allocator;
const Ui = zg_gui.Ui;
const Window = zg_gui.Window;
const virtual = zg_gui.virtual;
const TreeView = virtual.TreeView;
const TreeSource = virtual.TreeSource;
const ChildCount = virtual.tree_view.ChildCount;
const RowInfo = virtual.tree_view.RowInfo;
const LoadDone = virtual.tree_view.LoadDone;

pub const Item = struct {
    id: []const u8,
    name: []const u8,
    path: ?[]const u8 = null,
    version: ?[]const u8 = null,
    symbol_status: ?[]const u8 = null,
    address_range: ?[]const u8 = null,
    is_optimized: ?bool = null,
    is_user_code: ?bool = null,
};

const Node = struct {
    item: Item,
    /// The accessible name.
    label: []const u8,
    detail: []const u8,
};

pub const ModulesView = struct {
    gpa: Allocator,
    tv: TreeView = undefined,
    arena: std.heap.ArenaAllocator,
    nodes: std.AutoHashMapUnmanaged(u64, Node) = .empty,
    roots: []const u64 = &.{},

    /// `mv` must not move afterwards.
    pub fn init(mv: *ModulesView, gpa: Allocator) !void {
        mv.* = .{ .gpa = gpa, .arena = .init(gpa) };
        mv.tv = try TreeView.init(gpa, mv.source(), .{ .label = "Modules", .test_id = "debug-modules" });
    }

    pub fn deinit(mv: *ModulesView) void {
        mv.tv.deinit();
        mv.nodes.deinit(mv.gpa);
        mv.arena.deinit();
    }

    fn self(ptr: *anyopaque) *ModulesView {
        return @ptrCast(@alignCast(ptr));
    }

    pub fn isEmpty(mv: *const ModulesView) bool {
        return mv.roots.len == 0;
    }

    /// Rebuilds the rows from `items` (copied).
    pub fn update(mv: *ModulesView, items: []const Item) Allocator.Error!void {
        mv.nodes.clearRetainingCapacity();
        _ = mv.arena.reset(.retain_capacity);
        const a = mv.arena.allocator();
        var roots: std.ArrayList(u64) = .empty;
        for (items) |it| {
            const id = std.hash.Wyhash.hash(0, it.id);
            // A repeated id (an adapter's mistake) shows once.
            if (mv.nodes.contains(id)) continue;
            var detail: std.ArrayList(u8) = .empty;
            inline for (.{ it.symbol_status, it.version, it.address_range }) |part| if (part) |x| {
                if (detail.items.len > 0) try detail.appendSlice(a, ", ");
                try detail.appendSlice(a, x);
            };
            if (it.is_optimized orelse false) try detail.appendSlice(a, if (detail.items.len > 0) ", optimized" else "optimized");
            if (it.is_user_code orelse false) try detail.appendSlice(a, if (detail.items.len > 0) ", user code" else "user code");
            const copy: Item = .{
                .id = try a.dupe(u8, it.id),
                .name = try a.dupe(u8, it.name),
                .path = if (it.path) |p| try a.dupe(u8, p) else null,
            };
            const lb = if (detail.items.len > 0) try std.fmt.allocPrint(a, "{s}, {s}", .{ copy.name, detail.items }) else copy.name;
            try mv.nodes.put(mv.gpa, id, .{ .item = copy, .label = lb, .detail = detail.items });
            try roots.append(a, id);
        }
        mv.roots = roots.items;
        try mv.tv.reload();
    }

    /// The path of the module under the active row.
    pub fn activePath(mv: *const ModulesView) ?[]const u8 {
        const id = mv.tv.active orelse return null;
        const n = mv.nodes.get(id) orelse return null;
        return n.item.path;
    }

    // -- the tree's data --------------------------------------------------------

    fn source(mv: *ModulesView) TreeSource {
        return .{ .ptr = mv, .vtable = &vtable };
    }

    const vtable: TreeSource.VTable = .{
        .root_count = rootCount,
        .child_count = childCount,
        .child = child,
        .load = load,
        .label = label,
        .build_row = buildRow,
    };

    fn rootCount(ptr: *anyopaque) u32 {
        return @intCast(self(ptr).roots.len);
    }

    fn childCount(_: *anyopaque, _: u64) ChildCount {
        return .leaf;
    }

    fn child(ptr: *anyopaque, _: ?u64, i: u32) u64 {
        return self(ptr).roots[i];
    }

    fn load(_: *anyopaque, _: u64, _: LoadDone) void {}

    fn label(ptr: *anyopaque, id: u64) []const u8 {
        const n = self(ptr).nodes.get(id) orelse return "";
        return n.label;
    }

    /// Row `id`'s accessible name.
    pub fn labelOf(mv: *ModulesView, id: u64) []const u8 {
        return label(mv, id);
    }

    fn buildRow(ptr: *anyopaque, ui: *Ui, id: u64, _: RowInfo) void {
        const n = self(ptr).nodes.get(id) orelse return;
        ui.open(.{ .style = .{ .dir = .row, .gap = 6, .align_items = .center, .grow = 1, .shrink = 1 } });
        defer ui.close();
        ui.text(n.item.name, .{ .color = .fg, .wrap = false });
        if (n.detail.len > 0) ui.text(n.detail, .{ .color = .fg_muted, .wrap = false });
        if (n.item.path) |p| ui.text(p, .{ .color = .fg_muted, .wrap = false });
    }

    /// Focuses the tree.
    pub fn focus(mv: *ModulesView, w: *Window) void {
        if (!mv.tv.node.isNone() and w.store.valid(mv.tv.node)) w.setFocus(mv.tv.node, true);
    }

    pub fn build(mv: *ModulesView, ui: *Ui) void {
        mv.tv.win = ui.window();
        ui.open(.{ .style = .{ .dir = .column, .grow = 1, .basis = .{ .px = 0 } } });
        defer ui.close();
        zg_gui.w.contextMenu(ui, &.{
            .{ .action = .{ .label = "Copy Path", .action = "debug.copyModulePath", .enabled = mv.activePath() != null } },
        }, .{ .test_id = "modules-menu" });
        mv.tv.build(ui);
    }
};

const testing = std.testing;

fn rowLabels(mv: *ModulesView, a: Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (mv.tv.flat.rows.items) |r| try out.print(a, "{s}|", .{mv.labelOf(r.node)});
    return out.items;
}

test "ui: modules in the adapter's order with their details" {
    var mv: ModulesView = undefined;
    try mv.init(testing.allocator);
    defer mv.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const items = [_]Item{
        .{ .id = "1", .name = "app", .path = "/w/app", .symbol_status = "Symbols loaded", .address_range = "0x1000-0x2000", .is_user_code = true },
        .{ .id = "\"libm\"", .name = "libm.so.6", .version = "2.39", .is_optimized = true },
        .{ .id = "1", .name = "app again" },
        .{ .id = "2", .name = "ld.so" },
    };
    try mv.update(&items);
    try testing.expectEqualStrings(
        "app, Symbols loaded, 0x1000-0x2000, user code|libm.so.6, 2.39, optimized|ld.so|",
        try rowLabels(&mv, arena.allocator()),
    );
    mv.tv.moveTo(0, .replace);
    try testing.expectEqualStrings("/w/app", mv.activePath().?);
    mv.tv.moveTo(1, .replace);
    try testing.expect(mv.activePath() == null);
}
