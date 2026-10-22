//! `Ui`: the declarative builder view `build` functions call, and keyed
//! reconciliation against the previous frame's children (ADR 0009).
//!
//! Per opened parent, a cursor walks the old child list. A child whose key
//! matches the cursor is reused in O(1); otherwise a key → node map of the
//! old children is built once (in the frame arena) and consulted, so
//! unchanged, appended and permuted lists all reconcile in O(n). Old
//! children not seen by `close` are freed, subtree first.

const std = @import("std");
const builtin = @import("builtin");
const ids = @import("ids.zig");
const geom = @import("geom.zig");
const widget = @import("widget.zig");
const response_mod = @import("response.zig");
const view_mod = @import("view.zig");
const app_mod = @import("app.zig");
const window_mod = @import("window.zig");
const style_mod = @import("../layout/style.zig");
const theme_mod = @import("../theme/theme.zig");
const box = @import("../widgets/box.zig");
const text_w = @import("../widgets/text.zig");

const NodeId = ids.NodeId;
const Key = ids.Key;
const KindId = ids.KindId;
const Style = style_mod.Style;
const Response = response_mod.Response;
const Window = window_mod.Window;

/// The description of a generic container (`Ui.open`).
pub const BoxDesc = struct {
    style: Style = .{},
    role: widget.Role = .none,
    /// Accessible name (and test-query name).
    label: []const u8 = "",
    /// Test id for `TestApp` queries.
    test_id: []const u8 = "",
    /// Key context active while focus is inside this box (E15 when-clauses).
    key_context: []const u8 = "",
    /// Receives pointer events (clicks report through `Ui.response`).
    hit: bool = false,
    focusable: bool = false,
    disabled: bool = false,
};

const Frame = struct {
    node: NodeId,
    key: Key,
    old_first: NodeId,
    old_cursor: NodeId,
    kids_start: u32,
    ords_start: u32,
    map: ?*std.AutoHashMapUnmanaged(Key, NodeId) = null,
    /// Explicit keys emitted under this parent (safety-checked builds).
    explicit: ?*std.AutoHashMapUnmanaged(Key, void) = null,
    changed: bool = false,
    depth: u16,
    view: u16,
    src: ?std.builtin.SourceLocation = null,
    /// Pushed after a failed allocation so `close` stays balanced.
    throwaway: bool = false,
};

const Ord = struct { tag: u64, n: u32 };

/// Called when two siblings get the same explicit key. The default panics
/// in debug builds and logs otherwise; tests replace it.
pub const DuplicateKeyHook = *const fn (ctx: ?*anyopaque, key: Key) void;

fn defaultDuplicateKey(_: ?*anyopaque, key: Key) void {
    if (builtin.mode == .Debug) std.debug.panic("zg_gui: duplicate key {x} under one parent (use distinct Ui.id values)", .{key});
    std.log.scoped(.zg_gui).err("duplicate key {x} under one parent", .{key});
}

