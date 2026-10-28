//! The Variables and Watch views (E07.F07.S01.T03): trees over a
//! session's inspection models (zg_dap's `VariablesModel` and `Watches`).
//!
//! - **Variables.** The selected frame's scopes as roots; rows read
//!   `name: value`, the value in the warning colour when it changed since
//!   the previous stop, rows of an earlier stop greyed while the program
//!   runs. Lazy values read "(click to evaluate)" and evaluate when
//!   opened; large arrays open into `[0 … 99]` buckets. Opening and
//!   closing rows goes to the model, so they stay open across stops.
//! - **Watch.** One row per expression with its result (errors in the
//!   error colour, "not available" while running, "timed out"), opening
//!   into the result's children; a last "Add Expression…" row.
//! - **Editing.** Enter, a double click or F2 edits the active row in
//!   place: a variable's value (`setValue`; a refusal shows under the
//!   field, which stays open) or a watch's expression (empty removes it).
//! - Node ids are the model's `NodeId`s (stable across stops); watch rows
//!   take ids from a reserved range.
//! - Accessible names read "name, value, type".
//!
//! `update` re-reads the models after they changed (not per frame). UI
//! thread only.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_dap = @import("zg_dap");

const Allocator = std.mem.Allocator;
const Ui = zg_gui.Ui;
const Window = zg_gui.Window;
const virtual = zg_gui.virtual;
const TreeView = virtual.TreeView;
const TreeSource = virtual.TreeSource;
const ChildCount = virtual.tree_view.ChildCount;
const RowInfo = virtual.tree_view.RowInfo;
const LoadDone = virtual.tree_view.LoadDone;
const Inspector = zg_dap.inspect.Inspector;
const VariablesModel = zg_dap.inspect.VariablesModel;
const Watches = zg_dap.inspect.Watches;
const NodeId = VariablesModel.NodeId;

pub const Mode = enum { variables, watch };

/// Watch rows: `watch_base + index`; the add row is `add_row`.
const watch_base: u64 = 0xffff_ff00_0000_0000;
const add_row: u64 = 0xffff_ffff_ffff_fffe;

pub const add_label = "Add Expression\u{2026}";

/// What the view asks of its owner (the debug service).
pub const Hooks = struct {
    ctx: *anyopaque,
    /// Something to repaint.
    changed: *const fn (ctx: *anyopaque) void,
    /// The watch list changed (`add`, `edit`, `remove`): applied to every
    /// session's list by the owner.
    watch_add: *const fn (ctx: *anyopaque, expr: []const u8) void,
    watch_edit: *const fn (ctx: *anyopaque, index: u32, expr: []const u8) void,
    watch_remove: *const fn (ctx: *anyopaque, index: u32) void,
    /// A value was set: the watches may read it.
    value_set: *const fn (ctx: *anyopaque) void,
};

