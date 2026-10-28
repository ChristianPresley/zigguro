//! `HierarchyPanel`: call and type hierarchies (E07.F04.S01.T03) as a
//! tree in the bottom area, from zg_codeintel's `HierarchyService`. A
//! node's children load when it is first opened; a node that repeats an
//! ancestor says "(recursive)" and stays closed.
//!
//! The header names the root and direction; its buttons switch between
//! callers and callees (or supertypes and subtypes), ask again, and close
//! every node. A click shows where the call is (the caller's call site
//! for incoming calls, the call in the expanded function for outgoing
//! ones); Enter or a double click goes to the item itself and focuses
//! the editor. UI thread only.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_codeintel = @import("zg_codeintel");

const Allocator = std.mem.Allocator;
const Ui = zg_gui.Ui;
const Window = zg_gui.Window;
const virtual = zg_gui.virtual;
const TreeView = virtual.TreeView;
const TreeSource = virtual.TreeSource;
const ChildCount = virtual.tree_view.ChildCount;
const RowInfo = virtual.tree_view.RowInfo;
const LoadDone = virtual.tree_view.LoadDone;
pub const HierarchyService = zg_codeintel.features.HierarchyService;
const NavTarget = zg_codeintel.features.NavService.Target;

/// What the panel asks of its host (the workbench).
pub const Hooks = struct {
    ctx: *anyopaque,
    /// Shows `t` in an editor (`focus`: and moves focus there).
    open: *const fn (ctx: *anyopaque, t: NavTarget, focus: bool) void,
    /// Asks the root again (`refresh`).
    again: *const fn (ctx: *anyopaque) void,
};

