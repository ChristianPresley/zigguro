//! The Loaded Scripts view (E07.F07.S01.T03): the sources the active
//! session's debuggee loaded, by folder, from `loadedSource` events and
//! the `loadedSources` request.
//!
//! - Folders are shown relative to the workspace when inside it, and
//!   open the first time they show; files sort by name.
//! - Sources without a path (a `sourceReference` only: generated or
//!   evaluated code) are grouped by their `origin`, else under "No Path".
//! - A click or Enter on a source opens it: a file at its first line, a
//!   reference as a read-only `dap-source:` document.
//!
//! `update` rebuilds the rows from a snapshot when the sources changed
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
    session: u32,
    name: []const u8,
    path: ?[]const u8 = null,
    reference: i64 = 0,
    origin: ?[]const u8 = null,
};

/// What `update` shows.
pub const Snapshot = struct {
    /// The workspace folder (folders inside it are shown relative).
    root: []const u8 = "",
    items: []const Item = &.{},
};

pub const Hooks = struct {
    ctx: *anyopaque,
    open: *const fn (ctx: *anyopaque, item: *const Item) void,
};

pub const no_path_label = "No Path";

const Node = struct {
    label: []const u8,
    /// Shown after the name: a source's origin.
    detail: []const u8 = "",
    item: ?Item = null,
    children: []const u64 = &.{},
};

