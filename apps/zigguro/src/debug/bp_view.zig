//! The Breakpoints view (E07.F07.S01.T03): the active session's exception
//! filters, then function, data and instruction breakpoints, then source
//! breakpoints grouped by file, from zg_dap's `BreakpointManager`.
//!
//! - Every row but a file has a checkbox (a click, or Space on the active
//!   row): a filter turns on or off, a breakpoint is enabled or disabled.
//! - A breakpoint row shows what it does (condition, hit count, log
//!   message) and, while sessions run, whether they verified it: a solid
//!   dot, a hollow one, or a warning with the adapter's message.
//! - F2 (or Enter on a filter) edits in place: a breakpoint's condition,
//!   a logpoint's message, a filter's condition when the adapter takes
//!   one. An empty condition clears it. The function section ends with an
//!   "Add Function Breakpoint…" row while one is being typed.
//! - A click or Enter on a source breakpoint reveals its line.
//! - Node ids stay the same across updates (breakpoint ids, hashes of
//!   filter names and paths), so open files stay open.
//!
//! `update` rebuilds the rows from a snapshot when the breakpoints
//! changed (not per frame). UI thread only.

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
const BreakpointManager = zg_dap.breakpoints.BreakpointManager;
const BpId = BreakpointManager.BpId;
const View = BreakpointManager.View;
const ExceptionFilterState = BreakpointManager.ExceptionFilterState;

pub const add_function_label = "Add Function Breakpoint\u{2026}";

/// What the edit field changes.
pub const Field = enum { condition, log_message, filter_condition, new_function };

/// What the view asks of its owner (the debug service).
pub const Hooks = struct {
    ctx: *anyopaque,
    set_enabled: *const fn (ctx: *anyopaque, id: BpId, on: bool) void,
    /// `filter` of the active session's adapter.
    set_filter: *const fn (ctx: *anyopaque, filter: []const u8, enabled: bool, condition: ?[]const u8) void,
    remove: *const fn (ctx: *anyopaque, id: BpId) void,
    /// Shows a source breakpoint's line.
    reveal: *const fn (ctx: *anyopaque, path: []const u8, line: u32) void,
    /// A condition or log message (null: cleared).
    set_text: *const fn (ctx: *anyopaque, id: BpId, field: Field, text: ?[]const u8) void,
    add_function: *const fn (ctx: *anyopaque, name: []const u8) void,
};

/// What `update` shows.
pub const Snapshot = struct {
    filters: []const ExceptionFilterState = &.{},
    bps: []const View = &.{},
};

const Kind = enum(u8) { filter, function, data, instruction, file, source, add_function };

const Node = struct {
    kind: Kind,
    bp: ?BpId = null,
    enabled: bool = true,
    /// The accessible name.
    label: []const u8,
    name: []const u8,
    detail: []const u8 = "",
    /// Verification: none (no sessions), ok, hollow, warning.
    mark: enum { none, verified, unverified, warning } = .none,
    message: ?[]const u8 = null,
    path: []const u8 = "",
    line: u32 = 0,
    filter: []const u8 = "",
    filter_condition: ?[]const u8 = null,
    supports_condition: bool = false,
    is_log: bool = false,
    children: []const u64 = &.{},
};

const add_function_id: u64 = 0xffff_ffff_ffff_fff0;

