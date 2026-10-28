//! Rename, code actions and the lightbulb in the editor (E07.F04.S02.T02).
//!
//! F2 (`editor.rename`) asks the server where the symbol is; when it can
//! be renamed a box opens prefilled with its name. Enter renames, Ctrl+Enter
//! sends the edit to the review queue instead, Escape cancels. Errors (and
//! "can't rename this") show as a notice.
//!
//! Ctrl+. (`editor.quickFix`) asks every server for the actions at the
//! caret or selection and opens them as a menu below the caret, grouped
//! by kind, preferred first; picking a disabled one says why. When the
//! caret rests for `bulb_delay_ms` the quick fixes there are asked in the
//! background and a lightbulb marks the line when there are any.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_gui = @import("zg_gui");
const zg_editor = @import("zg_editor");
const zg_codeintel = @import("zg_codeintel");

const Allocator = std.mem.Allocator;
const Window = zg_gui.Window;
const Rect = zg_gui.core.Rect;
const DocHandle = zg_editor.model.api.registry.DocHandle;
const deco_store = zg_editor.model.decorations.store;
const DecorationStore = deco_store.DecorationStore;
const StyleRef = deco_store.StyleRef;
const Manager = zg_codeintel.Manager;
const Engine = zg_codeintel.edits.Engine;
const CommandService = zg_codeintel.features.CommandService;
const RenameService = zg_codeintel.features.RenameService;
const CodeActionService = zg_codeintel.features.CodeActionService;
const ByteRange = zg_codeintel.features.position.ByteRange;
const menu = zg_gui.w.menu;
const quick_pick = zg_gui.w.quick_pick;

const log = std.log.scoped(.refactor);

/// Caret rest before the lightbulb's quick fixes are asked.
pub const bulb_delay_ms = 250;
/// The gutter icon `EditorView` draws as a lightbulb.
pub const bulb_icon = deco_store.icon_lightbulb;

/// Shows a message (the workbench's notification toasts).
pub const Notice = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, warning: bool, msg: []const u8) void,
};

/// Finds an open document's editor decorations.
pub const DecoLookup = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, h: DocHandle) ?*DecorationStore,
};

