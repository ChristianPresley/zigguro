//! Markdown images (E04.F06.S01.T02): a paragraph that is one image or
//! `![[embed]]` becomes an image block. The app's `ImageLoader` loads it
//! asynchronously; until it has, a placeholder shows the alt text. Unsafe
//! sources are never loaded.

const std = @import("std");
const ast = @import("ast.zig");
const doc_mod = @import("doc.zig");
const links = @import("links.zig");
const view_mod = @import("view.zig");
const geom = @import("../core/geom.zig");
const hash = @import("../core/hash.zig");
const widget = @import("../core/widget.zig");
const canvas = @import("../paint/canvas.zig");
const measure_mod = @import("../layout/measure.zig");
const paint_cx = @import("../paint/paint_cx.zig");

const Doc = doc_mod.Doc;
const none = ast.none;

/// A loaded image: its texture and natural size (logical pixels).
pub const ImageHandle = struct {
    tex: canvas.TextureId,
    w: f32,
    h: f32,
};

/// Loads images for a view. `load` returns null until the image is
/// ready (it should start loading on the first call); when it finishes,
/// the app calls `MdViewState.imagesChanged` and rebuilds.
pub const ImageLoader = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// The operations.
    pub const VTable = struct {
        load: *const fn (ptr: *anyopaque, src: []const u8) ?ImageHandle,
    };

    /// See `VTable.load`.
    pub fn load(l: ImageLoader, src: []const u8) ?ImageHandle {
        return l.vtable.load(l.ptr, src);
    }
};

/// The image inline when paragraph `i` holds nothing else.
pub fn soleImage(d: *const Doc, i: u32) ?u32 {
    const first = d.blocks.items[i].first_inline;
    if (first == none) return null;
    const n = d.inlines.items[first];
    if (n.next != none) return null;
    return if (n.kind == .image or n.kind == .embed) first else null;
}

/// Placeholder size before (or without) the image.
const placeholder: geom.Size = .{ .w = 320, .h = 72 };

/// An image block.
pub const ImageBlock = struct {
    /// Shown in snapshots.
    pub const name = "md_image";

    /// The source, alt text and loader generation.
    pub const Props = struct {
        view: *view_mod.MdViewState,
        src: []const u8,
        alt: []const u8,
        blocked: bool,
        gen: u32,
    };

    fn handle(props: *const Props) ?ImageHandle {
        if (props.blocked) return null;
        const l = props.view.props.image_loader orelse return null;
        const h = l.load(props.src) orelse return null;
        if (h.w <= 0 or h.h <= 0) return null;
        return h;
    }

    /// Keeps its own width in a stretching column.
    pub fn style(_: *const Props, _: *const @import("../theme/theme.zig").Theme) @import("../layout/style.zig").Style {
        return .{ .align_self = .start, .shrink = 1 };
    }

    /// The image fitted to the width, or the placeholder.
    pub fn measure(_: *measure_mod.MeasureCx, props: *const Props, _: *widget.NoState, max_w: ?f32) geom.Size {
        const mw = max_w orelse std.math.inf(f32);
        const h = handle(props) orelse return .{ .w = @min(placeholder.w, mw), .h = placeholder.h };
        const w = @min(h.w, mw);
        return .{ .w = w, .h = h.h * w / h.w };
    }

    /// The texture, or a box with the alt text.
    pub fn paint(pc: *paint_cx.PaintCx, props: *const Props, _: *widget.NoState) void {
        const r = pc.bounds();
        const rad = pc.dim(.radius_md);
        if (handle(props)) |h| {
            pc.image(h.tex, r, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, geom.Color.hex(0xffffff), rad);
            return;
        }
        pc.fill(r, .bg_sunken, rad);
        pc.border(r, pc.dim(.border_w), pc.color(.border), rad);
        var buf: [256]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "{s}{s}", .{ if (props.blocked) "Blocked image: " else "🖼 ", if (props.alt.len > 0) props.alt else props.src }) catch props.alt;
        const st: @import("../paint/text.zig").TextStyle = .{ .size = pc.dim(.font_size_sm) };
        const lh = pc.text_sys.metrics(st).line_h;
        pc.textBox(label, st, pc.color(if (props.blocked) .warning else .fg_muted), .{ .x = 8, .y = (r.h - lh) / 2, .w = r.w - 16, .h = lh }, false, .center);
    }

    /// An image named by its alt text.
    pub fn a11y(props: *const Props, _: *widget.NoState) widget.A11y {
        return .{ .role = .img, .name = props.alt };
    }
};

/// Builds paragraph `i`, which is image inline `img`.
pub fn build(b: *view_mod.Builder, i: u32, img: u32) void {
    const d = b.s.doc;
    const n = &d.inlines.items[img];
    const src = if (n.kind == .embed) d.inlineText(n) else d.destOf(n);
    const e = b.s.entry(i);
    const alt = if (e) |x| x.flat.text.items else "";
    _ = b.ui.leaf(ImageBlock, .{
        .view = b.s,
        .src = src,
        .alt = alt,
        .blocked = n.unsafe or links.isUnsafeDestination(src),
        .gen = b.s.image_gen,
    });
}
