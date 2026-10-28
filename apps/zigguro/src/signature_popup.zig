//! The signature help popup (E07.F03.S01.T03): above the caret line, the
//! active signature's label with the active parameter bold, "2/3" when
//! there are several (Up and Down cycle them, through `CodeIntel`), then
//! the parameter's and the signature's documentation. It never takes
//! focus; it sits above the line so the completion list can open below.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_codeintel = @import("zg_codeintel");

const Allocator = std.mem.Allocator;
const Window = zg_gui.Window;
const Ui = zg_gui.Ui;
const Rect = zg_gui.core.Rect;
const Size = zg_gui.core.Size;
const OverlayId = zg_gui.w.overlay.OverlayId;
const PaintCx = zg_gui.paint.PaintCx;
const MeasureCx = zg_gui.layout.measure.MeasureCx;
const Style = zg_gui.layout.Style;
const Theme = zg_gui.theme.Theme;
const TextStyle = zg_gui.paint.text.TextStyle;
const widget = zg_gui.core.widget;
const markdown = zg_gui.markdown;
const SignatureService = zg_codeintel.features.SignatureService;
const HoverService = zg_codeintel.features.HoverService;

pub const max_width: f32 = 560;

pub const SignaturePopup = struct {
    gpa: Allocator,
    win: ?*Window = null,
    overlay: OverlayId = .none,
    /// Highlights code fences (the editor's highlighter, set by the
    /// workbench).
    highlighter: @FieldType(markdown.MdViewProps, "highlighter") = null,
    label: []const u8 = "",
    param: ?[2]usize = null,
    counter: [16]u8 = undefined,
    counter_len: usize = 0,
    md: ?*Md = null,
    text: std.ArrayList(u8) = .empty,

    const Md = struct {
        doc: markdown.Doc,
        view: markdown.MdViewState,
    };

    pub fn init(gpa: Allocator) SignaturePopup {
        return .{ .gpa = gpa };
    }

    /// Not `deinit`: the overlay's view calls that when it closes.
    pub fn release(p: *SignaturePopup) void {
        p.hide();
        p.freeMd();
        p.text.deinit(p.gpa);
    }

    fn freeMd(p: *SignaturePopup) void {
        const m = p.md orelse return;
        m.view.deinit();
        m.doc.deinit();
        p.gpa.destroy(m);
        p.md = null;
    }

    /// Shows `st` (borrowed until the next `show` or `hide`) above
    /// `anchor` (the caret, window coordinates).
    pub fn show(p: *SignaturePopup, st: *const SignatureService.State, anchor: Rect) !void {
        const w = p.win orelse return;
        const sig = st.signature();
        p.label = sig.label;
        p.param = st.param_range;
        p.counter_len = if (st.signatures.len > 1) if (std.fmt.bufPrint(&p.counter, "{d}/{d}", .{ st.active + 1, st.signatures.len })) |x| x.len else |_| 0 else 0;
        p.freeMd();
        p.text.clearRetainingCapacity();
        if (st.param) |i| if (sig.parameters) |ps| if (ps[i].documentation) |d| try docInto(p.gpa, d, &p.text);
        if (sig.documentation) |d| {
            if (p.text.items.len > 0) try p.text.appendSlice(p.gpa, "\n\n");
            try docInto(p.gpa, d, &p.text);
        }
        if (p.text.items.len > 0) {
            const m = try p.gpa.create(Md);
            errdefer p.gpa.destroy(m);
            m.* = .{ .doc = markdown.stream.init(p.gpa, .{}), .view = undefined };
            m.view = .init(p.gpa, &m.doc);
            p.md = m;
            _ = m.view.append(p.text.items) catch {};
            _ = m.view.finish() catch {};
        }
        if (p.isOpen()) {
            if (w.overlays.indexOf(p.overlay)) |i| w.overlays.items.items[i].opts.anchor = .{ .rect = anchor };
            w.markAllDirty();
            return;
        }
        p.overlay = try w.openOverlay(.of(p), .{
            .layer = .popover,
            .anchor = .{ .rect = anchor },
            .placement = .{ .side = .above, .alignment = .start, .gap = 2 },
            .light_dismiss = true,
            .consume_outside_click = false,
            .take_focus = false,
            .restore_focus = false,
            .role = .tooltip,
            .label = "Signature help",
            .test_id = "signature",
            .on_close = .{ .ctx = p, .f = onClose },
        });
        w.markAllDirty();
    }

    fn docInto(gpa: Allocator, d: anytype, out: *std.ArrayList(u8)) !void {
        switch (d) {
            .string => |s| try HoverService.escapeInto(gpa, s, out),
            .markup_content => |mc| if (mc.kind == .Markdown) try HoverService.sanitize(gpa, mc.value, out) else try HoverService.escapeInto(gpa, mc.value, out),
        }
    }

    pub fn hide(p: *SignaturePopup) void {
        p.label = "";
        const w = p.win orelse return;
        if (p.overlay == .none) return;
        const id = p.overlay;
        p.overlay = .none;
        w.closeOverlay(id);
    }

    pub fn isOpen(p: *const SignaturePopup) bool {
        const w = p.win orelse return false;
        return p.overlay != .none and w.isOverlayOpen(p.overlay);
    }

    fn onClose(ctx: *anyopaque, id: OverlayId) void {
        const p: *SignaturePopup = @ptrCast(@alignCast(ctx));
        if (p.overlay == id) p.overlay = .none;
    }

    pub fn build(p: *SignaturePopup, ui: *Ui) void {
        if (p.label.len == 0) return;
        ui.open(.{ .style = .{ .dir = .column, .max_w = max_width, .gap = 4 } });
        defer ui.close();
        _ = ui.leaf(Label, .{ .label = p.label, .param = p.param, .counter = p.counter[0..p.counter_len] });
        const m = p.md orelse return;
        ui.open(.{ .style = .{ .dir = .column, .max_h = 200, .scroll_y = true }, .test_id = "signature-docs" });
        defer ui.close();
        markdown.view(ui, &m.view, .{ .compact = true, .virtualize = false, .max_width = max_width, .highlighter = p.highlighter, .test_id = "signature-docs-text" });
    }
};