pub const HierarchyPanel = struct {
    gpa: Allocator,
    svc: *HierarchyService,
    tv: TreeView = undefined,
    hooks: Hooks,
    win: ?*Window = null,
    /// The tree was built from this round of the service.
    round_seen: u64 = 0,
    gen_seen: u64 = 0,
    done: ?LoadDone = null,
    loaded: std.ArrayList(u64) = .empty,
    scratch: [256]u8 = undefined,
    path_buf: [std.fs.max_path_bytes]u8 = undefined,

    /// `p` must not move afterwards.
    pub fn init(p: *HierarchyPanel, gpa: Allocator, svc: *HierarchyService, hooks: Hooks) !void {
        p.* = .{ .gpa = gpa, .svc = svc, .hooks = hooks };
        try p.newTree();
    }

    pub fn deinit(p: *HierarchyPanel) void {
        p.tv.deinit();
        p.loaded.deinit(p.gpa);
    }

    fn newTree(p: *HierarchyPanel) !void {
        p.tv = try TreeView.init(p.gpa, p.source(), .{
            .label = "Hierarchy",
            .test_id = "hierarchy-tree",
            .on_open = .{ .ctx = p, .f = onOpen },
            .on_click = .{ .ctx = p, .f = onClick },
        });
        p.tv.win = p.win;
        p.round_seen = p.svc.round;
        p.done = null;
        p.openFirst();
    }

    /// The first root starts open.
    fn openFirst(p: *HierarchyPanel) void {
        if (p.tv.flat.len() > 0) _ = p.tv.expandRow(0) catch {};
    }

    fn self(ptr: *anyopaque) *HierarchyPanel {
        return @ptrCast(@alignCast(ptr));
    }

    /// Follows the service; true when the tree changed.
    pub fn refresh(p: *HierarchyPanel) bool {
        if (p.svc.generation == p.gen_seen) return false;
        p.gen_seen = p.svc.generation;
        if (p.svc.round != p.round_seen) {
            // New roots: node ids mean other items now.
            p.tv.deinit();
            p.newTree() catch return true;
            return true;
        }
        if (p.tv.flat.len() == 0 and p.svc.roots.items.len > 0) {
            // The roots arrived.
            p.tv.reload() catch {};
            p.openFirst();
        }
        p.svc.takeLoaded(&p.loaded) catch return true;
        if (p.done) |d| for (p.loaded.items) |id| d.call(id);
        return true;
    }

    // -- the tree's data ------------------------------------------------------

    fn source(p: *HierarchyPanel) TreeSource {
        return .{ .ptr = p, .vtable = &vtable };
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
        return @intCast(self(ptr).svc.roots.items.len);
    }

    fn childCount(ptr: *anyopaque, id: u64) ChildCount {
        const n = self(ptr).svc.node(id) orelse return .leaf;
        if (n.recursive) return .leaf;
        const kids = n.children orelse return .unknown_loading;
        return if (kids.len == 0) .leaf else .{ .known = @intCast(kids.len) };
    }

    fn child(ptr: *anyopaque, parent: ?u64, i: u32) u64 {
        const svc = self(ptr).svc;
        const q = parent orelse return svc.roots.items[i];
        return svc.node(q).?.children.?[i];
    }

    fn load(ptr: *anyopaque, id: u64, done: LoadDone) void {
        const p = self(ptr);
        p.done = done;
        p.svc.expand(id) catch {};
    }

    fn label(ptr: *anyopaque, id: u64) []const u8 {
        const n = self(ptr).svc.node(id) orelse return "";
        return n.item.name;
    }

    fn basename(uri: []const u8) []const u8 {
        const i = std.mem.lastIndexOfScalar(u8, uri, '/') orelse return uri;
        return uri[i + 1 ..];
    }

    fn buildRow(ptr: *anyopaque, ui: *Ui, id: u64, _: RowInfo) void {
        const p = self(ptr);
        const n = p.svc.node(id) orelse return;
        ui.open(.{ .style = .{ .dir = .row, .gap = 6, .align_items = .center, .grow = 1, .shrink = 1 } });
        defer ui.close();
        ui.text(n.item.name, .{ .wrap = false });
        if (n.item.detail) |d| ui.text(d, .{ .color = .fg_muted, .wrap = false });
        var buf: [64]u8 = undefined;
        const where = std.fmt.bufPrint(&buf, "{s}:{d}", .{ basename(n.item.uri), n.item.selection.start.line + 1 }) catch "";
        ui.text(where, .{ .color = .fg_muted, .wrap = false });
        if (n.from_ranges.len > 1) ui.text(std.fmt.bufPrint(&p.scratch, "{d} calls", .{n.from_ranges.len}) catch "", .{ .color = .fg_muted, .wrap = false });
        if (n.recursive) ui.text("(recursive)", .{ .color = .fg_muted, .wrap = false });
        if (n.loading) ui.text("\u{2026}", .{ .color = .fg_muted, .wrap = false });
        if (n.failed) ui.text("(failed)", .{ .color = .danger, .wrap = false });
    }

    // -- actions ----------------------------------------------------------------

    fn target(p: *HierarchyPanel, uri: []const u8, r: zg_codeintel.protocol.Range, enc: zg_codeintel.features.position.Encoding) NavTarget {
        var fba = std.heap.FixedBufferAllocator.init(&p.path_buf);
        const path = zg_codeintel.uri.pathFromUri(fba.allocator(), uri) catch null;
        return .{ .uri = uri, .path = path, .selection = r, .range = r, .enc = enc };
    }

    /// Enter or a double click: the item itself, focused.
    fn onOpen(ctx: *anyopaque, id: u64) void {
        const p = self(ctx);
        const n = p.svc.node(id) orelse return;
        p.hooks.open(p.hooks.ctx, p.target(n.item.uri, n.item.selection, n.item.enc), true);
    }

    /// A click: the call site when there is one, else the item.
    fn onClick(ctx: *anyopaque, id: u64) void {
        const p = self(ctx);
        const n = p.svc.node(id) orelse return;
        if (n.from_ranges.len > 0) if (n.ranges_uri) |u| {
            return p.hooks.open(p.hooks.ctx, p.target(u, n.from_ranges[0], n.item.enc), false);
        };
        p.hooks.open(p.hooks.ctx, p.target(n.item.uri, n.item.selection, n.item.enc), false);
    }

    /// Focuses the tree.
    pub fn focus(p: *HierarchyPanel, w: *Window) void {
        if (!p.tv.node.isNone() and w.store.valid(p.tv.node)) w.setFocus(p.tv.node, true);
    }

    fn title(p: *HierarchyPanel) []const u8 {
        const root = if (p.svc.roots.items.len > 0) p.svc.node(p.svc.roots.items[0]).?.item.name else "";
        const what = switch (p.svc.dir) {
            .incoming => "Callers of",
            .outgoing => "Calls from",
            .supertypes => "Supertypes of",
            .subtypes => "Subtypes of",
        };
        return std.fmt.bufPrint(&p.scratch, "{s} {s}", .{ what, root }) catch what;
    }

    fn collapseAll(p: *HierarchyPanel) void {
        var i = p.tv.flat.len();
        while (i > 0) {
            i -= 1;
            const r = p.tv.flat.rows.items[i];
            if (r.depth == 0 and p.tv.flat.isExpanded(r.node)) _ = p.tv.collapseRow(i);
        }
    }

    pub fn build(p: *HierarchyPanel, ui: *Ui) void {
        p.win = ui.window();
        p.tv.win = p.win;
        _ = p.refresh();
        ui.open(.{ .style = .{ .dir = .column, .grow = 1, .basis = .{ .px = 0 }, .bg = .{ .token = .bg_elevated } }, .role = .group, .label = "Hierarchy" });
        defer ui.close();
        p.header(ui);
        if (p.svc.roots.items.len == 0) {
            ui.open(.{ .style = .{ .padding = .xy(12, 6), .shrink = 0 } });
            ui.text(if (p.svc.busy()) "Loading\u{2026}" else "No hierarchy here. Put the caret on a function or type and run Show Call Hierarchy or Show Type Hierarchy.", .{ .color = .fg_muted });
            ui.close();
            return;
        }
        ui.open(.{ .style = .{ .dir = .column, .grow = 1, .basis = .{ .px = 0 } }, .key_context = "hierarchyFocus" });
        p.tv.build(ui);
        ui.close();
    }

    fn header(p: *HierarchyPanel, ui: *Ui) void {
        ui.open(.{ .style = .{ .dir = .row, .gap = 8, .align_items = .center, .padding = .xy(10, 2), .h = .{ .px = 30 }, .shrink = 0 } });
        defer ui.close();
        if (p.svc.roots.items.len > 0) ui.text(p.title(), .{ .wrap = false });
        ui.open(.{ .style = .{ .grow = 1 } });
        ui.close();
        const flip: struct { HierarchyService.Direction, []const u8 } = switch (p.svc.dir) {
            .incoming => .{ .outgoing, "Show Calls From" },
            .outgoing => .{ .incoming, "Show Callers" },
            .supertypes => .{ .subtypes, "Show Subtypes" },
            .subtypes => .{ .supertypes, "Show Supertypes" },
        };
        if (zg_gui.w.button(ui, .{ .label = flip[1], .variant = .ghost }).clicked) p.svc.setDirection(flip[0]);
        if (zg_gui.w.button(ui, .{ .label = "Refresh", .variant = .ghost }).clicked) p.hooks.again(p.hooks.ctx);
        if (zg_gui.w.button(ui, .{ .label = "Collapse All", .variant = .ghost }).clicked) p.collapseAll();
    }
};

