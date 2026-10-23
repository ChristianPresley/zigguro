//! The image view widget (E04.F06.S02.T02): draws an `ImageCache` image
//! fitted into its box (contain, cover, actual size or fill), over a
//! checkerboard, with zoom and pan when `zoomable`, a pixel grid from 8×
//! zoom, an error state and an info overlay.
//!
//! - Zoom z ∈ [0.1, 32] is anchored at the pointer: the image point under
//!   it stays put. Ctrl+wheel steps ×1.1 per notch; `+`/`-` zoom about the
//!   centre, `0` fits and `1` shows 100 %. Zoom changes apply at once
//!   (smooth animation and pinch wait for E04.F04 physics and a gesture
//!   event).
//! - Middle drag, or Space and left drag, pans; at least 25 % of the image
//!   stays inside the view.
//! - From 2× the image is sampled nearest (crisp pixels); from 8× 1 px grid
//!   lines mark pixel boundaries over the visible part.
//! - The checkerboard is one cached texture of `checker_cells` squares a
//!   side, drawn as tiles.
//!
//! Zoom and pan are in logical pixels: 100 % maps one image pixel to one
//! logical pixel.

const std = @import("std");
const zg_platform = @import("zg_platform");
const geom = @import("../core/geom.zig");
const widget = @import("../core/widget.zig");
const ui_mod = @import("../core/ui.zig");
const paint_cx = @import("../paint/paint_cx.zig");
const canvas = @import("../paint/canvas.zig");
const measure_mod = @import("../layout/measure.zig");
const style_mod = @import("../layout/style.zig");
const theme_mod = @import("../theme/theme.zig");
const event_mod = @import("../input/event.zig");
const image = @import("image.zig");
const cache_mod = @import("cache.zig");
const textures = @import("textures.zig");

const Rect = geom.Rect;
const Vec2 = geom.Vec2;
const Size = geom.Size;
const Color = geom.Color;
const Ui = ui_mod.Ui;
const PaintCx = paint_cx.PaintCx;
const TextureId = canvas.TextureId;
const ImageCache = cache_mod.ImageCache;

/// How an image fills its box.
pub const Fit = enum(u8) {
    /// Whole image, aspect kept, never upscaled past the box.
    contain,
    /// Box covered, aspect kept (edges cropped).
    cover,
    /// One image pixel per logical pixel, centred.
    actual,
    /// Stretched to the box.
    fill,
};

pub const min_zoom: f32 = 0.1;
pub const max_zoom: f32 = 32;
/// Zoom from which pixels sample nearest.
pub const nearest_zoom: f32 = 2;
/// Zoom from which the pixel grid shows.
pub const grid_zoom: f32 = 8;
/// Zoom factor per wheel notch.
pub const wheel_step: f32 = 1.1;
/// Logical pixels per checkerboard square.
pub const checker_px: f32 = 8;

/// `imageView` props.
pub const ImageViewProps = struct {
    cache: *ImageCache,
    handle: cache_mod.Handle,
    fit: Fit = .contain,
    zoomable: bool = false,
    checkerboard: bool = true,
    info_overlay: bool = false,
    radius: f32 = 0,
    alt: []const u8 = "",
    /// The view's size; the image's own (fitted to the width) when null.
    w: ?f32 = null,
    h: ?f32 = null,
};

/// Zoom and pan of one view.
pub const ImageViewState = struct {
    /// 0 until the user zooms: the fit mode decides.
    zoom: f32 = 0,
    /// The image's top-left corner in the view (when `zoom` is set).
    pan: Vec2 = .{},
    drag: ?struct { from: Vec2, pan0: Vec2 } = null,
    ctrl: bool = false,
    space: bool = false,
};

/// Where the image goes in `box` for fit mode `fit`.
pub fn fitRect(fit: Fit, box: Rect, iw: f32, ih: f32) Rect {
    if (iw <= 0 or ih <= 0) return .{ .x = box.x, .y = box.y };
    const s: f32 = switch (fit) {
        .contain => @min(1, @min(box.w / iw, box.h / ih)),
        .cover => @max(box.w / iw, box.h / ih),
        .actual => 1,
        .fill => return box,
    };
    const w = iw * s;
    const h = ih * s;
    return .{ .x = box.x + (box.w - w) / 2, .y = box.y + (box.h - h) / 2, .w = w, .h = h };
}

/// The image rect for `st` (zoomed) or the fit mode.
pub fn imageRect(st: *const ImageViewState, fit: Fit, box: Rect, iw: f32, ih: f32) Rect {
    if (st.zoom == 0) return fitRect(fit, box, iw, ih);
    return .{ .x = box.x + st.pan.x, .y = box.y + st.pan.y, .w = iw * st.zoom, .h = ih * st.zoom };
}