/// The signature label, its active parameter bold.
const Label = struct {
    pub const name = "signature_label";

    pub const Props = struct {
        label: []const u8,
        param: ?[2]usize = null,
        counter: []const u8 = "",
    };

    fn styles(th: *const Theme) [2]TextStyle {
        const size = th.dim(.font_size);
        return .{ .{ .font = .mono, .size = size }, .{ .font = .mono, .size = size, .weight = 700 } };
    }

    pub fn style(_: *const Props, _: *const Theme) Style {
        return .{};
    }

    pub fn measure(mc: *MeasureCx, props: *const Props, _: *widget.NoState, _: ?f32) Size {
        const st = styles(mc.theme);
        const m = mc.text.metrics(st[0]);
        var w = mc.text.width(st[0], props.label) + 8;
        if (props.counter.len > 0) w += mc.text.width(st[0], props.counter) + 12;
        return .{ .w = @min(w, max_width), .h = m.line_h + 4 };
    }

    pub fn paint(pc: *PaintCx, props: *const Props, _: *widget.NoState) void {
        const r = pc.bounds();
        const st = styles(pc.theme);
        const m = pc.text_sys.metrics(st[0]);
        const baseline = r.y + 2 + (m.line_h - (m.ascent + m.descent)) / 2 + m.ascent;
        var x = r.x;
        const muted = pc.color(.fg_muted);
        if (props.counter.len > 0) {
            pc.textLine(props.counter, st[0], muted, .{ .x = x, .y = baseline });
            x += pc.text_sys.width(st[0], props.counter) + 12;
        }
        const fg = pc.color(.fg);
        const a, const b = props.param orelse .{ props.label.len, props.label.len };
        const parts = [_]struct { []const u8, bool }{ .{ props.label[0..a], false }, .{ props.label[a..b], true }, .{ props.label[b..], false } };
        for (parts) |part| {
            if (part[0].len == 0) continue;
            const s = st[@intFromBool(part[1])];
            pc.textLine(part[0], s, if (part[1]) pc.color(.accent) else fg, .{ .x = x, .y = baseline });
            x += pc.text_sys.width(s, part[0]);
        }
    }

    pub fn a11y(props: *const Props, _: *widget.NoState) widget.A11y {
        return .{ .role = .text, .name = props.label };
    }
};

test "signature popup: above the caret, active parameter and counter; hides" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const Page = struct {
        pub fn build(_: *@This(), ui: *Ui) void {
            ui.id("page");
            ui.open(.{ .style = .{ .w = .{ .pct = 100 }, .h = .{ .pct = 100 } }, .focusable = true });
            ui.close();
        }
    };
    var page: Page = .{};
    const t = try zg_gui.testing.TestApp.init(gpa, .{ .root = .of(&page), .size = .{ .w = 800, .h = 400 } });
    defer t.deinit();
    const protocol = @import("zg_codeintel").features.completion_rank.protocol;
    const sigs = [_]protocol.SignatureInformation{
        .{ .label = "f(a: u8, b: u16)", .documentation = .{ .string = "Adds." }, .parameters = &.{ .{ .label = .{ .string = "a: u8" }, .documentation = .{ .string = "First." } }, .{ .label = .{ .string = "b: u16" } } } },
        .{ .label = "f(c: bool)" },
    };
    const st: SignatureService.State = .{ .h = undefined, .at = 2, .line = 0, .signatures = &sigs, .active = 0, .param = 0, .param_range = .{ 2, 7 } };
    var p: SignaturePopup = .init(gpa);
    defer p.release();
    p.win = t.win;
    try p.show(&st, .{ .x = 100, .y = 200, .w = 2, .h = 16 });
    _ = t.settle();
    try testing.expect(p.isOpen());
    const r = try t.rectOf(.{ .test_id = "signature" });
    try testing.expect(r.y + r.h <= 200);
    try testing.expectEqualStrings("1/2", p.counter[0..p.counter_len]);
    try testing.expectEqualStrings("First\\.\n\nAdds\\.", p.text.items);
    p.hide();
    _ = t.settle();
    try testing.expect(!p.isOpen());
}
