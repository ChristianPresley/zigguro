//! Document mode's outline (E13.F04.S01.T02): the document's sections as
//! an indented list with word counts and a dot on sections with pending
//! agent changes. Clicking (or Enter) goes to a section; dragging a
//! heading, or Alt+Up/Down, moves the section with its subsections as one
//! ordinary edit (one undo step).

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_agents = @import("zg_agents");

const Allocator = std.mem.Allocator;
const Ui = zg_gui.Ui;
const NodeId = zg_gui.core.ids.NodeId;
const Vec2 = zg_gui.core.geom.Vec2;
const widget = zg_gui.core.widget;
const ev_mod = zg_gui.input.event;
const scroll = zg_gui.w.scroll;
const sections = zg_agents.docs.sections;
const Section = sections.Section;

pub const row_h: f32 = 26;
const drag_threshold: f32 = 5;

pub const Ports = struct {
    /// Puts the editor's cursor at a byte offset.
    navigate: struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque, offset: u32) void },
    /// Applies an edit as the person's own (the editor's undo stack).
    edit: struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque, m: sections.Move) void },
    /// Whether a range has pending agent changes.
    pending: ?struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque, r: sections.Range) bool } = null,
};

pub const OutlineView = struct {
    gpa: Allocator,
    ports: Ports,
    /// The outline and text it was built from (owned).
    arena: std.heap.ArenaAllocator,
    all: []const Section = &.{},
    text: []const u8 = "",
    version: ?u64 = null,
    /// The keyboard selection.
    selected: ?u32 = null,
    /// The section holding the editor's cursor.
    current: ?u32 = null,
    drag: ?struct { from: u32, pos: Vec2 } = null,
    /// Row nodes of the last frame (drop targets).
    rows: std.ArrayList(struct { i: u32, node: NodeId }) = .empty,
    node: NodeId = .none,

    pub fn init(gpa: Allocator, ports: Ports) OutlineView {
        return .{ .gpa = gpa, .ports = ports, .arena = .init(gpa) };
    }

    pub fn deinit(v: *OutlineView) void {
        v.arena.deinit();
        v.rows.deinit(v.gpa);
    }

    /// Takes the document's text and outline when its version changed.
    pub fn update(v: *OutlineView, text: []const u8, version: u64, cursor: ?u32) !void {
        if (v.version != version) {
            _ = v.arena.reset(.retain_capacity);
            const a = v.arena.allocator();
            v.text = try a.dupe(u8, text);
            v.all = try sections.outline(a, v.text);
            v.version = version;
            if (v.selected) |s| if (s >= v.all.len) {
                v.selected = null;
            };
        }
        v.current = if (cursor) |c| sections.sectionAt(v.all, c) else null;
    }

    pub fn go(v: *OutlineView, i: u32) void {
        if (i >= v.all.len) return;
        v.selected = i;
        v.ports.navigate.f(v.ports.navigate.ctx, v.all[i].range.start);
    }

    /// Moves section `from` before section `before` (null: the end).
    pub fn move(v: *OutlineView, from: u32, before: ?u32) void {
        var scratch: std.heap.ArenaAllocator = .init(v.gpa);
        defer scratch.deinit();
        const m = sections.moveSection(scratch.allocator(), v.text, v.all, from, before) catch return orelse return;
        v.ports.edit.f(v.ports.edit.ctx, m);
    }

    /// Alt+Up/Down: past the previous or next sibling.
    pub fn moveBy(v: *OutlineView, i: u32, dir: i2) void {
        const s = v.all[i];
        const sibs = if (s.parent) |p| v.all[p].children else roots: {
            var list: std.ArrayList(u32) = .empty;
            for (v.all, 0..) |x, k| if (x.parent == null) list.append(v.arena.allocator(), @intCast(k)) catch return;
            break :roots list.items;
        };
        const k = std.mem.indexOfScalar(u32, sibs, i) orelse return;
        if (dir < 0) {
            if (k == 0) return;
            v.move(i, sibs[k - 1]);
        } else {
            if (k + 1 >= sibs.len) return;
            // Before the sibling after next, or after the last one.
            const after = v.all[sibs[k + 1]];
            v.move(i, nextStart(v.all, after.range.end));
        }
    }

    fn nextStart(all: []const Section, at: u32) ?u32 {
        for (all, 0..) |s, k| if (s.range.start == at) return @intCast(k);
        return null;
    }

    fn onKey(v: *OutlineView, k: ev_mod.KeyPress) bool {
        if (k.action == .release or v.all.len == 0 or k.mods.ctrl or k.mods.super) return false;
        const sel = v.selected orelse v.current orelse 0;
        if (k.mods.alt) {
            switch (k.key) {
                .arrow_up => v.moveBy(sel, -1),
                .arrow_down => v.moveBy(sel, 1),
                else => return false,
            }
            return true;
        }
        switch (k.key) {
            .arrow_up => v.selected = sel -| 1,
            .arrow_down => v.selected = @min(sel + 1, @as(u32, @intCast(v.all.len - 1))),
            .home => v.selected = 0,
            .end => v.selected = @intCast(v.all.len - 1),
            .enter, .numpad_enter => v.go(sel),
            else => return false,
        }
        return true;
    }

    /// The drop target under `pos`: before row i (or the end).
    fn dropAt(v: *const OutlineView, ec: *ev_mod.EventCx, pos: Vec2) ?u32 {
        for (v.rows.items) |r| {
            const rect = ec.rectOf(r.node);
            if (pos.y < rect.y + rect.h / 2) return r.i;
        }
        return null;
    }

    fn pendingIn(v: *const OutlineView, r: sections.Range) bool {
        const p = v.ports.pending orelse return false;
        return p.f(p.ctx, r);
    }

    pub fn build(v: *OutlineView, ui: *Ui) void {
        v.rows.clearRetainingCapacity();
        _ = ui.begin(OutlineBox, .{ .v = v });
        v.node = ui.current();
        if (v.all.len == 0) {
            ui.text("No headings yet. Start a line with # to add one.", .{ .color = .fg_muted });
        } else {
            _ = scroll.virtualList(ui, .{ .count = v.all.len, .row_h = row_h, .test_id = "doc-outline" }, v, struct {
                fn row(ov: *OutlineView, u: *Ui, i: usize) void {
                    ov.buildRow(u, @intCast(i));
                }
            }.row);
        }
        ui.end(OutlineBox);
    }

    fn buildRow(v: *OutlineView, ui: *Ui, i: u32) void {
        const s = v.all[i];
        const pending = v.pendingIn(s.range);
        const label = std.fmt.allocPrint(ui.arena(), "{s}{s}, {d} words{s}", .{ if (s.title.len > 0) s.title else "(untitled)", "", s.words, if (pending) ", changes pending" else "" }) catch "";
        ui.id(@as(u64, i) + 1);
        _ = ui.begin(RowBox, .{
            .v = v,
            .i = i,
            .label = label,
            .indent = @as(f32, @floatFromInt(s.level - 1)) * 12,
            .selected = v.selected != null and v.selected.? == i,
            .current = v.current != null and v.current.? == i,
            .dragging = v.drag != null and v.drag.?.from == i,
        });
        v.rows.append(v.gpa, .{ .i = i, .node = ui.current() }) catch {};
        ui.text(if (s.title.len > 0) s.title else "(untitled)", .{ .wrap = false, .style = .{ .weight = if (s.level <= 2) 600 else 400 } });
        ui.open(.{ .style = .{ .grow = 1 } });
        ui.close();
        if (pending) ui.text("●", .{ .color = .accent, .wrap = false });
        ui.textf("{d}", .{s.words}, .{ .color = .fg_muted, .wrap = false });
        ui.end(RowBox);
    }
};