pub const BpView = struct {
    gpa: Allocator,
    hooks: Hooks,
    tv: TreeView = undefined,
    arena: std.heap.ArenaAllocator,
    nodes: std.AutoHashMapUnmanaged(u64, Node) = .empty,
    roots: []const u64 = &.{},
    editing: ?u64 = null,
    edit_field: Field = .condition,
    edit_buf: zg_gui.w.TextBuffer,
    focus_edit: bool = false,
    edit_node: zg_gui.core.NodeId = .none,
    /// Kept for `startAddFunction` before the next `update`.
    last: Snapshot = .{},
    /// Files shown before (a new one opens; a closed one stays closed).
    seen_files: std.AutoHashMapUnmanaged(u64, void) = .empty,

    /// `bv` must not move afterwards.
    pub fn init(bv: *BpView, gpa: Allocator, hooks: Hooks) !void {
        bv.* = .{ .gpa = gpa, .hooks = hooks, .arena = .init(gpa), .edit_buf = try .init(gpa, "") };
        errdefer bv.edit_buf.deinit();
        bv.tv = try TreeView.init(gpa, bv.source(), .{
            .label = "Breakpoints",
            .test_id = "debug-breakpoints",
            .expand_on_click = true,
            .on_open = .{ .ctx = bv, .f = onOpen },
            .on_click = .{ .ctx = bv, .f = onClick },
            .on_space = .{ .ctx = bv, .f = onSpace },
        });
    }

    pub fn deinit(bv: *BpView) void {
        bv.tv.deinit();
        bv.nodes.deinit(bv.gpa);
        bv.seen_files.deinit(bv.gpa);
        bv.edit_buf.deinit();
        bv.arena.deinit();
    }

    fn self(ptr: *anyopaque) *BpView {
        return @ptrCast(@alignCast(ptr));
    }

    // -- building the rows --------------------------------------------------------

    /// Rebuilds the rows from `snap` (copied).
    pub fn update(bv: *BpView, snap: Snapshot) Allocator.Error!void {
        bv.nodes.clearRetainingCapacity();
        _ = bv.arena.reset(.retain_capacity);
        const a = bv.arena.allocator();
        var roots: std.ArrayList(u64) = .empty;
        for (snap.filters) |f| {
            const id = hashId(0x1, f.filter);
            const cond = if (f.supports_condition) try dupeOpt(a, f.condition) else null;
            try bv.nodes.put(bv.gpa, id, .{
                .kind = .filter,
                .enabled = f.enabled,
                .label = try a.dupe(u8, f.label),
                .name = try a.dupe(u8, f.label),
                .detail = if (cond) |c| try std.fmt.allocPrint(a, "when {s}", .{c}) else "",
                .filter = try a.dupe(u8, f.filter),
                .filter_condition = cond,
                .supports_condition = f.supports_condition,
            });
            try roots.append(a, id);
        }
        // Non-source kinds, in their order, then the add row.
        inline for (.{ .function, .data, .instruction }) |k| {
            for (snap.bps) |*v| if (v.bp.kind == k) try roots.append(a, try bv.bpNode(a, v));
            if (k == .function and bv.editing == add_function_id) {
                try bv.nodes.put(bv.gpa, add_function_id, .{ .kind = .add_function, .label = add_function_label, .name = add_function_label });
                try roots.append(a, add_function_id);
            }
        }
        // Source breakpoints by file, files in first-seen order, lines
        // ascending.
        var files: std.ArrayList([]const u8) = .empty;
        for (snap.bps) |v| if (v.bp.kind == .source) {
            const p = v.bp.kind.source.path;
            for (files.items) |f| {
                if (std.mem.eql(u8, f, p)) break;
            } else try files.append(a, p);
        };
        for (files.items) |p| {
            var kids: std.ArrayList(*const View) = .empty;
            for (snap.bps) |*v| if (v.bp.kind == .source and std.mem.eql(u8, v.bp.kind.source.path, p)) try kids.append(a, v);
            std.mem.sort(*const View, kids.items, {}, struct {
                fn lt(_: void, x: *const View, y: *const View) bool {
                    return x.bp.kind.source.line < y.bp.kind.source.line;
                }
            }.lt);
            const ids = try a.alloc(u64, kids.items.len);
            for (kids.items, ids) |v, *id| id.* = try bv.bpNode(a, v);
            const id = hashId(0x2, p);
            const base = std.fs.path.basename(p);
            const dir = std.fs.path.dirname(p) orelse "";
            try bv.nodes.put(bv.gpa, id, .{
                .kind = .file,
                .label = try std.fmt.allocPrint(a, "{s}, {d} breakpoint{s}", .{ base, ids.len, if (ids.len == 1) "" else "s" }),
                .name = try a.dupe(u8, base),
                .detail = try a.dupe(u8, dir),
                .path = try a.dupe(u8, p),
                .children = ids,
            });
            try roots.append(a, id);
        }
        bv.roots = roots.items;
        bv.last = snap;
        try bv.tv.reload();
        // Files open the first time they show.
        for (bv.roots) |r| if (bv.nodes.get(r).?.kind == .file) {
            const seen = try bv.seen_files.getOrPut(bv.gpa, r);
            if (seen.found_existing) continue;
            if (bv.tv.flat.rowOf(r)) |row| if (!bv.tv.flat.isExpanded(r)) {
                _ = try bv.tv.expandRow(row);
            };
        };
        if (bv.editing) |e| if (e != add_function_id and !bv.nodes.contains(e)) {
            bv.editing = null;
        };
    }

    fn hashId(tag: u64, s: []const u8) u64 {
        // The top bits keep these apart from breakpoint ids.
        return (std.hash.Wyhash.hash(tag, s) | (@as(u64, 1) << 63)) & ~@as(u64, 0xf);
    }

    fn dupeOpt(a: Allocator, s: ?[]const u8) Allocator.Error!?[]const u8 {
        return if (s) |x| try a.dupe(u8, x) else null;
    }

    fn bpNode(bv: *BpView, a: Allocator, v: *const View) Allocator.Error!u64 {
        const id: u64 = @intFromEnum(v.bp.id);
        var n: Node = .{
            .kind = switch (v.bp.kind) {
                .source => .source,
                .function => .function,
                .data => .data,
                .instruction => .instruction,
            },
            .bp = v.bp.id,
            .enabled = v.bp.enabled,
            .label = "",
            .name = "",
            .message = try dupeOpt(a, v.message),
            .mark = if (!v.sessions) .none else if (v.unsupported) .warning else if (v.verified) .verified else .unverified,
        };
        var summary: std.ArrayList(u8) = .empty;
        const cond: ?[]const u8, const hit: ?[]const u8 = switch (v.bp.kind) {
            inline else => |k| .{ k.condition, k.hit_condition },
        };
        if (cond) |c| try summary.print(a, "when {s}", .{c});
        if (hit) |h| try summary.print(a, "{s}hit {s}", .{ if (summary.items.len > 0) ", " else "", h });
        switch (v.bp.kind) {
            .source => |s| {
                n.name = try std.fmt.allocPrint(a, "line {d}", .{s.line});
                n.path = try a.dupe(u8, s.path);
                n.line = s.line;
                if (s.log_message) |m| {
                    n.is_log = true;
                    try summary.print(a, "{s}log: {s}", .{ if (summary.items.len > 0) ", " else "", m });
                }
            },
            .function => |f| n.name = try a.dupe(u8, f.name),
            .data => |d| n.name = try std.fmt.allocPrint(a, "{s} ({t})", .{ d.description, d.access }),
            .instruction => |ins| n.name = try std.fmt.allocPrint(a, "{s}{s}{d}", .{ ins.reference, if (ins.offset < 0) "-" else "+", @abs(ins.offset) }),
        }
        n.detail = summary.items;
        // "a.zig line 12, when x > 3, disabled, unverified: message"
        var lb: std.ArrayList(u8) = .empty;
        if (n.kind == .source) try lb.print(a, "{s} ", .{std.fs.path.basename(n.path)});
        try lb.appendSlice(a, n.name);
        if (n.detail.len > 0) try lb.print(a, ", {s}", .{n.detail});
        if (!n.enabled) try lb.appendSlice(a, ", disabled");
        switch (n.mark) {
            .none, .verified => {},
            .unverified => try lb.appendSlice(a, ", unverified"),
            .warning => try lb.appendSlice(a, ", not fully supported"),
        }
        if (n.mark != .verified) if (n.message) |m| try lb.print(a, ": {s}", .{m});
        n.label = lb.items;
        try bv.nodes.put(bv.gpa, id, n);
        return id;
    }

    // -- the tree's data --------------------------------------------------------

    fn source(bv: *BpView) TreeSource {
        return .{ .ptr = bv, .vtable = &vtable };
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
        return if (n.children.len == 0) .leaf else .{ .known = @intCast(n.children.len) };
    }

    fn child(ptr: *anyopaque, parent: ?u64, i: u32) u64 {
        const bv = self(ptr);
        const p = parent orelse return bv.roots[i];
        return bv.nodes.get(p).?.children[i];
    }

    fn load(_: *anyopaque, _: u64, _: LoadDone) void {}

    fn label(ptr: *anyopaque, id: u64) []const u8 {
        const n = self(ptr).nodes.get(id) orelse return "";
        return n.label;
    }

    /// Row `id`'s accessible name.
    pub fn labelOf(bv: *BpView, id: u64) []const u8 {
        return label(bv, id);
    }

    fn buildRow(ptr: *anyopaque, ui: *Ui, id: u64, _: RowInfo) void {
        const bv = self(ptr);
        const n = bv.nodes.get(id) orelse return;
        ui.open(.{ .style = .{ .dir = .row, .gap = 6, .align_items = .center, .grow = 1, .shrink = 1 } });
        defer ui.close();
        if (n.kind != .file and n.kind != .add_function) {
            var on = n.enabled;
            if (zg_gui.w.checkbox(ui, "", &on).changed) bv.setEnabled(id, on);
        }
        if (n.kind == .source or n.kind == .function or n.kind == .data or n.kind == .instruction) {
            const glyph: []const u8, const color: zg_gui.theme.Token = switch (n.mark) {
                .none => .{ if (n.is_log) "\u{25C6}" else "\u{25CF}", if (n.enabled) .danger else .fg_muted },
                .verified => .{ if (n.is_log) "\u{25C6}" else "\u{25CF}", if (n.enabled) .danger else .fg_muted },
                .unverified => .{ "\u{25CB}", .fg_muted },
                .warning => .{ "\u{26A0}", .warning },
            };
            ui.text(glyph, .{ .color = color, .wrap = false });
        }
        if (bv.editing == id) return bv.editRow(ui, n);
        ui.text(n.name, .{ .color = if (n.kind == .add_function) .fg_link else if (n.enabled or n.kind == .file) .fg else .fg_muted, .wrap = false });
        if (n.detail.len > 0) ui.text(n.detail, .{ .color = .fg_muted, .wrap = false });
        if (n.mark == .warning or n.mark == .unverified) if (n.message) |m| ui.text(m, .{ .color = if (n.mark == .warning) .warning else .fg_muted, .wrap = false });
    }

    // -- editing ------------------------------------------------------------------

    /// Edits row `id`'s condition (a logpoint's message, a filter's
    /// condition) in place; false when it has none to edit.
    pub fn startEdit(bv: *BpView, id: u64) bool {
        const n = bv.nodes.get(id) orelse return false;
        const field: Field, const initial: []const u8 = switch (n.kind) {
            .filter => if (n.supports_condition) .{ .filter_condition, n.filter_condition orelse "" } else return false,
            .source, .function, .data, .instruction => blk: {
                const v = bv.viewOf(n.bp.?) orelse return false;
                switch (v.bp.kind) {
                    .source => |s| if (s.log_message) |m| break :blk .{ .log_message, m },
                    else => {},
                }
                break :blk .{ .condition, switch (v.bp.kind) {
                    inline else => |k| k.condition orelse "",
                } };
            },
            .file, .add_function => return false,
        };
        return bv.beginEdit(id, field, initial);
    }

    /// Edits the active row (F2).
    pub fn editActive(bv: *BpView) bool {
        const id = bv.tv.active orelse return false;
        return bv.startEdit(id);
    }

    /// Edits row `id`'s `field` (a log message turns a breakpoint into a
    /// logpoint).
    pub fn startEditField(bv: *BpView, id: u64, field: Field) bool {
        const n = bv.nodes.get(id) orelse return false;
        if (n.bp == null) return false;
        const v = bv.viewOf(n.bp.?) orelse return false;
        const initial: []const u8 = switch (field) {
            .log_message => if (v.bp.kind == .source) v.bp.kind.source.log_message orelse "" else return false,
            .condition => switch (v.bp.kind) {
                inline else => |k| k.condition orelse "",
            },
            else => return false,
        };
        return bv.beginEdit(id, field, initial);
    }

    /// The row of breakpoint `id`, if shown.
    pub fn rowId(_: *const BpView, id: BpId) u64 {
        return @intFromEnum(id);
    }

    /// Types a new function breakpoint's name.
    pub fn startAddFunction(bv: *BpView) void {
        _ = bv.beginEdit(add_function_id, .new_function, "");
        bv.update(bv.last) catch {};
        if (bv.tv.flat.rowOf(add_function_id)) |row| bv.tv.reveal(row);
    }

    fn beginEdit(bv: *BpView, id: u64, field: Field, initial: []const u8) bool {
        bv.edit_buf.setText(initial) catch return false;
        bv.editing = id;
        bv.edit_field = field;
        bv.focus_edit = true;
        bv.tv.markDirty();
        return true;
    }

    fn stopEdit(bv: *BpView) void {
        const was_add = bv.editing == add_function_id;
        bv.editing = null;
        if (was_add) bv.update(bv.last) catch {};
        bv.tv.markDirty();
    }

    fn viewOf(bv: *const BpView, id: BpId) ?*const View {
        for (bv.last.bps) |*v| if (v.bp.id == id) return v;
        return null;
    }

    fn editRow(bv: *BpView, ui: *Ui, n: Node) void {
        const a11y = switch (bv.edit_field) {
            .condition => "Breakpoint condition",
            .log_message => "Log message",
            .filter_condition => "Exception filter condition",
            .new_function => "Function name",
        };
        const placeholder = switch (bv.edit_field) {
            .condition => "Break when this is true (empty: always)",
            .log_message => "Message to log; {expression} is evaluated",
            .filter_condition => "Break when this is true (empty: always)",
            .new_function => "Function to break on",
        };
        if (bv.edit_field != .new_function) ui.text(n.name, .{ .color = .fg, .wrap = false });
        ui.open(.{ .style = .{ .grow = 1, .shrink = 1, .basis = .{ .px = 0 } } });
        const r = zg_gui.w.textField(ui, .{ .buffer = &bv.edit_buf, .a11y_label = a11y, .placeholder = placeholder, .font = .mono });
        bv.edit_node = ui.lastNode();
        ui.close();
        if (bv.focus_edit) {
            bv.focus_edit = false;
            ui.window().afterNextFrame(.{ .ctx = bv, .f = focusEdit });
        }
        if (r.cancelled) return bv.stopEdit();
        if (r.submitted) bv.submitEdit();
    }

    fn focusEdit(ctx: *anyopaque, w: *Window) void {
        const bv = self(ctx);
        if (!bv.edit_node.isNone() and w.store.valid(bv.edit_node)) w.setFocus(bv.edit_node, true);
    }

    /// Applies the edit in progress (as Enter in the field does).
    pub fn submitEdit(bv: *BpView) void {
        const id = bv.editing orelse return;
        const text = std.mem.trim(u8, bv.edit_buf.slice(), " \t");
        const opt: ?[]const u8 = if (text.len == 0) null else text;
        const field = bv.edit_field;
        // The hooks rebuild the rows: finish with the edit first.
        const n = bv.nodes.get(id);
        bv.stopEdit();
        switch (field) {
            .new_function => if (opt) |name| bv.hooks.add_function(bv.hooks.ctx, name),
            .filter_condition => if (n) |x| bv.hooks.set_filter(bv.hooks.ctx, x.filter, x.enabled, opt),
            .condition, .log_message => if (n) |x| if (x.bp) |bp| bv.hooks.set_text(bv.hooks.ctx, bp, field, opt),
        }
    }

    // -- actions ------------------------------------------------------------------

    fn setEnabled(bv: *BpView, id: u64, on: bool) void {
        const n = bv.nodes.get(id) orelse return;
        switch (n.kind) {
            .filter => bv.hooks.set_filter(bv.hooks.ctx, n.filter, on, n.filter_condition),
            .source, .function, .data, .instruction => bv.hooks.set_enabled(bv.hooks.ctx, n.bp.?, on),
            .file, .add_function => {},
        }
    }

    /// Space: the active row's checkbox.
    fn onSpace(ctx: *anyopaque, id: u64) void {
        const bv = self(ctx);
        const n = bv.nodes.get(id) orelse return;
        bv.setEnabled(id, !n.enabled);
    }

    fn onClick(ctx: *anyopaque, id: u64) void {
        const bv = self(ctx);
        const n = bv.nodes.get(id) orelse return;
        if (n.kind == .source) bv.hooks.reveal(bv.hooks.ctx, n.path, n.line);
    }

    fn onOpen(ctx: *anyopaque, id: u64) void {
        const bv = self(ctx);
        const n = bv.nodes.get(id) orelse return;
        switch (n.kind) {
            .source => bv.hooks.reveal(bv.hooks.ctx, n.path, n.line),
            .filter => _ = bv.startEdit(id),
            .function, .data, .instruction => _ = bv.startEdit(id),
            .file, .add_function => {},
        }
    }

    /// The breakpoint under the active row.
    pub fn activeBreakpoint(bv: *const BpView) ?BpId {
        const id = bv.tv.active orelse return null;
        const n = bv.nodes.get(id) orelse return null;
        return n.bp;
    }

    /// Focuses the tree.
    pub fn focus(bv: *BpView, w: *Window) void {
        if (!bv.tv.node.isNone() and w.store.valid(bv.tv.node)) w.setFocus(bv.tv.node, true);
    }

    pub fn build(bv: *BpView, ui: *Ui) void {
        bv.tv.win = ui.window();
        bv.tv.build(ui);
    }
};