const testing = std.testing;

const TestHost = struct {
    opened: std.ArrayList(u8) = .empty,
    focused: bool = false,
    again: u32 = 0,

    fn open(ctx: *anyopaque, t: NavTarget, focus_: bool) void {
        const h: *TestHost = @ptrCast(@alignCast(ctx));
        h.opened.clearRetainingCapacity();
        h.opened.print(testing.allocator, "{s}:{d}", .{ t.path orelse t.uri, t.selection.start.line }) catch {};
        h.focused = focus_;
    }

    fn askAgain(ctx: *anyopaque) void {
        const h: *TestHost = @ptrCast(@alignCast(ctx));
        h.again += 1;
    }
};

fn testRange(line: u32) zg_codeintel.protocol.Range {
    return .{ .start = .{ .line = line, .character = 4 }, .end = .{ .line = line, .character = 5 } };
}

test "hierarchy panel: lists roots, shows loaded children, clicks go to call sites" {
    // The protocol side is tested in zg_codeintel; here the panel runs
    // over nodes put into the service by hand (children already loaded,
    // so nothing asks a server).
    const gpa = testing.allocator;
    var svc: HierarchyService = undefined;
    svc.gpa = gpa;
    svc.nodes = .empty;
    svc.roots = .empty;
    svc.loaded = .empty;
    svc.round = 1;
    svc.generation = 1;
    svc.preparing = false;
    svc.dir = .incoming;
    svc.kind = .calls;
    defer {
        svc.nodes.deinit(gpa);
        svc.roots.deinit(gpa);
        svc.loaded.deinit(gpa);
    }
    const item = struct {
        fn of(name: []const u8, uri: []const u8, line: u32) HierarchyService.HierItem {
            return .{ .raw = "{}", .name = name, .kind = .Function, .uri = uri, .range = testRange(line), .selection = testRange(line), .enc = .utf16, .client = undefined };
        }
    }.of;
    const kids1 = [_]HierarchyService.NodeId{ 2, 3 };
    const ranges = [_]zg_codeintel.protocol.Range{ testRange(9), testRange(12) };
    try svc.nodes.append(gpa, .{ .item = item("f", "file:///w/a.py", 1), .parent = null, .children = &kids1 });
    try svc.nodes.append(gpa, .{ .item = item("g", "file:///w/b.py", 7), .parent = 1, .children = &.{}, .from_ranges = &ranges, .ranges_uri = "file:///w/b.py" });
    try svc.nodes.append(gpa, .{ .item = item("f", "file:///w/a.py", 1), .parent = 1, .recursive = true, .from_ranges = ranges[0..1], .ranges_uri = "file:///w/a.py" });
    try svc.roots.append(gpa, 1);

    var host: TestHost = .{};
    defer host.opened.deinit(gpa);
    var p: HierarchyPanel = undefined;
    try p.init(gpa, &svc, .{ .ctx = &host, .open = TestHost.open, .again = TestHost.askAgain });
    defer p.deinit();
    try testing.expect(p.refresh());
    // The root starts open: f, then its callers g and f (recursive).
    try testing.expectEqual(@as(usize, 3), p.tv.flat.len());
    try testing.expectEqualStrings("g", HierarchyPanel.label(&p, p.tv.flat.rows.items[1].node));
    try testing.expect(HierarchyPanel.childCount(&p, 3) == .leaf);
    try testing.expectEqualStrings("Callers of f", p.title());
    try testing.expect(!p.refresh());

    // A click shows the first call site, in the caller's file.
    HierarchyPanel.onClick(&p, 2);
    try testing.expectEqualStrings("/w/b.py:9", host.opened.items);
    try testing.expect(!host.focused);
    // Enter goes to the item and focuses it.
    HierarchyPanel.onOpen(&p, 2);
    try testing.expectEqualStrings("/w/b.py:7", host.opened.items);
    try testing.expect(host.focused);

    p.collapseAll();
    try testing.expectEqual(@as(usize, 1), p.tv.flat.len());
}