const OutlineBox = struct {
    pub const name = "doc_outline";
    pub const focusable = true;
    pub const Props = struct { v: *OutlineView };

    pub fn style(_: *const Props, _: *const zg_gui.theme.Theme) zg_gui.Style {
        return .{ .dir = .column, .grow = 1 };
    }

    pub fn event(ec: *ev_mod.EventCx, props: *const Props, _: *widget.NoState, ev: *const ev_mod.InputEvent) bool {
        if (ec.phase == .capture) return false;
        const k = switch (ev.*) {
            .key => |k| k,
            else => return false,
        };
        if (!props.v.onKey(k)) return false;
        ec.respond(.{ .changed = true });
        return true;
    }

    pub fn a11y(props: *const Props, _: *widget.NoState) widget.A11y {
        return .{ .role = .tree, .name = "Outline", .row_count = props.v.all.len };
    }
};

const RowBox = struct {
    pub const name = "doc_outline_row";
    pub const Props = struct {
        v: *OutlineView,
        i: u32,
        label: []const u8,
        indent: f32,
        selected: bool,
        current: bool,
        dragging: bool,
    };
    pub const State = struct { press: ?Vec2 = null };

    pub fn style(props: *const Props, _: *const zg_gui.theme.Theme) zg_gui.Style {
        return .{
            .dir = .row,
            .gap = 6,
            .align_items = .center,
            .grow = 1,
            .padding = .{ .l = 6 + props.indent, .r = 6, .t = 3, .b = 3 },
            .bg = if (props.selected) .{ .token = .selection_bg } else if (props.current) .{ .token = .bg_elevated } else .none,
            .border = if (props.dragging) .{ .token = .focus_ring } else .none,
            .border_w = if (props.dragging) 1 else 0,
        };
    }

    pub fn event(ec: *ev_mod.EventCx, props: *const Props, st: *State, ev: *const ev_mod.InputEvent) bool {
        if (ec.phase == .capture) return false;
        const v = props.v;
        switch (ev.*) {
            .pointer_down => |p| {
                if (p.button != .left) return false;
                st.press = p.pos;
                ec.capture();
                return true;
            },
            .pointer_move => |p| {
                const start = st.press orelse return false;
                if (v.drag == null) {
                    if (@abs(p.pos.x - start.x) + @abs(p.pos.y - start.y) < drag_threshold) return true;
                    v.drag = .{ .from = props.i, .pos = p.pos };
                } else v.drag.?.pos = p.pos;
                ec.respond(.{ .changed = true });
                return true;
            },
            .pointer_up => |p| {
                if (st.press == null) return false;
                st.press = null;
                ec.releaseCapture();
                if (v.drag) |d| {
                    v.drag = null;
                    v.move(d.from, v.dropAt(ec, p.pos));
                } else v.go(props.i);
                ec.respond(.{ .changed = true });
                return true;
            },
            else => return false,
        }
    }

    pub fn a11y(props: *const Props, _: *State) widget.A11y {
        return .{ .role = .treeitem, .name = props.label, .selected = props.selected };
    }
};