const testing = std.testing;

const TestHooks = struct {
    enabled: ?struct { id: BpId, on: bool } = null,
    filter: ?struct { name: []const u8, on: bool, cond: ?[]const u8 } = null,
    revealed: ?u32 = null,
    text: ?struct { id: BpId, field: Field, text: ?[]const u8 } = null,
    added: ?[]const u8 = null,
    arena: std.heap.ArenaAllocator,

    fn setEnabled(ctx: *anyopaque, id: BpId, on: bool) void {
        const h: *TestHooks = @ptrCast(@alignCast(ctx));
        h.enabled = .{ .id = id, .on = on };
    }
    fn setFilter(ctx: *anyopaque, f: []const u8, on: bool, cond: ?[]const u8) void {
        const h: *TestHooks = @ptrCast(@alignCast(ctx));
        const a = h.arena.allocator();
        h.filter = .{ .name = a.dupe(u8, f) catch "", .on = on, .cond = if (cond) |c| a.dupe(u8, c) catch null else null };
    }
    fn remove(_: *anyopaque, _: BpId) void {}
    fn reveal(ctx: *anyopaque, _: []const u8, line: u32) void {
        const h: *TestHooks = @ptrCast(@alignCast(ctx));
        h.revealed = line;
    }
    fn setText(ctx: *anyopaque, id: BpId, field: Field, text: ?[]const u8) void {
        const h: *TestHooks = @ptrCast(@alignCast(ctx));
        h.text = .{ .id = id, .field = field, .text = if (text) |t| h.arena.allocator().dupe(u8, t) catch null else null };
    }
    fn addFunction(ctx: *anyopaque, name: []const u8) void {
        const h: *TestHooks = @ptrCast(@alignCast(ctx));
        h.added = h.arena.allocator().dupe(u8, name) catch null;
    }
    fn hooks(h: *TestHooks) Hooks {
        return .{ .ctx = h, .set_enabled = setEnabled, .set_filter = setFilter, .remove = remove, .reveal = reveal, .set_text = setText, .add_function = addFunction };
    }
};

