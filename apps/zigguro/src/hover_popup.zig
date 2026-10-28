//! The hover popup (E07.F03.S02.T01): a popover above the word a hover
//! is about, showing the language servers' Markdown (diagnostics first).
//! It never takes focus, so typing goes on in the editor; a press
//! outside closes it, and `CodeIntel` hides it when the pointer moves to
//! another word, after the pointer leaves, on Escape or an edit.
//!
//! Links go to `on_link` (the workbench opens files, runs allowlisted
//! commands and copies web links); the Markdown was sanitized by
//! `zg_codeintel`, so no other link or raw HTML reaches here.

const std = @import("std");
const zg_gui = @import("zg_gui");

const Allocator = std.mem.Allocator;
const Window = zg_gui.Window;
const Rect = zg_gui.core.Rect;
const NodeId = zg_gui.core.NodeId;
const OverlayId = zg_gui.w.overlay.OverlayId;
const markdown = zg_gui.markdown;

/// Widest the popup gets.
pub const max_width: f32 = 520;

pub const HoverPopup = struct {
    gpa: Allocator,
    win: ?*Window = null,
    overlay: OverlayId = .none,
    md: ?*Md = null,
    on_link: @FieldType(markdown.MdViewProps, "on_link") = null,
    /// Highlights code fences (the editor's highlighter, set by the
    /// workbench).
    highlighter: @FieldType(markdown.MdViewProps, "highlighter") = null,

    /// The parsed text (on the heap: the view state points at the
    /// document).
    const Md = struct {
        doc: markdown.Doc,
        view: markdown.MdViewState,
    };

    pub fn init(gpa: Allocator) HoverPopup {
        return .{ .gpa = gpa };
    }

    pub fn deinit(p: *HoverPopup) void {
        p.hide();
        p.freeMd();
    }

    fn freeMd(p: *HoverPopup) void {
        const m = p.md orelse return;
        m.view.deinit();
        m.doc.deinit();
        p.gpa.destroy(m);
        p.md = null;
    }

    /// Shows `text` (Markdown) next to `anchor` (window coordinates),
    /// above it when there is room, replacing what was shown.
    pub fn show(p: *HoverPopup, text: []const u8, anchor: Rect) !void {
        const w = p.win orelse return;
        p.hide();
        p.freeMd();
        const m = try p.gpa.create(Md);
        errdefer p.gpa.destroy(m);
        m.* = .{ .doc = markdown.stream.init(p.gpa, .{}), .view = undefined };
        m.view = .init(p.gpa, &m.doc);
        p.md = m;
        _ = m.view.append(text) catch {};
        _ = m.view.finish() catch {};
        p.overlay = try w.openOverlay(.of(p), .{
            .layer = .popover,
            .anchor = .{ .rect = anchor },
            .placement = .{ .side = .above, .alignment = .start, .gap = 2 },
            .light_dismiss = true,
            .consume_outside_click = false,
            .take_focus = false,
            .restore_focus = false,
            .role = .tooltip,
            .label = "Hover",
            .test_id = "hover",
            .on_close = .{ .ctx = p, .f = onClose },
        });
        w.markAllDirty();
    }

    /// Closes the popup (no-op when it is not open).
    pub fn hide(p: *HoverPopup) void {
        const w = p.win orelse return;
        if (p.overlay == .none) return;
        const id = p.overlay;
        p.overlay = .none;
        w.closeOverlay(id);
    }

    pub fn isOpen(p: *const HoverPopup) bool {
        const w = p.win orelse return false;
        return p.overlay != .none and w.isOverlayOpen(p.overlay);
    }

    /// Whether `n` (the node under the pointer) is inside the popup.
    pub fn contains(p: *const HoverPopup, n: NodeId) bool {
        const w = p.win orelse return false;
        if (n.isNone() or p.overlay == .none) return false;
        const i = w.overlays.indexOf(p.overlay) orelse return false;
        const panel = w.overlays.items.items[i].panel;
        return !panel.isNone() and w.store.valid(panel) and w.store.valid(n) and (panel.eql(n) or w.store.isAncestor(panel, n));
    }

    fn onClose(ctx: *anyopaque, id: OverlayId) void {
        const p: *HoverPopup = @ptrCast(@alignCast(ctx));
        if (p.overlay == id) p.overlay = .none;
    }

    pub fn build(p: *HoverPopup, ui: *zg_gui.Ui) void {
        const m = p.md orelse return;
        ui.open(.{ .style = .{ .dir = .column, .max_w = max_width, .max_h = 320, .scroll_y = true } });
        defer ui.close();
        markdown.view(ui, &m.view, .{ .compact = true, .virtualize = false, .max_width = max_width, .on_link = p.on_link, .highlighter = p.highlighter, .test_id = "hover-text" });
    }
};

test "hover popup: shows Markdown above the anchor, without focus; hides" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const Page = struct {
        pub fn build(_: *@This(), ui: *zg_gui.Ui) void {
            ui.id("page");
            ui.open(.{ .style = .{ .w = .{ .pct = 100 }, .h = .{ .pct = 100 } }, .focusable = true });
            ui.close();
        }
    };
    var page: Page = .{};
    const t = try zg_gui.testing.TestApp.init(gpa, .{ .root = .of(&page), .size = .{ .w = 600, .h = 400 } });
    defer t.deinit();
    var p: HoverPopup = .init(gpa);
    defer p.deinit();
    p.win = t.win;
    try p.show("**error**: bad\n\n```zig\nfn f() void\n```", .{ .x = 100, .y = 200, .w = 30, .h = 16 });
    _ = t.settle();
    try testing.expect(p.isOpen());
    const r = try t.rectOf(.{ .test_id = "hover" });
    try testing.expect(r.y + r.h <= 200);
    try testing.expect(t.win.focus.isNone() or !p.contains(t.win.focus));
    try testing.expect(p.contains(t.win.hitTest(.{ .x = r.x + 4, .y = r.y + 4 })));
    // Showing again replaces the text.
    try p.show("plain", .{ .x = 100, .y = 200, .w = 30, .h = 16 });
    _ = t.settle();
    try testing.expect(p.isOpen());
    p.hide();
    _ = t.settle();
    try testing.expect(!p.isOpen());
}