/// Takes over from the fit mode (zoom and pan from what it shows).
fn ensureZoom(st: *ImageViewState, fit: Fit, box: Rect, iw: f32, ih: f32) void {
    if (st.zoom != 0) return;
    const r = fitRect(fit, .{ .w = box.w, .h = box.h }, iw, ih);
    st.zoom = std.math.clamp(r.w / iw, min_zoom, max_zoom);
    st.pan = .{ .x = r.x, .y = r.y };
}

/// Multiplies the zoom by `factor`, keeping the image point under
/// `anchor` (view-local) where it is, then clamps the pan.
pub fn zoomAt(st: *ImageViewState, fit: Fit, box: Size, iw: f32, ih: f32, anchor: Vec2, factor: f32) void {
    const b: Rect = .{ .w = box.w, .h = box.h };
    ensureZoom(st, fit, b, iw, ih);
    const z = std.math.clamp(st.zoom * factor, min_zoom, max_zoom);
    // The image point under the anchor, before and after.
    const px = (anchor.x - st.pan.x) / st.zoom;
    const py = (anchor.y - st.pan.y) / st.zoom;
    st.zoom = z;
    st.pan = .{ .x = anchor.x - px * z, .y = anchor.y - py * z };
    clampPan(st, box, iw, ih);
}

/// Sets the zoom to `z` about the view centre.
pub fn setZoom(st: *ImageViewState, fit: Fit, box: Size, iw: f32, ih: f32, z: f32) void {
    ensureZoom(st, fit, .{ .w = box.w, .h = box.h }, iw, ih);
    zoomAt(st, fit, box, iw, ih, .{ .x = box.w / 2, .y = box.h / 2 }, z / st.zoom);
}

/// Keeps at least a quarter of the image (or the whole view, when that
/// is smaller) inside the view.
pub fn clampPan(st: *ImageViewState, box: Size, iw: f32, ih: f32) void {
    const w = iw * st.zoom;
    const h = ih * st.zoom;
    const qx = @min(w / 4, box.w);
    const qy = @min(h / 4, box.h);
    st.pan.x = std.math.clamp(st.pan.x, qx - w, box.w - qx);
    st.pan.y = std.math.clamp(st.pan.y, qy - h, box.h - qy);
}

/// Draws `tex` (a `side`-texel square tile shown `tile` logical pixels a
/// side) repeated over `area`, tiles aligned to `origin`.
fn tiled(pc: *PaintCx, tex: TextureId, area: Rect, origin: Vec2, tile: f32) void {
    if (area.w <= 0 or area.h <= 0 or tile <= 0) return;
    const white: Color = .{ .r = 255, .g = 255, .b = 255 };
    var y = origin.y + @floor((area.y - origin.y) / tile) * tile;
    while (y < area.bottom()) : (y += tile) {
        var x = origin.x + @floor((area.x - origin.x) / tile) * tile;
        while (x < area.right()) : (x += tile) {
            const cell: Rect = .{ .x = x, .y = y, .w = tile, .h = tile };
            const vis = cell.intersect(area);
            if (vis.w <= 0 or vis.h <= 0) continue;
            pc.image(tex, vis, .{ .x = (vis.x - x) / tile, .y = (vis.y - y) / tile, .w = vis.w / tile, .h = vis.h / tile }, white, 0);
        }
    }
}