/// The builder. One per window; reused across frames.
pub const Ui = struct {
    win: *Window,
    frames: std.ArrayList(Frame) = .empty,
    kids: std.ArrayList(NodeId) = .empty,
    ords: std.ArrayList(Ord) = .empty,
    pending_id: ?u64 = null,
    pending_with: style_mod.Override = .{},
    cx_storage: app_mod.Context = undefined,
    on_duplicate_key: DuplicateKeyHook = defaultDuplicateKey,
    duplicate_ctx: ?*anyopaque = null,
    /// Nodes emitted during the current frame (debug counter).
    emitted: u32 = 0,
    /// Set when an allocation failed; the frame is retried in full.
    oom: bool = false,

    /// Frees the builder's scratch lists.
    pub fn deinit(ui: *Ui) void {
        const gpa = ui.win.gpa;
        ui.frames.deinit(gpa);
        ui.kids.deinit(gpa);
        ui.ords.deinit(gpa);
    }

    // -- public builder API -------------------------------------------------

    /// Opens a generic container; children follow until `close`.
    pub fn open(ui: *Ui, d: BoxDesc) void {
        const props: box.Box.Props = .{ .role = d.role, .label = d.label, .key_context = d.key_context };
        const node = ui.emit(.box, widget.vtable(.box), &props, d.style, d.test_id);
        if (!node.isNone()) {
            const fl = ui.win.store.flags(node);
            fl.hit_testable = d.hit or d.focusable;
            fl.focusable = d.focusable and !d.disabled;
            fl.disabled = d.disabled;
            fl.clips = d.style.clip;
        }
        ui.push(node, @src());
    }

    /// Closes the innermost `open` or `begin`.
    pub fn close(ui: *Ui) void {
        ui.pop();
    }

    /// Emits a typed leaf widget and returns its interaction response.
    pub fn leaf(ui: *Ui, comptime W: type, props: W.Props) Response {
        const kind = widget.kindOf(W);
        const vt = widget.vtable(kind);
        const st = if (vt.style) |f| f(&props, ui.theme()) else Style{};
        const node = ui.emit(kind, vt, &props, st, "");
        return ui.responseOf(node);
    }

    /// Emits a typed container widget; returns its state. Close with `end`.
    pub fn begin(ui: *Ui, comptime W: type, props: W.Props) *widget.StateOf(W) {
        const kind = widget.kindOf(W);
        const vt = widget.vtable(kind);
        const st = if (vt.style) |f| f(&props, ui.theme()) else Style{};
        const node = ui.emit(kind, vt, &props, st, "");
        ui.push(node, @src());
        return ui.stateOf(W, node);
    }

    /// Closes a `begin`.
    pub fn end(ui: *Ui, comptime W: type) void {
        _ = W;
        ui.pop();
    }

    /// The response of the innermost open container (after `begin`/`open`).
    pub fn response(ui: *Ui) Response {
        const f = ui.top() orelse return .{};
        return ui.responseOf(f.node);
    }

    /// The state of the last `leaf` of type `W` emitted under the current parent.
    pub fn lastState(ui: *Ui, comptime W: type) ?*widget.StateOf(W) {
        if (ui.kids.items.len == 0) return null;
        const f = ui.top() orelse return null;
        if (ui.kids.items.len <= f.kids_start) return null;
        const node = ui.kids.items[ui.kids.items.len - 1];
        if (ui.win.store.hot.items(.kind)[node.index] != widget.kindOf(W)) return null;
        return ui.stateOf(W, node);
    }

    /// Gives the next node an explicit identity (required in loops over data).
    pub fn id(ui: *Ui, explicit: anytype) void {
        ui.pending_id = ids.explicitDiscr(explicit);
    }

    /// Overrides layout fields of the next node's style.
    pub fn with(ui: *Ui, o: style_mod.Override) void {
        ui.pending_with = o;
    }

    /// A run of text (copied into the node).
    pub fn text(ui: *Ui, s: []const u8, p: text_w.TextProps) void {
        const props: text_w.Text.Props = .{ .text = s, .p = p };
        _ = ui.emit(.text, widget.vtable(.text), &props, .{ .shrink = 1 }, "");
    }

    /// Formatted text, formatted into the frame arena.
    pub fn textf(ui: *Ui, comptime fmt: []const u8, args: anytype, p: text_w.TextProps) void {
        const s = std.fmt.allocPrint(ui.arena(), fmt, args) catch {
            ui.oom = true;
            return;
        };
        ui.text(s, p);
    }

    /// Embeds a child view: its subtree is rebuilt only when it is dirty.
    pub fn mount(ui: *Ui, v: view_mod.AnyView) void {
        const props: box.ViewBoundary.Props = .{ .view_name = v.vtable.name };
        const node = ui.emit(.view, widget.vtable(.view), &props, .{ .dir = .column }, "");
        if (node.isNone()) return;
        const w = ui.win;
        const vid = w.viewFor(v, node) catch {
            ui.oom = true;
            return;
        };
        w.store.flags(node).view_root = true;
        const depth: u16 = if (ui.top()) |f| f.depth + 1 else 0;
        w.store.coldOf(node).depth = depth;
        const entry = &w.views.items[vid];
        const fresh = w.store.hot.items(.first_child)[node.index].isNone() and !entry.built_once;
        if (entry.dirty or fresh) ui.buildInto(vid, node);
    }

    /// The frame arena (reset after paint).
    pub fn arena(ui: *Ui) std.mem.Allocator {
        return ui.win.frame_arena.allocator();
    }

    /// The effect context of the view being built.
    pub fn cx(ui: *Ui) *app_mod.Context {
        ui.cx_storage = .{ .app = ui.win.app, .win = ui.win, .view = ui.currentView() };
        return &ui.cx_storage;
    }

    /// The active theme.
    pub fn theme(ui: *const Ui) *const theme_mod.Theme {
        return ui.win.app.theme;
    }

    /// The window being built.
    pub fn window(ui: *Ui) *Window {
        return ui.win;
    }

    // -- frame driver (used by Window) -------------------------------------

    /// Rebuilds view `vid` into its boundary `node` (children only).
    pub fn buildInto(ui: *Ui, vid: u16, node: NodeId) void {
        const w = ui.win;
        const entry = &w.views.items[vid];
        if (entry.built_frame == w.frame_no) {
            // A view is never built twice in one frame.
            std.debug.assert(false);
            return;
        }
        entry.built_frame = w.frame_no;
        entry.built_once = true;
        entry.dirty = false;
        w.clearObservations(vid);
        const depth: u16 = w.store.coldOf(node).depth;
        ui.pushFrame(node, depth, vid, null);
        const level = ui.frames.items.len;
        entry.view.vtable.build(entry.view.ptr, ui);
        if (ui.frames.items.len != level) {
            if (builtin.mode == .Debug) {
                const f = ui.frames.items[ui.frames.items.len - 1];
                if (f.src) |s| std.debug.panic("zg_gui: view {s} left a container open ({s}:{d})", .{ entry.view.vtable.name, s.file, s.line });
            }
            while (ui.frames.items.len > level) ui.pop();
        }
        ui.pop();
        w.stats.views_built += 1;
    }

    /// Builds the window root: the root node holds the root view.
    pub fn buildRoot(ui: *Ui, root: NodeId) void {
        ui.pushFrame(root, 0, 0, null);
        if (ui.win.root_view) |v| {
            ui.with(.{ .grow = 1 });
            ui.mount(v);
        }
        ui.pop();
    }

    // -- reconciliation -----------------------------------------------------

    fn top(ui: *Ui) ?*Frame {
        if (ui.frames.items.len == 0) return null;
        return &ui.frames.items[ui.frames.items.len - 1];
    }

    fn currentView(ui: *Ui) u16 {
        return if (ui.top()) |f| f.view else 0;
    }

    fn pushFrame(ui: *Ui, node: NodeId, depth: u16, vid: u16, src: ?std.builtin.SourceLocation) void {
        const w = ui.win;
        const first = w.store.hot.items(.first_child)[node.index];
        ui.frames.append(w.gpa, .{
            .node = node,
            .key = w.store.hot.items(.key)[node.index],
            .old_first = first,
            .old_cursor = first,
            .kids_start = @intCast(ui.kids.items.len),
            .ords_start = @intCast(ui.ords.items.len),
            .depth = depth,
            .view = vid,
            .src = src,
        }) catch {
            ui.oom = true;
        };
    }

    fn push(ui: *Ui, node: NodeId, src: std.builtin.SourceLocation) void {
        const f = ui.top() orelse return;
        if (node.isNone()) {
            // Allocation failed: open a throwaway frame so close() balances.
            ui.frames.append(ui.win.gpa, .{ .node = f.node, .key = 0, .old_first = .none, .old_cursor = .none, .kids_start = @intCast(ui.kids.items.len), .ords_start = @intCast(ui.ords.items.len), .depth = f.depth + 1, .view = f.view, .throwaway = true }) catch {};
            return;
        }
        ui.win.store.coldOf(node).depth = f.depth + 1;
        ui.pushFrame(node, f.depth + 1, f.view, if (builtin.mode == .Debug) src else null);
    }

    fn pop(ui: *Ui) void {
        const w = ui.win;
        const s = &w.store;
        const f = ui.frames.pop() orelse return;
        defer {
            ui.kids.shrinkRetainingCapacity(f.kids_start);
            ui.ords.shrinkRetainingCapacity(f.ords_start);
        }
        if (f.throwaway) return;
        const kids = ui.kids.items[f.kids_start..];
        const hot = s.hot.slice();
        const next = hot.items(.next_sibling);
        const flags = hot.items(.flags);
        // Free old children that were not emitted this time.
        var changed = f.changed;
        var c = f.old_first;
        while (!c.isNone()) {
            const n = next[c.index];
            if (!flags[c.index].seen) {
                s.freeSubtree(c);
                changed = true;
            }
            c = n;
        }
        // Link the new child list.
        const hot2 = s.hot.slice();
        const next2 = hot2.items(.next_sibling);
        const flags2 = hot2.items(.flags);
        hot2.items(.first_child)[f.node.index] = if (kids.len > 0) kids[0] else .none;
        for (kids, 0..) |k, i| {
            next2[k.index] = if (i + 1 < kids.len) kids[i + 1] else .none;
            flags2[k.index].seen = false;
        }
        if (changed) s.markChildren(f.node);
    }

    fn ordinal(ui: *Ui, f: *Frame, tag: u64) u64 {
        for (ui.ords.items[f.ords_start..]) |*o| {
            if (o.tag == tag) {
                o.n += 1;
                return o.n;
            }
        }
        ui.ords.append(ui.win.gpa, .{ .tag = tag, .n = 0 }) catch {
            ui.oom = true;
        };
        return 0;
    }

    fn checkDuplicate(ui: *Ui, f: *Frame, key: Key) void {
        const a = ui.arena();
        if (f.explicit == null) {
            const m = a.create(std.AutoHashMapUnmanaged(Key, void)) catch return;
            m.* = .empty;
            f.explicit = m;
        }
        const gop = f.explicit.?.getOrPut(a, key) catch return;
        if (gop.found_existing) ui.on_duplicate_key(ui.duplicate_ctx, key);
    }

    fn lookup(ui: *Ui, f: *Frame, key: Key) ?NodeId {
        const s = &ui.win.store;
        if (f.map == null) {
            const a = ui.arena();
            const m = a.create(std.AutoHashMapUnmanaged(Key, NodeId)) catch return null;
            m.* = .empty;
            var c = f.old_first;
            while (!c.isNone()) : (c = s.hot.items(.next_sibling)[c.index]) {
                m.put(a, s.hot.items(.key)[c.index], c) catch return null;
            }
            f.map = m;
        }
        return f.map.?.get(key);
    }

    /// Reconciles one child of the current parent and returns its node
    /// (`none` only when allocation failed).
    fn emit(ui: *Ui, kind: KindId, vt: *const widget.WidgetVTable, props: *const anyopaque, base_style: Style, test_id: []const u8) NodeId {
        const w = ui.win;
        const s = &w.store;
        const f = ui.top() orelse return .none;
        ui.emitted += 1;
        const discr = if (ui.pending_id) |d| d else ui.ordinal(f, vt.tag) | (@as(u64, 1) << 63);
        const explicit = ui.pending_id != null;
        ui.pending_id = null;
        const key = ids.childKey(f.key, vt.tag, discr);
        if (explicit and std.debug.runtime_safety) ui.checkDuplicate(f, key);
        const st = if (ui.pending_with.isEmpty()) base_style else ui.pending_with.apply(base_style);
        ui.pending_with = .{};

        // Fast path: the old child at the cursor.
        var cur = f.old_cursor;
        while (!cur.isNone() and s.hot.items(.flags)[cur.index].seen) cur = s.hot.items(.next_sibling)[cur.index];
        var node: NodeId = .none;
        var fresh = false;
        if (!cur.isNone() and s.hot.items(.key)[cur.index] == key and s.hot.items(.kind)[cur.index] == kind) {
            node = cur;
            f.old_cursor = s.hot.items(.next_sibling)[cur.index];
        } else if (ui.lookup(f, key)) |found| {
            if (s.hot.items(.flags)[found.index].seen) {
                // A duplicate key: reported by `checkDuplicate`; allocate fresh.
            } else if (s.hot.items(.kind)[found.index] == kind) {
                node = found;
                f.changed = true;
            }
        }
        if (node.isNone()) {
            node = s.alloc(key, kind) catch {
                ui.oom = true;
                return .none;
            };
            fresh = true;
            f.changed = true;
        }
        const hot = s.hot.slice();
        const i = node.index;
        hot.items(.parent)[i] = f.node;
        hot.items(.view)[i] = f.view;
        hot.items(.flags)[i].seen = true;
        const cold = &s.cold.items[i];
        cold.depth = f.depth + 1;
        cold.test_id = if (test_id.len > 0) std.hash.Wyhash.hash(0, test_id) else 0;

        if (fresh or !cold.style.eql(&st)) {
            cold.style = st;
            s.markLayout(node);
        }
        const lh, const ph = vt.hashes(props);
        const lchanged = fresh or hot.items(.props_hash)[i] != lh;
        const pchanged = fresh or hot.items(.paint_hash)[i] != ph;
        if (lchanged or pchanged) {
            vt.retain(w.gpa, &cold.blob, props) catch {
                ui.oom = true;
            };
            hot.items(.props_hash)[i] = lh;
            hot.items(.paint_hash)[i] = ph;
            if (lchanged) s.markLayout(node) else s.markPaint(node);
        }
        ui.kids.append(w.gpa, node) catch {
            ui.oom = true;
        };
        return node;
    }

    fn responseOf(ui: *Ui, node: NodeId) Response {
        if (node.isNone()) return .{};
        return ui.win.takeResponse(node);
    }

    fn stateOf(ui: *Ui, comptime W: type, node: NodeId) *widget.StateOf(W) {
        const S = widget.StateOf(W);
        if (@sizeOf(S) == 0 or node.isNone()) return @constCast(&empty_state(S).v);
        return @ptrCast(@alignCast(ui.win.store.hot.items(.state)[node.index].?));
    }

    fn empty_state(comptime S: type) type {
        return struct {
            const v: S = undefined;
        };
    }
};

test {
    std.testing.refAllDecls(@This());
    _ = geom;
}