fn rowLabels(bv: *BpView, a: Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (bv.tv.flat.rows.items) |r| try out.print(a, "{d}:{s}|", .{ r.depth, bv.labelOf(r.node) });
    return out.items;
}

fn srcView(id: u32, path: []const u8, line: u32, extra: struct { enabled: bool = true, condition: ?[]const u8 = null, log: ?[]const u8 = null, sessions: bool = false, verified: bool = false, unsupported: bool = false, message: ?[]const u8 = null }) View {
    return .{
        .bp = .{ .id = @enumFromInt(id), .enabled = extra.enabled, .kind = .{ .source = .{ .path = path, .line = line, .condition = extra.condition, .log_message = extra.log } } },
        .verified = extra.verified,
        .unsupported = extra.unsupported,
        .sessions = extra.sessions,
        .message = extra.message,
        .adopted = false,
    };
}

test "ui: breakpoints view toggles exception filters and conditions" {
    var h: TestHooks = .{ .arena = .init(testing.allocator) };
    defer h.arena.deinit();
    var bv: BpView = undefined;
    try bv.init(testing.allocator, h.hooks());
    defer bv.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const filters = [_]ExceptionFilterState{
        .{ .filter = "cpp_throw", .label = "C++: on throw", .enabled = false, .supports_condition = true },
        .{ .filter = "cpp_catch", .label = "C++: on catch", .enabled = true },
    };
    const bps = [_]View{
        srcView(3, "/w/src/b.zig", 30, .{}),
        srcView(1, "/w/src/a.zig", 12, .{ .condition = "x > 3" }),
        srcView(2, "/w/src/a.zig", 4, .{ .enabled = false }),
        .{ .bp = .{ .id = @enumFromInt(4), .kind = .{ .function = .{ .name = "main" } } }, .verified = false, .unsupported = false, .sessions = false, .message = null, .adopted = false },
    };
    try bv.update(.{ .filters = &filters, .bps = &bps });
    // Filters, functions, then files (open) with their lines in order.
    try testing.expectEqualStrings(
        "0:C++: on throw|0:C++: on catch|0:main|0:b.zig, 1 breakpoint|1:b.zig line 30|" ++
            "0:a.zig, 2 breakpoints|1:a.zig line 4, disabled|1:a.zig line 12, when x > 3|",
        try rowLabels(&bv, a),
    );
    // Space toggles the active row's checkbox: a filter, then a breakpoint.
    const K = zg_gui.input.event.KeyPress;
    _ = try bv.tv.onKey(K{ .key = .space });
    try testing.expectEqualStrings("cpp_throw", h.filter.?.name);
    try testing.expect(h.filter.?.on);
    _ = try bv.tv.onKey(K{ .key = .end });
    _ = try bv.tv.onKey(K{ .key = .space });
    try testing.expectEqual(@as(BpId, @enumFromInt(1)), h.enabled.?.id);
    try testing.expect(!h.enabled.?.on);
    // A filter that takes a condition edits it in place (Enter); one that
    // does not, does not.
    try testing.expect(bv.startEdit(bv.tv.flat.rows.items[0].node));
    try bv.edit_buf.setText("e.what() == 'oops'");
    bv.submitEdit();
    try testing.expectEqualStrings("e.what() == 'oops'", h.filter.?.cond.?);
    try testing.expect(!h.filter.?.on);
    try testing.expect(!bv.startEdit(bv.tv.flat.rows.items[1].node));
    // F2 on a breakpoint: its condition; emptied, it clears.
    try testing.expect(bv.editActive());
    try testing.expectEqualStrings("x > 3", bv.edit_buf.slice());
    try bv.edit_buf.setText("  ");
    bv.submitEdit();
    try testing.expectEqual(Field.condition, h.text.?.field);
    try testing.expect(h.text.?.text == null);
    // A click on a source breakpoint reveals its line.
    BpView.onClick(&bv, bv.tv.flat.rows.items[4].node);
    try testing.expectEqual(@as(?u32, 30), h.revealed);
    // Add Function Breakpoint: a row to type into, then the hook.
    bv.startAddFunction();
    try testing.expect(std.mem.indexOf(u8, try rowLabels(&bv, a), add_function_label) != null);
    try bv.edit_buf.setText("std.debug.panic");
    bv.submitEdit();
    try testing.expectEqualStrings("std.debug.panic", h.added.?);
    try testing.expect(std.mem.indexOf(u8, try rowLabels(&bv, a), add_function_label) == null);
}

