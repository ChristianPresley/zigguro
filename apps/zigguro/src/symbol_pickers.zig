//! Go to Symbol in File and in Workspace (E07.F04.S01.T02).
//!
//! `quickOpen.symbolsInFile` (Ctrl+Shift+O) lists the outline of the
//! current file, indented by depth; typing ":" first groups the symbols
//! by kind. Moving through the list previews each symbol (the editor
//! scrolls to it and selects its name); Escape puts the selection and
//! scroll back, Enter keeps the place (Go Back returns).
//!
//! `quickOpen.symbols` (Ctrl+T) searches the workspace: the language
//! servers are asked as the text changes (debounced), the list updates
//! as answers come, and a pick opens the file at the symbol (resolving
//! it first when the server sent no position).

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_editor = @import("zg_editor");
const zg_codeintel = @import("zg_codeintel");

const Allocator = std.mem.Allocator;
const Window = zg_gui.Window;
const EditorView = zg_editor.view.EditorView;
const Selection = zg_editor.model.edit.selection.Selection;
const DocHandle = zg_editor.model.api.registry.DocHandle;
const OutlineProvider = zg_codeintel.features.OutlineProvider;
const WorkspaceSymbols = zg_codeintel.features.WorkspaceSymbols;
const NavService = zg_codeintel.features.NavService;
const quick_pick = zg_gui.w.quick_pick;
const QpItem = quick_pick.QpItem;
const Vec2 = zg_gui.core.Vec2;

/// The workbench's side: jumps that Go Back can return from.
pub const Host = struct {
    ctx: *anyopaque,
    /// The caret goes to `offset` of the current editor.
    here: *const fn (ctx: *anyopaque, view: *EditorView, sel: Selection) void,
    /// Opens a target (another file, perhaps).
    to: *const fn (ctx: *anyopaque, t: NavService.Target) void,
    notice: *const fn (ctx: *anyopaque, msg: []const u8) void,
};