/// The widget behind `imageView`.
pub const ImageView = struct {
    /// Shown in snapshots.
    pub const name = "image";
    /// Focusable when zoomable (for the zoom keys).
    pub const focusable = true;

    pub const State = ImageViewState;

    /// What a frame shows.
    pub const Phase = enum(u8) { loading, shown, failed };

    /// Built by `imageView` from the cache.
    pub const Props = struct {
        phase: Phase = .loading,
        tex: TextureId = .none,
        checker: TextureId = .none,
        /// The full image size (a preview texture is stretched over it).
        img_w: u32 = 0,
        img_h: u32 = 0,
        format: image.Format = .unknown,
        file_size: u64 = 0,
        frames: u32 = 1,
        /// Changes the paint hash as an animation plays.
        frame: u32 = 0,
        preview: bool = false,
        err: []const u8 = "",
        fit: Fit = .contain,
        zoomable: bool = false,
        info_overlay: bool = false,
        radius: f32 = 0,
        alt: []const u8 = "",
        w: ?f32 = null,
        h: ?f32 = null,
    };

    /// The given size, else the image's.
    pub fn style(p: *const Props, _: *const theme_mod.Theme) style_mod.Style {
        return .{
            .w = if (p.w) |w| .{ .px = w } else .auto,
            .h = if (p.h) |h| .{ .px = h } else .auto,
            .clip = true,
            .radius = p.radius,
        };
    }

    /// The image size, scaled down to the width on offer.
    pub fn measure(_: *measure_mod.MeasureCx, p: *const Props, _: *State, max_w: ?f32) Size {
        var w: f32 = @floatFromInt(p.img_w);
        var h: f32 = @floatFromInt(p.img_h);
        if (p.phase != .shown) {
            w = 160;
            h = 120;
        }
        if (max_w) |m| if (w > m and w > 0) {
            h *= m / w;
            w = m;
        };
        return .{ .w = p.w orelse w, .h = p.h orelse h };
    }

    pub fn paint(pc: *PaintCx, p: *const Props, st: *State) void {
        const box = pc.bounds();
        switch (p.phase) {
            .loading => return,
            .failed => return paintError(pc, p, box),
            .shown => {},
        }
        const iw: f32 = @floatFromInt(p.img_w);
        const ih: f32 = @floatFromInt(p.img_h);
        const dst = imageRect(st, p.fit, box, iw, ih);
        const vis = dst.intersect(box);
        if (vis.w <= 0 or vis.h <= 0) return;
        pc.pushClip(box, p.radius);
        defer pc.popClip();
        if (p.checker != .none) tiled(pc, p.checker, vis, .{ .x = dst.x, .y = dst.y }, checker_px * @as(f32, ImageCache.checker_cells));
        const scale = dst.w / iw;
        const tex = if (scale >= nearest_zoom) textures.ImageTextures.nearest(p.tex) else p.tex;
        const uv: Rect = .{ .x = (vis.x - dst.x) / dst.w, .y = (vis.y - dst.y) / dst.h, .w = vis.w / dst.w, .h = vis.h / dst.h };
        pc.image(tex, vis, uv, .{ .r = 255, .g = 255, .b = 255 }, 0);
        if (scale >= grid_zoom) paintGrid(pc, dst, vis, scale);
        if (p.info_overlay) paintInfo(pc, p, box, scale);
    }

    /// Lines at the pixel boundaries inside `vis`.
    fn paintGrid(pc: *PaintCx, dst: Rect, vis: Rect, scale: f32) void {
        const c = pc.color(.border);
        var x = dst.x + @ceil((vis.x - dst.x) / scale) * scale;
        while (x <= vis.right()) : (x += scale) pc.rect(.{ .x = x, .y = vis.y, .w = 1, .h = vis.h }, c, .{});
        var y = dst.y + @ceil((vis.y - dst.y) / scale) * scale;
        while (y <= vis.bottom()) : (y += scale) pc.rect(.{ .x = vis.x, .y = y, .w = vis.w, .h = 1 }, c, .{});
    }

    fn paintInfo(pc: *PaintCx, p: *const Props, box: Rect, scale: f32) void {
        var buf: [128]u8 = undefined;
        const kb = (p.file_size + 1023) / 1024;
        const s = std.fmt.bufPrint(&buf, "{d}×{d} {s} {d} KB {d}%", .{ p.img_w, p.img_h, @tagName(p.format), kb, @as(u32, @intFromFloat(@round(scale * 100))) }) catch return;
        const st: @import("../paint/text.zig").TextStyle = .{ .size = pc.dim(.font_size_sm) };
        const pad = pc.dim(.space_sm);
        const tw = pc.text_sys.width(st, s);
        const lh = pc.text_sys.metrics(st).line_h;
        const r: Rect = .{ .x = box.x + pad, .y = box.y + pad, .w = @min(tw + pad * 2, box.w - pad * 2), .h = lh + pad };
        pc.fill(r, .bg_overlay, pc.dim(.radius_sm));
        pc.textBox(s, st, pc.color(.fg), r.inset(.xy(pad, pad / 2)), false, .start);
    }

    /// A broken-image mark, the alt text and the error.
    fn paintError(pc: *PaintCx, p: *const Props, box: Rect) void {
        pc.fill(box, .bg_sunken, p.radius);
        const st: @import("../paint/text.zig").TextStyle = .{ .size = pc.dim(.font_size_sm) };
        const lh = pc.text_sys.metrics(st).line_h;
        const mark = @min(24, @min(box.w, box.h) / 3);
        const top = box.y + (box.h - mark - lh * 2) / 2;
        const m: Rect = .{ .x = box.x + (box.w - mark) / 2, .y = top, .w = mark, .h = mark };
        pc.border(m, 1.5, pc.color(.danger), 3);
        pc.rect(.{ .x = m.x + 3, .y = m.y + m.h * 0.65, .w = m.w - 6, .h = 1.5 }, pc.color(.danger), .{});
        const row = top + mark + 4;
        if (p.alt.len > 0) pc.textBox(p.alt, st, pc.color(.fg), .{ .x = box.x, .y = row, .w = box.w, .h = lh }, false, .center);
        pc.textBox(p.err, st, pc.color(.fg_muted), .{ .x = box.x, .y = row + if (p.alt.len > 0) lh else 0, .w = box.w, .h = lh }, false, .center);
    }

    pub fn event(ec: *event_mod.EventCx, p: *const Props, st: *State, ev: *const event_mod.InputEvent) bool {
        if (!p.zoomable or p.phase != .shown) return false;
        const r = ec.rect();
        const box: Size = .{ .w = r.w, .h = r.h };
        const iw: f32 = @floatFromInt(p.img_w);
        const ih: f32 = @floatFromInt(p.img_h);
        switch (ev.*) {
            .pointer_move => |m| {
                st.ctrl = m.mods.ctrl;
                const d = st.drag orelse return false;
                const l = ec.local(m.pos);
                st.pan = .{ .x = d.pan0.x + l.x - d.from.x, .y = d.pan0.y + l.y - d.from.y };
                clampPan(st, box, iw, ih);
                ec.repaint();
                return true;
            },
            .pointer_down => |m| {
                st.ctrl = m.mods.ctrl;
                if (m.button == .left) ec.focus();
                if (m.button != .middle and !(m.button == .left and st.space)) return false;
                ensureZoom(st, p.fit, .{ .w = r.w, .h = r.h }, iw, ih);
                st.drag = .{ .from = ec.local(m.pos), .pan0 = st.pan };
                ec.capture();
                ec.setCursor(.grabbing);
                return true;
            },
            .pointer_up => {
                if (st.drag == null) return false;
                st.drag = null;
                ec.releaseCapture();
                ec.setCursor(.default);
                return true;
            },
            .scroll => |s| {
                if (!st.ctrl) return false;
                const notches = if (s.precise) s.dy / 40 else s.dy;
                zoomAt(st, p.fit, box, iw, ih, ec.local(s.pos), std.math.pow(f32, wheel_step, notches));
                ec.repaint();
                return true;
            },
            .key => |k| {
                if (k.key == .space) {
                    st.space = k.action != .release;
                    return true;
                }
                if (k.key == .control_left or k.key == .control_right) st.ctrl = k.action != .release;
                if (k.action == .release) return false;
                const z0 = if (st.zoom == 0) blk: {
                    ensureZoom(st, p.fit, .{ .w = r.w, .h = r.h }, iw, ih);
                    break :blk st.zoom;
                } else st.zoom;
                if (k.key == .equal or k.codepoint == '+') {
                    setZoom(st, p.fit, box, iw, ih, z0 * wheel_step);
                } else if (k.key == .minus or k.codepoint == '-') {
                    setZoom(st, p.fit, box, iw, ih, z0 / wheel_step);
                } else if (k.key == .digit_0) {
                    st.* = .{ .space = st.space, .ctrl = st.ctrl };
                } else if (k.key == .digit_1) {
                    setZoom(st, p.fit, box, iw, ih, 1);
                } else return false;
                ec.repaint();
                return true;
            },
            else => return false,
        }
    }

    pub fn a11y(p: *const Props, _: *State) widget.A11y {
        return .{ .role = .img, .name = if (p.alt.len > 0) p.alt else p.err };
    }
};

/// An image from `p.cache`; returns its zoom and pan state.
pub fn imageView(ui: *Ui, p: ImageViewProps) *ImageViewState {
    ui.cx().observe(p.cache.entity);
    var props: ImageView.Props = .{
        .fit = p.fit,
        .zoomable = p.zoomable,
        .info_overlay = p.info_overlay,
        .radius = p.radius,
        .alt = p.alt,
        .w = p.w,
        .h = p.h,
    };
    switch (p.cache.status(p.handle)) {
        .loading => {},
        .failed => |e| {
            props.phase = .failed;
            props.err = @errorName(e);
        },
        .preview, .ready => if (p.cache.use(p.handle, ui.window())) |u| {
            props.phase = .shown;
            props.tex = u.tex;
            props.img_w = u.info.w;
            props.img_h = u.info.h;
            props.format = u.info.format;
            props.file_size = u.info.file_size;
            props.frames = u.info.frames;
            props.frame = u.frame;
            props.preview = u.preview;
            if (p.checkerboard) {
                const th = ui.theme();
                props.checker = p.cache.checker(th.color(.bg_elevated), th.color(.bg_sunken));
            }
        },
    }
    _ = ui.leaf(ImageView, props);
    return ui.lastState(ImageView).?;
}
