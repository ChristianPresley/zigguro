//! The HUD's frame-time graph (E14.F03.S01.T02): one stacked bar per
//! frame, right-aligned (the newest frame on the right), with lines at the
//! refresh period and at 16.67 ms. Over-budget bars are drawn in the
//! theme's `danger` colour. A press on a bar reports its frame.
//!
//! Phase colours use existing status tokens (dispatch `info`, build
//! `accent`, layout `success`, paint `warning`, submit `fg_muted`, GPU
//! `border_strong`) until E15 adds `perf.*` tokens.

const std = @import("std");
const zg_gui = @import("zg_gui");
const model = @import("hud_model.zig");

const geom = zg_gui.core.geom;
const Token = zg_gui.theme.Token;
const PaintCx = zg_gui.paint.PaintCx;
const event_mod = zg_gui.input.event;

/// The colour token of each `model.Phase`.
pub const phase_tokens = [_]Token{ .info, .accent, .success, .warning, .fg_muted, .border_strong };

/// Called with the pressed bar's frame.
pub const Click = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, seq: u64) void,
};

pub const Graph = struct {
    pub const name = "perf_hud_graph";
    pub const State = struct {};

    pub const Props = struct {
        w: f32,
        h: f32,
        /// Bar slots (the newest bar is in the last one).
        slots: u16,
        bars: []const model.Bar,
        scale_ns: u64,
        refresh_ns: u64,
        click: ?Click = null,
        /// Changes when the bars do (the newest frame and the count).
        hash: u64 = 0,
    };

    pub fn style(p: *const Props, _: *const zg_gui.theme.Theme) zg_gui.layout.style.Style {
        return .{ .w = .{ .px = p.w }, .h = .{ .px = p.h } };
    }

    pub fn measure(_: *zg_gui.layout.measure.MeasureCx, p: *const Props, _: *State, _: ?f32) geom.Size {
        return .{ .w = p.w, .h = p.h };
    }

    pub fn paintHash(p: *const Props) u64 {
        return p.hash ^ (p.scale_ns *% 31) ^ p.refresh_ns;
    }

    pub fn paint(pc: *PaintCx, p: *const Props, _: *State) void {
        const box = pc.bounds();
        pc.fill(box, .bg_sunken, 2);
        const slot_w = box.w / @as(f32, @floatFromInt(@max(1, p.slots)));
        const bar_w = @max(1, slot_w - if (slot_w >= 3) @as(f32, 1) else 0);
        const k = box.h / @as(f32, @floatFromInt(@max(1, p.scale_ns)));
        const first = @as(usize, p.slots) -| p.bars.len;
        const danger = pc.color(.danger);
        for (p.bars, 0..) |b, i| {
            const x = box.x + @as(f32, @floatFromInt(first + i)) * slot_w;
            var y = box.bottom();
            for (b.ns, 0..) |ns, ph| {
                if (ns == 0) continue;
                const h = @min(@as(f32, @floatFromInt(ns)) * k, y - box.y);
                if (h <= 0) break;
                y -= h;
                pc.rect(.{ .x = x, .y = y, .w = bar_w, .h = h }, if (b.over) danger else pc.color(phase_tokens[ph]), .all(0));
            }
        }
        line(pc, box, k, p.refresh_ns, pc.color(.fg));
        if (p.refresh_ns != model.line_60hz_ns) line(pc, box, k, model.line_60hz_ns, pc.color(.fg_muted));
    }

    fn line(pc: *PaintCx, box: geom.Rect, k: f32, ns: u64, c: geom.Color) void {
        const y = box.bottom() - @as(f32, @floatFromInt(ns)) * k;
        if (y <= box.y) return;
        pc.rect(.{ .x = box.x, .y = y, .w = box.w, .h = 1 }, c, .all(0));
    }

    pub fn event(ec: *event_mod.EventCx, p: *const Props, _: *State, ev: *const event_mod.InputEvent) bool {
        switch (ev.*) {
            .pointer_down => |d| {
                const c = p.click orelse return false;
                const l = ec.local(d.pos);
                const slot_w = p.w / @as(f32, @floatFromInt(@max(1, p.slots)));
                if (l.x < 0 or slot_w <= 0) return false;
                const i: usize = @intFromFloat(@floor(l.x / slot_w));
                const first = @as(usize, p.slots) -| p.bars.len;
                if (i < first or i - first >= p.bars.len) return false;
                c.f(c.ctx, p.bars[i - first].seq);
                return true;
            },
            else => return false,
        }
    }
};