pub const SymbolPickers = struct {
    gpa: Allocator,
    outline: *OutlineProvider,
    ws: *WorkspaceSymbols,
    host: ?Host = null,
    win: ?*Window = null,

    // In file.
    doc_pick: quick_pick.QuickPickHandle = .{},
    doc_h: ?DocHandle = null,
    doc_view: ?*EditorView = null,
    saved_sel: Selection = .caret(0),
    saved_scroll: Vec2 = .{},
    doc_version: ?u64 = null,
    flat: std.ArrayList(OutlineProvider.Outline.Flat) = .empty,
    items: std.ArrayList(QpItem) = .empty,
    by_kind: std.ArrayList(QpItem) = .empty,
    arena: std.heap.ArenaAllocator,

    // In workspace.
    ws_pick: quick_pick.QuickPickHandle = .{},
    ws_items: std.ArrayList(QpItem) = .empty,
    ws_arena: std.heap.ArenaAllocator,
    ws_seen: u64 = 0,
    now_ms: u64 = 0,

    pub fn init(gpa: Allocator, outline: *OutlineProvider, ws: *WorkspaceSymbols) SymbolPickers {
        return .{ .gpa = gpa, .outline = outline, .ws = ws, .arena = .init(gpa), .ws_arena = .init(gpa) };
    }

    pub fn deinit(p: *SymbolPickers) void {
        if (p.win) |w| {
            p.doc_pick.close(w);
            p.ws_pick.close(w);
        }
        p.flat.deinit(p.gpa);
        p.items.deinit(p.gpa);
        p.by_kind.deinit(p.gpa);
        p.arena.deinit();
        p.ws_items.deinit(p.gpa);
        p.ws_arena.deinit();
    }

    // -- in file -----------------------------------------------------------

    /// Opens the picker over `view` showing `h`.
    pub fn openDocument(p: *SymbolPickers, win: *Window, view: *EditorView, h: DocHandle, now_ms: u64) !void {
        p.win = win;
        p.doc_pick.close(win);
        p.doc_h = h;
        p.doc_view = view;
        p.saved_sel = view.primarySel();
        p.saved_scroll = view.scroll;
        try p.outline.want(h, now_ms);
        p.rebuild();
        const provs = [_]quick_pick.Provider{
            .{ .ptr = p, .vtable = &doc_vtable },
            .{ .ptr = p, .vtable = &kind_vtable },
        };
        p.doc_pick = try quick_pick.openQuickPick(win, .{ .providers = &provs, .initial = "@", .title = "Go to Symbol in File", .test_id = "symbols-in-file" });
    }

    /// The outline changed (or arrived): the open picker lists it again.
    pub fn outlineChanged(p: *SymbolPickers, h: DocHandle) void {
        const d = p.doc_h orelse return;
        if (!std.meta.eql(d, h)) return;
        const w = p.win orelse return;
        if (!p.doc_pick.isOpen(w)) return;
        p.rebuild();
        p.doc_pick.refresh(w);
    }

    fn rebuild(p: *SymbolPickers) void {
        p.items.clearRetainingCapacity();
        p.by_kind.clearRetainingCapacity();
        p.flat.clearRetainingCapacity();
        _ = p.arena.reset(.retain_capacity);
        const h = p.doc_h orelse return;
        const o = p.outline.get(h) orelse return;
        p.doc_version = o.version;
        o.flatten(p.gpa, &p.flat) catch return;
        const a = p.arena.allocator();
        for (p.flat.items, 0..) |fl, i| {
            const n = fl.node;
            const indent = @min(fl.depth, 8) * 2;
            const label = std.fmt.allocPrint(a, "{s}{s}", .{ "                "[0..indent], n.name }) catch return;
            const it: QpItem = .{ .id = i, .label = label, .description = n.detail orelse "" };
            p.items.append(p.gpa, it) catch return;
            p.by_kind.append(p.gpa, .{ .id = i, .label = n.name, .description = n.detail orelse "", .group = kindLabel(n.kind) }) catch return;
        }
        std.sort.block(QpItem, p.by_kind.items, p, struct {
            fn lt(self: *SymbolPickers, x: QpItem, y: QpItem) bool {
                const kx = @intFromEnum(self.flat.items[@intCast(x.id)].node.kind);
                const ky = @intFromEnum(self.flat.items[@intCast(y.id)].node.kind);
                return if (kx != ky) kx < ky else x.id < y.id;
            }
        }.lt);
        // Group labels carry their counts.
        var i: usize = 0;
        while (i < p.by_kind.items.len) {
            const k = p.flat.items[@intCast(p.by_kind.items[i].id)].node.kind;
            var j = i;
            while (j < p.by_kind.items.len and p.flat.items[@intCast(p.by_kind.items[j].id)].node.kind == k) j += 1;
            const g = std.fmt.allocPrint(a, "{s} ({d})", .{ kindLabel(k), j - i }) catch return;
            for (p.by_kind.items[i..j]) |*it| it.group = g;
            i = j;
        }
    }

    pub fn kindLabel(k: zg_codeintel.protocol.SymbolKind) []const u8 {
        return switch (k) {
            .TypeParameter => "Type Parameter",
            .EnumMember => "Enum Member",
            _ => "Symbol",
            else => @tagName(k),
        };
    }

    const doc_vtable: quick_pick.Provider.VTable = .{
        .prefix = "@",
        .placeholder = "Symbol name (type : to group by kind)",
        .items = docItems,
        .active = docActive,
        .accept = docAccept,
    };

    const kind_vtable: quick_pick.Provider.VTable = .{
        .prefix = "@:",
        .placeholder = "Symbol name, by kind",
        .items = kindItems,
        .active = docActive,
        .accept = docAccept,
    };

    fn docItems(ptr: ?*anyopaque) []const QpItem {
        const p: *SymbolPickers = @ptrCast(@alignCast(ptr.?));
        return p.items.items;
    }

    fn kindItems(ptr: ?*anyopaque) []const QpItem {
        const p: *SymbolPickers = @ptrCast(@alignCast(ptr.?));
        return p.by_kind.items;
    }

    /// The symbol `id` names, if still current.
    fn nodeOf(p: *SymbolPickers, id: u64) ?*const zg_codeintel.features.OutlineProvider.SymbolNode {
        if (id >= p.flat.items.len) return null;
        const view = p.doc_view orelse return null;
        if (p.doc_version != view.doc.version) return null;
        return p.flat.items[@intCast(id)].node;
    }

    fn docActive(ptr: ?*anyopaque, item: ?QpItem) void {
        const p: *SymbolPickers = @ptrCast(@alignCast(ptr.?));
        const view = p.doc_view orelse return;
        const it = item orelse {
            // Closed without a pick: back to where it was.
            view.setSelection(p.saved_sel);
            view.scrollBy(.{ .x = p.saved_scroll.x - view.scroll.x, .y = p.saved_scroll.y - view.scroll.y });
            return;
        };
        const n = p.nodeOf(it.id) orelse return;
        view.setSelection(.{ .anchor = n.selection.start, .head = n.selection.end });
        view.revealRange(.{ .start = n.range.start, .end = @min(n.range.end, n.range.start + 1) });
        view.revealPrimary();
    }

    fn docAccept(ptr: ?*anyopaque, items: []const QpItem, _: ?[]const u8, _: bool) void {
        const p: *SymbolPickers = @ptrCast(@alignCast(ptr.?));
        const view = p.doc_view orelse return;
        if (items.len == 0) return;
        const n = p.nodeOf(items[0].id) orelse return;
        // The preview moved the caret: Go Back returns to where it was.
        view.setSelection(p.saved_sel);
        const h = p.host orelse return;
        h.here(h.ctx, view, .caret(n.selection.start));
        view.revealPrimary();
    }

    // -- in workspace ------------------------------------------------------

    pub fn openWorkspace(p: *SymbolPickers, win: *Window) !void {
        p.win = win;
        p.ws_pick.close(win);
        if (!p.ws.available()) {
            if (p.host) |h| h.notice(h.ctx, "No language server can search the workspace's symbols");
            return;
        }
        try p.ws.query("", p.now_ms);
        p.ws_items.clearRetainingCapacity();
        const provs = [_]quick_pick.Provider{.{ .ptr = p, .vtable = &ws_vtable }};
        p.ws_pick = try quick_pick.openQuickPick(win, .{ .providers = &provs, .initial = "#", .title = "Go to Symbol in Workspace", .test_id = "symbols-in-workspace" });
    }

    const ws_vtable: quick_pick.Provider.VTable = .{
        .prefix = "#",
        .placeholder = "Symbol name",
        .items = wsItems,
        .query_changed = wsQuery,
        .accept = wsAccept,
    };

    fn wsItems(ptr: ?*anyopaque) []const QpItem {
        const p: *SymbolPickers = @ptrCast(@alignCast(ptr.?));
        return p.ws_items.items;
    }

    fn wsQuery(ptr: ?*anyopaque, q: []const u8) void {
        const p: *SymbolPickers = @ptrCast(@alignCast(ptr.?));
        p.ws.query(q, p.now_ms) catch {};
    }

    fn wsAccept(ptr: ?*anyopaque, items: []const QpItem, _: ?[]const u8, _: bool) void {
        const p: *SymbolPickers = @ptrCast(@alignCast(ptr.?));
        if (items.len == 0 or items[0].id >= p.ws.hits().len) return;
        p.ws.pick(@intCast(items[0].id)) catch {};
        p.takeResolved();
    }

    fn takeResolved(p: *SymbolPickers) void {
        const hit = p.ws.takeResolved() orelse return;
        const h = p.host orelse return;
        const zero: zg_codeintel.protocol.Range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } };
        const r = hit.range orelse zero;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const path = zg_codeintel.protocol_uri.pathFromUri(fba.allocator(), hit.uri) catch null;
        h.to(h.ctx, .{ .uri = hit.uri, .path = path, .selection = r, .range = r, .enc = zg_codeintel.features.position.encodingOf(hit.enc) });
    }

    /// Lists new workspace answers and opens a resolved pick.
    pub fn tick(p: *SymbolPickers, now_ms: u64) void {
        p.now_ms = now_ms;
        p.takeResolved();
        const w = p.win orelse return;
        if (!p.ws_pick.isOpen(w) or p.ws.generation == p.ws_seen) return;
        p.ws_seen = p.ws.generation;
        p.ws_items.clearRetainingCapacity();
        _ = p.ws_arena.reset(.retain_capacity);
        const a = p.ws_arena.allocator();
        for (p.ws.hits(), 0..) |hit, i| {
            const file = std.fs.path.basename(hit.uri);
            const desc = if (hit.container) |c| std.fmt.allocPrint(a, "{s}  {s}", .{ c, file }) catch file else file;
            p.ws_items.append(p.gpa, .{ .id = i, .label = hit.name, .description = desc, .detail = "" }) catch break;
        }
        p.ws_pick.refresh(w);
    }
};