test "ui: breakpoints verification icons and tooltips" {
    var h: TestHooks = .{ .arena = .init(testing.allocator) };
    defer h.arena.deinit();
    var bv: BpView = undefined;
    try bv.init(testing.allocator, h.hooks());
    defer bv.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const bps = [_]View{
        srcView(1, "/w/a.zig", 1, .{ .sessions = true, .verified = true }),
        srcView(2, "/w/a.zig", 2, .{ .sessions = true, .message = "No code at this line" }),
        srcView(3, "/w/a.zig", 3, .{ .sessions = true, .verified = true, .unsupported = true, .message = "Conditions are not supported" }),
        srcView(4, "/w/a.zig", 4, .{ .log = "x is {x}" }),
    };
    try bv.update(.{ .bps = &bps });
    try testing.expectEqualStrings(
        "0:a.zig, 4 breakpoints|1:a.zig line 1|1:a.zig line 2, unverified: No code at this line|" ++
            "1:a.zig line 3, not fully supported: Conditions are not supported|1:a.zig line 4, log: x is {x}|",
        try rowLabels(&bv, arena.allocator()),
    );
    const n = bv.nodes.get(bv.tv.flat.rows.items[4].node).?;
    try testing.expect(n.is_log);
    // A logpoint's F2 edits its message.
    try testing.expect(bv.startEdit(bv.tv.flat.rows.items[4].node));
    try testing.expectEqual(Field.log_message, bv.edit_field);
    try testing.expectEqualStrings("x is {x}", bv.edit_buf.slice());
}