pub const Refactor = struct {
    gpa: Allocator,
    mgr: *Manager,
    win: ?*Window = null,
    commands: CommandService,
    rename: RenameService,
    actions: CodeActionService,
    notice: ?Notice = null,
    decos: ?DecoLookup = null,
    /// The lightbulb's styles (plain, and with a preferred fix).
    bulb_style: [2]StyleRef,

    rename_seen: u64 = 0,
    rename_pick: quick_pick.QuickPickHandle = .{},
    /// The box is open for the current `.ready` state.
    rename_open: bool = false,
    rename_title: std.ArrayList(u8) = .empty,

    actions_seen: u64 = 0,
    /// Ctrl+. waits for every answer, then opens the menu here.
    menu_at: ?Rect = null,
    menu: menu.MenuHandle = .{},
    menu_arena: std.heap.ArenaAllocator,

    /// Where the caret rests: the lightbulb asks at `due_ms`.
    rest: ?struct { h: DocHandle, range: ByteRange, due_ms: u64 } = null,
    /// The caret the lightbulb (or its pending request) is for.
    caret_at: ?struct { h: DocHandle, range: ByteRange, version: u64 } = null,
    bulb: ?struct { deco: *DecorationStore, owner: deco_store.OwnerId } = null,

    /// In place: the services point at each other.
    pub fn init(r: *Refactor, mgr: *Manager, engine: *Engine, diags: ?*zg_codeintel.diagnostics.Store, waker: zg_core.runtime.Waker, bulb_style: [2]StyleRef) void {
        r.* = .{
            .gpa = mgr.gpa,
            .mgr = mgr,
            .commands = undefined,
            .rename = undefined,
            .actions = undefined,
            .bulb_style = bulb_style,
            .menu_arena = .init(mgr.gpa),
        };
        r.commands = .init(mgr, waker);
        r.rename = .init(mgr, engine, waker);
        r.actions = .init(mgr, engine, &r.commands, diags, waker);
    }

    /// Closes the box and menu; call before the editors' decorations go.
    pub fn close(r: *Refactor) void {
        if (r.win) |w| {
            r.rename_pick.close(w);
            r.menu.close(w);
        }
        r.clearBulb();
    }

    /// Call after `Manager.deinit`.
    pub fn deinit(r: *Refactor) void {
        r.rename.deinit();
        r.actions.deinit();
        r.commands.deinit();
        r.rename_title.deinit(r.gpa);
        r.menu_arena.deinit();
    }

    pub fn say(r: *Refactor, warning: bool, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
        if (r.notice) |n| n.f(n.ctx, warning, msg) else log.info("{s}", .{msg});
    }

    // -- rename ----------------------------------------------------------

    /// F2 at byte `offset` of `h`.
    pub fn startRename(r: *Refactor, h: DocHandle, offset: u64) void {
        if (!r.rename.available(h)) return r.say(false, "No language server can rename here", .{});
        r.rename.begin(h, offset) catch |e| r.say(true, "Rename failed: {t}", .{e});
        r.syncRename();
    }

    fn syncRename(r: *Refactor) void {
        if (r.rename.generation == r.rename_seen) return;
        r.rename_seen = r.rename.generation;
        switch (r.rename.state) {
            .ready => |st| if (!r.rename_open) {
                r.rename_open = true;
                r.openRenameBox(st.placeholder) catch |e| {
                    r.rename_open = false;
                    r.rename.cancel();
                    r.say(true, "Rename: {t}", .{e});
                };
            },
            .failed => |msg| {
                r.say(false, "{s}", .{msg});
                r.rename.cancel();
            },
            .done => |out| {
                switch (out) {
                    .queued => r.say(false, "The rename is waiting in the review queue", .{}),
                    .failed => |f| r.say(true, "Rename failed: {s}", .{f.reason}),
                    .applied => {},
                }
                r.rename.cancel();
            },
            .idle => if (r.rename_open) {
                r.rename_open = false;
                if (r.win) |w| r.rename_pick.close(w);
            },
            .preparing, .renaming => {},
        }
        r.rename_seen = r.rename.generation;
        if (r.win) |w| w.markAllDirty();
    }

    fn openRenameBox(r: *Refactor, name: []const u8) !void {
        const w = r.win orelse return error.NoWindow;
        r.rename_title.clearRetainingCapacity();
        try r.rename_title.print(r.gpa, "Rename '{s}' (Enter to rename, Ctrl+Enter to preview)", .{name});
        const provs = [_]quick_pick.Provider{.{ .ptr = r, .vtable = &rename_vtable }};
        r.rename_pick = try quick_pick.openQuickPick(w, .{
            .providers = &provs,
            .initial = name,
            .allow_free_text = true,
            .title = r.rename_title.items,
            .width = 420,
            .test_id = "rename-input",
        });
    }

    const rename_vtable: quick_pick.Provider.VTable = .{
        .placeholder = "New name",
        .items = noItems,
        .accept = renameAccept,
    };

    fn noItems(_: ?*anyopaque) []const quick_pick.QpItem {
        return &.{};
    }

    fn renameAccept(ptr: ?*anyopaque, _: []const quick_pick.QpItem, free_text: ?[]const u8, alt: bool) void {
        const r: *Refactor = @ptrCast(@alignCast(ptr.?));
        r.rename_open = false;
        const name = std.mem.trim(u8, free_text orelse "", " \t");
        const st = switch (r.rename.state) {
            .ready => |x| x,
            else => return,
        };
        if (name.len == 0 or (!alt and std.mem.eql(u8, name, st.placeholder))) return r.rename.cancel();
        r.rename.commit(name, if (alt) .force_review else .auto, .user) catch |e| r.say(true, "Rename failed: {t}", .{e});
        r.syncRename();
    }

    // -- code actions ----------------------------------------------------

    /// Ctrl+.: the actions over `range` of `h`, as a menu at `at` (the
    /// caret, in window coordinates) once every server answered.
    pub fn quickFix(r: *Refactor, h: DocHandle, range: ByteRange, at: Rect) void {
        if (!r.actions.available(h)) return r.say(false, "No language server offers code actions here", .{});
        r.rest = null;
        r.clearBulb();
        r.actions.request(h, range, .invoked, null) catch |e| return r.say(true, "Code actions: {t}", .{e});
        r.menu_at = at;
        r.caret_at = null;
        r.syncActions();
    }

    fn syncActions(r: *Refactor) void {
        if (r.actions.failure.items.len > 0) {
            r.say(false, "{s}", .{r.actions.failure.items});
            r.actions.failure.clearRetainingCapacity();
        }
        const t = r.actions.target() orelse {
            if (r.menu_at != null) {
                r.menu_at = null;
                r.say(false, "No code actions available", .{});
            }
            return;
        };
        if (!r.actions.complete()) return;
        if (r.actions.generation == r.actions_seen and r.menu_at == null) return;
        r.actions_seen = r.actions.generation;
        switch (t.trigger) {
            .invoked => if (r.menu_at) |at| {
                r.menu_at = null;
                r.openMenu(at) catch |e| r.say(true, "Code actions: {t}", .{e});
            },
            .automatic => r.placeBulb(t.h, t.range),
        }
    }

    fn openMenu(r: *Refactor, at: Rect) !void {
        const w = r.win orelse return;
        const list = r.actions.items();
        if (list.len == 0) return r.say(false, "No code actions available", .{});
        _ = r.menu_arena.reset(.retain_capacity);
        const a = r.menu_arena.allocator();
        var rows: std.ArrayList(menu.MenuItem) = .empty;
        var group: ?CodeActionService.Group = null;
        var disabled_seen = false;
        for (list, 0..) |it, i| {
            if (it.disabled != null) {
                if (!disabled_seen) {
                    if (rows.items.len > 0) try rows.append(a, .separator);
                    disabled_seen = true;
                }
            } else if (group != it.group) {
                group = it.group;
                try rows.append(a, .{ .header = it.group.label() });
            }
            const label = if (it.disabled) |why| try std.fmt.allocPrint(a, "{s} ({s})", .{ it.title, why }) else it.title;
            try rows.append(a, .{ .action = .{ .label = try escapeMnemonic(a, label), .action = "codeintel.codeAction", .arg = try std.fmt.allocPrint(a, "{d}", .{i}) } });
        }
        r.menu.close(w);
        r.menu = try menu.openMenu(w, rows.items, .{ .rect = at }, .{
            .on_action = .{ .ctx = r, .f = onMenuAction },
            .keyboard = true,
            .test_id = "code-actions",
        });
    }

    /// `&` marks a mnemonic in menu labels.
    fn escapeMnemonic(a: Allocator, s: []const u8) ![]const u8 {
        if (std.mem.indexOfScalar(u8, s, '&') == null) return s;
        return std.mem.replaceOwned(u8, a, s, "&", "&&");
    }

    fn onMenuAction(ctx: ?*anyopaque, _: menu.ActionId, arg: ?[]const u8) void {
        const r: *Refactor = @ptrCast(@alignCast(ctx.?));
        const i = std.fmt.parseInt(usize, arg orelse return, 10) catch return;
        if (i >= r.actions.items().len) return;
        r.actions.run(i, .user) catch |e| r.say(true, "Code action failed: {t}", .{e});
        r.syncActions();
        r.clearBulb();
        r.caret_at = null;
    }

    // -- lightbulb -------------------------------------------------------

    /// The caret (or selection) of the editor showing `h` is `range` at
    /// document `version`.
    pub fn caret(r: *Refactor, h: DocHandle, range: ByteRange, version: u64, now_ms: u64) void {
        if (r.caret_at) |c| if (std.meta.eql(c.h, h) and std.meta.eql(c.range, range) and c.version == version) return;
        r.caret_at = .{ .h = h, .range = range, .version = version };
        r.clearBulb();
        if (r.menu_at != null) return;
        if (r.win) |w| if (r.menu.isOpen(w)) return;
        if (r.actions.target()) |t| if (t.trigger == .automatic) r.actions.cancel();
        r.rest = if (r.actions.available(h)) .{ .h = h, .range = range, .due_ms = now_ms + bulb_delay_ms } else null;
    }

    fn placeBulb(r: *Refactor, h: DocHandle, range: ByteRange) void {
        r.clearBulb();
        const b = r.actions.bulb();
        if (!b.any) return;
        const lk = r.decos orelse return;
        const d = lk.f(lk.ctx, h) orelse return;
        const doc = r.mgr.docs.get(h) orelse return;
        const owner = d.ownerByName("lsp.lightbulb") orelse d.registerOwner("lsp.lightbulb", 10) catch return;
        const deco: deco_store.Decoration = .{
            .range = .{ .start = range.start, .end = range.start },
            .owner = owner,
            .kind = .{ .gutter = .{ .lane = 1, .icon = bulb_icon, .style = r.bulb_style[@intFromBool(b.preferred)] } },
        };
        d.setOwnerDecorations(owner, doc.version, (&deco)[0..1]) catch return;
        r.bulb = .{ .deco = d, .owner = owner };
        if (r.win) |w| w.markAllDirty();
    }

    fn clearBulb(r: *Refactor) void {
        const b = r.bulb orelse return;
        b.deco.clearOwner(b.owner);
        r.bulb = null;
        if (r.win) |w| w.markAllDirty();
    }

    /// `d` is going away (its editor closed).
    pub fn forget(r: *Refactor, d: *DecorationStore) void {
        if (r.bulb) |b| if (b.deco == d) r.clearBulb();
    }

    /// Applies answers; returns when it next needs a tick, if timed.
    pub fn tick(r: *Refactor, now_ms: u64) ?u64 {
        if (r.commands.tick()) |msg| r.say(true, "{s}", .{msg});
        _ = r.rename.tick();
        // Escape closed the box.
        if (r.rename_open) if (r.win) |w| if (!r.rename_pick.isOpen(w)) {
            r.rename_open = false;
            r.rename.cancel();
        };
        r.syncRename();
        _ = r.actions.tick();
        r.syncActions();
        if (r.rest) |rs| {
            if (now_ms < rs.due_ms) return rs.due_ms;
            r.rest = null;
            r.actions.request(rs.h, rs.range, .automatic, &.{"quickfix"}) catch |e| log.debug("lightbulb: {t}", .{e});
        }
        return null;
    }
};