pub const VarTree = struct {
    gpa: Allocator,
    mode: Mode,
    hooks: Hooks,
    tv: TreeView = undefined,
    /// The models shown (null: no session).
    insp: ?*Inspector = null,
    /// Rows waiting for their children.
    loading: std.AutoArrayHashMapUnmanaged(u64, void) = .empty,
    done: ?LoadDone = null,
    /// The row being edited, its text and the last refusal.
    editing: ?u64 = null,
    edit_buf: zg_gui.w.TextBuffer,
    edit_err: ?[]u8 = null,
    focus_edit: bool = false,
    edit_node: zg_gui.core.NodeId = .none,
    /// Set answers that arrive after the edit moved on are dropped.
    edit_token: u64 = 0,
    /// Labels built for the rows this frame (accessible names).
    label_arena: std.heap.ArenaAllocator,

    /// `vt` must not move afterwards.
    pub fn init(vt: *VarTree, gpa: Allocator, mode: Mode, hooks: Hooks) !void {
        vt.* = .{ .gpa = gpa, .mode = mode, .hooks = hooks, .edit_buf = try .init(gpa, ""), .label_arena = .init(gpa) };
        errdefer vt.edit_buf.deinit();
        vt.tv = try TreeView.init(gpa, vt.source(), .{
            .label = if (mode == .variables) "Variables" else "Watch",
            .test_id = if (mode == .variables) "debug-variables" else "debug-watch",
            .expand_on_click = mode == .variables,
            .on_open = .{ .ctx = vt, .f = onOpen },
            .on_click = .{ .ctx = vt, .f = onClick },
            .on_toggle = .{ .ctx = vt, .f = onToggle },
        });
    }

    pub fn deinit(vt: *VarTree) void {
        vt.tv.deinit();
        vt.loading.deinit(vt.gpa);
        vt.edit_buf.deinit();
        if (vt.edit_err) |e| vt.gpa.free(e);
        vt.label_arena.deinit();
    }

    fn self(ptr: *anyopaque) *VarTree {
        return @ptrCast(@alignCast(ptr));
    }

    fn vm(vt: *VarTree) ?*VariablesModel {
        const i = vt.insp orelse return null;
        return &i.vars;
    }

    fn watches(vt: *const VarTree) []const Watches.WatchResult {
        const i = vt.insp orelse return &.{};
        return i.watches.results();
    }

    /// Shows `insp`'s models (re-read: call after they changed).
    pub fn update(vt: *VarTree, insp: ?*Inspector) Allocator.Error!void {
        if (vt.insp != insp) {
            vt.loading.clearRetainingCapacity();
            if (vt.editing) |e| if (e != add_row) vt.stopEdit();
        }
        vt.insp = insp;
        _ = vt.label_arena.reset(.retain_capacity);
        try vt.tv.reload();
        // Scopes the model shows open (the first one by default).
        if (vt.mode == .variables) if (vt.vm()) |m| for (m.roots()) |r| {
            if (!m.isExpanded(@enumFromInt(@intFromEnum(r)))) continue;
            const id = @intFromEnum(r);
            if (vt.tv.flat.isExpanded(id)) continue;
            const row = vt.tv.flat.rowOf(id) orelse continue;
            _ = try vt.tv.expandRow(row);
        };
        // Rows whose children arrived.
        var i: usize = 0;
        while (i < vt.loading.count()) {
            const id = vt.loading.keys()[i];
            switch (vt.childCountOf(id)) {
                .unknown_loading => i += 1,
                else => {
                    vt.loading.swapRemoveAt(i);
                    if (vt.done) |d| d.call(id);
                },
            }
        }
        if (vt.editing) |e| if (e != add_row and vt.tv.flat.rowOf(e) == null) vt.stopEdit();
    }

    // -- the tree's data --------------------------------------------------------

    fn source(vt: *VarTree) TreeSource {
        return .{ .ptr = vt, .vtable = &vtable };
    }

    const vtable: TreeSource.VTable = .{
        .root_count = rootCount,
        .child_count = childCount,
        .child = child,
        .load = load,
        .label = label,
        .build_row = buildRow,
    };

    /// The model node under row `id` (a watch row: its result's).
    fn varOf(vt: *const VarTree, id: u64) ?NodeId {
        if (id == add_row) return null;
        if (id >= watch_base) {
            const i = id - watch_base;
            const ws = vt.watches();
            if (i >= ws.len) return null;
            const r = ws[i].result orelse return null;
            if (ws[i].state != .ok and ws[i].state != .not_stopped) return null;
            return r.node;
        }
        return @enumFromInt(id);
    }

    fn rootCount(ptr: *anyopaque) u32 {
        const vt = self(ptr);
        return switch (vt.mode) {
            .variables => if (vt.vm()) |m| @intCast(m.roots().len) else 0,
            .watch => @intCast(vt.watches().len + 1),
        };
    }

    fn childCount(ptr: *anyopaque, id: u64) ChildCount {
        return self(ptr).childCountOf(id);
    }

    fn childCountOf(vt: *VarTree, id: u64) ChildCount {
        const m = vt.vm() orelse return .leaf;
        const n = vt.varOf(id) orelse return .leaf;
        const v = m.node(n) orelse return .leaf;
        switch (v.kind) {
            .more => return .leaf,
            .variable => if (v.child_count == null and !v.lazy) return .leaf,
            .scope, .bucket => {},
        }
        const p = m.peekChildren(n) orelse return .unknown_loading;
        if (p.ids.len == 0) return .leaf;
        return .{ .known = @intCast(p.ids.len) };
    }

    fn child(ptr: *anyopaque, parent: ?u64, i: u32) u64 {
        const vt = self(ptr);
        const p = parent orelse return switch (vt.mode) {
            .variables => @intFromEnum(vt.vm().?.roots()[i]),
            .watch => if (i < vt.watches().len) watch_base + i else add_row,
        };
        const kids = vt.vm().?.peekChildren(vt.varOf(p).?).?;
        return @intFromEnum(kids.ids[i]);
    }

    fn load(ptr: *anyopaque, id: u64, done: LoadDone) void {
        const vt = self(ptr);
        const m = vt.vm() orelse return;
        const n = vt.varOf(id) orelse return;
        vt.done = done;
        vt.loading.put(vt.gpa, id, {}) catch return;
        m.expand(n, true);
        vt.hooks.changed(vt.hooks.ctx);
    }

    fn onToggle(ctx: *anyopaque, id: u64, expanded: bool) void {
        const vt = self(ctx);
        const m = vt.vm() orelse return;
        const n = vt.varOf(id) orelse return;
        m.expand(n, expanded);
        vt.hooks.changed(vt.hooks.ctx);
    }

    /// What a row shows.
    const Text = struct {
        name: []const u8,
        value: []const u8 = "",
        type: ?[]const u8 = null,
        tone: enum { normal, changed, err, muted, link } = .normal,
    };

    fn rowText(vt: *VarTree, id: u64) Text {
        if (id == add_row) return .{ .name = add_label, .tone = .link };
        if (id >= watch_base) {
            const ws = vt.watches();
            const i = id - watch_base;
            if (i >= ws.len) return .{ .name = "" };
            const w = ws[i];
            return switch (w.state) {
                .pending => .{ .name = w.expr, .value = "\u{2026}", .tone = .muted },
                .ok => .{ .name = w.expr, .value = w.result.?.value, .type = w.result.?.type },
                .error_ => .{ .name = w.expr, .value = if (w.result) |r| r.value else "error", .tone = .err },
                .timed_out => .{ .name = w.expr, .value = "timed out", .tone = .err },
                .not_stopped => .{ .name = w.expr, .value = if (w.result) |r| r.value else "not available", .tone = .muted },
            };
        }
        const m = vt.vm() orelse return .{ .name = "" };
        const n: NodeId = @enumFromInt(id);
        const v = m.node(n) orelse return .{ .name = "" };
        const live = m.isLive(n);
        if (v.kind == .scope or v.kind == .bucket) return .{ .name = v.name, .tone = if (live) .normal else .muted };
        if (v.kind == .more) return .{ .name = v.name, .value = v.value, .tone = if (v.err) .err else .muted };
        return .{
            .name = v.name,
            .value = if (v.lazy) VariablesModel.lazy_label else v.value,
            .type = v.type,
            .tone = if (!live) .muted else if (v.err) .err else if (v.changed) .changed else .normal,
        };
    }

    fn label(ptr: *anyopaque, id: u64) []const u8 {
        const vt = self(ptr);
        const t = vt.rowText(id);
        const a = vt.label_arena.allocator();
        if (t.value.len == 0) return t.name;
        if (t.type) |ty| if (ty.len > 0) return std.fmt.allocPrint(a, "{s}, {s}, {s}", .{ t.name, t.value, ty }) catch t.name;
        return std.fmt.allocPrint(a, "{s}, {s}", .{ t.name, t.value }) catch t.name;
    }

    fn buildRow(ptr: *anyopaque, ui: *Ui, id: u64, _: RowInfo) void {
        const vt = self(ptr);
        if (vt.editing == id) return vt.editRow(ui, id);
        const t = vt.rowText(id);
        ui.open(.{ .style = .{ .dir = .row, .gap = 0, .align_items = .center, .grow = 1, .shrink = 1 } });
        defer ui.close();
        const name_color: zg_gui.theme.Token = switch (t.tone) {
            .link => .fg_link,
            .muted => .fg_muted,
            else => .fg,
        };
        ui.text(t.name, .{ .color = name_color, .wrap = false });
        if (t.value.len == 0) return;
        ui.text(": ", .{ .color = .fg_muted, .wrap = false });
        ui.text(t.value, .{ .color = switch (t.tone) {
            .changed => .warning,
            .err => .danger,
            .muted => .fg_muted,
            else => .info,
        }, .wrap = false });
    }

    // -- editing ------------------------------------------------------------------

    /// Whether row `id` can be edited.
    fn editable(vt: *VarTree, id: u64) bool {
        if (id == add_row or id >= watch_base) return vt.mode == .watch;
        const m = vt.vm() orelse return false;
        const n: NodeId = @enumFromInt(id);
        const v = m.node(n) orelse return false;
        if (v.kind != .variable or v.lazy or v.err or !m.isLive(n)) return false;
        if (v.hint) |h| if (h.read_only) return false;
        return true;
    }

    /// Edits row `id` in place (false when it cannot be edited).
    pub fn startEdit(vt: *VarTree, id: u64) bool {
        if (!vt.editable(id)) return false;
        const initial: []const u8 = blk: {
            if (id == add_row) break :blk "";
            if (id >= watch_base) break :blk vt.watches()[id - watch_base].expr;
            break :blk vt.vm().?.node(@enumFromInt(id)).?.value;
        };
        vt.edit_buf.setText(initial) catch return false;
        vt.clearErr();
        vt.editing = id;
        vt.edit_token += 1;
        vt.focus_edit = true;
        vt.tv.markDirty();
        return true;
    }

    /// Edits the active row (F2).
    pub fn editActive(vt: *VarTree) bool {
        const id = vt.tv.active orelse return false;
        return vt.startEdit(id);
    }

    /// The Watch view's "Add Expression…" row in edit.
    pub fn addExpression(vt: *VarTree) void {
        _ = vt.startEdit(add_row);
    }

    fn stopEdit(vt: *VarTree) void {
        vt.editing = null;
        vt.edit_token += 1;
        vt.clearErr();
        vt.tv.markDirty();
    }

    fn clearErr(vt: *VarTree) void {
        if (vt.edit_err) |e| vt.gpa.free(e);
        vt.edit_err = null;
    }

    fn editRow(vt: *VarTree, ui: *Ui, id: u64) void {
        ui.open(.{ .style = .{ .dir = .row, .gap = 6, .align_items = .center, .grow = 1, .shrink = 1 } });
        defer ui.close();
        const t = vt.rowText(id);
        const is_var = id < watch_base;
        if (is_var) ui.text(t.name, .{ .color = .fg, .wrap = false });
        var lb: [160]u8 = undefined;
        const a11y = if (is_var) std.fmt.bufPrint(&lb, "Value of {s}", .{t.name}) catch "Value" else "Watch expression";
        ui.open(.{ .style = .{ .grow = 1, .shrink = 1, .basis = .{ .px = 0 } } });
        const r = zg_gui.w.textField(ui, .{ .buffer = &vt.edit_buf, .invalid = vt.edit_err != null, .a11y_label = a11y, .placeholder = if (is_var) "" else "Expression to watch", .font = .mono });
        vt.edit_node = ui.lastNode();
        ui.close();
        if (vt.edit_err) |e| ui.text(e, .{ .color = .danger, .wrap = false });
        if (vt.focus_edit) {
            vt.focus_edit = false;
            ui.window().afterNextFrame(.{ .ctx = vt, .f = focusEdit });
        }
        if (r.changed) vt.clearErr();
        if (r.cancelled) return vt.stopEdit();
        if (r.submitted) vt.submit(id);
    }

    fn focusEdit(ctx: *anyopaque, w: *Window) void {
        const vt = self(ctx);
        if (!vt.edit_node.isNone() and w.store.valid(vt.edit_node)) w.setFocus(vt.edit_node, true);
    }

    /// Submits the edit in progress (as Enter in the field does).
    pub fn submitEdit(vt: *VarTree) void {
        const id = vt.editing orelse return;
        vt.submit(id);
    }

    /// Row `id`'s accessible name.
    pub fn labelOf(vt: *VarTree, id: u64) []const u8 {
        return label(vt, id);
    }

    fn submit(vt: *VarTree, id: u64) void {
        const text = std.mem.trim(u8, vt.edit_buf.slice(), " \t");
        if (id == add_row) {
            if (text.len > 0) vt.hooks.watch_add(vt.hooks.ctx, text);
            return vt.stopEdit();
        }
        if (id >= watch_base) {
            const i: u32 = @intCast(id - watch_base);
            if (text.len == 0) vt.hooks.watch_remove(vt.hooks.ctx, i) else vt.hooks.watch_edit(vt.hooks.ctx, i, text);
            return vt.stopEdit();
        }
        const m = vt.vm() orelse return vt.stopEdit();
        vt.edit_token += 1;
        m.setValue(@enumFromInt(id), text, .{ .ctx = vt, .user = vt.edit_token, .func = onSet });
    }

    /// A set's answer (the model drops pending answers with the session,
    /// and the view outlives the models' callbacks).
    fn onSet(ctx: ?*anyopaque, token: u64, ok: bool, message: ?[]const u8) void {
        const vt = self(ctx.?);
        if (ok) vt.hooks.value_set(vt.hooks.ctx);
        if (token != vt.edit_token) return;
        if (ok) return vt.stopEdit();
        vt.clearErr();
        vt.edit_err = vt.gpa.dupe(u8, message orelse "the debugger refused the value") catch null;
        vt.tv.markDirty();
        vt.hooks.changed(vt.hooks.ctx);
    }

    // -- actions ------------------------------------------------------------------

    fn onClick(ctx: *anyopaque, id: u64) void {
        const vt = self(ctx);
        if (id == add_row) return vt.addExpression();
        if (vt.mode == .watch) if (vt.tv.flat.rowOf(id)) |row| if (vt.tv.flat.rows.items[row].flags.expandable) {
            if (vt.tv.flat.isExpanded(id)) {
                _ = vt.tv.collapseRow(row);
            } else _ = vt.tv.expandRow(row) catch {};
        };
    }

    fn onOpen(ctx: *anyopaque, id: u64) void {
        _ = self(ctx).startEdit(id);
    }

    /// The model node of the active row (a watch row: its result's).
    pub fn activeVar(vt: *const VarTree) ?*const VariablesModel.VarNode {
        const id = vt.tv.active orelse return null;
        const n = vt.varOf(id) orelse return null;
        const i = vt.insp orelse return null;
        return i.vars.node(n);
    }

    /// The active watch's index.
    pub fn activeWatch(vt: *const VarTree) ?u32 {
        const id = vt.tv.active orelse return null;
        if (id == add_row or id < watch_base) return null;
        const i = id - watch_base;
        if (i >= vt.watches().len) return null;
        return @intCast(i);
    }

    /// The active row's value (Copy Value).
    pub fn activeValue(vt: *VarTree) ?[]const u8 {
        const id = vt.tv.active orelse return null;
        const t = vt.rowText(id);
        if (t.value.len == 0 or id == add_row) return null;
        return t.value;
    }

    /// Focuses the tree.
    pub fn focus(vt: *VarTree, w: *Window) void {
        if (!vt.tv.node.isNone() and w.store.valid(vt.tv.node)) w.setFocus(vt.tv.node, true);
    }

    pub fn build(vt: *VarTree, ui: *Ui) void {
        vt.tv.win = ui.window();
        vt.tv.build(ui);
    }
};