pub const SourcesView = struct {
    gpa: Allocator,
    hooks: Hooks,
    tv: TreeView = undefined,
    arena: std.heap.ArenaAllocator,
    nodes: std.AutoHashMapUnmanaged(u64, Node) = .empty,
    roots: []const u64 = &.{},
    /// Folders shown before (a new one opens; a closed one stays closed).
    seen: std.AutoHashMapUnmanaged(u64, void) = .empty,

    /// `sv` must not move afterwards.
    pub fn init(sv: *SourcesView, gpa: Allocator, hooks: Hooks) !void {
        sv.* = .{ .gpa = gpa, .hooks = hooks, .arena = .init(gpa) };
        sv.tv = try TreeView.init(gpa, sv.source(), .{
            .label = "Loaded Scripts",
            .test_id = "debug-loaded-scripts",
            .expand_on_click = true,
            .on_open = .{ .ctx = sv, .f = onOpen },
            .on_click = .{ .ctx = sv, .f = onOpen },
        });
    }

    pub fn deinit(sv: *SourcesView) void {
        sv.tv.deinit();
        sv.nodes.deinit(sv.gpa);
        sv.seen.deinit(sv.gpa);
        sv.arena.deinit();
    }

    fn self(ptr: *anyopaque) *SourcesView {
        return @ptrCast(@alignCast(ptr));
    }

    pub fn isEmpty(sv: *const SourcesView) bool {
        return sv.roots.len == 0;
    }

    /// Rebuilds the rows from `snap` (copied).
    pub fn update(sv: *SourcesView, snap: Snapshot) Allocator.Error!void {
        sv.nodes.clearRetainingCapacity();
        _ = sv.arena.reset(.retain_capacity);
        const a = sv.arena.allocator();
        // Folders in name order, "No Path" groups last.
        const Group = struct { key: []const u8, no_path: bool, items: std.ArrayList(*const Item) = .empty };
        var groups: std.ArrayList(Group) = .empty;
        for (snap.items) |*it| {
            const no_path = it.path == null;
            const key = if (it.path) |p| folderOf(snap.root, p) else it.origin orelse no_path_label;
            const g = for (groups.items) |*g| {
                if (g.no_path == no_path and std.mem.eql(u8, g.key, key)) break g;
            } else blk: {
                try groups.append(a, .{ .key = key, .no_path = no_path });
                break :blk &groups.items[groups.items.len - 1];
            };
            try g.items.append(a, it);
        }
        std.mem.sort(Group, groups.items, {}, struct {
            fn lt(_: void, x: Group, y: Group) bool {
                if (x.no_path != y.no_path) return y.no_path;
                return std.mem.order(u8, x.key, y.key) == .lt;
            }
        }.lt);
        const roots = try a.alloc(u64, groups.items.len);
        for (groups.items, roots) |*g, *root| {
            std.mem.sort(*const Item, g.items.items, {}, struct {
                fn lt(_: void, x: *const Item, y: *const Item) bool {
                    return switch (std.mem.order(u8, x.name, y.name)) {
                        .lt => true,
                        .gt => false,
                        .eq => x.reference < y.reference,
                    };
                }
            }.lt);
            const kids = try a.alloc(u64, g.items.items.len);
            for (g.items.items, kids) |it, *k| {
                k.* = itemId(it);
                const detail = if (it.path != null) it.origin orelse "" else if (it.reference > 0) try std.fmt.allocPrint(a, "#{d}", .{it.reference}) else "";
                try sv.nodes.put(sv.gpa, k.*, .{
                    .label = try a.dupe(u8, it.name),
                    .detail = try a.dupe(u8, detail),
                    .item = .{
                        .session = it.session,
                        .name = try a.dupe(u8, it.name),
                        .path = if (it.path) |p| try a.dupe(u8, p) else null,
                        .reference = it.reference,
                    },
                });
            }
            root.* = groupId(g.key, g.no_path);
            try sv.nodes.put(sv.gpa, root.*, .{ .label = try a.dupe(u8, if (g.key.len == 0) "." else g.key), .children = kids });
        }
        sv.roots = roots;
        try sv.tv.reload();
        for (sv.roots) |r| {
            const seen = try sv.seen.getOrPut(sv.gpa, r);
            if (seen.found_existing) continue;
            if (sv.tv.flat.rowOf(r)) |row| if (!sv.tv.flat.isExpanded(r)) {
                _ = try sv.tv.expandRow(row);
            };
        }
    }

    /// `path`'s folder, relative to `root` when inside it ("" for `root`
    /// itself).
    fn folderOf(root: []const u8, path: []const u8) []const u8 {
        const dir = std.fs.path.dirname(path) orelse return "";
        if (root.len > 0 and std.mem.startsWith(u8, dir, root)) {
            const rest = dir[root.len..];
            if (rest.len == 0) return "";
            if (rest[0] == '/' or rest[0] == '\\') return rest[1..];
        }
        return dir;
    }

    fn groupId(key: []const u8, no_path: bool) u64 {
        // Bit 0 set: a folder (sources have it clear).
        return std.hash.Wyhash.hash(@intFromBool(no_path), key) | 1;
    }

    fn itemId(it: *const Item) u64 {
        var h = std.hash.Wyhash.init(it.session);
        h.update(it.path orelse it.name);
        h.update(std.mem.asBytes(&it.reference));
        return h.final() & ~@as(u64, 1);
    }

    // -- the tree's data --------------------------------------------------------

    fn source(sv: *SourcesView) TreeSource {
        return .{ .ptr = sv, .vtable = &vtable };
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

    fn childCount(ptr: *anyopaque, id: u64) ChildCount {
        const n = self(ptr).nodes.get(id) orelse return .leaf;
        return if (n.item != null) .leaf else .{ .known = @intCast(n.children.len) };
    }

    fn child(ptr: *anyopaque, parent: ?u64, i: u32) u64 {
        const sv = self(ptr);
        const p = parent orelse return sv.roots[i];
        return sv.nodes.get(p).?.children[i];
    }

    fn load(_: *anyopaque, _: u64, _: LoadDone) void {}

    fn label(ptr: *anyopaque, id: u64) []const u8 {
        const n = self(ptr).nodes.get(id) orelse return "";
        return n.label;
    }

    /// Row `id`'s accessible name.
    pub fn labelOf(sv: *SourcesView, id: u64) []const u8 {
        return label(sv, id);
    }

    fn buildRow(ptr: *anyopaque, ui: *Ui, id: u64, _: RowInfo) void {
        const sv = self(ptr);
        const n = sv.nodes.get(id) orelse return;
        ui.open(.{ .style = .{ .dir = .row, .gap = 6, .align_items = .center, .grow = 1, .shrink = 1 } });
        defer ui.close();
        ui.text(n.label, .{ .color = if (n.item == null) .fg_muted else .fg, .wrap = false });
        if (n.detail.len > 0) ui.text(n.detail, .{ .color = .fg_muted, .wrap = false });
    }

    // -- actions ------------------------------------------------------------------

    fn onOpen(ctx: *anyopaque, id: u64) void {
        const sv = self(ctx);
        const n = sv.nodes.getPtr(id) orelse return;
        if (n.item) |*it| sv.hooks.open(sv.hooks.ctx, it);
    }

    /// Focuses the tree.
    pub fn focus(sv: *SourcesView, w: *Window) void {
        if (!sv.tv.node.isNone() and w.store.valid(sv.tv.node)) w.setFocus(sv.tv.node, true);
    }

    pub fn build(sv: *SourcesView, ui: *Ui) void {
        sv.tv.win = ui.window();
        sv.tv.build(ui);
    }
};

const testing = std.testing;

const TestHooks = struct {
    opened: ?Item = null,
    fn open(ctx: *anyopaque, it: *const Item) void {
        const h: *TestHooks = @ptrCast(@alignCast(ctx));
        h.opened = it.*;
    }
};

fn rowLabels(sv: *SourcesView, a: Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (sv.tv.flat.rows.items) |r| try out.print(a, "{d}:{s}|", .{ r.depth, sv.labelOf(r.node) });
    return out.items;
}

test "ui: loaded scripts by folder, sources without a path last" {
    var h: TestHooks = .{};
    var sv: SourcesView = undefined;
    try sv.init(testing.allocator, .{ .ctx = &h, .open = TestHooks.open });
    defer sv.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const items = [_]Item{
        .{ .session = 1, .name = "main.zig", .path = "/w/src/main.zig" },
        .{ .session = 1, .name = "<eval>", .reference = 8 },
        .{ .session = 1, .name = "debug.zig", .path = "/usr/lib/zig/std/debug.zig" },
        .{ .session = 1, .name = "app.zig", .path = "/w/src/app.zig" },
        .{ .session = 1, .name = "build.zig", .path = "/w/build.zig" },
        .{ .session = 1, .name = "gen.js", .reference = 3, .origin = "source map" },
    };
    try sv.update(.{ .root = "/w", .items = &items });
    try testing.expectEqualStrings(
        "0:.|1:build.zig|0:/usr/lib/zig/std|1:debug.zig|0:src|1:app.zig|1:main.zig|" ++
            "0:No Path|1:<eval>|0:source map|1:gen.js|",
        try rowLabels(&sv, a),
    );
    // A click opens the source.
    SourcesView.onOpen(&sv, sv.tv.flat.rows.items[5].node);
    try testing.expectEqualStrings("/w/src/app.zig", h.opened.?.path.?);
    SourcesView.onOpen(&sv, sv.tv.flat.rows.items[8].node);
    try testing.expectEqual(@as(i64, 8), h.opened.?.reference);
    try testing.expect(h.opened.?.path == null);
    // A folder opens nothing; one closed stays closed across updates.
    h.opened = null;
    SourcesView.onOpen(&sv, sv.tv.flat.rows.items[0].node);
    try testing.expect(h.opened == null);
    _ = sv.tv.collapseRow(0);
    try sv.update(.{ .root = "/w", .items = &items });
    try testing.expectEqualStrings(
        "0:.|0:/usr/lib/zig/std|1:debug.zig|0:src|1:app.zig|1:main.zig|" ++
            "0:No Path|1:<eval>|0:source map|1:gen.js|",
        try rowLabels(&sv, a),
    );
}
