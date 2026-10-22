//! The layout engine: CSS flexbox (§9 subset), stack and absolute
//! positioning over the `NodeStore`, with per-node caches keyed by the
//! layout inputs and dirty propagation through `subtree_dirty`.
//!
//! Sizes flow down as optional *known* sizes (a definite size the parent
//! imposes) and optional *available* sizes (the space content may use;
//! null means max-content). Every node's `rect` is written relative to its
//! parent's border box.

const std = @import("std");
const geom = @import("../core/geom.zig");
const ids = @import("../core/ids.zig");
const node_store = @import("../core/node_store.zig");
const widget = @import("../core/widget.zig");
const style_mod = @import("style.zig");
const measure_mod = @import("measure.zig");

const NodeId = ids.NodeId;
const NodeStore = node_store.NodeStore;
const Style = style_mod.Style;
const Size = geom.Size;
const Insets = geom.Insets;

/// Counters for one layout run.
pub const LayoutStats = struct {
    visited: u32 = 0,
    measured: u32 = 0,
    cache_hits: u32 = 0,
};

const none: f32 = -1;

fn enc(v: ?f32) f32 {
    return v orelse none;
}

const Item = struct {
    id: NodeId,
    base: f32,
    hyp: f32,
    min: f32,
    max: f32,
    target: f32,
    frozen: bool,
    cross: f32,
    /// Margins along the main axis (start, end) and cross axis (start, end).
    ms: f32,
    me: f32,
    cs: f32,
    ce: f32,
    grow: f32,
    shrink: f32,
    @"align": style_mod.Align,
    line: u32,
    main_pos: f32 = 0,
};

const LineInfo = struct { start: u32, end: u32, cross: f32 = 0, pos: f32 = 0 };

/// Lays out a node tree. One engine per window; scratch buffers are kept
/// between runs so steady-state layouts do not allocate.
pub const Engine = struct {
    gpa: std.mem.Allocator,
    store: *NodeStore,
    mc: measure_mod.MeasureCx,
    stats: LayoutStats = .{},
    items: std.ArrayList(Item) = .empty,
    lines: std.ArrayList(LineInfo) = .empty,
    oom: bool = false,

    /// Frees the scratch buffers.
    pub fn deinit(e: *Engine) void {
        e.items.deinit(e.gpa);
        e.lines.deinit(e.gpa);
    }

    /// Lays out the tree under `root` into a viewport of `size`.
    pub fn run(e: *Engine, root: NodeId, size: Size) void {
        e.stats = .{};
        e.mc.calls = 0;
        _ = e.layoutNode(root, size.w, size.h, size.w, size.h);
        const r = &e.store.hot.items(.rect)[root.index];
        r[0] = 0;
        r[1] = 0;
        e.stats.measured = e.mc.calls;
    }

    fn edges(st: *const Style) Insets {
        return .{
            .l = st.padding.l + st.border_w,
            .t = st.padding.t + st.border_w,
            .r = st.padding.r + st.border_w,
            .b = st.padding.b + st.border_w,
        };
    }

    fn clamp(v: f32, lo: f32, hi: f32) f32 {
        return @max(lo, @min(v, hi));
    }

    fn sane(v: f32) f32 {
        return if (std.math.isFinite(v)) v else 0;
    }

    /// Lays out `id` and returns its border-box size.
    pub fn layoutNode(e: *Engine, id: NodeId, known_w: ?f32, known_h: ?f32, avail_w: ?f32, avail_h: ?f32) Size {
        const s = e.store;
        const i = id.index;
        e.stats.visited += 1;
        const fl = &s.hot.items(.flags)[i];
        const cold = &s.cold.items[i];
        const st = &cold.style;
        if (st.display == .none) {
            fl.hidden = true;
            s.hot.items(.rect)[i] = .{ 0, 0, 0, 0 };
            fl.layout_dirty = false;
            fl.subtree_dirty = false;
            return .{};
        }
        fl.hidden = false;
        const c = &cold.cache;
        if (!fl.layout_dirty and !fl.subtree_dirty and c.valid and c.known_w == enc(known_w) and c.known_h == enc(known_h) and
            c.avail_w == enc(avail_w) and c.avail_h == enc(avail_h))
        {
            e.stats.cache_hits += 1;
            return c.size;
        }

        const pad = edges(st);
        var w: ?f32 = known_w orelse st.w.resolve(avail_w);
        var h: ?f32 = known_h orelse st.h.resolve(avail_h);
        if (st.aspect) |ar| if (ar > 0) {
            if (w != null and h == null) h = w.? / ar else if (h != null and w == null) w = h.? * ar;
        };
        if (w) |v| w = clamp(sane(v), st.min_w, st.max_w);
        if (h) |v| h = clamp(sane(v), st.min_h, st.max_h);

        const inner_w: ?f32 = if (w) |v| @max(0, v - pad.horizontal()) else null;
        const inner_h: ?f32 = if (h) |v| @max(0, v - pad.vertical()) else null;
        const avail_inner_w: ?f32 = inner_w orelse if (avail_w) |a| @max(0, @min(a, st.max_w) - pad.horizontal()) else null;
        const avail_inner_h: ?f32 = inner_h orelse if (avail_h) |a| @max(0, @min(a, st.max_h) - pad.vertical()) else null;

        var content = e.layoutContent(id, inner_w, inner_h, avail_inner_w, avail_inner_h);
        // An automatic width is fit-content: never wider than the space
        // available (the content is laid out again below if it shrank).
        const fit_w = if (avail_w) |a| @min(content.w + pad.horizontal(), @max(a, 0)) else content.w + pad.horizontal();
        var out: Size = .{
            .w = w orelse clamp(fit_w, st.min_w, st.max_w),
            .h = h orelse clamp(content.h + pad.vertical(), st.min_h, st.max_h),
        };
        // Clamping (min/max, fit-content) changed an automatic size: lay the
        // children out again with that axis definite; the other axis stays
        // automatic and is re-derived from the new content.
        const has_children = !s.hot.items(.first_child)[i].isNone();
        const w_clamped = w == null and out.w != content.w + pad.horizontal();
        const h_clamped = h == null and out.h != content.h + pad.vertical();
        if (has_children and (w_clamped or h_clamped)) {
            const iw: ?f32 = if (w != null or w_clamped) @max(0, out.w - pad.horizontal()) else null;
            const ih: ?f32 = if (h != null or h_clamped) @max(0, out.h - pad.vertical()) else null;
            content = e.layoutContent(id, iw, ih, iw orelse avail_inner_w, ih orelse avail_inner_h);
            if (h == null and !h_clamped) out.h = clamp(content.h + pad.vertical(), st.min_h, st.max_h);
            if (w == null and !w_clamped) out.w = clamp(content.w + pad.horizontal(), st.min_w, st.max_w);
        }
        out.w = sane(out.w);
        out.h = sane(out.h);
        e.layoutAbsolute(id, out);

        const r = &s.hot.items(.rect)[i];
        if (r[2] != out.w or r[3] != out.h) s.hot.items(.flags)[i].paint_dirty = true;
        r[2] = out.w;
        r[3] = out.h;
        const fl2 = &s.hot.items(.flags)[i];
        fl2.layout_dirty = false;
        fl2.subtree_dirty = false;
        s.cold.items[i].cache = .{
            .valid = true,
            .known_w = enc(known_w),
            .known_h = enc(known_h),
            .avail_w = enc(avail_w),
            .avail_h = enc(avail_h),
            .size = out,
        };
        return out;
    }

    /// The content-box size of `id`'s children (or its measured content).
    fn layoutContent(e: *Engine, id: NodeId, inner_w: ?f32, inner_h: ?f32, avail_w: ?f32, avail_h: ?f32) Size {
        const s = e.store;
        const i = id.index;
        const first = s.hot.items(.first_child)[i];
        const vt = widget.vtable(s.hot.items(.kind)[i]);
        if (first.isNone()) {
            if (vt.measure) |m| {
                const props = s.props(id) orelse return .{};
                e.mc.calls += 1;
                const state: *anyopaque = s.hot.items(.state)[i] orelse @ptrCast(@constCast(&dummy_state));
                const sz = m(&e.mc, props, state, inner_w orelse avail_w);
                return .{ .w = sane(sz.w), .h = sane(sz.h) };
            }
            return .{};
        }
        return switch (s.cold.items[i].style.display) {
            .flex => e.flex(id, inner_w, inner_h, avail_w, avail_h),
            .stack => e.stack(id, inner_w, inner_h, avail_w, avail_h),
            .none => .{},
        };
    }

    var dummy_state: u8 = 0;

    fn setPos(e: *Engine, id: NodeId, x: f32, y: f32) void {
        const r = &e.store.hot.items(.rect)[id.index];
        r[0] = x;
        r[1] = y;
    }

    fn mainOf(row: bool, sz: Size) f32 {
        return if (row) sz.w else sz.h;
    }

    fn crossOf(row: bool, sz: Size) f32 {
        return if (row) sz.h else sz.w;
    }

    fn flex(e: *Engine, id: NodeId, inner_w: ?f32, inner_h: ?f32, avail_w: ?f32, avail_h: ?f32) Size {
        const s = e.store;
        const st = s.cold.items[id.index].style;
        const pad = edges(&st);
        const row = st.isRow();
        const inner_main = if (row) inner_w else inner_h;
        const inner_cross = if (row) inner_h else inner_w;
        const avail_cross = inner_cross orelse (if (row) avail_h else avail_w);
        const start = e.items.items.len;
        defer e.items.shrinkRetainingCapacity(start);
        const lines_start = e.lines.items.len;
        defer e.lines.shrinkRetainingCapacity(lines_start);

        // §9.2 steps 1–3: flex items, base sizes and hypothetical main sizes.
        var it = s.children(id);
        while (it.next()) |c| {
            const cst = s.cold.items[c.index].style;
            if (cst.display == .none) {
                _ = e.layoutNode(c, 0, 0, 0, 0);
                continue;
            }
            if (cst.position == .absolute) continue;
            const m = cst.margin;
            const al = cst.align_self orelse st.align_items;
            const cross_dim = if (row) cst.h else cst.w;
            const stretch_cross: ?f32 = if (al == .stretch and cross_dim == .auto and inner_cross != null and !st.wrap)
                @max(0, inner_cross.? - (if (row) m.vertical() else m.horizontal()))
            else
                null;
            var basis: ?f32 = cst.basis.resolve(inner_main) orelse (if (row) cst.w else cst.h).resolve(inner_main);
            if (basis == null) {
                const cross_avail: ?f32 = if (avail_cross) |a| @max(0, a - (if (row) m.vertical() else m.horizontal())) else null;
                const sz = if (row)
                    e.layoutNode(c, null, stretch_cross, null, cross_avail)
                else
                    e.layoutNode(c, stretch_cross, null, cross_avail, null);
                basis = mainOf(row, sz);
            }
            const mn = if (row) cst.min_w else cst.min_h;
            const mx = if (row) cst.max_w else cst.max_h;
            e.items.append(e.gpa, .{
                .id = c,
                .base = sane(basis.?),
                .hyp = clamp(sane(basis.?), mn, mx),
                .min = mn,
                .max = mx,
                .target = 0,
                .frozen = false,
                .cross = 0,
                .ms = if (row) m.l else m.t,
                .me = if (row) m.r else m.b,
                .cs = if (row) m.t else m.l,
                .ce = if (row) m.b else m.r,
                .grow = @max(0, cst.grow),
                .shrink = @max(0, cst.shrink),
                .@"align" = al,
                .line = 0,
            }) catch {
                e.oom = true;
                return .{};
            };
        }
        const items = e.items.items[start..];

        // §9.3: collect into lines.
        {
            var line_start: u32 = 0;
            var used: f32 = 0;
            for (items, 0..) |*item, k| {
                const outer = item.hyp + item.ms + item.me;
                const extra = if (k > line_start) st.gap else 0;
                if (st.wrap and inner_main != null and k > line_start and used + extra + outer > inner_main.? + 0.001) {
                    e.lines.append(e.gpa, .{ .start = line_start, .end = @intCast(k) }) catch {
                        e.oom = true;
                    };
                    line_start = @intCast(k);
                    used = outer;
                } else used += extra + outer;
            }
            e.lines.append(e.gpa, .{ .start = line_start, .end = @intCast(items.len) }) catch {
                e.oom = true;
            };
        }
        const lines = e.lines.items[lines_start..];

        // §9.7: resolve flexible lengths per line.
        for (lines, 0..) |ln, li| {
            const li_items = items[ln.start..ln.end];
            for (li_items) |*item| item.line = @intCast(li);
            resolveFlexible(li_items, inner_main, st.gap);
        }

        // §9.4 steps 6–8: cross sizes (text wraps here, at the final main
        // size). Nested layouts append to the scratch lists, so items and
        // lines are re-fetched by index after every `layoutNode`.
        const n_lines = lines.len;
        for (0..n_lines) |li| {
            const ln = e.lines.items[lines_start + li];
            var cross: f32 = 0;
            var k = ln.start;
            while (k < ln.end) : (k += 1) {
                const item = e.items.items[start + k];
                const cst = s.cold.items[item.id.index].style;
                const cross_dim = if (row) cst.h else cst.w;
                const cm = item.cs + item.ce;
                var kc: ?f32 = cross_dim.resolve(inner_cross);
                if (item.@"align" == .stretch and cross_dim == .auto and inner_cross != null and n_lines == 1)
                    kc = @max(0, inner_cross.? - cm);
                const cross_avail: ?f32 = if (avail_cross) |a| @max(0, a - cm) else null;
                const sz = if (row)
                    e.layoutNode(item.id, item.target, kc, item.target, cross_avail)
                else
                    e.layoutNode(item.id, kc, item.target, cross_avail, item.target);
                e.items.items[start + k].cross = crossOf(row, sz);
                cross = @max(cross, crossOf(row, sz) + cm);
            }
            e.lines.items[lines_start + li].cross = cross;
        }
        if (n_lines == 1 and inner_cross != null) e.lines.items[lines_start].cross = inner_cross.?;

        // Stretch items whose line cross size became known only now.
        for (0..n_lines) |li| {
            const ln = e.lines.items[lines_start + li];
            var k = ln.start;
            while (k < ln.end) : (k += 1) {
                const item = e.items.items[start + k];
                const cst = s.cold.items[item.id.index].style;
                const cross_dim = if (row) cst.h else cst.w;
                if (item.@"align" != .stretch or cross_dim != .auto) continue;
                const want = clamp(@max(0, ln.cross - item.cs - item.ce), if (row) cst.min_h else cst.min_w, if (row) cst.max_h else cst.max_w);
                if (want == item.cross) continue;
                const sz = if (row)
                    e.layoutNode(item.id, item.target, want, item.target, want)
                else
                    e.layoutNode(item.id, want, item.target, want, item.target);
                e.items.items[start + k].cross = crossOf(row, sz);
            }
        }
        const items_final = e.items.items[start..];
        const lines_final = e.lines.items[lines_start..];

        // Content size.
        var used_main: f32 = 0;
        var total_cross: f32 = 0;
        for (lines_final, 0..) |ln, li| {
            var lm: f32 = 0;
            for (items_final[ln.start..ln.end], 0..) |item, k| {
                lm += item.target + item.ms + item.me;
                if (k > 0) lm += st.gap;
            }
            used_main = @max(used_main, lm);
            total_cross += ln.cross;
            if (li > 0) total_cross += st.gap;
        }
        const main_size = inner_main orelse used_main;
        const cross_size = inner_cross orelse total_cross;

        // §9.5 / §9.6: main-axis justification, per line.
        for (lines_final) |ln| {
            const li_items = items_final[ln.start..ln.end];
            const n: f32 = @floatFromInt(li_items.len);
            var used: f32 = 0;
            for (li_items) |item| used += item.target + item.ms + item.me;
            used += st.gap * @max(0, n - 1);
            const free = @max(0, main_size - used);
            var pos: f32 = 0;
            var between: f32 = st.gap;
            switch (st.justify) {
                .start => {},
                .end => pos = free,
                .center => pos = free / 2,
                .space_between => if (n > 1) {
                    between += free / (n - 1);
                },
                .space_around => if (n > 0) {
                    pos = free / n / 2;
                    between += free / n;
                },
                .space_evenly => {
                    pos = free / (n + 1);
                    between += free / (n + 1);
                },
            }
            for (li_items) |*item| {
                pos += item.ms;
                item.main_pos = pos;
                pos += item.target + item.me + between;
            }
            if (st.isReverse()) {
                for (li_items) |*item| item.main_pos = main_size - item.main_pos - item.target;
            }
        }

        // §9.6 align-content: distribute free cross space between lines.
        {
            const n: f32 = @floatFromInt(lines_final.len);
            var used: f32 = 0;
            for (lines_final) |ln| used += ln.cross;
            used += st.gap * @max(0, n - 1);
            const free = @max(0, cross_size - used);
            var pos: f32 = 0;
            var between: f32 = st.gap;
            if (lines_final.len > 1) switch (st.align_content) {
                .start => {},
                .end => pos = free,
                .center => pos = free / 2,
                .space_between => between += free / (n - 1),
                .space_around => {
                    pos = free / n / 2;
                    between += free / n;
                },
                .space_evenly => {
                    pos = free / (n + 1);
                    between += free / (n + 1);
                },
            };
            for (lines_final) |*ln| {
                ln.pos = pos;
                pos += ln.cross + between;
            }
        }

        // §9.6 align-items / align-self: cross positions, then write rects.
        for (items_final) |item| {
            const ln = lines_final[item.line];
            const room = ln.cross - item.cross - item.cs - item.ce;
            const off = switch (item.@"align") {
                .start, .stretch, .baseline => item.cs,
                .end => item.cs + room,
                .center => item.cs + room / 2,
            };
            const cpos = ln.pos + off;
            if (row) e.setPos(item.id, pad.l + item.main_pos, pad.t + cpos) else e.setPos(item.id, pad.l + cpos, pad.t + item.main_pos);
        }

        return if (row) .{ .w = used_main, .h = total_cross } else .{ .w = total_cross, .h = used_main };
    }

    /// §9.7 Resolving Flexible Lengths for one line.
    fn resolveFlexible(items: []Item, inner_main: ?f32, gap: f32) void {
        if (items.len == 0) return;
        const gaps = gap * @as(f32, @floatFromInt(items.len - 1));
        if (inner_main == null) {
            for (items) |*item| item.target = item.hyp;
            return;
        }
        const avail = inner_main.?;
        var used: f32 = gaps;
        for (items) |item| used += item.hyp + item.ms + item.me;
        const grow = used < avail;
        // Step 2: size inflexible items.
        for (items) |*item| {
            item.frozen = if (grow) (item.grow == 0 or item.base > item.hyp) else (item.shrink == 0 or item.base < item.hyp);
            item.target = item.hyp;
        }
        // Step 4: loop, freezing min/max violators.
        var iter: u32 = 0;
        while (iter < 16) : (iter += 1) {
            var any = false;
            var free: f32 = avail - gaps;
            var sum_grow: f32 = 0;
            var sum_scaled: f32 = 0;
            for (items) |item| {
                free -= item.ms + item.me;
                if (item.frozen) {
                    free -= item.target;
                } else {
                    any = true;
                    free -= item.base;
                    sum_grow += item.grow;
                    sum_scaled += item.shrink * item.base;
                }
            }
            if (!any) break;
            var total_violation: f32 = 0;
            for (items) |*item| {
                if (item.frozen) continue;
                var t = item.base;
                if (grow) {
                    if (sum_grow > 0) t += free * item.grow / @max(sum_grow, 1);
                } else if (sum_scaled > 0) {
                    t += free * (item.shrink * item.base) / sum_scaled;
                }
                const clamped = @max(0, clamp(t, item.min, item.max));
                total_violation += clamped - t;
                item.target = clamped;
                item.cross = clamped - t; // reuse as the violation for this pass
            }
            for (items) |*item| {
                if (item.frozen) continue;
                if (total_violation == 0 or (total_violation > 0 and item.cross > 0) or (total_violation < 0 and item.cross < 0))
                    item.frozen = true;
            }
        }
        for (items) |*item| item.cross = 0;
    }

    fn stack(e: *Engine, id: NodeId, inner_w: ?f32, inner_h: ?f32, avail_w: ?f32, avail_h: ?f32) Size {
        const s = e.store;
        const st = s.cold.items[id.index].style;
        const pad = edges(&st);
        var content: Size = .{};
        var it = s.children(id);
        while (it.next()) |c| {
            const cst = s.cold.items[c.index].style;
            if (cst.display == .none) {
                _ = e.layoutNode(c, 0, 0, 0, 0);
                continue;
            }
            if (cst.position == .absolute) continue;
            const m = cst.margin;
            const al = cst.align_self orelse st.align_items;
            const kw: ?f32 = if (al == .stretch and cst.w == .auto and inner_w != null) @max(0, inner_w.? - m.horizontal()) else null;
            const kh: ?f32 = if (al == .stretch and cst.h == .auto and inner_h != null) @max(0, inner_h.? - m.vertical()) else null;
            const aw: ?f32 = if (inner_w orelse avail_w) |a| @max(0, a - m.horizontal()) else null;
            const ah: ?f32 = if (inner_h orelse avail_h) |a| @max(0, a - m.vertical()) else null;
            const sz = e.layoutNode(c, kw, kh, aw, ah);
            content.w = @max(content.w, sz.w + m.horizontal());
            content.h = @max(content.h, sz.h + m.vertical());
        }
        const box_w = inner_w orelse content.w;
        const box_h = inner_h orelse content.h;
        it = s.children(id);
        while (it.next()) |c| {
            const cst = s.cold.items[c.index].style;
            if (cst.display == .none or cst.position == .absolute) continue;
            const m = cst.margin;
            const al = cst.align_self orelse st.align_items;
            const r = s.relRect(c);
            const fx = alignOffset(al, box_w - r.w - m.horizontal());
            const fy = alignOffset(al, box_h - r.h - m.vertical());
            e.setPos(c, pad.l + m.l + fx, pad.t + m.t + fy);
        }
        return content;
    }

    fn alignOffset(al: style_mod.Align, free: f32) f32 {
        return switch (al) {
            .start, .stretch, .baseline => 0,
            .center => free / 2,
            .end => free,
        };
    }

    /// Places `position = absolute` children against the padding box.
    fn layoutAbsolute(e: *Engine, id: NodeId, size: Size) void {
        const s = e.store;
        const st = s.cold.items[id.index].style;
        const bw = st.border_w;
        const pw = @max(0, size.w - 2 * bw);
        const ph = @max(0, size.h - 2 * bw);
        var it = s.children(id);
        while (it.next()) |c| {
            const cst = s.cold.items[c.index].style;
            if (cst.position != .absolute or cst.display == .none) continue;
            const in = cst.inset;
            const m = cst.margin;
            var kw: ?f32 = cst.w.resolve(pw);
            var kh: ?f32 = cst.h.resolve(ph);
            if (kw == null and in.l != null and in.r != null) kw = @max(0, pw - in.l.? - in.r.? - m.horizontal());
            if (kh == null and in.t != null and in.b != null) kh = @max(0, ph - in.t.? - in.b.? - m.vertical());
            const sz = e.layoutNode(c, kw, kh, pw, ph);
            const x = if (in.l) |l| bw + l + m.l else if (in.r) |r| bw + pw - r - m.r - sz.w else bw + st.padding.l + m.l;
            const y = if (in.t) |t| bw + t + m.t else if (in.b) |b| bw + ph - b - m.b - sz.h else bw + st.padding.t + m.t;
            e.setPos(c, x, y);
        }
    }
};

test {
    std.testing.refAllDecls(@This());
}
